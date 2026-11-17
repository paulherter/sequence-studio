// Swift: StepWindowEditGeometry.swift
//! Maps a Color Step window (picture space, uv 0...1, y down; width and height as fractions of the picture; rotation
//! clockwise about the center, measured in aspect-corrected space exactly like the render shader) onto the Program
//! monitor and back, and turns drags of its handles into a new window. Pure; `StepWindowOverlayView` draws and routes.

use super::zoom_edit_geometry::ZoomEditGeometry;
use sq_core_model::{StepWindow, StepWindowShape};
use sq_core_time::Vec2;
use sq_uikit::controls_grid::CGPoint;
use std::ops::RangeInclusive;

/// An edge handle.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Edge {
    /// Right.
    Right,
    /// Left.
    Left,
    /// Top.
    Top,
    /// Bottom.
    Bottom,
}

impl Edge {
    /// Every edge, in declaration order.
    pub const ALL: [Edge; 4] = [Edge::Right, Edge::Left, Edge::Top, Edge::Bottom];
}

/// What a press hit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hit {
    /// The rotate handle.
    Rotate,
    /// An edge handle.
    Edge(Edge),
    /// The center handle.
    Center,
    /// The inside of the shape.
    Body,
}

/// The geometry of one Step window over a layer.
#[derive(Clone, Debug, PartialEq)]
pub struct StepWindowEditGeometry {
    /// The zoom geometry, which carries the layer.
    pub layer: ZoomEditGeometry,
}

impl StepWindowEditGeometry {
    /// Smallest and largest size a drag sets (fractions; the sliders' 1...200 %).
    pub const SIZE_RANGE: RangeInclusive<f32> = 0.01..=2.0;
    /// Distance of the rotate handle beyond the top edge, in view points.
    pub const ROTATE_OFFSET: f64 = 24.0;
    /// Where the linear shape's rotate handle sits above its line (fraction of the picture height).
    pub const LINEAR_REACH: f64 = 0.15;

    /// The geometry over a layer.
    pub fn new(layer: ZoomEditGeometry) -> StepWindowEditGeometry {
        StepWindowEditGeometry { layer }
    }

    /// Picture width / height, the render shader's `aspect`.
    pub fn aspect(&self) -> f64 {
        let s = self.layer.layer.fitted_size();
        if s.height > 0.0 { s.width / s.height } else { 16.0 / 9.0 }
    }

    // Spaces

    fn rotation(w: &StepWindow) -> (f64, f64) {
        let r = w.rotation as f64 * std::f64::consts::PI / 180.0;
        (r.cos(), r.sin())
    }

    /// Window space (x along the window's width in aspect-corrected units, y along its height) to picture uv.
    pub fn uv_from_window(&self, q: Vec2, w: &StepWindow) -> Vec2 {
        let (c, s) = Self::rotation(w);
        let (px, py) = (q.x * c - q.y * s, q.x * s + q.y * c);
        Vec2::new(w.center_x as f64 + px / self.aspect().max(1e-6), w.center_y as f64 + py)
    }

    /// Picture uv to window space (inverse of `uv_from_window`).
    pub fn window_from_uv(&self, p: Vec2, w: &StepWindow) -> Vec2 {
        let (c, s) = Self::rotation(w);
        let (px, py) = ((p.x - w.center_x as f64) * self.aspect(), p.y - w.center_y as f64);
        Vec2::new(px * c + py * s, -px * s + py * c)
    }

    fn view(&self, q: Vec2, w: &StepWindow) -> CGPoint {
        self.layer.view_point(self.uv_from_window(q, w))
    }

    // Handles

    /// Half extents in window space.
    fn half(&self, w: &StepWindow) -> Vec2 {
        Vec2::new(w.width as f64 / 2.0 * self.aspect(), w.height as f64 / 2.0)
    }

    /// The center handle.
    pub fn center_point(&self, w: &StepWindow) -> CGPoint {
        self.view(Vec2::new(0.0, 0.0), w)
    }

    /// Edge handles exist for the ellipse and the rectangle; the linear shape is a line and has none.
    pub fn edge_point(&self, e: Edge, w: &StepWindow) -> Option<CGPoint> {
        if w.shape == StepWindowShape::Linear {
            return None;
        }
        let h = self.half(w);
        Some(match e {
            Edge::Right => self.view(Vec2::new(h.x, 0.0), w),
            Edge::Left => self.view(Vec2::new(-h.x, 0.0), w),
            Edge::Top => self.view(Vec2::new(0.0, -h.y), w),
            Edge::Bottom => self.view(Vec2::new(0.0, h.y), w),
        })
    }

    /// The rotate handle: beyond the top edge (the linear shape: above its line).
    pub fn rotate_point(&self, w: &StepWindow) -> CGPoint {
        let anchor = if w.shape == StepWindowShape::Linear {
            self.view(Vec2::new(0.0, -Self::LINEAR_REACH), w)
        } else {
            self.edge_point(Edge::Top, w).unwrap_or_else(|| self.center_point(w))
        };
        let c = self.center_point(w);
        let (dx, dy) = (anchor.x - c.x, anchor.y - c.y);
        let len = dx.hypot(dy).max(1e-6);
        CGPoint { x: anchor.x + dx / len * Self::ROTATE_OFFSET, y: anchor.y + dy / len * Self::ROTATE_OFFSET }
    }

    /// The shape's outline in view points (ellipse and rectangle: closed; linear: the line across the picture).
    pub fn outline(&self, w: &StepWindow, segments: usize) -> Vec<CGPoint> {
        let h = self.half(w);
        match w.shape {
            StepWindowShape::Rectangle => {
                [Vec2::new(-h.x, -h.y), Vec2::new(h.x, -h.y), Vec2::new(h.x, h.y), Vec2::new(-h.x, h.y)]
                    .iter()
                    .map(|q| self.view(*q, w))
                    .collect()
            }
            StepWindowShape::Ellipse => (0..segments)
                .map(|i| {
                    let a = i as f64 / segments as f64 * 2.0 * std::f64::consts::PI;
                    self.view(Vec2::new(a.cos() * h.x, a.sin() * h.y), w)
                })
                .collect(),
            StepWindowShape::Linear => {
                let reach = self.aspect().max(1.0) * 2.0;
                vec![self.view(Vec2::new(-reach, 0.0), w), self.view(Vec2::new(reach, 0.0), w)]
            }
        }
    }

    // Hit testing

    /// Rotate handle, edge handles, center, then the body (inside an ellipse or rectangle) for moving.
    pub fn hit_test(&self, p: CGPoint, w: &StepWindow, handle_radius: f64) -> Option<Hit> {
        let near = |q: Option<CGPoint>| q.is_some_and(|q| (q.x - p.x).hypot(q.y - p.y) <= handle_radius);
        if near(Some(self.rotate_point(w))) {
            return Some(Hit::Rotate);
        }
        for e in Edge::ALL {
            if near(self.edge_point(e, w)) {
                return Some(Hit::Edge(e));
            }
        }
        if near(Some(self.center_point(w))) {
            return Some(Hit::Center);
        }
        if w.shape == StepWindowShape::Linear {
            return None;
        }
        let q = self.window_from_uv(self.layer.normalised(p), w);
        let h = self.half(w);
        let inside = if w.shape == StepWindowShape::Rectangle {
            q.x.abs() <= h.x && q.y.abs() <= h.y
        } else {
            (q.x / h.x.max(1e-9)) * (q.x / h.x.max(1e-9)) + (q.y / h.y.max(1e-9)) * (q.y / h.y.max(1e-9)) <= 1.0
        };
        if inside { Some(Hit::Body) } else { None }
    }

    // Dragging

    /// The window after dragging `hit` from `press` to `p`; `base` is the window at the press. Position stays on the
    /// picture, sizes inside `SIZE_RANGE`, rotation inside -180...180; shape, softness and invert are never touched.
    pub fn dragged(&self, hit: Hit, press: CGPoint, p: CGPoint, base: &StepWindow) -> StepWindow {
        let mut w = base.clone();
        let n0 = self.layer.normalised(press);
        let n1 = self.layer.normalised(p);
        match hit {
            Hit::Center | Hit::Body => {
                w.center_x = (base.center_x as f64 + n1.x - n0.x).clamp(0.0, 1.0) as f32;
                w.center_y = (base.center_y as f64 + n1.y - n0.y).clamp(0.0, 1.0) as f32;
            }
            Hit::Edge(e) => {
                let q = self.window_from_uv(n1, base);
                match e {
                    Edge::Left | Edge::Right => {
                        w.width = Self::clamp_size((q.x.abs() * 2.0 / self.aspect().max(1e-6)) as f32)
                    }
                    Edge::Top | Edge::Bottom => w.height = Self::clamp_size((q.y.abs() * 2.0) as f32),
                }
            }
            Hit::Rotate => {
                let px = (n1.x - base.center_x as f64) * self.aspect();
                let py = n1.y - base.center_y as f64;
                if px.hypot(py) <= 1e-6 {
                    return base.clone();
                }
                w.rotation = (px.atan2(-py) * 180.0 / std::f64::consts::PI) as f32;
            }
        }
        w
    }

    fn clamp_size(v: f32) -> f32 {
        v.max(*Self::SIZE_RANGE.start()).min(*Self::SIZE_RANGE.end())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::monitor::transform_overlay_geometry::TransformOverlayGeometry;
    use sq_core_model::ClipTransform;
    use sq_uikit::controls_grid::{CGRect, CGSize};

    fn geo(t: ClipTransform) -> StepWindowEditGeometry {
        StepWindowEditGeometry::new(ZoomEditGeometry::new(TransformOverlayGeometry::new(
            CGSize::new(1920.0, 1080.0),
            CGRect::new(10.0, 10.0, 960.0, 540.0),
            16.0 / 9.0,
            t,
            None,
        )))
    }
    fn g0() -> StepWindowEditGeometry {
        geo(ClipTransform::IDENTITY)
    }
    fn close(a: CGPoint, b: CGPoint) -> bool {
        (a.x - b.x).abs() < 0.01 && (a.y - b.y).abs() < 0.01
    }
    fn rect() -> StepWindow {
        StepWindow { shape: StepWindowShape::Rectangle, ..Default::default() }
    }
    fn pt(x: f64, y: f64) -> CGPoint {
        CGPoint { x, y }
    }

    #[test]
    fn window_and_picture_spaces_round_trip() {
        let g = g0();
        let w = StepWindow { center_x: 0.3, center_y: 0.6, rotation: 33.0, ..rect() };
        for q in [Vec2::new(0.0, 0.0), Vec2::new(0.2, -0.1), Vec2::new(-0.5, 0.3)] {
            let back = g.window_from_uv(g.uv_from_window(q, &w), &w);
            assert!((back.x - q.x).abs() < 1e-9 && (back.y - q.y).abs() < 1e-9);
        }
    }

    #[test]
    fn handles_sit_on_the_shape_at_identity() {
        let g = g0();
        let w = StepWindow { center_x: 0.5, center_y: 0.5, ..Default::default() };
        assert!(close(g.center_point(&w), pt(490.0, 280.0)));
        assert!(close(g.edge_point(Edge::Right, &w).unwrap_or_default(), pt(490.0 + 0.25 * 960.0, 280.0)));
        assert!(close(g.edge_point(Edge::Top, &w).unwrap_or_default(), pt(490.0, 280.0 - 0.25 * 540.0)));
        let r = g.rotate_point(&w);
        assert!(
            (r.x - 490.0).abs() < 0.01
                && (r.y - (280.0 - 0.25 * 540.0 - StepWindowEditGeometry::ROTATE_OFFSET)).abs() < 0.01
        );
    }

    #[test]
    fn rotation_turns_the_handles_clockwise() {
        let g = g0();
        let w = StepWindow { rotation: 90.0, ..rect() };
        let right = g.edge_point(Edge::Right, &w).unwrap_or_default();
        let c = g.center_point(&w);
        assert!((right.x - c.x).abs() < 0.01 && right.y > c.y);
    }

    #[test]
    fn hit_test_orders_rotate_edge_center_body() {
        let g = g0();
        let w = rect();
        assert_eq!(g.hit_test(g.rotate_point(&w), &w, 8.0), Some(Hit::Rotate));
        assert_eq!(g.hit_test(g.edge_point(Edge::Left, &w).unwrap_or_default(), &w, 8.0), Some(Hit::Edge(Edge::Left)));
        assert_eq!(g.hit_test(g.center_point(&w), &w, 8.0), Some(Hit::Center));
        assert_eq!(g.hit_test(pt(490.0 + 100.0, 280.0 + 60.0), &w, 8.0), Some(Hit::Body));
        assert_eq!(g.hit_test(pt(20.0, 20.0), &w, 8.0), None);
    }

    #[test]
    fn linear_has_no_edges_or_body() {
        let g = g0();
        let w = StepWindow { shape: StepWindowShape::Linear, ..Default::default() };
        assert!(g.edge_point(Edge::Right, &w).is_none());
        assert_eq!(g.hit_test(pt(490.0, 280.0 + 80.0), &w, 8.0), None);
        assert_eq!(g.hit_test(g.center_point(&w), &w, 8.0), Some(Hit::Center));
        assert_eq!(g.hit_test(g.rotate_point(&w), &w, 8.0), Some(Hit::Rotate));
    }

    #[test]
    fn moving_keeps_the_window_on_the_picture() {
        let g = g0();
        let w = StepWindow::default();
        let press = g.center_point(&w);
        let moved = g.dragged(Hit::Center, press, pt(press.x + 96.0, press.y - 54.0), &w);
        assert!((moved.center_x - 0.6).abs() < 1e-4 && (moved.center_y - 0.4).abs() < 1e-4);
        assert!(moved.width == w.width && moved.softness == w.softness && moved.shape == w.shape);
        let off = g.dragged(Hit::Body, press, pt(5000.0, -5000.0), &w);
        assert!(off.center_x == 1.0 && off.center_y == 0.0);
    }

    #[test]
    fn edges_resize_around_the_center_and_clamp() {
        let g = g0();
        let w = rect();
        let right = g.edge_point(Edge::Right, &w).unwrap_or_default();
        let wide = g.dragged(Hit::Edge(Edge::Right), right, pt(right.x + 96.0, right.y), &w);
        assert!((wide.width - 0.7).abs() < 1e-4 && wide.height == w.height && wide.center_x == w.center_x);
        let top = g.edge_point(Edge::Top, &w).unwrap_or_default();
        let tall = g.dragged(Hit::Edge(Edge::Top), top, pt(top.x, top.y - 54.0), &w);
        assert!((tall.height - 0.7).abs() < 1e-4);
        let tiny = g.dragged(Hit::Edge(Edge::Right), right, g.center_point(&w), &w);
        assert_eq!(tiny.width, *StepWindowEditGeometry::SIZE_RANGE.start());
        let huge = g.dragged(Hit::Edge(Edge::Right), right, pt(9000.0, 280.0), &w);
        assert_eq!(huge.width, *StepWindowEditGeometry::SIZE_RANGE.end());
    }

    #[test]
    fn rotate_handle_sets_the_angle_from_the_center() {
        let g = g0();
        let w = rect();
        let c = g.center_point(&w);
        let east = g.dragged(Hit::Rotate, g.rotate_point(&w), pt(c.x + 200.0, c.y), &w);
        assert!((east.rotation - 90.0).abs() < 1e-3);
        let up = g.dragged(Hit::Rotate, g.rotate_point(&w), pt(c.x, c.y - 200.0), &w);
        assert!(up.rotation.abs() < 1e-3);
        let south = g.dragged(Hit::Rotate, g.rotate_point(&w), pt(c.x + 1.0, c.y + 200.0), &w);
        assert!((south.rotation.abs() - 180.0).abs() < 1.0);
    }

    #[test]
    fn mapping_follows_the_clip_transform() {
        let t = ClipTransform {
            position: Vec2::new(200.0, 100.0),
            scale: Vec2::new(0.5, 0.5),
            rotation: 0.0,
            ..ClipTransform::IDENTITY
        };
        let g = geo(t);
        let w = StepWindow::default();
        let c = g.center_point(&w);
        assert!(close(c, pt(490.0 + 100.0, 280.0 + 50.0)));
        let e = g.edge_point(Edge::Right, &w).unwrap_or_default();
        assert!(((e.x - c.x) - 0.25 * 960.0 * 0.5).abs() < 0.01);
    }
}
