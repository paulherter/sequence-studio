//! Decides when failed presents before the first frame mean the window will never show the app (`SQS-204`) and when they
//! are the ordinary noise of a cold start: the first draws can come before the surface is configured, and a drawable that
//! is late, outdated or timed out is no failure at all. Any answer from the surface (a frame or "not ready yet") ends the
//! streak; only an unbroken run of failures that lasts long enough counts.

use std::time::Duration;

/// Failures in a row before a verdict is possible.
const MIN_ERRORS: u32 = 5;
/// How long the unbroken run must last when the surface was configured: a configure and its first frame fit in far less.
const SPAN_CONFIGURED: Duration = Duration::from_secs(3);
/// The same when the surface is not configured (a configure that panics keeps failing): longer, because the loop
/// reconfigures it on every draw and a slow display may need a moment.
const SPAN_UNCONFIGURED: Duration = Duration::from_secs(10);

/// The run of failed presents since the last answer.
#[derive(Debug, Default)]
pub struct PresentWatch {
    errors: u32,
    since: Option<Duration>,
}

impl PresentWatch {
    /// The surface answered (a presented frame, or no drawable yet): the streak is over.
    pub fn answered(&mut self) {
        *self = PresentWatch::default();
    }

    /// A present failed `now` after the window opened. True once the unbroken run is long enough to be a failure.
    pub fn failed(&mut self, now: Duration, configured: bool) -> bool {
        self.errors = self.errors.saturating_add(1);
        let since = *self.since.get_or_insert(now);
        let span = if configured { SPAN_CONFIGURED } else { SPAN_UNCONFIGURED };
        self.errors >= MIN_ERRORS && now.saturating_sub(since) >= span
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn five_failures_within_a_cold_start_tick_are_no_verdict() {
        let mut w = PresentWatch::default();
        let verdicts: Vec<bool> = (0..5).map(|i| w.failed(ms(i * 16), true)).collect();
        assert!(verdicts.iter().all(|v| !v), "5 errors in 64 ms: {verdicts:?}");
        assert!(!w.failed(ms(2_900), true), "even a long run is no verdict before 3 s");
    }

    #[test]
    fn an_unbroken_run_of_three_seconds_is_the_verdict() {
        let mut w = PresentWatch::default();
        for i in 0..200 {
            assert!(!w.failed(ms(i * 15), true), "failure {i} is too early");
        }
        assert!(w.failed(ms(3_000), true));
        assert!(w.failed(ms(3_016), true), "and it stays a verdict");
    }

    #[test]
    fn any_answer_from_the_surface_ends_the_streak() {
        let mut w = PresentWatch::default();
        for i in 0..100 {
            w.failed(ms(i * 30), true);
            if i % 4 == 3 {
                w.answered(); // a late drawable (Ok(false)) between the failures
            }
        }
        assert!(!w.failed(ms(3_100), true), "failures with answers in between never add up");
        w.failed(ms(3_200), true);
        w.answered();
        assert!(!w.failed(ms(6_500), true), "a run restarts after an answer");
    }

    #[test]
    fn a_surface_that_never_configures_needs_ten_seconds() {
        let mut w = PresentWatch::default();
        for i in 0..400 {
            assert!(!w.failed(ms(i * 24), false), "failure {i}");
        }
        assert!(!w.failed(ms(9_900), false));
        assert!(w.failed(ms(10_000), false));
    }
}
