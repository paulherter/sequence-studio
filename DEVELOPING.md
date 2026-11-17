# Developing Sequence Studio (Rust tree)

How to set up, build, run and test the Rust workspace on macOS, Windows and Linux. Rules for changes: [CONTRIBUTING.md](CONTRIBUTING.md). Design: [ARCHITECTURE.md](ARCHITECTURE.md).

## Setup

- Rust: `rust-toolchain.toml` pins the toolchain (1.99.0 with rustfmt and clippy); `rustup` installs it on first use.
- Optional tools: `cargo-nextest` (`cargo xtask check` uses it when present, else `cargo test`), `cargo-deny` (used by `cargo xtask gate`).
- A C/C++ compiler (Xcode command line tools on macOS, MSVC build tools on Windows): `sq-media-ffmpeg` and `sq-onnx` compile small C/C++ shims with the `cc` crate.
- FFmpeg (shared build with headers). `crates/sq-media-ffmpeg/build.rs` looks in this order:
  1. `SQ_FFMPEG`: a folder with `include` and `lib`.
  2. Windows: `%USERPROFILE%\ffmpeg\ffmpeg-master-latest-win64-lgpl-shared`.
  3. `pkg-config` (macOS: `brew install ffmpeg pkg-config`).

  Without FFmpeg everything still builds with a stub shim; decoding and encoding then fail at run time.
- ONNX Runtime is loaded at run time (`sq-onnx`). Without it the app starts and the ML features report "unavailable". `cargo xtask package` (Mac) and `packaging/windows/build-installer.ps1` (PC) fetch the pinned runtime (1.24.4, sha256 checked) into a cache folder and bundle it (`SQ_ONNXRUNTIME` = own folder instead). The five EdgeTAM ONNX parts come from `SQ_SUBJECT_MASK_MODELS` (never in the repo); the app finds them in `Contents/Resources/SubjectMask` (Mac) or `SubjectMask` next to the exe (PC). Headless check of a package: `SequenceStudio --mask-eval out.txt clip.mp4 --eval-click 0.25,0.5 [--eval-disk x,y,vx,vy,r]` prints load time, ms per frame and IoU against a synthetic disk.
- Windows: install Rust through `rustup` (MSVC toolchain), the Visual Studio Build Tools (C++ workload), an FFmpeg LGPL shared build (for example BtbN `ffmpeg-master-latest-win64-lgpl-shared`, unpacked to `%USERPROFILE%\ffmpeg\...`), and put its `bin` folder on `PATH` before running tests or the app: `$env:PATH += ";$env:USERPROFILE\ffmpeg\ffmpeg-master-latest-win64-lgpl-shared\bin"`. Inno Setup 6 is optional (installer). A GPU with a D3D12 driver is needed for the wgpu paths; `SQ_GPU_ADAPTER` picks one when the ranking is wrong.
- Remote Windows machine from a Mac: some contributors keep the repository on a Mac and run the heavy cargo jobs on a Windows PC. Any file sync plus a remote shell works; the important parts are that the PC has its own `target` folder and that only one cargo runs at a time.
- The Slang compiler (`slangc`) is only needed to change shaders. The compiled outputs are committed in `crates/sq-gpu/shaders/`, so normal builds do not need it.
- Test media is not in the repository and never will be. Keep your own files in a git-ignored folder.

## Build, run, test

Use the `cargo xtask` alias (`.cargo/config.toml`).

| Command | What it does |
|---|---|
| `cargo run -p sequence-studio` | Start the app. An optional `.sqproj` path opens that project; without one the start window shows. `SQ_FONTS` overrides the font folder. |
| `cargo xtask check` | `fmt --check`, `clippy --all-targets -D warnings`, tests for the whole workspace. |
| `cargo hakari generate && cargo hakari manage-deps` | Run after you add or change a dependency or its features: `workspace-hack/` unifies feature sets so wgpu, serde and others compile once. `cargo xtask check` runs `cargo hakari verify` (install: `cargo install cargo-hakari`). Config: `.config/hakari.toml`. |
| `cargo xtask check <crate>` | The same for one crate, for example `cargo xtask check sq-core-time`. Run this before you call a change done. |
| `cargo xtask gate <crate>` | `check`, plus an `unsafe` count (only allow-listed crates may use it), `cargo deny` when installed, and the crate's oracle comparison when `oracle/<crate>/run` exists. |
| `cargo xtask shaders [--spirv]` | Rebuild the committed shader outputs with `slangc` (`SQ_SLANGC` names the binary; DXIL needs Windows, `SQ_DXC_DIR` names the DXC folder). |
| `cargo xtask package [--sign] [--notarize] [--dmg] [--no-smoke]` | macOS: build `target/package/Sequence Studio.app`. Ad-hoc signed unless `--sign`. See `packaging/macos/README.md`. |

`SQ_NICE=<n>` runs cargo under `nice -n <n>` on macOS and Linux, which keeps a busy machine usable.

While iterating, `cargo check -p <crate>` and `cargo test -p <crate> <filter>` are faster.

### Headless and benchmark modes (no window)

```
sequence-studio --ui-shot out.png [--size WxH] [--scale S] [project.sqproj]
sequence-studio --a11y-dump out.txt [--size WxH] [project.sqproj]
```
Run them with `cargo run -p sequence-studio -- --ui-shot out.png --size 1440x900` (extra flags for `--ui-shot`: `--scale`, `--playhead <seconds>`, `--select <clip>`, `--page edit|color`, `--click x,y`).
`--ui-shot` renders one frame with the software renderer into a PNG (default size 1440x900, scale 1). `--a11y-dump` writes the accessibility tree of one frame, one `role<TAB>label` line per node. `cargo xtask package` uses `--ui-shot` as a smoke test; both are handy to check a UI change without a window. Parsing and defaults: `crates/sequence-studio/src/cli.rs`.


Benchmark and check modes (all write a text report to the given path; run them with `--release` for real numbers):

| Mode | What it does |
|---|---|
| `--play-bench out.txt [--size WxH] project.sqproj` | Plays the project for a few seconds through the real engine and the UI frame loop; writes frames per second and UI frame times. |
| `--engine-bench out.txt clip.mp4` | Plays one clip through the Program engine without a window: frames, drops, monitor upload, CPU per picture, scrub latency. Numbers and method: `docs/rust/PERF-NOTES.md`. Variables: `SQ_BENCH_CLIP`, `SQ_BENCH_NO_PACING`, `SQ_FORCE_SW_DECODE`. |
| `--present-check out.txt clip.mp4` | Scrubs and plays through the real engine and window picture path and compares the presented picture with a software ground truth from the platform decoder. |
| `--mask-eval out.txt clip.mp4 --eval-click x,y [--eval-disk x,y,vx,vy,r]` | Loads the Magic Mask model, tracks a click, prints load time, ms per frame and IoU against a synthetic disk. Needs the ONNX Runtime and the EdgeTAM parts (`SQ_SUBJECT_MASK_MODELS`). |

Export without a window (same pipeline as the Export sheet: preset settings, `ExportQueue`, FFmpeg encoder; the same on Mac and Windows):

```
sequence-studio project.sqproj --export out.mp4 [--preset "<name>"] [--range in,out] [--size WxH] [--hdr hlg|pq] [--no-hardware]
sequence-studio --list-presets
```
It exports the project's active sequence, prints `export <frames> frames ...` and `progress N%` lines, then one JSON line `{"file","frames","seconds","codec","size_bytes"}` (`seconds` is the wall time of the export). Exit code 0, or 1 with the sheet's text (`Export failed: “name”: why`). `--preset` takes a name from `--list-presets` (or its id, case does not matter); without it the sheet's default for the sequence is used. `--range` is in and out in seconds, `--hdr` needs an HEVC preset. The file extension must match the preset (`.mp4`, `.mov`, ...). Code: `crates/sequence-studio/src/export_cli.rs`.

### Parity harness (Mac against Windows, and against the Swift app)

- Picture parity: `SQ_PARITY_OUT=<dir> cargo test -p sq-render parity_dump -- --nocapture` renders a fixed card (and optionally one real frame, `SQ_PARITY_NV12=<file>`) through the real compositor and Present pass on this machine's GPU; run it on each machine and compare the folders with `scripts/parity-compare <dirA> <dirB> [threshold]`. Last result: Metal against D3D12, at most 1/255 difference. Details: `docs/rust/PARITY-HARNESS.md`.
- Behavior parity against the Swift app: reference outputs ("oracle") recorded from the Swift code live in `oracle/<crate>/golden`; tests compare Rust output to them. Method and re-recording rules: `docs/rust/ORACLE.md`. Verify with numbers against the Swift reference, never by eye.

### Logging and caches

- `SQ_LOG=error|warn|info|debug` (default `info`) sets the level of the rolling log in `<support folder>/Logs`; `debug` adds open-to-first-picture milestones and why a frame was not presented. `SQ_PERF=1` prints performance counters. Crash reports are written next to the log.
- The support folder is `~/Library/Application Support/Sequence Studio` on macOS and `%APPDATA%\Sequence Studio` on Windows (`crates/sequence-studio/src/paths.rs`). It holds `prefs.json`, autosaves, logs, crash reports and the Library stores.
- Caches: waveform disk cache (1 GiB default, `SQ_WAVEFORM_CACHE=0` turns it off), Library preview thumbnails and proxies under the cache folder chosen in Preferences > Media, downloaded models (`SQ_TRANSLATE_MODELS`, `SQ_WHISPER_MODELS`, `SQ_SUBJECT_MASK_MODELS` override the folders), and the packaging download cache (`SQ_BUILD_CACHE`; ONNX Runtime). Deleting any cache folder is safe; it refills.

### Packaging

- macOS: `cargo xtask package` (release build, bundle, bundled FFmpeg/ONNX libraries with rewritten install names, signing, smoke test). Developer ID signing and notarization read their identity from `SQ_SIGN_ID` and `SQ_NOTARY_PROFILE`; credentials never go into the repository.
- Windows: `packaging/windows/build-installer.ps1` stages the release build into a zip (and an installer when Inno Setup is present); `packaging/windows/test-installer.ps1` installs and starts it. Signing reads `SQ_WIN_CERT_PFX` and `SQ_WIN_CERT_PASSWORD`.
- Both packages carry `LICENSE`, `LICENSE-ADDITIONAL-TERMS.md` (GPL-3.0 section 7 terms), the FFmpeg LGPL notice and license text (`packaging/licenses/`) and the third-party lists. Packaging stops when the FFmpeg build was configured with `--enable-gpl` or `--enable-nonfree`: use an LGPL shared build (`SQ_FFMPEG`). After a dependency change regenerate the crate list: `cargo metadata --format-version 1 --locked > meta.json && scripts/gen-third-party-crates.py meta.json` (no cargo plugin needed).

## Repository layout

Crates live under `crates/`; the Cargo workspace is the root `Cargo.toml` (`members = ["crates/*"]`). External dependencies are pinned once in the root `[workspace.dependencies]`; crates use `dep.workspace = true`. Crate list and status: `crates/README.md`, per-crate `README.md`.

| Group | Crates |
|---|---|
| Core (no OS code) | `sq-core-time`, `-model`, `-file`, `-color`, `-audio`, `-masks`, `-effects`, `-graphics`, `-edit`, `-project`; `sq-edit-api`, `sq-premiere-import`, `sq-prproj-reader` |
| Media | `sq-frame`, `sq-media`, `sq-media-ffmpeg`, `sq-video-hw`, `sq-library`, `sq-proxy`, `sq-analysis`, `sq-transcribe`, `sq-onnx`, `sq-lottie` |
| GPU and render | `sq-gpu`, `sq-render` |
| Audio and playback | `sq-audiofx`, `sq-audio-out`, `sq-playback` |
| Export | `sq-export` |
| Session | `sq-runtime`, `sq-editor-session` |
| Draw UI | `sq-text`, `sq-uikit`, `sq-draw`, `sq-timeline-ui`, `sq-draw-timeline`, `sq-draw-monitor`, `sq-draw-library`, `sq-inspector-ui`, `sq-draw-shell` |
| Hosts and app | `sq-app-shell`, `sq-app-hosts`, `sequence-studio` (binary) |
| Platform shells | `sq-platform-mac`, `sq-platform-win` |
| Tooling | `xtask` |

Other folders: `oracle/` (reference outputs per crate, see `docs/rust/ORACLE.md`), `packaging/`, `docs/`, `spikes/` (early experiments), and the older Swift tree (`App/`, `Packages/`), which stays out of the public repository. The map of how the crates fit together is [ARCHITECTURE.md](ARCHITECTURE.md).

## Not sure yet

- Whether `cargo-nextest` should become a hard requirement.
- The Windows installer has had one end-to-end run on the test PC, not on a clean machine.
- Linux builds and ships as an AppImage (`cargo xtask package`, `scripts/linux-deps.sh` fetches FFmpeg and the AppImage tool); other distributions' packages are not provided.
