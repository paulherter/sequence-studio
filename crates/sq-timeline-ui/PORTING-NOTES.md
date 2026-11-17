# sq-timeline-ui porting notes

Port of `Packages/SQTimelineUI`. One module per Swift file. Pure logic only: nothing draws.

## Not ported
- `#if canImport(AppKit)` branches (NSColor/NSImage helpers in `ClipMarkerFlags`, `FXBadge`, `WaveformTint`,
  `WaveformClipping`, `TransitionLayout`, `TransitionLayerLayout`, `ScrollGestureLogic`, `TimelineInteraction`); the
  portable branch is the oracle.
- `Exports.swift` (`@_exported import`): a Swift module detail.
- Perf-budget tests (`TimingSupport.swift` users) and the `UnlinkedSelection*Session*` suites: they test `EditorSession`
  and belong to sq-editor-session.
- `TransitionUITests` session suites (`TransitionTargets`, `TransitionDefaults` live in the session package).

## Deferred: needs a type the session crate does not have yet (do not declare a second one)
- `LayerListLogic` (needs `GraphicsDocument::move` and `ClipEffect::key_times`).

## Deviations from the Swift API (decisions)
- `TimelineInteraction::new(timeline, geometry, id_seed)`: Swift creates `UUID()`s for new tracks and copies inside a drag.
  The reducer is `Clone` (tests copy it), so it mints ids itself: `id_seed + 1, + 2, ...`. The caller passes a random seed.
- `DropPreview::update` takes `&mut dyn IdSource` for the stand-in ids of ghost tracks, and a `DropContext`.
- `MarkerRange::duration`, `VolumeLine::clip_dragging` and the line gestures take small parameter structs
  (`MarkerEndDrag`, `FadeDrag`) because clippy denies more than seven arguments.
- Hooks that were `NotificationCenter` posts (`ToolStripPrefs`, `ThumbnailPrefs`) are gone; the setter's caller redraws.
  Menu closures become `Rc<dyn Fn>`; `ToolStripTools::all_tool_items` reports docking through a `ToolStripAction` callback
  instead of writing `ToolStripPrefs` itself.
- `UserDefaults` -> `SettingsStore` (`TrackHeightStore`, `ToolStripPrefs`, `ThumbnailPrefs`).
- `Theme.Metrics` etc.: `portable_theme.rs` copies the values as Swift's `PortableTheme.swift` does.
- `CGRect.intersects` is strict (shared edges and empty rects do not intersect); `rect_math.rs`.
- `trimmingCharacters(in: .whitespacesAndNewlines)` in `nest`: private copy of the Foundation predicate (second user after
  sq-prproj-reader); move it to `sq_core_time::text` when that crate may be edited.

## Swift quirks kept
- `Double -> Int64` conversions trap in Swift on NaN/inf; here `int64()` debug-asserts finiteness and saturates in release.
- `snapPoints` of `TimelineInteraction` keeps its cache key (excluded ids, playhead, markers); `snap_cache_enabled` is
  `pub(crate)` for the lockstep test.

## Escalations
none

## Added with the draw-timeline port
- `TimelineSideMenus.trackHeader` is `track_header(&Track, TrackHeaderMenu)` (the handlers in one struct, the Swift defaults are `None`).
- `TimelineMenuSpec`, `KeystonesPanelModel`, `KeystoneEaseSource`, `WaveformClipping`, `ToneWaveform`, `DuckCurveSource` and
  `TimelineSideMenus.ruler` are ported. New direct dependencies: `sq-core-graphics` (`animation_side`) and `sq-media` (`WaveformData`).
- `timeline_menu_spec.rs` uses the core's `TimelinePrimaryClipExt::primary_clip` (sq-core-project, new dependency) and
  `timeline_beat_markers::BEAT_MARKER_NAME`. `caption_items` uses `captions_at`; `Clip.extendsToSequenceEnd` reads `extends_to_end_store == Some(true)`.
- `TimelineContextMenu::items` takes sets of ids and a `&CommandMap` (Swift defaults `CommandMap.current`); `items_with_captions`
  is the Swift call with `captionSelection`. `makeSQItems` takes `Rc<dyn Fn>` handlers.
- `KeystonesPanelModel`: `@Observable` becomes `version()`; `keystones()` is `&mut self` (decoded cache); `save` is an `async fn`;
  `on_save_stored` returns a boxed future. `KeystoneEaseSource` shares the model as `Rc<RefCell<..>>` (see OWNERSHIP.md) and
  gets an `IdSource` for the saved curve (Swift `UUID()`).
