# Sequence Studio

A native macOS video editor in Swift, aiming at the workflow of Adobe Premiere Pro. Licensed under GPL-3.0-or-later.

## Status

Pre-alpha. The engine, timeline editing model and editor UI are under active development. There are no releases, file formats may change, and the app is not ready for real projects. Progress and open decisions are in `docs/STATUS.md`; the roadmap is `PLAN.md`.

## Requirements

- macOS 26 on Apple Silicon (arm64)
- Xcode with the Swift 6.2 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build and test

```
xcodegen generate
scripts/build.sh          # builds the app, prints errors only
scripts/test.sh [Package] # runs swift test for one package, or all
```

The generated `SequenceStudio.xcodeproj` is not committed. Test footage is not part of the repository; put your own under `TestMedia/` (git-ignored).

## Packages

| Package | Purpose |
|---|---|
| SSCore | Project model, rational time, timeline edit logic, undo snapshots, project file, autosave. No AVFoundation/AppKit. |
| SSMedia | Media import and probing, demuxing, video/audio decoding, thumbnails, relink. |
| SSRender | Metal compositor and presenter. |
| SSPlayback | Playback clock, frame cache, prefetch, decode scheduling, audio engine. |
| SSExport | Export settings, frame source, writer, loudness normalization. |
| SSAudioFX | Audio effects, including noise suppression (RNNoise). |
| SSProxy | Proxy media generation and cache. |
| SSLibrary | Media library: bins, folder watching, search. |
| SSText | Text layout and titles. |
| SSTranscribe | Speech transcription. |
| SSEditorUI | Theme, panel layout, timeline and monitor views. |

`App/` holds the SwiftUI shell; `Tools/` holds development executables.

## Documentation

- `PLAN.md`: phases and scope
- `docs/ARCHITECTURE.md`: engine interfaces and data flow
- `docs/DECISIONS.md`: design decisions and their reasons

## Credits

Borrowed and referenced code, with licenses, is listed in `docs/THIRD_PARTY.md`.

## License

GPL-3.0-or-later. See `LICENSE`.
