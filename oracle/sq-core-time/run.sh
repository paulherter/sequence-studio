#!/bin/bash
# Rebuilds the Swift dumper and regenerates golden/ops.tsv and golden/text-tables.tsv. Needs Xcode (plain swiftc, no SwiftPM).
# Usage: oracle/sq-core-time/run.sh [seed] [count]     defaults: 20261105 10000
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
core="$here/../../Packages/SQCore/Sources/SQCore"
seed="${1:-20261105}"; count="${2:-10000}"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
gen="$here/swift-dump/out/gen"; mkdir -p "$gen" "$here/golden"
# TextSearch.swift: only the enum (the file also extends Timeline, which would pull in the whole model).
awk '/^extension Timeline/{on=0} BEGIN{on=1} on' "$core/TextSearch.swift" > "$gen/TextSearch.swift"
files=(); for f in Time FrameRate CMXTimecode EasingSpring EaseNames KeyframesEasing KeyframesSpatial KeyframesModel WordSegmentation StepStatus; do files+=("$core/$f.swift"); done
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -o "$here/swift-dump/out/dump" "$here/swift-dump/main.swift" "$here/swift-dump/stubs.swift" "$gen/TextSearch.swift" "${files[@]}"
"$here/swift-dump/out/dump" ops "$seed" "$count" > "$here/golden/ops.tsv"
"$here/swift-dump/out/dump" text -AppleLocale en_US -AppleLanguages "(en)" > "$here/golden/text-tables.tsv"
wc -l "$here/golden/ops.tsv" "$here/golden/text-tables.tsv"
