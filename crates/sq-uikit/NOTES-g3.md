# sq-uikit notes: group g3 (worker ui3)

Ported: appearance_palette, sqcolor_value, sqcolor_recents, about_content, panel_id, timecode, rotation_text,
live_drag_coalescer, timeline_signposts, project_salvage_notice, keyframe_graph_geometry, waveform_drawing (geometry,
`WaveformCache`), key_character_resolver, keyboard_listing, keymap_store, keymap_import, localization_counts,
sqicon_resources, sqmascot_reactor.

## Verified here
appearance_palette, sqcolor_*, about_content, panel_id, timecode, live_drag_coalescer, timeline_signposts,
project_salvage_notice, keyframe_graph_geometry, key_character_resolver, waveform_drawing and rotation_text compiled and
passed (65 tests, clippy -D warnings clean) against temporary local stubs of `Key`, `ScrubMath::evaluate` and
`WaveformData::peaks` (the stubs were not committed).

## Merge
All names resolved at the merge (ui-fix): localization_counts and keymap_import use the `SQL10n` front (`plural_in`, `undo_name_in` for a given language).

## Shared helpers defined here (one home)
- `appearance_palette::UiDefaults` (the injected `UserDefaults`; strings, integers, string lists, bytes) and a test-only `MemoryDefaults`.
- `timecode::trim_blanks` (Foundation `.whitespaces`), `keyframe_graph_geometry::{Point, Size, Rect}`.
- `waveform_drawing::MemoryPressure` (no Rust port exists yet; move it when SQCore's MemoryPressure lands).

## Deviations from Swift
- `WaveformCache`: Swift builds buckets on its own utility queue and coalesces the notification on the main queue; here
  `request_build` only queues and the host runs `run_queued_builds()` on a background thread (then `set_on_built` fires once).
  The memory-pressure registry registration is the host's job (`apply_memory_pressure`). Input holds `Arc<WaveformData>`/`Arc<WaveformCache>`.
- The CoreGraphics paths (`path`, `outline`, `clipMarks`, `draw`) are not ported; tests use `bars`, `outline_polygons`, `clip_mark_rects`.
- `LiveDragCoalescer`: `schedule` hands the host a generation token; the host calls `run_scheduled(generation)` later (no weak self).
- `KeymapSet::export_data` writes pretty JSON with sorted keys, but serde puts `"key": value` where Foundation writes `"key" : value`;
  content is identical and both read back. Set ids come from `IdSource` (uppercase UUID text like `uuidString`).
- `AppearanceSettings` background/contrast are private with clamping setters (Swift `didSet`).
- `KeyCharacterResolver::current_layout()` is the US table (shortcut comment in code; the Carbon lookup is Apple-only).
- `EditorCommand::id()` default branch: the Debug name with a lower-case first letter (what Swift's `"\(self)"` prints for a case without payload).

## Swift quirks kept
- `Keymap.apply` marks a slot used even when the override clears it, so a cleared base slot is not re-added.
