# sq-core-color notes (task C-1)

## Done
Basic tone curves, Auto Tone, Zone Board maths, Key color pick, film look / gate weave, camera input color spaces,
the Color effect on `ClipEffect` (field tables, read/write at a time, edit-only writes, wheel keying, range strength,
`scaled`), the clip's color view (`color`, `set_color`, edits, render color, range grades with fades, keyframing,
paste/replace grade, Pro grade accessors), the Pro grade (Step edits, columns, stacks, wiring, list, "Send to Pro"),
Color Match (wheels solver, Oklab planner, clip solver), Color Bypass, Color Matte, Color Range key.
130 tests, no Swift-side oracle table needed: every ported test carries its own numeric expectations (the solvers pass
the Swift tolerances unchanged).

## Calling `adoptLegacyGrade` (m1.md)
`ClipGradeExt::adopt_legacy_grade(&mut self, old: &ClipColor, ids)`. The Clip decode (sq-core-model `model.rs`, or the
file crate's v26 -> v27 step) runs it for a `color` key of a file older than v27: decode the old `color` as `ClipColor`,
then call it. sq-core-model cannot call it (it needs this crate), so the file crate (or `ProjectFixups`) does it after
decoding the clip, with the project's `IdSource`. Same for the other decode steps listed in sq-core-model `notes/s1.md`:
`pin_basic_model` is in the model; `ColorGraph::sanitize_wiring()` is `ColorGraphExt::sanitize_wiring` (call after decode).

## Waiting on
- `EffectStackPreset` / `ClipEffect.make` / `EffectCatalog` entries: `KeyingPresets` (Green/Blue Screen), `FilmPresets`
  and their tests (`greenAndBlueScreenPresets`, FilmLook preset tests), and the FilmLook *evaluation* from effects
  (`ClipEffects.look`, FilmLookTests that call `c.effects(at:)`). The struct types and `GateWeave` are here.
- The catalog should register `ColorGradeFields::spec()` (kind `color`) and use `ColorGradeFields::default_parameters()`
  for `ClipEffect::default_parameters("color")`; also an (empty-params) `colorGraph` spec. Not done here (catalog is model).
- `ClipEffect` decode must still call `pin_basic_model` (model notes); the Swift tests `aStoredColourEffectWithoutTheFlag...`
  wait for that.
- `remove_effect`: `clip_grade::remove_effect` is the one body (the grade edits here remove effects, and color sits below
  effects, so it cannot move up); `ClipEffectsEditingExt::remove_effect` in the effects crate forwards to it. The masks rule
  `hasLiveMaskInput` is passed into `render_color` as a closure; `Clip.canAcceptPastedEffect`, `EffectCatalog.isGeneratorOwned`,
  `Clip.addEffect(kind:)` and `moveEffect` tests (ColorGradeEffectTests: colourEffectsStayFirstInTheList, paste/preset tests)
  wait for the catalog.
- Done in `color_grade_links.rs` (X-1): `replaceBaseGrade`, `mappingKeyTimes`, `Clip.gradeIndependent`, `isSourceGradeable`, and the
  Project part of ColorGradeLinks (`linkGrades`, `linkAllClipsOfSource`, `unlinkGrades`, `propagateGradeLinks`, `gradeLinkMembers`,
  `referencedLUTFiles`, `replaceLUTPaths`, `containsGradeLinksOrRanges`, `containsColorRangeQualifiers`). Ids Swift draws with `UUID()`
  come in as `&mut dyn IdSource`. Not translated: the ColorGradeLinkTests that write a project file (versions) or use range fades/trims.
- Still open, Project/Timeline level (need Track `overwrite`/add-track and generators): `ColorGradeTargets` Project part
  (`sourceGradePlan`, `prepareSourceGradeEdit`, `setGradeLinkedToSource`, `ensureSequenceGrade`, `sequenceGradeClip`, `isSequenceGrade`),
  `Timeline.colorMatchPair` / `Clip.colorMatchSampleTime` / `isColorMatchPicture` (ColorMatchToClip), `Project.addColorMatte/setColorMatte`,
  `Project.containsRangeFades`, `containsV93Content`-style gates.
- `ColorDecisionImport` (CC/CCC/CDL XML + EDL comments): not started; the plan says to use the `fastxml` reader of
  sq-prproj-reader (needs that crate as a dependency of this one). Its tests (ColorGraphTests parsesCC...) wait.
- `ColorGraph` file-version tests (v78/v79/v80 gates) belong to the file crate (`uses_v80_fields`, `uses_v79_fields` are here).
- `LayerRequest` (render request) is not in the model: `ColorBypass::ungraded` takes `(clip id, &ClipColor)`.
- `InputColorProfile` is not serde (no saved type holds it); `VendorColorSpaceTests` (media detection) belong to media.

## Swift quirks kept / deviations to know
- NaN handling of `min(max(v, lo), hi)`: Swift `max` returns the NaN argument, Rust `f32::max` returns the other one.
  Where the Swift value can be NaN (guards in `clamped`) the same `isFinite` checks are kept; other places use
  `clamp` (NaN stays NaN like Swift) or `max().min()` on finite data only.
- `SIMD3.sum()` is assumed to add left to right; the Color Match tests pass with it (tolerance level only).
- `rename` trims with `str::trim` (Unicode White_Space) where Swift trims Foundation's whitespacesAndNewlines
  (differs only for U+200B and a few exotic spaces).
- Ids drawn by Swift (`UUID()`) come from `IdSource`; a conversion-only / default-empty graph uses `Id::NIL` for its
  never-rendered Step.
- `ColorMatchTargets` is `pub(crate)` (Swift internal); `ColorWheelsModel.Prepared`, `unapply`, `exposed` are `pub(crate)`.
- Constant tables in `ColorGradeFields` are `LazyLock<Vec<...>>` with `fn` pointers instead of Swift key paths;
  the five wheel pucks write through `set_puck` (match on the hue key).
- `ClipEffect.colorGrade(e)` takes an effect id and an `IdSource` (keyframes); `ClipEffect::color_grade(id, e, ids)`.
- Parameter keys are in `color_keys::*` constants (Swift `ClipEffect.color...Key`), `COLOR_KIND` re-exported from the model.
