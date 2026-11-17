#!/bin/bash
# Rebuilds the Swift dumper of the export core from the real source files (plain swiftc, Foundation only) and regenerates
# golden/core.tsv. Needs Xcode. Stubs in swift-dump/main.swift: GainMath (verbatim from SQAudioFX Gain.swift, whose file
# needs SQCore), the audio source protocols and LoudnessNormalization (verbatim from FrameSource.swift / ExportSettings.swift,
# which need SQCore), ExportQueue.sanitize (verbatim from ExportQueue.swift, an actor).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
pk="$here/../../../Packages"
ex="$pk/SQExport/Sources/SQExport"
fx="$pk/SQAudioFX/Sources/SQAudioFX"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
mkdir -p "$here/swift-dump/out" "$here/golden"
# The real files, without their `import SQ...` lines (the stubs in main.swift replace what those modules gave them).
rm -rf "$here/swift-dump/out/src"; mkdir -p "$here/swift-dump/out/src"
files=()
for f in "$fx/Loudness.swift" "$fx/Limiter.swift" "$ex/LoudnessNormalizer.swift" "$ex/GIFPalette.swift" "$ex/FrameStillPixels.swift" \
  "$ex/FrameStillFormat.swift" "$ex/HDRDelivery.swift" "$ex/ExportProgressTracker.swift" "$ex/FrameOutputNaming.swift"; do
  sed '/^import SQ/d' "$f" > "$here/swift-dump/out/src/$(basename "$f")"; files+=("$here/swift-dump/out/src/$(basename "$f")")
done
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -swift-version 5 -o "$here/swift-dump/out/dump" "$here/swift-dump/main.swift" "${files[@]}"
"$here/swift-dump/out/dump" > "$here/golden/core.tsv"
wc -l "$here/golden/core.tsv"
