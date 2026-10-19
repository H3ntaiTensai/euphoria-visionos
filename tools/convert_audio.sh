#!/bin/sh
# Convert the game's Ogg Vorbis audio to AAC (.m4a) in place under GAME_DIR.
# visionOS cannot decode Ogg Vorbis; macOS's afconvert can read it.
# Usage: tools/convert_audio.sh visionOS/Euphoria/Resources/Game
set -eu
GAME=${1:?game folder}
find "$GAME/voice" "$GAME/se" "$GAME/bgm" -name '*.ogg' -print0 |
  xargs -0 -P 8 -n 1 sh -c '
    out="${0%.ogg}.m4a"
    case "$0" in */bgm/*) rate=160000 ;; *) rate=64000 ;; esac
    afconvert -f m4af -d aac -b "$rate" "$0" "$out" && rm "$0"
  '
echo "remaining ogg: $(find "$GAME" -name '*.ogg' | wc -l)"
