#!/usr/bin/env python3
"""Link the extracted game assets into the app's resource folder.

Usage: package_assets.py EXTRACTED_DIR GAME_DIR

Files are hard-linked (same volume) so the 2.5 GB of art and audio is not
duplicated on disk; the folder layout matches the asset index written by
build_story.py: cg/, voice/, se/, bgm/, sys/.
"""
import os
import shutil
import sys

LAYOUT = {"cg": "cg/cg", "voice": "vo/voice", "se": "se/se", "bgm": "sn/bgm", "sys": "cgsys/cgsys"}


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    extracted, game = sys.argv[1:]
    linked = 0
    for dest, src in LAYOUT.items():
        root = os.path.join(extracted, src)
        for folder, _, files in os.walk(root):
            out_folder = os.path.join(game, dest, os.path.relpath(folder, root))
            os.makedirs(out_folder, exist_ok=True)
            for name in files:
                target = os.path.join(out_folder, name)
                if os.path.exists(target):
                    continue
                try:
                    os.link(os.path.join(folder, name), target)
                except OSError:
                    shutil.copy2(os.path.join(folder, name), target)
                linked += 1
    print(f"linked {linked} files into {game}")


if __name__ == "__main__":
    main()
