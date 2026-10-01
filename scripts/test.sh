#!/bin/bash
# Runs `swift test` for one package (or all); prints errors/failures only.
# Uses /usr/bin/swift (Xcode toolchain): the swiftly shim on PATH picks a mismatched CLT SDK and fails to link.
# Usage: scripts/test.sh [Package]
#
# Watchdog: a package run that prints nothing for SQ_TEST_IDLE seconds (default 300) is considered stuck (a wedged fontd or
# CoreText call used to hang the whole run): its own process group is killed and the run is retried once. The limit is
# on inactivity, not on total time, so a long but progressing run (build, many tests) is never cut. A second stall is
# reported as a failure. Only this run's own process group is ever killed.
cd "$(dirname "$0")/../Packages" || exit 1
pkgs=("$@"); [ ${#pkgs[@]} -eq 0 ] && pkgs=(SQ*)
idle="${SQ_TEST_IDLE:-300}"
rc=0

# run_pkg <package> <outfile>: runs swift test in its own process group; returns its status, or 124 when it stalled.
run_pkg() {
  local p="$1" outfile="$2" extra=()
  # SQMedia runs serially: its AVAssetReader/Writer tests block cooperative-pool threads and deadlock when run in parallel.
  # SQText runs serially too: parallel CoreText font matching can wedge in fontd.
  case "$p" in SQMedia|SQText) extra=(--no-parallel) ;; esac
  : >"$outfile"
  # perl makes the child its own process group leader (setpgrp) so the whole tree can be signalled without touching others.
  perl -e 'setpgrp(0, 0); exec @ARGV' /bin/bash -c 'cd "$1" && shift && exec /usr/bin/swift test "$@"' _ "$p" "${extra[@]}" >"$outfile" 2>&1 &
  local pid=$! last=-1 quiet=0 size
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    size=$(stat -f %z "$outfile" 2>/dev/null || echo 0)
    if [ "$size" != "$last" ]; then last="$size"; quiet=0; else quiet=$((quiet + 2)); fi
    if [ "$quiet" -ge "$idle" ]; then
      kill -TERM -- "-$pid" 2>/dev/null; sleep 3; kill -KILL -- "-$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
  done
  wait "$pid"
}

for p in "${pkgs[@]}"; do
  outfile=$(mktemp -t sqtest)
  run_pkg "$p" "$outfile"; s=$?
  if [ $s -eq 124 ]; then
    echo "== $p: no output for ${idle}s (stuck, probably fontd/CoreText); retrying once"
    run_pkg "$p" "$outfile"; s=$?
    [ $s -eq 124 ] && echo "== $p FAILED: stalled twice (${idle}s without output each)"
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
