#!/usr/bin/env bash
# Fetches the two tools `cargo xtask package` needs on Linux into one folder, each pinned by sha256:
#   - an LGPL FFmpeg shared build (BtbN, n9.0) -> $SQ_DEPS/ffmpeg-linux  (what SQ_FFMPEG names)
#   - appimagetool 1.9.1                       -> $SQ_DEPS/appimagetool-x86_64.AppImage (what SQ_APPIMAGETOOL names)
# $SQ_DEPS defaults to ~/.cache/sequence-studio/deps. Prints the two exports at the end. Safe to run again.
set -euo pipefail
deps="${SQ_DEPS:-$HOME/.cache/sequence-studio/deps}"
mkdir -p "$deps"

FFMPEG_URL="https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/autobuild-2026-11-10-12-39/ffmpeg-n9.0.2-48-gd4070a14ce-linux64-lgpl-shared-9.0.tar.xz"
FFMPEG_SHA="6c212a1b914c84dc1e201fddeb9dea7304ef0748884722d4bb13311416c36ebb"
TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage"
TOOL_SHA="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"

fetch() { # url sha dest
  if [ -f "$3" ] && [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ]; then return; fi
  curl -fsSL --retry 3 -o "$3.part" "$1"
  [ "$(sha256sum "$3.part" | cut -d' ' -f1)" = "$2" ] || { echo "sha256 mismatch for $1" >&2; rm -f "$3.part"; exit 1; }
  mv "$3.part" "$3"
}

fetch "$FFMPEG_URL" "$FFMPEG_SHA" "$deps/ffmpeg-linux.tar.xz"
if [ ! -d "$deps/ffmpeg-linux/lib" ]; then
  rm -rf "$deps/ffmpeg-linux" "$deps/.ffmpeg-extract"
  mkdir "$deps/.ffmpeg-extract"
  tar -xf "$deps/ffmpeg-linux.tar.xz" -C "$deps/.ffmpeg-extract" --strip-components=1
  mv "$deps/.ffmpeg-extract" "$deps/ffmpeg-linux"
fi
fetch "$TOOL_URL" "$TOOL_SHA" "$deps/appimagetool-x86_64.AppImage"
chmod +x "$deps/appimagetool-x86_64.AppImage"
echo "export SQ_FFMPEG=$deps/ffmpeg-linux"
echo "export SQ_APPIMAGETOOL=$deps/appimagetool-x86_64.AppImage"
