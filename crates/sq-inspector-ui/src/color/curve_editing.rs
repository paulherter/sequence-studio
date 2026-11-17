// Swift: Color/CurveEditing.swift
//! Pure point editing for one curve (x ascending, 0…1). Interior points keep a minimum gap to their neighbors; the end
//! points only move vertically.

use sq_core_model::CurvePoint;
use sq_uikit::controls_grid::CGSize;

/// Pure point editing for one curve.
pub struct CurveEditing;

impl CurveEditing {
    pub const MIN_GAP: f32 = 0.01;
    pub const HIT_RADIUS: f64 = 8.0;

    /// Adds a point at (x, y); returns the new list and the index of the point.
    pub fn add(pts: &[CurvePoint], x: f32, y: f32) -> (Vec<CurvePoint>, usize) {
        let mut p = pts.to_vec();
        let cx = x.clamp(0.0, 1.0);
        let cy = y.clamp(0.0, 1.0);
        let i = p.iter().position(|q| q.x > cx).unwrap_or(p.len());
        p.insert(i, CurvePoint { x: cx, y: cy });
        (p, i)
    }

    /// Moves point `i`; an index outside the list changes nothing.
    pub fn move_point(pts: &[CurvePoint], i: usize, x: f32, y: f32) -> Vec<CurvePoint> {
        if i >= pts.len() {
            return pts.to_vec();
        }
        let mut p = pts.to_vec();
        let cy = y.clamp(0.0, 1.0);
        if i == 0 || i == p.len() - 1 {
            p[i].y = cy;
        } else {
            let lo = p[i - 1].x + Self::MIN_GAP;
            let hi = p[i + 1].x - Self::MIN_GAP;
            p[i] = CurvePoint { x: x.max(lo).min(lo.max(hi)), y: cy };
        }
        p
    }

    /// Interior points can be removed; the two end points stay.
    pub fn remove(pts: &[CurvePoint], i: usize) -> Vec<CurvePoint> {
        if pts.len() <= 2 || i == 0 || i >= pts.len() - 1 {
            return pts.to_vec();
        }
        let mut p = pts.to_vec();
        p.remove(i);
        p
    }

    /// Index of the point within `radius` (in the same units as the coordinates) of (x, y), nearest first.
    pub fn hit(pts: &[CurvePoint], x: f64, y: f64, size: CGSize, radius: f64) -> Option<usize> {
        let mut best: Option<(usize, f64)> = None;
        for (i, q) in pts.iter().enumerate() {
            let d = (f64::from(q.x) * size.width - x).hypot((1.0 - f64::from(q.y)) * size.height - y);
            if d <= radius && best.is_none_or(|b| d < b.1) {
                best = Some((i, d));
            }
        }
        best.map(|b| b.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pts() -> Vec<CurvePoint> {
        vec![CurvePoint { x: 0.0, y: 0.0 }, CurvePoint { x: 1.0, y: 1.0 }]
    }

    #[test]
    fn add_inserts_in_x_order_and_clamps() {
        let (p, i) = CurveEditing::add(&pts(), 0.5, 2.0);
        assert_eq!(i, 1);
        assert_eq!(p[1], CurvePoint { x: 0.5, y: 1.0 });
    }

    #[test]
    fn interior_points_keep_the_gap_and_end_points_move_vertically() {
        let (p, i) = CurveEditing::add(&pts(), 0.5, 0.5);
        let q = CurveEditing::move_point(&p, i, 5.0, 0.25);
        assert_eq!(q[1].x, 1.0 - CurveEditing::MIN_GAP);
        let e = CurveEditing::move_point(&p, 0, 0.7, 0.3);
        assert_eq!(e[0], CurvePoint { x: 0.0, y: 0.3 });
    }

    #[test]
    fn end_points_cannot_be_removed() {
        let (p, i) = CurveEditing::add(&pts(), 0.5, 0.5);
        assert_eq!(CurveEditing::remove(&p, 0).len(), 3);
        assert_eq!(CurveEditing::remove(&p, i).len(), 2);
        assert_eq!(CurveEditing::remove(&pts(), 1).len(), 2);
    }

    #[test]
    fn hit_finds_the_nearest_point_in_the_radius() {
        let size = CGSize { width: 100.0, height: 100.0 };
        assert_eq!(CurveEditing::hit(&pts(), 2.0, 98.0, size, CurveEditing::HIT_RADIUS), Some(0));
        assert_eq!(CurveEditing::hit(&pts(), 50.0, 50.0, size, CurveEditing::HIT_RADIUS), None);
    }
}
