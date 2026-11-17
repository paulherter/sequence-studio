# sq-app-shell: porting notes

## Mapping decisions (K3)
- Swift `AppPointer.Facts` -> `AppPointerFacts` (no nested types in Rust).
- `AppMonitorEngine.player` (a class reference, mutable through the getter) -> `player()` and `player_mut()`.
- `exportFrame(status:)` is `@escaping`: `Box<dyn FnMut(String)>` (UI thread only, no `Send`).
- `AppScreenSampler.ownEyedropper` (optional closure taking a `done` callback) -> `own_eyedropper() ->
  Option<ModalAsk<Option<SQColorValue>>>`: `None` = the host samples per event, otherwise the ask is answered once.
- `MaskTintPicture.image` tuple `(RGBAImage, generation: Int)` -> `MaskTintImage { image, generation }`.
- `ShellFilePicker`'s `async` methods return `ModalAsk<..>`; the Swift protocol-extension defaults (shortcut file and
  export, style kit, folder, file, export location) are trait defaults answering `None` at once.
- Hooks: host hooks are `AppEvent` variants matched in `App::dispatch`; the session's `onChange` chain and `on*` hooks
  reach hosts through `AppHost::on_change` / `AppHost::session_event`, after the call that caused them, repeated until
  nothing is pending (at most 16 rounds, debug assert).

## Pending (owner in brackets)
- `AppMonitorEngine.exportShownFrame` and `AppPicture.rgbaImage`: need `RGBAImage(nv12:)` and `pngData()`
  (SQDrawKit `RGBAImage+PNG.swift`, not ported in sq-draw yet) [sq-draw owner, then AS].
- `AppMonitorBackend.timelineMedia`: `TimelineMediaSource` lives in SQDrawTimeline (sq-draw-timeline) [DT, then AS].
- `AppScreenSampler.loupeUnderPointer`: `ColorLoupe` lives in SQDrawMonitor (sq-draw-monitor) [DM, then AS].
- Routing: `App::handle` routes top-most first over the added hosts; AS1-5 replace it with the hand-ordered chain of
  `AppController.handle` (shell, caption row, text editing, popovers, panels, timeline, screen).
- `App::status_text` lacks the Windows audio-device fallback ("Audio off") [P1-P3].

## Layering
`ShellFilePicker` (and `answered`) now live in `sq-draw-shell` (it is used by `ShellHost`, which sits below this crate);
this crate re-exports both, so implementers see no API change.
