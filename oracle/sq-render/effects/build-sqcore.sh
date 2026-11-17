#!/bin/bash
# Builds the pure SQCore sources (no dependencies) into a throwaway module for the effects dumper (plain swiftc).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/swift-dump/out"; mkdir -p "$out"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -wmo -parse-as-library -module-name SQCore -emit-module -emit-module-path "$out/SQCore.swiftmodule" \
  -emit-library -o "$out/libSQCore.dylib" $(find "$here/../../../Packages/SQCore/Sources/SQCore" -name '*.swift')
