// Swift: MonitorGuides.swift
//! User guides of the Program monitor: vertical positions are fractions of the picture width, horizontal ones of its
//! height (0...1, origin top-left). Guides belong to the monitor session, not to the project.

/// Which way a guide runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis {
    /// A vertical line.
    Vertical,
    /// A horizontal line.
    Horizontal,
}

/// One guide.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Guide {
    /// Its direction.
    pub axis: Axis,
    /// Its place as a fraction of the picture.
    pub fraction: f64,
}

/// The guides of one monitor session.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MonitorGuides {
    vertical: Vec<f64>,
    horizontal: Vec<f64>,
}

impl MonitorGuides {
    /// Ruler tick spacing (fraction of the picture) with major ticks every 10 %, minor every 5 % (always the same
    /// scale: the ruler reads in percent of the frame, independent of the sequence size).
    pub const MINOR_STEP: f64 = 0.05;

    /// No guides.
    pub fn new() -> MonitorGuides {
        MonitorGuides::default()
    }

    /// The vertical guides.
    pub fn vertical(&self) -> &[f64] {
        &self.vertical
    }
    /// The horizontal guides.
    pub fn horizontal(&self) -> &[f64] {
        &self.horizontal
    }
    /// Whether there are none.
    pub fn is_empty(&self) -> bool {
        self.vertical.is_empty() && self.horizontal.is_empty()
    }
    /// Every guide, vertical first.
    pub fn all(&self) -> Vec<Guide> {
        let v = self.vertical.iter().map(|f| Guide { axis: Axis::Vertical, fraction: *f });
        v.chain(self.horizontal.iter().map(|f| Guide { axis: Axis::Horizontal, fraction: *f })).collect()
    }

    fn list_mut(&mut self, axis: Axis) -> &mut Vec<f64> {
        match axis {
            Axis::Vertical => &mut self.vertical,
            Axis::Horizontal => &mut self.horizontal,
        }
    }

    /// Adds a guide (clamped into the picture) and returns its index within its axis.
    pub fn add(&mut self, axis: Axis, fraction: f64) -> usize {
        let f = fraction.clamp(0.0, 1.0);
        let list = self.list_mut(axis);
        list.push(f);
        list.len() - 1
    }

    /// Moves a guide (Swift `move`).
    pub fn move_guide(&mut self, axis: Axis, index: usize, fraction: f64) {
        let f = fraction.clamp(0.0, 1.0);
        if let Some(g) = self.list_mut(axis).get_mut(index) {
            *g = f;
        }
    }

    /// Removes a guide.
    pub fn remove(&mut self, axis: Axis, index: usize) {
        let list = self.list_mut(axis);
        if index < list.len() {
            list.remove(index);
        }
    }

    /// Removes all guides.
    pub fn clear(&mut self) {
        self.vertical = vec![];
        self.horizontal = vec![];
    }

    fn list(&self, axis: Axis) -> &[f64] {
        match axis {
            Axis::Vertical => &self.vertical,
            Axis::Horizontal => &self.horizontal,
        }
    }

    /// The guide nearest to `fraction` on `axis` within `tolerance` (fractions), or `None`.
    pub fn nearest(&self, axis: Axis, fraction: f64, tolerance: f64) -> Option<usize> {
        let mut best: Option<(usize, f64)> = None;
        for (i, g) in self.list(axis).iter().enumerate() {
            let d = (g - fraction).abs();
            if d <= tolerance && best.is_none_or(|b| d < b.1) {
                best = Some((i, d));
            }
        }
        best.map(|b| b.0)
    }

    /// Snaps `fraction` to a guide on `axis` within `tolerance`; unchanged when none is near.
    pub fn snapped(&self, axis: Axis, fraction: f64, tolerance: f64) -> f64 {
        match self.nearest(axis, fraction, tolerance) {
            Some(i) => self.list(axis)[i],
            None => fraction,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_move_remove_clamp_into_the_picture() {
        let mut g = MonitorGuides::new();
        assert!(g.is_empty());
        let v = g.add(Axis::Vertical, 1.4);
        let h = g.add(Axis::Horizontal, -0.2);
        assert!(g.vertical() == [1.0] && g.horizontal() == [0.0]);
        g.move_guide(Axis::Vertical, v, 0.25);
        assert_eq!(g.vertical(), [0.25]);
        g.remove(Axis::Horizontal, h);
        assert!(g.horizontal().is_empty());
        g.move_guide(Axis::Vertical, 9, 0.5);
        assert_eq!(g.vertical(), [0.25]);
        g.clear();
        assert!(g.is_empty());
    }

    #[test]
    fn nearest_and_snap_respect_the_tolerance() {
        let mut g = MonitorGuides::new();
        g.add(Axis::Vertical, 0.2);
        g.add(Axis::Vertical, 0.5);
        assert_eq!(g.nearest(Axis::Vertical, 0.48, 0.05), Some(1));
        assert_eq!(g.nearest(Axis::Vertical, 0.35, 0.05), None);
        assert_eq!(g.snapped(Axis::Vertical, 0.49, 0.02), 0.5);
        assert_eq!(g.snapped(Axis::Vertical, 0.4, 0.02), 0.4);
        assert_eq!(g.snapped(Axis::Horizontal, 0.5, 0.5), 0.5);
    }

    #[test]
    fn all_lists_both_axes() {
        let mut g = MonitorGuides::new();
        g.add(Axis::Vertical, 0.1);
        g.add(Axis::Horizontal, 0.9);
        assert_eq!(
            g.all(),
            vec![Guide { axis: Axis::Vertical, fraction: 0.1 }, Guide { axis: Axis::Horizontal, fraction: 0.9 }]
        );
    }
}
