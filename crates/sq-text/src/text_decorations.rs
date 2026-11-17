// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextDecorations.swift
//! Underline, strikethrough and overline: bars drawn across the text line in the glyph fill, in layout space (sequence
//! pixels, y down). One pure function feeds the plain renderer and the per-character animator renderer, so the monitor
//! and the export draw the same bars.

use crate::text_layout::{TextLayout, TextLayoutResult, TextRect};
use crate::text_style::TextStyle;
use std::collections::HashMap;

/// Which decoration a bar is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    /// Under the baseline.
    Underline,
    /// Through the x-height.
    Strikethrough,
    /// Above the caps.
    Overline,
}

/// One bar over the whole width of a line. `rect` spans `TextLine.x ... x + width`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Bar {
    /// Which decoration.
    pub kind: Kind,
    /// The line it belongs to.
    pub line_index: usize,
    /// Which look the line is drawn in (`TextLine.styleIndex`).
    pub style_index: usize,
    /// The bar.
    pub rect: TextRect,
}

/// The font numbers the bars need, in layout px, y up from the baseline.
struct Metrics {
    size: f64,
    underline_position: f64,
    underline_thickness: f64,
    x_height: f64,
    cap_height: f64,
}

/// Namespace of the decoration functions.
pub enum TextDecorations {}

impl TextDecorations {
    /// Which kinds `style` switches on, in drawing order.
    pub fn kinds(style: &TextStyle) -> Vec<Kind> {
        let mut k = Vec::new();
        if style.underline {
            k.push(Kind::Underline);
        }
        if style.strikethrough {
            k.push(Kind::Strikethrough);
        }
        if style.overline {
            k.push(Kind::Overline);
        }
        k
    }

    /// The bars of every non-empty line of `layout`; empty when the style has no decoration.
    pub fn bars(layout: &TextLayoutResult, style: &TextStyle) -> Vec<Bar> {
        let kinds = Self::kinds(style);
        if kinds.is_empty() {
            return Vec::new();
        }
        let mut fonts: HashMap<usize, Metrics> = HashMap::new();
        let mut out = Vec::new();
        for (i, l) in layout.lines.iter().enumerate() {
            if l.text.is_empty() || l.width <= 0.0 {
                continue;
            }
            let m = fonts.entry(l.style_index).or_insert_with(|| Self::metrics(&style.line_style(l.style_index)));
            let size = m.size;
            let thickness = 1.0f64.max(m.underline_thickness).max(size * 0.045);
            let base = l.y + l.baseline;
            for k in &kinds {
                // Font metrics are y up from the baseline; `center` is converted to layout y (down).
                let center = match k {
                    Kind::Underline => base - m.underline_position,
                    Kind::Strikethrough => base - m.x_height.max(size * 0.3) * 0.5,
                    Kind::Overline => base - m.cap_height - thickness,
                };
                out.push(Bar {
                    kind: *k,
                    line_index: i,
                    style_index: l.style_index,
                    rect: TextRect::new(l.x, center - thickness / 2.0, l.width, thickness),
                });
            }
        }
        out
    }

    fn metrics(style: &TextStyle) -> Metrics {
        let font = TextLayout::make_font(style);
        let f = font.face();
        let k = font.scale();
        // A font without OS/2 v2 heights: Core Text's own estimates (x 0.5 em, caps 0.7 em).
        Metrics {
            size: font.size,
            underline_position: f.underline_position as f64 * k,
            underline_thickness: f.underline_thickness as f64 * k,
            x_height: if f.x_height > 0 { f.x_height as f64 * k } else { font.size * 0.5 },
            cap_height: if f.cap_height > 0 { f.cap_height as f64 * k } else { font.size * 0.7 },
        }
    }
}
