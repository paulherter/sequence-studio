---
title: Troubleshooting
chapter: troubleshooting
order: 1
code: crates/sq-fault-text, crates/sequence-studio/src/crash.rs, crates/sequence-studio/src/start_failure.rs, crates/sequence-studio/src/paths.rs
---

## For users

Fixes for the most common problems, where to find logs, and how to report a bug.

### The Mac says the app cannot be opened

Sequence Studio needs a Mac with Apple Silicon and macOS 26 or later. Older Macs and Intel Macs are not supported.

If a build is only ad-hoc signed, right-click the app, choose Open, and confirm once.

### Windows shows a SmartScreen warning

The Windows installer is not signed yet, so Windows may say "Windows protected your PC".

1. Click More info.
2. Click Run anyway.

The installer installs for your user only and does not need administrator rights. Sequence Studio for Windows needs Windows 10 or 11 (64-bit). Some commands may answer "... is not available on this computer yet".

### The AppImage does not start on Linux

1. Make the file executable (`chmod +x`).
2. Check that your system has a Vulkan graphics driver and glibc 2.35 or newer (Ubuntu 22.04 or a newer distribution). Older distributions cannot run the AppImage.
3. Start it from a terminal to read the error. If the program or one of its bundled libraries cannot start, a dialog (when your desktop has `zenity`, `kdialog`, `xmessage` or `notify-send`) and the log name the error `SQS-304`.

For **Voiceover from Text**, install the `espeak-ng` package.

### An error window appears when Sequence Studio starts

When something stops the start, Sequence Studio shows a window instead of closing silently. It names an error code (for example `Error SQS-201`), says in one sentence what went wrong, and shows the details.

- **Copy details** puts the code, the version, your system and the log path on the clipboard. Paste it into a bug report.
- **Open log** opens the log file. On the Mac it is `~/Library/Logs/Sequence Studio/sq.log`, on Windows `%APPDATA%\Sequence Studio\Logs\sq.log`, on Linux `~/.local/share/Sequence Studio/Logs/sq.log` (under `$XDG_DATA_HOME` when that is set).
- **Try Again** starts Sequence Studio again. **Continue** appears when the problem was worked around (a damaged settings file was set aside, a project could not be opened) and the app can go on.

| Code | Meaning | What to do |
|---|---|---|
| SQS-101, 102, 103 | The window system did not answer or the window could not be created. | Start it from a desktop session. On Linux you need Wayland or X11. Restart the computer if it keeps happening. |
| SQS-201, 202, 203 | No graphics adapter, an adapter that is too old, or a driver that refused to start. | Install or update the graphics driver. |
| SQS-204, 205 | The display cannot show GPU pictures, or the driver could not build the drawing programs. | Update the graphics driver. Remote and headless desktops are not supported; inside a nested Weston session start Weston with `--renderer=gl`. |
| SQS-301, 302 | A video library is missing, blocked by a virus scanner, or from another version. | Install Sequence Studio again. |
| SQS-303 | The font files are missing. | Install Sequence Studio again. |
| SQS-304 | Linux AppImage: the program or a bundled library cannot start. | Download the AppImage again. |
| SQS-401 | The settings folder cannot be written. | Free up disk space or fix the folder's permissions. |
| SQS-402 | The log folder cannot be written; the log goes to the temp folder. | Nothing, the app starts. |
| SQS-403 | The settings file was damaged. It was kept as `prefs.json.damaged-<number>` and the defaults are used. | Press Continue. |
| SQS-404 | The project you opened could not be read. | Press Continue and open a backup of the project. |
| SQS-901, 902, 999 | An unexpected error, or the last start never finished. | Copy details and report it. |

### Playback is slow or drops frames

1. Open Settings > Playback and set Preview Quality lower (Auto does this on computers with 8 GB of memory or less).
2. Turn on Background Work > Make proxies while you edit. Proxies are light copies of heavy clips. They are used while you edit; export uses the full files.
3. Make sure the proxy cache has room (Settings > Media > Cache Size).
4. Watch for the amber dot in the Program monitor. It tells you frames were dropped.
5. Close other apps that use the GPU or disk.

### Media is offline

Choose File > Project > Reconnect Media… and pick the folder that holds your files.

### Transcription does not start

- The speech model (about 249 MB) downloads the first time you transcribe, on every system. Check your connection and your free disk space, then choose Try Again. See [Titles and Captions](text-and-subtitles.md).

### Export fails

Open the Export Queue to read the reason after "Failed". Check free disk space and that the folder can be written. See [Export](export.md).

### Find the logs

Logs and crash reports stay on your computer; Sequence Studio sends nothing.

Choose Help > Reveal Logs and Reports. On the Mac the log is in Library/Logs/Sequence Studio in your home folder. On Windows and Linux it is in the Logs folder of the Sequence Studio data folder. Crash reports are in the Crashes folder next to it. See [Settings and updates](settings-and-updates.md#feedback-and-logs).

### Report a bug

1. Open Help > Reveal Logs and Reports and keep the log file close.
2. Tell us what you did, what you expected and what happened. Add your Sequence Studio version, which you see in Help > Check for Updates….
3. Send it:
   - GitHub: https://github.com/paulherter/sequence-studio/issues
   - Discord: https://discord.gg/q6KPQc8WCA
   - Email: info@getsequencestudio.com (Help > Send Feedback… fills in your version and system).

### Not sure yet

- Whether every crash on Windows and Linux leaves a report. An abort that the app raises itself on Windows does not.
- The SmartScreen wording can differ between Windows versions.
- Whether the error window follows the Light theme on every Linux desktop (it reads the system setting where the window system reports it).

Related: [Getting Started](getting-started.md), [Settings and Updates](settings-and-updates.md), [Export](export.md), [Shortcuts](shortcuts.md)

## For developers

### Where things live

| Part | File |
|---|---|
| Crash reports | `crates/sequence-studio/src/crash.rs`: a panic hook writes a plain-text report into `Crashes/` of the support folder; the newest 10 are kept; nothing is sent over the network. |
| Native faults | `sq-platform-win` and `sq-platform-mac` (`install_native`) write a shorter report of the same layout from inside an exception filter or signal handler, using the allocation-free helpers of `crates/sq-fault-text/src/lib.rs`. |
| Start errors | `crates/sequence-studio/src/start_failure.rs` (`StartCode`, shown as `SQS-<number>`) and `error_window.rs` (the window; `native_message` is the fallback). |
| Log folder | `crates/sequence-studio/src/paths.rs` (`log_dir_from`): `~/Library/Logs/Sequence Studio` on the Mac, `Logs` in the support folder elsewhere. |
| Import diagnosis | `crates/sq-media/src/media_diagnosis.rs`. |

### Data flow

1. A panic runs the hook: the report holds the message (cut to 500 characters), the place, a backtrace, the app version, the system and the last log lines. The project is never read and the home folder is replaced by `~` in every line.
2. On the next launch `pending` finds the newest report the user has not dealt with; the user can show or copy it.
3. A start failure becomes one `StartFailure` value (code, step, path, system). Fatal codes show the error window; non-fatal ones offer Continue.

### Tests

`cargo test -p sq-fault-text` and `cargo test -p sequence-studio` (unit tests sit next to `crash.rs`, `paths.rs` and `applog.rs`).

## For AI agents

- Privacy invariant: crash reports and logs stay on the machine; nothing is sent. Help > Report a Problem only opens a pre-filled form that the user sends.
- Crash reports: folder `Crashes/` in the support folder, 10 kept (`KEEP` in `crash.rs`), message cap 500 characters, home folder redacted to `~` (`Buf::redacted` in `sq-fault-text`).
- `sq-fault-text` functions (`Buf::new`, `str`, `raw`, `dec`, `hex`, `redacted`, `stamp`, `iso`, `whole_lines`, `header`) allocate nothing and take no locks; keep it that way, they run inside signal handlers.
- Error codes: `SQS-` plus `StartCode::number()` (`start_failure.rs`). The user table of codes on this page must match that enum; change both together.
- Log path: Mac `~/Library/Logs/Sequence Studio/sq.log`; others `<support>/Logs/sq.log`.
- Commands: `cargo test -p sq-fault-text`; `cargo test -p sequence-studio`.
