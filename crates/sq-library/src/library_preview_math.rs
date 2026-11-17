// Swift: LibraryPreviewMath.swift
//! Pure helpers of the Library preview transport and panel layout.

use crate::library_item_kind::LibraryItemKind;

/// The preview a library kind gets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PreviewMode {
    /// Sound player.
    Audio,
    /// Movie player.
    Video,
    /// Still image.
    Image,
}

/// Smallest viewer height.
pub const MIN_VIEWER_HEIGHT: f64 = 60.0;
/// Largest viewer height.
pub const MAX_VIEWER_HEIGHT: f64 = 480.0;
/// Height the list keeps at least.
pub const LIST_RESERVE: f64 = 160.0;
/// What the bar needs besides the viewer (padding, transport).
pub const CHROME_HEIGHT: f64 = 70.0;
/// Sidebar width when nothing is stored.
pub const DEFAULT_SIDEBAR_WIDTH: f64 = 136.0;
/// Smallest sidebar width.
pub const MIN_SIDEBAR_WIDTH: f64 = 96.0;
/// Largest sidebar width.
pub const MAX_SIDEBAR_WIDTH: f64 = 320.0;
/// Width the item area keeps at least.
pub const CONTENT_RESERVE: f64 = 160.0;

/// Seek target for a skip button: clamped to 0...duration (an unknown duration only clamps at 0).
pub fn skip_target(position: f64, delta: f64, duration: f64) -> f64 {
    let t = position + delta;
    if !t.is_finite() {
        return 0.0;
    }
    if duration > 0.0 { t.max(0.0).min(duration) } else { t.max(0.0) }
}

/// "m:ss", or "h:mm:ss" from one hour; negative, NaN and infinity read 0:00.
pub fn time_text(seconds: f64) -> String {
    if !seconds.is_finite() || seconds <= 0.0 {
        return "0:00".to_string();
    }
    let s = seconds as i64;
    let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60);
    if h > 0 { format!("{h}:{m:02}:{sec:02}") } else { format!("{m}:{sec:02}") }
}

/// The preview a library kind gets.
pub fn mode(kind: LibraryItemKind) -> Option<PreviewMode> {
    match kind {
        LibraryItemKind::Audio => Some(PreviewMode::Audio),
        LibraryItemKind::Video => Some(PreviewMode::Video),
        LibraryItemKind::Image | LibraryItemKind::Overlay => Some(PreviewMode::Image),
        LibraryItemKind::Lut | LibraryItemKind::Font | LibraryItemKind::Other => None,
    }
}

/// The viewer height to show: the stored one (or `fallback`), within min/max and, when the panel height is known
/// (> 0), leaving `LIST_RESERVE` for the list.
pub fn viewer_height(stored: Option<f64>, fallback: f64, panel_height: f64) -> f64 {
    let mut h = stored.filter(|v| v.is_finite()).unwrap_or(fallback);
    let mut top = MAX_VIEWER_HEIGHT;
    if panel_height > 0.0 {
        top = top.min(panel_height - LIST_RESERVE - CHROME_HEIGHT);
    }
    h = h.min(top);
    h.max(MIN_VIEWER_HEIGHT)
}

/// Dragging the divider up (negative y change in a flipped view) makes the viewer taller.
pub fn resized_height(start: f64, drag_delta_y: f64) -> f64 {
    start - drag_delta_y
}

/// The sidebar width to show: the stored one (or the default) within min/max, leaving `CONTENT_RESERVE` for the items.
/// A panel narrower than min + reserve keeps the minimum.
pub fn sidebar_width(stored: Option<f64>, panel_width: f64) -> f64 {
    let w = stored.filter(|v| v.is_finite()).unwrap_or(DEFAULT_SIDEBAR_WIDTH);
    let mut top = MAX_SIDEBAR_WIDTH;
    if panel_width > 0.0 {
        top = top.min(panel_width - CONTENT_RESERVE);
    }
    w.min(top).max(MIN_SIDEBAR_WIDTH)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skip_clamps() {
        assert_eq!(skip_target(3.0, -5.0, 60.0), 0.0);
        assert_eq!(skip_target(58.0, 5.0, 60.0), 60.0);
        assert_eq!(skip_target(10.0, 5.0, 60.0), 15.0);
        assert_eq!(skip_target(10.0, 5.0, 0.0), 15.0);
        assert_eq!(skip_target(f64::NAN, 5.0, 60.0), 0.0);
    }

    #[test]
    fn time_text_formats() {
        assert_eq!(time_text(0.0), "0:00");
        assert_eq!(time_text(65.9), "1:05");
        assert_eq!(time_text(3725.0), "1:02:05");
        assert_eq!(time_text(-3.0), "0:00");
        assert_eq!(time_text(f64::INFINITY), "0:00");
    }

    #[test]
    fn modes() {
        assert_eq!(mode(LibraryItemKind::Audio), Some(PreviewMode::Audio));
        assert_eq!(mode(LibraryItemKind::Video), Some(PreviewMode::Video));
        assert_eq!(mode(LibraryItemKind::Image), Some(PreviewMode::Image));
        assert_eq!(mode(LibraryItemKind::Lut), None);
    }

    #[test]
    fn viewer_height_clamps() {
        assert_eq!(viewer_height(None, 150.0, 800.0), 150.0);
        assert_eq!(viewer_height(Some(10.0), 150.0, 800.0), MIN_VIEWER_HEIGHT);
        assert_eq!(viewer_height(Some(9000.0), 150.0, 800.0), MAX_VIEWER_HEIGHT);
        assert_eq!(viewer_height(Some(f64::NAN), 150.0, 800.0), 150.0);
        assert_eq!(viewer_height(Some(300.0), 150.0, 400.0), 400.0 - LIST_RESERVE - CHROME_HEIGHT);
        assert_eq!(viewer_height(Some(300.0), 150.0, 100.0), MIN_VIEWER_HEIGHT);
        assert_eq!(viewer_height(Some(300.0), 150.0, 0.0), 300.0);
    }

    #[test]
    fn drag_resize_grows_upward() {
        assert_eq!(resized_height(150.0, -40.0), 190.0);
        assert_eq!(resized_height(150.0, 40.0), 110.0);
    }

    #[test]
    fn sidebar_width_defaults_and_clamps() {
        assert_eq!(sidebar_width(None, 600.0), 136.0);
        assert_eq!(sidebar_width(Some(10.0), 600.0), 96.0);
        assert_eq!(sidebar_width(Some(900.0), 2000.0), 320.0);
        assert_eq!(sidebar_width(Some(300.0), 400.0), 240.0);
        assert_eq!(sidebar_width(Some(200.0), 200.0), 96.0);
        assert_eq!(sidebar_width(Some(f64::NAN), 600.0), 136.0);
    }
}
