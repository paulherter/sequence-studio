# sq-core-graphics notes

Done: all 13 modules of the task (Graphics+Create, +Editing, +Follow, +LayerProjection, +MakeGraphic, +MoveOut,
TextAnimatorModel, SplitLayout, CustomAnimation, ShapeGenerator, DateStamp, FormatVariants+View, LottieGenerator), plus the
items earlier crates parked here. 187 tests. Extension traits are named after the Swift file (`GraphicsDocumentEditingExt`,
`GraphicsFollowDocumentExt`, `ProjectMoveOutExt`, ...); ids come in as `&mut dyn IdSource`.

## Parked items taken over
- `GraphicsDocument::remove` (`graphics_editing`), `Project::add_graphics_clip` / `add_graphics_layer` (`graphics_editing`),
  `add_shape_clip` / `set_shape_kind` (`shape_generator`), `TextAnimator` timing, `TextUnits`, `TextCharacterState`
  (`text_animator_model`).
- Caption hand-over animation (`sq-core-audio` could not own it): `CaptionHandoverAnimationExt` on `sq_core_audio::CaptionHandover`
  (`tail_opacity`, `entering_clip_time`, `draw`) and `AnimationSetEntranceExt` (`entrance_end`, `entrance_coverage`), in
  `text_animator_model`.
- `LayerHooks` of `sq-core-effects`: the app wires
  `LayerHooks { date_stamp: &date_stamp_request, variant_format: &variant_format, resolve_variant: &resolve_variant,
  resolve_follow: &follow_hook(text_bounds_provider, exact), angle_view: <edit crate>, ..LayerHooks::plain() }`.
  `date_stamp_request` (`date_stamp`), `variant_format` / `resolve_variant` (`format_variants_view`), `follow_hook`
  (`graphics_follow`; the provider is Swift's `GraphicsTextBounds.install`, the task-local `exact` is an argument).
- `TEXT_KIND` is exported from `graphics_make_graphic`; `sq-core-effects::sequence_conform` still has its copied literal.
- The logic of `FormatVariants.swift` (variant list verbs, overrides, detach/reset, prune, `Clip::resolved`) had no owner in the
  core split; it lives in `format_variants_view` next to the view code.

## Waiting on / for the integrator
- `sq-core-model/src/graphics_item_range.rs` keeps a private `remove_layers` copy of `GraphicsDocument::remove`; delete it and
  call `GraphicsDocumentEditingExt::remove` when the edit crate (which sees both) merges them. Same for `clamped`
  (`graphics_move_out` has a copy, marked `shortcut:`) and `MAX_DIMENSION` (`format_variants_view`).
- `sq-core-effects::sequence_conform::ConformMode` duplicates `sq_core_model::ConformMode`; `Clip::resolved` maps between them.
  Effects should re-export the model's.
- `Generators.swift` `updateGenerator` is not in the model; `set_shape_kind` carries the same loop (`shortcut:`).
- `Timeline.replaceClip` (Timeline+Replace, edit crate) is copied privately in `format_variants_view` (`shortcut:`).
- `TitleTemplate*` Swift tests (TitleTemplate.swift is not in this crate's file list) and `Timeline+ReelFill` are not ported.
- Mac-only / app side, not ported: `GraphicsTextBounds` global install (replaced by the `follow_hook` argument).
- Swift tests left out: GraphicsClipTests, GraphicsItemKeysTests, GraphicsItemRangeTests (model/edit verbs), `nest`-based
  FormatVariants W5 tests, `duplicateAsFormat`/`changeFormat`/file-format cases of FormatVariants*Tests (edit / file crates),
  the timing measurement test.

## Differences from Swift
- Errors: Swift `throws` of two error types becomes one enum with the second as a case: `SplitLayoutError::Edit`,
  `VariantError::Edit`, `LottieImportError::Edit`.
- `KeyframesPair::editable/edit` need an `IdSource` in Rust, so `AnimationSetCustomExt::position` / `edit_position`,
  `Keystone::from_animation` take one.
- Date Stamp: no `Foundation.Calendar`; a proleptic Gregorian civil-date calculation in UTC (same results, tested for roll-over
  and leap days). Non-finite parameter values count as 0 (Swift would trap).
- `GraphicsFollow::to_target` replaces `GraphicsFollow(target:)` (clippy `new_ret_no_self` for an extension trait), the
  `GraphicsEdges` set operations are `GraphicsEdgesExt`.
- `rename_group` uses `str::trim` (Foundation trims U+200B too; differs only for pathological names).
- `add_lottie_clip` takes a `GeneratorPlacement` whose `duration` is ignored (the clip takes the animation's length).
- `SplitLayout::cells` has the `f64` canvas only; the `Int` overloads were wrappers.
- Payload field order is the sorted key order Swift writes (`DateStampSpec`, `LottieSpec`); the gate compares decoded content.
