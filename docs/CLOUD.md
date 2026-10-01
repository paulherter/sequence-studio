# Cloud jobs (Claude Code on the web)

The cloud runs on Linux: it cannot build or run the app (AppKit, Metal, AVFoundation, VideoToolbox).
It reads `main` from GitHub. Never push to `main`: put results on a branch `cloud/<job>` and open a pull request,
or write findings to `docs/cloud/<job>.md` on that branch. English, small commits. Read `CLAUDE.md` first.

Naming: never abbreviate Sequence Studio as "SS" in anything new (use SQ / sq).

## Job A: does the core build on Linux?
Install a Swift 6 toolchain if missing. In `Packages/SSCore` run `swift build` and `swift test`.
Report what fails and why (Foundation differences, missing imports). Fix only portability issues, with tests green on Linux.

## Job B: deep review, one package per run
Package given in the run text (SSCore, SSEditorUI, SSRender, SSPlayback, SSExport, SSText, SSTranscribe, SSMedia).
Read every source file. Look for provable bugs only: undo not one step per action, time not rational, off-by-one frames,
overlapping clips after edits, linked A/V drifting, crashes on empty/zero-length/1-frame input, data loss in project file
migrations, concurrency violations, unbounded caches. For each finding: file:line, failure scenario, fix. For SSCore also
write a failing test and the fix. Output `docs/cloud/review-<package>.md`.

## Job C: Premiere parity audit by reading
Compare `docs/audit/*.md` and `docs/PREMIERE-BEHAVIOR.md` with the code. List behaviours that are claimed but not
implemented, shortcuts bound twice or to nothing, menu items without effect, context menus missing entries.
Output `docs/cloud/parity.md`, most valuable first.

## Job D: test hardening for edit logic
In SSCore, add property-style tests for every edit operation (insert, overwrite, lift, extract, ripple/roll/slip/slide,
split, nudge, paste, link/unlink): invariants = no overlaps on a track, no negative or zero durations, linked clips stay
aligned, undo then redo restores the exact snapshot. Fix what they find.
