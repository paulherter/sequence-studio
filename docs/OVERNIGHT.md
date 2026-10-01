# Overnight Premiere-parity pass (2026-10-01 night)

Goal (Paul): a Premiere user must feel at home. Same handling as Premiere Pro (what you click, what happens,
which context menu appears, which shortcut does what), in our own design and our own code. Optimised for
YouTube and TikTok editing first. Add what is missing, fix what is wrong, remove inconsistencies and logic errors.
Paul tests the result in the morning.

## How every stream works

1. Work only in your own worktree. Never check out or commit in `/Users/paul/Documents/SequenceStudio` itself.
   Start with `git merge main`.
2. Inventory first: list what Sequence Studio has in your area (read the code, not the docs alone), then how
   Premiere does each thing. Sources: `docs/PREMIERE-BEHAVIOR.md` (first pass, many "(unverified)" items),
   web search to verify (Adobe's helpx pages block fetches: use search snippets, Adobe community, ProVideo
   Coalition, Larry Jordan, Premiere Bro, school helpwikis). Do not copy Adobe text or assets.
3. Write `docs/audit/<stream>.md`: a table `Feature | Premiere | Sequence Studio now | Gap | Done tonight?`.
   Keep it short and factual. Mark what you could not verify.
4. Fix and build the gaps, most valuable for everyday YouTube/TikTok cutting first. Small commits, English.
   Edit logic: tests first (SQCore has no AppKit/AVFoundation). Time is rational, never Double. Model = value
   types, undo = one snapshot step per user action or gesture. Swift 6 strict concurrency.
5. Every user-visible element gets the Premiere handling: click, double-click, drag, modifier keys, context menu
   (right-click) with the entries Premiere has there (omit entries for features we don't have; never show dead
   entries), tooltip, keyboard shortcut (Premiere macOS default).
6. Verify: `scripts/test.sh <Package>` (errors only), `xcodegen generate && scripts/build.sh`. No click-testing
   with screenshots. For new or changed layout, render the view offscreen ONCE (cacheDisplay, 2x) and look at
   it, because unit tests missed an upside-down layout and split glyphs before. Use NSLog dev aids for real-app
   checks.
7. Look and feel: native AppKit controls, Final Cut-like clean look, SF Symbols, `Theme` colours. No new panels
   unless Premiere has them and Paul's UX rules allow it (no Properties panel; minimal toolbar; panels via
   Window menu; effects are dragged onto clips).
8. Shared hot files (`App/Sources/AppController+Commands.swift`, `App/Sources/EditorPanels.swift`,
   `EditorSession*.swift`, menus): keep edits there minimal and additive (new functions in new files or
   extensions where possible) so merges stay clean.
9. Before your final report: `git merge main` again, resolve conflicts keeping both sides' behaviour, re-run
   tests and build, commit. Never push. Do not merge into main yourself.
10. Final report (short): branch + hash, what was added/fixed (user-visible wording), what is still missing,
    test counts, and a "try this" list of at most 10 lines for Paul.

Known flaky under load (not yours to fix unless you are the stability stream):
`AudioEngineTests.playsAtAllRatesWithoutUnderruns`, `redrawPerformance200Clips`, `CaptionsPanelModelTests.rapidEditsCoalesce`,
SQText hanging in fontd inside `scripts/test.sh` (passes with plain `/usr/bin/swift test`).
