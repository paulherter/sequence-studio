//! Starting things from the setup program: a file in its default app, and finding the window of a program that was just
//! started (so the setup can close once the app is on screen).

use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows_sys::Win32::Foundation::{HWND, LPARAM};
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowThreadProcessId, IsWindowVisible, SW_SHOWNORMAL,
};

fn wide(text: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    text.as_ref().encode_wide().chain(std::iter::once(0)).collect()
}

/// Opens `path` with the program Windows has for it (the license text, the log). False when Windows refused.
pub fn open_with_default(path: &Path) -> bool {
    let (verb, file) = (wide("open"), wide(path));
    // SAFETY: both strings are NUL-terminated and outlive the call; the other pointers are documented as optional.
    let result = unsafe {
        ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            file.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            SW_SHOWNORMAL,
        )
    };
    // ShellExecute reports success with a value above 32.
    result as isize > 32
}

struct Search {
    pid: u32,
    found: bool,
}

unsafe extern "system" fn each_window(hwnd: HWND, lparam: LPARAM) -> i32 {
    // SAFETY: `lparam` is the `Search` that `has_visible_window` passed and keeps alive for the whole enumeration.
    let search = unsafe { &mut *(lparam as *mut Search) };
    let mut owner = 0u32;
    // SAFETY: `hwnd` comes from the enumeration; `owner` is a plain out value.
    let visible = unsafe {
        GetWindowThreadProcessId(hwnd, &mut owner);
        IsWindowVisible(hwnd) != 0
    };
    if owner == search.pid && visible {
        search.found = true;
        return 0;
    }
    1
}

/// Whether the process `pid` owns a visible top-level window.
pub fn has_visible_window(pid: u32) -> bool {
    let mut search = Search { pid, found: false };
    // SAFETY: the callback only touches `search`, which lives until the call returns.
    unsafe { EnumWindows(Some(each_window), &mut search as *mut Search as LPARAM) };
    search.found
}
