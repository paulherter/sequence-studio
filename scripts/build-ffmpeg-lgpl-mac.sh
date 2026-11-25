#!/bin/bash
# Builds the LGPL FFmpeg a Mac release needs (Homebrew's has x264/x265 = GPL and `cargo xtask package` refuses it).
# Same source as the Windows installer's BtbN master build (N-128100-gceb466cbcd, 2026-10-26).
# Output: $SQ_FFMPEG_OUT (default ~/Documents/SQ-Rust-Ffmpeg-LGPL) with bin/ lib/ include/ BUILDINFO. Use it as SQ_FFMPEG.
# Needs the Homebrew libs dav1d opus lame libvpx svt-av1 nasm pkgconf; installs nothing. Codecs whose lib is missing are dropped.
set -euo pipefail

COMMIT=ceb466cbcd7f2366d2dc738cda02e47f0ac59f7d
SHA256=195e2aa3ec75a1bda09c29b6ea49c7d5998b8e2c3ea7b2503687a04b31077c17
URL="https://github.com/FFmpeg/FFmpeg/archive/$COMMIT.tar.gz"
OUT="${SQ_FFMPEG_OUT:-$HOME/Documents/SQ-Rust-Ffmpeg-LGPL}"
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PKG_CONFIG_PATH="$BREW/lib/pkgconfig:$BREW/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$BREW/bin:$PATH"
# The default CLT SDK (27.0) can fail to link with this clang ("tapi error"); fall back to a 26.x SDK that links.
if ! (cd "${TMPDIR:-/tmp}" && echo 'int main(){return 0;}' | cc -x c - -o /dev/null 2>/dev/null); then
  for s in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    [ -d "$s" ] && { export SDKROOT="$s"; break; }
  done
fi

free_gb=$(df -g "$HOME" | awk 'NR==2{print $4}')
[ "$free_gb" -ge 12 ] || { echo "only ${free_gb} GB free, need 12" >&2; exit 1; }

. "$(dirname "$0")/lib-safe-delete.sh" || exit 1
WORK="$(safe_tmpdir sq-ffmpeg)"
trap 'safe_delete "$WORK" "${TMPDIR:-/tmp}" 2>/dev/null || true' EXIT

curl -fsSL -o "$WORK/ffmpeg.tgz" "$URL"
got=$(shasum -a 256 "$WORK/ffmpeg.tgz" | awk '{print $1}')
[ "$got" = "$SHA256" ] || { echo "sha256 $got is not the pinned $SHA256" >&2; exit 1; }
mkdir "$WORK/src" && tar xzf "$WORK/ffmpeg.tgz" -C "$WORK/src" --strip-components=1

flags=(--prefix="$OUT" --enable-shared --disable-static --disable-gpl --disable-nonfree --enable-version3
  --disable-doc --disable-debug --enable-videotoolbox --enable-audiotoolbox --enable-pic)
for pair in dav1d:libdav1d opus:libopus libmp3lame:libmp3lame vpx:libvpx SvtAv1Enc:libsvtav1; do
  pc=${pair%%:*}; opt=${pair##*:}
  [ "$pc" = libmp3lame ] && { [ -e "$BREW/lib/libmp3lame.dylib" ] && flags+=(--enable-libmp3lame); continue; }
  if pkg-config --exists "$pc"; then flags+=(--enable-"$opt"); else echo "missing $pc: dropping $opt" >&2; fi
done
flags+=(--extra-cflags="-I$BREW/include" --extra-ldflags="-L$BREW/lib")

cd "$WORK/src"
./configure "${flags[@]}" >"$WORK/configure.log" 2>&1 || { tail -30 "$WORK/configure.log" >&2; exit 1; }
nice -n 15 make -j4 >"$WORK/make.log" 2>&1 || { tail -30 "$WORK/make.log" >&2; exit 1; }
make install >/dev/null 2>&1
{
  echo "FFmpeg commit $COMMIT (BtbN N-128100-gceb466cbcd), built $(date -u +%FT%TZ)"
  echo "configure: ./configure ${flags[*]}"
} >"$OUT/BUILDINFO"
echo "installed $OUT"
