---
title: Developers
chapter: developers
order: 1
code: Cargo.toml, DEVELOPING.md, CONTRIBUTING.md, crates/sq-gpu/src/gpu, crates/xtask
---

## For users

Sequence Studio is open source (GPL-3.0-or-later) and written in Rust. This page is the map for contributors. Setup, every command and the rules for changes are in [DEVELOPING.md](../../DEVELOPING.md) and [CONTRIBUTING.md](../../CONTRIBUTING.md); they are the source of truth, this page summarizes them.

### Build and run

- The Rust toolchain is pinned by `rust-toolchain.toml` (`rustup` installs it on first use).
- FFmpeg is needed for real decoding and encoding. Without it everything builds with a stub and decoding fails at run time. ONNX Runtime is loaded at run time; without it the app starts and the ML features report "unavailable".
- `cargo run -p sequence-studio` starts the app. An optional `.sqproj` path opens that project.
- `cargo xtask check <crate>` runs `fmt --check`, `clippy -D warnings` and the tests for one crate. Run it before you call a change done.
- `cargo xtask check` without a crate does it for the whole workspace; `cargo xtask gate <crate>` adds an `unsafe` count, `cargo deny` and the oracle comparison.

### Rules in short

- Tests first for edit logic. No `unwrap`, `expect`, `todo!` or `dbg!` in non-test code.
- `unsafe` is allowed only in a few crates (`sq-gpu`, `sq-video-hw`, `sq-platform-*` and the FFI modules named in their READMEs).
- Time is rational, never `f64`. American English everywhere.
- No new dependencies without an issue first; only GPL-3.0-or-later compatible licenses.
- No footage, secrets or certificates in the repository.
- A user-visible change updates the matching page in `docs/wiki/` in the same change.

## For developers

The Cargo workspace is the root `Cargo.toml` (`members = ["crates/*", "workspace-hack"]`, edition 2024). External dependencies are pinned once in `[workspace.dependencies]`; crates use `dep.workspace = true`. `workspace-hack/` unifies feature sets (run `cargo hakari generate && cargo hakari manage-deps` after a dependency change).

### Crate map

Core (no OS code):

| Crate | What it is |
|---|---|
| `sq-core-time` | Rational time, frame rates, keyframe tracks and easing, ids, text helpers. The bottom layer. |
| `sq-core-model` | The project model: `Project`, `Timeline`, `Track`, `Clip` and every saved type, with serde coding. |
| `sq-core-file` | `.sqproj` reader and writer. |
| `sq-core-edit` | Edit operations, magnetic timeline, history, snapping, nesting, angles and the playback model. |
| `sq-core-effects` | Effect evaluation, transitions, presets and sequence conform logic. |
| `sq-core-color` | Tone curves, Auto Tone, the Zone Board, film looks, the Pro grade graph, camera color spaces. |
| `sq-core-audio` | Audio gain, roles, ducking, silence and filler cuts, voiceover helpers, caption editing logic. |
| `sq-core-graphics` | Graphics, title templates, text animators, shape and format variants. |
| `sq-core-masks` | Mask, Magic Mask, Subject mask, stabilizer, rolling shutter, anonymize and perspective tilt logic. |
| `sq-core-project` | Recovery, templates, relink, keymaps, command tables and render cache planning. |
| `sq-edit-api` | Local edit API (state, commands, discovery) for tools and agents. |
| `sq-premiere-import`, `sq-prproj-reader` | Premiere project import and its container reader. |

Media, render and playback:

| Crate | What it is |
|---|---|
| `sq-frame` | Frame buffers and pixel formats shared by decode, render and export. |
| `sq-media` | Media probing, demux and decode seams, WebM/Vorbis readers. |
| `sq-media-ffmpeg` | FFmpeg demux, decode and encode behind `sq-media`'s traits (C++ shim built with `cc`). |
| `sq-video-hw` | macOS VideoToolbox decode with zero-copy import into wgpu; a stub elsewhere. |
| `sq-gpu` | GPU device layer on wgpu: shader outputs, fixed binding layout, pipelines, frames, readback. |
| `sq-render` | Render graph and compositor: layer requests to GPU passes, color pipeline, effects, scopes; CPU references as test oracle. |
| `sq-playback` | Playback engine: render thread, frame cache, audio feeder, scrub, shuttle. |
| `sq-audiofx`, `sq-audio-out` | Audio DSP; audio output stream, ring buffer and clock. |
| `sq-export` | Export settings, presets, queue, loudness, stems, interchange formats, encode pipeline. |
| `sq-library`, `sq-proxy`, `sq-analysis` | Media library; proxy planning and queue; stabilization, mattes, magic mask, subject tracking. |
| `sq-transcribe`, `sq-translate`, `sq-onnx` | Speech to text and caption readers; offline translation; ONNX Runtime wrapper (loaded at run time). |
| `sq-lottie`, `sq-gyroflow` | Lottie model and renderer seam; Gyroflow stabilization. |
| `sq-text` | Own text engine: font parsing, layout, glyph raster, text effects. |

Session, UI and app:

| Crate | What it is |
|---|---|
| `sq-runtime` | Async runtime of the UI side: single-threaded executor, worker pool, channels. |
| `sq-editor-session` | The editing session: one project with undo history, the active sequence, playhead, selection and the Program engine. Every edit goes through it. |
| `sq-uikit` | UI kit models: tokens, menus, focus routing, fonts, accessibility text. |
| `sq-draw` | Foundation of the shared draw UI: draw list, canvas, theme, glyph atlas, input, scroll physics, the `Panel` trait and both renderers. |
| `sq-timeline-ui`, `sq-draw-timeline` | Portable timeline logic; the drawn timeline panel. |
| `sq-draw-monitor`, `sq-draw-library`, `sq-inspector-ui`, `sq-draw-shell` | Program and Source monitors; Library and Effects panels; inspector panels; the menu bar, dialogs and key route. |
| `sq-app-shell`, `sq-app-hosts` | The app root (`App`) and the panel hosts that route events. |
| `sequence-studio` | The application binary: opens a window around the headless `App` and draws it with the wgpu renderer. |

Platform and tooling:

| Crate | What it is |
|---|---|
| `sq-os` | The system the app runs on and what differs between systems, as pure values. |
| `sq-platform` | One facade over the system services, so the app has no `cfg(target_os)` for them. |
| `sq-platform-mac`, `sq-platform-win`, `sq-platform-tts`, `sq-platform-vision` | System services: macOS only, Windows only, text to speech, Apple Vision registration. |
| `sq-trash` | The system Trash for all three systems. |
| `sq-fault-text` | Allocation-free building blocks of a native fault report. |
| `sq-installer`, `sq-setup-engine` | The setup program and the logic under it. |
| `xtask` | `cargo xtask <check, gate, hook, driver>`: repository automation. |

### The three GPU backends

`sq-gpu` runs on wgpu and picks the backend by system (`crates/sq-gpu/src/gpu/mod.rs`, `backend()`): D3D12 on Windows, Metal on macOS, Vulkan on everything else (Linux). The adapter choice tries discrete, then integrated, then virtual adapters, with a software adapter last; `SQ_GPU_ADAPTER=<part of the name>` forces one. Shaders are written once in Slang (`crates/sq-gpu/shaders-src`); the compiled outputs are committed in `crates/sq-gpu/shaders/`, so a normal build does not need `slangc`. `cargo xtask shaders` rebuilds them. The same code runs on every backend; picture parity between Metal and D3D12 is checked to at most 1/255 per channel (`crates/sq-gpu/README.md`).

### Tests and gates

Tests live beside the code. Reference data ("oracle") recorded from the original Swift app lives in `oracle/<crate>/golden`; tests compare the Rust output to it. `cargo xtask check <crate>` is the definition of done for a crate; before a merge also run it for the crates that depend on yours. GPU tests skip with a note when no adapter exists.

Extension points: add a crate as `crates/sq-foo` and register it in the root `[workspace.dependencies]` as `sq-foo = { path = "crates/sq-foo" }`; new UI goes into the draw-UI crates with `DrawTheme` tokens only.

## For AI agents

- **Workspace**: root `Cargo.toml` (the workspace version lives there), edition 2024, license `GPL-3.0-or-later`, `publish = false`. Toolchain pinned in `rust-toolchain.toml`. The command alias `cargo xtask` is in `.cargo/config.toml`.
- **Commands**: `cargo run -p sequence-studio` (app); `cargo xtask check [<crate>]` (fmt, clippy `-D warnings`, tests); `cargo xtask gate <crate>`; `cargo xtask shaders` (writes the SPIR-V and other backend outputs); `cargo xtask package [--sign] [--notarize] [--dmg] [--no-smoke]` (macOS; `--notarize` needs `--sign`); `cargo check -p <crate>` and `cargo test -p <crate> <filter>` while iterating.
- **Headless modes** of the binary (parsing in `crates/sequence-studio/src/cli.rs`): `--ui-shot out.png [--size WxH] [--scale S]`, `--a11y-dump out.txt`, `--play-bench [--page color]`, `--engine-bench`, `--present-check`, `--mask-eval`, and `project.sqproj --export out.mp4 [--preset "<name>"]` with `--list-presets` (`export_cli.rs`).
- **Environment**: `SQ_FFMPEG` (FFmpeg folder with `include` and `lib`), `SQ_FONTS`, `SQ_GPU_ADAPTER`, `SQ_LOG=error|warn|info|debug`, `SQ_PERF=1`, `SQ_NICE=<n>`, `SQ_WHISPER_MODELS`, `SQ_TRANSLATE_MODELS`, `SQ_SUBJECT_MASK_MODELS`, `SQ_NO_EXTERNAL_OPEN` (set by `.cargo/config.toml` so tests never open a mail client, browser or file manager).
- **Lints (deny)**: no `unwrap`, `expect`, `todo!`, `unimplemented!`, `dbg!` outside tests; `Rc::clone(&x)` instead of `x.clone()`; `unsafe` only in `sq-gpu`, `sq-video-hw`, `sq-platform-*` and the FFI modules of `sq-audiofx`, `sq-transcribe` and `sq-onnx`.
- **Invariants**: time is rational (`sq_core_time::Time`), never `f64`; core crates have no OS code; platform differences go behind `sq-platform` or `sq-os`; a UI change is made once in the shared draw UI; edit logic gets a test first.
- **Commits**: small, English, imperative, explicit paths (`git add <paths>`, not `git add -A`). A user-visible change updates the matching page in `docs/wiki/`.
- **Where to read**: per-crate `README.md`, `DEVELOPING.md`, `CONTRIBUTING.md`, `CONTRIBUTING-AI.md`, `ARCHITECTURE.md`, `docs/rust/ORACLE.md` (oracle method).
