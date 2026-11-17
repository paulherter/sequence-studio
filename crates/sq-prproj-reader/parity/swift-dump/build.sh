#!/bin/bash
# Builds the two Swift dumpers into ./out: dump-swift-apple (Compression framework, as the Mac app) and
# dump-swift-portable (SQCore RawInflate, as Windows). Uses plain swiftc; no package build.
set -euo pipefail
SWIFTC="${SWIFTC:-$(/usr/bin/xcrun --find swiftc)}"  # Xcode toolchain; the swiftly one does not match the SDK
SDK="${SDK:-/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk}"
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../../../Packages/SQPremiereImport/Sources/SQPremiereImport"
core="$here/../../../../Packages/SQCore/Sources/SQCore/RawInflate.swift"
gen="$here/out/gen"; mkdir -p "$gen"
# PRImportError, PRGzip, PRNode: from "public enum PRImportError" up to the PRObjectTable doc comment.
{ printf 'import Foundation\n#if SQ_APPLE_INFLATE\nimport Compression\n#endif\n'; awk '/^public enum PRImportError/{on=1} /^\/\/\/ The flat top-level object list/{on=0} on' "$src/PRContainer.swift"; } \
  | sed 's/#if canImport(Compression)/#if SQ_APPLE_INFLATE/' > "$gen/Container.swift"
sed '/^import SQCore/d' "$src/PRInflate.swift" > "$gen/Inflate.swift"
cp "$core" "$gen/RawInflate.swift"
files=("$gen/Container.swift" "$gen/Inflate.swift" "$gen/RawInflate.swift" "$src/PRZip.swift" "$src/PRFastXML.swift")
# Both builds use main.swift as the entry point.

nice -n 15 "$SWIFTC" -sdk "$SDK" -O -DSQ_APPLE_INFLATE -o "$here/out/dump-swift-apple" "$here/main.swift" "${files[@]}"
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -o "$here/out/dump-swift-portable" "$here/main.swift" "${files[@]}"
