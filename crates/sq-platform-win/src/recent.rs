//! Recent documents on the taskbar button's jump list and in Explorer (`SHAddToRecentDocs`); the shell lists them under
//! the program the file type is registered to (the installer registers `.sqproj`).

use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows_sys::Win32::UI::Shell::{SHARD_PATHW, SHAddToRecentDocs};

/// Adds `path` to the system's recent list.
pub fn add_recent_document(path: &Path) {
    let wide: Vec<u16> = sq_os::paths::for_os(path).as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    // SAFETY: `wide` is a NUL terminated UTF-16 path that outlives the call; SHARD_PATHW says so.
    unsafe { SHAddToRecentDocs(SHARD_PATHW as u32, wide.as_ptr().cast()) };
}
