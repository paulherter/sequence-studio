//! The `CGRect` helpers the Swift panels call (`intersects`, `offsetBy`, `hypot`).

use sq_uikit::controls_grid::{CGPoint, CGRect};

/// `CGRect.intersects`: the rectangles share area (touching edges do not count).
pub(crate) fn intersects(a: &CGRect, b: &CGRect) -> bool {
    a.min_x() < b.max_x() && b.min_x() < a.max_x() && a.min_y() < b.max_y() && b.min_y() < a.max_y()
}

/// `CGRect.offsetBy`.
pub(crate) fn offset_by(r: &CGRect, dx: f64, dy: f64) -> CGRect {
    CGRect::new(r.x + dx, r.y + dy, r.width, r.height)
}

/// `hypot` of the offset between two points.
pub(crate) fn dist(a: CGPoint, b: CGPoint) -> f64 {
    (a.x - b.x).hypot(a.y - b.y)
}

/// `trimmingCharacters(in: .whitespaces)`: spaces and tabs at both ends.
pub(crate) fn trim_ws(s: &str) -> &str {
    s.trim_matches([' ', '\t'])
}
