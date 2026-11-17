# Architecture

Sequence Studio is a video editor for macOS, Windows and Linux, written in Rust. One Cargo workspace (`crates/`) holds everything; the same code draws the same user interface on both systems, and only small platform crates touch the operating system.

The full map (layers, the App/AppHost flow, event paths, undo and time, threads) is in [docs/rust/ARCHITECTURE.md](docs/rust/ARCHITECTURE.md). Per-crate details are in each crate's `README.md`; the crate list is [crates/README.md](crates/README.md).

## In one screen

```
sequence-studio (binary)  <- sq-platform-mac / sq-platform-win (window, menus, dialogs)
  sq-app-shell, sq-app-hosts       App wires session, services and panels together
  sq-draw-* / sq-timeline-ui / sq-inspector-ui   drawn panels on sq-draw (DrawTheme tokens, wgpu + software renderer)
  sq-editor-session, sq-runtime    one EditorSession owns project, undo, selection, playhead
  sq-playback, sq-export, sq-render, sq-gpu       engine, encode, compositor (shaders written once in Slang)
  sq-media*, sq-library, sq-proxy, sq-analysis, sq-transcribe, sq-translate, sq-onnx   media and AI services
  sq-core-*                        project model and edit logic (pure Rust, no OS code)
```

Dependencies point downward only. The model is value types with snapshot undo, time is rational, and `unsafe` is limited to a few allow-listed crates.

## Where to read next

- Setup and commands: [DEVELOPING.md](DEVELOPING.md). Rules for changes: [CONTRIBUTING.md](CONTRIBUTING.md).
- Design notes: [docs/rust/session-ui-design.md](docs/rust/session-ui-design.md), [docs/rust/render-playback-export-design.md](docs/rust/render-playback-export-design.md).
- Porting from the Swift reference and how parity is checked: [docs/rust/PORTING.md](docs/rust/PORTING.md), [docs/rust/ORACLE.md](docs/rust/ORACLE.md), [docs/rust/PARITY-HARNESS.md](docs/rust/PARITY-HARNESS.md).
