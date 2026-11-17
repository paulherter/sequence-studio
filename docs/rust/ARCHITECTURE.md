# Architecture

Sequence Studio is a video editor for macOS and Windows. The Rust tree is one Cargo workspace; the same code draws the same UI on both systems. This page is the map; each crate's `README.md` has the details. Deeper design notes: `docs/rust/session-ui-design.md`, `docs/rust/render-playback-export-design.md`.

## Layers (bottom to top)

1. **Core** (`sq-core-*`): the project model and edit logic. Pure data and algorithms, no OS, no GPU. Time (`sq-core-time`), the saved model (`sq-core-model`), file format (`-file`), color, audio, masks, effects, graphics, edit operations and history (`-edit`), project handling (`-project`). Also `sq-edit-api` and the Premiere project importers.
2. **Media** (`sq-frame`, `sq-media`, `sq-media-ffmpeg`, `sq-video-hw`, library, proxy, analysis, transcribe, onnx): decoding and probing behind traits (`sq_media::Demuxing`, `VideoDecoding`, `AudioSource`). FFmpeg is the portable backend (a small C++ shim built with `cc`); `sq-video-hw` is the macOS hardware path.
3. **GPU and render** (`sq-gpu`, `sq-render`): wgpu device, compiled shader outputs (written once in Slang, committed per platform) and the compositor that turns layer requests into passes.
4. **Playback** (`sq-playback`, `sq-audio-out`, `sq-audiofx`): the program engine (render thread, decode lanes, cache) and the audio mixer. Audio output goes through `cpal`.
5. **Export** (`sq-export`): frame source, audio source and encoder traits plus the queue; encoding via `sq-media-ffmpeg`.
6. **Session** (`sq-runtime`, `sq-editor-session`): `sq-runtime` is a std-only single-thread async runtime (`UiExecutor`, `WorkerPool`, channels). `EditorSession` owns the project, undo history, selection, playhead and the services around them. It has no UI dependency.
7. **Draw kit** (`sq-draw`, `sq-uikit`, `sq-text`): the one UI toolkit. `DrawList`, `Canvas`, `DrawTheme` (the only source of colors, fonts and spacing), input types, widgets, a wgpu renderer and a software renderer (used by `--ui-shot`).
8. **Panels** (`sq-timeline-ui`, `sq-draw-timeline`, `sq-draw-monitor`, `sq-draw-library`, `sq-inspector-ui`, `sq-draw-shell`): drawn panels built on the draw kit.
9. **Hosts** (`sq-app-shell`, `sq-app-hosts`): `App` ties session, services and panels together; hosts adapt panels to it.
10. **Platform shells** (`sequence-studio`, `sq-platform-mac`, `sq-platform-win`): the winit window, surfaces, input translation, file dialogs, clipboard, accessibility bridge, menu bar (macOS) and borderless window chrome (Windows). Only these crates and the media crates touch the OS.

Dependencies point downward only. `unsafe` is allowed only in `sq-gpu`, `sq-video-hw`, `sq-platform-*` (and narrow FFI modules); `cargo xtask gate` counts it.

## Flow: AppHost, App, AppRoot

- `App` (`sq-app-shell`) owns the `EditorSession`, the services, the hosts and the UI context (`UiCx`). It lives in `UiRoot<App>` (`Rc<RefCell<App>>`) and is borrowed once per input event, frame, inbox drain and task poll; async tasks reach it through weak `UiRef` handles with closure-only access.
- `AppHost` is the trait every panel host implements: `sync(&EditorSession)`, `layout`, `draw(&mut Canvas, &DrawTheme)`, `handle(&InputEvent, &mut HostCx) -> bool`, optional `a11y`, `on_change`, `session_event`.
- `AppRoot` (`sq-app-hosts`) is one `AppHost` that owns the Monitor, Library and Timeline hosts, splits the window between them and routes input to them in a fixed order.
- The binary's loop (`crates/sequence-studio/src/main.rs`): drain the inbox, poll tasks, draw if the app asks for it, set the cursor, then sleep until the next deadline or wake-up. A redraw happens only on input, a state change, an inbox message, a due timer, playback, or an animation request.
- Views pull: every frame, hosts `sync` from the session; models carry version counters so caches know when to rebuild.

## Event paths

- Input: winit event, translated by `input.rs` to an `InputEvent`, then `App::handle`, `AppRoot`, a host, the panel's `handle`. A panel returns `true` when it consumed the event.
- Panel to session: a panel emits its own event enum; its host turns that into session calls and `AppEvent`s; `App::dispatch` handles those after the handler returns.
- Session to UI: edits mark `Change` bits and bump versions; `App::dispatch` drains them and hosts react in `on_change`. Session hooks arrive as `SessionEvent`s.
- Background work: services (proxy, transcribe, analysis, library, export, media prep) post typed messages through a `sq_runtime::channel` into the app inbox, which wakes the event loop and is drained at frame start.
- Dialogs: code asks with `ask()`, which returns a `ModalAsk` future; the task awaits it outside the root borrow and a button click answers it.

## Undo, time and values

- The model is value types. Undo is snapshots: `sq_core_edit::History<Project>`; `session.perform(name, key, |project| ..)` commits one undo step, then updates the engine and notifies the UI. Big lists (`Project.timelines`, `Timeline.tracks`, `Track.clips`) are `CowVec`s, so a snapshot shares storage until something changes.
- Time is rational: `Time { value, timescale }` with integer math (`i128` intermediates). Never use floating point for time.
- Logic paths take a clock or RNG argument instead of reading the system clock.

## Threads

UI thread (winit, session, drawing); one render thread (program engine, compositor); up to four decode lanes; an audio mixer feeding a real-time callback; one lane per export job; a worker pool for probes, thumbnails, waveforms and proxies. Threads talk over channels and mailboxes; decoding is pull-based.

## Not sure yet

- Some session members are still marked pending (see `crates/sq-editor-session/TASKS.md`); the flow above is stable, the list of finished features is not.
- `docs/rust/session-ui-design.md` and `render-playback-export-design.md` describe the plan; where they and the code differ, the code wins.
