#!/usr/bin/env python3
"""Explore every route of the converted story, as the app's interpreter runs it.

Usage: explore_routes.py STORY_DIR [GLOBALS_JSON] [--max-states N]

A headless mirror of StoryEngine/Eris control flow (no pictures or sound): text
lines, IF/ELSE, GO, LET, story-level subroutines, choices (ES.SEL.*), the heroine
selection (ES.CSEL.SET) and the framework calls that change variables. At every
choice it forks one path per option. States already seen (same position and
variables) are not explored twice.

Reports scripts and labels never reached, endings reached, and anything that would
break in the app: jumps to unknown labels, running off the end of a script, loops
without text, menus with no available option.

GLOBALS_JSON is the app's Documents/globals.json (the original's @1134 flags,
for example from tools/import_saves.py); without it the explorer starts as a new
player would, and the run is repeated with each ending's global flags carried into
the next playthrough until nothing new is reached.
"""
import json
import os
import random
import sys
from collections import Counter, defaultdict

CURRENT, RELATIVE = -99_999_999, -99_999_998
SCENE_END_CALLS = {"ES.SCENARIO.END"}


def key(name, indices):
    return f"{name}({','.join(map(str, indices))})" if indices else name


class Story:
    def __init__(self, root):
        self.index = json.load(open(os.path.join(root, "index.json"), encoding="utf-8"))
        self.scripts = {int(k): json.load(open(os.path.join(root, f"{int(k):05d}.json"), encoding="utf-8"))
                        for k in self.index["scripts"]}
        self.labels = {name: tuple(v) for name, v in self.index["labels"].items()}


def evaluate(e, vars):
    if isinstance(e, bool):
        return int(e)
    if isinstance(e, (int, float, str)):
        return e
    if "v" in e:
        name = e["v"]
        idx = [int(num(evaluate(x, vars))) for x in e.get("i", [])]
        return vars.get(key(name, idx), "" if name.startswith("$") else 0)
    if "r" in e:
        return e["r"]
    op, args = e["o"], [evaluate(a, vars) for a in e["a"]]
    if len(args) == 1:
        a = args[0]
        return {"neg": lambda: -num(a), "str": lambda: text(a), "int": lambda: int(num(a))}.get(op, lambda: a)()
    a, b = args
    if isinstance(a, str) or isinstance(b, str):
        if op == "+":
            return text(a) + text(b)
        if op == "==":
            return int(text(a) == text(b))
        if op == "!=":
            return int(text(a) != text(b))
    a, b = num(a), num(b)
    ints = isinstance(a, int) and isinstance(b, int)
    ops = {
        "+": lambda: a + b, "-": lambda: a - b, "*": lambda: a * b,
        "/": lambda: (int(a / b) if ints else a / b) if b else 0,
        "%": lambda: int(a) % int(b) if b else 0,
        "==": lambda: int(a == b), "!=": lambda: int(a != b), "<": lambda: int(a < b), ">": lambda: int(a > b),
        "<=": lambda: int(a <= b), ">=": lambda: int(a >= b),
        "&&": lambda: int(bool(a) and bool(b)), "||": lambda: int(bool(a) or bool(b)),
        "&": lambda: int(a) & int(b), "|": lambda: int(a) | int(b), "^": lambda: int(a) ^ int(b),
    }
    return ops.get(op, lambda: 0)()


def num(v):
    if isinstance(v, str):
        try:
            return int(v)
        except ValueError:
            try:
                return float(v)
            except ValueError:
                return 0
    return v


def text(v):
    if isinstance(v, float) and v == int(v):
        return str(int(v))
    return str(v)


def truthy(v):
    return v != "" if isinstance(v, str) else v != 0


class Path:
    def __init__(self, script, ip, vars, frames=(), selection=None):
        self.script, self.ip, self.vars, self.frames = script, ip, dict(vars), list(frames)
        self.selection = dict(selection or {"labels": [], "enabled": []})

    def fork(self):
        return Path(self.script, self.ip, self.vars, self.frames, self.selection)

    def state(self):
        return (self.script, self.ip, tuple(self.frames), frozenset(self.vars.items()))


class Explorer:
    def __init__(self, story, max_states):
        self.story = story
        self.max_states = max_states
        self.seen = set()
        self.reached_scripts = set()
        self.reached_labels = set()
        self.lines = 0
        self.endings = Counter()
        self.movies = Counter()
        self.problems = defaultdict(set)
        self.globals_written = defaultdict(set)  # ending -> global flags it sets
        self.states = 0

    def run(self, start_vars):
        start = self.story.labels[self.story.index["start"]]
        stack = [Path(start[0], start[1], start_vars)]
        while stack and self.states < self.max_states:
            path = stack.pop()
            stack.extend(self.step_until_choice(path))
        return not stack

    def step_until_choice(self, p):
        """Runs a path until it forks (returns the forks) or ends (returns [])."""
        silent = 0
        labels_at = self.labels_by_position()
        while True:
            script = self.story.scripts.get(p.script)
            if script is None:
                self.problems["missing script"].add(p.script)
                return []
            ops = script["ops"]
            if p.ip >= len(ops):
                self.problems["ran off the end"].add(script["path"])
                return []
            self.reached_scripts.add(p.script)
            for name in labels_at.get((p.script, p.ip), ()):
                self.reached_labels.add(name)
            op = ops[p.ip]
            here = p.ip
            p.ip += 1
            kind = op["op"]
            silent += 1
            if silent > 50_000:
                self.problems["loop without text"].add(f"{script['path']}:{here}")
                return []
            if kind == "say":
                self.lines += 1
                silent = 0
            elif kind == "if" or kind == "elif":
                if "q" in op and not truthy(evaluate(op["q"], p.vars)):
                    p.ip = op["j"]
            elif kind == "jmp":
                p.ip = op["j"]
            elif kind == "go":
                label = text(evaluate(op["l"], p.vars))
                if label == "SCENARIO_TITLE":
                    self.end(p, "title")
                    return []
                target = self.story.labels.get(label)
                if target is None:
                    self.problems["unknown label"].add(f"{script['path']}:{here} {label!r}")
                    return []
                p.script, p.ip = target
            elif kind == "let":
                self.assign(p, op)
            elif kind == "ret":
                if not p.frames:
                    self.end(p, "return to title")
                    return []
                p.script, p.ip = p.frames.pop()
            elif kind == "end":
                self.end(p, "END")
                return []
            elif kind == "call":
                result = self.call(p, op, script, here)
                if result is not None:
                    return result

    def labels_by_position(self):
        if not hasattr(self, "_labels_at"):
            self._labels_at = defaultdict(list)
            for name, (s, ip) in self.story.labels.items():
                self._labels_at[(s, ip)].append(name)
        return self._labels_at

    def assign(self, p, op):
        target = op["v"]
        name = target["v"]
        k = key(name, [int(num(evaluate(x, p.vars))) for x in target.get("i", [])])
        value = evaluate(op["e"], p.vars)
        old = p.vars.get(k, "" if name.startswith("$") else 0)
        o = op.get("o", "=")
        if o == "+=":
            value = text(old) + text(value) if name.startswith("$") else num(old) + num(value)
        elif o == "-=":
            value = num(old) - num(value)
        elif o == "*=":
            value = num(old) * num(value)
        elif o == "/=":
            value = int(num(old) / num(value)) if num(value) else 0
        p.vars[k] = text(value) if name.startswith("$") else value

    def call(self, p, op, script, here):
        name = op.get("m") or text(evaluate(op["e"], p.vars))
        args = [evaluate(a, p.vars) if a is not None else None for a in op.get("a", [])]
        arg = lambda n, d=0: args[n - 1] if n <= len(args) and args[n - 1] is not None else d
        if name in self.story.labels:
            p.frames.append((p.script, p.ip))
            for n, value in enumerate(args, start=1):
                if value is None:
                    continue
                p.vars[key("@50", [n])] = value
                p.vars[key("@51", [n])] = value
                p.vars[key("$52", [n])] = text(value)
            p.script, p.ip = self.story.labels[name]
            return None
        if name == "ES.SEL.GO":
            p.selection["labels"] = [text(arg(n, "")) for n in range(1, 11)]
        elif name == "ES.SEL.E":
            p.selection["enabled"] = [truthy(arg(n, 1)) for n in range(1, 11)]
        elif name == "ES.SEL.SET":
            captions = [text(arg(n, "")) for n in range(1, 11)]
            enabled = p.selection["enabled"] or [True] * 10
            options = [i for i, c in enumerate(captions) if c.strip(" “”\"") and (i >= len(enabled) or enabled[i])]
            if not options:
                self.problems["menu with no option"].add(f"{script['path']}:{here}")
                return []
            labels = p.selection["labels"]
            forks = []
            for i in options:
                if i >= len(labels) or not labels[i]:
                    self.problems["option without a label"].add(f"{script['path']}:{here} option {i + 1}")
                    continue
                f = p.fork()
                f.vars["$1110"] = labels[i]
                f.selection = {"labels": [], "enabled": []}
                forks.append(f)
            return self.unseen(forks)
        elif name == "ES.CSEL.SET":
            options = [n for n in range(1, 6) if num(p.vars.get(key("@1136", [8000 + n]), 0)) == 1]
            if not options:
                self.problems["heroine selection with no option"].add(f"{script['path']}:{here}")
                return []
            forks = []
            for n in options:
                f = p.fork()
                f.vars[key("@1143", [93, 5])] = n
                forks.append(f)
            return self.unseen(forks)
        elif name == "es.RND":
            low, high = int(num(arg(1))), int(num(arg(2)))
            p.vars[key("@54", [1])] = random.randint(min(low, high), max(low, high))
        elif name == "es.CM.SD.SET":
            p.vars["@1085"] = arg(1)
        elif name == "es.CM.MD.SET":
            p.vars["@1086"] = arg(1)
        elif name in SCENE_END_CALLS:
            self.endings[f"{script['path']}:{here}"] += 1
            if num(p.vars.get("@1182", 0)):
                # A replay ends here and returns to its list (the app's StoryEngine.returnToTitle).
                self.replay_ended = True
                return []
            self.globals_written[f"{script['path']}:{here}"].update(
                (k, v) for k, v in p.vars.items() if k.startswith("@1134(") or k.startswith("$1135("))
        elif name == "es.MOVIEPLAY.SET":
            self.movies[text(arg(1))] += 1
        return None

    def unseen(self, forks):
        out = []
        for f in forks:
            s = f.state()
            if s in self.seen:
                continue
            self.seen.add(s)
            self.states += 1
            out.append(f)
        return out

    def end(self, p, how):
        pass


def main():
    argv = sys.argv[1:]
    max_states = 200_000
    if "--max-states" in argv:
        i = argv.index("--max-states")
        max_states = int(argv[i + 1])
        del argv[i:i + 2]
    args = argv
    if not args:
        sys.exit(__doc__)
    story = Story(args[0])
    start_vars = {"@1078": CURRENT, "@1076": RELATIVE, "@1085": 128, "@1086": 0x808080}
    if "--replays" in sys.argv:
        # Every scene replay and staff comment, as the extras start them (@1182 = 1 or 2):
        # each must end through ES.SCENARIO.END, which returns to its list.
        targets = [(r["label"], 1) for r in story.index["replays"]] + [(l, 2) for l in story.index["staff"]]
        failed = 0
        for label, flag in targets:
            explorer = Explorer(story, 20_000)
            explorer.replay_ended = False
            vars = dict(start_vars, **{"@1182": flag})
            s, ip = story.labels[label]
            stack = [Path(s, ip, vars)]
            while stack and explorer.states < explorer.max_states:
                stack.extend(explorer.step_until_choice(stack.pop()))
            if explorer.problems or not explorer.replay_ended:
                failed += 1
                print(f"{label}: ended={explorer.replay_ended} lines={explorer.lines} "
                      f"problems={ {k: sorted(map(str, v))[:3] for k, v in explorer.problems.items()} }")
        print(f"{len(targets) - failed} of {len(targets)} replays end cleanly")
        return
    explorer = Explorer(story, max_states)
    if len(args) > 1:
        start_vars.update(json.load(open(args[1])))
        complete = explorer.run(start_vars)
    else:
        # New player: replay with the global flags each set of endings leaves behind,
        # until no new global flags appear (the routes that unlock after clearing others).
        known = {}
        complete = True
        for round_ in range(6):
            vars = dict(start_vars)
            vars.update(known)
            complete = explorer.run(vars) and complete
            gained = {k: v for flags in explorer.globals_written.values() for k, v in flags}
            new = {k: v for k, v in gained.items() if known.get(k) != v}
            print(f"playthrough {round_ + 1}: {len(explorer.reached_scripts)} scripts reached, "
                  f"{len(new)} new global flags")
            if not new:
                break
            known.update(new)

    all_scripts = set(story.scripts)
    unreached = sorted(story.scripts[s]["path"] for s in all_scripts - explorer.reached_scripts)
    print(f"\nstates explored: {explorer.states}{'' if complete else ' (stopped at the limit)'}")
    print(f"text lines executed: {explorer.lines}")
    print(f"scripts reached: {len(explorer.reached_scripts)} of {len(all_scripts)}")
    print(f"labels reached: {len(explorer.reached_labels)} of {len(story.labels)}")
    print(f"scene ends reached: {len(explorer.endings)}")
    print(f"movies played: {dict(explorer.movies)}")
    for kind, items in explorer.problems.items():
        print(f"\nPROBLEM {kind}: {len(items)}")
        for item in sorted(map(str, items))[:15]:
            print("   ", item)
    print(f"\nunreached scripts ({len(unreached)}):")
    for path in unreached:
        print("   ", path)
    missed = sorted(set(story.labels) - explorer.reached_labels)
    print(f"\nunreached labels ({len(missed)}):")
    for name in missed:
        s, ip = story.labels[name]
        print(f"    {name}  ({story.scripts[s]['path'].split('/')[-1]}:{ip})")


if __name__ == "__main__":
    main()
