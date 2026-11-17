# sq-setup-engine

What the Windows installer (and the Linux first-run flow) does, without any drawing.

- `version`, `job`, `error`: version compare, the jobs and their steps, the `SQI-` error codes.
- `payload`: file format of `SequenceStudio-Setup-<ver>.exe` = stub exe + deflate-packed files + index + 96-byte trailer
  (`SQSETUP1`, SHA-256 over the payload). `pack`, `open`, `Payload::verify/unpack_to/read_file`, `copy_stub` (the uninstaller
  copy carries no payload).
- `plan`: the shortcuts and HKCU values as `Action`s, and their `inverse` (design/installer/spec.md 10.1, 10.2).
- `host`: the `Host` trait (registry, shortcuts, processes, folders) and `FakeHost` for tests. `WindowsHost` (Windows only)
  calls `sq_platform_win::setup`.
- `engine`: `run_job` runs install, update or uninstall with progress, cancel before 90 %, rollback on failure, a log file.
- `detect`: installed version (our key, else the Inno key), update kind, location check and resolve, data size.

Tests: `cargo test -p sq-setup-engine` (Linux, temp folders and `FakeHost`). Windows: `cargo xwin check -p sq-platform-win -p sq-setup-engine`;
the registry and shortcut tests in `sq-platform-win/src/setup.rs` run on Windows only.
