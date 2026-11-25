// SPDX-License-Identifier: GPL-3.0-or-later
//! Status lines from threads that have no window access (the audio output): they queue here and the root host shows
//! the newest one in the status bar on its next turn.

use sq_app_shell::NoticeQueue;

/// Queues `line` for the status bar of the app that owns `queue`.
pub fn post(queue: &NoticeQueue, line: impl Into<String>) {
    queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(line.into());
}

/// Takes every line queued in `queue`, oldest first.
pub fn take(queue: &NoticeQueue) -> Vec<String> {
    std::mem::take(&mut *queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn posted_lines_come_out_once_in_order() {
        let q = NoticeQueue::default();
        post(&q, "a");
        post(&q, String::from("b"));
        assert_eq!(take(&q), ["a", "b"]);
        assert!(take(&q).is_empty());
    }

    #[test]
    fn a_line_posted_to_one_app_never_reaches_another() {
        let (one, two) = (NoticeQueue::default(), NoticeQueue::default());
        post(&one, "only for one");
        assert!(take(&two).is_empty());
        assert_eq!(take(&one), ["only for one"]);
    }
}
