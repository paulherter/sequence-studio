# sq-platform-mac

macOS-only services of the `sequence-studio` binary. The crate is empty on other systems.

- `MenuBar::install()`: the native menu bar (application menu with About, Hide, Quit; Window menu with Minimize and
  Zoom) through `muda`. The editor's own commands and their shortcuts stay in the draw UI, so the bar carries no
  accelerators of its own: a menu key equivalent would take the key before the app sees it.
- `tag_surface_srgb()`: tags the window's CAMetalLayer sRGB after every surface configure (wgpu leaves it untagged, and
  an untagged layer shows raw values on a Display P3 screen: too saturated and contrasty). Windows and Linux need no
  counterpart: their surfaces are shown as sRGB without OS color management, so the same sRGB code values (UI colors,
  the re-encoded video of `sq_draw::display_gamma`) look the same there. See docs/rust/COLOR-DISPLAY.md.

Window attributes, event translation, cursor, clipboard and file dialogs are shared by both systems and live in the
binary (`crates/sequence-studio`). Check: `cargo xtask check sq-platform-mac`.
