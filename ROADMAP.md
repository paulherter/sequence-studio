# Roadmap

What is planned for Sequence Studio, roughly in the order it will happen. This list is public on purpose: if something
here matters to you, say so, or build it yourself and open a pull request.

**Status:** 0.1 Alpha is the first public version. Everything below is not done yet.

## How to take part

- **Vote:** open the matching issue (label `roadmap`) and add a 👍, or tell us in [Discord](https://discord.gg/q6KPQc8WCA)
  what you need most. The more people ask, the earlier it moves up.
- **Build it:** comment on the issue so nobody works twice on the same thing, then follow
  [CONTRIBUTING.md](CONTRIBUTING.md) and open a pull request. Working with an AI assistant such as Claude is welcome;
  please read and test what it wrote before you send it.
- **Missing something?** [Open an issue](https://github.com/paulherter/sequence-studio/issues/new/choose).

## Next

| Item | What it means | Good first step |
| --- | --- | --- |
| **Local MCP server** | One click connects Claude or another AI agent to the app, so it can cut, trim, caption and export for you. Runs on your own computer, no cloud. | Design the tool list on top of the edit API ([docs/EDIT-API.md](docs/EDIT-API.md)) |
| **Windows parity** | Stabilization (Gyroflow), auto reframe, HDR and ProRes on Windows, same behavior as on the Mac. | Pick one feature, port it behind the existing platform protocol |
| **Windows polish** | More hands-on testing of the shared app, scrolling feel, remaining "not available in this window yet" commands. | Run it, report what feels different from the Mac |
| **Update channels** | Stable and test releases, so you can choose to get early builds. | |
| **Release builds in the cloud** | Build the Windows installer on GitHub Actions, no local Windows machine needed. | |

## Later

| Item | What it means |
| --- | --- |
| **Plugin support** | A documented API for third-party effects, transitions and tools. |
| **Preset and effects library** | Shareable presets, title templates and MOGRT import. |
| **Node-based color** | An optional node view on top of the current color panels. |
| **More Premiere import** | More effects and project features when you open a `.prproj`. |
| **Intel Mac, Windows on ARM, Linux** | Not started. A port needs someone who runs that system daily. |

## Still being researched

We are comparing with other editors to find out what is really missing. This list will grow after the first
round of feedback. If you edit for a living and something blocks you, that is the most useful thing you can tell us.

## Done in 0.1 Alpha

Timeline editing, color grading, masks (including subject), captions, audio cleanup, stabilization on the Mac,
export presets for YouTube, TikTok and Reels, Premiere project import, Fast Cut timeline mode, the same app on Mac and Windows.
See the [README](README.md#-features) for the full list.
