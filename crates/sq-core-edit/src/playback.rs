//! Rational playback speed and the J/K/L shuttle state machine.
// Swift: Playback.swift

use std::collections::BTreeSet;

/// Swift traps when an `Int32` result overflows.
pub(crate) fn int32(v: i64) -> i32 {
    i32::try_from(v).unwrap_or_else(|_| panic!("PlaybackRate arithmetic overflow"))
}

/// Rational playback speed. Negative = reverse, `.zero` = paused. Always stored reduced with `den > 0`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PlaybackRate {
    num: i32,
    den: i32,
}

impl PlaybackRate {
    /// `num / den`, reduced; panics for a zero denominator, like the Swift precondition.
    pub fn new(num: i32, den: i32) -> PlaybackRate {
        assert!(den != 0, "PlaybackRate denominator must not be zero");
        let (mut n, mut d) = (i64::from(num), i64::from(den));
        if d < 0 {
            n = -n;
            d = -d;
        }
        let (mut a, mut b) = (n.abs(), d);
        while b != 0 {
            (a, b) = (b, a % b);
        }
        if a > 1 {
            n /= a;
            d /= a;
        }
        if n == 0 {
            d = 1;
        }
        PlaybackRate {
            num: n.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32,
            den: d.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32,
        }
    }

    /// `n / 1`.
    pub fn whole(n: i32) -> PlaybackRate {
        PlaybackRate::new(n, 1)
    }

    /// Paused.
    pub const ZERO: PlaybackRate = PlaybackRate { num: 0, den: 1 };
    /// 1x forward.
    pub const FORWARD: PlaybackRate = PlaybackRate { num: 1, den: 1 };
    /// 1x backward.
    pub const REVERSE: PlaybackRate = PlaybackRate { num: -1, den: 1 };

    /// Numerator (negative = reverse).
    pub fn num(self) -> i32 {
        self.num
    }

    /// Denominator (always positive).
    pub fn den(self) -> i32 {
        self.den
    }

    /// Not playing.
    pub fn is_paused(self) -> bool {
        self.num == 0
    }

    /// Playing backwards.
    pub fn is_reverse(self) -> bool {
        self.num < 0
    }

    /// Playing forwards.
    pub fn is_forward(self) -> bool {
        self.num > 0
    }

    /// Absolute speed (always >= 0).
    pub fn magnitude(self) -> PlaybackRate {
        PlaybackRate::new(if self.num == i32::MIN { i32::MAX } else { self.num.abs() }, self.den)
    }

    /// Scales the magnitude by `factor`, keeping the sign.
    pub(crate) fn scaled(self, factor: i32) -> PlaybackRate {
        PlaybackRate::new(int32(i64::from(self.num) * i64::from(factor)), self.den)
    }

    pub(crate) fn is_less_than_magnitude(self, other: i32) -> bool {
        i64::from(self.num).abs() < i64::from(other) * i64::from(self.den)
    }

    pub(crate) fn is_greater_than_magnitude(self, other: i32) -> bool {
        i64::from(self.num).abs() > i64::from(other) * i64::from(self.den)
    }
}

/// A shuttle key.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ShuttleKey {
    J,
    K,
    L,
}

/// What the player does after a shuttle key event.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShuttleAction {
    SetRate(PlaybackRate),
    /// Frames, signed.
    Step(i64),
    None,
}

/// J/K/L shuttle state machine (Premiere behavior).
///
/// - L: 1, 2, 4, 8 on repeated presses (capped at 8, whatever the starting rate). J mirrors.
/// - The opposite key while playing faster than 1x slows down one step (halves the speed, not below 1x); at 1x or slower
///   (or paused) it starts the other direction at ±1 (Premiere: L L L then J J J gives 4x, 2x, 1x, then -1x).
/// - K: stop. While K is held:
///   - press of L/J is a tap: `Step(±1)` frame immediately;
///   - if the L/J key is still held after the UI's hold threshold (~0.25 s), the UI calls
///     `hold_elapsed` which returns `SetRate(±1/4)`; releasing L/J then returns `SetRate(ZERO)`.
/// - Choice: releasing K while a slow-mode L/J is still held resumes at ±1 (simple, documented).
///   Releasing K otherwise does nothing (stays paused).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Shuttle {
    rate: PlaybackRate,
    k_held: bool,
    /// L/J currently down.
    held: BTreeSet<ShuttleKey>,
    /// L/J promoted to slow mode by hold.
    slow: BTreeSet<ShuttleKey>,
}

impl Default for Shuttle {
    fn default() -> Self {
        Shuttle::new()
    }
}

impl Shuttle {
    /// Paused, no key down.
    pub fn new() -> Shuttle {
        Shuttle { rate: PlaybackRate::ZERO, k_held: false, held: BTreeSet::new(), slow: BTreeSet::new() }
    }

    /// The current speed.
    pub fn rate(&self) -> PlaybackRate {
        self.rate
    }

    /// Playback was stopped by something other than K (a click in the timeline, the transport button).
    pub fn stopped(&mut self) {
        self.rate = PlaybackRate::ZERO;
    }

    /// The playing speed was changed from outside (Shift+L / Shift+J nudge): the next L/J continues from it.
    pub fn adopt(&mut self, r: PlaybackRate) {
        self.rate = r;
    }

    /// A key went down.
    pub fn press(&mut self, key: ShuttleKey) -> ShuttleAction {
        match key {
            ShuttleKey::K => {
                self.k_held = true;
                self.set_rate(PlaybackRate::ZERO)
            }
            ShuttleKey::L | ShuttleKey::J => {
                let dir: i32 = if key == ShuttleKey::L { 1 } else { -1 };
                self.held.insert(key);
                if self.k_held {
                    return ShuttleAction::Step(i64::from(dir));
                }
                let rate = self.rate;
                let same = if dir > 0 { rate.is_forward() } else { rate.is_reverse() };
                if !same {
                    if rate.is_greater_than_magnitude(1) {
                        let half = PlaybackRate::new(rate.num, int32(i64::from(rate.den) * 2));
                        let r = if half.is_less_than_magnitude(1) {
                            PlaybackRate::whole(if rate.is_forward() { 1 } else { -1 })
                        } else {
                            half
                        };
                        return self.set_rate(r);
                    }
                    return self.set_rate(PlaybackRate::whole(dir));
                }
                if rate.is_less_than_magnitude(1) {
                    return self.set_rate(PlaybackRate::whole(dir));
                }
                let doubled = rate.scaled(2);
                let r = if doubled.is_greater_than_magnitude(8) { PlaybackRate::whole(dir * 8) } else { doubled };
                self.set_rate(r)
            }
        }
    }

    /// A key went up.
    pub fn release(&mut self, key: ShuttleKey) -> ShuttleAction {
        match key {
            ShuttleKey::K => {
                self.k_held = false;
                // Resume from slow mode if L/J is still held.
                if self.slow.remove(&ShuttleKey::L) {
                    return self.set_rate(PlaybackRate::FORWARD);
                }
                if self.slow.remove(&ShuttleKey::J) {
                    return self.set_rate(PlaybackRate::REVERSE);
                }
                ShuttleAction::None
            }
            ShuttleKey::L | ShuttleKey::J => {
                self.held.remove(&key);
                if self.slow.remove(&key) {
                    return self.set_rate(PlaybackRate::ZERO);
                }
                ShuttleAction::None
            }
        }
    }

    /// Every key went up without its key up being seen (the window lost focus while J/K/L were held). The held state is
    /// dropped; slow mode stops (nothing holds it any more), normal J/L play keeps running.
    pub fn all_keys_released(&mut self) -> ShuttleAction {
        let was_slow = !self.slow.is_empty();
        self.k_held = false;
        self.held.clear();
        self.slow.clear();
        if was_slow { self.set_rate(PlaybackRate::ZERO) } else { ShuttleAction::None }
    }

    /// Called by the UI when L/J has stayed down with K held past the hold threshold.
    pub fn hold_elapsed(&mut self, key: ShuttleKey) -> ShuttleAction {
        if !(self.k_held && key != ShuttleKey::K && self.held.contains(&key)) {
            return ShuttleAction::None;
        }
        self.slow.insert(key);
        self.set_rate(PlaybackRate::new(if key == ShuttleKey::L { 1 } else { -1 }, 4))
    }

    fn set_rate(&mut self, r: PlaybackRate) -> ShuttleAction {
        self.rate = r;
        ShuttleAction::SetRate(r)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ShuttleKey::{J, K, L};

    enum Step {
        Press(ShuttleKey),
        Release(ShuttleKey),
        Hold(ShuttleKey),
    }
    use Step::{Hold, Press, Release};

    fn run(steps: &[Step]) -> (Shuttle, Vec<ShuttleAction>) {
        let mut s = Shuttle::new();
        let mut out = Vec::new();
        for st in steps {
            out.push(match st {
                Press(k) => s.press(*k),
                Release(k) => s.release(*k),
                Hold(k) => s.hold_elapsed(*k),
            });
        }
        (s, out)
    }

    fn r(n: i32) -> PlaybackRate {
        PlaybackRate::whole(n)
    }

    #[test]
    fn rate_basics() {
        assert_eq!(PlaybackRate::new(2, 4), PlaybackRate::new(1, 2));
        assert_eq!(PlaybackRate::new(1, -4), PlaybackRate::new(-1, 4));
        assert!(r(-2).is_reverse());
        assert_eq!(r(-2).magnitude(), r(2));
        assert_eq!(PlaybackRate::new(0, 5), PlaybackRate::ZERO);
        assert!(PlaybackRate::ZERO.is_paused());
    }

    #[test]
    fn sequences() {
        let q = PlaybackRate::new(1, 4);
        let cases: Vec<(&str, Vec<Step>, PlaybackRate)> = vec![
            ("L", vec![Press(L)], r(1)),
            ("L L", vec![Press(L), Press(L)], r(2)),
            ("L L L", vec![Press(L), Press(L), Press(L)], r(4)),
            ("L x4", (0..4).map(|_| Press(L)).collect(), r(8)),
            ("L x5 capped", (0..5).map(|_| Press(L)).collect(), r(8)),
            ("J J", vec![Press(J), Press(J)], r(-2)),
            ("L L J decelerates", vec![Press(L), Press(L), Press(J)], r(1)),
            ("L J at 1x reverses", vec![Press(L), Press(J)], r(-1)),
            ("J J L decelerates", vec![Press(J), Press(J), Press(L)], r(-1)),
            ("J L at -1x reverses", vec![Press(J), Press(L)], r(1)),
            ("L L L J", vec![Press(L), Press(L), Press(L), Press(J)], r(2)),
            ("L L L J J", vec![Press(L), Press(L), Press(L), Press(J), Press(J)], r(1)),
            ("L L L J J J", vec![Press(L), Press(L), Press(L), Press(J), Press(J), Press(J)], r(-1)),
            ("L L L J K", vec![Press(L), Press(L), Press(L), Press(J), Press(K)], PlaybackRate::ZERO),
            ("L K", vec![Press(L), Press(K)], PlaybackRate::ZERO),
            ("K+L held", vec![Press(K), Press(L), Hold(L)], q),
            ("K+J held", vec![Press(K), Press(J), Hold(J)], PlaybackRate::new(-1, 4)),
            ("K+L held, release L", vec![Press(K), Press(L), Hold(L), Release(L)], PlaybackRate::ZERO),
            ("K+L held, release K", vec![Press(K), Press(L), Hold(L), Release(K)], r(1)),
            ("K+tap L", vec![Press(K), Press(L), Release(L)], PlaybackRate::ZERO),
        ];
        for (name, steps, expected) in cases {
            assert_eq!(run(&steps).0.rate(), expected, "{name}");
        }
    }

    #[test]
    fn taps_step_one_frame() {
        let (_, a) = run(&[Press(K), Press(L), Release(L)]);
        assert_eq!(a, [ShuttleAction::SetRate(PlaybackRate::ZERO), ShuttleAction::Step(1), ShuttleAction::None]);
        let (_, b) = run(&[Press(K), Press(J), Release(J)]);
        assert_eq!(b, [ShuttleAction::SetRate(PlaybackRate::ZERO), ShuttleAction::Step(-1), ShuttleAction::None]);
    }

    #[test]
    fn hold_without_k_is_ignored() {
        let (s, a) = run(&[Press(L), Hold(L)]);
        assert_eq!(a.last(), Some(&ShuttleAction::None));
        assert_eq!(s.rate(), PlaybackRate::FORWARD);
    }

    #[test]
    fn follows_nudged_rate_and_clamps_at_eight() {
        let cases = [(r(3), r(6)), (r(5), r(8)), (r(7), r(8)), (r(-5), r(-8)), (PlaybackRate::new(9, 2), r(8))];
        for (start, expected) in cases {
            let mut s = Shuttle::new();
            s.adopt(start);
            assert_eq!(s.press(if start.is_forward() { L } else { J }), ShuttleAction::SetRate(expected), "{start:?}");
        }
        let mut s = Shuttle::new();
        s.adopt(PlaybackRate::new(5, 4));
        assert_eq!(s.press(J), ShuttleAction::SetRate(r(1)));
        assert_eq!(s.press(J), ShuttleAction::SetRate(r(-1)));
    }

    #[test]
    fn all_keys_released_forgets_held_k() {
        let mut s = Shuttle::new();
        s.press(K);
        assert_eq!(s.all_keys_released(), ShuttleAction::None);
        assert_eq!(s.press(L), ShuttleAction::SetRate(r(1)));
    }

    #[test]
    fn all_keys_released_stops_slow_mode() {
        let mut s = Shuttle::new();
        s.press(K);
        s.press(L);
        assert_eq!(s.hold_elapsed(L), ShuttleAction::SetRate(PlaybackRate::new(1, 4)));
        assert_eq!(s.all_keys_released(), ShuttleAction::SetRate(PlaybackRate::ZERO));
        assert_eq!(s.rate(), PlaybackRate::ZERO);
        assert_eq!(s.all_keys_released(), ShuttleAction::None);
    }

    #[test]
    fn all_keys_released_keeps_normal_playback() {
        let mut s = Shuttle::new();
        s.press(L);
        assert_eq!(s.all_keys_released(), ShuttleAction::None);
        assert_eq!(s.rate(), r(1));
        assert_eq!(s.press(L), ShuttleAction::SetRate(r(2)));
    }
}
