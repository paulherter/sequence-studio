// Swift: TimelineSkin.swift
//! The Mac timeline tokens that `DrawTheme` does not carry yet, with the Mac values. One place, so a token added to
//! `DrawTheme` replaces a line here.

use sq_core_model::MarkerColor;
use sq_draw::{Canvas, Color, DrawTheme};
use sq_uikit::appearance_palette::PaletteColor;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{alpha, hex, timeline};

/// Timeline colors derived from the theme.
#[derive(Clone, Copy)]
pub struct TimelineSkin<'a> {
    /// The theme the colors come from.
    pub theme: &'a DrawTheme,
}

/// Head size in points (`Theme.PlayheadSkin`).
const HEAD_SIZE: f64 = timeline::HEAD_SIZE;

impl TimelineSkin<'_> {
    /// Clip bodies sit this far inside the lane top and bottom. Drawing only; hit tests use the lane.
    pub const CLIP_INSET: f64 = 2.0;
    /// Width of a selection outline.
    pub const SELECTION_OUTLINE_WIDTH: f64 = timeline::SELECTION_OUTLINE_WIDTH;

    /// The accent at its tint alpha.
    pub fn accent_tint(&self) -> Color {
        self.theme.accent_tint()
    }
    /// Faint ink fill.
    pub fn fill2(&self) -> Color {
        self.theme.ink_fill(alpha::FILL2)
    }
    /// Shade over trim handles and transition boxes.
    pub fn clip_shade(&self) -> Color {
        Color::BLACK.with_alpha(alpha::CLIP_SHADE as f32)
    }
    /// The snap line: the accent (transient feedback, draft 03-timeline).
    pub fn snap_line(&self) -> Color {
        self.theme.accent()
    }
    /// A selected clip's outline.
    pub fn selection_outline(&self) -> Color {
        Color::WHITE
    }
    /// A clip's edge line.
    pub fn clip_edge(&self) -> Color {
        Color::WHITE.with_alpha(alpha::CLIP_EDGE as f32)
    }
    /// The rubber bands' fill.
    pub fn badge_fill(&self) -> Color {
        Color::WHITE.with_alpha(alpha::BADGE_FILL as f32)
    }
    /// The rubber bands' edge.
    pub fn badge_edge(&self) -> Color {
        Color::BLACK.with_alpha(alpha::BADGE_EDGE as f32)
    }
    /// The rule between thumbnail tiles.
    pub fn thumb_rule(&self) -> Color {
        Color::BLACK.with_alpha(alpha::THUMB_RULE as f32)
    }
    /// The thumbnail well.
    pub fn thumb_well(&self) -> Color {
        Color::hex(hex::THUMB_WELL, 1.0)
    }
    /// The ruler's cache strip.
    pub fn cache_strip(&self) -> Color {
        self.theme.accent().with_alpha(alpha::CACHE_STRIP as f32)
    }
    /// Hatch of a held transition.
    pub fn transition_issue(&self) -> Color {
        self.red().with_alpha(alpha::TRANSITION_ISSUE as f32)
    }
    /// A HUD label's fill.
    pub fn hud_fill(&self) -> Color {
        Color::BLACK.with_alpha(alpha::VIEWER_HUD as f32)
    }
    /// A clip whose media is missing.
    pub fn offline_clip(&self) -> Color {
        self.theme.token(sq_uikit::redesign_tokens::color::RAISED)
    }
    /// The text on an offline clip.
    pub fn offline_text(&self) -> Color {
        self.theme.label2()
    }
    /// Green.
    pub fn green(&self) -> Color {
        self.theme.green()
    }
    /// Warning amber.
    pub fn warning(&self) -> Color {
        Self::color(self.theme.palette.warning)
    }
    /// Red.
    pub fn red(&self) -> Color {
        Self::color(self.theme.palette.red)
    }
    /// The playhead head's outline (light theme only).
    pub fn head_outline(&self) -> Color {
        if self.theme.palette.is_dark() {
            Color::CLEAR
        } else {
            self.theme.playhead().with_alpha(alpha::HEAD_OUTLINE_LIGHT as f32)
        }
    }

    /// A palette color as a draw color.
    pub fn color(c: PaletteColor) -> Color {
        Color::new((c.r / 255.0) as f32, (c.g / 255.0) as f32, (c.b / 255.0) as f32, c.a as f32)
    }

    /// `Theme.Palette.marker`.
    pub fn marker(&self, c: MarkerColor) -> Color {
        DrawTheme::marker(c)
    }

    /// Clip name color on a label fill: white unless white falls under WCAG 4.5:1 on it.
    pub fn text_on(fill: Color) -> Color {
        fn lin(v: f32) -> f32 {
            if v <= 0.03928 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
        }
        let lum = 0.2126 * lin(fill.r) + 0.7152 * lin(fill.g) + 0.0722 * lin(fill.b);
        if 1.05 / (lum + 0.05) < 4.5 { Color::BLACK } else { Color::WHITE }
    }

    /// The head outline in head-local points (0...12), bezier corners flattened to 6 steps each (pip-head.svg in its
    /// 780 x 776 box, flattened once per call).
    pub fn head_outline_points() -> Vec<CGPoint> {
        let p = |x: f64, y: f64| CGPoint { x, y };
        let mut out: Vec<CGPoint> = Vec::new();
        let mut cur = p(250.96, 152.12);
        out.push(cur);
        let line = |to: CGPoint, out: &mut Vec<CGPoint>, cur: &mut CGPoint| {
            out.push(to);
            *cur = to;
        };
        let curve = |to: CGPoint, c1: CGPoint, c2: CGPoint, out: &mut Vec<CGPoint>, cur: &mut CGPoint| {
            let a = *cur;
            for i in 1..=6 {
                let t = i as f64 / 6.0;
                let u = 1.0 - t;
                let x = u * u * u * a.x + 3.0 * u * u * t * c1.x + 3.0 * u * t * t * c2.x + t * t * t * to.x;
                let y = u * u * u * a.y + 3.0 * u * u * t * c1.y + 3.0 * u * t * t * c2.y + t * t * t * to.y;
                out.push(p(x, y));
            }
            *cur = to;
        };
        line(p(773.04, 152.12), &mut out, &mut cur);
        curve(p(902.0, 281.08), p(855.62, 152.12), p(902.0, 198.5), &mut out, &mut cur);
        line(p(902.0, 620.12), &mut out, &mut cur);
        curve(p(824.0, 738.68), p(902.0, 669.94), p(865.18, 707.58), &mut out, &mut cur);
        line(p(609.55, 900.92), &mut out, &mut cur);
        curve(p(414.45, 900.92), p(561.4, 937.32), p(462.6, 937.32), &mut out, &mut cur);
        line(p(200.0, 738.68), &mut out, &mut cur);
        curve(p(122.0, 620.12), p(158.82, 707.58), p(122.0, 669.94), &mut out, &mut cur);
        line(p(122.0, 281.08), &mut out, &mut cur);
        curve(p(250.96, 152.12), p(122.0, 198.5), p(168.38, 152.12), &mut out, &mut cur);
        out.pop(); // closes on the first point
        out.iter().map(|q| p((q.x - 122.0) * HEAD_SIZE / 780.0, (q.y - 152.0) * HEAD_SIZE / 776.0)).collect()
    }

    /// `Theme.PlayheadSkin.drawHead`: the head over the line at `center_x`, top at `top`.
    /// The head is flat playhead color, as in Swift (the artifact's `.phead` is flat).
    pub fn draw_head(&self, cv: &mut Canvas, center_x: f64, top: f64) {
        // Shared with the keyframe lane: one shape and token (`DrawTheme::playhead_head`).
        self.theme.playhead_head(center_x, top).draw(cv);
    }

    /// `Theme.PlayheadSkin.lineFrame`: the line centered on `x`.
    pub fn line_frame(center_x: f64, y: f64, height: f64) -> CGRect {
        CGRect::new(center_x.round() - 0.5, y, 1.0, height)
    }
}

/// `Theme.Palette.marker` for panels outside the timeline (the Marker List's dots).
pub fn marker_color(c: MarkerColor, theme: &DrawTheme) -> Color {
    TimelineSkin { theme }.marker(c)
}
