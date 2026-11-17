//! Small `CGRect` helpers the monitor code needs on top of `sq_uikit`'s rect (Swift `CGRect` members).

use sq_uikit::controls_grid::{CGPoint, CGRect};

/// Swift `CGRect.offsetBy`, `intersection`, `isEmpty` and the corner list of the picture tools.
pub trait RectExt {
    /// `offsetBy(dx:dy:)`.
    fn offset_by(&self, dx: f64, dy: f64) -> CGRect;
    /// `intersection(_:)`; `None` is Swift's null rect (no overlap).
    fn intersection(&self, o: &CGRect) -> Option<CGRect>;
    /// The four corners clockwise from the top-left (for polygon strokes).
    fn corner_points(&self) -> [CGPoint; 4];
    /// `isEmpty` for a non-null rect: no width or no height.
    fn is_empty_rect(&self) -> bool;
}

impl RectExt for CGRect {
    fn offset_by(&self, dx: f64, dy: f64) -> CGRect {
        CGRect::new(self.x + dx, self.y + dy, self.width, self.height)
    }
    fn intersection(&self, o: &CGRect) -> Option<CGRect> {
        let x0 = self.min_x().max(o.min_x());
        let y0 = self.min_y().max(o.min_y());
        let x1 = self.max_x().min(o.max_x());
        let y1 = self.max_y().min(o.max_y());
        if x1 < x0 || y1 < y0 { None } else { Some(CGRect::new(x0, y0, x1 - x0, y1 - y0)) }
    }
    fn corner_points(&self) -> [CGPoint; 4] {
        [
            CGPoint::new(self.min_x(), self.min_y()),
            CGPoint::new(self.max_x(), self.min_y()),
            CGPoint::new(self.max_x(), self.max_y()),
            CGPoint::new(self.min_x(), self.max_y()),
        ]
    }
    fn is_empty_rect(&self) -> bool {
        self.width <= 0.0 || self.height <= 0.0
    }
}
