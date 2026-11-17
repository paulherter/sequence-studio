// Swift: InspectorColorSlider.swift
//! The Color page slider (the Mac `ColorSlider`) and its ramp tracks.

use super::inspector_controls::{InspectorDraw, InspectorTokens, faded};
use crate::canvas::Canvas;
use crate::draw_list::Color;
use crate::theme::DrawTheme;
use sq_uikit::controls_grid::CGRect;

/// The track behind a Color page slider (the Mac `ColorParam.Track`): plain, or a color ramp for Temperature (blue to
/// orange), Tint (green to magenta) and Saturation / Vibrance (gray to warm).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InspectorColorRamp {
    /// A plain track.
    Plain,
    /// Blue to orange.
    Temperature,
    /// Green to magenta.
    Tint,
    /// Gray to warm.
    Saturation,
}

impl InspectorColorRamp {
    /// The ramp's stops (location 0...1, color): `Theme.Palette.whiteBalanceTemperature`, `whiteBalanceTint`,
    /// `saturationRamp`; `None` for the plain track.
    pub fn stops(self) -> Option<Vec<(f32, Color)>> {
        let c = |h| Color::hex(h, 1.0);
        let gray = c(0x9AA4B0);
        match self {
            InspectorColorRamp::Plain => None,
            InspectorColorRamp::Temperature => Some(vec![(0.0, c(0x4D85F2)), (0.5, gray), (1.0, c(0xF59433))]),
            InspectorColorRamp::Tint => Some(vec![(0.0, c(0x30D158)), (0.5, gray), (1.0, c(0xD65CD6))]),
            InspectorColorRamp::Saturation => Some(vec![(0.0, c(0x6E6E75)), (0.55, c(0xA08BD0)), (1.0, c(0xF2A65A))]),
        }
    }

    /// The ramp's color at `t` (0...1), linear between the stops.
    pub fn color(self, t: f32) -> Option<Color> {
        let s = self.stops()?;
        let (first, last) = (s.first()?, s.last()?);
        if t <= first.0 {
            return Some(first.1);
        }
        for w in s.windows(2) {
            let (a, b) = (w[0], w[1]);
            if t <= b.0 {
                let k = (t - a.0) / (b.0 - a.0).max(1e-6);
                return Some(Color::new(
                    a.1.r + (b.1.r - a.1.r) * k,
                    a.1.g + (b.1.g - a.1.g) * k,
                    a.1.b + (b.1.b - a.1.b) * k,
                    a.1.a + (b.1.a - a.1.a) * k,
                ));
            }
        }
        Some(last.1)
    }
}

impl InspectorDraw {
    /// Version 9 `.sl` tracks (the Mac `ColorSlider`): a 3 pt track, 4 pt for a color ramp (the frame's `Track`).
    pub const COLOR_TRACK: f64 = 3.0;
    /// Track height of a ramp.
    pub const COLOR_RAMP_TRACK: f64 = 4.0;
    /// The 4 x 14 bar thumb.
    pub const COLOR_THUMB: (f64, f64) = (4.0, 14.0);
    /// The Mac knob's box (`ColorSlider.knob`): the thumb's center travels 5 pt in from each end of the track.
    pub const COLOR_KNOB: f64 = 10.0;
    /// Pieces a ramp is drawn in (enough for three or four stops at any width).
    const RAMP_PIECES: usize = 48;

    /// A Color page slider (the Mac `ColorSlider.draw`): the plain track with its accent fill from the start, or from the
    /// neutral's center tick for a signed value (`neutral` = the neutral's fraction, `None` = fill from the start); a ramp
    /// track shows no fill but a center tick. The thumb is the 4 x 14 bar.
    pub fn color_slider(
        c: &mut Canvas,
        fraction: f64,
        neutral: Option<f64>,
        ramp: InspectorColorRamp,
        rect: CGRect,
        enabled: bool,
        t: &DrawTheme,
    ) {
        let a = if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        let inset = Self::COLOR_KNOB / 2.0;
        let x0 = rect.min_x() + inset;
        let x1 = (rect.max_x() - inset).max(x0);
        let x = |f: f64| x0 + (x1 - x0) * f.clamp(0.0, 1.0);
        let y = rect.mid_y().round();
        if ramp.stops().is_some() {
            let th = Self::COLOR_RAMP_TRACK;
            let line = CGRect::new(rect.min_x(), y - th / 2.0, rect.width, th);
            Self::fill_horizontal_ramp(c, ramp, line, a);
            // The frame's inner shadow: a dark 1 pt rim around the ramp.
            c.stroke_rounded(line.inset_by(0.5, 0.5), th / 2.0 - 0.5, 1.0, Color::BLACK.with_alpha(0.5 * a));
            c.fill(CGRect::new((rect.mid_x() - 0.5).round(), y - 4.5, 1.0, 9.0), t.label().with_alpha(0.5 * a));
        } else {
            let th = Self::COLOR_TRACK;
            let line = CGRect::new(rect.min_x(), y - th / 2.0, rect.width, th);
            c.fill_rounded(line, th / 2.0, faded(t.fill(), a));
            if enabled {
                let k = x(fraction);
                let from = neutral.map(x).unwrap_or(rect.min_x());
                let span = CGRect::new(k.min(from), line.min_y(), (k - from).abs(), th);
                if span.width > 0.0 {
                    c.fill_rounded(span, th / 2.0, t.accent());
                }
            }
        }
        let (tw, th) = Self::COLOR_THUMB;
        let thumb = CGRect::new((x(fraction) - tw / 2.0).round(), y - th / 2.0, tw, th);
        c.shadow(thumb, tw / 2.0, 1.5, 0.5, Color::BLACK.with_alpha(0.6 * a), false);
        c.fill_rounded(thumb, tw / 2.0, if enabled { Color::hex(0xF2F2F2, 1.0) } else { faded(t.label3(), a) });
    }

    /// Fraction of a Color page slider for a pointer at `x` (inverse of `color_slider`).
    pub fn color_slider_fraction(x: f64, rect: CGRect) -> f64 {
        let x0 = rect.min_x() + Self::COLOR_KNOB / 2.0;
        let x1 = rect.max_x() - Self::COLOR_KNOB / 2.0;
        if x1 <= x0 {
            return 0.0;
        }
        ((x - x0) / (x1 - x0)).clamp(0.0, 1.0)
    }

    /// The ramp left to right in `r` with round ends: `RAMP_PIECES` flat pieces, each the ramp's color at its center.
    pub(crate) fn fill_horizontal_ramp(c: &mut Canvas, ramp: InspectorColorRamp, r: CGRect, alpha: f32) {
        let (Some(first), Some(last)) = (ramp.color(0.0), ramp.color(1.0)) else { return };
        if r.width <= 0.0 {
            return;
        }
        let cap = (r.height / 2.0).min(r.width / 2.0);
        c.fill_ellipse(CGRect::new(r.min_x(), r.min_y(), cap * 2.0, r.height), faded(first, alpha));
        c.fill_ellipse(CGRect::new(r.max_x() - cap * 2.0, r.min_y(), cap * 2.0, r.height), faded(last, alpha));
        let body = r.inset_by(cap, 0.0);
        let n = Self::RAMP_PIECES;
        let w = body.width / n as f64;
        for i in 0..n {
            let t = (i as f32 + 0.5) / n as f32;
            let Some(col) = ramp.color(t) else { continue };
            // An opaque piece reaches into the next by a hair so no seam shows (translucent ones would darken there).
            let overlap = if i == n - 1 || alpha < 1.0 { 0.0 } else { 0.5 };
            c.fill(CGRect::new(body.min_x() + i as f64 * w, r.min_y(), w + overlap, r.height), faded(col, alpha));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ramp_colors_run_through_the_stops() {
        assert!(InspectorColorRamp::Plain.color(0.5).is_none());
        let t = InspectorColorRamp::Temperature;
        assert_eq!(t.color(0.0), Some(Color::hex(0x4D85F2, 1.0)));
        assert!(t.color(1.0).is_some_and(|c| (c.b - Color::hex(0xF59433, 1.0).b).abs() < 1e-6));
        assert_eq!(t.color(0.5), Some(Color::hex(0x9AA4B0, 1.0)));
    }

    #[test]
    fn a_ramp_track_is_4_pt_tall_like_the_frame() {
        assert_eq!(InspectorDraw::COLOR_RAMP_TRACK, 4.0);
        assert_eq!(InspectorColorRamp::Saturation.color(0.0), Some(Color::hex(0x6E6E75, 1.0)));
    }

    #[test]
    fn color_slider_fraction_inverts_the_thumb_position() {
        let r = CGRect::new(0.0, 0.0, 110.0, 20.0);
        assert_eq!(InspectorDraw::color_slider_fraction(5.0, r), 0.0);
        assert_eq!(InspectorDraw::color_slider_fraction(55.0, r), 0.5);
        assert_eq!(InspectorDraw::color_slider_fraction(300.0, r), 1.0);
    }

    #[test]
    fn a_ramp_slider_draws_a_ramp_and_a_plain_one_an_accent_span() {
        let t = DrawTheme::default();
        let mut c = Canvas::with_size(110.0, 20.0, None, 1.0);
        let r = CGRect::new(0.0, 0.0, 110.0, 20.0);
        InspectorDraw::color_slider(&mut c, 0.5, None, InspectorColorRamp::Tint, r, true, &t);
        let ramp_quads = c.list.quads().len();
        let mut p = Canvas::with_size(110.0, 20.0, None, 1.0);
        InspectorDraw::color_slider(&mut p, 0.5, None, InspectorColorRamp::Plain, r, true, &t);
        assert!(ramp_quads > 48 && p.list.quads().len() < ramp_quads / 2);
    }
}
