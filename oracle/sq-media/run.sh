#!/bin/bash
# Rebuilds the Swift Vorbis dumper from the real VorbisDecoder.swift and regenerates golden/vorbis.tsv. Needs Xcode (plain swiftc).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../Packages/SQMedia/Sources/SQMedia"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
mkdir -p "$here/swift-dump/out" "$here/golden"
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -o "$here/swift-dump/out/dump" "$here/swift-dump/main.swift" "$src/WebM/VorbisDecoder.swift"
"$here/swift-dump/out/dump" > "$here/golden/vorbis.tsv"
wc -l "$here/golden/vorbis.tsv"
