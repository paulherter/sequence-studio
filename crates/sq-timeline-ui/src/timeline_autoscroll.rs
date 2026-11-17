// Swift: TimelineAutoscroll.swift
//! Edge autoscroll while a clip, an edge or the playhead is dragged near the border of the timeline (pure), and the
//! Shift axis lock of a clip drag.

/// Edge autoscroll.
pub struct TimelineAutoscroll;

impl TimelineAutoscroll {
    /// Distance from the edge, inside the view, where scrolling starts (points).
    pub const ZONE: f64 = 48.0;
    /// The pointer this far outside the view (or further) scrolls at full speed (points).
    pub const OVERSHOOT: f64 = 80.0;
    /// Top speed in points per second.
    pub const MAX_SPEED: f64 = 1800.0;

    /// Scroll speed (points per second, >= 0) for a pointer `distance_from_edge` points inside the nearest edge; negative
    /// = outside the view. Zero in the interior (>= `ZONE`), growing smoothly towards the edge, capped at `MAX_SPEED`.
    /// Monotonic: a smaller distance never scrolls slower.
    pub fn autoscroll_speed(distance_from_edge: f64) -> f64 {
        let d = distance_from_edge;
        if d >= Self::ZONE {
            return 0.0;
        }
        let t = ((Self::ZONE - d) / (Self::ZONE + Self::OVERSHOOT)).min(1.0);
        Self::MAX_SPEED * t * t
    }

    /// Signed horizontal velocity (points per second, negative = scroll left) for a pointer at `x` over the content
    /// area `view_left..<view_right`. Zero when the area is too narrow to hold both zones.
    pub fn velocity(x: f64, view_left: f64, view_right: f64) -> f64 {
        if view_right - view_left <= 2.0 * Self::ZONE {
            return 0.0;
        }
        let from_left = x - view_left;
        let from_right = view_right - x;
        if from_left < from_right {
            return -Self::autoscroll_speed(from_left);
        }
        Self::autoscroll_speed(from_right)
    }
}

/// The axis a clip drag is locked to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LockAxis {
    /// Time.
    Horizontal,
    /// Track.
    Vertical,
}

/// Shift while dragging a clip locks the movement to the axis that moved first (horizontal = time, vertical = track).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AxisLock {
    axis: Option<LockAxis>,
}

impl AxisLock {
    /// Pointer travel (points) before an axis is chosen.
    pub const THRESHOLD: f64 = 4.0;

    /// A fresh lock.
    pub fn new() -> AxisLock {
        AxisLock::default()
    }

    /// The chosen axis.
    pub fn axis(&self) -> Option<LockAxis> {
        self.axis
    }

    /// Feeds the pointer travel since mouse down. The first axis whose travel reaches `THRESHOLD` wins, the larger one
    /// when both do at once; once chosen it stays until `reset()`.
    pub fn update(&mut self, dx: f64, dy: f64) -> Option<LockAxis> {
        if self.axis.is_none() && dx.abs().max(dy.abs()) >= Self::THRESHOLD {
            self.axis = Some(if dx.abs() >= dy.abs() { LockAxis::Horizontal } else { LockAxis::Vertical });
        }
        self.axis
    }

    /// Forgets the axis.
    pub fn reset(&mut self) {
        self.axis = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn speed_is_zero_inside_and_monotonic_towards_the_edge() {
        assert_eq!(TimelineAutoscroll::autoscroll_speed(48.0), 0.0);
        let mut last = 0.0;
        for d in (-100..48).rev() {
            let s = TimelineAutoscroll::autoscroll_speed(f64::from(d));
            assert!(s >= last);
            last = s;
        }
        assert_eq!(TimelineAutoscroll::autoscroll_speed(-80.0), TimelineAutoscroll::MAX_SPEED);
    }

    #[test]
    fn velocity_points_to_the_near_edge() {
        assert!(TimelineAutoscroll::velocity(110.0, 100.0, 1100.0) < 0.0);
        assert!(TimelineAutoscroll::velocity(1090.0, 100.0, 1100.0) > 0.0);
        assert_eq!(TimelineAutoscroll::velocity(600.0, 100.0, 1100.0), 0.0);
        assert_eq!(TimelineAutoscroll::velocity(110.0, 100.0, 150.0), 0.0);
    }

    #[test]
    fn axis_lock_picks_the_first_axis_and_keeps_it() {
        let mut l = AxisLock::new();
        assert_eq!(l.update(3.0, 3.0), None);
        assert_eq!(l.update(1.0, 5.0), Some(LockAxis::Vertical));
        assert_eq!(l.update(50.0, 0.0), Some(LockAxis::Vertical));
        l.reset();
        assert_eq!(l.update(4.0, 4.0), Some(LockAxis::Horizontal));
    }
}
