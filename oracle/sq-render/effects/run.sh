#!/bin/bash
# Rebuilds the Swift dumper from the real Effects sources (plain swiftc) and regenerates golden/effects.tsv. Needs Xcode.
# SQCore is built once into swift-dump/out by build-sqcore.sh (runs here when missing). The Swift files are compiled as they
# are, except that `import SQGPUKernels` is dropped and its pure GPUFilterUniforms/GPUFilterPlan (Passes.swift, lines 2-63)
# are added, and `Compositor` is an empty enum (VisibleSourceRegion.swift only extends it).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$here/../../.."
src="$root/Packages/SQRender/Sources/SQRender"
out="$here/swift-dump/out"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.app/Contents/Developer ]; then export DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer; fi
SWIFTC="$(/usr/bin/xcrun --find swiftc)"; SDK="$(/usr/bin/xcrun --show-sdk-path)"
[ -f "$out/libSQCore.dylib" ] || "$here/build-sqcore.sh"
mkdir -p "$out/src" "$here/golden"
for f in Effects/BlendModes Effects/CropMask Effects/UltraKey Effects/ImageFilters Effects/StyleFilters Effects/GaussianBlur VisibleSourceRegion; do
  grep -v '^import SQGPUKernels' "$src/$f.swift" > "$out/src/$(basename "$f").swift"
done
# VisibleSourceRegion.swift: drop `isPointwise` (needs ColorPipeline) and `averagesBeforeGrading` (needs SourceColorSpace); both
# types live in the Color sources, which this dumper does not build.
python3 - "$out/src/VisibleSourceRegion.swift" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
a = s.index("    /// A color chain whose every op works per pixel"); b = s.index("    /// Above this many canvas px")
c = s.index("    /// Sources whose 2 x 2 average")
s = s[:a] + s[b:c].rstrip() + "\n}\n"
open(p, 'w').write(s)
PY
{ sed -n '2,63p' "$root/Packages/SQGPU/Sources/SQGPUKernels/Passes.swift" | grep -v '^import'; echo 'enum Compositor {}'; } > "$out/src/Stubs.swift"
sed -i '' '1i\
import Foundation
' "$out/src/Stubs.swift"
nice -n 15 "$SWIFTC" -sdk "$SDK" -O -I "$out" -L "$out" -lSQCore -Xlinker -rpath -Xlinker "$out" -o "$out/dump" \
  "$here/swift-dump/main.swift" "$out"/src/*.swift
"$out/dump" "$here/golden/effects.tsv"
