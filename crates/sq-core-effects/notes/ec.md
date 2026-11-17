# E-C notes (editing, presets, style kit, keystone, conform, blurred fill, adjustment)

Modules: `effects_editing`, `effect_preset`, `effect_stack_preset`, `style_effects`, `style_kit`, `keystone`,
`sequence_conform`, `blurred_fill`, `adjustment_clip`, `adjustment_extend`. Branch `rs/core-eff-ec` has `rs/core-eff-ea` merged
in (ImageFilter, ClipEffects, effect transform stage, transitions), because `style_effects` and the film-look tests build on it.

## Where things are
- `Clip.addEffect / setParameter / setColor / setPoint / moveEffect / duplicateEffect / removeEffect`, opacity keys and fades,
  Paste Attributes, `addAnonymize`, `addStabilizer`, `Stabilizer.insertionIndex` (`stabilizer_insertion_index`),
  `Stabilizer.effect` (`stabilizer_effect`), `MosaicBlockSize`: `effects_editing.rs` (`ClipEffectsEditingExt`,
  `TimelineEffectsEditingExt`). `stabilizeSpec` was already in the model catalog (`stage_specs::stabilize`).
- `EffectPreset`, `Anchor`, `ApplyMode`, `Clip.applyPreset`, `Timeline.applyPreset`: `effect_preset.rs`.
- `EffectStackPreset(s)`, `KeyingPresets`, `FilmPresets`, `AudioPresets` (the audio crate cannot hold them): `effect_stack_preset.rs`.
  Built-in ids are placeholders (`SequentialIds`): applying copies every effect and key with a fresh id.
- `StyleEffects.styleFilter` -> `ClipEffectStyleExt::style_filter`; `StyleEffects::period_hash`: `style_effects.rs`.
- StyleKit logic (`merging`, `StyleValue.resolve`, `MotionDefaults.apply`, `.sqstyle` file, `rewriteGenerators`): `style_kit.rs`.
- `Keystone` whole type (not a model type), `Keystone::built_in_id`, `Keystone::is_hidden` (the check `HiddenCatalog.isHidden(keystone:)`
  needs): `keystone.rs`.
- Change Format / Duplicate as Format: `sequence_conform.rs`. Fit with Blurred Fill: `blurred_fill.rs`. Adjustment Layer: `adjustment_*.rs`.

## Swap / wire when others land
- `remove_effect`: the body lives in `sq_core_color::remove_effect` (color sits below this crate and its grade edits need it);
  `ClipEffectsEditingExt::remove_effect` forwards to it. Done in X-1.
- `effects_evaluation.rs` image filter: the default arm calls `ClipEffectStyleExt::style_filter`. Done in X-1.
- `Timeline.replaceClip` (edit crate): `effects_editing::replace_clip` is a private copy (marked `shortcut:`).
- `extend_adjustment_layers_to_sequence_end` / `set_extend_to_sequence_end` take the edit crate's plain tail trim as a closure
  (`TailTrim`); pass `|t, id, by| { let _ = t.trim(id, ClipEdge::Tail, by); }`.
- `CaptionTrack` has no setter for its items: `duplicate_sequence` rebuilds caption tracks through JSON (marked `shortcut:`).
- `TEXT_KIND` ("text") in `sequence_conform.rs` is a copied literal until the graphics crate exports it.

## Waiting on
- `TransitionPreset` capture/apply/add verbs (`applyTransitionPreset`, `addTransition(preset:)`, `replaceTransitionBorder`,
  `TransitionPreset.capture`, `trackKind`) and `EffectDefaults.setDefault(from: Transition)`: transition logic is the other worker's
  (`transition*.rs`); they only need `TransitionPreset` from the model.
- `MotionPresets` / `MotionRecipes` are in `motion_presets.rs` / `motion_recipes.rs` (X-1) and `EffectStackPresets::all` starts with
  the motion bin, then keying, looks, audio (Swift order). Tests of the fingerprints (`EffectStackPresetTests`, FNV over Swift JSON) wait for the oracle golden.
- `LayerRequest.isAdjustment` (AdjustmentClip.swift): evaluation worker's `LayerRequest`.
- File-version gates `containsAdjustmentClips`, `containsExtendedBlendModes`, `containsFullBlendModes`, `containsExtendedAdjustments`,
  `containsGradientEffects`: already in `sq-core-file::gates`.
- Tests not ported: AdjustmentClipTests parts that evaluate `videoLayers` or write ProjectFile versions; StyleKitTests that go through
  ProjectFile; SequenceConform `deliveryTargetClearedWhenOrientationFlips` (needs `DeliveryTarget` constructors);
  StabilizerRetime speed-ramp case (needs `SpeedKeys` builders); AnonymizeTests/AnonymizeOrderTests parts that read `effects(at:)`
  scopes and project mask keys; EffectsStyleCatalog tests (catalog is the model's).

## Deviations and quirks
- `EffectPreset::scaled` (Swift `EffectPreset.scaled`, microsecond fallback) stays separate from `Time::scaled` (continued-fraction
  fallback): they differ only when the exact result does not fit Int64.
- `StyleKitFile::write` writes a temporary file and renames it (Swift `.atomic`).
- Swift `Keystone.Property/Anchor` are `KeystoneProperty/KeystoneAnchor`; `EffectStackPreset.Bin` is `StackBin`.
- `trimmingCharacters(in: .whitespacesAndNewlines)` in `duplicate_sequence` uses `str::trim` (shortcut marked in code).
- `Stabilizer::correction` and the effect stage both use the model's `StageTransform` (masks re-exports it).

## X-1 additions
`motion_recipes.rs`, `motion_presets.rs`, `speed_ramp_preset.rs` (`SpeedRampPreset`, `SpeedKeysPeak::peak_time`), `dynamic_zoom.rs`.
ElementTransitions.swift was already ported as `transition/element.rs`. Left out: `SpeedRampPresetTests.applyingThroughTheTimeline...` (needs `Timeline.editSpeedKeys`, edit crate), DynamicZoom's `convertToKeyframes` preset test.
`SpeedSegment::joins` is `pub` in the model now (one word changed) so the ramp builder can merge the plateau halves.
