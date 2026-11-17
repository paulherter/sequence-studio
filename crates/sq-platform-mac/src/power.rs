//! No idle sleep while an export runs (Swift `ProcessInfo.beginActivity`).
//!
//! shortcut: a `caffeinate -i -w <pid>` child holds the assertion (it ends with the app or on drop); a direct
//! `IOPMAssertionCreateWithName` call needs IOKit bindings. Upgrade when the child shows up in a crash or process list.

use std::process::{Child, Command, Stdio};

/// Held while the export runs; dropping it lets the Mac sleep again.
pub struct SleepLock(Child);

impl SleepLock {
    /// `None` when `caffeinate` cannot start (the export runs on, the Mac may sleep).
    pub fn acquire() -> Option<SleepLock> {
        let pid = std::process::id().to_string();
        let child = Command::new("/usr/bin/caffeinate")
            .args(["-i", "-w", &pid])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        Some(SleepLock(child))
    }
}

impl Drop for SleepLock {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
