//! The system Trash, one function for all three systems.
//!
//! - Mac: `NSFileManager.trashItem` (same call as the Swift app).
//! - Windows: the Recycle Bin through `SHFileOperationW` with `FOF_ALLOWUNDO`.
//! - Linux: the freedesktop.org Trash specification 1.0 (home trash, or `.Trash-$uid` on another volume).
//!
//! Also `is_finder_alias`: the Mac `isAliasFileKey` check (false elsewhere, as in Swift's Windows branch).

use std::io;
use std::path::Path;

#[cfg(unix)]
pub mod freedesktop; // also built on the Mac so its tests run there

/// Moves `path` to the Trash. Never deletes for good: an error leaves the file where it is.
pub fn trash(path: &Path) -> io::Result<()> {
    imp::trash(path)
}

/// True when `path` is a Finder alias file (a regular file that points at another file). Always false off the Mac.
pub fn is_finder_alias(path: &Path) -> bool {
    imp::is_finder_alias(path)
}

#[cfg(target_os = "macos")]
mod imp {
    use super::*;
    use objc2_foundation::{NSFileManager, NSString, NSURL};
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;

    pub fn trash(path: &Path) -> io::Result<()> {
        let s = path.to_str().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path is not UTF-8"))?;
        let url = NSURL::fileURLWithPath(&NSString::from_str(s));
        let fm = NSFileManager::defaultManager();
        fm.trashItemAtURL_resultingItemURL_error(&url, None)
            .map_err(|e| io::Error::other(e.localizedDescription().to_string()))
    }

    /// Finder sets the alias flag (0x8000, big endian, byte 8) in the `com.apple.FinderInfo` attribute.
    pub fn is_finder_alias(path: &Path) -> bool {
        let Ok(c) = CString::new(path.as_os_str().as_bytes()) else { return false };
        let mut info = [0u8; 32];
        // SAFETY: `c` is a valid C string and `info` is 32 writable bytes, the size passed in.
        let n = unsafe {
            libc::getxattr(
                c.as_ptr(),
                c"com.apple.FinderInfo".as_ptr(),
                info.as_mut_ptr().cast(),
                info.len(),
                0,
                libc::XATTR_NOFOLLOW,
            )
        };
        n >= 10 && u16::from_be_bytes([info[8], info[9]]) & 0x8000 != 0
    }
}

#[cfg(all(unix, not(target_os = "macos")))]
mod imp {
    use super::*;

    pub fn trash(path: &Path) -> io::Result<()> {
        freedesktop::trash(path)
    }

    pub fn is_finder_alias(_: &Path) -> bool {
        false
    }
}

#[cfg(windows)]
mod imp {
    use super::*;
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::Shell::{
        FO_DELETE, FOF_ALLOWUNDO, FOF_NOERRORUI, FOF_SILENT, FOF_WANTNUKEWARNING, SHFILEOPSTRUCTW, SHFileOperationW,
    };

    /// Recycle only. `FOF_NOCONFIRMATION` is left out on purpose: with it the Shell deletes for good when the Recycle Bin
    /// cannot take the file (a network or USB drive, a file over the bin's size), and a Move import would lose the original.
    /// `FOF_WANTNUKEWARNING` makes the Shell ask before such a permanent delete; "No" aborts, which `trash` reports as an error.
    pub(super) const FLAGS: u32 = FOF_ALLOWUNDO | FOF_WANTNUKEWARNING | FOF_NOERRORUI | FOF_SILENT;

    pub fn trash(path: &Path) -> io::Result<()> {
        // The Shell wants an absolute path, double-null terminated; "\\?\" paths are not accepted.
        let abs = std::path::absolute(path)?;
        let mut from: Vec<u16> = abs.as_os_str().encode_wide().collect();
        from.extend([0, 0]);
        let mut op = SHFILEOPSTRUCTW {
            hwnd: std::ptr::null_mut(),
            wFunc: FO_DELETE,
            pFrom: from.as_ptr(),
            pTo: std::ptr::null(),
            fFlags: FLAGS as u16,
            fAnyOperationsAborted: 0,
            hNameMappings: std::ptr::null_mut(),
            lpszProgressTitle: std::ptr::null(),
        };
        // SAFETY: `op` points at `from`, which outlives the call and ends with two nulls.
        let code = unsafe { SHFileOperationW(&mut op) };
        if code != 0 || op.fAnyOperationsAborted != 0 {
            return Err(io::Error::other(format!("Recycle Bin refused the file (code {code})")));
        }
        Ok(())
    }

    pub fn is_finder_alias(_: &Path) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(windows)]
    #[test]
    fn windows_never_deletes_for_good_when_the_bin_cannot_take_a_file() {
        use windows_sys::Win32::UI::Shell::{FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_WANTNUKEWARNING};
        const { assert!(imp::FLAGS & FOF_ALLOWUNDO != 0 && imp::FLAGS & FOF_WANTNUKEWARNING != 0) };
        const { assert!(imp::FLAGS & FOF_NOCONFIRMATION == 0, "silent confirmation lets the Shell delete permanently") };
    }

    #[cfg(windows)]
    #[test]
    fn windows_trash_moves_a_file_to_the_recycle_bin() {
        let p = std::env::temp_dir().join(format!("sq-trash-win-{}.txt", std::process::id()));
        assert!(std::fs::write(&p, b"x").is_ok());
        assert!(trash(&p).is_ok());
        assert!(!p.exists(), "the file left its folder");
    }

    #[test]
    fn a_plain_file_is_no_alias() {
        let p = std::env::temp_dir().join(format!("sq-trash-alias-{}", std::process::id()));
        assert!(std::fs::write(&p, b"x").is_ok());
        assert!(!is_finder_alias(&p));
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn a_missing_file_fails_and_is_no_alias() {
        let p = std::env::temp_dir().join("sq-trash-does-not-exist-xyz");
        assert!(trash(&p).is_err());
        assert!(!is_finder_alias(&p));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_trash_moves_the_file_to_a_freedesktop_trash() {
        let p = std::env::temp_dir().join(format!("sq-trash-linux-{}.txt", std::process::id()));
        assert!(std::fs::write(&p, b"x").is_ok());
        assert!(trash(&p).is_ok());
        assert!(!p.exists());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn mac_trash_moves_the_file_and_a_finder_alias_is_seen() {
        let p = std::env::temp_dir().join(format!("sq-trash-mac-{}.txt", std::process::id()));
        assert!(std::fs::write(&p, b"x").is_ok());
        assert!(trash(&p).is_ok());
        assert!(!p.exists());
        // A real Finder alias made with osascript.
        let t = std::env::temp_dir().join(format!("sq-trash-target-{}.txt", std::process::id()));
        assert!(std::fs::write(&t, b"x").is_ok());
        let script = format!(
            "tell application \"Finder\" to make alias file to POSIX file \"{}\" at POSIX file \"{}\"",
            t.display(),
            std::env::temp_dir().display()
        );
        let out = std::process::Command::new("osascript").args(["-e", &script]).output();
        if out.is_ok_and(|o| o.status.success()) {
            let alias = std::env::temp_dir().join(t.file_name().unwrap_or_default().to_string_lossy().to_string());
            let _ = alias; // Finder names it "<name> alias"
            let found =
                std::fs::read_dir(std::env::temp_dir()).into_iter().flatten().flatten().map(|e| e.path()).find(|e| {
                    e.to_string_lossy().contains("sq-trash-target") && e.to_string_lossy().ends_with(" alias")
                });
            if let Some(a) = found {
                assert!(is_finder_alias(&a));
                assert!(!is_finder_alias(&t));
                let _ = std::fs::remove_file(&a);
            }
        }
        let _ = std::fs::remove_file(&t);
    }
}
