#!/bin/bash
# Runs `swift test` for one package (or all); prints errors/failures only.
# Uses /usr/bin/swift (Xcode toolchain): the swiftly shim on PATH picks a mismatched CLT SDK and fails to link.
# Usage: scripts/test.sh [Package]   (SQ_TEST_FILTER=<regex> limits the run to matching tests,
#        SQ_TEST_RELEASE=1 builds optimised for perf benches, SQ_TEST_SERIAL=1 runs one test at a time for real per-test
#        times, SQ_TEST_SOAK=1 runs the fuzz/soak tests with their full iteration counts (default: reduced))
# Each package ends with one line: "== <Pkg> ok (...) 95s (build 60s, tests 35s)". Per-test times land in
# $TMPDIR/sqtest-xunit-<Pkg>*.xml (Swift Testing writes the -swift-testing.xml one; XCTest only in parallel runs), so a
# slow suite can be read later without rerunning. SQ_SEED_BUILD=1: a worktree without .build for the package first tries
# scripts/seed-build.sh (APFS clone of main's .build, only when its stamp matches; see that script).
#
# Watchdog: a package run that prints nothing for SQ_TEST_STALL_SECONDS (alias SQ_TEST_IDLE) seconds (default 300) is considered stuck (a wedged fontd or
# CoreText call used to hang the whole run): its own process group is killed and the run is retried once. The limit is
# on inactivity, not on total time, so a long but progressing run (build, many tests) is never cut. A second stall is
# reported as a failure; the message names the last test that started. Only this run's own process tree is ever killed,
# also when the script itself is interrupted or terminated (trap), so no swiftpm-testing-helper outlives it holding a slot.
#
# Log cap: the per-run log ($TMPDIR/sqtest.XXXX) never grows past SQ_TEST_LOG_CAP_MB (default 500): a looping test once
# wrote 81 GB and filled the disk. Output goes through `head -c`, so the file cannot exceed the cap; a run that reaches it
# is killed and fails with "log cap reached" (no retry). The log is deleted when the script ends, however it ends; a
# failed run keeps a copy (at most 20 MB: its start and its end) in $TMPDIR/sqtest-last-fail-<Pkg>.log.
cd "$(dirname "$0")/../Packages" || exit 1
pkgs=("$@"); [ ${#pkgs[@]} -eq 0 ] && pkgs=(SQ*)
# Tests compare English UI text: force the source language (SQL10n reads SQ_LANGUAGE) whatever the Mac is set to.
export SQ_LANGUAGE="${SQ_LANGUAGE:-en}"
idle="${SQ_TEST_STALL_SECONDS:-${SQ_TEST_IDLE:-300}}"
log_cap=$(( ${SQ_TEST_LOG_CAP_MB:-500} * 1024 * 1024 ))
[ -n "$SQ_TEST_LOG_CAP_BYTES" ] && log_cap="$SQ_TEST_LOG_CAP_BYTES"      # exact cap in bytes (to try the cap itself)
outfile=""
rc=0

# A test target that imports a module only reached transitively keeps stale objects when that module's layout changes
# (SwiftPM only tracks direct dependencies): it then crashes at run time. Fail early instead (the design notes).
../scripts/check-direct-deps.sh "${pkgs[@]}" || { echo "== add the missing direct dependencies to Package.swift"; exit 1; }

# kill_tree <pid>: TERM then KILL for a pid, its process group and every descendant (swiftpm-testing-helper and
# *PackageTests.xctest can leave their group, then survive the group kill holding VideoToolbox/GPU).
descendants() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
kill_tree() {
  local pid="$1" all
  all="$pid $(descendants "$pid")"
  kill -TERM -- "-$pid" 2>/dev/null; kill -TERM $all 2>/dev/null; sleep 3
  kill -KILL -- "-$pid" 2>/dev/null; kill -KILL $all 2>/dev/null
}
# Orphans of earlier killed runs: only processes reparented to launchd (ppid 1), never a live run's helper.
clean_orphans() {
  local pid
  for pid in $(pgrep -f 'swiftpm-testing-helper|PackageTests\.xctest' 2>/dev/null); do
    [ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" = 1 ] && kill -KILL "$pid" 2>/dev/null
  done
  return 0
}
clean_orphans

# Machine-wide run slots (scripts/lib-slots.sh): test execution waits for one of SQ_TEST_SLOTS (default 4) slots, the
# compile for one of SQ_BUILD_SLOTS (default 3) and runs niced, so a running test never starves behind other builds.
. ../scripts/lib-slots.sh
watch_pid=""; last_test=""
cleanup() {
  trap '' INT TERM
  [ -n "$watch_pid" ] && kill -0 "$watch_pid" 2>/dev/null && kill_tree "$watch_pid"
  sq_release_all_slots; [ -n "$outfile" ] && rm -f "$outfile"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
tmp="${TMPDIR:-/tmp}"
# Stamps are written only in the main checkout (worktrees seed from it, never the other way round).
in_main=0
[ "$(git rev-parse --show-toplevel 2>/dev/null)" = "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")" ] && in_main=1

# watch <package> <outfile> <swift args...>: runs /usr/bin/swift in the package, in its own process group, output appended
# to outfile; returns its status, 124 when it printed nothing for $idle seconds, or 125 when the log reached the cap
# (its whole tree is killed in both cases).
watch() {
  local p="$1" outfile="$2" room; shift 2
  room=$(( log_cap - $(stat -f %z "$outfile" 2>/dev/null || echo 0) ))
  [ "$room" -le 0 ] && return 125
  # perl makes the child its own process group leader (setpgrp) so the whole tree can be signalled without touching others.
  perl -e 'setpgrp(0, 0); exec @ARGV' /bin/bash -c 'cd "$1" && shift && exec $SQ_RUN_PREFIX /usr/bin/swift "$@"' _ "$p" "$@" > >(head -c "$room" >>"$outfile") 2>&1 &
  local pid=$! last=-1 quiet=0 size
  watch_pid=$pid
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    size=$(stat -f %z "$outfile" 2>/dev/null || echo 0)
    if [ "$size" -ge "$log_cap" ]; then
      kill_tree "$pid"; clean_orphans
      wait "$pid" 2>/dev/null; watch_pid=""
      return 125
    fi
    if [ "$size" != "$last" ]; then last="$size"; quiet=0; else quiet=$((quiet + 1)); fi
    if [ "$quiet" -ge "$idle" ]; then
      last_test=$(grep -E 'Test (case )?.*(started|Started)' "$outfile" | tail -1 | cut -c1-160)
      kill_tree "$pid"; clean_orphans
      wait "$pid" 2>/dev/null; watch_pid=""
      return 124
    fi
  done
  wait "$pid"; local st=$?
  watch_pid=""
  # `head` (not a child we can wait for) may still be writing the last bytes: wait until the log stops growing (max 3 s).
  local n=0 prev=-1
  while [ $n -lt 15 ]; do
    size=$(stat -f %z "$outfile" 2>/dev/null || echo 0)
    [ "$size" = "$prev" ] && break
    prev="$size"; n=$((n + 1)); sleep 0.2
  done
  return $st
}

# run_pkg <package> <outfile>: builds the tests (build slot, niced), then runs them in a test slot; returns the status, or 124 on a stall.
run_pkg() {
  local p="$1" outfile="$2" extra=() build=() s
  # SQMedia runs serially: its AVAssetReader/Writer tests block cooperative-pool threads and deadlock when run in parallel.
  # SQText runs serially too: parallel CoreText font matching can wedge in fontd.
  # SQPlayback runs serially: its decode/audio-thread timing tests flake when suites compete for CPU/GPU.
  # SQExport runs serially: ~340 export/AVAssetReader/Metal/Vision tests in parallel crawl (53 s for a trivial test) and stall;
  # run one suite at a time each takes about 4 s. (--no-parallel does not serialise the cases of a parameterised test:
  # those carry `.serialized` in SQExport, 16 preset exports at once crashed the run.)
  # No --num-workers cap: SwiftPM only accepts it with --parallel (XCTest processes) and Swift Testing, which holds nearly
  # all suites here, ignores it; its own parallelism is bounded by the test slots in scripts/lib-slots.sh instead.
  case "$p" in SQMedia|SQText|SQPlayback|SQExport) extra=(--no-parallel) ;; esac
  # SQ_TEST_SERIAL=1: one test at a time, so the per-test times in the xunit file are real (parallel runs report
  # queue time: every test of a busy run shows the same ~30 s).
  [ -n "$SQ_TEST_SERIAL" ] && extra=(--no-parallel)
  extra+=(--xunit-output "$tmp/sqtest-xunit-$p.xml")
  # SQ_TEST_FILTER=<regex>: run only matching tests (e.g. a perf suite on its own, without the rest competing for CPU).
  [ -n "$SQ_TEST_FILTER" ] && extra+=(--filter "$SQ_TEST_FILTER")
  # SQ_TEST_RELEASE=1: optimised build (perf benches measure Release code; @testable still works via -enable-testing).
  if [ -n "$SQ_TEST_RELEASE" ]; then build+=(-c release -Xswiftc -enable-testing)
  # Debug: no index store (nothing reads it in scripted runs) and line tables only (backtraces keep file:line). Measured
  # 2026-10-12 on a cold SQCore test build: 490 s CPU -> 428 s (-13 %). Changing these flags rebuilds a package once.
  else build+=(--disable-index-store -Xswiftc -gline-tables-only); fi
  : >"$outfile"
  [ "${SQ_SEED_BUILD:-0}" = 1 ] && [ $in_main -eq 0 ] && [ ! -d "$p/.build" ] && ../scripts/seed-build.sh "$p"
  rm -f "$p/.build/sq-built-from"                        # the objects are about to change; re-stamped after a clean build
  local t0 t1
  t0=$(date +%s)
  sq_acquire_slot "$sq_build_slot_dir" "${SQ_BUILD_SLOTS:-3}" build
  SQ_RUN_PREFIX="nice -n ${SQ_BUILD_NICE:-10}" watch "$p" "$outfile" build --build-tests -j "$(sq_build_jobs)" "${build[@]}"; s=$?
  sq_release_slot "$sq_build_slot_dir"
  t1=$(date +%s); build_secs=$((t1 - t0))
  [ $s -ne 0 ] && return $s
  # Stamp: main's debug .build now matches HEAD (scripts/seed-build.sh clones it into fresh worktrees from this commit).
  # A release build (SQ_TEST_RELEASE) leaves the debug objects as they were, so it never stamps.
  [ $in_main -eq 1 ] && [ -z "$SQ_TEST_RELEASE" ] && [ -z "$(git status --porcelain -- . 2>/dev/null | head -1)" ] && git rev-parse HEAD >"$p/.build/sq-built-from" 2>/dev/null
  sq_acquire_slot "$sq_test_slot_dir" "${SQ_TEST_SLOTS:-4}" test
  SQ_RUN_PREFIX="" watch "$p" "$outfile" test --skip-build "${build[@]}" "${extra[@]}"; s=$?
  sq_release_slot "$sq_test_slot_dir"
  test_secs=$(( $(date +%s) - t1 ))
  return $s
}

for p in "${pkgs[@]}"; do
  outfile=$(mktemp -t sqtest)
  build_secs=0; test_secs=0; pkg_t0=$(date +%s)
  run_pkg "$p" "$outfile"; s=$?
  if [ $s -eq 124 ]; then
    echo "== $p: no output for ${idle}s, last started: ${last_test:-none} (stuck: fontd/CoreText, or the media engine starved by other runs); retrying once"
    run_pkg "$p" "$outfile"; s=$?
    [ $s -eq 124 ] && echo "== $p FAILED: stalled twice (${idle}s without output each), last started: ${last_test:-none}"
  fi
  if [ $s -eq 125 ] || [ "$(stat -f %z "$outfile" 2>/dev/null || echo 0)" -ge "$log_cap" ]; then
    s=125
    echo "== $p FAILED: log cap reached: a test is probably looping (log over $((log_cap / 1048576)) MB, run killed)"
  fi
  # A huge log is read (and kept) as its first and last 10 MB only.
  if [ "$(stat -f %z "$outfile" 2>/dev/null || echo 0)" -gt 20971520 ]; then
    { head -c 10485760 "$outfile"; printf '\n== ... log shortened by scripts/test.sh ...\n'; tail -c 10485760 "$outfile"; } >"$outfile.short"
    mv -f "$outfile.short" "$outfile"
  fi
  out=$(cat "$outfile")
  # Exit 0 without the Swift Testing summary means the process quit mid-run (e.g. a test stopped the run loop): not a pass.
  if [ $s -eq 0 ] && ! echo "$out" | grep -Eq 'Test run with [0-9]+ tests?.* passed'; then
    echo "== $p: exit 0 but no \"Test run with N tests passed\" line (test process quit mid-run)"; s=1
  fi
  # A filter that matches nothing is a mistake (typo, renamed suite), not a pass.
  if [ $s -eq 0 ] && [ -n "$SQ_TEST_FILTER" ] && ! echo "$out" | grep -Eq 'Test run with ([1-9][0-9]*) tests?.* passed|Executed [1-9][0-9]* tests?'; then
    echo "== $p: SQ_TEST_FILTER '$SQ_TEST_FILTER' matched 0 tests"; s=1
  fi
  [ $s -ne 0 ] && cp "$outfile" "$tmp/sqtest-last-fail-$p.log" && echo "== full log: $tmp/sqtest-last-fail-$p.log"
  [ -n "$SQ_TEST_KEEP_LOG" ] && cp "$outfile" "$tmp/sqtest-log-$p.log"   # full output with "passed after N seconds" lines
  rm -f "$outfile"; outfile=""
  echo "$out" | grep -E "^PERF " | cut -c1-200      # benchmark lines printed by perf tests (TimelineScrollPerfTests)
  wall="$(( $(date +%s) - pkg_t0 ))s (build ${build_secs}s, tests ${test_secs}s)"
  if [ $s -ne 0 ]; then
    rc=$s; [ $s -ne 124 ] && [ $s -ne 125 ] && echo "== $p FAILED $wall"
    echo "$out" | grep -E "error:|✘|Fatal error|failed" | cut -c1-200 | sort -u | head -30
  else
    echo "== $p ok ($(echo "$out" | grep -Eo 'Executed [0-9]+ tests?|Test run with [0-9]+ tests? in [0-9]+ suites? passed' | tail -1)) $wall"
  fi
done
exit $rc
