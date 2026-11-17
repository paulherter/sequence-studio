# Windows installer (setup program `sq-installer`, per user, no admin)

`SequenceStudio-Setup-<version>-<stamp>.exe` is the `sq-installer` program (drawn with the app's own toolkit, design in
`design/installer/spec.md`) with the staged release folder appended as its payload. It installs to
`%LOCALAPPDATA%\Programs\Sequence Studio`, adds the Start menu entry and the `.sqproj` link, writes the uninstall entry under
HKCU and copies itself (without the payload) as `Uninstall Sequence Studio.exe`. Public releases are named `SequenceStudio-Setup-<version>.exe`: `cargo xtask package --release` (or `build-installer.ps1 -Release`) leaves the build stamp out. Silent: `Setup.exe --quiet [--dir <folder>]
[--desktop]`, `Uninstall Sequence Studio.exe --uninstall --quiet [--delete-data]`; the exit code is the error number.
`build-installer.ps1 -Inno` still builds the old Inno Setup installer described below, until the new one is checked in the VM.

# Old installer (Inno Setup 6, per user, no admin)

Files: `SequenceStudio.iss` (installer), `build-installer.ps1` (stage + zip + installer), `test-installer.ps1` (end-to-end check).

## Build (on the PC)
`powershell -File packaging\windows\build-installer.ps1` (version from Cargo.toml; `-Version x.y.z` overrides) (set `$env:CARGO_BUILD_JOBS=3` on the shared PC).
- Needs: FFmpeg LGPL shared build in `%USERPROFILE%\ffmpeg\ffmpeg-master-latest-win64-lgpl-shared` (a GPL/nonfree build is refused),
  Inno Setup 6 (`iscc` on PATH or `%LOCALAPPDATA%\Programs\Inno Setup 6`; without it only the zip is made).
- ONNX Runtime 1.24.4 DirectML is downloaded once from nuget and checked against the pinned sha256 (or `SQ_ONNXRUNTIME`).
- EdgeTAM models are NOT in the repo: set `SQ_SUBJECT_MASK_MODELS` to the folder with `edgetam_*.onnx`, else Magic Mask reports them missing.
- Output: `target\package\windows\SequenceStudio-Setup-<version>-<yyyyMMdd-HHmm>.exe` and the zip; `-Exe <path>` packages an exe cross-built on Linux (cargo xwin) instead of running cargo.

## Test on a clean machine
`powershell -File packaging\windows\test-installer.ps1 -Setup <Setup.exe> [-Project <.sqproj>]` installs silently into a temp
folder, starts the app with a PATH of only System32 (no FFmpeg/ORT/cargo, so the DLLs must sit beside the exe), checks no
"System Error" dialog, `--ui-shot` from the installed copy, file association, AUMID key + Start Menu shortcut, an upgrade
over the install (preferences in `%APPDATA%\Sequence Studio` survive), and that uninstall removes files, keys and shortcut.
Best context, in order: Windows Sandbox (needs the feature + restart), a Hyper-V VM, a fresh local user; the test PC has neither
Sandbox nor Hyper-V enabled (checked 2026-11-09, both Disabled), so the scrubbed-PATH run is what was done.

## Missing FFmpeg DLLs
The exe delay-links the five FFmpeg DLLs (`/DELAYLOAD`, see `crates/sequence-studio/build.rs`; the short-format import libraries come
from `crates/sq-media-ffmpeg/build.rs`, made with `llvm-lib` or `lib.exe` from the `.def` files of the FFmpeg build). The loader therefore
does not look for them before `main`: the start loads them itself (`preflight.rs`), and a missing or blocked one ends in the app's own error
window `SQS-301` (log: `%APPDATA%\Sequence Studio\Logs\sq.log`) instead of a system dialog or a silent exit. Try: rename
`avcodec-*.dll` next to the installed exe and start it. `SQ_FAULT_INJECT=ffmpeg` (with `SQ_FAULT_INJECT_ALLOW=1` on a release build) shows the
same window without touching a file.

## Signing
`-Sign` signs the exe and DLLs with `SQ_WIN_CERT_PFX` / `SQ_WIN_CERT_PASSWORD`. No certificate exists on the test PC (store empty,
no signtool): the installer is unsigned and shows SmartScreen "unknown publisher" until one is bought. The `.iss` has no `SignTool`
line, so the setup exe itself is not signed even with `-Sign`.

## Magic Mask models
`build-installer.ps1` bundles the five EdgeTAM ONNX parts (about 111 MB, Apache-2.0) into `SubjectMask` next to the exe, where
`sq-analysis` looks first. Folder: `SQ_SUBJECT_MASK_MODELS`, else `%USERPROFILE%\sqmodels`, `%USERPROFILE%\sqonnx\models`
(made by `scripts/win-onnx-setup.sh`), else `Tools\SubjectMaskSpike\work\models-onnx`. Each part is checked against the sha256
pinned in the script (a mismatch stops the build). The Apache-2.0 text is shipped as `Licenses\APACHE-2.0.txt`.
