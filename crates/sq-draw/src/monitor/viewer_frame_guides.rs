// Swift: ViewerFrameGuides.swift
//! Aspect frame and safe margins of the Program monitor (session-only overlays).

use sq_uikit::controls_grid::CGRect;

/// Aspect frame of the Program monitor: the largest centered rectangle of a ratio inside the picture (9:16 inside a
/// 16:9 picture, 16:9 inside a vertical one). Session-only, drawn over the picture, never exported.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AspectFrame {
    /// No frame.
    Off,
    /// 9:16.
    Vertical9x16,
    /// 4:5.
    Portrait4x5,
    /// 1:1.
    Square1x1,
    /// 16:9.
    Wide16x9,
}

impl AspectFrame {
    /// Every case, in declaration order.
    pub const ALL: [AspectFrame; 5] = [
        AspectFrame::Off,
        AspectFrame::Vertical9x16,
        AspectFrame::Portrait4x5,
        AspectFrame::Square1x1,
        AspectFrame::Wide16x9,
    ];

    /// Menu title.
    pub fn title(self) -> &'static str {
        match self {
            AspectFrame::Off => "Off",
            AspectFrame::Vertical9x16 => "9:16",
            AspectFrame::Portrait4x5 => "4:5",
            AspectFrame::Square1x1 => "1:1",
            AspectFrame::Wide16x9 => "16:9",
        }
    }

    /// Width / height; `None` for `Off`.
    pub fn ratio(self) -> Option<f64> {
        match self {
            AspectFrame::Off => None,
            AspectFrame::Vertical9x16 => Some(9.0 / 16.0),
            AspectFrame::Portrait4x5 => Some(4.0 / 5.0),
            AspectFrame::Square1x1 => Some(1.0),
            AspectFrame::Wide16x9 => Some(16.0 / 9.0),
        }
    }

    /// The frame inside `picture` (same coordinate space), centered; `None` when off or the picture is empty.
    pub fn rect(self, picture: CGRect) -> Option<CGRect> {
        let ratio = self.ratio().filter(|_| picture.width > 0.0 && picture.height > 0.0)?;
        let (mut w, mut h) = (picture.width, picture.width / ratio);
        if h > picture.height {
            h = picture.height;
            w = h * ratio;
        }
        Some(CGRect::new(picture.mid_x() - w / 2.0, picture.mid_y() - h / 2.0, w, h))
    }
}

/// Size of the two safe-margin rectangles as percent of the picture (action outer, title inner). Session-only.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SafeMarginSizes {
    action: i64,
    title: i64,
}

impl SafeMarginSizes {
    /// Action-safe presets.
    pub const ACTION_PRESETS: [i64; 4] = [95, 93, 90, 85];
    /// Title-safe presets.
    pub const TITLE_PRESETS: [i64; 4] = [90, 85, 80, 70];
    /// 90 % and 80 %.
    pub const DEFAULT: SafeMarginSizes = SafeMarginSizes { action: 90, title: 80 };

    /// Sizes clamped to 50...100, the title never larger than the action rectangle.
    pub fn new(action: i64, title: i64) -> SafeMarginSizes {
        let a = action.clamp(50, 100);
        SafeMarginSizes { action: a, title: title.max(50).min(a) } // title safe never exceeds action safe
    }

    /// The action-safe percent.
    pub fn action(&self) -> i64 {
        self.action
    }
    /// The title-safe percent.
    pub fn title(&self) -> i64 {
        self.title
    }
    /// These sizes with a new action percent.
    pub fn setting_action(&self, v: i64) -> SafeMarginSizes {
        SafeMarginSizes::new(v, self.title)
    }
    /// These sizes with a new title percent.
    pub fn setting_title(&self, v: i64) -> SafeMarginSizes {
        SafeMarginSizes::new(self.action, v)
    }
    /// Fractions in draw order (outer first).
    pub fn fractions(&self) -> [f64; 2] {
        [self.action as f64 / 100.0, self.title as f64 / 100.0]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vertical_frame_inside_landscape_picture() {
        let r = AspectFrame::Vertical9x16.rect(CGRect::new(10.0, 20.0, 1600.0, 900.0));
        let r = r.unwrap_or_default();
        assert!((r.height - 900.0).abs() < 0.001 && (r.width - 506.25).abs() < 0.001);
        assert!((r.mid_x() - 810.0).abs() < 0.001 && (r.mid_y() - 470.0).abs() < 0.001);
    }

    #[test]
    fn wide_frame_inside_vertical_picture() {
        let r = AspectFrame::Wide16x9.rect(CGRect::new(0.0, 0.0, 900.0, 1600.0)).unwrap_or_default();
        assert!((r.width - 900.0).abs() < 0.001 && (r.height - 506.25).abs() < 0.001);
        assert!((r.mid_y() - 800.0).abs() < 0.001);
    }

    #[test]
    fn square_and_portrait_fit() {
        let s = AspectFrame::Square1x1.rect(CGRect::new(0.0, 0.0, 1920.0, 1080.0)).unwrap_or_default();
        assert!(s.width == 1080.0 && s.height == 1080.0);
        let p = AspectFrame::Portrait4x5.rect(CGRect::new(0.0, 0.0, 1920.0, 1080.0)).unwrap_or_default();
        assert!((p.width - 864.0).abs() < 0.001 && p.height == 1080.0);
        assert!(AspectFrame::Off.rect(CGRect::new(0.0, 0.0, 10.0, 10.0)).is_none());
        assert!(AspectFrame::Square1x1.rect(CGRect::default()).is_none());
    }

    #[test]
    fn safe_margin_sizes_clamp_and_keep_title_inside_action() {
        assert_eq!(SafeMarginSizes::DEFAULT.fractions(), [0.9, 0.8]);
        let s = SafeMarginSizes::DEFAULT.setting_action(70).setting_title(85);
        assert!(s.action() == 70 && s.title() == 70);
        assert_eq!(SafeMarginSizes::DEFAULT.setting_action(95).title(), 80);
        assert_eq!(SafeMarginSizes::new(10, 10).action(), 50);
        assert_eq!(SafeMarginSizes::DEFAULT.setting_action(75).title(), 75);
    }
}
