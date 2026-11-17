// SPDX-License-Identifier: GPL-3.0-or-later
//! Status lines from threads that have no window access (the audio output): they queue here and the root host shows
//! the newest one in the status bar on its next turn.

use std::sync::Mutex;

static LINES: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Queues `line` for the status bar.
pub fn post(line: impl Into<String>) {
    LINES.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(line.into());
}

/// Takes every queued line, oldest first.
pub fn take() -> Vec<String> {
    std::mem::take(&mut *LINES.lock().unwrap_or_else(std::sync::PoisonError::into_inner))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn posted_lines_come_out_once_in_order() {
        let _ = take();
        post("a");
        post(String::from("b"));
        assert_eq!(take(), ["a", "b"]);
        assert!(take().is_empty());
    }
}
