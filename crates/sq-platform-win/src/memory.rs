//! Resident memory of this process (`GetProcessMemoryInfo`): the working set, the number `ps -o rss` reports on the Mac and Linux.

use windows_sys::Win32::System::ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS};
use windows_sys::Win32::System::Threading::GetCurrentProcess;

/// The working set of this process in bytes; `None` when the system cannot say.
pub fn working_set_bytes() -> Option<u64> {
    // SAFETY: zeroed counters are a valid value of the plain C struct.
    let mut counters: PROCESS_MEMORY_COUNTERS = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<PROCESS_MEMORY_COUNTERS>() as u32;
    counters.cb = size;
    // SAFETY: `GetCurrentProcess` is the pseudo handle of this process (it needs no close); `counters` is a valid out
    // structure of `size` bytes with `cb` set, as the call requires.
    let ok = unsafe { GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, size) };
    (ok != 0).then_some(counters.WorkingSetSize as u64)
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_working_set_of_the_test_process_is_known() {
        let bytes = super::working_set_bytes();
        assert!(bytes.is_some_and(|b| b > 1 << 20), "{bytes:?}");
    }
}
