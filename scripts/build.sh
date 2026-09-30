#!/bin/bash
# Builds the app; prints errors only. Full log: build/build.log
cd "$(dirname "$0")/.." || exit 1
mkdir -p build
[ -d SequenceStudio.xcodeproj ] || xcodegen generate --quiet || exit 1
xcodebuild -project SequenceStudio.xcodeproj -scheme SequenceStudio -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData build \
  > build/build.log 2>&1
status=$?
if [ $status -ne 0 ]; then
  grep -E "error:|fatal error:|BUILD FAILED" build/build.log | sort -u | head -40
  echo "FAILED (full log: build/build.log)"
  exit $status
fi
echo "OK"
