//! Small helpers the audio and transition draw blocks share (Swift `CGRect` calls and the `onMenu` hook).

use sq_uikit::controls_grid::CGRect;
use sq_uikit::sqmenu_model::SQMenuItem;

/// `CGRect.offsetBy`.
pub(crate) fn offset_by(r: &CGRect, dx: f64, dy: f64) -> CGRect {
    CGRect::new(r.x + dx, r.y + dy, r.width, r.height)
}

/// A menu a block asked for (Swift `onMenu(items, anchor)`): the host shows the SQ menu at `anchor` (block coordinates).
#[derive(Clone, Debug)]
pub struct MenuRequest {
    pub items: Vec<SQMenuItem>,
    pub anchor: CGRect,
}
