# M-5b notes (catalog entries, defaults, shapes, typed shortcuts)

## Done
- `effects_catalog/` (child modules of `effects_catalog.rs`, no lib.rs change): `keys.rs` and `audio_keys.rs` (every kind and
  key string of `extension ClipEffect`, `ClipEffect::SCREAMING_CASE`; generated from the Swift sources, acronyms split as
  `AUDIO_EQ_KIND`, `STAGE_SCALE_Y_KEY`), `video_specs.rs` (core, film look, temporal, Posterize Time, Date Stamp),
  `style_specs.rs`, `motion_specs.rs`, `audio_specs.rs` (incl. Multiband, Parametric EQ, Graphic EQ, pitch, Enhance Speech),
  `stage_specs.rs` (Transform, Auto Reframe, Dynamic Zoom, Stabilizer, Group Transform, Shape generator, Color Graph, Color),
  `eval.rs` (`ClipEffect::scalar/flag/choice/color/point/sanitized/noise_seed`, `EffectCatalog::is_generator_owned`).
- `EffectCatalog::{every_spec, all, offered_video, every_audio_spec, offered_audio, generator_specs, spec_for, title_for, param}`;
  lists are built once (`OnceLock`), `spec_for` returns a clone. `EffectParamSpec::{hue, display_scale, axis}`,
  `EffectParamPair::stage_pairs`, `EffectParamSpec::choice` takes any `&[impl AsRef<str>]`.
- `ClipEffect::{default_parameters, default_colors, default_points, applied_start_value, make}` (`make` takes the new id).
- `effect_defaults.rs`: `can_have_default`, `set_default_effect`, `make_effect`, `from_payload` (legacy shadow upgrade and
  transition alignment fix), `transition`, `set_default_transition`, `Clip::reset_effect`; the real `TransitionPreset` type
  (serde, payload, `from_payload`) replaces the opaque JSON; `effect_defaults/legacy_shadow.rs` is
  `ClipEffect::upgrading_legacy_shadow_color` (ProjectFile+V24.swift) with `has_legacy_shadow_color`.
- `graphics/shape_style.rs`: `ShapeKind::{ALL, title}`, `GeneratorRef::{SHAPE, shape, shape_kind}`, `ShapeStyle` (evaluate,
  raster size, arrow points, is_empty), `Clip::{shape_style, graphics_layer_clip}`, `Project::{default_shape_effect, edit_graphics}`,
  `GraphicsLayer::{shape, path, shape_style, generator_ref}`, `GraphicsDocument::add`.
- `affine2.rs`: `StageTransform`, `Affine2::from(&StageTransform)`, `ClipTransform::map`.
- `keyframes_hue.rs`: `ClipEffect::shown_value`, `Clip::follow_shown_values` with the Color wheel parts they need
  (`COLOR_PUCKS`, `puck_value`, `key_wheel_partners`; Swift ColorKeyframing.swift, small slice).
- `anchored_animation/text_animator.rs`: the real `TextAnimator` (+ unit, effect, order, slide direction enums) in
  `KeyframeTemplate::text_animator`; decode clamps like the Swift initializer.
- `masks/construct.rs`: `MaskPath::{rectangle, ellipse, polygon}`, `ClipMask::{make, make_subject, make_magic, make_picture,
  make_color_range}` (they take the new id).

## Id sources
`ClipEffect::make(id, kind)`; `EffectDefaults::{set_default_effect, make_effect, from_payload}`, `Clip::{reset_effect,
follow_shown_values}`, `ClipEffect::upgrading_legacy_shadow_color`, `GraphicsLayer::{shape, path}`,
`Project::default_shape_effect` and the `ClipMask::make*` family take an `IdSource` or an `Id` for what Swift draws with `UUID()`.

## Deviations
- `EffectCatalog::title_for` has no Effect Stack preset name fallback (marked `shortcut:`).
- `posterize_time` carries Swift's `PosterizeTime.rateRange` (1...60) and `defaultRate` (8) as literals (marked `shortcut:`).
- Spec lists return clones from `spec_for`/`param` (Swift copies structs too); a hot path wants a borrowed lookup later.

## Waiting on (needs code outside this crate or in files M-5a edits)
- Evaluation into `ImageFilter` (`ClipEffect.imageFilter`, `styleFilter`, `applyTemporal`, `EffectsEvaluation.swift`,
  `MotionEffects.stage`, `stageTransform`, Stabilizer `rollingShutterFilter`), `ClipEffect.reframeEffect` / Dynamic Zoom
  `effect(from:)`, the `isTransformStage` / `stabilizeMethod` helpers: sq-core-effects.
- `Project.addGraphicsClip`, `addGraphicsLayer`, `addShapeClip`: need `addGeneratorClip` and the `edit(timeline)` verbs (M-5a / project side).
  `edit_graphics` is done and is what `addGraphicsLayer` will call.
- `Clip.addEffect` / `addStabilizer` (EffectsEditing.swift; uses `acceptsColor`, `colorEffectIndices`), `Timeline.applyTransitionDefault`,
  `resetTransition`, `EffectDefaults.setDefault(from: Transition)` (`TransitionPreset.capture`, needs `TransitionKind.defaultEasing`,
  `defaultMotionBlur`, `hasParams`, `Transition.effective*`), `TransitionPreset.trackKind`: transition logic, effects crate.
- Color: the rest of ColorKeyframing.swift / ColorGradeEffect logic (`colorEffect(atLocal:)`, `setColorEffect`, `colorGrade`) and the
  v26 -> v27 `adoptLegacyGrade` fold; `ColorGradeFields.scalars/pucks` as shared tables (only the catalog rows and the puck keys live here).
- `TextAnimator` timing (`rank`, `start`, `totalDuration`, `progress`, `inState`, `outState`, `TextUnits`, `TextCharacterState`): graphics crate.
- `ClipMask.shape(atLocal:)` and `MaskShape` (render type), `MaskPath.moveVertex/translated` and the other path edits: masks crate.
- Bake logic (`Clip.bake*`, UserPresetBake) stays for sq-core-masks / sq-core-color: it reads `ColorEffect` and `MaskPath` edits.
- Swift tests not ported because they build tracks/projects through edit verbs or evaluate filters: EffectsBatch1/Style/Look/FilmLook
  (filters), MotionEffectsTests (stage), AudioEffectsTests (values), PosterizeDateStampTests, ShapeGeneratorTests parts using
  `addShapeClip`/`addEffect`/`duplicateEffect`/`pastingAttributes`, GraphicsClipTests/GraphicsCreateTests (project verbs),
  EffectDefaultsTests transition cases and the `addEffect(defaults:)` ones (ported through `make_effect`), HiddenCatalogTests that need
  `Clip.addEffect`, ColorGradeEffectTests, EffectParamTypesTests migration-through-ProjectFile cases (v23 load).
