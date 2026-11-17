//! Springs that carry a release velocity, and the settle of a dropped item.
//!
//! One enum per animation ([`DropSettle`]), transitions in one place, reduced motion = no spring, instant
//! (docs/rust/MOTION.md). `ReleaseSpring` has no overshoot of its own (critical damping): an overscrolled view or a dragged
//! divider never swings past its rest place by itself; a dropped item uses [`DropSettle`] (the `Spring` ease, 2.5% overshoot).

use crate::motion::{self, Ease, duration};
use sq_uikit::controls_grid::CGPoint;

/// A critically damped spring (response 0.35 s, damping 1.0) from `offset` away from its rest place, seeded with the
/// release `velocity` (points per second, the same sign convention as `offset`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ReleaseSpring {
    offset: f64,
    velocity: f64,
}

impl ReleaseSpring {
    /// Seconds of one spring period (the tuning "response").
    pub const RESPONSE: f64 = 0.35;
    /// Angular speed of the critically damped spring.
    pub const OMEGA: f64 = std::f64::consts::TAU / Self::RESPONSE;

    /// A spring released at `offset` from rest moving at `velocity`.
    pub fn new(offset: f64, velocity: f64) -> ReleaseSpring {
        ReleaseSpring { offset, velocity }
    }

    /// The offset from rest `t` seconds after the release. A velocity toward rest never carries it past rest.
    pub fn offset(&self, t: f64) -> f64 {
        let t = t.max(0.0);
        let w = Self::OMEGA;
        let x = (self.offset + (self.velocity + w * self.offset) * t) * (-w * t).exp();
        if x * self.offset < 0.0 { 0.0 } else { x }
    }

    /// The speed `t` seconds after the release.
    pub fn velocity(&self, t: f64) -> f64 {
        let t = t.max(0.0);
        let w = Self::OMEGA;
        let c = self.velocity + w * self.offset;
        (c - w * (self.offset + c * t)) * (-w * t).exp()
    }

    /// Close enough to rest to snap: under a quarter point and slow, or after three seconds.
    pub fn is_settled(&self, t: f64) -> bool {
        t > 3.0 || (self.offset(t).abs() < 0.25 && self.velocity(t).abs() < 2.0)
    }
}

/// A dropped item settling onto its place: it starts `from` away from rest and arrives with the `Spring` ease over
/// `MEDIUM` (180 ms). The only spring with overshoot; never used on a control.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub enum DropSettle {
    /// At its place.
    #[default]
    Rest,
    /// On its way from `from` (an offset from the place), started at `start` (seconds, the frame clock).
    Settling { from: CGPoint, start: f64 },
}

impl DropSettle {
    /// The item was dropped `from` away from where it lands. Reduced motion, or no distance: it just lands.
    pub fn drop(from: CGPoint, now: f64) -> DropSettle {
        if motion::reduce_motion() || (from.x.abs() < 0.5 && from.y.abs() < 0.5) {
            return DropSettle::Rest;
        }
        DropSettle::Settling { from, start: now }
    }

    /// A press (a new drag) catches the item where it is: it lands at once.
    pub fn press(&mut self) {
        *self = DropSettle::Rest;
    }

    /// The offset from its place at `now`; lands (and turns to `Rest`) when the ease ends.
    pub fn offset(&mut self, now: f64) -> CGPoint {
        let DropSettle::Settling { from, start } = *self else { return CGPoint { x: 0.0, y: 0.0 } };
        let p = (now - start) / duration::MEDIUM;
        if p >= 1.0 {
            *self = DropSettle::Rest;
            return CGPoint { x: 0.0, y: 0.0 };
        }
        let left = 1.0 - Ease::Spring.apply(p);
        CGPoint { x: from.x * left, y: from.y * left }
    }

    /// Whether the host keeps drawing frames.
    pub fn is_running(&self) -> bool {
        matches!(self, DropSettle::Settling { .. })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_release_velocity_changes_the_settle_curve() {
        let rest = ReleaseSpring::new(-40.0, 0.0);
        let thrown_out = ReleaseSpring::new(-40.0, -300.0); // still moving further out
        let thrown_back = ReleaseSpring::new(-40.0, 300.0); // moving toward rest
        let t = 0.1;
        assert!(thrown_out.offset(t).abs() > rest.offset(t).abs(), "momentum outward goes deeper first");
        assert!(thrown_back.offset(t).abs() < rest.offset(t).abs(), "momentum inward returns sooner");
        assert_eq!(rest.offset(0.0), -40.0);
    }

    #[test]
    fn the_spring_settles_and_never_swings_past_rest() {
        for v in [-500.0, 0.0, 200.0, 5000.0] {
            let s = ReleaseSpring::new(-40.0, v);
            for i in 0..200 {
                assert!(s.offset(f64::from(i) * 0.01) <= 0.0, "no overshoot at v={v}");
            }
            assert!(s.is_settled(1.5), "settled at v={v}");
        }
    }

    #[test]
    fn a_drop_overshoots_a_little_then_lands_and_reduced_motion_lands_at_once() {
        motion::set_reduce_motion(false);
        let mut d = DropSettle::drop(CGPoint { x: 20.0, y: 0.0 }, 0.0);
        assert!(d.is_running());
        assert_eq!(d.offset(0.0).x, 20.0);
        let mut min: f64 = 0.0;
        for i in 1..18 {
            min = min.min(d.offset(f64::from(i) * 0.01).x);
        }
        assert!(min < 0.0 && min > -1.0, "2.5% overshoot of 20 points, got {min}");
        assert_eq!(d.offset(0.2).x, 0.0);
        assert!(!d.is_running());
        motion::set_reduce_motion(true);
        assert_eq!(DropSettle::drop(CGPoint { x: 20.0, y: 5.0 }, 0.0), DropSettle::Rest);
        motion::set_reduce_motion(false);
    }

    #[test]
    fn a_press_lands_a_settling_drop_at_once() {
        motion::set_reduce_motion(false);
        let mut d = DropSettle::drop(CGPoint { x: 20.0, y: 0.0 }, 0.0);
        d.press();
        assert_eq!(d, DropSettle::Rest);
        assert_eq!(d.offset(0.05).x, 0.0);
    }
}
