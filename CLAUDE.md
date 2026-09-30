# Sequence Studio

Native macOS video editor (Premiere replacement). Plan: `PLAN.md`. Progress + open decisions: `docs/STATUS.md`.
Decisions log: `docs/DECISIONS.md`. Engine interfaces: `docs/ARCHITECTURE.md`. Borrowed code: `docs/THIRD_PARTY.md`.
Never deviate from PLAN.md silently: propose to Paul, record approved changes in docs/DECISIONS.md.

## Token budget (Claude Max, limits are tight — this matters)
- Main chat: Sonnet by default. Opus only for architecture, engine, color pipeline, hard bugs.
- Agents: `implementer` (Sonnet), `reviewer` (Sonnet, read-only), `scout` (Haiku, search/logs). No multi-agent workflows.
- Never paste raw xcodebuild output: use `scripts/build.sh` / `scripts/test.sh` (errors only).
- Read only the files needed. Prefer `swift test` in a package over building the app.
- Screenshots only when layout itself is the question. Paul judges feel; you report measurements.
- One task per session. Before ending: update docs/STATUS.md (short).

## Rules
- Swift 6, strict concurrency. English for code, UI and docs.
- Time is rational (value/timescale), never Double. Model = value types, undo = snapshots.
- SSCore has no AVFoundation/AppKit imports. Edit logic: tests first.
- Timeline and monitors: AppKit/Metal. Shell: SwiftUI. Icons: SF Symbols are fine (native app).
- Test media lives outside the repo (`~/Documents/Videos`, or `TestMedia/` which is gitignored). Never commit footage.
- Borrowing code: GPL-3.0-compatible only (GPL, MIT, BSD, Apache-2.0). Read and check it first, record in docs/THIRD_PARTY.md.
- Commits small, English, never push without being asked.

## Commands (set up in Phase 0)
- Generate project: `xcodegen generate`
- Build: `scripts/build.sh`  Test: `scripts/test.sh [Package]`
