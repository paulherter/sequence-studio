//! Start timing, behind `SQ_START_TRACE=1`: when each start step ended, and every stretch where the UI thread did not
//! return to the message loop. Windows marks a window "(Not Responding)" after about 5 s without a pump, so a start step
//! that long on the UI thread is a bug; this log names it (the app log, info level).

use crate::applog;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// A handler call at least this long is logged (a frame is 16 ms; the user feels 100 ms).
const SLOW_BLOCK: Duration = Duration::from_millis(100);

static ORIGIN: OnceLock<Instant> = OnceLock::new();
static ENABLED: OnceLock<bool> = OnceLock::new();
/// The longest handler call so far, in microseconds.
static LONGEST_US: AtomicU64 = AtomicU64::new(0);

fn enabled() -> bool {
    *ENABLED.get_or_init(|| std::env::var_os("SQ_START_TRACE").is_some_and(|v| !v.is_empty() && v != "0"))
}

/// Starts the clock of the trace: the first thing `run` does.
pub fn begin() {
    let _ = ORIGIN.set(Instant::now());
}

fn since_begin() -> f64 {
    ORIGIN.get().map_or(0.0, |t| t.elapsed().as_secs_f64() * 1e3)
}

/// One line: `name` happened now.
pub fn mark(name: &str) {
    sq_os::trace::mark_dyn("start", name);
    if enabled() {
        applog::info(&format!("start trace +{:.0} ms: {name}", since_begin()));
    }
}

/// The end line, once the first frame is on screen: the longest block of the whole start.
pub fn first_frame() {
    if enabled() {
        let longest = Duration::from_micros(LONGEST_US.load(Ordering::Relaxed));
        applog::info(&format!(
            "start trace +{:.0} ms: first frame presented, longest UI-thread block {:.0} ms",
            since_begin(),
            longest.as_secs_f64() * 1e3
        ));
    }
}

/// A loop turn or redraw that took at least this long is broken down by phase (see `slow_turn`).
const SLOW_TURN: Duration = Duration::from_millis(50);

/// The breakdown of a slow UI-thread turn: which phase (inbox, tasks, settle, frame) and which host or task took the time.
/// Logged when `SQ_START_TRACE` or `SQ_LATENCY_LOG` is on; costs nothing otherwise.
pub fn slow_turn(took: Duration, times: sq_app_shell::TurnTimes, hosts: &[(&'static str, &'static str, Duration)]) {
    if took < SLOW_TURN || !(enabled() || crate::latency_log::on()) {
        return;
    }
    let ms = |d: Duration| d.as_secs_f64() * 1e3;
    let short = |name: &str| name.rsplit("::").next().unwrap_or(name).to_string();
    let (poll_took, poll_name) = times.slowest_poll;
    let mut top: Vec<_> = hosts.iter().filter(|h| h.2 >= Duration::from_millis(4)).collect();
    top.sort_by_key(|h| std::cmp::Reverse(h.2));
    let slowest_host =
        top.iter().take(8).map(|h| format!("{}:{} {:.0}", short(h.0), h.1, ms(h.2))).collect::<Vec<_>>().join(", ");
    let line = format!(
        "slow turn {:.0} ms (+{:.0} ms): drain {:.0} tasks {:.0} settle {:.0} frame {:.0}; slowest poll {:.0} ms {poll_name}; slowest {slowest_host}",
        ms(took),
        since_begin(),
        ms(times.drain),
        ms(times.tasks),
        ms(times.settle),
        ms(times.frame),
        ms(poll_took),
    );
    if enabled() {
        applog::info(&line);
    }
    if crate::latency_log::on() {
        sq_os::errln!("{line}");
    }
}

/// Times one handler call of the event loop until it is dropped.
pub struct Block {
    what: &'static str,
    began: Option<Instant>,
}

/// Starts timing `what`; nothing is measured unless the trace is on.
pub fn block(what: &'static str) -> Block {
    Block { what, began: enabled().then(Instant::now) }
}

impl Drop for Block {
    fn drop(&mut self) {
        let Some(began) = self.began else { return };
        let took = began.elapsed();
        LONGEST_US.fetch_max(u64::try_from(took.as_micros()).unwrap_or(u64::MAX), Ordering::Relaxed);
        if took >= SLOW_BLOCK {
            applog::info(&format!(
                "start trace +{:.0} ms: UI thread blocked {:.0} ms in {}",
                since_begin(),
                took.as_secs_f64() * 1e3,
                self.what
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_block_of_an_untraced_run_measures_nothing() {
        // The env var is not set in the test run: the guard must cost nothing and record nothing.
        let b = block("test");
        assert!(b.began.is_none());
    }
}
