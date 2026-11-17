// Swift: PortableTheme.swift
//! The few `Theme` tokens the portable timeline logic reads (SQUIKit's `Theme` is AppKit and stays Mac-only). Values are
//! the Mac's at UI scale 1; the draw-list toolkit scales points to pixels itself.
// shortcut: copies of `Theme.Metrics` / `Theme.Motion` / `Theme.PlayheadSkin` values, until the sq-uikit tokens carry them.

use sq_uikit::keyframe_graph_geometry::Rect;

/// `Theme.Metrics`.
pub mod metrics {
    /// Default video row height.
    pub const TRACK_V1: f64 = 40.0;
    /// Default audio row height.
    pub const TRACK_A1: f64 = 32.0;
    /// Other row height.
    pub const TRACK_OTHER: f64 = 20.0;
    /// Track header column width.
    pub const TRACK_HEADER: f64 = sq_uikit::redesign_tokens::size::TRACK_HEADER as f64;
    /// Tool column width.
    pub const TOOL_COLUMN: f64 = 0.0;
}

/// `Theme.PlayheadSkin`.
pub mod playhead_skin {
    use super::Rect;

    /// Width of the playhead line.
    pub const LINE_WIDTH: f64 = 1.0;

    /// Frame of the line centered at `x` (rounded to a whole point).
    pub fn line_frame(center_x: f64, y: f64, height: f64) -> Rect {
        Rect::new(center_x.round() - LINE_WIDTH / 2.0, y, LINE_WIDTH, height)
    }
}

/// `Theme.Motion`.
pub mod motion {
    /// Fast duration in seconds.
    pub const FAST: f64 = 0.12;

    /// Easing curves.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum Curve {
        /// Ease-out cubic.
        EaseOut,
    }

    impl Curve {
        /// The curve value at `t` (clamped to 0...1).
        pub fn value(self, t: f64) -> f64 {
            let c = t.clamp(0.0, 1.0);
            1.0 - (1.0 - c).powf(3.0)
        }
    }
}
