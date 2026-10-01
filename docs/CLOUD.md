# Cloud jobs (Claude Code on the web)

The cloud runs on Linux: it cannot build or run the app (AppKit, Metal, AVFoundation, VideoToolbox).
It reads `main` from GitHub. Never push to `main`: put results on a branch `cloud/<job>` and open a pull request,
or write findings to `docs/cloud/<job>.md` on that branch. English, small commits. Read `CLAUDE.md` first.

Naming: never abbreviate Sequence Studio as "SS" in anything new (use SQ / sq).

## Job A: does the core build on Linux?
Install a Swift 6 toolchain if missing. In `Packages/SQCore` run `swift build` and `swift test`.
Report what fails and why (Foundation differences, missing imports). Fix only portability issues, with tests green on Linux.

## Job B: deep review, one package per run
Package given in the run text (SQCore, SQEditorUI, SQRender, SQPlayback, SQExport, SQText, SQTranscribe, SQMedia).
Read every source file. Look for provable bugs only: undo not one step per action, time not rational, off-by-one frames,
overlapping clips after edits, linked A/V drifting, crashes on empty/zero-length/1-frame input, data loss in project file
migrations, concurrency violations, unbounded caches. For each finding: file:line, failure scenario, fix. For SQCore also
write a failing test and the fix. Output `docs/cloud/review-<package>.md`.

## Job C: Premiere parity audit by reading
Compare `docs/audit/*.md` and `docs/PREMIERE-BEHAVIOR.md` with the code. List behaviours that are claimed but not
implemented, shortcuts bound twice or to nothing, menu items without effect, context menus missing entries.
Output `docs/cloud/parity.md`, most valuable first.

## Job D: test hardening for edit logic
In SQCore, add property-style tests for every edit operation (insert, overwrite, lift, extract, ripple/roll/slip/slide,
split, nudge, paste, link/unlink): invariants = no overlaps on a track, no negative or zero durations, linked clips stay
aligned, undo then redo restores the exact snapshot. Fix what they find.

## Job E: Premiere behaviour spec for one area (area given in the run text)
Areas: `timeline` (selection, trims, tools, snapping, track headers, markers, navigation), `monitors` (Source/Program,
three/four-point edits, JKL, Project panel), `effects` (Effect Controls, keyframes, interpolation, speed, time remapping,
transitions), `colour` (Lumetri, scopes), `text-audio` (Type tool, Essential Graphics/Properties text, captions, audio
gain/volume/mixing), `shell` (menus, shortcuts, workspaces, preferences, export, project handling).
1. Get sources: run `python3 scripts/fetch_adobe_guide.py` (Adobe's guide as text into docs/reference/adobe/, gitignored;
   never commit those files, never copy Adobe text: describe behaviour in your own words, cite the page name). Add web
   search for details Adobe leaves out (community forums, ProVideo Coalition, Larry Jordan, Premiere Bro, YouTube tutorial
   transcripts are fine as hints).
2. Read our code for that area (not only docs/audit/<area>.md) and write `docs/spec/<area>.md`:
   a table per feature: user action (incl. modifier keys, double-click, right-click menu entries, cursor shown, default
   shortcut on macOS) → exact result in Premiere → what Sequence Studio does today (file:line) → verdict
   (same / differs / missing) → proposed fix sized S/M/L. Include feel: speeds, step sizes, thresholds, defaults.
3. End with a ranked backlog (most valuable for YouTube/TikTok editing first) of at most 40 items, each implementable
   on its own, with acceptance criteria that can be unit-tested.

## Job F: how others solve it (topic given in the run text)
Topics: `feel` (timeline zoom/scroll/scrub/snapping/trim feedback in Premiere vs DaVinci Resolve vs Final Cut: what makes
each feel fast; concrete numbers where findable), `engine` (playback caching, proxy/optimised media, waveform and
thumbnail generation, render cache, audio pitch-preserving time-stretch, transitions and compositing order: study
GPL-3.0-compatible open-source editors on GitHub such as Kdenlive/MLT, Olive, Shotcut, OpenShot, and OpenTimelineIO;
read their code and docs).
Output `docs/research/<topic>.md`: findings with links, what we should adopt, in which package, estimated effort, and for
any code worth borrowing the licence and exact file (must be GPL-3.0-compatible; record nothing in THIRD_PARTY yet, just list).

## Job G: core feature with tests (feature given in the run text) — only after the SQ rename has landed in main
SQCore/SQCore only (pure Swift, builds on Linux: install Swift as in Job A). Tests first, rational time, value types,
one undo step per action. Report what the UI/engine layers must add on the Mac side.
