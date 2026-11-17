# sq-core-audio notes

Port of the audio part of Swift `SQCore`: AnglesAudioSync, AudioDriftFit (incl. `fit`), AudioChannelMap (logic), AudioDriftFit (result type), AudioEffects*, AudioGain*,
AudioGainPlan, AudioRole, Ducking, LiveDucking, LiveDuckingIndex, Caption* (items, words, karaoke, tidy, translation,
hand-over), FillerWords, SilenceRemoval, ToneGenerator, Voiceover. Saved types (`CaptionTrack`, `DuckTiming`,
`ProjectLiveDucking`, `AudioChannelMap`, `AudioTag`) stay in `sq-core-model`.

## Design choices
- Swift `extension X` on a model type is `XExt` (see `lib.rs`); Swift namespaces (`enum AudioGain`) are uninhabited enums.
- Ids and clocks come in as arguments (`&mut dyn IdSource`); nothing here calls a UUID generator.
- `UserDefaults` is the small `DefaultsStore` trait (numbers only: the only values Swift stores there).
- `ClipEffect.scalar(_:atLocal:)` is in the effects crate (it clamps to the catalog), so `audio_stage` takes it as a closure.
- Caption verbs are methods of `Vec<CaptionItem>` (`CaptionItemsExt`), because `CaptionTrack.items` is private in the model.
  Anything that read the track's own look takes `track_style` / `track_animation` as arguments.
- Float code keeps Swift's types and operation order (`f32` gains in `LiveDucking`, `f64` elsewhere).

## Waiting on (other crates)
- sq-core-model:
  - `CaptionTrack::with_items(&mut self, f: impl FnOnce(&mut Vec<CaptionItem>) -> R) -> R` (Swift `withItems`) and
    `CaptionTrack::new(...)` (Swift `init`, sorts the items). Then the track and timeline wrappers become one-liners:
    `CaptionTrack.replaceAll/setLines/move/trim/remove/split/merge/add/setStyle/setItem*/replaceText/closeSpan/openGap/`
    `setWord/insertWord/split(beforeWord:)/retimeWord`, and `Timeline.replaceCaptions/addCaptionTrack/setCaptionText/`
    `moveCaption/trimCaption/deleteCaption/splitCaption/mergeCaptions/addCaption/replaceCaptionText/setCaptionStyle/`
    `setCaptionItem*/resetCaptionItemsToTrackLook/setCaptionWord/deleteCaptionWord/insertCaptionWord/joinCaption/`
    `retimeCaptionWord/replaceCaptionMatch`, `closeCaptionSpan/openCaptionGap` (also need `shiftMarkers`, `shiftInOut`).
  - `AudioChannelMap::stored` is needed by the model's `replace_media` / `relink` (`Project+MediaOps`), but its logic
    (`file_layout`, `mappable_channels`) is here, above the model. Move `file_layout`, `stored`, `mappable_channels` and
    `AudioChannelLayout` down into `media_info.rs`, or inject them into `replace_media`.
  - `FadeKeys::snap_down` is private; `silence_removal.rs` has a 4-line copy.
  - `Project::edit(timeline, body)` (Swift `Project.edit` in Nesting.swift): needed for `addToneClip`.
  - `EffectStackPreset` (+ `EffectStackPreset.effect`, `StackBin`): needed for `AudioPresets.swift` (voice, Rode NTG).
  - `Timeline::add_track` (Timeline+AddTrack, edit crate): `place_voiceover` has a marked inline copy.
- sq-core-edit (Timeline+* verbs): `Timeline.removeCuts`, `removeSilences`, `softenJoins` (SilenceRemoval.swift; need
  `targetIndices`, `extractAll`, `extract`, `batchRippleApplies`), `Timeline.bleep` (ToneGenerator.swift, `targetIndices`,
  `split(at:relinks:)`), `Timeline.syncAudio` (AudioDriftFit.swift, `linkedGroup`, `setSpeed`), `Timeline.disguiseVoice`
  (Pitch file; `addEffect`, `setParameter`, `split(at:relinks:)`, `setClips`), Tests `LiveDuckingTests.movingADialogueClipMovesTheDuck`,
  `SilenceRippleTests` (except `cutsAreSortedMergedAndClamped`), `BatchRippleTests` and `ToneBleepTests.addToneClip*`
  wait with them. `Timeline.audioSegments` (ToneBleepTests) is not in this crate's files.
- sq-core-graphics (TextUnits, TextAnimator): `CaptionHandover.tailOpacity/enteringClipTime/draw`, `AnimationSet.entranceEnd`,
  `entranceCoverage`. `CaptionHandoverTests` cases that use them wait.
- sq-core-file: tests that write project versions (`containsV70Content`, `ProjectFile.writtenVersion`, v39/v43/v46 gates);
  `contains_audio_effects`, `contains_voice_chain_effects`, `contains_live_ducking_settings` are here for that crate to call.
- Not ported (platform): `LiveDuckingObserver` (NotificationCenter + UserDefaults notification); the app's settings store
  calls `LiveDucking::current` itself on a change.

## Swift quirks and differences
- `Voiceover.cleaned` and `fileName` count Swift Characters (graphemes); `isLetter`/`isNumber` of a Character is decided
  by its first scalar here (`char::is_alphanumeric`).
- `FillerWords.normalised` trims non-letters with `char::is_alphabetic`; Foundation's `CharacterSet.letters` also counts
  combining marks as letters. Only differs for words that begin or end in a bare combining mark.
- `Timeline.captionMatches` folds case and diacritics in Swift; `sq_core_time::text::ci_contains` folds case (and Latin-1
  decomposition) only. `CaptionItem.textMatches` (replace) folds case per grapheme, as Swift does (no diacritics).
- `AudioGainPlan.choice(index:)` traps on an index outside 0...4 in Swift; here it falls back to the last row.
- `LiveDucking.bake` ignores the `try? replaceClip` result (it cannot fail: same id, place and length); `Track::replace`
  is used directly.
- Sampled outputs (`LiveDucking.gain`, `curve`, baked keys) are compared with tolerances 1e-5 to 1e-6, as the Swift tests do;
  the maths is identical (`Float` gain, `Double` ramp fraction), libm `pow` may differ in the last bit.
- `min(max(x, lo), hi)` is `clamp` here. NaN differs only where Swift's argument order turns NaN into the lower bound
  (`min(1, max(0, red))` in `KaraokeStyle`, `Voiceover.clampedRate`); inputs are never NaN in the app.
