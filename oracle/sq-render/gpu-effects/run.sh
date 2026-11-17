#!/bin/bash
# Rebuilds the Swift dumper from the real plan sources (plain swiftc) and regenerates golden/gpu-effects.tsv. Needs Xcode.
# Uses the SQCore build of ../effects (build-sqcore.sh runs there when missing). The Swift files are compiled as they are
# (EffectChainPlan, FilmLookPlan, MaskData, OutlineFilters, GaussianBlur, UltraKey), except that `import SQGPU*` is dropped;
# `Compositor.Uniforms` is a stub with the fields these files touch, and the Metal-only `Accelerate` branch of MaskData is used.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fx="$here/../effects"
src="$here/../../../Packages/SQRender/Sources/SQRender"
out="$here/out"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
[ -f "$fx/swift-dump/out/libSQCore.dylib" ] || "$fx/build-sqcore.sh"
mkdir -p "$out/src" "$here/golden"
for f in Effects/EffectChainPlan Effects/FilmLookPlan Effects/MaskData Effects/OutlineFilters Effects/GaussianBlur Effects/UltraKey; do
  grep -v '^import SQGPU' "$src/$f.swift" > "$out/src/$(basename "$f").swift"
done
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -I "$fx/swift-dump/out" -L "$fx/swift-dump/out" -lSQCore -Xlinker -rpath -Xlinker "$fx/swift-dump/out" \
  -o "$out/dump" "$here/main.swift" "$here/Stubs.swift" "$out"/src/*.swift
"$out/dump" "$here/golden/gpu-effects.tsv"
