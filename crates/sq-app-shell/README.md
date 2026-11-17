# sq-app-shell

The app root of the shared draw UI (Swift `SQAppShell` plus the portable part of the Windows `AppController`).
Design: `docs/rust/session-ui-design.md` sections 1, 2 and 4 (skeleton task K3). No winit, no OS calls.

## Public API
- `App`: owns `EditorSession`, `AppServices`, the panel hosts and the `UiCx`. Live in `UiRoot<App>`; one borrow per call.
  - `App::new(session, AppDeps)`; `drain()` (inbox, engine position, dispatch), `handle(&InputEvent) -> bool`,
    `needs_redraw()`, `frame(width_px, height_px) -> DrawList`, `pointer_shape()`, `accessibility(active)`.
  - `add_host(Box<dyn AppHost>) -> HostId`, `set_host_frame(id, Option<CGRect>)`, `sender() -> Sender<AppMessage>`,
    `status_text()`, `session()/session_mut()`, `services_mut()`, `ui()/ui_mut()`, `set_theme`, `clock()`.
  - Implements `sq_editor_session::SessionRoot`, so session flows take `UiRef<App>`.
- `AppHost`: `sync(&EditorSession)`, `layout(CGRect, &TextMeasure)`, `draw(&mut Canvas, &DrawTheme)`,
  `handle(&InputEvent, &mut HostCx) -> bool`, optional `a11y`, `on_change(Change, &mut HostCx)` (the `onChange` chain),
  `session_event(&SessionEvent, &mut HostCx)` (the session's `on*` hooks). `HostCx` lends `session`, `ui`, `services`
  and `emit(AppEvent)`.
- Platform traits (port of `AppPlatform.swift`): `PanelFileChooser`, `AppPictureSource`, `AppMonitorEngine`,
  `AppMonitorBackend`, `AppScreenSampler`, `AppMagicMasks` (+ `MaskTintPicture`), `AppPointer::shape(&AppPointerFacts)`,
  `AppPicture`, `LUTFileTypes`, `AppPlatform::TRANSCRIPTION_HINT`.
- `ShellFilePicker` (Swift `SQDrawShell`, defined in `sq-draw-shell` and re-exported here): Swift's `async` choosers return `ModalAsk<..>`; `answered(v)` for choosers
  a platform does not offer (the trait's defaults).
- `Headless`: the loop without a window (`turn()` = drain, `poll_frame` outside the borrow, frame if needed; `input`,
  `with`, `handle`, `executor`, `resize`); `AppDeps::headless(clock)`, `AppServices::headless()`, `CancelAllFiles`.

Notes and pending pieces: `PORTING-NOTES.md`. Check: `cargo xtask check sq-app-shell`.
