//! Whether another process runs.

/// Whether a process with this pid runs. shortcut: Windows has no check (always false), upgrade with OpenProcess when
/// a Windows run shows a false "stopped while starting" report.
pub fn is_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
        // SAFETY: signal 0 only checks that the process exists.
        let r = unsafe { libc::kill(pid, 0) };
        r == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        false
    }
}

#[cfg(all(test, unix))]
mod tests {
    #[test]
    fn this_process_is_alive_and_a_missing_one_is_not() {
        assert!(super::is_alive(std::process::id()));
        assert!(!super::is_alive(i32::MAX as u32 - 1));
    }
}
