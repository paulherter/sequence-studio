# SQCore deep review, round 2 (Job B)

Scope: everything in `Packages/SQCore` changed since 107ad46 (transitions, speed keys, fades, ducking, pan, effect instances,
frame hold, enable/disable, duplicate, source edit placement, caption karaoke, migrations v17-v23). Two reviewers read the
code, every finding was tried as a failing test first. Linux: Swift 6.2.4, `swift build` and `swift test` green after the
fixes (911 tests). Tests are in `Tests/SQCoreTests/CoreReview2Tests.swift`.
Nothing found: Double used for time, undo steps (every edit traced is one step), migrations v16-v23 (identity, optional fields),
source edit placement, silence removal, pan and gain maths, enable/disable skipping in evaluation.

## Fixed (failing test first)
1. **Audio fade deleted a user key at clip start/end** (`Fades.swift` `place`). `KeyframeTrack.insert` replaces a key at the
   same time, so a user key at 0 or at the clip end vanished, and removing the fade did not restore it.
   Fix: `FadeMarks.displacedHead/displacedTail` remember it, removal puts it back. Tests: `audioFadeRemovalRestoresUserKeyAt…`.
2. **Video fades crossed on tiny clips** (`EffectsEditing.swift` `applyVideoFade`). Half the clip was snapped up to frames:
   3-frame clip peaked at 0.5 after fade in + out; 1-frame clip became invisible. Fix: cap at whole frames in half the clip
   (a 1-frame clip gets no fade). Tests: `videoFadesOnAThreeFrameClipDoNotCross`, `videoFadeOnAOneFrameClipLeavesItVisible`.
3. **Auto Duck with zero fade did nothing** (`Ducking.swift`): the un-ducked and ducked key at the same time collided and
   the ducked one was dropped. Fix: no un-ducked key when the fade is zero. Known limit: the line before the first ducked
   key then holds the ducked level (a step needs a time before it). Test: `duckingWithZeroFadeStillDucks`.
4. **Crash: `Clip.sourceRange` on a keyed clip outside its own range** (`Model.swift:216`, precondition "empty slice").
   Reached by retimed nested audio in a transition handle. Fix: clamp first, fall through to the extended mapping.
   Test: `sourceRangeOutsideAKeyedClipDoesNotTrap`.
5. **`setTransition` stored a transition that fits no frame** (`Transition.swift`), which the next `Project.edit` prune
   deleted (alignment dropdown made it vanish). Fix: throw `insufficientMedia`, timeline unchanged.
   Test: `setTransitionNeverStoresOneThatFitsNoFrame`.
6. **Reversing a keyed clip did not mirror animation keys** (`Timeline+Speed.swift:102`, `mirror: false`; the constant-speed
   path mirrors). Fix: same flag as the constant path. Test: `reversingAKeyedClipMirrorsItsOpacityKeys`.
7. **`SpeedKeys.removingKey` not exact** (`SpeedKeysEditing.swift:147`): used the Time-rounded `span`, about 1 us off at 29.97.
   Fix: exact `span(at:)`. Test: `removingAKeyKeepsTheEndPositionExact`.
8. Test portability: `ProjectFileV21Tests.v21MigrationIsIdentity` failed on Linux (Swift dictionary vs `isEqual(to:)`). Compares NSDictionary now.

## Not fixed: needs a decision from Paul
- **Slip through a zero handle drops the transition for good** (`Transition.swift` header vs `pruneTransitions`, run by
  `Project.edit`, Nesting.swift:46). The header promises a slip only re-clamps and undo restores; but prune deletes any
  transition that resolves to nothing, so slipping a drag to handle 0 and back loses it. Repro: A 0..60, B 60..120 from
  source frame 10, 10-frame `endAtCut` transition, `slip(B, -10f)` then prune: 0 transitions. Fix options: prune only
  structurally dead transitions (clip gone, cut not adjacent), or correct the comment. Not changed: it is a design call.
- **`insertFrameHold` does not snap `duration`** (`Timeline+FreezeFrame.swift:65`): `Time(1,7)` leaves later clips off the
  frame grid. Existing test `insertFrameHoldDurationIsRational` deliberately expects an off-grid 1001/30000 hold on a 1/30
  timeline, so I did not change it. Decide whether holds snap.
- **Retimed nested audio loses transition envelopes** (`Evaluation.swift:261` builds `AudioNest` without `envelopes`, the
  non-retimed branch at :274 passes them). READ-ONLY, not reproduced: the time basis of the envelope for a retimed nest
  needs checking before passing it through.
- **`CaptionItem.words` doc says "on the timeline"** (`Captions.swift:16`) but the code treats them as relative to
  `range.start`; `replaceCaptions` does not validate. Fix the comment or convert on entry. Low.
- `editSpeedKeys` and the reverse flip rebuild the track with the Time-rounded `origin` and drop `originExact`
  (sub-microsecond). `SpeedKeys.fitting` cuts one frame per iteration (slow, and a failure reads as `.collision`).
  `setSpeed` can leave a keyed member shorter than `newDuration` after clamping (rare). READ-ONLY.
