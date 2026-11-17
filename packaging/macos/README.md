# macOS packaging

`cargo xtask package` builds `target/package/Sequence Studio.app` from the Rust workspace.

| Command | Result |
|---|---|
| `cargo xtask package` | release build, bundle, FFmpeg dylibs copied into `Contents/Frameworks` with `@executable_path/../Frameworks` install names, ad-hoc signed, `--ui-shot` smoke test |
| `... --dmg` | also `target/package/Sequence Studio.dmg` (scripts/make-dmg.sh) |
| `... --no-smoke` | skip the headless `--ui-shot` run |

Environment: `SQ_FFMPEG` (FFmpeg folder, default Homebrew via pkg-config), `SQ_ONNXRUNTIME` (folder with
`libonnxruntime*.dylib` to use instead of the pinned 1.24.4 release that `cargo xtask package` downloads into `~/Library/Caches/SequenceStudio` and checks by sha256; sq-onnx loads it from `Contents/Frameworks` at run time), `SQ_SUBJECT_MASK_MODELS` (the five EdgeTAM ONNX parts, copied to `Contents/Resources/SubjectMask`), `SQ_NICE`.

## Developer ID and notarization (documented, not run yet)

Same flow as scripts/package.sh, credentials only from the environment or the keychain:

```
SQ_SIGN_ID="Developer ID Application: <name> (<team id>)" \
SQ_NOTARY_PROFILE=sq-notary \
cargo xtask package --sign --notarize --dmg
```

- `--sign` signs dylibs first, the app last, hardened runtime, secure timestamp, `Release.entitlements`.
- `--notarize` zips the app, runs `xcrun notarytool submit --keychain-profile $SQ_NOTARY_PROFILE --wait`, then
  `xcrun stapler staple`. One-time profile setup: `xcrun notarytool store-credentials sq-notary --apple-id <id> --team-id <team>`.
- Still open: notarize and staple the DMG itself (scripts/package.sh does it), sign the DMG, `Release.entitlements`
  review for the Rust binary.

## Known gaps

- The app finds Inter through `SQ_FONTS` or the build-time source path (crates/sequence-studio/src/main.rs `fonts_root`).
  The bundle carries `Contents/Resources/Fonts`; main.rs should look there first. The smoke test sets `SQ_FONTS`.
- Homebrew FFmpeg is a GPL build (x264/x265); a release needs the LGPL build: `scripts/build-ffmpeg-lgpl-mac.sh` (see below).
- The icon is the compiled `AppIcon.icns` of the Swift app (from `App/AppIcon.icon`); rebuild it when the icon changes.
- Subject-mask models are not bundled yet.

## LGPL FFmpeg for releases

`scripts/build-ffmpeg-lgpl-mac.sh` builds the FFmpeg commit of the Windows installer's BtbN master build
(N-128100-gceb466cbcd) from the pinned GitHub tarball (sha256 checked, temp dir outside the repo, deleted afterwards)
with `--enable-shared --disable-static --disable-gpl --disable-nonfree --enable-version3 --enable-videotoolbox
--enable-audiotoolbox` plus libdav1d, libopus, libmp3lame, libvpx, libsvtav1 from the installed Homebrew libs (nothing is
installed; a missing lib drops its codec). Needs 12 GB free. Output: `~/Documents/SQ-Rust-Ffmpeg-LGPL` (override
`SQ_FFMPEG_OUT`) with a `BUILDINFO` holding the configure line. Package with
`SQ_FFMPEG=~/Documents/SQ-Rust-Ffmpeg-LGPL cargo xtask package --sign`.
No libx264/libx265/fdk-aac: H.264/HEVC/ProRes encode runs on VideoToolbox, AAC on audiotoolbox (`aac_at`) or the native `aac`.
