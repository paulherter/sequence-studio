---
title: Settings and Updates
chapter: settings-and-shortcuts
order: 1
code: crates/sq-editor-session/src/es10_workspace/settings.rs, crates/sq-editor-session/src/es10_workspace/update.rs, crates/sq-editor-session/src/es10_workspace/storage.rs, crates/sq-draw-shell/src/shell_preferences.rs, crates/sq-draw-shell/src/shell_edit_api.rs, crates/sq-app-hosts/src/edit_api_host.rs, crates/sq-core-project/src/support_policy.rs
---

## For users

Where to change how Sequence Studio works, how updates arrive, how to send feedback, and the optional edit API.

Open Settings with Command-comma (Windows and Linux: Ctrl+comma). There are six pages.

### General

- **Interface Language**: takes effect the next time you start the app.
- **Interface Size** and **Appearance** (Dark or Light), with Background and Contrast sliders.
- **Autosave**: every minute, or every few minutes.
- **Recovery**: offers to restore your work after an unclean quit.
- **Updates**: check for a newer version at launch, and the **Update Channel** (Stable or Nightly).
- **New Text Length**, **Transcription language** and **Auto Language** (runs again in the language the text turns out to be).

### Playback

Preview Quality (Auto starts at full quality, and at half resolution on weaker computers: 8 GB of memory or less, 4 cores or fewer, or an Intel Mac; if playback stays late for about two seconds, Auto drops one step for the rest of the session. A sequence's own Preview Quality in Sequence Settings replaces this while it is open. Export always uses full quality), Frame Cache, Background Work (make proxies while you edit), Preroll and Postroll, Audio Output, Audio Scrubbing, and Dropped Frames (an amber dot in the Program monitor).

### Editing

- New Sequences Start in Normal or Fast Cut.
- Default lengths for video and audio transitions.
- Lists of default effects and transitions, with Restore Factory.

### Audio

De-Click, Live Ducking, Duck Preset and Duck Timing, Crossfade kind and length, J / L Offset, Meter Response and Fade Shape. See [Audio](audio.md).

### Media

What to do with files outside the project (Ask, Copy, Move or Leave), project folder watching, Library folders, cache folder and size, Delete Cache, Scratch Folder, "Use proxies when exporting" (off by default), and the Projects Folder (default: Movies/Sequence Studio on the Mac, Videos/Sequence Studio on Windows and Linux).

The settings search has a **Clear Search** button. A storage folder you chose that no longer exists is marked "(missing)".

### Advanced

Edit API (see below).

### Updates

Sequence Studio checks for a new version at launch if you leave "Check for a newer version at launch" on. It asks one address for the newest version number. Nothing else is sent.

#### Stable and Nightly

Settings > General > Update Channel picks which builds the update check follows. **Stable** is the released versions. **Nightly** is a build made every night: it has the newest changes and can break projects. A new install starts on the channel it was built for; a Nightly build shows "Nightly" after the version in About.

When you pick Nightly, a dialog says "Nightly builds can break projects. Back up your projects before you switch." Choose Switch to Nightly to go on, or Cancel to stay on Stable. Switching back to Stable needs no question. The check then asks the other address, and a Nightly version compares by its date, so a newer nightly counts as an update, and the release of the same number counts as newer than its nightlies.

To check by hand, choose Help > Check for Updates…. You will see one of:

- "Sequence Studio X is the newest version."
- "Version X is available", with Download and Later. Download opens the page for your system (a .dmg on the Mac, an .exe installer on Windows, an .AppImage on Linux).
- "The update information could not be read. Check your connection and try again later."

On Windows you update by downloading and running the new installer; it shows "Update Sequence Studio" and keeps your settings. On Linux you download the new AppImage and run it in place of the old one. On the Mac you replace the app in Applications.

### Feedback and logs

- **Help > Send Feedback…** opens an email to info@getsequencestudio.com with your version, build and system filled in.
- **Help > Reveal Logs and Reports** shows the app log in your file browser. On the Mac it also selects the newest crash report. The log is kept in three rolling files (sq.log, sq.1.log, sq.2.log). On the Mac they are in Library/Logs/Sequence Studio in your home folder. On Windows and Linux they are in the Logs folder of the Sequence Studio data folder (on Windows inside your AppData\Roaming folder, on Linux inside ~/.local/share), next to a Crashes folder.
- **Crash reports** are plain text files in the Crashes folder, on all three systems. After a crash the next start offers to show or copy the newest one. They hold the error, a stack trace, the app version, your system and the last log lines, with your home folder name hidden. They never contain your project, and nothing is sent anywhere. The newest ten are kept.
- Help also links to the Discord, GitHub, and Support Sequence Studio….

### Edit API (off by default)

The Edit API lets scripts and AI tools on your own computer edit the open project. It is off by default.

1. Open Settings > Advanced.
2. Turn on "Allow local tools to edit the open project".

Only programs on your own computer can connect (the local loopback address, localhost), with a key that changes every launch. Each agent edit is one undo step, shown as "Agent: …". The default port is 19790. Most people never need this.

### Not sure yet

- There are no release channels (such as beta) in the app, so this page does not describe any.
- Whether every crash on Windows and Linux leaves a report. An abort that the app raises itself on Windows does not.

Related: [Getting Started](getting-started.md), [Audio](audio.md), [Shortcuts](shortcuts.md), [Troubleshooting](troubleshooting.md)

## For developers

- **Model and storage**: `AppSettings` (`crates/sq-editor-session/src/es10_workspace/settings.rs`) holds General, Playback and Editing fields such as `autosave_interval`, `offer_recovery`, `check_for_updates`, `update_channel`, `onboarding_seen`, `default_quality`. It is stored through the typed `UiDefaults` mirror; a flag is the integer 0 or 1, a list of numbers is comma-separated text, a list of paths is one path per line. Cache, proxy, scratch and projects folders are resolved in `storage.rs` of the same folder.
- **Settings window**: `crates/sq-draw-shell/src/shell_preferences.rs` builds the pages as `ShellForm` rows in a dialog with a sidebar. Stores outside `AppSettings` (language, size, transition defaults, audio role defaults, De-Click, ducking, meter response, fade shape, media defaults, card import) travel in `Extras`; the host applies what it reads from `ShellEvent::SettingsChanged`. What the host knows (output devices, the effect defaults library) comes in `PreferencesHost`; a row whose reader the host lacks is left out. `shell_settings.rs` is the shell's read and write side of the store.
- **Updates**: `UpdateCheck` in `sq-editor-session/src/es10_workspace/update.rs`. The address is `SQ_UPDATE_URL`, else the `sq.updateFeedURL` default, else the address of the chosen `ReleaseChannel` (Stable: the GitHub releases API of the public repository; Nightly: `nightly.json` of the release tagged `nightly`); an empty address turns the check off and nothing touches the network. The answer is either `{"version", "url", "notes"}` or a GitHub release (`tag_name`, `html_url`, `body`, `assets`). The result is an `UpdateOutcome` (`NotConfigured`, `UpToDate`, `Available`, `Failed`). A release counts only with a numeric version and an `https://` download address. Versions compare as dotted numbers, ignoring a leading `v`, a stage word after a space and a suffix after `-` or `+`; with equal numbers a `-nightly.<date>` version is older than the plain release and a later date is newer. The build's own channel is the compile-time `SQ_CHANNEL` (`ReleaseChannel::build`, Stable when unset); the choice is stored as `sq.updates.channel`. The shell reaches it through `ShellFlow::CheckForUpdates` (`shell_flows.rs`) and `ShellHost::update_feed`.
- **Edit API**: the server and its protocol are in `crates/sq-edit-api` (router, HTTP, transactions, diffs, project state, time limits; a network server and a Winsock server). The host side is `crates/sq-app-hosts/src/edit_api_host.rs`: every call is a message to the UI thread answered through a channel. The Advanced page (`shell_edit_api.rs`) shows only when the host provides an `edit_api`.
- **Support entries and reminder rules**: `crates/sq-core-project/src/support_policy.rs`, pure functions with dates and links injected.
- **Tests**: `crates/sq-editor-session/src/es10_workspace/tests/settings.rs` (settings and the update address), tests in `edit_api_host.rs`, and `sq-draw-shell` tests.
- **Extension points**: a new setting is a field and key in `settings.rs` plus a row in `shell_preferences.rs`; a new update source is a new document shape in `UpdateCheck::release`.

## For AI agents

- **Defaults keys**: `sq.api.enabled` (switch), `sq.api.port` (port, default 19790, used when none or an invalid one is stored), `sq.updateFeedURL` (update address). Source: `crates/sq-app-hosts/src/edit_api_host.rs`, `update.rs`.
- **Update address order**: environment `SQ_UPDATE_URL`, then `sq.updateFeedURL`, then the channel's default: `UpdateCheck::DEFAULT_FEED_URL` (`https://api.github.com/repos/paulherter/sequence-studio/releases/latest`) for Stable, `UpdateCheck::NIGHTLY_FEED_URL` for Nightly. Empty means inert; a non-https address is `NotConfigured`.
- **Installer asset suffix**: `.dmg` on the Mac, `.exe` on Windows, `.AppImage` on Linux (`UpdateCheck::installer_suffix`); with no matching asset the release page is the download.
- **Autosave default**: 300 s (`AutosavePolicy::default` in `crates/sq-core-project/src/recovery.rs`).
- **Product folder name**: `Sequence Studio` under every per-user root; the older `SequenceStudio` folder is moved over once (`crates/sq-os/src/app_folders.rs`).
- **Edit API invariant**: off by default; one agent edit is one undo step.
- **Files**: `crates/sq-editor-session/src/es10_workspace/{settings,storage,update}.rs`, `crates/sq-draw-shell/src/{shell_preferences,shell_settings,shell_edit_api}.rs`, `crates/sq-app-hosts/src/edit_api_host.rs`, `crates/sq-core-project/src/support_policy.rs`.
- **Run tests**: `cargo test -p sq-editor-session settings` and `cargo test -p sq-app-hosts edit_api` (heavy builds go through the project's remote wrapper, not the Mac).
