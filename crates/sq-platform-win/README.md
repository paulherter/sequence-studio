# sq-platform-win

Windows-only services of the `sequence-studio` binary. The crate is empty on other systems.

- `install_chrome(&Window, Chrome)`: for a borderless window (`with_decorations(false)`), a window subclass asks the
  app `Chrome::hit` for every `WM_NCHITTEST` (drag area, resize edges, the maximize button that shows the snap
  layouts; winit 0.30 has no hook for it) and forwards the pointer over the maximize button through
  `Chrome::max_button`, because the system keeps those messages from the client area. The drawn caption lives in
  `crates/sequence-studio/src/caption.rs`.
- All `unsafe` of the app's Windows side is here (allow-listed crate).

Event translation, cursor, clipboard and file dialogs are shared by both systems and live in the binary
(`crates/sequence-studio`). Check: `cargo xtask check sq-platform-win` (on the PC for a real build).
