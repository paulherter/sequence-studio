#!/bin/bash
# Builds the Gyroflow engine (Vendor/sqgyro, Rust: gyroflow_core behind a C API) as build/gyro/libsqgyro.dylib.
# The app loads it at runtime (SQGyro package, dlopen); without it the Gyroflow method stays grayed with a reason.
# Never commit the output (build/ is ignored).
# Usage: scripts/build-gyro.sh               the app's archs (project.yml ARCHS: arm64; + x86_64 once the app lists it)
#        scripts/build-gyro.sh --universal   arm64 + x86_64, lipo'd, whatever the app builds
#        scripts/build-gyro.sh --check CLIP  also builds + runs the C smoke test on CLIP (open, recompute, warp)
#        scripts/build-gyro.sh --if-needed   only when the dylib is missing or older than the Rust sources; silent
#                                            no-op when cargo is not installed (used by scripts/build.sh)
# Needs rustup (user install in ~/.cargo) with targets aarch64-apple-darwin (+ x86_64-apple-darwin for --universal),
# and network on the first build (crates, gyroflow git rev, lens-profile download by gyroflow_core's build.rs).
cd "$(dirname "$0")/.." || exit 1
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
CRATE=Vendor/sqgyro
OUT=build/gyro
UNIVERSAL=0; CHECK=""; IF_NEEDED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --universal) UNIVERSAL=1 ;;
    --check) CHECK="$2"; shift ;;
    --if-needed) IF_NEEDED=1 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
  shift
done
# The library must carry every arch the app does (an Intel Mac loads the x86_64 slice of a universal app).
grep -E '^[[:space:]]*ARCHS:' project.yml | grep -q x86_64 && UNIVERSAL=1

if [ ! -x "$CARGO" ]; then
  [ $IF_NEEDED = 1 ] && exit 0
  echo "FAILED: cargo not found ($CARGO). Install rustup (https://rustup.rs), then:"
  echo "  rustup target add aarch64-apple-darwin x86_64-apple-darwin"
  exit 1
fi
if [ $IF_NEEDED = 1 ] && [ -f "$OUT/libsqgyro.dylib" ] && \
   { [ $UNIVERSAL = 0 ] || lipo -archs "$OUT/libsqgyro.dylib" 2>/dev/null | grep -q x86_64; } && \
   [ -z "$(find "$CRATE/src" "$CRATE/Cargo.toml" "$CRATE/Cargo.lock" -newer "$OUT/libsqgyro.dylib" -print -quit)" ]; then
  exit 0
fi

mkdir -p "$OUT"
# One cargo target dir for every checkout and worktree (SQ_CARGO_TARGET_DIR overrides): the crates.io and gyroflow
# dependencies, the bulk of the 80+ s cold build and 1.3 GB per worktree, are compiled once; cargo locks the dir, so
# concurrent builds queue instead of colliding. Only the sqgyro crate itself rebuilds per path.
export CARGO_TARGET_DIR="${SQ_CARGO_TARGET_DIR:-$HOME/.cache/sq-gyro-target}"
TARGETS=(aarch64-apple-darwin)
[ $UNIVERSAL = 1 ] && TARGETS+=(x86_64-apple-darwin)
start=$(date +%s)
# Pin the lens-profile database: gyroflow_core's build.rs downloads ".../releases/latest/..." only when the file is
# missing, so the pinned release (LENS_PROFILES_TAG) is placed there first. Bump the tag on purpose.
LENS_PROFILES_TAG=v41
"$CARGO" fetch --locked --manifest-path "$CRATE/Cargo.toml" >/dev/null 2>&1
for d in "$HOME"/.cargo/git/checkouts/gyroflow-*/*/; do
  [ -d "$d/src/core" ] || continue
  f="$d/resources/camera_presets/profiles.cbor.gz"
  if [ ! -f "$f.$LENS_PROFILES_TAG" ]; then
    mkdir -p "$(dirname "$f")"
    curl -fsL "https://github.com/gyroflow/lens_profiles/releases/download/$LENS_PROFILES_TAG/profiles.cbor.gz" -o "$f.tmp" \
      && mv "$f.tmp" "$f" && touch "$f.$LENS_PROFILES_TAG"
    rm -f "$f.tmp"
  fi
done
for t in "${TARGETS[@]}"; do
  MACOSX_DEPLOYMENT_TARGET=14.0 "$CARGO" build --release --locked --manifest-path "$CRATE/Cargo.toml" --target "$t" \
    > "$OUT/cargo-$t.log" 2>&1 || { grep -E "^error" -A6 "$OUT/cargo-$t.log" | head -40; echo "FAILED (log: $OUT/cargo-$t.log)"; exit 1; }
done
secs=$(( $(date +%s) - start ))
LIBS=()
for t in "${TARGETS[@]}"; do LIBS+=("$CARGO_TARGET_DIR/$t/release/libsqgyro.dylib"); done
rm -f "$OUT/libsqgyro.dylib"
if [ ${#LIBS[@]} -gt 1 ]; then lipo -create "${LIBS[@]}" -output "$OUT/libsqgyro.dylib" || exit 1
else cp "${LIBS[0]}" "$OUT/libsqgyro.dylib"; fi
install_name_tool -id @rpath/libsqgyro.dylib "$OUT/libsqgyro.dylib" 2>/dev/null
codesign --force -s - "$OUT/libsqgyro.dylib" 2>/dev/null
cp "$CRATE/include/sqgyro.h" "$OUT/"
size=$(stat -f %z "$OUT/libsqgyro.dylib")
echo "OK: $OUT/libsqgyro.dylib ($(lipo -archs "$OUT/libsqgyro.dylib"), $((size / 1024 / 1024)) MB, cargo ${secs} s)"

if [ -n "$CHECK" ]; then
  xcrun --sdk macosx clang -O2 -I"$CRATE/include" "$CRATE/tests/smoke.c" -L"$OUT" -lsqgyro -Wl,-rpath,"$(pwd)/$OUT" -o "$OUT/smoke" || exit 1
  "$OUT/smoke" "$CHECK"
fi
