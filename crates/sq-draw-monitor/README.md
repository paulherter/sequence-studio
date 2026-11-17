# sq-draw-monitor

The Program and Source monitors on the shared draw UI (Swift `SQDrawMonitor`, tasks DM1-DM3 of
`docs/rust/session-ui-design.md`). Check: `cargo xtask check sq-draw-monitor`.

## What is here
- `MonitorPanel` (`monitor_panel*.rs`): the card (header popups, picture, footer) as an `sq_app_shell::AppHost`.
  `MonitorPanelModel` (+ `MonitorMenus`, `SafeZoneChoice`) holds its state; the Source monitor's player and mark keeper is
  `SourceMonitorCore` (+ `SourceTimelineBuilder`).
- On-picture overlays: `TransformOverlay` (+ masks, motion path, crop, point handles), `GraphicsLayerOverlay`,
  `ZoomEditOverlay`, `StepWindowOverlay`, `MonitorTextField`, `CreateToolDrag`, `SlipTwoUpPicture`, `ColorLoupe`.
- `MeterPanel` and `ScopesPanel` (+ `ScopeImage`, the CPU scope shader that needs `sq-render`'s `ScopeCounts`, and
  `ScopeTraceSettings`).

## How the Swift hooks map
- A hook that reported something (`onSeek`, `onMenu`, `onTransform`, ...) is a variant of an event enum the owner drains:
  `MonitorEvent` (model), `PanelEvent` (panel), `OverlayEvent`, `SourceCoreEvent`, `MeterPanelEvent`, `ZoomEditEvent`.
- A hook that returned a value is a field the owner fills before the call (`type_tool_on`, `hand_tool_on`,
  `create_mode_now`, `loudness`, `MeterPanel::reading`, ...) or a small trait that receives the session
  (`PictureToolsHost`, `GraphicsLayerSource`).
- A hook whose mere presence changed the UI is a flag in `MonitorWiring` / `PanelWiring`.
- Menu rows hold no reference to their owner: they push commands into a `MenuQueue` (see `OWNERSHIP.md`); `sync` / `pump`
  applies them.
- Settings (`UserDefaults`) go through an injected `UiDefaults` store (`MemoryDefaults` until the host gives the real one).

Notes and limits: `PORTING-NOTES.md`.
