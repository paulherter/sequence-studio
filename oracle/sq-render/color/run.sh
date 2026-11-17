#!/bin/bash
# Rebuilds the Swift dumper and regenerates golden/color.tsv for crates/sq-render/src/color (float dumps, f32 bit patterns).
# Plain swiftc from Xcode 27.1, no SwiftPM: the whole SQCore source folder plus the pure SQRender Color files (their
# `import SQCore` / SQGPU lines are stripped, the GPU pass lines of ColorPipeline are cut) in one module.
# Usage: oracle/sq-render/color/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../.."
core="$root/Packages/SQCore/Sources/SQCore"
color="$root/Packages/SQRender/Sources/SQRender/Color"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
out="$here/swift-dump/out"; gen="$out/gen"; rm -rf "$gen"; mkdir -p "$gen" "$here/golden"
pure=(AutoTone ClipColorPipeline ColorGraphStages ColorPipeline ColorStages CubeLUT "CubeLUT+3DL" "CubeLUT+VLT" Gamut HDRConform
      LookThumbnail OutputTarget Rec709Output ToneMapping TransferFunctions "TransferFunctions+Vendor" WhiteBalanceSolver)
files=()
for f in "${pure[@]}"; do
  grep -v '^import SQCore\|^import SQGPU' "$color/$f.swift" | grep -v 'gpuPasses' > "$gen/$f.swift"
  files+=("$gen/$f.swift")
done
nice -n 15 "$SWIFTC" -sdk "$SDK" -Onone -swift-version 5 -o "$out/dump" "$here/swift-dump/main.swift" "$here/swift-dump/stubs.swift" \
  "${files[@]}" "$core"/*.swift
"$out/dump" > "$here/golden/color.tsv"
wc -l "$here/golden/color.tsv"
