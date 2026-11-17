# M-5a notes (model follow-up: edits that needed several tasks' code)

## Done
- `timeline/ripple.rs` (declared in timeline.rs): `Timeline::{ripple_delete, ripple_delete_detailed, ripple_delete_one, ripple_trim,
  ripple_trim_many, insert}`, `RippleClamp`, the caption/marker/In-Out hooks (`close_caption_span`, `open_caption_gap`,
  `shift_markers`, `shift_in_out`, `explicit_marks`). `CaptionTrack::{follows_ripple, close_span, open_gap}` and the word helpers
  (`CaptionItem::{tokens, has_word_timings, effective_words}`) are in captions.rs. `Timeline::duration` (Evaluation.swift) is in timeline.rs.
- `animation_zones_lengths.rs`: `Clip::{animation_zone_lengths, minimum_duration, clamping_shortening}` (Clip+AnimationFloor; the
  text payload is decoded on every call, marked `shortcut:`).
- `clip_attachment.rs`: `derive_attachments`, `Timeline::set_edit_mode`, `Project::set_edit_mode`, `remap_attachments`,
  `drop_attachments_to_missing_hosts`, `Clip::remap_attachment`, `clear_main_track_attachments`; the private `locate_clip` is gone (uses `find`).
- `timeline/three_point.rs`: `Timeline::overwrite` (placements), `three_point_edit` (+ `SourcePlacement`, `ThreePointMode`).
- `timeline/set_speed.rs`: `Timeline::{set_speed, set_duration, refresh_nested_durations}` (Timeline+Speed.swift, without rate stretch and `apply`).
- `timeline/picture_masks.rs`: `Timeline::remap_picture_masks`, `ClipEffect::{TRACK_MASK_KIND, is_track_mask}`.
- `transition.rs`: `Timeline::prune_transitions` / `Track::prune_transitions`, `TransitionKind::{track_kind, is_element, is_stinger}`.
- `nesting.rs`: `Project::{edit, sequence_clips, nest}`. `angles.rs`: `AnglesSetup::first_choice`.
- `project_media_ops.rs`: `sequence_from_media`, `replace_media` (+ private `fit_usage`); `project_media_ops/frame_scale.rs` (all of
  FrameScale.swift: fit/fill scale, `picture_size`, set to frame size, the v10 migration and `apply_pending_scale_migration`);
  `project_media_ops/generator_clips.rs` (`add_generator_clip`, `GeneratorPlacement`). `media_info.rs`: `AudioChannelMap::{mono, stereo,
  dual_mono, file_layout, stored}`, `AudioTrackInfo::mappable_channels`.
- `sequence_settings.rs`: `Project::set_settings`, `SequenceFormat::{is_valid, sanitized, MAX_DIMENSION, PROBE_FALLBACK}` (validity part of SequenceFormatPresets.swift).
- `timeline.rs`: `master_gain`, `master_gain_at`. Stand-ins swapped: `speed_keys_ease.rs` now uses `EaseShape::{effective, LINEAR}`.
- Swift tests ported: RippleDelete/RippleTrim/TimelineInsert/SyncedRipple/RippleTrimPivot/SplitEditRipple/SplitRelink (ripple.rs), SetSpeedTests
  (set_speed.rs), NestingTests (nest, edit, cycles, sequenceClips), ClipAttachment derive/mode/remap, AnimationFloor payload cases,
  AnimationZoneLengths (`minimum_duration`), GraphicsItemRange trim/split/follow/retime on a placed Graphic, FrameScaleTests, ProjectMediaOps
  and SequenceSettings tests, ThreePoint placement basics.

## Waiting on
- `GraphicsDocument::remove` (Graphics+Editing.swift, M-5b's graphics module): `graphics_item_range.rs` still has the private `remove_layers`
  copy (marked `shortcut:`); swap it when the real one exists. `Project::add_graphics_clip` (Graphics.swift) is not ported either: the item-range
  tests build the same clip with `add_generator_clip` and set `graphics_store`.
- `three_point_edit` is the Normal-mode path. Swift sends a Fast Cut sequence to `fastCutSourceEdit` (Timeline+MagneticOps.swift, 1144 lines,
  in no task): the caller must do that until it is ported (marked `shortcut:`). `Timeline::source_edit_targets` (Timeline+SourceEdit, needs
  `dropTargets` / `ensureAudioTrack`) is not ported; `sequence_from_media` applies the targeted-track half of that rule itself, which is exact
  for a fresh sequence.
- `Timeline::prune_transitions` uses `Track::resolved_portions`, a reduced `Track.resolve` (frame counts only). The full `ResolvedTransition`
  (span, easing, held frames, evaluation) is still a later task.
- Still no home: `adoptLegacyGrade` (Color effect logic, sq-core-color), `Keystone` ids for `HiddenCatalog.isHidden(keystone:)`,
  `Clip.detectedZones` / `Project.autoDetectAnimationZones` (`Clip.keyframeTimes`, Snapping.swift, `TitleTemplateError.noKeyframes`), the
  effect-key items of M-2 in EffectsCatalog (M-5b), `Project.allClips`, rate stretch and `apply(SpeedChange)` of Timeline+Speed, `trim`/`slip`/
  `roll`/`lift`/`extract` (Timeline+Edits, RangeEdits) and so the matching SpeedTrimTests, `videoLayers`/`audioSegments` (Evaluation).
- `floored_to_frame` is private to `timeline/ripple.rs` (Swift `Time.flooredToFrame`, TimelineSolo.swift); move it to sq-core-time with the rest of
  that file.
- Batch ripple (`Timeline+BatchRipple`: `shift_markers(through:)`, `closeSpans`) is not ported; `shift_in_out` has no `through` variant yet.

## Decisions and deviations
- Editing methods that mint ids take `&mut dyn IdSource`; `Project::edit` takes a closure and clones the project like Swift.
- `three_point_edit` takes a `SourcePlacement` value instead of 11 arguments, `add_generator_clip` a `GeneratorPlacement` (the lint rules forbid
  `allow(too_many_arguments)`); the Swift call sites map one to one.
- `Timeline::insert` (Swift `insert(_:at:)`) and `Timeline::overwrite` take `&[(Clip, Id)]` and an id source.
- `ripple_trim_many` is Swift's `rippleTrim(_ picks:edge:)`; the single-clip `ripple_trim` keeps the Swift name.
- Swift `min`/`sort` ties: `ripple_delete_detailed` sorts right to left with a stable sort; Swift's sort is not stable, so equal starts (two clips of
  one linked group) could be handled in either order there. The result does not depend on it.
