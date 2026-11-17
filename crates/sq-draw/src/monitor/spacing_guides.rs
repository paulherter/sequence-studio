// Swift: SpacingGuides.swift
//! Spacing guides of the Program monitor: while a layer is moved between two other layers, it snaps to the position
//! where the gap to the left layer equals the gap to the right one (same on y). Offset space, y down, like `SnapGuides`.

use sq_uikit::controls_grid::CGRect;

/// One gap to mark: `from`..`to` along an axis, at `cross` on the other axis.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Gap {
    /// True: the gap is measured on y (a vertical run).
    pub vertical: bool,
    /// Start.
    pub from: f64,
    /// End.
    pub to: f64,
    /// Position on the other axis.
    pub cross: f64,
}

/// The snap: the shift to apply and the gaps to mark.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SnapResult {
    /// Shift on x.
    pub dx: f64,
    /// Shift on y.
    pub dy: f64,
    /// The gaps to draw.
    pub gaps: Vec<Gap>,
}

impl SnapResult {
    /// No snap.
    pub fn none() -> SnapResult {
        SnapResult::default()
    }
}

/// Spacing guides.
pub enum SpacingGuides {}

struct EqualGap {
    shift: f64,
    before_edge: f64,
    after_edge: f64,
}

fn is_empty(r: &CGRect) -> bool {
    r.width == 0.0 || r.height == 0.0
}

impl SpacingGuides {
    /// `box_` is the moving layer's bounds, `others` the other layers' bounds. Only layers that overlap the box on the
    /// cross axis count as neighbors. The nearest pair per axis within `threshold` wins.
    pub fn snap(box_: CGRect, others: &[CGRect], threshold: f64) -> SnapResult {
        let mut r = SnapResult::none();
        // x axis: neighbors overlapping in y
        let row_mates: Vec<CGRect> = others
            .iter()
            .filter(|o| !is_empty(o) && o.max_y() > box_.min_y() && o.min_y() < box_.max_y())
            .copied()
            .collect();
        let before: Vec<(f64, f64)> =
            row_mates.iter().filter(|o| o.max_x() <= box_.min_x() + 1e-6).map(|o| (o.min_x(), o.max_x())).collect();
        let after: Vec<(f64, f64)> =
            row_mates.iter().filter(|o| o.min_x() >= box_.max_x() - 1e-6).map(|o| (o.min_x(), o.max_x())).collect();
        if let Some(s) = Self::equal_gap(box_.min_x(), box_.max_x(), &before, &after, threshold) {
            r.dx = s.shift;
            let y = box_.mid_y();
            r.gaps.push(Gap { vertical: false, from: s.before_edge, to: box_.min_x() + s.shift, cross: y });
            r.gaps.push(Gap { vertical: false, from: box_.max_x() + s.shift, to: s.after_edge, cross: y });
        }
        let col_mates: Vec<CGRect> = others
            .iter()
            .filter(|o| !is_empty(o) && o.max_x() > box_.min_x() && o.min_x() < box_.max_x())
            .copied()
            .collect();
        let before: Vec<(f64, f64)> =
            col_mates.iter().filter(|o| o.max_y() <= box_.min_y() + 1e-6).map(|o| (o.min_y(), o.max_y())).collect();
        let after: Vec<(f64, f64)> =
            col_mates.iter().filter(|o| o.min_y() >= box_.max_y() - 1e-6).map(|o| (o.min_y(), o.max_y())).collect();
        if let Some(s) = Self::equal_gap(box_.min_y(), box_.max_y(), &before, &after, threshold) {
            r.dy = s.shift;
            let x = box_.mid_x();
            r.gaps.push(Gap { vertical: true, from: s.before_edge, to: box_.min_y() + s.shift, cross: x });
            r.gaps.push(Gap { vertical: true, from: box_.max_y() + s.shift, to: s.after_edge, cross: x });
        }
        r
    }

    fn equal_gap(lo: f64, hi: f64, before: &[(f64, f64)], after: &[(f64, f64)], threshold: f64) -> Option<EqualGap> {
        // Swift max(by:) / min(by:) keep the first of equal elements.
        let b = before.iter().copied().reduce(|best, e| if best.1 < e.1 { e } else { best })?;
        let a = after.iter().copied().reduce(|best, e| if e.0 < best.0 { e } else { best })?;
        let free = a.0 - b.1 - (hi - lo); // room left around the box
        if free < 0.0 {
            return None;
        }
        let want = b.1 + free / 2.0; // box.lo when both gaps are equal
        let shift = want - lo;
        if shift.abs() > threshold {
            return None;
        }
        Some(EqualGap { shift, before_edge: b.1, after_edge: a.0 })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEFT: CGRect = CGRect::new(0.0, 0.0, 100.0, 100.0);
    const RIGHT: CGRect = CGRect::new(300.0, 0.0, 100.0, 100.0);

    #[test]
    fn snaps_to_equal_gap_on_x() {
        let b = CGRect::new(153.0, 10.0, 50.0, 50.0);
        let r = SpacingGuides::snap(b, &[LEFT, RIGHT], 30.0);
        assert!((r.dx - 22.0).abs() < 1e-9);
        assert_eq!(r.dy, 0.0);
        assert_eq!(r.gaps.len(), 2);
        assert!(r.gaps[0].from == 100.0 && (r.gaps[0].to - 175.0).abs() < 1e-9);
    }

    #[test]
    fn outside_threshold_does_nothing() {
        let b = CGRect::new(110.0, 10.0, 50.0, 50.0);
        assert_eq!(SpacingGuides::snap(b, &[LEFT, RIGHT], 6.0), SnapResult::none());
    }

    #[test]
    fn needs_both_neighbors_and_row_overlap() {
        let b = CGRect::new(170.0, 500.0, 50.0, 50.0);
        assert_eq!(SpacingGuides::snap(b, &[LEFT, RIGHT], 30.0), SnapResult::none());
        assert_eq!(SpacingGuides::snap(CGRect::new(170.0, 10.0, 50.0, 50.0), &[LEFT], 30.0), SnapResult::none());
    }

    #[test]
    fn snaps_on_y() {
        let top = CGRect::new(0.0, 0.0, 100.0, 50.0);
        let bottom = CGRect::new(0.0, 250.0, 100.0, 50.0);
        let r = SpacingGuides::snap(CGRect::new(10.0, 120.0, 50.0, 50.0), &[top, bottom], 30.0);
        assert!((r.dy - 5.0).abs() < 1e-9);
    }
}
