#!/usr/bin/env python3
"""Decompile Euphoria's compiled YU-RIS scripts into readable source and JSON.

Usage: ybn_decompile.py YSBIN_DIR OUT_DIR

Writes, under OUT_DIR:
  source/<original path>.txt  YU-RIS-style source, one file per compiled script
  json/<index>.json           every instruction with decoded arguments
  labels.json                 label name -> script index and instruction
  scripts.json                script index -> original source path

Variable names are not stored in the compiled form; variables print as their
type sigil and index (@12 int, $12 string).
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yuris  # noqa: E402

INDENT_OPEN = {"IF", "LOOP"}
INDENT_CLOSE = {"IFEND", "LOOPEND"}


def format_instruction(ins):
    cmd, args = ins["cmd"], ins["args"]
    values = [a for a in args if a["type"] != 0]
    if cmd == "_":
        return yuris.literal(values[0]["raw"]) if values else ""
    if cmd == "RETURNCODE":
        return None
    if cmd == "LET" and len(values) == 2:
        op = yuris.LET_OPS.get(values[0]["op"] or values[1]["op"], "?=")
        return f"{yuris.expression(values[0]['raw'])} {op} {yuris.expression(values[1]['raw'])}"
    if cmd in ("IF", "LOOP") and values and values[0]["slot"] == 0 and cmd == "IF":
        return f"IF[{yuris.expression(values[0]['raw'])}]"
    if cmd in ("G_INT", "G_STR", "G_FLT", "S_INT", "S_STR", "S_FLT", "INT", "STR", "FLT") and values:
        parts = [yuris.expression(v["raw"]) for v in values]
        return f"{cmd}[{' = '.join(parts)}]"
    if not values:
        return cmd
    parts = []
    for v in values:
        parts.append(f"{v['name']}={yuris.expression(v['raw'])}")
    return f"{cmd}[{' '.join(parts)}]"


def instruction_json(ins):
    out = dict(cmd=ins["cmd"], line=ins["line"])
    args = []
    for a in ins["args"]:
        if a["type"] == 0:
            args.append(dict(target=a["target"]))
            continue
        item = dict(name=a["name"], expr=yuris.expression(a["raw"]))
        lit = yuris.literal(a["raw"])
        if lit is not None:
            item["value"] = lit
        if a["op"]:
            item["op"] = yuris.LET_OPS.get(a["op"], a["op"])
        args.append(item)
    if args:
        out["args"] = args
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out = sys.argv[1:]
    commands = yuris.read_commands(os.path.join(src, "ysc.ybn"))
    scripts = yuris.read_script_list(os.path.join(src, "yst_list.ybn"))
    labels = yuris.read_labels(os.path.join(src, "ysl.ybn"))

    labels_at = {}
    for lab in labels:
        labels_at.setdefault((lab["script"], lab["ip"]), []).append(lab["name"])

    os.makedirs(os.path.join(out, "json"), exist_ok=True)
    errors = 0
    for index, path in sorted(scripts.items()):
        ybn = os.path.join(src, f"yst{index:05d}.ybn")
        if not os.path.exists(ybn):
            continue
        try:
            script = yuris.Script(ybn, commands)
        except Exception as exc:  # report and keep going
            print(f"{index} {path}: {exc}", file=sys.stderr)
            errors += 1
            continue

        rel = path.replace("\\", "/")
        if rel.startswith("data/script/"):
            rel = rel[len("data/script/"):]
        dest = os.path.join(out, "source", os.path.splitext(rel)[0] + ".txt")
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        lines = [f"// script {index}: {path}"]
        depth = 0
        for ip, ins in enumerate(script.instructions):
            for name in labels_at.get((index, ip), []):
                lines.append(f"#={name}")
            if ins["cmd"] in INDENT_CLOSE or ins["cmd"] == "ELSE":
                depth = max(0, depth - 1)
            try:
                text = format_instruction(ins)
            except Exception as exc:
                text = f"// {ins['cmd']}: undecoded ({exc})"
                errors += 1
            if text is not None:
                lines.append("    " * depth + text)
            if ins["cmd"] in INDENT_OPEN or ins["cmd"] == "ELSE":
                depth += 1
        with open(dest, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

        with open(os.path.join(out, "json", f"{index:05d}.json"), "w", encoding="utf-8") as f:
            json.dump(dict(index=index, path=path,
                           labels={n: ip for (s, ip), ns in labels_at.items() if s == index for n in ns},
                           code=[instruction_json(i) for i in script.instructions]),
                      f, ensure_ascii=False, indent=1)

    with open(os.path.join(out, "scripts.json"), "w", encoding="utf-8") as f:
        json.dump(scripts, f, ensure_ascii=False, indent=1)
    with open(os.path.join(out, "labels.json"), "w", encoding="utf-8") as f:
        json.dump(labels, f, ensure_ascii=False, indent=1)
    print(f"decompiled {len(scripts)} scripts, {errors} errors")


if __name__ == "__main__":
    main()
