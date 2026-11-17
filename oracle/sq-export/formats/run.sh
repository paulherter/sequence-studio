#!/bin/bash
# Regenerates golden/ from the real Swift writers (EDL, FCPXML, XMEML, OTIO, SRT, VTT, ITT, MarkerCSV, YouTubeChapters).
# Builds a scratch package outside the repo: symlinks to the writer sources, path dependencies on SQCore and SQText.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
pk="${SQ_SWIFT_PACKAGES:?set SQ_SWIFT_PACKAGES to the Packages folder of the Swift reference tree}"
scratch="${TMPDIR:-/tmp}/sq-x2-dump"
rm -rf "$scratch"; mkdir -p "$scratch/Sources/Dump"
for f in EDLWriter FCPXMLWriter XMEMLWriter OTIOWriter SRTWriter VTTWriter ITTWriter MarkerCSV YouTubeChapters; do
  ln -s "$pk/SQExport/Sources/SQExport/$f.swift" "$scratch/Sources/Dump/$f.swift"
done
cp "$here/swift-dump/main.swift" "$scratch/Sources/Dump/main.swift"
cat > "$scratch/Package.swift" <<PKG
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Dump", platforms: [.macOS(.v26)],
  dependencies: [.package(path: "$pk/SQCore"), .package(path: "$pk/SQText")],
  targets: [.executableTarget(name: "Dump", dependencies: ["SQCore", "SQText"], swiftSettings: [.swiftLanguageMode(.v5)])])
PKG
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
mkdir -p "$here/golden"; rm -f "$here"/golden/*
(cd "$scratch" && nice -n 15 /usr/bin/swift run -c release Dump "$here/golden")
ls "$here/golden" | wc -l
