# E-A notes (evaluation, effects evaluation, transform stage, temporal and motion effects)

Modules: `evaluation.rs` (+ `evaluation/layer_occlusion.rs`), `effects_evaluation.rs`, `effect_transform_stage.rs`,
`temporal_effects.rs`, `motion_effects.rs`. Extension traits are named after the Swift file (`ClipEffectStage`,
`ClipStageEval`, `ClipEffectsEval`, `ClipEffectFilters`, `TimelineEvaluation`, `TemporalEffectEval`, ...); `lib.rs` has no
re-exports yet.

## Decisions
- `Clip.effects(at:)` is `ClipEffectsEval::effects_at` (the field is called `effects`).
- Nested Swift types are flat: `TemporalFilter.Denoise` is `TemporalDenoise`, `LayerRequest.PairInfo` is `PairInfo`, etc.
- `video_layers` needs four things Swift reads from crates above this one (Angles in edit; format variants, Date Stamp and
  Follow in graphics). They come in through `LayerHooks` (closures); `LayerHooks::plain()` = none of them. The caller above
  wires the real ones. The audio side of an Angles clip plays the sequence as it is (no hook yet).
- `SequenceResolver<'a> = &'a dyn Fn(Id) -> Option<&'a Timeline>` (borrowed, no clone per lookup).
- `StageTransform` is the model's (`affine2.rs`); `sq-core-masks` re-exports it (its own copy was removed).
  plan; the stabilizer user must convert (same fields) or masks should re-export the model's.
- `ClipEffects` carries the pieces masks waited on: `magic_mattes`, `magic_matte_keys`, `MagicMatteUse`,
  `needs_subject_matte`; `ClipEffectFilters::rolling_shutter_filter` / `track_mask_shape`; `ClipEffectsEval::moves_pixels`;
  `LayerRequest::picture_tracks_at_level`, `matte_layers`, `TimelineEvaluation::picture_matte_tracks`; `LayerOcclusion`.
- Also ported here because no skeleton module owns them: `StackTransition` (TransitionLayer.swift), `PosterizeTime.heldLocal`
  and `Clip.posterizedTime`, the Group Transform stage evaluation (`group_stage`, `composed`, `removing_group_stages`,
  `applying_group_stages`, `group_stage_transforms`), `ClipEffect.trackMaskShape`, `ClipEffect.rollingShutterFilter`.
  Left to the edit side: `ClipEffect.groupTransform(from:shift:)`, `isIdentityGroupStage` (Grouping logic).

## Waiting on
- `ClipEffectFilters::image_filter` falls through to `ClipEffectStyleExt::style_filter` for every kind it does not handle (X-1).
- `MatteRefine` type (`ChromaKey.refine`): masks has only `morph`/`box_blur`; `ChromaKey::refine` is not ported.
- `ELEMENT_SPAN_KEY` ("elementSpan") is a private literal in `motion_effects.rs`.
- `adjustment_clip.rs`: `LayerRequest::is_adjustment` is defined here (kind literal "adjustment"); drop it there or here.
- Swift tests left out: `EffectsBatch1/Style/Look/Review` filter and look cases (need `addEffect`, `styleFilter`), the
  `MotionRecipesTests` (MotionRecipes, another module), `MotionShutterTests`, `HiddenMotionTests`, MaskMotion and
  TransitionMotion tests, `m7TickWithThreeStagesStaysUnderBudget` (timing), `EffectTransformStageFileTests` (project file).

## Quirks kept
- `Clip.motion_blur`, `stage_transform`: float clamps use `clamp`, which keeps NaN like Swift's min/max pair.
- `reframe_effect` takes `id` and `ids` (new key ids), Swift used `UUID()`.
