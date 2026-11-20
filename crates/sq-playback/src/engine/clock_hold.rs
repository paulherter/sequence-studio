// SPDX-License-Identifier: GPL-3.0-or-later
//! The clock hold after Play: one state, one decision. The clock (and the sound) stays parked until the picture at the
//! playhead is on screen and the next `PREROLL_FRAMES` frames of every visible video layer are cached, so the first frames
//! of the run do not arrive late. The extra buffering waits at most `PREROLL_LIMIT` after Play; the first-picture wait keeps
//! its own, longer limit (`FIRST_PICTURE_LIMIT`).

use std::time::{Duration, Instant};

/// A started play waits this long for its first picture before the clock runs anyway.
pub const FIRST_PICTURE_LIMIT: Duration = Duration::from_secs(2);
/// The pre-roll after the first picture waits at most this long after Play (the product rule: up to 0.5 s).
pub const PREROLL_LIMIT: Duration = Duration::from_millis(500);
/// Frames after the playhead, per visible video layer, that are cached before the clock starts.
pub const PREROLL_FRAMES: i64 = 6;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClockHold {
    /// The clock runs (or the engine is paused).
    Running,
    /// Play was pressed at `since`; the clock waits.
    Held { since: Instant },
}

/// What the hold decides on one tick.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HoldStep {
    /// The picture at the playhead is not up yet.
    WaitFirstPicture,
    /// The picture is up, the frames ahead are still decoding.
    WaitPreRoll,
    /// Start the clock.
    Release,
}

impl ClockHold {
    pub fn is_held(&self) -> bool {
        matches!(self, ClockHold::Held { .. })
    }

    pub fn waited(&self) -> Option<Duration> {
        match self {
            ClockHold::Held { since } => Some(since.elapsed()),
            ClockHold::Running => None,
        }
    }

    /// `first_picture`: the picture at the playhead is on screen. `ahead_ready`: the frames ahead of every visible layer are
    /// cached (true when there is nothing to pre-roll).
    pub fn step(waited: Duration, first_picture: bool, ahead_ready: bool) -> HoldStep {
        if waited > FIRST_PICTURE_LIMIT {
            HoldStep::Release
        } else if !first_picture {
            HoldStep::WaitFirstPicture
        } else if ahead_ready || waited >= PREROLL_LIMIT {
            HoldStep::Release
        } else {
            HoldStep::WaitPreRoll
        }
    }
}

/// The frame indices a layer at `index` still has to show in play direction, at most `PREROLL_FRAMES`: forward up to the file's
/// `count` and the clip's end frame `end` (exclusive), backward down to 0 and the clip's start frame `start`.
pub fn ahead_indices(index: i64, forward: bool, count: i64, start: Option<i64>, end: Option<i64>) -> Vec<i64> {
    if forward {
        let top = end.map_or(count, |e| e.min(count));
        (index + 1..=index + PREROLL_FRAMES).take_while(|i| *i < top).collect()
    } else {
        let bottom = start.unwrap_or(0).max(0);
        (index - PREROLL_FRAMES..index).rev().take_while(|i| *i >= bottom).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forward_frames_stop_at_the_clip_end_and_the_file_end() {
        assert_eq!(ahead_indices(10, true, 100, None, None), vec![11, 12, 13, 14, 15, 16]);
        assert_eq!(ahead_indices(10, true, 100, None, Some(13)), vec![11, 12]);
        assert_eq!(ahead_indices(98, true, 100, None, Some(200)), vec![99]);
        assert!(ahead_indices(12, true, 100, None, Some(13)).is_empty());
    }

    #[test]
    fn reverse_frames_run_down_and_stop_at_the_clip_start_and_zero() {
        assert_eq!(ahead_indices(10, false, 100, None, None), vec![9, 8, 7, 6, 5, 4]);
        assert_eq!(ahead_indices(3, false, 100, None, None), vec![2, 1, 0]);
        assert_eq!(ahead_indices(10, false, 100, Some(8), None), vec![9, 8]);
        assert!(ahead_indices(0, false, 100, None, None).is_empty());
    }

    const FAST: Duration = Duration::from_millis(40);

    #[test]
    fn releases_once_the_picture_and_six_frames_are_ready() {
        assert_eq!(ClockHold::step(FAST, true, true), HoldStep::Release);
    }

    #[test]
    fn waits_while_the_frames_ahead_are_missing() {
        assert_eq!(ClockHold::step(FAST, true, false), HoldStep::WaitPreRoll);
        assert_eq!(ClockHold::step(Duration::from_millis(499), true, false), HoldStep::WaitPreRoll);
    }

    #[test]
    fn releases_at_half_a_second_when_the_frames_are_slow() {
        assert_eq!(ClockHold::step(PREROLL_LIMIT, true, false), HoldStep::Release);
    }

    #[test]
    fn no_pre_roll_wait_without_video_layers() {
        // No layers: the picture counts as shown and nothing is missing ahead.
        assert_eq!(ClockHold::step(Duration::ZERO, true, true), HoldStep::Release);
    }

    #[test]
    fn the_first_picture_keeps_its_two_second_limit() {
        // Past the pre-roll limit the missing picture still holds the clock.
        assert_eq!(ClockHold::step(Duration::from_millis(900), false, false), HoldStep::WaitFirstPicture);
        assert_eq!(ClockHold::step(Duration::from_millis(1999), false, true), HoldStep::WaitFirstPicture);
        assert_eq!(ClockHold::step(Duration::from_millis(2001), false, false), HoldStep::Release);
    }

    #[test]
    fn the_hold_state_reports_its_wait() {
        assert!(!ClockHold::Running.is_held());
        assert!(ClockHold::Held { since: Instant::now() }.is_held());
        assert_eq!(ClockHold::Running.waited(), None);
    }
}
