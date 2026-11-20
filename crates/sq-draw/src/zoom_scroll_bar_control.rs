// Swift: ZoomScrollBarControl.swift
//! The zoom/scroll bar under the Timeline and in Effect Controls (`ZoomScrollBar`) on the canvas: the same
//! `ZoomScrollBarGesture` rules and `KeyframeZoomBarGeometry` mapping, the kit `Timeline/ZoomBar` look (8 pt raised stone
//! track, a knob at each end of the span). Coordinates are the owner's points; `bounds` is the bar's rect.

use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::theme::DrawTheme;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::zoom_scroll_bar_gesture::{KeyframeZoomBarGeometry, Output, Part, ZoomScrollBarGesture};

/// One zoom/scroll bar: its gesture and hover state.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ZoomScrollBarControl {
    gesture: ZoomScrollBarGesture,
    /// The part under the pointer.
    pub hovered: Option<Part>,
}

impl ZoomScrollBarControl {
    /// Bar height.
    pub const HEIGHT: f64 = ZoomScrollBarGesture::HEIGHT;

    /// A bar at rest.
    pub fn new() -> ZoomScrollBarControl {
        ZoomScrollBarControl::default()
    }

    /// The gesture state.
    pub fn gesture(&self) -> &ZoomScrollBarGesture {
        &self.gesture
    }

    /// Whether a drag is running.
    pub fn is_dragging(&self) -> bool {
        self.gesture.drag().is_some()
    }

    /// A press at `p` inside `bounds`.
    pub fn mouse_down(&mut self, p: CGPoint, click_count: i64, bounds: CGRect, handles: (f64, f64)) -> Vec<Output> {
        self.gesture.begin(p.x - bounds.min_x(), click_count, bounds.width, handles)
    }

    /// The pointer moved with the button down.
    pub fn mouse_dragged(&self, p: CGPoint, bounds: CGRect) -> Option<Output> {
        self.gesture.drag_to(p.x - bounds.min_x(), bounds.width)
    }

    /// The button went up.
    pub fn mouse_up(&mut self) {
        self.gesture.end();
    }

    /// Hover over the bar (`None` = outside).
    pub fn hover(&mut self, p: Option<CGPoint>, bounds: CGRect, handles: (f64, f64)) {
        let Some(p) = p.filter(|p| bounds.contains(*p)) else {
            self.hovered = None;
            return;
        };
        self.hovered = Some(KeyframeZoomBarGeometry::new(bounds.width).part(p.x - bounds.min_x(), handles));
    }

    /// Draws the bar.
    pub fn draw(&self, c: &mut Canvas, bounds: CGRect, h: (f64, f64), t: &DrawTheme, background: Option<Color>) {
        if let Some(background) = background {
            c.fill(bounds, background);
        }
        let g = KeyframeZoomBarGeometry::new(bounds.width);
        let mid_y = bounds.mid_y();
        let xl = bounds.min_x() + g.x_for_fraction(h.0);
        let xh = bounds.min_x() + g.x_for_fraction(h.1);
        let inset = KeyframeZoomBarGeometry::SIDE_INSET;
        // The kit's `Timeline/ZoomBar`: a raised stone track with a round knob at each end of the visible span; between
        // the knobs a faint neutral body shows the span (the maintainer: no big blue bar).
        crate::stone_controls::zoom_bar_stone(c, bounds, inset, xl, xh, t);
        let k = crate::stone_controls::ZOOM_BAR_HEIGHT;
        // Rest, hover and press are three levels of the theme's ink (white on dark, near-black on light), so each differs in both themes.
        let level = if self.gesture.is_panning() {
            0.26
        } else if self.hovered == Some(Part::Body) {
            0.15
        } else {
            0.07
        };
        let body = CGRect::new(xl + k / 2.0, mid_y - k / 2.0, (xh - xl - k).max(0.0), k);
        c.fill(body, t.label().with_alpha(level));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hover_names_the_part_and_leaving_clears_it() {
        let mut z = ZoomScrollBarControl::new();
        let b = CGRect::new(10.0, 0.0, 200.0, 18.0);
        let mid = CGPoint { x: 110.0, y: 9.0 };
        z.hover(Some(mid), b, (0.25, 0.75));
        assert_eq!(z.hovered, Some(Part::Body));
        z.hover(Some(CGPoint { x: 500.0, y: 9.0 }), b, (0.25, 0.75));
        assert_eq!(z.hovered, None);
    }

    #[test]
    fn the_body_draws_brighter_while_hovered() {
        let t = DrawTheme::default();
        let b = CGRect::new(0.0, 0.0, 100.0, 18.0);
        let mut z = ZoomScrollBarControl::new();
        let mut rest = Canvas::with_size(100.0, 18.0, None, 1.0);
        z.draw(&mut rest, b, (0.2, 0.8), &t, None);
        z.hover(Some(CGPoint { x: 50.0, y: 9.0 }), b, (0.2, 0.8));
        let mut hot = Canvas::with_size(100.0, 18.0, None, 1.0);
        z.draw(&mut hot, b, (0.2, 0.8), &t, None);
        let alpha = |c: &Canvas| c.list.quads().last().map(|q| q.color.a);
        assert!(alpha(&hot) > alpha(&rest));
    }

    #[test]
    fn rest_hover_and_press_differ_in_both_themes() {
        for dark in [true, false] {
            let mode = if dark {
                sq_uikit::appearance_palette::AppearanceMode::Dark
            } else {
                sq_uikit::appearance_palette::AppearanceMode::Light
            };
            let t = DrawTheme::new(&sq_uikit::appearance_palette::AppearanceSettings::new(mode, 0, 50), 1.0);
            let b = CGRect::new(0.0, 0.0, 100.0, 18.0);
            let body = |z: &ZoomScrollBarControl| {
                let mut c = Canvas::with_size(100.0, 18.0, None, 1.0);
                z.draw(&mut c, b, (0.2, 0.8), &t, None);
                c.list.quads().last().map(|q| q.color)
            };
            let rest = ZoomScrollBarControl::new();
            let mut hot = ZoomScrollBarControl::new();
            hot.hover(Some(CGPoint { x: 50.0, y: 9.0 }), b, (0.2, 0.8));
            let mut down = ZoomScrollBarControl::new();
            down.mouse_down(CGPoint { x: 50.0, y: 9.0 }, 1, b, (0.2, 0.8));
            let (r, h, d) = (body(&rest), body(&hot), body(&down));
            assert!(r != h && h != d && r != d, "dark {dark}: {r:?} {h:?} {d:?}");
        }
    }

    #[test]
    fn the_bar_is_the_kits_eight_point_raised_stone_with_a_knob_at_each_end() {
        let t = DrawTheme::default();
        let b = CGRect::new(0.0, 0.0, 200.0, 18.0);
        let mut c = Canvas::with_size(200.0, 18.0, None, 1.0);
        ZoomScrollBarControl::new().draw(&mut c, b, (0.0, 1.0), &t, None);
        let img = crate::software::SoftwareRenderer::render(
            &c.list,
            200,
            18,
            Color::BLACK,
            &crate::software::Sources::default(),
        );
        let px = |x: usize, y: usize| img.pixels[(y * 200 + x) * 4..(y * 200 + x) * 4 + 3].to_vec();
        assert_eq!(px(100, 4), vec![0, 0, 0], "8 pt tall: row 4 is above the bar (rows 5...12)");
        assert_ne!(px(100, 8), vec![0, 0, 0], "the raised stone track");
        let knob = px(11, 9);
        assert!(knob[0] > 100, "the round knob at the start is the light zoom knob, got {knob:?}");
    }
}
