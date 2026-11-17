//! The video libraries are delay-linked into the exe (`build.rs` of `sequence-studio`), so the Windows loader does not
//! look for them before `main`: a missing one would otherwise end the process with a system dialog and no window of ours.
//! The start loads them itself, one by one, and reports the one that does not load.

use std::os::windows::ffi::OsStrExt;
use windows_sys::Win32::System::LibraryLoader::LoadLibraryW;

/// Loads each of `names` (a DLL file name, found the way the loader finds any: the exe's folder first). Returns the first
/// that does not load with the system's error, or `None` when all do. The loaded ones stay loaded for the whole run, which
/// is where the delay-load helper finds them. Order matters: list a library after the ones it needs, so the one reported
/// is the missing one and not its user.
pub fn first_missing_library(names: &[&str]) -> Option<(String, std::io::Error)> {
    for name in names {
        let wide: Vec<u16> = std::ffi::OsStr::new(name).encode_wide().chain(std::iter::once(0)).collect();
        // SAFETY: `wide` is a NUL-terminated UTF-16 string that lives through the call. The module handle is not freed:
        // the app needs the library for the whole run.
        let module = unsafe { LoadLibraryW(wide.as_ptr()) };
        if module.is_null() {
            return Some(((*name).to_string(), std::io::Error::last_os_error()));
        }
    }
    None
}
