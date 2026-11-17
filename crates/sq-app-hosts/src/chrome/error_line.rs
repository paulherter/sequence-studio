//! The session's last error on the status line: shown for a while, then gone. Without this a message from a task
//! that no longer matters ("The clip no longer exists.") stayed on the bar for the whole session.

use std::time::{Duration, SystemTime};

/// How long an error stays on the status bar.
pub(super) const ERROR_SHOWN: Duration = Duration::from_secs(8);

/// The error the bar saw last and when it first appeared.
#[derive(Default)]
pub(super) struct ErrorLine {
    seen: Option<(String, u64, SystemTime)>,
}

impl ErrorLine {
    /// The line to show for the session's `error` at `now`: the error while it is younger than [`ERROR_SHOWN`].
    /// `serial` is the session's error counter: the same text raised again (a refused edit tried twice) has a new serial
    /// and restarts the clock; the same message still standing keeps its clock.
    pub(super) fn show(&mut self, error: Option<&str>, serial: u64, now: SystemTime) -> Option<String> {
        let Some(e) = error else {
            self.seen = None;
            return None;
        };
        if self.seen.as_ref().is_none_or(|(text, n, _)| text != e || *n != serial) {
            self.seen = Some((e.to_string(), serial, now));
        }
        let (text, _, at) = self.seen.as_ref()?;
        now.duration_since(*at).is_ok_and(|d| d < ERROR_SHOWN).then(|| text.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_error_disappears_after_a_few_seconds_and_a_new_one_shows_again() {
        let t0 = SystemTime::UNIX_EPOCH + Duration::from_secs(1000);
        let mut line = ErrorLine::default();
        assert_eq!(line.show(Some("The clip no longer exists."), 1, t0).as_deref(), Some("The clip no longer exists."));
        assert!(line.show(Some("The clip no longer exists."), 1, t0 + Duration::from_secs(7)).is_some());
        assert_eq!(line.show(Some("The clip no longer exists."), 1, t0 + Duration::from_secs(9)), None);
        let later = t0 + Duration::from_secs(60);
        assert_eq!(line.show(Some("The track is locked."), 2, later).as_deref(), Some("The track is locked."));
        // The same refusal raised again after it expired shows again (a new serial restarts the clock).
        let again = later + Duration::from_secs(30);
        assert_eq!(line.show(Some("The track is locked."), 2, again), None);
        assert_eq!(line.show(Some("The track is locked."), 3, again).as_deref(), Some("The track is locked."));
        assert_eq!(line.show(None, 3, again), None);
    }
}
