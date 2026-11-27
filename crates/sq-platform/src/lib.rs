//! One facade over the system services of the app, so the app has no `cfg(target_os)` for them. The logic that is the same
//! on every system (when the progress badge changes, when the sleep lock is held) lives here and is tested on any host;
//! the backends are small: `sq-platform-mac` (Dock badge, `caffeinate`) and `sq-platform-win` (taskbar progress,
//! `SetThreadExecutionState`). Linux gets the shared unix free-space probe and no-ops for the rest. The menu bar and window chrome stay in the backends (they differ
//! in kind: the Mac has a system menu bar, Windows draws its own). See docs/rust/PLATFORM-MATRIX.md.

pub mod app_update;
pub mod app_window;
mod backend;
pub mod clipboard;
pub mod desktop_integration;
#[cfg(unix)]
mod disk_unix;
pub mod display;
#[cfg(target_os = "linux")]
mod fault_linux;
mod gate;
pub mod instance;
#[cfg(not(any(windows, target_os = "macos")))]
mod linux_power;
#[cfg(not(any(target_os = "macos", windows)))]
pub mod linux_settings;
pub mod notify;
pub mod owned_window;
pub mod process;

pub use backend::{
    add_recent_document, free_bytes, install_fault_report, install_open_handler, physical_memory, volume_bytes,
};
pub use gate::{ExportIndicators, Step};
pub use sq_fault_text::FaultConfig;
