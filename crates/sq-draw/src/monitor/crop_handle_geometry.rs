// Swift: CropHandleGeometry.swift
//! Crop handles on the layer of the Program monitor.

use super::mask_overlay_geometry::MaskOverlayGeometry;
use sq_core_effects::effects_evaluation::CropInsets;
use sq_core_model::ClipEffect;
use sq_core_time::Vec2;
use sq_uikit::controls_grid::CGPoint;

/// One edge of the clip's Crop effect as an on-canvas handle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CropEdge {
    /// Left edge.
    Left,
    /// Top edge.
    Top,
    /// Right edge.
    Right,
    /// Bottom edge.
    Bottom,
}

impl CropEdge {
    /// Every edge, in declaration order.
    pub const ALL: [CropEdge; 4] = [CropEdge::Left, CropEdge::Top, CropEdge::Right, CropEdge::Bottom];

    /// Parameter key of the Crop effect (values are percent of the clip's own frame).
    pub fn effect_key(self) -> &'static str {
        match self {
            CropEdge::Left => ClipEffect::CROP_LEFT_KEY,
            CropEdge::Top => ClipEffect::CROP_TOP_KEY,
            CropEdge::Right => ClipEffect::CROP_RIGHT_KEY,
            CropEdge::Bottom => ClipEffect::CROP_BOTTOM_KEY,
        }
    }

    /// Display name.
    pub fn title(self) -> &'static str {
        match self {
            CropEdge::Left => "Left",
            CropEdge::Top => "Top",
            CropEdge::Right => "Right",
            CropEdge::Bottom => "Bottom",
        }
    }

    /// Left and right edges move along x.
    pub fn is_vertical(self) -> bool {
        self == CropEdge::Left || self == CropEdge::Right
    }

    /// The inset of this edge.
    pub fn value(self, i: &CropInsets) -> f64 {
        match self {
            CropEdge::Left => i.left,
            CropEdge::Top => i.top,
            CropEdge::Right => i.right,
            CropEdge::Bottom => i.bottom,
        }
    }

    /// `i` with this edge set to `v`.
    pub fn setting(self, v: f64, i: &CropInsets) -> CropInsets {
        let mut r = *i;
        match self {
            CropEdge::Left => r.left = v,
            CropEdge::Top => r.top = v,
            CropEdge::Right => r.right = v,
            CropEdge::Bottom => r.bottom = v,
        }
        r
    }
}

/// Crop handles on the layer: one handle at the middle of each cropped edge, dragged along the clip's own axes
/// (insets are fractions of the clip's frame, applied before the transform, so they follow rotation and scale).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CropHandleGeometry {
    /// The layer's frame.
    pub frame: MaskOverlayGeometry,
}

impl CropHandleGeometry {
    /// Grab radius of an edge handle, view pt.
    pub const GRAB_RADIUS: f64 = 9.0;
    /// The part of the frame that always stays (a crop never reaches zero size).
    pub const MIN_REMAINING: f64 = 0.01;

    /// The geometry of a layer quad.
    pub fn new(quad: &[CGPoint]) -> CropHandleGeometry {
        CropHandleGeometry { frame: MaskOverlayGeometry::new(quad) }
    }

    /// Corners of the kept rectangle in view points (top-left, top-right, bottom-right, bottom-left).
    pub fn corners(&self, i: &CropInsets) -> [CGPoint; 4] {
        [
            self.frame.view_point(Vec2::new(i.left, i.top)),
            self.frame.view_point(Vec2::new(1.0 - i.right, i.top)),
            self.frame.view_point(Vec2::new(1.0 - i.right, 1.0 - i.bottom)),
            self.frame.view_point(Vec2::new(i.left, 1.0 - i.bottom)),
        ]
    }

    /// Where an edge's handle sits.
    pub fn handle_point(&self, e: CropEdge, i: &CropInsets) -> CGPoint {
        let mid_x = i.left + (1.0 - i.left - i.right) / 2.0;
        let mid_y = i.top + (1.0 - i.top - i.bottom) / 2.0;
        match e {
            CropEdge::Left => self.frame.view_point(Vec2::new(i.left, mid_y)),
            CropEdge::Right => self.frame.view_point(Vec2::new(1.0 - i.right, mid_y)),
            CropEdge::Top => self.frame.view_point(Vec2::new(mid_x, i.top)),
            CropEdge::Bottom => self.frame.view_point(Vec2::new(mid_x, 1.0 - i.bottom)),
        }
    }

    /// The nearest edge handle within the grab radius.
    pub fn hit(&self, p: CGPoint, i: &CropInsets) -> Option<CropEdge> {
        let mut best: Option<(CropEdge, f64)> = None;
        for e in CropEdge::ALL {
            let c = self.handle_point(e, i);
            let d = (c.x - p.x).hypot(c.y - p.y);
            if d <= Self::GRAB_RADIUS && d < best.map_or(f64::INFINITY, |b| b.1) {
                best = Some((e, d));
            }
        }
        best.map(|b| b.0)
    }

    /// New inset (fraction) of `edge` with the pointer at `p`: 0 ... what leaves `MIN_REMAINING` against the opposite edge.
    pub fn inset(&self, edge: CropEdge, p: CGPoint, i: &CropInsets) -> f64 {
        let Some(n) = self.frame.frame_point(p) else { return edge.value(i) };
        let (raw, opposite) = match edge {
            CropEdge::Left => (n.x, i.right),
            CropEdge::Right => (1.0 - n.x, i.left),
            CropEdge::Top => (n.y, i.bottom),
            CropEdge::Bottom => (1.0 - n.y, i.top),
        };
        raw.max(0.0).min((1.0 - opposite - Self::MIN_REMAINING).max(0.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Frame drawn 200 x 100 at (50, 40).
    fn quad() -> [CGPoint; 4] {
        [
            CGPoint { x: 50.0, y: 40.0 },
            CGPoint { x: 250.0, y: 40.0 },
            CGPoint { x: 250.0, y: 140.0 },
            CGPoint { x: 50.0, y: 140.0 },
        ]
    }
    fn near(a: CGPoint, b: CGPoint) -> bool {
        (a.x - b.x).abs() < 1e-6 && (a.y - b.y).abs() < 1e-6
    }
    fn insets(left: f64, top: f64, right: f64, bottom: f64) -> CropInsets {
        CropInsets { left, top, right, bottom }
    }

    #[test]
    fn handles_sit_at_the_middle_of_each_cropped_edge() {
        let g = CropHandleGeometry::new(&quad());
        let i = insets(0.1, 0.2, 0.3, 0.0);
        assert!(near(g.handle_point(CropEdge::Left, &i), CGPoint { x: 70.0, y: 40.0 + 100.0 * (0.2 + 0.4) }));
        assert!(near(g.handle_point(CropEdge::Top, &i), CGPoint { x: 50.0 + 200.0 * (0.1 + 0.3), y: 60.0 }));
        assert!(near(g.handle_point(CropEdge::Right, &i), CGPoint { x: 50.0 + 200.0 * 0.7, y: 40.0 + 100.0 * 0.6 }));
        assert!(near(g.handle_point(CropEdge::Bottom, &i), CGPoint { x: 50.0 + 200.0 * 0.4, y: 140.0 }));
    }

    #[test]
    fn hit_picks_the_nearest_handle_only() {
        let g = CropHandleGeometry::new(&quad());
        let i = CropInsets::NONE;
        assert_eq!(g.hit(CGPoint { x: 52.0, y: 90.0 }, &i), Some(CropEdge::Left));
        assert_eq!(g.hit(CGPoint { x: 150.0, y: 138.0 }, &i), Some(CropEdge::Bottom));
        assert_eq!(g.hit(CGPoint { x: 150.0, y: 90.0 }, &i), None);
    }

    #[test]
    fn drag_writes_only_that_edge_and_clamps() {
        let g = CropHandleGeometry::new(&quad());
        let i = insets(0.0, 0.0, 0.5, 0.0);
        assert_eq!(g.inset(CropEdge::Left, CGPoint { x: 100.0, y: 90.0 }, &i), 0.25);
        assert_eq!(g.inset(CropEdge::Left, CGPoint { x: 0.0, y: 90.0 }, &i), 0.0);
        assert_eq!(g.inset(CropEdge::Left, CGPoint { x: 240.0, y: 90.0 }, &i), 0.5 - CropHandleGeometry::MIN_REMAINING);
        assert_eq!(g.inset(CropEdge::Bottom, CGPoint { x: 150.0, y: 115.0 }, &i), 0.25);
    }

    #[test]
    fn rotated_layer_still_drags_along_its_own_axis() {
        let q = [
            CGPoint { x: 100.0, y: 0.0 },
            CGPoint { x: 100.0, y: 200.0 },
            CGPoint { x: 0.0, y: 200.0 },
            CGPoint { x: 0.0, y: 0.0 },
        ];
        let g = CropHandleGeometry::new(&q);
        assert_eq!(g.inset(CropEdge::Top, CGPoint { x: 75.0, y: 50.0 }, &CropInsets::NONE), 0.25);
    }

    #[test]
    fn edges_map_to_the_effect_keys() {
        assert_eq!(CropEdge::ALL.map(|e| e.effect_key()), ["left", "top", "right", "bottom"]);
        assert_eq!(CropEdge::Top.setting(0.2, &CropInsets::NONE), insets(0.0, 0.2, 0.0, 0.0));
    }
}
