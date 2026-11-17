//! Free space of the volume a folder lives on, for Mac and Linux (`statvfs`; Swift `volumeAvailableCapacityForImportantUsage`).

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// Bytes the current user can still write on the volume of `folder` (the nearest existing parent when the folder is not
/// there yet); `None` when the system cannot say.
pub fn free_bytes(folder: &Path) -> Option<i64> {
    volume_bytes(folder).0
}

/// Free (for this user) and total bytes of the volume holding `folder`, each `None` when the system cannot say.
pub fn volume_bytes(folder: &Path) -> (Option<i64>, Option<i64>) {
    let Some(existing) = folder.ancestors().find(|p| p.exists()) else { return (None, None) };
    let Ok(path) = CString::new(existing.as_os_str().as_bytes()) else { return (None, None) };
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::zeroed();
    // SAFETY: `path` is a NUL-terminated C string that lives through the call and `stat` is a valid out buffer.
    let rc = unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) };
    if rc != 0 {
        return (None, None);
    }
    // SAFETY: statvfs returned 0, so it filled the struct.
    let stat = unsafe { stat.assume_init() };
    let size = |blocks: u128| Some(i64::try_from(blocks * u128::from(stat.f_frsize)).unwrap_or(i64::MAX));
    (size(u128::from(stat.f_bavail)), size(u128::from(stat.f_blocks)))
}

/// Physical memory of the machine in bytes (`sysconf`; Swift `ProcessInfo.physicalMemory`).
pub fn physical_memory() -> Option<u64> {
    // SAFETY: `sysconf` takes a plain constant and has no preconditions.
    let (pages, page) = unsafe { (libc::sysconf(libc::_SC_PHYS_PAGES), libc::sysconf(libc::_SC_PAGESIZE)) };
    u64::try_from(pages).ok()?.checked_mul(u64::try_from(page).ok()?).filter(|b| *b > 0)
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_temp_folder_reports_free_space() {
        assert!(super::free_bytes(&std::env::temp_dir()).is_some_and(|b| b > 0));
        assert!(super::free_bytes(&std::env::temp_dir().join("no-such-folder-yet").join("a")).is_some());
    }

    #[test]
    fn the_volume_has_a_total_that_is_at_least_the_free_part() {
        let (free, total) = super::volume_bytes(&std::env::temp_dir());
        assert!(free.is_some() && total.is_some_and(|t| t > 0 && Some(t) >= free));
    }

    #[test]
    fn the_machine_reports_its_memory() {
        assert!(super::physical_memory().is_some_and(|m| m >= 256 << 20));
    }
}
