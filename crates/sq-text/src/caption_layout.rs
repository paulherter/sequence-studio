// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: CaptionLayout.swift (the Core Text raster pivots `pivot(of:)` and `wholePivot(of:)` are not ported: `TextRaster` is Apple-only)
//! The one place that says how a caption looks and where it sits. The Program monitor and the export burn-in both
//! use it, so the picture you cut on is the picture you export: the caption is area text in a box inside the safe area
//! (FB-Y: at the top, middle or bottom, text aligned left/center/right in it, plus a free offset), and the center of the
//! text lines is the pivot of its animation (the caption pop scales about the words, not about the box).

use crate::caption_karaoke::TextHighlight;
use crate::font_resolver::{FitKey, FontResolver};
use crate::text_layout::{TextLayout, TextLayoutResult, TextRect};
use crate::text_style::{TextAlignment, TextBox, TextStyle, TextVerticalAlignment};
use crate::text_template::TextTemplate;
use sq_core_model::{CaptionHorizontal, CaptionPosition, CaptionVertical};
use sq_core_time::{Vec2, word_segmentation};

/// Namespace of the caption layout functions.
pub enum CaptionLayout {}

impl CaptionLayout {
    /// Distance of the box from the canvas top or bottom edge (fraction of the height).
    pub const BOTTOM_MARGIN: f64 = 0.12;
    /// Box width (fraction of the canvas width).
    pub const WIDTH_FRACTION: f64 = 0.86;
    /// Box height (fraction of the canvas height); the text is aligned inside it by the position.
    pub const BOX_HEIGHT_FRACTION: f64 = 0.30;

    /// The caption box for a canvas.
    pub fn box_(canvas_width: f64, canvas_height: f64, width_fraction: f64) -> TextBox {
        TextBox::new(canvas_width * width_fraction, canvas_height * Self::BOX_HEIGHT_FRACTION)
    }

    /// Text alignment in the box for a position.
    pub fn align(s: &mut TextStyle, position: &CaptionPosition) {
        s.alignment = match position.horizontal {
            CaptionHorizontal::Left => TextAlignment::Left,
            CaptionHorizontal::Center => TextAlignment::Center,
            CaptionHorizontal::Right => TextAlignment::Right,
        };
        s.vertical_alignment = match position.vertical {
            CaptionVertical::Top => TextVerticalAlignment::Top,
            CaptionVertical::Middle => TextVerticalAlignment::Middle,
            CaptionVertical::Bottom => TextVerticalAlignment::Bottom,
        };
    }

    /// The caption as a text template: aligned, fitted to the box, in a caption box.
    pub fn template(
        text: &str,
        style: &TextStyle,
        canvas_width: f64,
        canvas_height: f64,
        width_fraction: f64,
        highlight: Option<TextHighlight>,
        position: &CaptionPosition,
    ) -> TextTemplate {
        let mut s = style.clone();
        Self::align(&mut s, position);
        s.footage_fill = None; // a caption is never stenciled: it keeps its own colors
        s.second_line = None; // captions are one style; the second-line look belongs to text clips
        let b = Self::box_(canvas_width, canvas_height, width_fraction);
        s.size = Self::fitting_size(text, &s, b.width);
        let mut t = TextTemplate::new("Caption", text, s);
        t.highlight = highlight;
        t.box_ = Some(b);
        t
    }

    /// FB-M: words are never split across lines, so a caption whose widest word (with its stroke and pill padding) is wider
    /// than the box is drawn smaller until that word fits. Otherwise the style's size.
    pub fn fitting_size(text: &str, style: &TextStyle, box_width: f64) -> f64 {
        if style.size <= 0.0 {
            return style.size;
        }
        // Asked for every caption on every playback frame: one layout per word, remembered until the fonts change.
        FontResolver::memo()
            .fit(FitKey::new(text, style, box_width), || Self::measure_fitting_size(text, style, box_width))
    }

    fn measure_fitting_size(text: &str, style: &TextStyle, box_width: f64) -> f64 {
        let words = word_segmentation::words(text);
        if words.is_empty() || style.size <= 0.0 {
            return style.size;
        }
        let widest = words
            .iter()
            .map(|w| TextLayout::layout(w, style, None, None).lines.first().map_or(0.0, |l| l.width))
            .fold(None, |m: Option<f64>, w| Some(m.map_or(w, |m| m.max(w))))
            .unwrap_or(0.0);
        let extra =
            2.0 * (style.stroke.map_or(0.0, |s| s.reach()) + style.background.map_or(0.0, |b| b.padding.horizontal));
        let room = box_width - extra;
        if !(widest > room && room > 0.0) {
            return style.size;
        }
        // Width grows linearly with the size (tracking is in points and does not scale; the 1 % margin covers it and rounding).
        1.0f64.max((style.size * room / widest * 0.99 * 100.0).floor() / 100.0)
    }

    /// Box center relative to the canvas center (sequence px, y down). `bottom_margin` is the distance from the top or
    /// bottom edge (top and bottom positions).
    pub fn box_centre(
        canvas_width: f64,
        canvas_height: f64,
        position: &CaptionPosition,
        bottom_margin: f64,
    ) -> (f64, f64) {
        let half = canvas_height * (0.5 - bottom_margin) - canvas_height * Self::BOX_HEIGHT_FRACTION / 2.0;
        let y = match position.vertical {
            CaptionVertical::Top => -half,
            CaptionVertical::Middle => 0.0,
            CaptionVertical::Bottom => half,
        };
        (canvas_width * position.offset_x, y + canvas_height * position.offset_y)
    }

    /// Center of the rendered raster in canvas pixels (origin top-left, y down). `origin` is the raster's top-left
    /// relative to the box (`TextRaster.originX/Y`), `size` its size in sequence pixels.
    pub fn raster_centre(
        canvas: (f64, f64),
        origin: (f64, f64),
        size: (f64, f64),
        width_fraction: f64,
        position: &CaptionPosition,
        bottom_margin: f64,
    ) -> (f64, f64) {
        let (canvas_width, canvas_height) = canvas;
        let b = Self::box_(canvas_width, canvas_height, width_fraction);
        let c = Self::box_centre(canvas_width, canvas_height, position, bottom_margin);
        let left = canvas_width / 2.0 + c.0 - b.width / 2.0;
        let top = canvas_height / 2.0 + c.1 - b.height / 2.0;
        (left + origin.0 + size.0 / 2.0, top + origin.1 + size.1 / 2.0)
    }

    /// Center of the text lines (layout space); nil for empty text. A pill is symmetric around them, a shadow is not part
    /// of it, so this is the center of the words as the eye sees them.
    pub fn text_centre(layout: &TextLayoutResult) -> Option<(f64, f64)> {
        let r = layout.lines.iter().map(|l| l.rect()).reduce(|acc: TextRect, r| acc.union(&r))?;
        Some((r.x + r.width / 2.0, r.y + r.height / 2.0))
    }

    /// Where the raster center is drawn when the caption is scaled and rotated (degrees, clockwise on screen) about its
    /// pivot and moved by `offset`: what the compositor does with an anchored layer in the Program monitor.
    pub fn draw_centre(
        raster_centre: (f64, f64),
        pivot: (f64, f64),
        scale: f64,
        rotation_degrees: f64,
        offset: Vec2,
    ) -> (f64, f64) {
        let (c, p) = (raster_centre, pivot);
        let r = rotation_degrees * std::f64::consts::PI / 180.0;
        let dx = -p.0 * scale;
        let dy = -p.1 * scale;
        (c.0 + p.0 + offset.x + r.cos() * dx - r.sin() * dy, c.1 + p.1 + offset.y + r.sin() * dx + r.cos() * dy)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::portable_font_match::use_bundled_fonts;
    use crate::text_style::{FontWeight, RGBAColor};

    fn style(size: f64) -> TextStyle {
        use_bundled_fonts();
        TextStyle::new("Inter", size, FontWeight::Regular, RGBAColor::WHITE)
    }

    fn position(vertical: CaptionVertical, horizontal: CaptionHorizontal) -> CaptionPosition {
        CaptionPosition { vertical, horizontal, offset_x: 0.0, offset_y: 0.0 }
    }

    #[test]
    fn the_box_is_a_share_of_the_canvas() {
        let b = CaptionLayout::box_(1080.0, 1920.0, CaptionLayout::WIDTH_FRACTION);
        assert!((b.width - 1080.0 * 0.86).abs() < 1e-9 && (b.height - 1920.0 * 0.30).abs() < 1e-9);
    }

    #[test]
    fn box_centre_sits_above_the_bottom_margin_and_follows_the_position() {
        let (x, y) = CaptionLayout::box_centre(
            1920.0,
            1080.0,
            &position(CaptionVertical::Bottom, CaptionHorizontal::Center),
            0.12,
        );
        assert_eq!(x, 0.0);
        assert!((y - 1080.0 * 0.23).abs() < 1e-9);
        let top =
            CaptionLayout::box_centre(1920.0, 1080.0, &position(CaptionVertical::Top, CaptionHorizontal::Center), 0.12);
        let middle = CaptionLayout::box_centre(
            1920.0,
            1080.0,
            &position(CaptionVertical::Middle, CaptionHorizontal::Center),
            0.12,
        );
        assert!((top.1 + y).abs() < 1e-9 && middle.1 == 0.0);
        let moved = CaptionPosition {
            offset_x: 0.1,
            offset_y: -0.05,
            ..position(CaptionVertical::Middle, CaptionHorizontal::Center)
        };
        let (mx, my) = CaptionLayout::box_centre(1000.0, 2000.0, &moved, 0.12);
        assert!((mx - 100.0).abs() < 1e-9 && (my + 100.0).abs() < 1e-9);
    }

    #[test]
    fn align_sets_horizontal_and_vertical_alignment() {
        let mut s = style(40.0);
        CaptionLayout::align(&mut s, &position(CaptionVertical::Top, CaptionHorizontal::Right));
        assert!(s.alignment == TextAlignment::Right && s.vertical_alignment == TextVerticalAlignment::Top);
    }

    #[test]
    fn the_raster_centre_adds_the_origin_and_half_the_size() {
        let c = CaptionLayout::raster_centre(
            (1920.0, 1080.0),
            (10.0, 20.0),
            (100.0, 50.0),
            CaptionLayout::WIDTH_FRACTION,
            &position(CaptionVertical::Bottom, CaptionHorizontal::Center),
            CaptionLayout::BOTTOM_MARGIN,
        );
        let b = CaptionLayout::box_(1920.0, 1080.0, CaptionLayout::WIDTH_FRACTION);
        let centre = CaptionLayout::box_centre(
            1920.0,
            1080.0,
            &position(CaptionVertical::Bottom, CaptionHorizontal::Center),
            0.12,
        );
        assert!((c.0 - (960.0 + centre.0 - b.width / 2.0 + 10.0 + 50.0)).abs() < 1e-9);
        assert!((c.1 - (540.0 + centre.1 - b.height / 2.0 + 20.0 + 25.0)).abs() < 1e-9);
    }

    #[test]
    fn draw_centre_without_scale_or_rotation_moves_by_the_offset() {
        let c = CaptionLayout::draw_centre((100.0, 50.0), (3.0, -4.0), 1.0, 0.0, Vec2::new(7.0, 9.0));
        assert!((c.0 - 107.0).abs() < 1e-9 && (c.1 - 59.0).abs() < 1e-9);
        // Half a turn about the pivot mirrors the raster centre through it.
        let r = CaptionLayout::draw_centre((100.0, 50.0), (3.0, -4.0), 1.0, 180.0, Vec2::ZERO);
        assert!((r.0 - 106.0).abs() < 1e-9 && (r.1 - 42.0).abs() < 1e-9);
    }

    #[test]
    fn a_short_caption_keeps_its_size_and_a_wide_word_shrinks() {
        let s = style(60.0);
        assert_eq!(CaptionLayout::fitting_size("Hi", &s, 800.0), 60.0);
        let shrunk = CaptionLayout::fitting_size("Supercalifragilisticexpialidocious", &s, 300.0);
        assert!((1.0..60.0).contains(&shrunk));
        let width =
            TextLayout::layout("Supercalifragilisticexpialidocious", &TextStyle { size: shrunk, ..s }, None, None)
                .lines[0]
                .width;
        // Inter's optical size widens smaller text, so the linear estimate lands a little over the room (as in Swift).
        assert!((width / 300.0 - 1.0).abs() < 0.1, "width {width} at {shrunk}");
    }

    #[test]
    fn the_template_is_aligned_fitted_and_boxed() {
        let mut s = style(60.0);
        s.footage_fill = Some(crate::text_style::TextFootageFill::Stencil);
        let t = CaptionLayout::template(
            "Hello",
            &s,
            1080.0,
            1920.0,
            CaptionLayout::WIDTH_FRACTION,
            None,
            &position(CaptionVertical::Top, CaptionHorizontal::Left),
        );
        assert!(t.style.footage_fill.is_none() && t.style.alignment == TextAlignment::Left);
        assert_eq!(t.box_, Some(CaptionLayout::box_(1080.0, 1920.0, CaptionLayout::WIDTH_FRACTION)));
        assert_eq!(t.name, "Caption");
    }
}
