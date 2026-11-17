// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextTemplate+Resize.swift

use crate::text_style::TextBox;
use crate::text_template::TextTemplate;
use sq_core_time::Vec2;

/// Smallest font size a handle drag may produce (sequence px).
pub const RESIZE_SIZE_MIN: f64 = 1.0;
/// Largest font size a handle drag may produce (sequence px).
pub const RESIZE_SIZE_MAX: f64 = 2000.0;

/// `extension TextTemplate` of TextTemplate+Resize.swift.
pub trait TextTemplateResizeExt {
    /// This text with every size-bound value multiplied by `factor`: font size, second line size, tracking, line
    /// spacing and the area box. Dragging a text frame's handles resizes the font this way and leaves the clip's
    /// Scale alone. Sizes are sequence-frame px.
    fn resized(&self, factor: f64) -> TextTemplate;

    /// Font size factor for a scale-handle drag from Scale `start` to `now`: the geometric mean of the two axis ratios
    /// (edge handles stretch one axis). 1 for a degenerate start.
    fn resize_factor(start: Vec2, now: Vec2) -> f64;
}

impl TextTemplateResizeExt for TextTemplate {
    fn resized(&self, factor: f64) -> TextTemplate {
        if !(factor.is_finite() && factor > 0.0) {
            return self.clone();
        }
        let mut t = self.clone();
        let clamp = |v: f64| v.clamp(RESIZE_SIZE_MIN, RESIZE_SIZE_MAX);
        t.style.size = clamp(self.style.size * factor);
        let applied = t.style.size / self.style.size.max(1e-9); // after clamping, the rest follows the size actually reached
        t.style.tracking = self.style.tracking * applied;
        t.style.line_spacing = self.style.line_spacing * applied;
        if let Some(second) = t.style.second_line.as_mut() {
            second.size = clamp(second.size * applied);
        }
        if let Some(own) = t.style.line_styles.as_mut() {
            for l in own.iter_mut() {
                l.size = clamp(l.size * applied);
            }
        }
        if let Some(b) = self.box_ {
            t.box_ = Some(TextBox::new(b.width * applied, b.height * applied));
        }
        t
    }

    fn resize_factor(start: Vec2, now: Vec2) -> f64 {
        if !(start.x.abs() > 1e-9 && start.y.abs() > 1e-9) {
            return 1.0;
        }
        let f = ((now.x / start.x) * (now.y / start.y)).abs().sqrt();
        if f.is_finite() && f > 0.0 { f } else { 1.0 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text_style::TextStyle;

    fn template(style: TextStyle, b: Option<TextBox>) -> TextTemplate {
        TextTemplate { box_: b, ..TextTemplate::new("t", "Hi", style) }
    }

    #[test]
    fn resize_scales_size_tracking_spacing_and_box() {
        let t = template(
            TextStyle { size: 40.0, line_spacing: 4.0, tracking: 2.0, ..TextStyle::default() },
            Some(TextBox::new(400.0, 100.0)),
        );
        let r = t.resized(1.5);
        assert_eq!(r.style.size, 60.0);
        assert_eq!(r.style.tracking, 3.0);
        assert_eq!(r.style.line_spacing, 6.0);
        assert_eq!(r.box_, Some(TextBox::new(600.0, 150.0)));
    }

    #[test]
    fn resize_clamps_and_ignores_bad_factors() {
        let t = template(TextStyle { size: 40.0, ..TextStyle::default() }, None);
        assert_eq!(t.resized(0.0001).style.size, 1.0);
        assert_eq!(t.resized(1000.0).style.size, 2000.0);
        assert_eq!(t.resized(f64::NAN), t);
        assert_eq!(t.resized(-1.0), t);
    }

    #[test]
    fn handle_factor_is_the_mean_of_both_axes() {
        let v = Vec2::new;
        assert_eq!(TextTemplate::resize_factor(v(1.0, 1.0), v(2.0, 2.0)), 2.0);
        assert!((TextTemplate::resize_factor(v(1.0, 1.0), v(4.0, 1.0)) - 2.0).abs() < 1e-12); // edge handle: one axis
        assert_eq!(TextTemplate::resize_factor(v(0.0, 1.0), v(2.0, 2.0)), 1.0);
        assert_eq!(TextTemplate::resize_factor(v(1.0, 1.0), v(0.0, 2.0)), 1.0);
    }
}
