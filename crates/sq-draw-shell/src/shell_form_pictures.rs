//! The two fixed mock pictures of the Settings choice cards (Dark / Light theme, Normal / Fast Cut timeline). They show a
//! theme and clip colors that are NOT the current theme's, so their colors are literals on purpose (allow-listed in
//! scripts/lint-ui-allow.txt for this file only); everything else in the form uses tokens.

use crate::shell_form::{ShellForm, text};
use sq_draw::DrawTheme;
use sq_draw::{Canvas, Color, TextAlign};
use sq_uikit::controls_grid::CGRect;
use sq_uikit::tokens::radius as rd;

impl ShellForm {
    /// The Dark / Light picture of the kit (`Settings/Choice/Dark|Light`, 189.33 x 78 scaled to `r`): the window with two
    /// panels around the viewer and one lane with two clips.
    pub(crate) fn paint_theme_picture(c: &mut Canvas, r: CGRect, dark: bool) {
        let (bg, panel, lane) = if dark { (0x0E0E10, 0x1F1F22, 0x2B2B2F) } else { (0xD9D9DD, 0xF4F4F6, 0xE6E6EA) };
        let (sx, sy) = (r.width / 189.33, r.height / 78.0);
        let part = |c: &mut Canvas, x: f64, y: f64, w: f64, h: f64, rgb: u32| {
            c.fill_rounded(
                CGRect::new(r.min_x() + x * sx, r.min_y() + y * sy, w * sx, h * sy),
                f64::from(rd::CLIP),
                Color::hex(rgb, 1.0),
            );
        };
        c.fill_rounded(r, f64::from(rd::CONTROL), Color::hex(bg, 1.0));
        part(c, 6.0, 6.0, 55.27, 33.16, panel);
        part(c, 64.27, 6.0, 71.85, 33.16, 0x111111);
        part(c, 139.12, 6.0, 44.21, 33.16, panel);
        part(c, 6.0, 42.16, 177.33, 29.84, lane);
        part(c, 27.28, 51.11, 53.2, 6.57, 0x3474B5);
        part(c, 87.57, 51.11, 39.01, 6.57, 0x3474B5);
    }

    /// The Normal / Fast Cut picture of the kit: three clips on one lane; Normal leaves a dashed gap, Fast Cut closes it.
    pub(crate) fn paint_edit_mode_picture(c: &mut Canvas, r: CGRect, fast: bool, t: &DrawTheme, font: f64) {
        c.fill_rounded(r, f64::from(rd::CONTROL), Color::hex(0x141416, 1.0));
        let (sx, y, h) = (r.width / 290.0, r.min_y() + r.height * 0.38, r.height * 0.26);
        let clip = |c: &mut Canvas, x: f64, w: f64, rgb: u32| {
            c.fill_rounded(CGRect::new(r.min_x() + x * sx, y, w * sx, h), f64::from(rd::CLIP), Color::hex(rgb, 1.0));
        };
        clip(c, 23.2, 75.4, 0x3474B5);
        let note = if fast {
            clip(c, 104.4, 87.0, 0x3474B5);
            clip(c, 197.2, 58.0, 0x2A5F96);
            "Gap closes by itself"
        } else {
            // The gap: a dashed outline (3 on, 2 off).
            let g = CGRect::new(r.min_x() + 104.4 * sx, y, 63.8 * sx, h);
            let dash = Color::hex(0xFFFFFF, 0.3);
            let mut x = g.min_x();
            while x < g.max_x() {
                let w = 3.0f64.min(g.max_x() - x);
                c.fill(CGRect::new(x, g.min_y(), w, 1.0), dash);
                c.fill(CGRect::new(x, g.max_y() - 1.0, w, 1.0), dash);
                x += 5.0;
            }
            let mut yy = g.min_y();
            while yy < g.max_y() {
                let hh = 3.0f64.min(g.max_y() - yy);
                c.fill(CGRect::new(g.min_x(), yy, 1.0, hh), dash);
                c.fill(CGRect::new(g.max_x() - 1.0, yy, 1.0, hh), dash);
                yy += 5.0;
            }
            clip(c, 174.0, 87.0, 0x3474B5);
            "Delete leaves a gap"
        };
        text(
            c,
            note,
            CGRect::new(r.min_x() + 10.0, r.min_y() + r.height * 0.77, r.width - 20.0, 14.0),
            font - 1.0,
            t.label3(),
            TextAlign::Left,
        );
    }
}
