#!/bin/bash
# Rebuilds the Swift dumper and regenerates golden/mascot.tsv. Needs Xcode (plain swiftc, no SwiftPM).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../Packages/SQUIKit/Sources/SQUIKit"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
gen="$here/swift-dump/out/gen"; mkdir -p "$gen" "$here/golden"
# SQMascotModel.swift: drop `shared` (it reads the SwiftPM bundle, which a plain swiftc build does not have).
awk '/public static let shared: SQMascotLibrary = \{/{skip=1} skip&&/^    \}\(\)/{skip=0; next} !skip' "$src/Mascot/SQMascotModel.swift" | sed '1i\
import CoreGraphics
' > "$gen/SQMascotModel.swift"
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -o "$here/swift-dump/out/dump" "$here/swift-dump/main.swift" "$gen/SQMascotModel.swift" "$src/Mascot/SQMascotPlayer.swift"
"$here/swift-dump/out/dump" "$src/Resources/Mascot/pip-anim.json" > "$here/golden/mascot.tsv"
wc -l "$here/golden/mascot.tsv"
