#!/bin/sh
# Convert the game's movies (MPEG-1 program streams named *.ypf) to H.264/AAC MP4
# for AVPlayer on visionOS, with tools/transcode_movie.swift (AVFoundation; the
# built-in avconvert stalls on several of these files).
# Usage: tools/convert_movies.sh original/Euphoria/pac visionOS/Euphoria/Resources/Game
set -eu
PAC=${1:?pac folder}
GAME=${2:?game folder}
HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="$HERE/../.build/transcode_movie"
mkdir -p "$(dirname "$TOOL")" "$GAME/movie"
swiftc -O "$HERE/transcode_movie.swift" -o "$TOOL"
TMP=$(mktemp -d)
for name in OP fake normal_bad normal_good special_bad true_end; do
  out="$GAME/movie/$(echo "$name" | tr '[:upper:]' '[:lower:]').mp4"
  [ -f "$out" ] && continue
  cp "$PAC/$name.ypf" "$TMP/$name.mpg"
  "$TOOL" "$TMP/$name.mpg" "$out"
  rm "$TMP/$name.mpg"
done
rmdir "$TMP"
