//! Latest seek wins: seeks queued behind each other (a scrub drag while the render thread was busy) are not all planned
//! and decoded, only the newest one is.

use super::handle::{Command, Msg};

/// Drops every `Seek` that a later `Seek` of the same batch replaces. A seek is kept when a command, query or stop sits
/// between it and the next seek (play, pause, step, scrub, edits and readbacks must see the order they were sent in);
/// arriving pictures do not count, they are handled in order anyway.
pub(crate) fn coalesce_seeks(batch: Vec<Msg>) -> Vec<Msg> {
    let mut newer_seek = false;
    let mut keep: Vec<bool> = batch
        .iter()
        .rev()
        .map(|m| match m {
            Msg::Command(Command::Seek(_)) => !std::mem::replace(&mut newer_seek, true),
            Msg::Command(_) | Msg::Query(_) | Msg::Stop => {
                newer_seek = false;
                true
            }
            _ => true,
        })
        .collect();
    keep.reverse();
    batch.into_iter().zip(keep).filter_map(|(m, k)| k.then_some(m)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    fn seek(s: i64) -> Msg {
        Msg::Command(Command::Seek(Time::seconds(s)))
    }

    fn seeks(batch: &[Msg]) -> Vec<Time> {
        batch
            .iter()
            .filter_map(|m| match m {
                Msg::Command(Command::Seek(t)) => Some(*t),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn queued_seeks_leave_only_the_newest() {
        let out = coalesce_seeks(vec![seek(1), seek(2), seek(3)]);
        assert_eq!(seeks(&out), vec![Time::seconds(3)]);
    }

    #[test]
    fn a_command_between_two_seeks_keeps_both() {
        let out = coalesce_seeks(vec![seek(1), Msg::Command(Command::Pause), seek(2)]);
        assert_eq!(seeks(&out), vec![Time::seconds(1), Time::seconds(2)]);
        let out = coalesce_seeks(vec![seek(1), Msg::Query(Box::new(|_| ())), seek(2)]);
        assert_eq!(seeks(&out), vec![Time::seconds(1), Time::seconds(2)]);
    }

    #[test]
    fn a_seek_after_the_last_command_replaces_only_its_own_run() {
        let out = coalesce_seeks(vec![seek(1), seek(2), Msg::Command(Command::Pause), seek(3), seek(4)]);
        assert_eq!(seeks(&out), vec![Time::seconds(2), Time::seconds(4)]);
        assert_eq!(out.len(), 3);
    }
}
