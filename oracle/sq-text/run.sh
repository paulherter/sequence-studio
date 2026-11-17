#!/bin/bash
# Rebuilds the Swift dumper for LinearCanvas.swift and regenerates golden/linear-canvas.tsv. Needs Xcode (plain swiftc, no SwiftPM).
# Usage: oracle/sq-text/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../Packages/SQText/Sources/SQText"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
gen="$here/swift-dump/out/gen"; mkdir -p "$gen" "$here/golden"
# GlyphRaster.swift: only CoverageRasterizer (the rest needs the font reader).
{ echo "import Foundation"; awk '/^public struct CoverageRasterizer/{on=1} on' "$src/GlyphRaster.swift"; } > "$gen/CoverageRasterizer.swift"
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -o "$here/swift-dump/out/dump" "$here/swift-dump/main.swift" "$here/swift-dump/stubs.swift" "$gen/CoverageRasterizer.swift" "$src/PortableRaster/LinearCanvas.swift"
"$here/swift-dump/out/dump" > "$here/golden/linear-canvas.tsv"
wc -l "$here/golden/linear-canvas.tsv"
# SfntVariations.swift: variable-font tables of the bundled Inter.
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -o "$here/swift-dump/out/vdump" "$here/swift-dump/variations/main.swift" "$here/swift-dump/variations/stubs.swift" "$src/SfntVariations.swift"
"$here/swift-dump/out/vdump" "$src/Resources/Fonts/Inter-VariableFont_opsz,wght.ttf" > "$here/golden/font-variations.tsv"
wc -l "$here/golden/font-variations.tsv"
