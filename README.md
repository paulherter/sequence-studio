<div align="center">

<img alt="Sequence Studio" src="docs/readme/banner.png" width="860">

### The open-source video editor that stays out of your way.

Cut, grade, caption and export short-form video in one fast app. For Mac and Windows.<br>
**Open source (GPL-3.0). The alpha is a free download. No account, no watermark.**

[![Download for Mac](https://img.shields.io/badge/Download-for%20Mac-0a6cf0?style=for-the-badge&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSIyLjYiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI%2BPHBhdGggZD0iTTEyIDN2MTIiLz48cGF0aCBkPSJNNi41IDEwLjUgMTIgMTZsNS41LTUuNSIvPjxwYXRoIGQ9Ik00IDIwaDE2Ii8%2BPC9zdmc%2B)](https://github.com/paulherter/sequence-studio/releases)
[![Report a bug](https://img.shields.io/badge/Report-a%20bug-555555?style=for-the-badge&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgc3Ryb2tlPSJ3aGl0ZSIgc3Ryb2tlLXdpZHRoPSIyLjIiIHN0cm9rZS1saW5lY2FwPSJyb3VuZCIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI%2BPHJlY3QgeD0iOCIgeT0iNyIgd2lkdGg9IjgiIGhlaWdodD0iMTMiIHJ4PSI0Ii8%2BPHBhdGggZD0iTTkuNSA3YTIuNSAyLjUgMCAwIDEgNSAwIi8%2BPHBhdGggZD0iTTggMTFINE04IDE1SDRNMjAgMTFoLTRNMjAgMTVoLTRNNiA1bDIuNSAyLjVNMTggNWwtMi41IDIuNU0xMiAxMXY5Ii8%2BPC9zdmc%2B)](https://github.com/paulherter/sequence-studio/issues/new/choose)

[![Website](https://img.shields.io/badge/Website-getsequencestudio.com-1f2937?style=for-the-badge)](https://getsequencestudio.com)
[![Discord](https://img.shields.io/badge/Discord-join%20the%20chat-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/q6KPQc8WCA)
[![Support](https://img.shields.io/badge/Support-buy%20Pip%20a%20coffee-f59e0b?style=for-the-badge)](https://getsequencestudio.com/supporter/)
[![Roadmap](https://img.shields.io/badge/Roadmap-what's%20next-16a34a?style=for-the-badge)](ROADMAP.md)

[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)
![macOS 26 or later](https://img.shields.io/badge/macOS-26%2B-lightgray.svg)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-lightgray.svg)
![Windows 10/11 x64](https://img.shields.io/badge/Windows-10%2F11%20x64-lightgray.svg)
![Status: Alpha](https://img.shields.io/badge/status-alpha-orange.svg)

[Why](#-why-sequence-studio) &middot; [Features](#-features) &middot; [Install](#-install) &middot; [Status](#-status-alpha) &middot; [Roadmap](ROADMAP.md) &middot; [Community](#-community-and-support) &middot; [Formats](#formats) &middot; [Contributing](#contributing)

<img alt="Sequence Studio editor window" src="docs/readme/shot-hero.png" width="900">

</div>

## ✨ Why Sequence Studio

- **Feels familiar.** A multi-track timeline, Source and Program monitors and Effect Controls, where you expect them.
  If you have edited before, you can start cutting right away.
- **Fast.** Written in Swift. On the Mac the picture is drawn with Metal and decoding is hardware accelerated; on
  Windows it is Direct3D 12 and FFmpeg. The editor stays responsive, also on smaller machines.
- **Uncluttered.** One tool per job, no panels you never open, no upsell. Panels dock, tab and float.
- **Made for short-form.** Rough cut, b-roll, titles, captions, a quick grade, export for vertical and widescreen.
- **One codebase.** The editor UI and engine logic are shared between macOS and Windows, so a feature is written once.
- **Open source, free during the alpha.** Download the alpha builds for free. From the first stable release the ready-made builds are paid. The source stays open under the GPL-3.0.

## 🎬 Features

<table>
<tr>
<td width="50%" valign="top">
<img alt="Timeline" src="docs/readme/shot-timeline.png"><br>
<b>Timeline</b><br>
Multi-track editing with ripple, roll, slip and slide trims, insert and overwrite, razor, markers, nested sequences,
undo for everything and autosave. <b>Fast Cut</b> sequences add a magnetic mode where every edit closes gaps for you.
</td>
<td width="50%" valign="top">
<img alt="Program monitor" src="docs/readme/shot-monitors.png"><br>
<b>Playback</b><br>
Hardware decoding, frame cache and prefetch, proxy generation for heavy footage, and GPU compositing that matches
the export. Monitors can float as their own windows. An optional guide draws a platform UI mock over the Program
monitor.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<img alt="Effect Controls" src="docs/readme/shot-effects.png"><br>
<b>Effects and motion</b><br>
Transform with keyframes and curves, blurs, drop and long shadows, outline, trails, transitions, speed changes and
Lottie animations. Quick Apply puts a favorite effect or preset on the selected clip from a search popup.
</td>
<td width="50%" valign="top">
<img alt="Color" src="docs/readme/shot-color.png"><br>
<b>Color</b><br>
Grading with scopes and LUTs, and Match Color, which matches one clip to the look of another.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<img alt="Masks and tracking" src="docs/readme/shot-masks.png"><br>
<b>Masks, tracking and analysis</b><br>
Shape masks, picture (matte) masks, Magic Mask (click a subject, then track it), point and mask tracking,
stabilization, auto reframe and scene-change detection. Gyro-based stabilization uses
<a href="https://github.com/gyroflow/gyroflow">Gyroflow</a> (optional, Mac). On Windows, Magic Mask and scene
detection are wired up; stabilization and auto reframe are not available yet.
</td>
<td width="50%" valign="top">
<img alt="Titles and captions" src="docs/readme/shot-captions.png"><br>
<b>Titles and captions</b><br>
Text layout with bundled open fonts, caption styles, on-device speech transcription (Apple speech on the Mac,
<a href="https://github.com/ggml-org/whisper.cpp">whisper.cpp</a> on Windows) and subtitle import. Premiere-authored
<code>.mogrt</code> templates can be imported as title templates.
</td>
</tr>
<tr>
<td width="50%" valign="top">
<img alt="Audio" src="docs/readme/shot-audio.png"><br>
<b>Audio</b><br>
Per-track and per-clip effects, noise suppression, silence removal, ducking, loudness normalization on export.
</td>
<td width="50%" valign="top">
<img alt="Export queue" src="docs/readme/shot-export.png"><br>
<b>Export</b><br>
A queue with progress, presets for common social formats, smart rendering where possible and an optional
sidecar <code>.srt</code>. ProRes is Mac only.
</td>
</tr>
</table>

Also in the box: a start window with recents, 9:16 and 16:9 starting points and templates; Premiere Pro project and
effect preset import (experimental, the import report lists what was skipped); Lottie and `.mogrt` import; and an
optional local HTTP/MCP edit API so scripts and agents can read and edit the open project (off by default, see
[docs/EDIT-API.md](docs/EDIT-API.md)).

<div align="center">
<img alt="Start window" src="docs/readme/shot-start.png" width="600">
</div>

## 📦 Install

**Mac:** download the latest `.dmg` from the [Releases](https://github.com/paulherter/sequence-studio/releases) page and
drag Sequence Studio to Applications. You need a Mac with Apple Silicon and macOS 26 or later. Release builds are
Developer ID signed and notarized. If a build is only ad-hoc signed (the release notes say so), right-click the app,
choose **Open** and confirm once.

**Windows:** a Windows 10/11 x64 build comes with the release; until an installer is published you can build it from
source, see [Build from source](#build-from-source).

**Free or paid?** While Sequence Studio is in alpha, the `.dmg` and the Windows build are a free download. From the first
stable release, the ready-made builds (signed and notarized `.dmg`, Windows installer, updates) are paid to fund
development; the price is not set yet. The source code stays open under the GPL-3.0, so you can always build it
yourself, see [Build from source](#build-from-source).

## 🚧 Status: Alpha

Sequence Studio is alpha software. It already does a lot, but most of it has had limited hands-on testing, so expect
rough edges. Project files may change between versions: keep backups and do not use it for paid work yet.

**Mac and Windows share one app.** The editor UI (timeline, monitors, inspector, color, text, library, dialogs) is
drawn by shared code (`SQDraw*`, `SQAppShell`, `SQEditorSession`); only the media, GPU, audio and window backends differ
per platform. On the Mac the shared app is now the default; the older AppKit UI is kept as a fallback (`SQ_APPKIT_UI=1`, see
`scripts/run-shared.sh`); Windows only runs the shared app. A command audit of the two is in
[docs/FEATURE-PARITY.md](docs/FEATURE-PARITY.md).

**Works today**

- Timeline editing, Fast Cut magnetic sequences, undo, autosave, nested sequences, markers, floating panels.
- Playback with hardware decoding, caches and proxies, with the same compositor as the export.
- Effects, keyframes and curves, transitions, speed, Quick Apply, Lottie clips, masks, Magic Mask, tracking, stabilization.
- Color grading with scopes, LUTs and Match Color, titles, captions, on-device transcription, audio effects.
- Export queue with social presets, H.264 and HEVC (and ProRes on the Mac), loudness normalization.
- Premiere Pro project import, `.mogrt` template import, local edit API.

**Not there yet**

- Windows (x86-64, Direct3D 12) is a first alpha for developers: it runs the shared app on FFmpeg media, with Magic
  Mask and whisper.cpp captions. A per-user installer (Setup.exe) exists and Help > Check for Updates reads the GitHub
  releases, but nothing is published there yet and updating means downloading the new Setup.exe. No ProRes, no HDR, no Gyroflow, stabilization or
  auto reframe, and some commands answer "not available in this window yet". Much of it was verified by tests and
  headless runs, not yet by long hands-on use.
- No Intel Mac, Windows on ARM or Linux.
- Premiere import covers a subset of effects and project features.
- Plugin support and a node-based color mode are not started.

See the [Roadmap](ROADMAP.md) for what is coming next and where you can help. Found a bug or missing something? [Open an issue](https://github.com/paulherter/sequence-studio/issues/new/choose). Feedback shapes what gets built next.

## 💬 Community and support

- **Chat:** [join the Discord](https://discord.gg/q6KPQc8WCA) to ask questions, show your edits and meet Pip, the helper bot.
- **Website:** [getsequencestudio.com](https://getsequencestudio.com), with downloads for Mac and Windows.
- **Support the project:** Sequence Studio is made by one person, with no ads and no investors. If you like it, [buy Pip a coffee](https://getsequencestudio.com/supporter/) once or monthly. Supporters get a key and can be named in the credits.
- **What's next:** the [Roadmap](ROADMAP.md) lists what is planned and where you can help.
- **Bugs and ideas:** [open an issue](https://github.com/paulherter/sequence-studio/issues/new/choose).

## Formats

| | |
|---|---|
| Import (video) | iPhone HEVC (SDR and HDR/HLG), H.264, camera footage such as Sony XAVC (S-Log3), ProRes, `.mkv` and `.webm` (HDR on Windows is not done) |
| Import (other) | Still images, animated PNG, Lottie, subtitle files, Premiere Pro projects, `.mogrt` templates |
| Export | H.264, HEVC, ProRes (422, 422 HQ, 4444; Mac only), with presets for social formats |

## Build from source

**Mac:** you need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate
scripts/build.sh            # builds the app, prints errors only
scripts/run-shared.sh       # builds, then starts the app on the shared UI (the Windows code path)
scripts/test.sh [Package]   # tests one package, or all
scripts/check.sh            # tests the packages your change touches, UI lint, app build
```

**Windows:** the app lives in `Windows/SQWinApp` and builds with SwiftPM (Swift 6 for Windows, an FFmpeg LGPL shared
build in `SQ_FFMPEG`). Optional runtime pieces: whisper.cpp for captions (`scripts/win-whisper-setup.sh`) and ONNX
Runtime for Magic Mask (`scripts/win-onnx-setup.sh`). The portable packages test on Windows with
`scripts/win-test.sh <Package> build|test`; `scripts/win-app.sh` builds and runs the app on a Windows PC driven from a
Mac.

Optional: `scripts/build-gyro.sh` builds the Rust Gyroflow engine (needs a Rust toolchain). Without it the app
works; only the Gyroflow stabilization method is unavailable. Test footage is not in the repository: put your own
under `TestMedia/` (git-ignored). More in [CONTRIBUTING.md](CONTRIBUTING.md).

<details>
<summary>Packages</summary>

The engine is split into Swift packages under `Packages/`; `App/` is the Mac app shell, `Windows/SQWinApp` the
Windows app and `Tools/` holds development executables.

| Package | Purpose |
|---|---|
| SQCore | Project model, rational time, timeline edit logic, undo snapshots, project file, autosave. No AVFoundation or AppKit. |
| SQMedia | Media import and probing, demuxing, video and audio decoding, thumbnails, relink. |
| SQRender | Metal compositor, effects and presenter. |
| SQPlayback | Playback clock, frame cache, prefetch, decode scheduling, audio engine. |
| SQExport | Export settings, frame source, writer, loudness normalization. |
| SQAudioFX | Audio effects, including noise suppression (RNNoise). |
| SQAnalysis | Stabilization (including Gyroflow), tracking, Magic Mask, scene detection, reframing. |
| SQProxy | Proxy media generation and cache. |
| SQLibrary | Media library: bins, folder watching, search. |
| SQText | Text layout, titles and bundled fonts. |
| SQTranscribe | Speech transcription (Apple speech, whisper.cpp), captions and subtitle files. |
| SQLottie | Lottie rendering (ThorVG). |
| SQPremiereImport | Reader and mapper for Premiere Pro projects and effect presets. |
| SQEditAPI | Local edit API server for scripts and agents. |
| SQEditorUI | Theme, panel layout, timeline and monitor views of the AppKit app. |
| SQUIKit, SQTimelineUI, SQMonitorUI, SQInspectorUI | AppKit controls and panels (design tokens, icons, timeline, monitors, inspector). |
| SQDrawKit | Portable draw-list UI toolkit: canvas, glyph atlas, controls and renderers (CoreGraphics, Metal, D3D12, software). |
| SQDrawShell, SQDrawTimeline, SQDrawMonitor, SQDrawLibrary | Shared panels drawn with SQDrawKit: menus and dialogs, timeline, monitors, Project and Effects libraries. |
| SQEditorSession | Portable editor session: commands, selection, tools, analysis flows. |
| SQAppShell | The shared app shell and panel hosts both platforms run. |
| SQFrame, SQGPU, SQGPUD3D12 | Neutral frame type, GPU backend protocol (shaders in Slang) and the Direct3D 12 backend. |
| SQMediaFFmpeg | FFmpeg demuxing, decoding and export encoding (Windows). |
| SQOnnx | ONNX Runtime wrapper for subject masks (Windows). |
| TestSupport | Shared helpers for tests (timing). |

</details>

## Contributing

**What is planned next is in the [Roadmap](ROADMAP.md).** Pick something, or tell us what matters to you. Issues and pull requests are welcome, in English. Please open an issue before starting larger work. Read
[CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md) first. Security problems: see
[SECURITY.md](SECURITY.md). Questions and ideas are welcome as issues.

## License and credits

GPL-3.0-or-later, see [LICENSE](LICENSE). Every binary release links the source tag it was built from.
Third-party code, fonts and libraries with their licenses are listed in [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md),
among them Gyroflow (GPL-3.0), ThorVG (MIT), RNNoise (BSD-3-Clause) and the bundled OFL fonts.

Sequence Studio is an independent project. Not affiliated with Adobe; Premiere Pro is a trademark of Adobe. Other
product names are trademarks of their owners and are used for identification only.

Built with help from [Claude](https://claude.com/claude-code), Anthropic's coding assistant.
