//! Opens a file or a link with its default app through the shell (`ShellExecuteW`, verb `open`): what a double click in
//! Explorer does. The app used to start `cmd /c start "" <path>`; from this window-less GUI process that opened nothing
//! (seen in the Windows VM: the start-error window's "Open log"), and `cmd` read the path as a command line (an `&` or `^`
//! in a file name ended or changed the command).

use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use windows_sys::Win32::System::Com::{COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE, CoInitializeEx};
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

/// `text` as a NUL-terminated UTF-16 string; `None` when it holds a NUL (the shell would read a shorter name).
fn to_wide(text: &OsStr) -> Option<Vec<u16>> {
    let mut wide: Vec<u16> = text.encode_wide().collect();
    if wide.contains(&0) {
        return None;
    }
    wide.push(0);
    Some(wide)
}

/// What a `ShellExecuteW` result of 32 or less means (the documented error values).
fn describe(code: usize) -> String {
    let what = match code {
        0 => "the system is out of memory or resources",
        2 => "the file was not found",
        3 => "the path was not found",
        5 => "access was denied",
        8 => "there is not enough memory",
        26 => "the file is in use by another program",
        27 => "the file type's app association is incomplete",
        28..=30 => "the app that handles this file did not answer",
        31 => "no app is set to open this kind of file",
        32 => "a library of the app that handles this file is missing",
        _ => "the shell refused to open it",
    };
    format!("{what} (ShellExecute {code})")
}

/// Opens `target` (a file, a folder or a link such as `https://…` or `mailto:…`) in its default app. Returns once the shell
/// took the request; the error says what the shell answered.
pub fn open(target: &OsStr) -> Result<(), String> {
    let file = to_wide(target).ok_or("the name holds a NUL character")?;
    let verb = to_wide(OsStr::new("open")).ok_or("no verb")?;
    // SAFETY: both strings are NUL-terminated UTF-16 that live through the call; the other pointers are null as the
    // API allows. COM is started on this thread when it is not yet (the shell needs an apartment for some handlers); an
    // already started thread answers S_FALSE or RPC_E_CHANGED_MODE, which is fine. The call runs on the UI thread, which
    // pumps messages, so the apartment stays valid.
    let result = unsafe {
        CoInitializeEx(std::ptr::null(), (COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) as u32);
        ShellExecuteW(
            std::ptr::null_mut(),
            verb.as_ptr(),
            file.as_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            SW_SHOWNORMAL,
        )
    };
    let code = result as usize;
    if code > 32 { Ok(()) } else { Err(describe(code)) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_with_command_characters_stays_one_name() {
        let wide = to_wide(OsStr::new("C:\\Logs & More\\sq^1.log")).unwrap_or_default();
        assert_eq!(wide.last(), Some(&0));
        assert_eq!(String::from_utf16_lossy(&wide[..wide.len() - 1]), "C:\\Logs & More\\sq^1.log");
    }

    #[test]
    fn a_name_with_a_nul_is_refused_instead_of_cut_short() {
        assert_eq!(to_wide(OsStr::new("a\0b")), None);
        assert_eq!(open(OsStr::new("a\0b")), Err("the name holds a NUL character".to_string()));
    }

    #[test]
    fn the_documented_error_values_have_words() {
        assert!(describe(2).starts_with("the file was not found"));
        assert!(describe(31).contains("no app is set"));
        assert!(describe(11).contains("ShellExecute 11"));
    }
}
