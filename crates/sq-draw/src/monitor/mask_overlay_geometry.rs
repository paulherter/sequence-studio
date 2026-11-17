// Swift: MaskOverlayGeometry.swift
//! Mask overlay geometry of the Program monitor.

use sq_core_masks::MaskCoverage;
use sq_core_masks::mask_path_editing::MaskPathEditingExt;
use sq_core_model::MaskPath;
use sq_core_time::{Id, Vec2};
use sq_uikit::controls_grid::CGPoint;

/// A direction in view space (Swift `CGVector`, which swift-corelibs-foundation lacks).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CGVector {
    /// Horizontal.
    pub dx: f64,
    /// Vertical.
    pub dy: f64,
}

/// One mask of the selected clip as the Program monitor overlay shows it (W6.7): its path at the playhead. `active` = the
/// mask being edited (selected in Effect Controls, or the clip's only path mask): it shows tangent handles, a click on its
/// outline adds a vertex and a drag inside it moves the whole mask.
#[derive(Clone, Debug, PartialEq)]
pub struct MaskOverlay {
    /// The mask.
    pub id: Id,
    /// Its path at the playhead.
    pub path: MaskPath,
    /// Being edited.
    pub active: bool,
}

impl MaskOverlay {
    /// An overlay of a mask.
    pub fn new(id: Id, path: MaskPath, active: bool) -> MaskOverlay {
        MaskOverlay { id, path, active }
    }
}

/// A hit on a tangent handle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TangentHit {
    /// Index of the mask.
    pub mask: usize,
    /// Index of the vertex.
    pub vertex: usize,
    /// The out tangent, not the in tangent.
    pub out: bool,
}

/// A hit on an outline segment.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SegmentHit {
    /// Index of the mask.
    pub mask: usize,
    /// Index of the segment.
    pub segment: usize,
    /// Curve parameter on it.
    pub t: f64,
}

/// Maps mask points (fractions of the clip's frame) to view points and back through the layer's quad on the canvas
/// (top-left, top-right, bottom-right, bottom-left; the transform is affine, so three corners define it).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaskOverlayGeometry {
    /// Top-left corner.
    pub origin: CGPoint,
    /// Top-left to top-right.
    pub x_axis: CGVector,
    /// Top-left to bottom-left.
    pub y_axis: CGVector,
}

impl MaskOverlayGeometry {
    /// Grab radius of a vertex, view pt.
    pub const VERTEX_RADIUS: f64 = 6.0;

    /// The geometry of a quad of four corners.
    pub fn new(q: &[CGPoint]) -> MaskOverlayGeometry {
        debug_assert!(q.len() == 4, "quad needs four corners");
        MaskOverlayGeometry {
            origin: q[0],
            x_axis: CGVector { dx: q[1].x - q[0].x, dy: q[1].y - q[0].y },
            y_axis: CGVector { dx: q[3].x - q[0].x, dy: q[3].y - q[0].y },
        }
    }

    /// The view point of a frame fraction.
    pub fn view_point(&self, n: Vec2) -> CGPoint {
        CGPoint {
            x: self.origin.x + n.x * self.x_axis.dx + n.y * self.y_axis.dx,
            y: self.origin.y + n.x * self.x_axis.dy + n.y * self.y_axis.dy,
        }
    }

    /// Frame fraction under view point `p`; `None` when the layer has no area (scale 0).
    pub fn frame_point(&self, p: CGPoint) -> Option<Vec2> {
        let det = self.x_axis.dx * self.y_axis.dy - self.x_axis.dy * self.y_axis.dx;
        if det.abs() <= 1e-9 {
            return None;
        }
        let (dx, dy) = (p.x - self.origin.x, p.y - self.origin.y);
        let u = (dx * self.y_axis.dy - dy * self.y_axis.dx) / det;
        let v = (self.x_axis.dx * dy - self.x_axis.dy * dx) / det;
        Some(Vec2::new(u, v))
    }

    /// Outline in view points (the flattened path).
    pub fn outline(&self, path: &MaskPath) -> Vec<CGPoint> {
        path.polygon().into_iter().map(|p| self.view_point(p)).collect()
    }

    /// The topmost mask vertex within `VERTEX_RADIUS` of `p`: (mask index, vertex index).
    pub fn hit_vertex(&self, p: CGPoint, masks: &[MaskOverlay]) -> Option<(usize, usize)> {
        let mut best: Option<(usize, usize, f64)> = None;
        for (mi, m) in masks.iter().enumerate() {
            for (vi, v) in m.path.vertices.iter().enumerate() {
                let c = self.view_point(v.point);
                let d = (c.x - p.x).hypot(c.y - p.y);
                if d <= Self::VERTEX_RADIUS && d < best.map_or(f64::INFINITY, |b| b.2) {
                    best = Some((mi, vi, d));
                }
            }
        }
        best.map(|b| (b.0, b.1))
    }

    /// Frame size in view points (for px distances along the path).
    pub fn frame_extent(&self) -> Vec2 {
        Vec2::new(self.x_axis.dx.hypot(self.x_axis.dy), self.y_axis.dx.hypot(self.y_axis.dy))
    }

    /// A tangent handle (end of a non-zero tangent) of an active mask within `VERTEX_RADIUS`.
    pub fn hit_tangent(&self, p: CGPoint, masks: &[MaskOverlay]) -> Option<TangentHit> {
        let mut best: Option<(TangentHit, f64)> = None;
        for (mi, m) in masks.iter().enumerate().filter(|(_, m)| m.active) {
            for (vi, v) in m.path.vertices.iter().enumerate() {
                for (is_out, t) in [(false, v.in_tangent), (true, v.out_tangent)] {
                    if t == Vec2::ZERO {
                        continue;
                    }
                    let c = self.view_point(v.point + t);
                    let d = (c.x - p.x).hypot(c.y - p.y);
                    if d <= Self::VERTEX_RADIUS && d < best.map_or(f64::INFINITY, |b| b.1) {
                        best = Some((TangentHit { mask: mi, vertex: vi, out: is_out }, d));
                    }
                }
            }
        }
        best.map(|b| b.0)
    }

    /// A point on the outline of an active mask within `VERTEX_RADIUS` (a click there adds a vertex).
    pub fn hit_segment(&self, p: CGPoint, masks: &[MaskOverlay]) -> Option<SegmentHit> {
        let n = self.frame_point(p)?;
        let mut best: Option<(SegmentHit, f64)> = None;
        for (mi, m) in masks.iter().enumerate().filter(|(_, m)| m.active) {
            let Some(h) = m.path.nearest_segment(n, self.frame_extent()).filter(|h| h.distance <= Self::VERTEX_RADIUS)
            else {
                continue;
            };
            if h.distance < best.map_or(f64::INFINITY, |b| b.1) {
                best = Some((SegmentHit { mask: mi, segment: h.segment, t: h.t }, h.distance));
            }
        }
        best.map(|b| b.0)
    }

    /// The topmost mask (last drawn) whose outline contains `p`, active or not.
    pub fn hit_any_inside(&self, p: CGPoint, masks: &[MaskOverlay]) -> Option<usize> {
        let n = self.frame_point(p)?;
        (0..masks.len()).rev().find(|&i| MaskCoverage::signed_distance(n, &masks[i].path.polygon()) < 0.0)
    }

    /// The topmost active mask whose outline contains `p`.
    pub fn hit_inside(&self, p: CGPoint, masks: &[MaskOverlay]) -> Option<usize> {
        let n = self.frame_point(p)?;
        (0..masks.len()).find(|&i| masks[i].active && MaskCoverage::signed_distance(n, &masks[i].path.polygon()) < 0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MaskVertex;
    use sq_core_time::{IdSource, SequentialIds};

    fn quad() -> [CGPoint; 4] {
        [
            CGPoint { x: 50.0, y: 40.0 },
            CGPoint { x: 250.0, y: 40.0 },
            CGPoint { x: 250.0, y: 140.0 },
            CGPoint { x: 50.0, y: 140.0 },
        ]
    }

    #[test]
    fn view_and_frame_points_round_trip() {
        let g = MaskOverlayGeometry::new(&quad());
        let v = g.view_point(Vec2::new(0.25, 0.5));
        assert_eq!(v, CGPoint { x: 100.0, y: 90.0 });
        let back = g.frame_point(v).unwrap_or(Vec2::ZERO);
        assert!((back.x - 0.25).abs() < 1e-12 && (back.y - 0.5).abs() < 1e-12);
        assert_eq!(g.frame_extent(), Vec2::new(200.0, 100.0));
    }

    #[test]
    fn a_flat_layer_has_no_frame_point() {
        let flat = [CGPoint { x: 0.0, y: 0.0 }; 4];
        assert!(MaskOverlayGeometry::new(&flat).frame_point(CGPoint { x: 1.0, y: 1.0 }).is_none());
    }

    #[test]
    fn the_nearest_vertex_within_the_grab_radius_wins() {
        let g = MaskOverlayGeometry::new(&quad());
        let path = MaskPath {
            vertices: vec![MaskVertex::corner(Vec2::new(0.25, 0.5)), MaskVertex::corner(Vec2::new(0.26, 0.5))],
        };
        let masks = [MaskOverlay::new(SequentialIds::default().next_id(), path, false)];
        assert_eq!(g.hit_vertex(CGPoint { x: 101.0, y: 90.0 }, &masks), Some((0, 0)));
        assert_eq!(g.hit_vertex(CGPoint { x: 300.0, y: 90.0 }, &masks), None);
    }
}
