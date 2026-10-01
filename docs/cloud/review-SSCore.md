# SSCore deep review (Job B)

Read-only review of every file in `Packages/SSCore/Sources/SSCore`, by reading only. Paths below are inside that folder.
Items 1 and 2 were confirmed with a failing test and fixed. The rest are not reproduced: verify before fixing.
No Double-for-time bugs found. Linked A/V partners get the same delta in every edit traced.

## Fixed (failing test first)
1. **`Timeline+MatchFrame.swift:38` reverse match used unnormalised numerators.** The fallback compared
   `at.value*ph.timescale - ph.value*at.timescale`, which is |at-playhead| times a per-candidate timescale.
   Playhead 0, candidates at 3/1 and 5/2: picked 3 s over 2.5 s. Fix: compare `Time` distances.
   Test: `reverseMatchPicksNearestClipAcrossTimescales`.
2. **`Model.swift:239` `Track.clear` with an empty hole split a clip** in two (new id and link). Fix: return early
   on an empty hole. Test: `clearWithEmptyHoleLeavesClipsAlone`.

## Open findings (unverified)
3. **Ripple edits never shift sequence markers** (`Timeline.swift:83-201`, `Timeline+RangeEdits.swift:32-49`).
   Captions are shifted (`closeCaptionSpan`/`openCaptionGap`), markers are not; `shiftMarkers` (`Timeline+Markers.swift:62`)
   is only called from its unit test. Marker at 10 s, ripple-delete 2 s clip at 0: marker stays at 10 s, content is at 8 s.
   `inOut` is not shifted either. Fix: call `shiftMarkers` next to each caption call. Confidence: high it is missing, medium it is unintended.
4. **Shuttle 8x cap** (`Playback.swift:75-77`): `!isLess(thanMagnitude: 8)` lets rates 3, 5, 7 double to 10x/14x.
   Only reachable if the app layer sets such a rate (Shift+L nudge); `Shuttle.rate` is not settable from SSCore, so no SSCore test.
   Fix: clamp to 8x after scaling.
5. **Non-container `"project"` value may raise an ObjC exception** (`ProjectFile.swift:67-69, 120-122`):
   `JSONSerialization.data(withJSONObject:)` with `try?` does not catch it. Guard with `isValidJSONObject`. Medium; needs macOS to confirm.
6. **Nested-clip `mediaDuration` is a stale snapshot** (`Nesting.swift:52,107`, `Model.swift:59`): trim/roll/extend clamp to the
   inner sequence's length at nest time. Derive from the inner timeline at edit time.
7. **Paste clamps missing lanes** (`Timeline+Clipboard.swift:66`): V1+V2 clips pasted into a sequence with only V1 land on
   V1 and overwrite each other. Throw or create tracks.
8. **`slide` with a sub-frame neighbour** (`Timeline+RangeEdits.swift:72,79`): `-(dur - frame)` turns positive, slides the wrong way. Clamp with `max(.zero, ...)`.
9. **Caption trim can overlap a neighbour when shorter than one frame** (`Captions.swift:97,100-102`): final `max(e, start+minDuration)` undoes the neighbour clamp. Apply the neighbour clamp last.
10. **Zero `frameDuration` traps** (`Time.swift:43-55`): `frameIndex`/`snapped` divide by zero; `Project+MediaOps.swift:17` and
    `Timeline.sourceTimeline` copy `nominalFrameDuration` unvalidated, decoding accepts 0. Validate at construction/decode.
11. **`History.squash`/`rewind` depths go stale** after the 200-step trim (`History.swift:43,63-77`). Use a monotonic step counter.
12. **Audio clip label colour differs between panel and timeline for unprobed media** (`Labels.swift:68-74,117` vs `93`). Cosmetic.

## Job A (Linux build)
Swift 6.2.4 (Docker image layers pulled via mirror.gcr.io; download.swift.org is blocked). Two portability fixes:
`Recovery.swift` start time via `/proc`; `ProjectFile.atomicWrite` via `rename(2)` (corelibs `replaceItemAt` fails when the target exists).
One test skipped as root (read-only dir is not enforced). 451 tests pass on Linux.
