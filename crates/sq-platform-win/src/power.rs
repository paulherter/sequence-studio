//! No idle sleep while an export runs (`SetThreadExecutionState`).

use windows_sys::Win32::System::Power::{ES_CONTINUOUS, ES_SYSTEM_REQUIRED, SetThreadExecutionState};

/// Held while the export runs; the state belongs to the thread that took it, so take and drop it on the main thread.
pub struct SleepLock(());

impl SleepLock {
    pub fn acquire() -> Option<SleepLock> {
        // SAFETY: a plain call that sets the calling thread's execution state.
        let before = unsafe { SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) };
        (before != 0).then_some(SleepLock(()))
    }
}

impl Drop for SleepLock {
    fn drop(&mut self) {
        // SAFETY: clears the continuous state this thread set in `acquire`.
        unsafe { SetThreadExecutionState(ES_CONTINUOUS) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_lock_can_be_taken_and_released() {
        let lock = SleepLock::acquire();
        assert!(lock.is_some());
        drop(lock);
    }
}
