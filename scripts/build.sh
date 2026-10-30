#!/bin/bash
# Builds the app; prints errors only. Full log: build/build.log
# Usage: scripts/build.sh [Debug|Release]   (Release goes to build/DerivedData-Release)
cd "$(dirname "$0")/.." || exit 1
CONFIG="${1:-Debug}"
DD=build/DerivedData
[ "$CONFIG" = Debug ] || DD="build/DerivedData-$CONFIG"
mkdir -p build
touch build/.metadata_never_index                      # Spotlight must not index build output
# Regenerate when the project is missing or any app source / project.yml is newer (new files after merges).
PBX=SequenceStudio.xcodeproj/project.pbxproj
if [ ! -f "$PBX" ] || [ project.yml -nt "$PBX" ] || [ -n "$(find App -name '*.swift' -newer "$PBX" -print -quit)" ]; then
  xcodegen generate --quiet || exit 1
fi
# Gyroflow engine (Rust): rebuilt only when its sources changed; skipped silently when cargo is not installed.
scripts/build-gyro.sh --if-needed || exit 1
# One of the machine-wide build slots, niced (scripts/lib-slots.sh): parallel agent builds must not starve running tests.
. scripts/lib-slots.sh
trap sq_release_all_slots EXIT
sq_acquire_slot "$sq_build_slot_dir" "${SQ_BUILD_SLOTS:-3}" build
# Debug builds are what the maintainer plays video in: unoptimized Swift made playback drop frames (live meter, matte math, decode
# glue all 10-100x slower). Optimize every module (app and packages) unless SQ_DEBUG_OPT=0; symbols and the debug dylib stay.
OPT=()
[ "$CONFIG" = Debug ] && [ "${SQ_DEBUG_OPT:-1}" = 1 ] && OPT=(SWIFT_OPTIMIZATION_LEVEL=-O GCC_OPTIMIZATION_LEVEL=s)
nice -n "${SQ_BUILD_NICE:-10}" xcodebuild -project SequenceStudio.xcodeproj -scheme SequenceStudio -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" -jobs "$(sq_build_jobs)" COMPILER_INDEX_STORE_ENABLE=NO "${OPT[@]}" build \
  > build/build.log 2>&1
status=$?
sq_release_all_slots
if [ $status -ne 0 ]; then
  grep -E "error:|fatal error:|BUILD FAILED" build/build.log | sort -u | head -40
  echo "FAILED (full log: build/build.log)"
  exit $status
fi
echo "OK"
