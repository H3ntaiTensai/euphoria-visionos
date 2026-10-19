#!/usr/bin/env python3
"""Extract YU-RIS YPF archives (tested on version 474, Euphoria).

Index layout per entry (little-endian), starting at 0x20:
  u32 name hash
  u8  name length, bitwise NOT, then swapped through NAME_LENGTH_SWAPS
  N   name bytes, each bitwise NOT, Shift-JIS, backslash separators
  u8  file type
  u8  compressed (1 = zlib)
  u32 unpacked size
  u32 packed size
  u32 data offset
  u32 checksum of the packed data

Usage: ypf_extract.py ARCHIVE OUT_DIR [--list]
"""
import os
import struct
import sys
import zlib


# Pairs of name lengths the engine swaps after the NOT. Observed in Euphoria's
# archives by matching coded lengths against actual name boundaries.
NAME_LENGTH_SWAPS = {}
for a, b in [(12, 16), (13, 19), (17, 25), (21, 27), (28, 30), (32, 35)]:
    NAME_LENGTH_SWAPS[a] = b
    NAME_LENGTH_SWAPS[b] = a


def _plausible_name(raw):
    try:
        name = raw.decode("cp932")
    except UnicodeDecodeError:
        return None
    if not name or any(ord(ch) < 0x20 or 0xE000 <= ord(ch) <= 0xF8FF for ch in name):
        return None
    if "." not in name.rsplit("\\", 1)[-1]:
        return None
    return name


def read_index(path):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        head = f.read(0x20)
        sig, version, count, index_size = struct.unpack_from("<4sIII", head)
        if sig != b"YPF\0":
            raise ValueError(f"{path}: not a YPF archive")
        index = f.read(index_size)
    entries = []
    p = 0
    for _ in range(count):
        coded_len = (~index[p + 4]) & 0xFF
        coded_len = NAME_LENGTH_SWAPS.get(coded_len, coded_len)
        # Try the direct length first, then any other length that parses cleanly.
        for n in [coded_len] + [k for k in range(1, 256) if k != coded_len]:
            q = p + 5 + n
            if q + 18 > len(index):
                continue
            name = _plausible_name(bytes((~b) & 0xFF for b in index[p + 5 : q]))
            if name is None:
                continue
            ftype, comp, usize, psize, offset, check = struct.unpack_from("<BBIIII", index, q)
            if comp > 1 or offset + psize > size:
                continue
            entries.append(dict(name=name, type=ftype, comp=comp, usize=usize,
                                psize=psize, offset=offset, check=check))
            p = q + 18
            break
        else:
            raise ValueError(f"{path}: cannot parse index entry at 0x{p + 0x20:x}")
    return version, entries


def extract(path, out_dir):
    version, entries = read_index(path)
    with open(path, "rb") as f:
        for e in entries:
            f.seek(e["offset"])
            blob = f.read(e["psize"])
            if e["comp"]:
                blob = zlib.decompress(blob)
            if len(blob) != e["usize"]:
                print(f"warning: {e['name']}: size {len(blob)} != {e['usize']}", file=sys.stderr)
            dest = os.path.join(out_dir, *e["name"].split("\\"))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as o:
                o.write(blob)
    return version, len(entries)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    archive, out_dir = sys.argv[1], sys.argv[2]
    if "--list" in sys.argv:
        version, entries = read_index(archive)
        print(f"version {version}, {len(entries)} entries")
        for e in entries:
            print(f"{e['usize']:>10} {e['type']:>2} {e['name']}")
        return
    version, n = extract(archive, out_dir)
    print(f"{archive}: version {version}, extracted {n} files")


if __name__ == "__main__":
    main()
