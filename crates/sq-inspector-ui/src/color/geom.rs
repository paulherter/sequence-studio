//! CoreGraphics rectangle helpers the Swift code calls on `CGRect` (union, intersects, offsetBy).

use sq_uikit::controls_grid::{CGPoint, CGRect};

/// `CGRect.union` for two non-null rectangles.
pub(crate) fn union(a: &CGRect, b: &CGRect) -> CGRect {
    let x0 = a.min_x().min(b.min_x());
    let y0 = a.min_y().min(b.min_y());
    let x1 = a.max_x().max(b.max_x());
    let y1 = a.max_y().max(b.max_y());
    CGRect::new(x0, y0, x1 - x0, y1 - y0)
}

/// `CGRect.intersects`: the rectangles share area (touching edges do not count).
pub(crate) fn intersects(a: &CGRect, b: &CGRect) -> bool {
    a.min_x() < b.max_x() && b.min_x() < a.max_x() && a.min_y() < b.max_y() && b.min_y() < a.max_y()
}

/// `CGRect.offsetBy`.
pub(crate) fn offset_by(r: &CGRect, dx: f64, dy: f64) -> CGRect {
    CGRect::new(r.x + dx, r.y + dy, r.width, r.height)
}

/// `hypot` of two offsets.
pub(crate) fn dist(a: CGPoint, b: CGPoint) -> f64 {
    (a.x - b.x).hypot(a.y - b.y)
}
