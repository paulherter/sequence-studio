# Contributing

Thanks for helping. Sequence Studio is alpha software, so please open an issue before starting larger work.
Issues and pull requests are in English. By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Build prerequisites

- A Mac with Apple Silicon, macOS 26
- Xcode 26 (Swift 6.2 toolchain)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Optional, for Gyroflow stabilization: a Rust toolchain, then `scripts/build-gyro.sh` (builds `libsqgyro.dylib`).
  Without it the app builds and runs; the Gyroflow method is just unavailable.

```
xcodegen generate
scripts/build.sh            # builds the app, prints errors only
scripts/test.sh [Package]   # swift test for one package (e.g. SQCore), or all
scripts/lint-ui.sh          # UI consistency lint, run it when you touch UI code
```

Test footage is not part of the repository. Put your own under `TestMedia/` (git-ignored); tests that need media
skip themselves when it is missing.

## Rules

- Tests first for edit logic. `scripts/build.sh` and the tests of every package you touched must pass.
- Swift 6 with strict concurrency. Do not suppress warnings to get around it.
- Time is rational (`value/timescale`), never `Double`.
- The model is value types; undo works on snapshots.
- `SQCore` must not import AVFoundation or AppKit.
- UI: use the `Theme` tokens and the components in `SQEditorUI`; no hard-coded colors, fonts or radii.
- No footage or other media in the repository.
- Only GPL-3.0-compatible code (GPL, MIT, BSD, Apache-2.0). Read and check it first, then add an entry to
  `docs/THIRD_PARTY.md`.
- Keep commits small, with English messages.

## License

Sequence Studio is GPL-3.0-or-later. By contributing you agree that your work is licensed under GPL-3.0-or-later.
