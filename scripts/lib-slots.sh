#!/bin/bash
# Machine-wide run slots, sourced by scripts/test.sh and scripts/build.sh.
# Several agents build and test in their own worktrees at once. Unlimited, that puts load 120+ on 10 cores: test
# processes starve, print nothing for minutes and the watchdog in test.sh calls it a stall (measured 2026-10-07:
# 295 stalls in three days, each 5-10 minutes lost). Two pools:
#   test slots  (SQ_TEST_SLOTS, default 4): test execution; the suites share one hardware media engine.
#     Was 2 until 2026-10-08: measured with seven agents queued, the two running suites used about one core of ten
#     and rounds took 2-3 hours, almost all of it waiting for a slot.
#   build slots (SQ_BUILD_SLOTS, default 3): compiles; they also run niced so a running test always wins the CPU.
#     Was 4 until 2026-10-09: four compiles plus four test runs oversubscribed the ten cores.
# A slot whose owner died is taken over; after SQ_SLOT_WAIT seconds (default 1800) the run starts anyway, so nothing
# can deadlock. Slots are directories under /tmp, taken with mkdir (atomic).
sq_test_slot_dir="/tmp/sq-test-slots-$(id -u)"
sq_build_slot_dir="/tmp/sq-build-slots-$(id -u)"
sq_held_slots=()

# sq_reap_slot <dir> <i>: frees slot i when its owner is gone. Check and removal happen under one lock directory, so
# the owner read is always the current one: two waiters can never delete the slot a third run has just taken.
sq_reap_slot() {
  local d="$1/$2" lock="$1/.reap" owner
  if ! mkdir "$lock" 2>/dev/null; then
    # A reaper that died inside the lock (it holds it for milliseconds): clear it after a minute.
    [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$lock" 2>/dev/null
    return 0
  fi
  owner=$(cat "$d/pid" 2>/dev/null)
  if [ -n "$owner" ]; then
    kill -0 "$owner" 2>/dev/null || rm -rf "$d"                               # owner gone: free it, taken next round
  elif [ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rm -rf "$d"                                                                # died between mkdir and writing its pid
  fi
  rmdir "$lock" 2>/dev/null
  return 0
}

# sq_acquire_slot <dir> <count> <label>: blocks until one of <count> slots in <dir> is free.
sq_acquire_slot() {
  local dir="$1" n="$2" label="$3" limit="${SQ_SLOT_WAIT:-${SQ_TEST_SLOT_WAIT:-1800}}" waited=0 i holders
  [ "$n" -le 0 ] 2>/dev/null && return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  while :; do
    for i in $(seq 1 "$n"); do
      if mkdir "$dir/$i" 2>/dev/null; then echo $$ >"$dir/$i/pid"; sq_held_slots+=("$dir/$i"); return 0; fi
      sq_reap_slot "$dir" "$i"
    done
    [ "$waited" -ge "$limit" ] && { echo "== no free $label slot after ${limit}s, running anyway"; return 0; }
    if [ $((waited % 60)) -eq 0 ]; then
      holders=$(cat "$dir"/[0-9]*/pid 2>/dev/null | tr '\n' ' ')
      echo "== waiting for a $label slot (held by pid ${holders:-?}), ${waited}s so far" >&2
    fi
    sleep 2; waited=$((waited + 2))
  done
}

# sq_release_slot <dir>: frees this run's slot in <dir>.   sq_release_all_slots: frees every slot this run holds.
sq_release_slot() {
  local keep=() s
  for s in "${sq_held_slots[@]}"; do
    case "$s" in "$1"/*) rm -rf "$s" ;; *) keep+=("$s") ;; esac
  done
  sq_held_slots=("${keep[@]}")
  return 0
}
sq_release_all_slots() {
  local s
  for s in "${sq_held_slots[@]}"; do rm -rf "$s"; done
  sq_held_slots=()
  return 0
}

# sq_build_jobs: compile jobs for a build that has just taken its slot: the cores divided by the builds running now,
# at least 3. One build alone keeps every core; four at once ask for about twice the cores instead of four times.
sq_build_jobs() {
  local cores busy
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
  busy=$(ls -d "$sq_build_slot_dir"/[0-9]* 2>/dev/null | wc -l | tr -d ' ')
  [ "$busy" -lt 1 ] && busy=1
  [ -n "$SQ_BUILD_JOBS" ] && { echo "$SQ_BUILD_JOBS"; return 0; }
  local j=$((cores / busy)); [ "$j" -lt 3 ] && j=3
  echo "$j"
}

# sq_disk_guard: refuses to start a build or test below SQ_MIN_FREE_GB (default 15) free on the volume.
# Override with SQ_SKIP_DISK_GUARD=1. Returns 1 after printing one line; callers exit on it.
sq_disk_guard() {
  [ "${SQ_SKIP_DISK_GUARD:-}" = 1 ] && return 0
  local min="${SQ_MIN_FREE_GB:-15}" kb free_gb
  kb=$(df -k "${1:-.}" 2>/dev/null | awk 'NR==2 {print $4}')
  case "$kb" in ''|*[!0-9]*) return 0 ;; esac
  free_gb=$((kb / 1024 / 1024))
  if [ "$free_gb" -lt "$min" ]; then
    echo "== disk almost full: ${free_gb} GB free, need ${min} GB. Run scripts/clean-worktrees.sh (SQ_SKIP_DISK_GUARD=1 overrides)" >&2
    return 1
  fi
  return 0
}
sq_disk_guard "$(dirname "${BASH_SOURCE[0]:-$0}")" || exit 1
