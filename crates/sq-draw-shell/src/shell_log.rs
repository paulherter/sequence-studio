//! A log line from the shell flows. The app installs its logger once; with none installed (tests) lines go nowhere.

use std::sync::OnceLock;

static SINK: OnceLock<fn(bool, &str)> = OnceLock::new();

/// Installs the app logger: `f(is_error, line)`. Only the first call counts.
pub fn set_log_sink(f: fn(bool, &str)) {
    let _ = SINK.set(f);
}

pub(crate) fn info(line: &str) {
    if let Some(f) = SINK.get() {
        f(false, line);
    }
}

pub(crate) fn error(line: &str) {
    if let Some(f) = SINK.get() {
        f(true, line);
    }
}
