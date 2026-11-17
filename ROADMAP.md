# Roadmap

Where Sequence Studio stands and what comes next. This page is the one place for planned work, in roughly the order it
will happen. Feedback and ideas are welcome in [Discord](https://discord.gg/q6KPQc8WCA) or as a
[new issue](https://github.com/paulherter/sequence-studio/issues/new/choose). To build something yourself, open an
issue first so nobody works twice on the same thing, then follow [CONTRIBUTING.md](CONTRIBUTING.md).

## Current state

**0.2.0 Alpha** is the first release of the Rust app for Mac, Windows and Linux. It replaces the earlier Swift app
(0.1.x), which was Mac and Windows only. One codebase draws the same editor on all three systems.

- Mac: Apple Silicon, macOS 26 or later. Windows: 10 or 11, x64. Linux: x86-64 with a Vulkan driver (AppImage).
- Editing, playback, effects and keyframes, color, titles and captions, audio, export and Premiere Pro project import
  work on all three systems. The full list is in the [README](README.md#-features) and the
  [manual](docs/manual/01-getting-started.md).
- Updating is manual: download the new installer, AppImage or disk image (Help > Check for Updates tells you when one is
  out). There are no release channels yet.

## Known problems

- **Experimental features.** Magic Mask, mask and point tracking, stabilization (including Gyroflow) and auto reframe
  have had little hands-on testing. Results vary with the footage.
- **The Windows installer is not code-signed.** Windows may show a SmartScreen warning ("Windows protected your PC"); see
  [Troubleshooting](docs/manual/12-troubleshooting.md).
- **Windows and Linux are new.** They have had less hands-on testing than the Mac. Some commands answer "not available
  on this computer yet". Hardware encoding depends on the graphics driver and falls back to software.
- **HDR.** HDR export on Windows was checked on one PC; on Linux it is not verified.
- **Not yet tried over long sessions on a real device:** dragging files in from the system, trackpad feel, screen
  readers (VoiceOver, Narrator), audio sync with external devices.
- **Voiceover from Text on Linux** needs `espeak-ng` from your package manager.
- **Premiere import** covers a subset of effects and project features. The import report lists what was skipped.

## Next

| Item | What it means | Good first step |
| --- | --- | --- |
| **Local MCP server** | One click connects Claude or another AI agent to the app, so it can cut, trim, caption and export for you. Runs on your own computer, no cloud. | Design the tool list on top of the edit API ([docs/EDIT-API.md](docs/EDIT-API.md)) |
| **Windows and Linux parity** | Bring stabilization (Gyroflow), auto reframe, HDR and hardware encoding on Windows and Linux to the level of the Mac, with the same behavior. | Pick one feature, run it on your system and report or fix what differs |
| **Windows and Linux polish** | More hands-on testing of the shared app: scrolling feel, the remaining "not available on this computer yet" commands. | Run it, report what feels different from the Mac |
| **Update channels** | Stable and test releases, so you can choose to get early builds in the app. | |
| **Release builds in the cloud** | Build the Windows installer and the other packages on GitHub Actions, so a release does not depend on a local machine. | |

## Later

| Item | What it means |
| --- | --- |
| **Signed installers** | Code-sign the Windows installer so it shows no SmartScreen warning. |
| **Plugin support** | A documented API for third-party effects, transitions and tools. |
| **Preset and effects library** | Shareable presets and title templates, and more complete MOGRT import. |
| **Node-based color** | An optional node view on top of the current color panels: a scene-referred working space; a node graph (correctors with their own key, parallel and layer mixers, splitter and combiner, compound and shared nodes); grade levels before the clip, per clip, after the clip and for the whole timeline; grade templates with switchable nodes and controls; CDL and LUT import that lists what could not be carried over; log inputs; film emulation; color tools for the local MCP server. |
| **More Premiere import** | More effects and project features when you open a `.prproj`. |
| **Intel Mac, Windows on ARM, Linux on ARM** | Not started. A port needs someone who runs that system daily. |

## Still being researched

We compare with other editors to find out what is really missing. If you edit for a living and something blocks you,
that is the most useful thing you can tell us.
