//! The release app is a windows-subsystem program (no console tab of its own). Started from a terminal, its CLI output
//! (`--ui-shot`, `--a11y-dump`, errors) must still print there: join the parent's console.

use std::os::windows::io::IntoRawHandle;
use windows::Win32::Foundation::HANDLE;
use windows::Win32::System::Console::{
    ATTACH_PARENT_PROCESS, AttachConsole, GetStdHandle, STD_ERROR_HANDLE, STD_HANDLE, STD_OUTPUT_HANDLE, SetStdHandle,
};

/// Attaches to the parent process's console, if it has one, and points stdout and stderr at it when they were not
/// redirected to a file or pipe (a redirected handle stays as the caller set it). Without a parent console (Explorer, a
/// shortcut) nothing happens.
pub fn attach_parent_console() {
    // SAFETY: AttachConsole only changes this process's console; it fails without a parent console.
    if unsafe { AttachConsole(ATTACH_PARENT_PROCESS) }.is_err() {
        return;
    }
    for which in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
        point_at_console(which);
    }
}

fn point_at_console(which: STD_HANDLE) {
    // SAFETY: plain handle getters and a setter on handles this function owns.
    unsafe {
        if GetStdHandle(which).is_ok_and(|h| !h.is_invalid()) {
            return;
        }
        if let Ok(console) = std::fs::OpenOptions::new().write(true).open("CONOUT$") {
            // The handle stays open for the life of the process, as a standard handle does.
            let _ = SetStdHandle(which, HANDLE(console.into_raw_handle()));
        }
    }
}
