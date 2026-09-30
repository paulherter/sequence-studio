#!/bin/bash
# Runs `swift test` for one package (or all); prints errors/failures only.
# Uses /usr/bin/swift (Xcode toolchain): the swiftly shim on PATH picks a mismatched CLT SDK and fails to link.
# Usage: scripts/test.sh [Package]
cd "$(dirname "$0")/../Packages" || exit 1
pkgs=("$@"); [ ${#pkgs[@]} -eq 0 ] && pkgs=(SS*)
rc=0
for p in "${pkgs[@]}"; do
  out=$(cd "$p" && /usr/bin/swift test 2>&1); s=$?
  if [ $s -ne 0 ]; then
    rc=$s; echo "== $p FAILED"
    echo "$out" | grep -E "error:|✘|Fatal error|failed" | cut -c1-200 | sort -u | head -30
  else
    echo "== $p ok ($(echo "$out" | grep -Eo 'Executed [0-9]+ tests?|Test run with [0-9]+ tests? in [0-9]+ suites? passed' | tail -1))"
  fi
done
exit $rc
