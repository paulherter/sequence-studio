// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: CaptionPill.swift
//! The pill look (`CaptionEmphasis.pill` in SQTranscribe): a fully rounded filled box behind the caption text. Monitor and
//! burn-in both draw `TextStyle.background` from the same layout, so one style gives one picture; this is the single place
//! that decides the pill's color, padding and rounding. A short-video caption is one word, so the box around the caption
//! is the box around the active word.

use crate::text_layout::{TextLayoutResult, TextRect};
use crate::text_style::{BoxPadding, RGBAColor, TextBackground, TextStyle};

/// Namespace of the pill functions.
pub enum CaptionPill {}

impl CaptionPill {
    /// Style id of the built-in pill look in `CaptionPresetLibrary`.
    pub const STYLE_ID: &'static str = "pill";
    /// The pill color.
    pub const COLOR: RGBAColor = RGBAColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 0.82 };
    /// Horizontal padding in em (fraction of the font size) so the pill scales with the text.
    pub const HORIZONTAL_EM: f64 = 0.40;
    /// Vertical padding in em.
    pub const VERTICAL_EM: f64 = 0.16;

    /// The pill background for `style`: `COLOR` unless given or the style already has a background color, padding from
    /// the font size, corner radius large enough that the renderer clamps it to half the pill height (round ends).
    pub fn background(style: &TextStyle, color_override: Option<RGBAColor>) -> TextBackground {
        TextBackground::new(
            color_override.or_else(|| style.background.map(|b| b.color)).unwrap_or(Self::COLOR),
            BoxPadding::new((style.size * Self::HORIZONTAL_EM).round(), (style.size * Self::VERTICAL_EM).round()),
            10_000.0,
        )
    }

    /// `style` with the pill background.
    pub fn apply(style: &TextStyle, color_override: Option<RGBAColor>) -> TextStyle {
        let mut s = style.clone();
        s.background = Some(Self::background(style, color_override));
        s
    }

    /// The pill rectangle of a laid-out caption (layout space, origin top-left of the text block); nil for empty text.
    pub fn rect(layout: &TextLayoutResult) -> Option<TextRect> {
        layout.background_rect
    }
}
