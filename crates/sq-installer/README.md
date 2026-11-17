# sq-installer

The Sequence Studio setup program, drawn with the app's own toolkit (`sq-draw`, the stone buttons, `DrawTheme`).
Design and behavior: `design/installer/spec.md` (renders `design/installer/*.png`).

- Windows: `SequenceStudio-Setup-<version>.exe` is this program with the release folder appended as a payload
  (`sq-setup-engine::payload`). Per user, no admin. The same program without the payload is installed as
  `Uninstall Sequence Studio.exe`.
- Linux: the app opens the same window on its first start from an AppImage (`session::SetupSession`, `Chrome::System`).

Layers: `machine` (one enum, one transition function, no I/O), `model` (the text of every screen as data), `view` (draw and
input; the error screen is `sq_draw_shell::ErrorView`), `session` (software-rendered window and the effects), `shots`
(`sq-installer --shot <screen> --theme dark|light --scale 2 --out <png>` renders a screen without a window).
The work itself (payload, plan, registry, shortcuts, rollback) is `sq-setup-engine`.
