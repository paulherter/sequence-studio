//! Small `CGRect` helpers the Swift code gets from CoreGraphics (`intersects`, `intersection`, `insetBy`, `minX`...).

use sq_uikit::controls_grid::{CGPoint, CGRect};

/// Swift `CGRect` accessors and tests on [`CGRect`].
pub trait RectExt {
    /// `insetBy(dx:dy:)`.
    fn inset(&self, dx: f64, dy: f64) -> CGRect;
    /// `intersects` (strict: shared edges and empty rects do not intersect).
    fn intersects(&self, o: &CGRect) -> bool;
    /// `intersection` (an empty rect at the origin when disjoint, like `CGRectNull` read as empty).
    fn intersection(&self, o: &CGRect) -> CGRect;
    /// `contains(point)` (half-open like CoreGraphics).
    fn has(&self, p: CGPoint) -> bool;
    /// `isEmpty`.
    fn is_empty_rect(&self) -> bool;
}

impl RectExt for CGRect {
    fn inset(&self, dx: f64, dy: f64) -> CGRect {
        CGRect::new(self.x + dx, self.y + dy, self.width - 2.0 * dx, self.height - 2.0 * dy)
    }
    fn intersects(&self, o: &CGRect) -> bool {
        !self.is_empty_rect()
            && !o.is_empty_rect()
            && self.x < o.max_x()
            && o.x < self.max_x()
            && self.y < o.max_y()
            && o.y < self.max_y()
    }
    fn intersection(&self, o: &CGRect) -> CGRect {
        let x0 = self.x.max(o.x);
        let y0 = self.y.max(o.y);
        let x1 = self.max_x().min(o.max_x());
        let y1 = self.max_y().min(o.max_y());
        if x1 <= x0 || y1 <= y0 { CGRect::new(0.0, 0.0, 0.0, 0.0) } else { CGRect::new(x0, y0, x1 - x0, y1 - y0) }
    }
    fn has(&self, p: CGPoint) -> bool {
        p.x >= self.x && p.x < self.max_x() && p.y >= self.y && p.y < self.max_y()
    }
    fn is_empty_rect(&self) -> bool {
        self.width <= 0.0 || self.height <= 0.0
    }
}
