//! Shift+L / Shift+J: fine changes of the playing speed.
// Swift: PlaybackNudge.swift

use crate::playback::{PlaybackRate, int32};

impl PlaybackRate {
    /// Shift+L / Shift+J (Premiere "Shuttle Slow Right / Left"): a fine change of the playing speed by 1/4.
    /// From a stop it starts at 1.25x in that direction. In the key's own direction it speeds up (at most 8x); against the
    /// current direction it slows down and stops when the speed reaches zero.
    pub fn nudged(self, forward: bool) -> PlaybackRate {
        let dir: i32 = if forward { 1 } else { -1 };
        if self.is_paused() {
            return PlaybackRate::new(dir * 5, 4);
        }
        // (num/den + dir/4) * 4 * den, reduced by the constructor.
        let signed = i64::from(self.num()) * 4 + i64::from(dir) * i64::from(self.den());
        let (signed, den4) = (int32(signed), int32(i64::from(self.den()) * 4));
        let r = PlaybackRate::new(signed, den4);
        if r.is_paused() || (r.is_forward() != self.is_forward()) {
            return PlaybackRate::ZERO;
        }
        if i64::from(r.num()).abs() > 8 * i64::from(r.den()) { self } else { r }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(n: i32, d: i32) -> PlaybackRate {
        PlaybackRate::new(n, d)
    }

    #[test]
    fn starts_at_five_quarters_from_stop() {
        assert_eq!(PlaybackRate::ZERO.nudged(true), r(5, 4));
        assert_eq!(PlaybackRate::ZERO.nudged(false), r(-5, 4));
    }

    #[test]
    fn speeds_up_in_own_direction_and_slows_against_it() {
        assert_eq!(r(1, 1).nudged(true), r(5, 4));
        assert_eq!(r(5, 4).nudged(true), r(3, 2));
        assert_eq!(r(2, 1).nudged(false), r(7, 4));
        assert_eq!(r(-1, 1).nudged(false), r(-5, 4));
    }

    #[test]
    fn stops_when_slowed_to_zero_and_caps_at_eight() {
        assert_eq!(r(1, 4).nudged(false), PlaybackRate::ZERO);
        assert_eq!(r(8, 1).nudged(true), r(8, 1));
    }
}
