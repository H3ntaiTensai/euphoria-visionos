#!/usr/bin/env python3
"""Import the original game's saves (save/*.sd) into the visionOS app.

Usage: import_saves.py ORIGINAL_SAVE_DIR STORY_DIR OUT_DIR

  ORIGINAL_SAVE_DIR  the PC game's save folder (save00001.sd ..., gsd.sd)
  STORY_DIR          the converted story (visionOS/Euphoria/Resources/Game/story)
  OUT_DIR            a local folder; copy its contents to the app's Documents
                     folder on the headset (see README › Importing PC saves)

Writes Saves/slotN.json for saveNNNNN.sd (save10001 becomes the quick save,
save3000N slot 110+N) and globals.json from gsd.sd.

Original save format (YSSD): a 1024-entry table of offsets, one per data number
(DNO, table index + 1). Each block is u32 sequence, u32 flags, u32 packed size,
u32 size, then zlib data. A variable's data is u32 type (1 int, 3 string),
u32 dimension count, u32 per dimension, u32 byte length, then 64-bit integers
or u32-length-prefixed Shift-JIS strings.

ERIS saves (eris/es_saveload): DNO 5 @1136 story flags, 6 $1137 names, 50 the
backlog (newest first), 909 the save caption (speaker and current line).
gsd.sd DNO 3 is @1134, the global flags. The original resumes from an engine
position recorded at the start of the scene; this importer instead finds the
saved line in the converted story and has the app replay the scene silently up
to it (SaveData.catchUpFrom), which rebuilds the background, sprites and music.
"""
import glob
import json
import os
import re
import struct
import sys
import zlib

APPLE_EPOCH = 978307200  # 2001-01-01, the reference date of Swift's Date coding
CHOICE_CALLS = {"ES.SEL.SET", "ES.CSEL.SET"}
labels_index = {}


def blocks(path):
    data = open(path, "rb").read()
    magic, _version, _count, slots = struct.unpack_from("<4sIII", data)
    if magic != b"YSSD":
        raise ValueError(f"{path}: not a YU-RIS save")
    offsets = struct.unpack_from(f"<{slots}I", data, 16)
    out = {}
    for index, offset in enumerate(offsets):
        if offset:
            packed = struct.unpack_from("<I", data, offset + 8)[0]
            out[index + 1] = zlib.decompress(data[offset + 16 : offset + 16 + packed])
    return out


def variable(blob):
    """Decode a saved variable into (dimensions, flat list of values)."""
    kind, ndims = struct.unpack_from("<II", blob)
    dims = list(struct.unpack_from(f"<{ndims}I", blob, 8))
    p = 8 + 4 * ndims + 4
    count = 1
    for d in dims:
        count *= d
    values = []
    if kind == 3:
        for _ in range(count):
            length = struct.unpack_from("<I", blob, p)[0]
            values.append(blob[p + 4 : p + 4 + length].decode("cp932", "replace"))
            p += 4 + length
    else:
        values = list(struct.unpack_from(f"<{count}q", blob, p))
    return dims, values


def flat_vars(name, blob):
    dims, values = variable(blob)
    out = {}
    for i, value in enumerate(values):
        if value in (0, ""):
            continue
        index, rest = [], i
        for d in reversed(dims[1:]):
            index.insert(0, rest % d)
            rest //= d
        index.insert(0, rest)
        out[f"{name}({','.join(map(str, index))})"] = value
    return out


def normalize(text):
    text = text.replace("—", "==")
    text = re.sub(r"[“”„\"]", '"', text)
    text = re.sub(r"[‘’']", "'", text)
    return re.sub(r"\s+", " ", text).strip()


def load_story(story_dir):
    index = json.load(open(os.path.join(story_dir, "index.json"), encoding="utf-8"))
    scripts = {}
    for key in index["scripts"]:
        scripts[int(key)] = json.load(open(os.path.join(story_dir, f"{int(key):05d}.json"), encoding="utf-8"))
    lines = {}
    for sid, script in scripts.items():
        for ip, op in enumerate(script["ops"]):
            if op["op"] == "say" and "t" in op:
                lines.setdefault(normalize(op["t"]), []).append((sid, ip))
    labels_by_script = {}
    for name, (sid, ip) in index["labels"].items():
        labels_by_script.setdefault(sid, []).append(ip)
    global labels_index
    labels_index = {name: tuple(v) for name, v in index["labels"].items()}
    return scripts, lines, labels_by_script


def locate_prefix(text, scripts, lines):
    """A line the backlog stored cut short: the unique story line starting with it."""
    key = normalize(text)
    if len(key) < 6:
        return None
    matches = [where for line, places in lines.items() if line.startswith(key) for where in places]
    return matches[0] if len(matches) == 1 else None


def previous_says(script, ip, count):
    out = []
    for p in range(ip - 1, -1, -1):
        op = script["ops"][p]
        if op["op"] == "say" and "t" in op:
            out.append(normalize(op["t"]))
            if len(out) == count:
                break
    return out


def locate(saved_text, backlog, scripts, lines):
    candidates = lines.get(normalize(saved_text), [])
    if len(candidates) <= 1:
        return candidates[0] if candidates else None
    # Several lines read the same: prefer the one whose preceding lines match the backlog.
    def score(candidate):
        sid, ip = candidate
        before = previous_says(scripts[sid], ip, len(backlog))
        return sum(1 for a, b in zip(before, backlog) if a == b)
    return max(candidates, key=score)


def catch_up_start(script, labels, ip):
    """The first label after the last choice before the line (or the script start)."""
    ops = script["ops"]
    last_choice = -1
    for p in range(ip):
        op = ops[p]
        if op["op"] == "call" and op.get("m") in CHOICE_CALLS:
            last_choice = p
    candidates = [l for l in labels if last_choice < l <= ip]
    return min(candidates) if candidates else ip


def next_menu(scripts, labels_index, sid, ip):
    """The next choice menu after a line, following jumps to other scripts."""
    return (scan_menu(scripts, labels_index, sid, ip, resolve=False)
            or scan_menu(scripts, labels_index, sid, ip, resolve=True))


def scan_menu(scripts, labels_index, sid, ip, resolve, steps=400):
    strings = {}
    while steps > 0:
        ops = scripts[sid]["ops"]
        ip += 1
        if ip >= len(ops):
            return None
        op = ops[ip]
        steps -= 1
        if op["op"] == "call" and op.get("m") in CHOICE_CALLS:
            return sid, ip
        if op["op"] == "let" and isinstance(op.get("e"), str) and op["e"]:
            strings[op["v"].get("v")] = op["e"]
        if op["op"] == "go":
            label = op.get("l")
            if isinstance(label, dict):
                label = strings.get(label.get("v")) if resolve else None
            if label in labels_index:
                sid, ip = labels_index[label]
                ip -= 1
    return None


SCENE_CALLS = ("MAC.BG", "MAC.EV", "MAC.BG_C", "MAC.EV_C", "MAC.EV_G_C", "MAC.EV_G_O_C", "MAC.EV_G_A_C")


def tween(value):
    return {"from": value, "to": value, "start": 0, "duration": 0, "curve": 0}


def background_stage(script, ip):
    """The picture on screen at a line: the last background or event CG shown before it."""
    for p in range(ip, -1, -1):
        op = script["ops"][p]
        if op["op"] != "call" or not op.get("a"):
            continue
        image = None
        if op.get("m") in SCENE_CALLS and isinstance(op["a"][0], str):
            image = op["a"][0]
        elif op.get("m") == "es.SP.CG.SET" and len(op["a"]) > 1 and isinstance(op["a"][1], str) \
                and op["a"][1].lower().startswith(("bg/", "ev/")):
            image = op["a"][1]
        if image:
            sprite = {"id": "BG", "image": image, "fade": tween(1), "alpha": tween(256),
                      "x": tween(0), "y": tween(0), "z": tween(200), "order": -1_000_000}
            return {"sprites": {"BG": sprite}, "nextOrder": 0}
    return {"sprites": {}, "nextOrder": 0}


def history(b):
    """The backlog as History lines, oldest first, without the line being resumed."""
    if 50 not in b:
        return []
    texts = variable(b[50])[1]
    names = variable(b[51])[1] if 51 in b else [""] * len(texts)
    out = []
    for text, name in list(zip(texts, names))[1:]:
        if text and not text.startswith("< Select >"):
            out.append({k: v for k, v in {"name": name, "who": name, "text": text}.items() if v})
    return list(reversed(out))[-100:]


def import_save(path, scripts, lines, labels):
    b = blocks(path)
    caption = variable(b[909])[1][0] if 909 in b else ""
    backlog = [t for t in variable(b[50])[1] if t] if 50 in b else []
    if not backlog:
        return None, "no backlog"
    # The backlog's first entry is the last line read, unwrapped (the caption is
    # word-wrapped). A save made at a menu has the menu in its caption instead.
    at_menu = caption.startswith(("\u201c", "\u201d", "\"", "< Select >"))
    # The backlog also records menu captions; match on the last line of story text.
    read = [t for t in backlog if not t.startswith(("< Select >", "\u201c", "\u201d"))]
    found = locate(read[0], [normalize(t) for t in read[1:]], scripts, lines) if read else None
    if not found and not read and at_menu:
        # A save at the very first menu, before any line was read.
        start = labels_index["00_op_01"]
        found = (start[0], start[1])
    if not found and read:
        found = locate_prefix(read[0], scripts, lines)
    if not found:
        return None, f"line not found: {read[0][:60] if read else ''!r}"
    sid, ip = found
    if at_menu:
        menu = next_menu(scripts, labels_index, sid, ip)
        if menu is None:
            return None, f"no menu after {read[0][:40]!r}"
        sid, ip = menu
    values = {"@1078": -99_999_999, "@1076": -99_999_998}
    values.update(flat_vars("@1136", b[5]))
    values.update(flat_vars("$1137", b[6]))
    mtime = os.path.getmtime(path)
    op = scripts[sid]["ops"][ip]
    said = scripts[found[0]]["ops"][found[1]]
    shown = op if op["op"] == "say" else said if said["op"] == "say" else None
    save = {
        "script": sid, "ip": ip, "frames": [], "vars": {"values": values},
        "stage": background_stage(scripts[sid], ip), "selection": {"labels": [], "enabled": []},
        "history": history(b),
        "music": {}, "date": mtime - APPLE_EPOCH,
        "line": {k: v for k, v in {"name": shown.get("n"), "who": shown.get("c"), "text": shown["t"]}.items() if v}
        if shown else None,
        "catchUpFrom": catch_up_start(scripts[sid], labels.get(sid, []), ip),
    }
    where = "menu" if at_menu else "line"
    return save, f"{scripts[sid]['path'].split('/')[-1]} {where} {ip}: {backlog[0][:50]}"


def unlocks(g, index):
    """Gallery and replay unlocks from gsd.sd, for the app's Documents/progress.json.

    DNO 11 holds the CG gallery's flags: per set, a slot for its thumbnail, then
    one per picture (es.CGMODE.DEF.SET). DNO 12 holds the replays': per scene, a
    thumbnail slot, then its label's slot (es.RPMODE.DEF.SET). Both start at 1.
    """
    seen, replays = [], []
    if 11 in g:
        flags = variable(g[11])[1]
        slot = 0
        for gallery_set in index["gallery"]:
            slot += 1
            for picture in gallery_set["pictures"]:
                slot += 1
                if slot < len(flags) and flags[slot]:
                    seen.append(picture)
    if 12 in g:
        flags = variable(g[12])[1]
        slot = 0
        for replay in index["replays"]:
            slot += 2
            if slot < len(flags) and flags[slot]:
                replays.append(replay["label"])
    # DNO 14: the music room's tracks, one flag per track from 1.
    tracks = []
    if 14 in g:
        flags = variable(g[14])[1]
        tracks = [name for i, name in enumerate(index["music"], start=1) if i < len(flags) and flags[i]]
    return {"seenCG": sorted(set(seen)), "replays": replays, "tracks": tracks, "movies": [], "endings": []}


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    save_dir, story_dir, out_dir = sys.argv[1:]
    scripts, lines, labels = load_story(story_dir)
    os.makedirs(os.path.join(out_dir, "Saves"), exist_ok=True)

    gsd = os.path.join(save_dir, "gsd.sd")
    if os.path.exists(gsd):
        g = blocks(gsd)
        globals_ = flat_vars("@1134", g[3])
        json.dump(globals_, open(os.path.join(out_dir, "globals.json"), "w"))
        print(f"globals: {len(globals_)} flags from gsd.sd")
        progress = unlocks(g, json.load(open(os.path.join(story_dir, "index.json"), encoding="utf-8")))
        json.dump(progress, open(os.path.join(out_dir, "progress.json"), "w"))
        print(f"unlocks: {len(progress['seenCG'])} CGs, {len(progress['replays'])} scene replays, "
              f"{len(progress['tracks'])} music tracks")

    imported = 0
    for path in sorted(glob.glob(os.path.join(save_dir, "save*.sd"))):
        number = int(re.search(r"save(\d+)", path).group(1))
        slot = "quick" if number == 10001 else f"slot{110 + number - 30000}" if number > 30000 else f"slot{number}"
        try:
            save, info = import_save(path, scripts, lines, labels)
        except Exception as exc:  # keep going; report the save
            save, info = None, f"error: {exc}"
        print(f"{os.path.basename(path)} -> {slot}: {info}")
        if save:
            json.dump(save, open(os.path.join(out_dir, "Saves", f"{slot}.json"), "w"), ensure_ascii=False)
            imported += 1
    print(f"imported {imported} saves")


if __name__ == "__main__":
    main()
