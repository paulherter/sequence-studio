#!/bin/bash
# Runs `swift test` for one package (or all); prints errors/failures only.
# Uses /usr/bin/swift (Xcode toolchain): the swiftly shim on PATH picks a mismatched CLT SDK and fails to link.
# Usage: scripts/test.sh [Package]
#
# Watchdog: a package run that produces no result within SQ_TEST_TIMEOUT seconds (default 900) is killed (the whole
# process tree) and retried once. This is what a stuck fontd / CoreText call looked like before: the run hung forever
# and blocked every later package. A second timeout is reported as a failure, not a hang.
cd "$(dirname "$0")/../Packages" || exit 1
pkgs=("$@"); [ ${#pkgs[@]} -eq 0 ] && pkgs=(SS*)
limit="${SQ_TEST_TIMEOUT:-900}"
rc=0

kill_tree() {
  local p
  for p in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$p"; done
  kill -KILL "$1" 2>/dev/null
}

# run_pkg <package> <outfile>: runs swift test, returns its status, or 124 on timeout.
run_pkg() {
  local p="$1" outfile="$2"
  # SSMedia runs serially: its AVAssetReader/Writer tests block cooperative-pool threads and deadlock when run in parallel.
  # SSText runs serially too: parallel CoreText font matching can wedge in fontd.
  local extra=()
  case "$p" in SSMedia|SSText) extra=(--no-parallel) ;; esac
  (cd "$p" && exec /usr/bin/swift test "${extra[@]}") >"$outfile" 2>&1 &
  local pid=$!
  # The watchdog must not keep our stdout open (its sleep would outlive the run and block a pipe reader such as `| tail`).
  ( exec >/dev/null 2>&1; sleep "$limit"; echo timeout >"$outfile.timeout"; kill_tree "$pid" ) &
  local watchdog=$!
  wait "$pid" 2>/dev/null; local s=$?
  kill_tree "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  if [ -f "$outfile.timeout" ]; then rm -f "$outfile.timeout"; return 124; fi
  return $s
}

for p in "${pkgs[@]}"; do
  outfile=$(mktemp -t sqtest)
  run_pkg "$p" "$outfile"; s=$?
  if [ $s -eq 124 ]; then
    echo "== $p: no result after ${limit}s (stuck, probably fontd/CoreText); retrying once"
    pkill -f "xctest.*$p" 2>/dev/null
    run_pkg "$p" "$outfile"; s=$?
    [ $s -eq 124 ] && echo "== $p FAILED: timed out twice (${limit}s each)"
  fi
  out=$(cat "$outfile"); rm -f "$outfile"
  if [ $s -ne 0 ]; then
    rc=$s; [ $s -ne 124 ] && echo "== $p FAILED"
    echo "$out" | grep -E "error:|✘|Fatal error|failed" | cut -c1-200 | sort -u | head -30
  else
    echo "== $p ok ($(echo "$out" | grep -Eo 'Executed [0-9]+ tests?|Test run with [0-9]+ tests? in [0-9]+ suites? passed' | tail -1))"
  fi
done
exit $rc
