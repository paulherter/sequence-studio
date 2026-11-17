# sq-draw-monitor porting notes

## Mapping decisions
- No stored session: `SourceMonitorCore`, the graphics layer overlay and the caption routing receive `&EditorSession` /
  `&mut EditorSession` per call. `MonitorPanel` gets it through `HostCx` in `AppHost::handle` and `sync`.
- `MonitorPanel::sync` applies queued menu picks and refreshes the format switcher; `pump(&mut EditorSession)` applies the
  format / sequence picks (they write the session) and is called after every handled event and by the owner after a menu row ran.
- `AppHost::draw` has no `UiCx`: the draw pass keeps a `MonitorPanel::draw_cx` whose `requests.caret` (timecode field, text
  field) the owner copies to its `UiCx` after the frame.
- The key map tips read `MonitorPanel::key_map` (taken from `CommandMap::current()` when the panel is made) instead of the
  global `CommandMap.current` on every move.
- Settings: `MonitorPanelModel`, `MeterPanel` and `ScopeTraceSettings` own a `Box<dyn UiDefaults>` (`MemoryDefaults` by
  default). Swift's `ScopeTraceSettings.shared` singleton and its `didChange` notification are a per-panel value with a
  `version()` counter; the owner shares one value by setting the same intensity on every panel.
- `AspectFrame` has no raw values in `sq-draw`; the remembered setting uses the Swift raw strings (`aspect_frame_raw`).
- `SafeZoneChoice` is ported here because `sq-core-edit/src/safe_zone_choice.rs` is still empty (`shortcut:` comment in the file).
- `SourceMonitorCore` runs the Project mark rules on a scratch project holding only this clip's marks (`shortcut:` comment).
- Async scope binning and picture rendering (`ScopesPanel`) run on the calling thread (`shortcut:` header comment): the
  Swift tests `renderImages must not draw inline` and `settle()` are not ported; the key check (redraw only when size, kind,
  intensity or counts changed) is.
- `ScopeImage` and its graticule test against `cbcr` live here because they need `sq-render` (`scope_image.rs`).

## Not ported (Mac only)
- `MonitorPanelModel.dragItem` (an `NSPasteboardItem`), `AngleTile.image` (a `CGImage`), the `viewItems` argument source of the
  Mac renderer (`option_items(view_items)` still takes them), `SourceMonitorCore.onCommand` (never called inside the class),
  and the `#if os(macOS)` `onZoomChange` that sets `engine.viewerZoom`.

## Swift quirks kept
- `MeterStripTests.labelClickSolosAltClickMutes` probes bar 1 at x + 18, which is bar 0's inclusive edge
  (`bar_at_x`: `x <= bx + 6 + 4`); the Rust test probes at the bars' own 10 pt pitch.
- `f64::clamp` replaces Swift's `min(max())` in a few clamps (waveform peaks, `saturate`, view scale); NaN stays NaN there.
- `TextEditState` holds `char`s (see `sq-draw` notes): the text field's caret counts `chars()`, not graphemes.

## Escalations
None.
