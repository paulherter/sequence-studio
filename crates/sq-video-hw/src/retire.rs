//! Cap on VideoToolbox sessions draining off the decode thread: macOS has a limited number of hardware sessions, and a fast
//! run of seeks must not leave a pile of them waiting to finish.

use std::sync::atomic::{AtomicUsize, Ordering};

/// Sessions allowed to drain on their own threads at once; more are dropped inline (the decode waits for them).
pub const MAX_RETIRING: usize = 2;

/// Counts the sessions draining now.
pub struct Retiring(AtomicUsize);

impl Retiring {
    pub const fn new() -> Retiring {
        Retiring(AtomicUsize::new(0))
    }

    /// Takes a place for one more draining session; false when `MAX_RETIRING` are draining already.
    pub fn try_begin(&self) -> bool {
        self.0
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| (n < MAX_RETIRING).then_some(n + 1))
            .is_ok()
    }

    /// A draining session is gone.
    pub fn end(&self) {
        let _ = self.0.fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_sub(1));
    }
}

impl Default for Retiring {
    fn default() -> Self {
        Retiring::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn at_most_two_sessions_drain_at_once_and_a_finished_one_frees_its_place() {
        let r = Retiring::new();
        assert!(r.try_begin());
        assert!(r.try_begin());
        assert!(!r.try_begin(), "the third drops inline");
        r.end();
        assert!(r.try_begin());
        r.end();
        r.end();
        r.end();
        assert!(r.try_begin(), "an extra end never underflows");
    }
}
