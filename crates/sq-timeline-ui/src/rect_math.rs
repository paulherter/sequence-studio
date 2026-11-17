//! `CGRect` operations the portable layout code needs on top of the sq-uikit `Rect`.

use sq_uikit::keyframe_graph_geometry::Rect;

/// `CGRect.intersection`: the overlap, `None` (the null rect) when the rectangles are apart.
pub(crate) fn intersection(a: &Rect, b: &Rect) -> Option<Rect> {
    let x0 = a.min_x().max(b.min_x());
    let x1 = a.max_x().min(b.max_x());
    let y0 = a.min_y().max(b.min_y());
    let y1 = a.max_y().min(b.max_y());
    if x1 < x0 || y1 < y0 { None } else { Some(Rect::new(x0, y0, x1 - x0, y1 - y0)) }
}

/// `CGRect.intersects`: the rectangles overlap with a non-empty area.
pub(crate) fn intersects(a: &Rect, b: &Rect) -> bool {
    a.min_x() < b.max_x() && b.min_x() < a.max_x() && a.min_y() < b.max_y() && b.min_y() < a.max_y()
}

/// `CGRect.union`.
#[cfg(test)]
pub(crate) fn union(a: &Rect, b: &Rect) -> Rect {
    let x0 = a.min_x().min(b.min_x());
    let y0 = a.min_y().min(b.min_y());
    Rect::new(x0, y0, a.max_x().max(b.max_x()) - x0, a.max_y().max(b.max_y()) - y0)
}
