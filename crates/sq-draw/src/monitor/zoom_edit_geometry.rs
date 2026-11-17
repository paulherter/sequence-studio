// Swift: ZoomEditGeometry.swift
//! Maps Dynamic Zoom windows (normalized picture space, 0...1, y down) onto the Program monitor and back, through the clip's
//! Motion transform (the same layer quad the transform overlay draws). Pure; hit testing and drag maths for
//! `ZoomEditOverlayView`.

use super::transform_overlay_geometry::TransformOverlayGeometry;
use sq_core_effects::dynamic_zoom::{ZoomCorner, ZoomRect};
use sq_core_time::Vec2;
use sq_uikit::controls_grid::{CGPoint, CGSize};

/// Which of the two windows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Which {
    /// The start window.
    Start,
    /// The end window.
    End,
}

/// What a press hit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hit {
    /// A corner handle.
    Corner(Which, ZoomCorner),
    /// The inside of a window.
    Body(Which),
}

/// The corners in declaration order.
pub const ZOOM_CORNERS: [ZoomCorner; 4] =
    [ZoomCorner::TopLeft, ZoomCorner::TopRight, ZoomCorner::BottomRight, ZoomCorner::BottomLeft];

/// The geometry of the zoom windows over a layer.
#[derive(Clone, Debug, PartialEq)]
pub struct ZoomEditGeometry {
    /// The layer the windows ride on.
    pub layer: TransformOverlayGeometry,
}

impl ZoomEditGeometry {
    /// The geometry over a layer.
    pub fn new(layer: TransformOverlayGeometry) -> ZoomEditGeometry {
        ZoomEditGeometry { layer }
    }

    /// The picture's size at scale 1 (sequence px).
    fn size(&self) -> CGSize {
        self.layer.fitted_size()
    }

    /// The view point of a normalized picture point.
    pub fn view_point(&self, n: Vec2) -> CGPoint {
        let size = self.size();
        self.layer.view_point_from_local(Vec2::new((n.x - 0.5) * size.width, (n.y - 0.5) * size.height))
    }

    /// Inverse of `view_point` (through position, rotation, scale and anchor of the layer transform).
    pub fn normalised(&self, p: CGPoint) -> Vec2 {
        let size = self.size();
        let t = &self.layer.transform;
        let o = self.layer.offset_from_view(p);
        let d = o - t.position;
        let a = -t.rotation * std::f64::consts::PI / 180.0;
        let r = Vec2::new(d.x * a.cos() - d.y * a.sin(), d.x * a.sin() + d.y * a.cos());
        let l = Vec2::new(r.x / t.scale.x.max(1e-6), r.y / t.scale.y.max(1e-6)) + t.anchor;
        Vec2::new(l.x / size.width.max(1e-6) + 0.5, l.y / size.height.max(1e-6) + 0.5)
    }

    /// The view point of a window corner.
    pub fn corner(&self, c: ZoomCorner, r: &ZoomRect) -> CGPoint {
        match c {
            ZoomCorner::TopLeft => self.view_point(Vec2::new(r.x, r.y)),
            ZoomCorner::TopRight => self.view_point(Vec2::new(r.x + r.width, r.y)),
            ZoomCorner::BottomRight => self.view_point(Vec2::new(r.x + r.width, r.y + r.height)),
            ZoomCorner::BottomLeft => self.view_point(Vec2::new(r.x, r.y + r.height)),
        }
    }
    /// The window's four corners.
    pub fn quad_of(&self, r: &ZoomRect) -> Vec<CGPoint> {
        ZOOM_CORNERS.iter().map(|c| self.corner(*c, r)).collect()
    }
    /// The window's center.
    pub fn centre_of(&self, r: &ZoomRect) -> CGPoint {
        self.view_point(Vec2::new(r.x + r.width / 2.0, r.y + r.height / 2.0))
    }

    /// Corner handles first (end window before start where they overlap), then bodies (end, then start).
    pub fn hit_test(&self, p: CGPoint, start: &ZoomRect, end: &ZoomRect, handle_radius: f64) -> Option<Hit> {
        for w in [Which::End, Which::Start] {
            let r = if w == Which::End { end } else { start };
            for c in ZOOM_CORNERS {
                let q = self.corner(c, r);
                if (q.x - p.x).hypot(q.y - p.y) <= handle_radius {
                    return Some(Hit::Corner(w, c));
                }
            }
        }
        let n = self.normalised(p);
        for w in [Which::End, Which::Start] {
            let r = (if w == Which::End { end } else { start }).clamped();
            if n.x >= r.x && n.x <= r.x + r.width && n.y >= r.y && n.y <= r.y + r.height {
                return Some(Hit::Body(w));
            }
        }
        None
    }

    /// The windows after dragging `hit` from `start_view` (press) to `p`; `base` are the windows at the press.
    pub fn dragged(
        &self,
        hit: Hit,
        start_view: CGPoint,
        p: CGPoint,
        base: (ZoomRect, ZoomRect),
    ) -> (ZoomRect, ZoomRect) {
        let mut out = base;
        let n0 = self.normalised(start_view);
        let n1 = self.normalised(p);
        match hit {
            Hit::Body(w) => {
                let moved =
                    (if w == Which::Start { base.0 } else { base.1 }).moved(Vec2::new(n1.x - n0.x, n1.y - n0.y));
                if w == Which::Start {
                    out.0 = moved;
                } else {
                    out.1 = moved;
                }
            }
            Hit::Corner(w, c) => {
                let resized = (if w == Which::Start { base.0 } else { base.1 }).resized(c, n1);
                if w == Which::Start {
                    out.0 = resized;
                } else {
                    out.1 = resized;
                }
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::ClipTransform;

    fn geo(t: ClipTransform) -> ZoomEditGeometry {
        ZoomEditGeometry::new(TransformOverlayGeometry::new(
            CGSize::new(1920.0, 1080.0),
            sq_uikit::controls_grid::CGRect::new(10.0, 10.0, 960.0, 540.0),
            16.0 / 9.0,
            t,
            None,
        ))
    }
    fn close(a: CGPoint, b: CGPoint) -> bool {
        (a.x - b.x).abs() < 0.001 && (a.y - b.y).abs() < 0.001
    }

    #[test]
    fn normalised_and_view_points_round_trip_through_motion() {
        let t = ClipTransform {
            position: Vec2::new(120.0, -40.0),
            scale: Vec2::new(0.6, 0.6),
            rotation: 20.0,
            ..ClipTransform::IDENTITY
        };
        let g = geo(t);
        for n in [Vec2::new(0.0, 0.0), Vec2::new(0.3, 0.8), Vec2::new(1.0, 1.0)] {
            let back = g.normalised(g.view_point(n));
            assert!((back.x - n.x).abs() < 1e-9 && (back.y - n.y).abs() < 1e-9);
        }
    }

    #[test]
    fn full_window_covers_the_canvas_at_identity() {
        let q = geo(ClipTransform::IDENTITY).quad_of(&ZoomRect::FULL);
        assert!(close(q[0], CGPoint { x: 10.0, y: 10.0 }) && close(q[2], CGPoint { x: 970.0, y: 550.0 }));
    }

    #[test]
    fn corners_win_over_bodies_and_the_end_window_over_the_start() {
        let g = geo(ClipTransform::IDENTITY);
        let s = ZoomRect::FULL;
        let e = ZoomRect::centred(2.0, Vec2::new(0.5, 0.5));
        assert_eq!(
            g.hit_test(CGPoint { x: 11.0, y: 11.0 }, &s, &e, 8.0),
            Some(Hit::Corner(Which::Start, ZoomCorner::TopLeft))
        );
        assert_eq!(
            g.hit_test(g.corner(ZoomCorner::TopLeft, &e), &s, &e, 8.0),
            Some(Hit::Corner(Which::End, ZoomCorner::TopLeft))
        );
        assert_eq!(g.hit_test(g.view_point(Vec2::new(0.5, 0.5)), &s, &e, 8.0), Some(Hit::Body(Which::End)));
        assert_eq!(g.hit_test(g.view_point(Vec2::new(0.1, 0.5)), &s, &e, 8.0), Some(Hit::Body(Which::Start)));
        assert_eq!(g.hit_test(CGPoint { x: -50.0, y: -50.0 }, &s, &e, 8.0), None);
    }

    #[test]
    fn dragging_the_body_moves_the_window_by_the_normalised_distance() {
        let g = geo(ClipTransform::IDENTITY);
        let e = ZoomRect::centred(2.0, Vec2::new(0.5, 0.5));
        let a = g.view_point(Vec2::new(0.5, 0.5));
        let b = g.view_point(Vec2::new(0.6, 0.55));
        let out = g.dragged(Hit::Body(Which::End), a, b, (ZoomRect::FULL, e));
        assert!((out.1.x - 0.35).abs() < 1e-9 && (out.1.y - 0.3).abs() < 1e-9 && out.0 == ZoomRect::FULL);
    }

    #[test]
    fn dragging_a_corner_resizes_around_the_opposite_corner() {
        let g = geo(ClipTransform::IDENTITY);
        let e = ZoomRect { x: 0.25, y: 0.25, width: 0.5, height: 0.5 };
        let out = g.dragged(
            Hit::Corner(Which::End, ZoomCorner::BottomRight),
            g.corner(ZoomCorner::BottomRight, &e),
            g.view_point(Vec2::new(0.9, 0.9)),
            (ZoomRect::FULL, e),
        );
        assert!((out.1.x - 0.25).abs() < 1e-9 && (out.1.width - 0.65).abs() < 1e-9);
        assert!(out.1.zoom() > 1.5);
    }
}
