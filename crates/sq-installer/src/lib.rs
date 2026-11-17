//! The Sequence Studio setup program. One state machine ([`machine`]), the text of every screen as data ([`model`]), the
//! drawing and input ([`view`]) and the window ([`window`]). The Windows installer and uninstaller are the `sq-installer`
//! binary; the Linux first-run flow of the app opens the same window from `sequence-studio`.
//! Design: `design/installer/spec.md`.

pub mod app;
pub mod args;
pub mod machine;
pub mod model;
pub mod session;
pub mod shots;
pub mod view;

#[cfg(windows)]
pub mod windows;

#[cfg(unix)]
pub mod linux;
