#!/bin/bash
# Rebuilds the Swift dumpers for the portable SQUIKit files and regenerates golden/*.txt. Needs Xcode (plain swiftc, no SwiftPM).
# Usage: oracle/sq-uikit/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../Packages/SQUIKit/Sources/SQUIKit"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
out="$here/swift-dump/out"; mkdir -p "$out" "$here/golden"
# DesignTokens.swift: every SQTokens value, printed as group.NAME=value.
mkdir -p "$out/tokens" && cp "$here/swift-dump/design-tokens-main.swift" "$out/tokens/main.swift"
nice -n 15 "$SWIFTC" -sdk "$SDK" -o "$out/tokens-dump" "$out/tokens/main.swift" "$src/DesignTokens.swift"
"$out/tokens-dump" > "$here/golden/design-tokens.txt"
wc -l "$here/golden/design-tokens.txt"
