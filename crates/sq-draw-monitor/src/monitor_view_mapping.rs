// Swift: MonitorViewMapping.swift
//! Where the sequence canvas sits inside the Program monitor view, for a `ViewerZoom`.

use sq_core_edit::viewer_zoom::{Size, ViewerZoom};
use sq_core_time::Vec2;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

/// Where the sequence canvas sits inside the Program monitor view, for a `ViewerZoom` (pure; mirrors
/// `Presenter.destinationRect`, which works in drawable pixels). Also the pan/zoom reducers of the monitor *view*
/// (Hand tool, trackpad scroll and pinch): they change the zoom value only, never the picture's transform.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MonitorViewMapping {
    /// View size in points (the overlay / viewer slot).
    pub view_size: CGSize,
    /// Device pixels per point (at least 0.5).
    pub backing_scale: f64,
    /// Sequence size in px (= the composite texture size).
    pub sequence_size: CGSize,
    /// The zoom shown.
    pub zoom: ViewerZoom,
}

impl MonitorViewMapping {
    /// Smallest view scale a gesture reaches.
    pub const MIN_SCALE: f64 = 0.05;
    /// Largest view scale a gesture reaches.
    pub const MAX_SCALE: f64 = 16.0;

    /// A mapping; the backing scale is raised to 0.5.
    pub fn new(view_size: CGSize, backing_scale: f64, sequence_size: CGSize, zoom: ViewerZoom) -> MonitorViewMapping {
        MonitorViewMapping { view_size, backing_scale: backing_scale.max(0.5), sequence_size, zoom }
    }

    /// The view in device pixels.
    pub fn drawable_size(&self) -> CGSize {
        CGSize::new(self.view_size.width * self.backing_scale, self.view_size.height * self.backing_scale)
    }

    /// Drawable px per sequence px when the picture is aspect-fitted.
    pub fn fit_scale(&self) -> f64 {
        if self.sequence_size.width <= 0.0 || self.sequence_size.height <= 0.0 {
            return 1.0;
        }
        let d = self.drawable_size();
        (d.width / self.sequence_size.width).min(d.height / self.sequence_size.height)
    }

    /// Effective drawable px per sequence px.
    pub fn scale(&self) -> f64 {
        match self.zoom {
            ViewerZoom::Fit => self.fit_scale(),
            ViewerZoom::Percent(p) => p.max(1) as f64 / 100.0,
            ViewerZoom::View { scale, .. } => scale,
        }
    }

    /// Sequence offset (from the canvas center) shown at the view center.
    pub fn center(&self) -> CGPoint {
        if let ViewerZoom::View { center_x, center_y, .. } = self.zoom {
            return CGPoint::new(center_x, center_y);
        }
        CGPoint::ZERO
    }

    /// True for `Fit`.
    pub fn is_fit(&self) -> bool {
        matches!(self.zoom, ViewerZoom::Fit)
    }

    /// The canvas in view points, origin top-left.
    pub fn canvas_rect(&self) -> CGRect {
        let d = self.drawable_size();
        let r = self.zoom.destination_rect(
            Size { width: self.sequence_size.width, height: self.sequence_size.height },
            Size { width: d.width, height: d.height },
        );
        CGRect::new(
            r.x / self.backing_scale,
            r.y / self.backing_scale,
            r.width / self.backing_scale,
            r.height / self.backing_scale,
        )
    }

    /// View point to sequence px relative to the canvas center.
    pub fn sequence_offset(&self, p: CGPoint) -> Vec2 {
        let r = self.canvas_rect();
        let k = self.scale() / self.backing_scale;
        if k <= 0.0 {
            return Vec2::ZERO;
        }
        Vec2::new((p.x - r.mid_x()) / k, (p.y - r.mid_y()) / k)
    }

    /// Position (sequence px from the canvas center) for a click at `p` (view points); `None` when the click lands in the
    /// letterbox of the view, beside the canvas. A click far outside the view clamps onto the canvas (Type tool, picking).
    pub fn click_position(&self, p: CGPoint) -> Option<Vec2> {
        let r = self.canvas_rect();
        let in_view = CGRect::new(0.0, 0.0, self.view_size.width, self.view_size.height).contains(p);
        if in_view && !r.contains(p) {
            return None;
        }
        let o = self.sequence_offset(p);
        let hw = self.sequence_size.width / 2.0;
        let hh = self.sequence_size.height / 2.0;
        Some(Vec2::new(o.x.max(-hw).min(hw), o.y.max(-hh).min(hh)))
    }

    /// The picture follows the pointer: dragging right by `d.width` points moves the picture right.
    pub fn panned(&self, d: CGSize) -> ViewerZoom {
        let s = self.scale();
        if !(s > 0.0 && s.is_finite() && self.view_size.width > 0.0 && self.view_size.height > 0.0) {
            return self.zoom;
        }
        let c = self.center();
        self.clamped(s, c.x - d.width * self.backing_scale / s, c.y - d.height * self.backing_scale / s)
    }

    /// Zooms by `factor`, keeping the sequence point under `p` (view points) where it is. Returns `Fit` when the result
    /// is (nearly) the fitted picture again.
    pub fn zoomed(&self, factor: f64, p: CGPoint) -> ViewerZoom {
        if !(factor > 0.0 && factor.is_finite()) {
            return self.zoom;
        }
        let s0 = self.scale();
        if !(s0 > 0.0 && s0.is_finite() && self.view_size.width > 0.0 && self.view_size.height > 0.0) {
            return self.zoom;
        }
        let s1 = (s0 * factor).clamp(Self::MIN_SCALE, Self::MAX_SCALE);
        let c = self.center();
        // Drawable-pixel offset of the anchor from the view center.
        let dx = (p.x - self.view_size.width / 2.0) * self.backing_scale;
        let dy = (p.y - self.view_size.height / 2.0) * self.backing_scale;
        let nx = c.x + dx / s0 - dx / s1;
        let ny = c.y + dy / s0 - dy / s1;
        let z = self.clamped(s1, nx, ny);
        if let ViewerZoom::View { scale, center_x, center_y } = z
            && (scale / self.fit_scale() - 1.0).abs() < 0.02
            && center_x.abs() < 1.0
            && center_y.abs() < 1.0
        {
            return ViewerZoom::Fit;
        }
        z
    }

    /// Keeps at least the canvas center inside the view.
    fn clamped(&self, scale: f64, center_x: f64, center_y: f64) -> ViewerZoom {
        let mx = self.sequence_size.width / 2.0;
        let my = self.sequence_size.height / 2.0;
        ViewerZoom::View { scale, center_x: center_x.max(-mx).min(mx), center_y: center_y.max(-my).min(my) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn click_position_is_nil_in_the_letterbox() {
        let m = MonitorViewMapping::new(CGSize::new(800.0, 800.0), 1.0, CGSize::new(1920.0, 1080.0), ViewerZoom::Fit);
        assert_eq!(m.click_position(CGPoint::new(400.0, 50.0)), None);
        assert_eq!(m.click_position(CGPoint::new(400.0, 400.0)), Some(Vec2::new(0.0, 0.0)));
    }

    #[test]
    fn zooming_back_to_the_fitted_scale_returns_fit() {
        let m = MonitorViewMapping::new(CGSize::new(800.0, 450.0), 1.0, CGSize::new(1920.0, 1080.0), ViewerZoom::Fit);
        let z = m.zoomed(2.0, CGPoint::new(400.0, 225.0));
        assert!(matches!(z, ViewerZoom::View { .. }));
        let back = MonitorViewMapping { zoom: z, ..m }.zoomed(0.5, CGPoint::new(400.0, 225.0));
        assert_eq!(back, ViewerZoom::Fit);
    }
}
