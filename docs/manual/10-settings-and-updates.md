# Settings and Updates

Where to change how Sequence Studio works, how updates arrive, how to send feedback, and the optional edit API.

Open Settings with Command-comma (Windows and Linux: Ctrl+comma). There are six pages.

## General

- **Interface Language**: takes effect the next time you start the app.
- **Interface Size** and **Appearance** (Dark or Light), with Background and Contrast sliders.
- **Autosave**: every minute, or every few minutes.
- **Recovery**: offers to restore your work after an unclean quit.
- **Updates**: check for a newer version at launch.
- **New Text Length**, **Transcription language** and **Auto Language** (runs again in the language the text turns out to be).

## Playback

Preview Quality (Auto uses half resolution on computers with 8 GB of memory or less; export always uses full quality), Frame Cache, Background Work (make proxies while you edit), Preroll and Postroll, Audio Output, Audio Scrubbing, and Dropped Frames (an amber dot in the Program monitor).

## Editing

- New Sequences Start in Normal or Fast Cut.
- Default lengths for video and audio transitions.
- Lists of default effects and transitions, with Restore Factory.

## Audio

De-Click, Live Ducking, Duck Preset and Duck Timing, Crossfade kind and length, J / L Offset, Meter Response and Fade Shape. See [Audio](07-audio.md).

## Media

What to do with files outside the project (Ask, Copy, Move or Leave), project folder watching, Library folders, cache folder and size, Delete Cache, Scratch Folder, "Use proxies when exporting" (off by default), and the Projects Folder (default: Movies/Sequence Studio on the Mac, Videos/Sequence Studio on Windows and Linux).

## Advanced

Edit API (see below).

## Updates

Sequence Studio checks for a new version at launch if you leave "Check for a newer version at launch" on. It asks one address for the newest version number. Nothing else is sent.

To check by hand, choose Help > Check for Updates…. You will see one of:

- "Sequence Studio X is the newest version."
- "Version X is available", with Download and Later. Download opens the page for your system (a .dmg on the Mac, an .exe installer on Windows, an .AppImage on Linux).
- "The update information could not be read. Check your connection and try again later."

On Windows you update by downloading and running the new installer; it shows "Update Sequence Studio" and keeps your settings. On Linux you download the new AppImage and run it in place of the old one. On the Mac you replace the app in Applications.

## Feedback and logs

- **Help > Send Feedback…** opens an email to info@getsequencestudio.com with your version, build and system filled in.
- **Help > Reveal Logs and Reports** shows the app log in your file browser. On the Mac it also selects the newest crash report. The log is kept in three rolling files (sq.log, sq.1.log, sq.2.log). On the Mac they are in Library/Logs/Sequence Studio in your home folder. On Windows and Linux they are in the Logs folder of the Sequence Studio data folder (on Windows inside your AppData\Roaming folder, on Linux inside ~/.local/share), next to a Crashes folder.
- **Crash reports** are plain text files in the Crashes folder, on all three systems. After a crash the next start offers to show or copy the newest one. They hold the error, a stack trace, the app version, your system and the last log lines, with your home folder name hidden. They never contain your project, and nothing is sent anywhere. The newest ten are kept.
- Help also links to the Discord, GitHub, and Support Sequence Studio….

## Edit API (off by default)

The Edit API lets scripts and AI tools on your own computer edit the open project. It is off by default.

1. Open Settings > Advanced.
2. Turn on "Allow local tools to edit the open project".

Only programs on your own computer can connect (address 127.0.0.1), with a key that changes every launch. Each agent edit is one undo step, shown as "Agent: …". The default port is 19790. Most people never need this.

## Not sure yet

- There are no release channels (such as beta) in the app, so this page does not describe any.
- Whether every crash on Windows and Linux leaves a report. An abort that the app raises itself on Windows does not.

Related: [Getting Started](01-getting-started.md), [Audio](07-audio.md), [Shortcuts](11-shortcuts.md), [Troubleshooting](12-troubleshooting.md)
