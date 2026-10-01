# Autopilot (control session)

You are the control session. Paul is not answering questions between slices. You plan, delegate, check and
commit until V1 is done. You do not write product code yourself: implementer agents do.

## Start of every session
1. Read CLAUDE.md, docs/STATUS.md, docs/DECISIONS.md, `git log --oneline -30`, `git status --short`.
2. First run only: merge the separate status files (docs/PHASE3/4/5/7/8.md, EXPORT.md, LIBRARY.md, PROXY.md,
   REVIEW-1.md) into ONE slice list in docs/STATUS.md (done / next / open). Keep the detail files as references.
   Earlier parallel sessions may have been stopped mid-task. Their open items are in those files
   (incl. answers Paul already gave there: Proxy auto-generation + 50 GB LRU cache, own 4-band compressor,
   denoise mix ~50 %, review fixes 1-10, caption in/out anchors, Library open questions → decide yourself).
3. Uncommitted leftovers in `git status`: per package, run its tests. Green and coherent → review briefly and commit.
   Half-done → finish via an implementer agent or discard with `git restore`/delete, then note it in STATUS.md.
4. Continue with the next open slices.

## Order of work
1. Finish Phase 2 (engine slices, then shell/timeline/monitors/shortcuts). This is the critical path.
2. Integration, as soon as its prerequisites exist: GPU color chain + scopes into the compositor; SQText rendering;
   keyframes in Effect Controls (graph editor, easing menu, summary rows); SQAudioFX chain in playback;
   proxies for drag-scrubbing; SQExport FrameSource from the real renderer (+ caption burn-in);
   captions flow (Transcribe → edit → CC → Enter); Library panel; color UI + scopes; export dialog + queue.
3. Phase 6 nesting + multiple sequences.
4. Phase 9: tab groups + drag-to-dock, workspaces (PC/MacBook), autosave/crash recovery, relink, performance.
Always follow PLAN.md, docs/UX.md, docs/DESIGN.md, docs/ARCHITECTURE.md.

## How to run slices
- One slice = one implementer agent (Sonnet) with a self-contained brief: files, interface, acceptance test.
- Up to 3 implementer agents in parallel, only if they touch disjoint packages/files. Otherwise sequential.
- Tests first. After each agent: run `scripts/test.sh <Package>` yourself; red → one retry with the failure; red twice → mark blocked in STATUS.md, move on to other work.
- Reviewer agent before committing: playback clock, frame cache, audio engine, undo, project file, color, any change across 3+ packages.
- Commit with explicit `git add <paths>` (never `git add -A` / `.`), small English messages with the Co-Authored-By line. Never push.
- Build the app with `scripts/build.sh` after UI slices; it must stay green.

## Decisions
Decide yourself instead of asking. Default = how Premiere Pro behaves, unless PLAN/UX/DESIGN/DECISIONS say otherwise.
Record every non-trivial choice in docs/DECISIONS.md, prefixed `[auto]`. Paul reviews those later in one go.

## Waiting instead of stopping
This session runs under `/loop` (self-paced). If nothing is free to take (other sessions busy, waiting on a package),
don't end the loop: schedule the next wakeup (~10 min) and check `git status` / `git log` again then.
A package counts as free once it has no uncommitted changes and no commit for 10 minutes.
End the loop only for the stop reasons below.

## Stop only when
- a milestone needs Paul's hands and eyes: (a) after the E-14 benchmark: playback test, (b) timeline usable: cutting feel,
  (c) color: comparison with QuickTime, (d) captions flow end to end. Before stopping, keep doing other work
  that doesn't depend on the test; then stop with a short checklist of what Paul should try.
- test media is missing (e.g. TestMedia/iphone-hlg.mov),
- the usage limit is reached (Paul types "continue"),
- your own context gets large: update STATUS.md so a fresh session can pick up, and tell Paul to start a new one.

## Token rules
Keep your own context small: read reports, not code. No screenshots unless layout is the question.
Opus only for this control session and hard bugs; implementer and reviewer run on Sonnet, scout on Haiku.
