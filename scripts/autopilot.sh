#!/bin/bash
# Runs fresh headless Sonnet sessions, one STATUS.md slice each, until the phase is done,
# something is blocked, tests fail, or the run limit is reached.
# Usage: scripts/autopilot.sh [max_runs]   (default 4)
cd "$(dirname "$0")/.." || exit 1
max=${1:-4}
mkdir -p logs
log="logs/autopilot-$(date +%Y%m%d-%H%M).log"

prompt='Continue with the next step from docs/STATUS.md. Do exactly ONE slice, tests first.
Run scripts/test.sh until green. Then update docs/STATUS.md (short) and commit (small, English, with the Co-Authored-By line). Never push.
Do not ask questions: if a real decision by Paul is needed, write it under "Open decisions" in STATUS.md, commit, and stop.
Your very last line must be exactly one of:
AUTOPILOT: CONTINUE
AUTOPILOT: PHASE_DONE
AUTOPILOT: BLOCKED <one-line reason>'

tools='Read Edit Write Glob Grep Bash(scripts/test.sh:*) Bash(scripts/build.sh:*) Bash(/usr/bin/swift:*) Bash(xcodegen:*) Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(git add:*) Bash(git commit:*) Bash(ls:*)'

for i in $(seq 1 "$max"); do
  before=$(git rev-parse HEAD)
  echo "== run $i/$max $(date +%H:%M)" | tee -a "$log"
  out=$(caffeinate -i claude -p "$prompt" --model sonnet --permission-mode acceptEdits --allowedTools $tools 2>&1)
  rc=$?
  echo "$out" >> "$log"
  last=$(echo "$out" | grep -E '^AUTOPILOT:' | tail -1)
  echo "   $last" | tee -a "$log"

  [ $rc -ne 0 ] && { echo "Stopped: claude exited $rc (limit reached?)" | tee -a "$log"; exit 1; }
  [ "$(git rev-parse HEAD)" = "$before" ] && { echo "Stopped: no new commit" | tee -a "$log"; exit 1; }
  [ -n "$(git status --porcelain)" ] && { echo "Stopped: uncommitted changes left" | tee -a "$log"; exit 1; }
  scripts/test.sh > /dev/null 2>&1 || { echo "Stopped: tests red after commit" | tee -a "$log"; exit 1; }
  case "$last" in
    "AUTOPILOT: CONTINUE") ;;
    *) echo "Stopped: $last" | tee -a "$log"; exit 0 ;;
  esac
done
echo "Stopped: run limit ($max) reached" | tee -a "$log"
