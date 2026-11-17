//! Free space of the volume a folder lives on (`GetDiskFreeSpaceExW`; Swift `volumeAvailableCapacityForImportantUsage`).

use std::os::windows::ffi::OsStrExt;
use std::path::Path;
use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
use windows_sys::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};

/// Bytes the current user can still write on the volume of `folder` (the nearest existing parent when the folder is not
/// there yet); `None` when the system cannot say.
pub fn free_bytes(folder: &Path) -> Option<i64> {
    volume_bytes(folder).0
}

/// Free (for this user) and total bytes of the volume holding `folder`, each `None` when the system cannot say.
pub fn volume_bytes(folder: &Path) -> (Option<i64>, Option<i64>) {
    let Some(existing) = folder.ancestors().find(|p| p.exists()) else { return (None, None) };
    let wide: Vec<u16> = existing.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let mut available: u64 = 0;
    let mut total: u64 = 0;
    // SAFETY: `wide` is a NUL-terminated UTF-16 path that lives through the call; the out pointers are valid `u64`s, the
    // third may be null.
    let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut available, &mut total, std::ptr::null_mut()) };
    if ok == 0 {
        return (None, None);
    }
    (Some(i64::try_from(available).unwrap_or(i64::MAX)), Some(i64::try_from(total).unwrap_or(i64::MAX)))
}

/// Physical memory of the machine in bytes (`GlobalMemoryStatusEx`; Swift `ProcessInfo.physicalMemory`).
pub fn physical_memory() -> Option<u64> {
    // SAFETY: a zeroed `MEMORYSTATUSEX` with `dwLength` set is the documented input; the call fills it.
    let mut status: MEMORYSTATUSEX = unsafe { std::mem::zeroed() };
    status.dwLength = std::mem::size_of::<MEMORYSTATUSEX>() as u32;
    // SAFETY: `status` is a valid, correctly sized out structure.
    let ok = unsafe { GlobalMemoryStatusEx(&mut status) };
    (ok != 0 && status.ullTotalPhys > 0).then_some(status.ullTotalPhys)
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_temp_folder_reports_free_space() {
        assert!(super::free_bytes(&std::env::temp_dir()).is_some_and(|b| b > 0));
        assert!(super::free_bytes(&std::env::temp_dir().join("no-such-folder-yet").join("a")).is_some());
    }

    #[test]
    fn the_volume_total_and_the_memory_are_known() {
        let (free, total) = super::volume_bytes(&std::env::temp_dir());
        assert!(free.is_some() && total.is_some_and(|t| t > 0 && Some(t) >= free));
        assert!(super::physical_memory().is_some_and(|m| m >= 256 << 20));
    }
}
