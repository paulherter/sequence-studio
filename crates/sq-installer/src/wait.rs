//! Waiting for the app that started an update to end before its files are replaced.

use std::time::Duration;

/// How often and how long a quiet update waits for the app that started it.
pub const POLL: Duration = Duration::from_millis(200);
pub const TRIES: u32 = 150;

/// Whether `pid` is gone: `running` lists the process ids of the app's image; `pause` sleeps between looks. Looks at
/// most `tries` times.
pub fn wait_until_gone(pid: u32, mut running: impl FnMut() -> Vec<u32>, tries: u32, mut pause: impl FnMut()) -> bool {
    for look in 0..tries {
        if !running().contains(&pid) {
            return true;
        }
        if look + 1 < tries {
            pause();
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_returns_as_soon_as_the_process_is_gone() {
        let mut lists = vec![vec![7, 9], vec![9], vec![]].into_iter();
        let mut pauses = 0;
        assert!(wait_until_gone(9, || lists.next().unwrap_or_default(), 10, || pauses += 1));
        assert_eq!(pauses, 2);
    }

    #[test]
    fn it_gives_up_after_the_last_look() {
        let mut pauses = 0;
        assert!(!wait_until_gone(5, || vec![5], 3, || pauses += 1));
        assert_eq!(pauses, 2);
    }

    #[test]
    fn another_process_of_the_same_app_does_not_hold_it_up() {
        assert!(wait_until_gone(5, || vec![6], 3, || {}));
    }
}
