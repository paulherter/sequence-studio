//! The one close X of every dialog, sheet, popover and notice (kit `Form/IconButton/Close`: a 22 pt button with a 14 pt
//! Lucide X in `text3`; the notice's `Close` is 20 pt with an 11 pt X). The X is a hairline of about 8 pt; the
//! pointer target stays at least 24 pt so the small glyph is still easy to hit.

use crate::stone::{hover_level, press_level};
use crate::{Canvas, DrawTheme};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::tokens::radius;
use sq_uikit::sqicon::SQIcon;

/// The kit's icon button: the box that lights up on hover.
pub const BUTTON: f64 = 22.0;
/// The glyph box of the dialog X (the X itself measures about 8.5 pt inside it).
pub const GLYPH: f64 = 14.0;
/// The notice's smaller X: box and glyph.
pub const NOTICE_BUTTON: f64 = 20.0;
pub const NOTICE_GLYPH: f64 = 11.0;
/// The least pointer target of a close X.
pub const MIN_HIT: f64 = 24.0;

/// What a close X shows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct CloseXState {
    pub hovered: bool,
    pub pressed: bool,
    /// Keyboard focus: the focus ring around the button box.
    pub focused: bool,
}

/// Where the X sits inside its pointer `frame`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CloseXGeometry {
    /// The box that takes the hover fill.
    pub button: CGRect,
    /// The glyph box.
    pub glyph: CGRect,
}

/// The pointer target for an X whose frame is `frame`: the frame itself, grown to `MIN_HIT` around its center.
pub fn hit_rect(frame: CGRect) -> CGRect {
    let (w, h) = (frame.width.max(MIN_HIT), frame.height.max(MIN_HIT));
    CGRect::new(frame.mid_x() - w / 2.0, frame.mid_y() - h / 2.0, w, h)
}

/// The button box (`button` pt square) and the glyph (`glyph` pt square) centered in `frame`.
pub fn geometry(frame: CGRect, button: f64, glyph: f64) -> CloseXGeometry {
    let sq = |s: f64| CGRect::new(frame.mid_x() - s / 2.0, frame.mid_y() - s / 2.0, s, s);
    CloseXGeometry { button: sq(button), glyph: sq(glyph) }
}

impl Canvas<'_> {
    /// The dialog close X centered in `frame` (kit 22 pt button, 14 pt glyph).
    pub fn close_x(&mut self, frame: CGRect, state: CloseXState, t: &DrawTheme) {
        self.close_x_sized(frame, BUTTON, GLYPH, state, t);
    }

    /// A close X of `button` / `glyph` size centered in `frame`: hover fills the box softly, the glyph rises from
    /// `text3` to `text2`, a press dims it back.
    pub fn close_x_sized(&mut self, frame: CGRect, button: f64, glyph: f64, state: CloseXState, t: &DrawTheme) {
        let g = geometry(frame, button, glyph);
        let hl = hover_level(state.hovered && !state.pressed);
        let pl = press_level(self, frame, state.pressed);
        let fill = t.fill_hover();
        let over = hl.max(pl);
        let ink = t.label3().mix(t.label2(), hl).mix(t.label3(), pl);
        self.stone_ghost_button(g.button, f64::from(radius::CONTROL), fill.with_alpha(fill.a * over), state.focused, t);
        self.draw_icon(SQIcon::Close, CGPoint::new(g.glyph.x, g.glyph.y), glyph, ink, None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_glyph_is_the_kits_14_pt_box_centered_in_a_22_pt_button() {
        let g = geometry(CGRect::new(100.0, 40.0, 28.0, 28.0), BUTTON, GLYPH);
        assert_eq!((g.button.width, g.button.height), (22.0, 22.0));
        assert_eq!((g.glyph.width, g.glyph.height), (14.0, 14.0));
        assert_eq!((g.button.mid_x(), g.button.mid_y()), (114.0, 54.0));
        assert_eq!((g.glyph.mid_x(), g.glyph.mid_y()), (114.0, 54.0));
    }

    #[test]
    fn the_notice_x_is_20_with_an_11_pt_glyph() {
        let g = geometry(CGRect::new(0.0, 0.0, 20.0, 20.0), NOTICE_BUTTON, NOTICE_GLYPH);
        assert_eq!((g.button.width, g.glyph.width), (20.0, 11.0));
    }

    #[test]
    fn a_small_frame_still_has_a_24_pt_hit_rect_and_a_big_one_keeps_its_size() {
        let small = hit_rect(CGRect::new(10.0, 10.0, 16.0, 16.0));
        assert_eq!((small.width, small.height, small.mid_x(), small.mid_y()), (24.0, 24.0, 18.0, 18.0));
        let big = hit_rect(CGRect::new(0.0, 0.0, 28.0, 28.0));
        assert_eq!((big.width, big.height), (28.0, 28.0));
    }

    /// The glyph is the kit's `ph-x`: its strokes span 50..206 of 256 units, so about 8.5 pt at 14 pt.
    #[test]
    fn the_drawn_x_is_a_hairline_of_about_eight_points() {
        let g = crate::IconOutline::glyph(SQIcon::Close);
        let k = GLYPH / g.grid;
        let pts = g.fills.iter().chain(g.strokes.iter()).flatten();
        let (mut lo, mut hi) = (f64::MAX, f64::MIN);
        for p in pts {
            lo = lo.min(p.x * k);
            hi = hi.max(p.x * k);
        }
        let span = hi - lo + if g.fills.is_empty() { g.line_width * k } else { 0.0 };
        assert!((7.5..=9.0).contains(&span), "the X spans {span} pt");
    }
}
