#!/bin/bash
# Parity: dumps every fixture with the Rust CLI and the Swift dumpers and diffs the dumps.
#   rust  vs  swift-portable (SQCore RawInflate, the code the Rust inflate is ported from): must be zero diffs
#   rust  vs  swift-apple (Compression framework, what the Mac app uses): differences are listed, not fatal
# Fixtures: synthetic (gen_fixtures.py, deterministic), the repo's Fixtures/ folder and real .prproj files
# (REAL_FILES: your own .prproj files; they stay outside the repo).
set -o pipefail
here="$(cd "$(dirname "$0")" && pwd)"
crate="$here/.."
repo="$crate/../.."
out="$here/out"; fx="$here/fixtures"
mkdir -p "$out/rust" "$out/portable" "$out/apple"

( cd "$crate" && nice -n 15 cargo build --release -q ) || exit 1
[ -x "$here/swift-dump/out/dump-swift-portable" ] || "$here/swift-dump/build.sh" || exit 1
python3 -I "$here/gen_fixtures.py" "$fx" || exit 1

RS="$repo/target/release/dump"
SP="$here/swift-dump/out/dump-swift-portable"
SA="$here/swift-dump/out/dump-swift-apple"

files=()
for f in "$fx"/*; do case "$f" in *.limit) ;; *) files+=("$f");; esac; done
for f in "$repo"/Packages/SQPremiereImport/Tests/SQPremiereImportTests/Fixtures/*; do [ -f "$f" ] && files+=("$f"); done
if [ -n "${REAL_FILES:-}" ]; then IFS=: read -ra real <<< "$REAL_FILES"; else
  real=()

fi
files+=("${real[@]}")

known=(); total=0; dp=0; da=0; badp=(); bada=()
for f in "${files[@]}"; do
  b="$(basename "$f")"; id="$(echo "$f" | cksum | cut -d' ' -f1)-$b"
  lim=(); [ -f "$f.limit" ] && lim=(--limit "$(cat "$f.limit")")
  "$RS" "${lim[@]}" "$f" > "$out/rust/$id.txt" 2> "$out/rust/$id.err"; rc=$?
  "$SP" "${lim[@]}" "$f" > "$out/portable/$id.txt" 2> "$out/portable/$id.err"; sc=$?
  total=$((total+1))
  if ! cmp -s "$out/rust/$id.txt" "$out/portable/$id.txt" || [ $rc != $sc ]; then
    if grep -qxF "$b" "$here/known-divergences.txt"; then known+=("$b"); else dp=$((dp+1)); badp+=("$b (rust rc=$rc, swift rc=$sc)"); fi
  fi
  if [ -x "$SA" ]; then
    "$SA" "${lim[@]}" "$f" > "$out/apple/$id.txt" 2> "$out/apple/$id.err"
    cmp -s "$out/rust/$id.txt" "$out/apple/$id.txt" || { da=$((da+1)); bada+=("$b"); }
  fi
done
echo "files compared: $total"
echo "known divergences (known-divergences.txt): ${#known[@]}"; for x in "${known[@]:-}"; do [ -n "$x" ] && echo "  known $x"; done
echo "rust vs swift-portable diffs: $dp"; for x in "${badp[@]:-}"; do [ -n "$x" ] && echo "  DIFF $x"; done
echo "rust vs swift-apple (Compression) diffs: $da"; for x in "${bada[@]:-}"; do [ -n "$x" ] && echo "  DIFF $x"; done
[ "$dp" = 0 ]
