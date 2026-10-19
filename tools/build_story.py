#!/usr/bin/env python3
"""Convert Euphoria's compiled story scripts into the native app's story format.

Usage: build_story.py YSBIN_DIR EXTRACTED_DIR OUT_DIR

Reads the compiled scripts directly (via yuris.py) and writes, under OUT_DIR:
  story/NNNNN.json  one file per story script: {"path", "ops"}
  story/index.json  labels, BGM names, character names, and the asset index

Only the scenario scripts (userscript/) and story-level helpers are kept. The
ERIS framework (eris/, puserdefine/, puserdesign/) is not: the app implements
the framework calls the story makes (MAC.BG, es.SND, es.SP.*, ...) natively.

Ops (JSON objects keyed by "op"):
  say   n (shown name), c (character), t (text) or e (expression), w (waits for a click)
  call  m (macro name), a (positional arguments, index 0 = first parameter)
  if    q (condition), j (instruction to jump to when false)
  elif  q (optional condition), j (next branch or end when false)
  jmp   j (end of the if: reached at the end of a taken branch)
  go    l (label expression)
  let   v (variable expression), o (operator), e (value)
  wait  ms
  ret, end, nop, x (unsupported command, kept by name)

Expressions: numbers and strings are literal JSON values. {"v": "@12", "i": [..]}
reads a variable (with array indices), {"r": "@12"} references one, and
{"o": "+", "a": [l, r]} applies an operator (unary: neg, str, int).
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yuris  # noqa: E402

STORY_HELPERS = ("userdefine\\新規ﾃｷｽﾄ文書.txt",)
PARAM = re.compile(r"^P(?:INT|FLT|STR)(\d*)$")


def ast(raw):
    stack, marker = [], object()
    for op, value in yuris.tokens(raw):
        if op in "BWIL":
            stack.append(value)
        elif op == "F":
            stack.append(value)
        elif op == "M":
            stack.append(value[1:-1] if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'" else value)
        elif op == "H":
            stack.append({"v": f"{value[0]}{value[1]}"})
        elif op == "v":
            stack.append({"r": f"{value[0]}{value[1]}"})
        elif op == "V":
            stack.append(marker)
            stack.append({"v": f"{value[0]}{value[1]}"})
        elif op == ",":
            pass
        elif op == ")":
            items = []
            while stack[-1] is not marker:
                items.append(stack.pop())
            stack.pop()
            items.reverse()
            var = dict(items[0])
            var["i"] = items[1:]
            stack.append(var)
        elif op in yuris.UNARY_OPS:
            name = {"R": "neg", "s": "str", "i": "int"}[op]
            stack.append({"o": name, "a": [stack.pop()]})
        elif op in yuris.BINARY_OPS:
            b, a = stack.pop(), stack.pop()
            stack.append({"o": yuris.BINARY_OPS[op], "a": [a, b]})
        else:
            raise ValueError(f"unknown expression token {op!r}")
    if len(stack) != 1:
        raise ValueError(f"expression left {len(stack)} values")
    return stack[0]


def clean_text(text):
    return text.replace("==", "—")


def parse_say(text):
    """Split 'Name／Who: “line”' into shown name, character and text."""
    match = re.match(r"^([^“”:]{1,48}): (?=[“‘(（])", text)
    if not match:
        return None, None, clean_text(text)
    label = match.group(1)
    shown, _, who = label.partition("／")
    return shown, who or shown, clean_text(text[match.end():])


def convert(script, labels):
    code = script.instructions
    ops = []
    for ip, ins in enumerate(code):
        cmd = ins["cmd"]
        values = [a for a in ins["args"] if a["type"] != 0]
        if cmd == "_":
            lit = yuris.literal(values[0]["raw"])
            waits = ip + 1 < len(code) and code[ip + 1]["cmd"] == "RETURNCODE"
            if isinstance(lit, str):
                shown, who, text = parse_say(lit)
                op = {"op": "say", "t": text, "w": waits}
                if shown:
                    op["n"], op["c"] = shown, who
            else:
                op = {"op": "say", "e": ast(values[0]["raw"]), "w": waits}
            ops.append(op)
        elif cmd == "GOSUB":
            name = yuris.literal(values[0]["raw"])
            args = []
            for v in values[1:]:
                index = int(PARAM.match(v["name"]).group(1) or 1)
                while len(args) < index:
                    args.append(None)
                args[index - 1] = ast(v["raw"])
            if isinstance(name, str):
                ops.append({"op": "call", "m": name, "a": args})
            else:
                ops.append({"op": "call", "e": ast(values[0]["raw"]), "a": args})
        elif cmd == "GO":
            ops.append({"op": "go", "l": ast(values[0]["raw"])})
        elif cmd == "IF":
            ops.append({"op": "if", "q": ast(values[0]["raw"]), "j": None})
        elif cmd == "ELSE":
            op = {"op": "elif", "j": None}
            if values:
                op["q"] = ast(values[0]["raw"])
            ops.append(op)
        elif cmd == "IFBLEND":
            ops.append({"op": "jmp", "j": None})
        elif cmd == "IFEND":
            ops.append({"op": "nop"})
        elif cmd in ("LET", "INT", "STR", "FLT"):
            if len(values) != 2:
                ops.append({"op": "x", "cmd": cmd})
                continue
            operator = yuris.LET_OPS.get(values[0]["op"] or values[1]["op"], "=")
            ops.append({"op": "let", "v": ast(values[0]["raw"]), "o": operator, "e": ast(values[1]["raw"])})
        elif cmd == "WAIT":
            frames = next((yuris.literal(v["raw"]) for v in values if v["name"] == "FRAME"), None)
            ms = next((yuris.literal(v["raw"]) for v in values if v["name"] == "TIME"), None)
            ops.append({"op": "wait", "ms": ms if ms is not None else round((frames or 1) * 1000 / 60)})
        elif cmd == "RETURNCODE":
            ops.append({"op": "nop"})
        elif cmd == "RETURN":
            ops.append({"op": "ret"})
        elif cmd == "END":
            ops.append({"op": "end"})
        else:
            ops.append({"op": "x", "cmd": cmd})
    return ops


def link_with_markers(ops, code):
    """Fill in jump targets for if / elif / jmp from the IF ... IFEND structure."""
    stack = []
    for ip, ins in enumerate(code):
        cmd = ins["cmd"]
        if cmd == "IF":
            stack.append({"pending": [ip], "blends": []})
        elif cmd == "IFBLEND":
            stack[-1]["blends"].append(ip)
        elif cmd == "ELSE":
            for p in stack[-1]["pending"]:
                ops[p]["j"] = ip
            stack[-1]["pending"] = [ip]
        elif cmd == "IFEND":
            block = stack.pop()
            for p in block["pending"]:
                ops[p]["j"] = ip
            for b in block["blends"]:
                ops[b]["j"] = ip
    if stack:
        raise ValueError("unterminated IF")


def asset_index(extracted):
    """Map lowercase names (without extension) to paths under the game folder."""
    index = {}
    roots = [("cg", os.path.join(extracted, "cg", "cg")), ("voice", os.path.join(extracted, "vo", "voice")),
             ("se", os.path.join(extracted, "se", "se")), ("bgm", os.path.join(extracted, "sn", "bgm"))]
    for prefix, root in roots:
        for folder, _, files in os.walk(root):
            for name in files:
                rel = os.path.relpath(os.path.join(folder, name), root).replace(os.sep, "/")
                key = os.path.splitext(name)[0].lower()
                # Gallery thumbnails share the full pictures' names: reach them by path only.
                thumbnail = rel.startswith("thumb_")
                path = f"{prefix}/{rel}"
                if path.endswith(".ogg"):
                    # tools/convert_audio.sh turns the Ogg audio into AAC for visionOS.
                    path = path[:-4] + ".m4a"
                if not thumbnail:
                    index.setdefault(key, path)
                # Also index by folder-relative path ("bg/red", "tip/danmen/x").
                index.setdefault(os.path.splitext(rel)[0].lower(), path)
    # Movies (tools/convert_movies.sh), by the scripts' names ("pac/op.ypf").
    for name in MOVIES:
        index[f"pac/{name}.ypf"] = f"movie/{name}.mp4"
    # Interface art, by path only ("sys/title/back"): its names repeat the story's.
    sys_root = os.path.join(extracted, "cgsys", "cgsys")
    for folder, _, files in os.walk(sys_root):
        for name in files:
            rel = os.path.relpath(os.path.join(folder, name), sys_root).replace(os.sep, "/")
            index["sys/" + os.path.splitext(rel)[0].lower()] = f"sys/{rel}"
    return index


def definitions(src, commands, scripts, wanted):
    """Collect es.BGMDEF and es.CHAR.NAME arguments from the definition scripts."""
    found = {name: [] for name in wanted}
    for index, path in scripts.items():
        ybn = os.path.join(src, f"yst{index:05d}.ybn")
        if "userdefine" not in path or not os.path.exists(ybn):
            continue
        script = yuris.Script(ybn, commands)
        for ins in script.instructions:
            if ins["cmd"] != "GOSUB":
                continue
            values = [a for a in ins["args"] if a["type"] != 0]
            name = yuris.literal(values[0]["raw"])
            if name in found:
                found[name].append([yuris.literal(v["raw"]) for v in values[1:]])
    return found


MOVIES = ["op", "fake", "normal_bad", "normal_good", "special_bad", "true_end"]


def extras(src, commands, scripts):
    """The CG gallery sets, scene replays and music room tracks, in the original's order.

    Gallery: es.CGMODE.CG.SET adds a picture, THUMB.SET names the set's
    thumbnail, DEF.SET closes the set. Replays: THUMB.SET, LABEL.SET, DEF.SET.
    """
    gallery, replays, music = [], [], []
    pictures, thumb, label = [], None, None
    for index, path in scripts.items():
        ybn = os.path.join(src, f"yst{index:05d}.ybn")
        if "userdefine" not in path or not os.path.exists(ybn):  # userdefine and puserdefine
            continue
        for ins in yuris.Script(ybn, commands).instructions:
            if ins["cmd"] != "GOSUB":
                continue
            values = [a for a in ins["args"] if a["type"] != 0]
            name = yuris.literal(values[0]["raw"])
            arg = yuris.literal(values[1]["raw"]) if len(values) > 1 else None
            if name == "es.CGMODE.CG.SET":
                pictures.append(arg.lower())
            elif name in ("es.CGMODE.THUMB.SET", "es.RPMODE.THUMB.SET"):
                thumb = arg.lower()
            elif name == "es.CGMODE.DEF.SET":
                gallery.append({"thumb": thumb, "pictures": pictures})
                pictures, thumb = [], None
            elif name == "es.RPMODE.LABEL.SET":
                label = arg
            elif name == "es.RPMODE.DEF.SET":
                replays.append({"thumb": thumb, "label": label})
                thumb, label = None, None
            elif name == "ES.BGMMODE.FILE.SET":
                music.append(arg.lower())
    return gallery, replays, music


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, extracted, out = sys.argv[1:]
    commands = yuris.read_commands(os.path.join(src, "ysc.ybn"))
    scripts = yuris.read_script_list(os.path.join(src, "yst_list.ybn"))
    labels = yuris.read_labels(os.path.join(src, "ysl.ybn"))

    story_dir = os.path.join(out, "story")
    os.makedirs(story_dir, exist_ok=True)
    kept = {}
    for index, path in sorted(scripts.items()):
        rel = path.replace("data\\script\\", "")
        if not (rel.startswith("userscript\\") or rel in STORY_HELPERS):
            continue
        script = yuris.Script(os.path.join(src, f"yst{index:05d}.ybn"), commands)
        ops = convert(script, labels)
        link_with_markers(ops, script.instructions)
        with open(os.path.join(story_dir, f"{index:05d}.json"), "w", encoding="utf-8") as f:
            json.dump({"path": rel.replace("\\", "/"), "ops": ops}, f, ensure_ascii=False, separators=(",", ":"))
        kept[index] = rel

    defs = definitions(src, commands, scripts, ["es.BGMDEF", "es.CHAR.NAME"])
    gallery, replays, music = extras(src, commands, scripts)
    index = {
        "scripts": {str(k): v.replace("\\", "/") for k, v in kept.items()},
        "labels": {l["name"]: [l["script"], l["ip"]] for l in labels if l["script"] in kept},
        "bgm": {a[0].lower(): a[1].lower() for a in defs["es.BGMDEF"]},
        "names": {a[0].rstrip(": "): a[1] for a in defs["es.CHAR.NAME"]},
        "assets": asset_index(extracted),
        "start": "SCENARIO_MAIN",
        "gallery": gallery,
        "replays": replays,
        "music": music,
        "staff": sorted(l["name"] for l in labels if l["name"].startswith("STAFF_") and l["script"] in kept),
    }
    with open(os.path.join(story_dir, "index.json"), "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False, separators=(",", ":"))
    ops = sum(len(json.load(open(os.path.join(story_dir, f"{k:05d}.json")))["ops"]) for k in kept)
    print(f"{len(kept)} story scripts, {ops} ops, {len(index['labels'])} labels, {len(index['assets'])} asset keys")


if __name__ == "__main__":
    main()
