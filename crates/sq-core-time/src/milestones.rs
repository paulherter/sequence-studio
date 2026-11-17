//! Open-to-first-picture timing: one line per milestone with the milliseconds since the project open began.
//! `begin` starts the clock; `mark` reports a milestone once per name (repeats are dropped) through the installed sink.

use std::sync::{Mutex, OnceLock};
use std::time::Instant;

static SINK: OnceLock<fn(&str)> = OnceLock::new();
static STATE: Mutex<Option<(Instant, Vec<String>)>> = Mutex::new(None);

/// Installs the log sink (the app log at debug level). Only the first call counts.
pub fn set_sink(f: fn(&str)) {
    let _ = SINK.set(f);
}

static INFO_SINK: OnceLock<fn(&str)> = OnceLock::new();

/// Installs the sink of [`info`] (the app log at info level). Only the first call counts.
pub fn set_info_sink(f: fn(&str)) {
    let _ = INFO_SINK.set(f);
}

/// One line for the normal app log (not a timing milestone): facts worth finding in a bug report, like the encoder an export opened.
pub fn info(line: &str) {
    if let Some(f) = INFO_SINK.get() {
        f(line);
    }
}

/// Starts a new open: the clock restarts and every milestone may be reported again.
pub fn begin(name: &str) {
    *STATE.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), Vec::new()));
    emit(0.0, name);
}

/// Reports `name` once since the last `begin`; nothing before the first `begin`.
pub fn mark(name: &str) {
    let ms = {
        let mut g = STATE.lock().unwrap_or_else(|e| e.into_inner());
        let Some((start, seen)) = g.as_mut() else { return };
        if seen.iter().any(|s| s == name) {
            return;
        }
        seen.push(name.to_string());
        start.elapsed().as_secs_f64() * 1000.0
    };
    emit(ms, name);
}

/// One log line through the sink, every time (no clock, no repeat filter): state changes that are not part of an open.
pub fn note(line: &str) {
    if let Some(f) = SINK.get() {
        f(line);
    }
}

fn emit(ms: f64, name: &str) {
    if let Some(f) = SINK.get() {
        f(&format!("open +{ms:.0} ms {name}"));
    }
}

/// The milestones reported since the last `begin`, in order.
pub fn reported() -> Vec<String> {
    STATE.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|(_, s)| s.clone()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn marks_once_per_open_and_restart_on_begin() {
        begin("t");
        mark("a");
        mark("a");
        mark("b");
        assert_eq!(reported(), ["a", "b"]);
        begin("t");
        assert!(reported().is_empty());
        mark("a");
        assert_eq!(reported(), ["a"]);
    }
}
