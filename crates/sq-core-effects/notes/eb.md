# E-B notes (transition.rs, transition_layer.rs, transition_feel.rs, transition_custom_curve.rs)

## Done
- `transition.rs` (+ `transition/{render,resolve,edit,element}.rs`, tests in `transition/*_tests.rs`): all of Transition.swift's logic,
  ElementTransitions.swift (nobody else owned it) and the v89 `renderDirection`. Extension traits on the model types:
  `TransitionKindExt` (names, flags, `default_easing`, `default_motion_blur`, `preset_duration`), `TransitionDirectionExt`,
  `TransitionAlignmentExt`, `TransitionExt` (`new`, `effective_*`, `render_direction`), `TransitionStingerExt::clip`,
  `TransitionKindElement` (`element_params`), `TransitionElementExt` (`param`, `element_effect`), `TrackTransitions` (`resolve`,
  `resolved_transitions`, `applied_alignment`, `max_transition_frames`, `video_entries`, `audio_transition_info`),
  `TrackElementTransitions`, `TimelineTransitions` (add/set/remove, stinger, border, presets, defaults, reset, element verbs),
  `TransitionPresetExt` (`new`, `normalized`, `capture`, `track_kind`), `EffectDefaultsTransitionExt::set_default_from`.
  Render maths: `TransitionMix`, `TransitionSide`, `TransitionRender::evaluate(&RenderStyle, i, n)` and the shader mirrors
  (`iris`, `shape_wipe`, `light_leak`, `spring_fall`, `flip_3d`, `blur_dissolve`, `Glitch`, `Border`).
- `transition_custom_curve.rs`: trait `TransitionEasing` on `EasingCurve` (`progress`, `mix_weight`, presets, custom, `overshoot`).
- `transition_feel.rs`: factory looks (`TransitionKindFeel`, `TransitionFeelExt`, `TransitionLayerFeel`, `TimelineTransitionFeel`).
- `transition_layer.rs`: layer payload logic, `Clip`/`Track`/`Project`/`Timeline` layer verbs, `stack_render`.
- Tests: 213 in the crate (Swift: TransitionTests, Motion, More, ShapeWipe, ThirdSet, Glitch, IrisLightLeak, Border, TransitionShape,
  Zoom, Feel incl. the pinned overshoot render values, CustomCurve, Preset, HeldFrame, Stinger, ElementTransition (logic parts),
  TransitionLayer (model + stack render), EffectsInTransition (held clip)).

## Full `resolve` and the model's prune (answer for M-5a)
`TrackTransitions::resolve` is the full `Track.resolve`. `sq_core_model::Track::prune_transitions` keeps a transition exactly when
the full resolve returns `Some` (same guards, same arithmetic; `tests::model::full_resolution_agrees_with_the_models_prune` checks it).
So M-5a's reduced `resolved_portions` can stay as it is: the model cannot call this crate (the dependency runs the other way).
If the two ever need to be one function, move `ResolvedTransition` + `resolve` down into `sq-core-model/src/transition.rs`
and make `resolved_portions` a thin wrapper; nothing in this crate would change except imports.

## Waiting on (not in this crate)
- `Timeline::trim` (Timeline+Edits): `resizeTransitionLayer` is not ported; TransitionLayerTests resize/trim/move cases, TransitionTests
  EditConsistency (roll/slip/trim/move/paste/duplicate/moveInsert), ElementTransition tests that move clips, HeldFrame
  `trimmingBothHandlesAway` are left out for the same reason (and `Timeline::slip/roll/move`).
- `videoLayers` / `audioSegments` (Evaluation.swift, evaluation.rs): the tests that read layers (pair role, source times, groups, stack
  tags, effects in a pair, blend modes) are covered by `video_entries` / `audio_transition_info` here only where they test the entry
  list. `StackTransition` (needs `LayerRequest::PairRole`, `SequenceFormat` tag) is not ported.
- `MotionEffects.stage` (motion_effects.rs): ElementTransitionRenderTests (position/scale/opacity of Move/Zoom/Pop), the Pop curve shape.
  `element.rs` writes the mode as literals `MODE_IN`/`MODE_OUT` (marked `shortcut:`) until `MotionMode` exists.
- `Project::setStinger` / `containsStinger` / `containsElementTransitions` / `containsV89Content` (Project-level helpers; the gates in
  sq-core-file read the model directly), `Clip` clipboard copy of transitions (ClipboardTransitionsTests), `Timeline.addEdit`.
- `EasingCurve.displayName` / `EaseName` (only one Feel assertion left out).
- `ClipEffect::CUSTOM_CURVE_KEYS` is private in motion_easing.rs: `transition/element.rs` keeps its own 4-key list (make it `pub` and delete).
- ProjectFile round-trip cases of the Swift tests (Stinger v38, Layer v53, Element v40, Feel "byte identical") belong to sq-core-file goldens.

## Decisions / deviations
- `evaluate` takes a `RenderStyle` (the lint forbids 12 arguments); `addTransition` a `NewTransition`; `setTransition` a `TransitionChange`
  (all fields optional, `Default`); Swift's two `setTransition` overloads are `set_transition` and `set_transition_params`.
- Ids that Swift draws with `UUID()` come from `&mut dyn IdSource` (`add_transition`, `add_transition_from_preset`, `add_element_transitions`,
  `add_transition_layer`).
- `video_entries` returns a `VideoEntries` struct instead of the Swift tuple; clips are cloned into it.
- `TransitionPreset::capture` goes through `normalized()` like Swift's init (custom alignment saved as center).
- `TransitionPresetExt::new` is `TransitionPreset(kind:duration:)` with defaults; `normalized` is the rest of Swift's init rules.
- `replace_transition_border`, `apply_transition_preset`, `add_transition_from_preset` (EffectPreset.swift) live in edit.rs next to
  the other transition verbs; EA/EC should not port them again.
- Clippy: `is_*` trait methods take `&self` (wrong_self_convention); everything else by value on the Copy enums.
