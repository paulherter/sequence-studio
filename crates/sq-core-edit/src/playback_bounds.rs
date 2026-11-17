//! What the end of a play range does while a monitor plays.
// Swift: PlaybackBounds.swift

use sq_core_time::{Time, TimeRange};

use crate::playback::PlaybackRate;

/// What the end of a play range does while a monitor plays: stop at the end (default), or wrap around (Loop).
/// `range` limits playback to an In..Out span (Premiere "Play In to Out"); nil = the whole sequence / clip.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Default)]
pub struct PlaybackBounds {
    pub loop_playback: bool,
    range: Option<TimeRange>,
    /// Where the playhead goes when a non-looping range ends (Play Around: back to where it started). nil = stay at the end.
    pub return_to: Option<Time>,
}

/// What to do after a frame was shown.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaybackAction {
    None,
    /// Pause and park the playhead here.
    Stop(Time),
    /// Continue from here at the same rate.
    Wrap(Time),
    /// Pause and put the playhead back at the time (Play Around ended).
    StopAndReturn(Time),
}

impl PlaybackBounds {
    /// Preroll default (Premiere: 3 s before; Preferences > Playback).
    pub const DEFAULT_PREROLL: Time = Time::seconds(3);
    /// Postroll default (Premiere: 2 s after).
    pub const DEFAULT_POSTROLL: Time = Time::seconds(2);

    /// Bounds with the given loop flag, range and return time.
    pub fn new(loop_playback: bool, range: Option<TimeRange>, return_to: Option<Time>) -> PlaybackBounds {
        PlaybackBounds { loop_playback, range, return_to }
    }

    /// The In..Out span playback is limited to.
    pub fn range(&self) -> Option<TimeRange> {
        self.range
    }

    /// Sets the range; clearing it also clears `return_to` (Swift `didSet`).
    pub fn set_range(&mut self, range: Option<TimeRange>) {
        self.range = range;
        if range.is_none() {
            self.return_to = None;
        }
    }

    /// `range` extended by `preroll` before and `postroll` after, clamped to 0...`duration` (Shift+Space: Play In to Out
    /// with preroll and postroll). None when the result is empty.
    pub fn extended(range: TimeRange, preroll: Time, postroll: Time, duration: Time) -> Option<TimeRange> {
        let start = Time::ZERO.max(range.start - preroll.max(Time::ZERO));
        let end = duration.min(range.end() + postroll.max(Time::ZERO));
        if end > start { Some(TimeRange::from_end(start, end)) } else { None }
    }

    /// Play Around (Shift+K): `preroll` before to `postroll` after the playhead, clamped to 0...`duration`.
    pub fn play_around(t: Time, preroll: Time, postroll: Time, duration: Time) -> Option<TimeRange> {
        Self::extended(TimeRange::new(t, Time::ZERO), preroll, postroll, duration)
    }

    /// Decides what to do after frame `t` was shown. `duration` is the end of the content. Forward playback ends when
    /// the next frame would pass the end; reverse playback ends at the range start (or 0).
    pub fn action(&self, t: Time, rate: PlaybackRate, fd: Time, duration: Time) -> PlaybackAction {
        let start = self.range.map_or(Time::ZERO, |r| r.start);
        let end = self.range.map_or(duration, |r| r.end()).min(duration);
        if end <= start {
            return PlaybackAction::None;
        }
        if rate.is_forward() && t + fd >= end {
            if self.loop_playback {
                return PlaybackAction::Wrap(start);
            }
            if let (Some(_), Some(back)) = (self.range, self.return_to) {
                return PlaybackAction::StopAndReturn(back);
            }
            return PlaybackAction::Stop(end);
        }
        if rate.is_reverse() && t <= start && (self.range.is_some() || self.loop_playback) {
            if self.loop_playback {
                return PlaybackAction::Wrap(start.max(end - fd));
            }
            if let Some(back) = self.return_to {
                return PlaybackAction::StopAndReturn(back);
            }
            return PlaybackAction::Stop(start);
        }
        PlaybackAction::None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use PlaybackAction::{None as Nothing, Stop, Wrap};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn fd() -> Time {
        Time::new(1, 30)
    }
    fn fwd() -> PlaybackRate {
        PlaybackRate::FORWARD
    }

    #[test]
    fn stops_at_end() {
        let b = PlaybackBounds::default();
        assert_eq!(b.action(s(5), fwd(), fd(), s(10)), Nothing);
        assert_eq!(b.action(s(10) - fd(), fwd(), fd(), s(10)), Stop(s(10)));
    }

    #[test]
    fn loop_wraps_to_start() {
        let b = PlaybackBounds::new(true, None, None);
        assert_eq!(b.action(s(10) - fd(), fwd(), fd(), s(10)), Wrap(Time::ZERO));
    }

    #[test]
    fn range_limits_playback() {
        let range = Some(TimeRange::from_end(s(2), s(4)));
        let b = PlaybackBounds::new(false, range, None);
        assert_eq!(b.action(s(4) - fd(), fwd(), fd(), s(10)), Stop(s(4)));
        assert_eq!(b.action(s(2), PlaybackRate::REVERSE, fd(), s(10)), Stop(s(2)));
        let l = PlaybackBounds::new(true, range, None);
        assert_eq!(l.action(s(4) - fd(), fwd(), fd(), s(10)), Wrap(s(2)));
    }

    #[test]
    fn reverse_without_range_is_left_to_the_engine() {
        assert_eq!(PlaybackBounds::default().action(Time::ZERO, PlaybackRate::REVERSE, fd(), s(10)), Nothing);
    }

    #[test]
    fn play_around_returns_and_clearing_the_range_clears_the_return() {
        let range =
            PlaybackBounds::play_around(s(5), PlaybackBounds::DEFAULT_PREROLL, PlaybackBounds::DEFAULT_POSTROLL, s(6));
        assert_eq!(range, Some(TimeRange::from_end(s(2), s(6))));
        let mut b = PlaybackBounds::new(false, range, Some(s(5)));
        assert_eq!(b.action(s(6) - fd(), fwd(), fd(), s(10)), PlaybackAction::StopAndReturn(s(5)));
        b.set_range(None);
        assert_eq!(b.return_to, None);
    }
}
