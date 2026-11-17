// Swift: EaseHandleDragMath.swift
//! Pure axis rule of an ease handle drag.

use std::ops::RangeInclusive;

/// Pure axis rule of an ease handle drag (like Premiere, no accidental bounce): a drag starts horizontal only (Reach);
/// the vertical part (speed at the key) applies once the pointer has left the dead zone around the press, then follows
/// both axes freely. Shift keeps the drag horizontal only.
pub enum EaseHandleDragMath {}

impl EaseHandleDragMath {
    /// Points of vertical travel from the press before the height starts to follow.
    pub const DEAD_ZONE: f64 = 6.0;

    /// Whether the vertical part is on: it latches once past the dead zone, and Shift switches it off.
    pub fn is_vertical(was_vertical: bool, press_y: f64, y: f64, shift: bool) -> bool {
        if shift {
            return false;
        }
        was_vertical || (y - press_y).abs() > Self::DEAD_ZONE
    }

    /// The speed to write: the pointer's speed when vertical is on, else the speed the handle had (`kept`),
    /// clamped to what the handle's value part can store (`dy = speed * dx`, `dx` = reach).
    pub fn speed(
        vertical: bool,
        pointer: f64,
        kept: f64,
        reach: f64,
        value_range: Option<&RangeInclusive<f64>>,
    ) -> f64 {
        let s = if vertical { pointer } else { kept };
        let Some(r) = value_range else { return s };
        if reach <= 1e-9 {
            return s;
        }
        s.clamp(*r.start() / reach, *r.end() / reach)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stays_horizontal_inside_the_dead_zone() {
        assert!(!EaseHandleDragMath::is_vertical(false, 50.0, 55.9, false));
        assert!(!EaseHandleDragMath::is_vertical(false, 50.0, 44.1, false));
    }

    #[test]
    fn follows_vertically_past_the_dead_zone_and_latches() {
        assert!(EaseHandleDragMath::is_vertical(false, 50.0, 56.5, false));
        assert!(EaseHandleDragMath::is_vertical(true, 50.0, 50.0, false));
    }

    #[test]
    fn shift_forces_horizontal() {
        assert!(!EaseHandleDragMath::is_vertical(true, 50.0, 90.0, true));
        assert!(!EaseHandleDragMath::is_vertical(false, 50.0, 90.0, true));
    }

    #[test]
    fn speed_keeps_or_follows_and_clamps() {
        let r = -2.0..=3.0;
        assert_eq!(EaseHandleDragMath::speed(false, 9.0, 1.5, 0.5, Some(&r)), 1.5);
        assert_eq!(EaseHandleDragMath::speed(true, 2.0, 1.0, 0.5, Some(&r)), 2.0);
        assert_eq!(EaseHandleDragMath::speed(true, 99.0, 1.0, 0.5, Some(&r)), 6.0);
        let unit = 0.0..=1.0;
        assert_eq!(EaseHandleDragMath::speed(true, -99.0, 1.0, 0.5, Some(&unit)), 0.0);
        assert_eq!(EaseHandleDragMath::speed(true, 99.0, 1.0, 1.0, None), 99.0);
    }
}
