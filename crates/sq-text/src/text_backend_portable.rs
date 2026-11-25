// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextBackend+Portable.swift

//! Portable text backend (Windows, Linux, and here the Mac too): measuring and Latin-grade layout from the font files
//! themselves, no platform text engine. A small TrueType/OpenType reader supplies advance widths and vertical metrics.
//! Variable-font instances and GPOS pair kerning as the raster draws them (`portable_font_match`, `sfnt_kerning`).
//! known limit: no ligatures, bidi or complex scripts, no font fallback. Upgrade path: HarfBuzz for shaping.
//! The Swift registration helpers (`registerFontFile`, `isInstalled`) have no counterpart: fonts are read from files on demand.

use crate::portable_fallback::PortableFallback;
use crate::portable_font_match::PortableFontChoice;
use crate::sfnt_face::SfntFace;
use crate::text_backend::{LineTypesetting, TextFontMetrics, TextLineMetrics};
use crate::text_layout::TextLayout;

/// A font face at a size, read straight from a .ttf/.otf file, at one point of its variation space.
#[derive(Clone, Debug)]
pub struct PortableFont {
    /// The chosen face and its variation coordinates.
    pub choice: PortableFontChoice,
    /// Point size.
    pub size: f64,
}

/// The platform's font type.
pub type PlatformFont = PortableFont;

impl PortableFont {
    /// A face at a size.
    pub fn new(choice: PortableFontChoice, size: f64) -> Self {
        PortableFont { choice, size }
    }

    /// The font file's tables.
    pub fn face(&self) -> &SfntFace {
        &self.choice.font.face
    }

    /// Normalized variation coordinates.
    pub fn coords(&self) -> &[f64] {
        &self.choice.coords
    }

    /// Points per font unit.
    pub fn scale(&self) -> f64 {
        self.size / self.face().units_per_em as f64
    }

    /// Vertical metrics in points.
    pub fn metrics(&self) -> TextFontMetrics {
        let scale = self.scale();
        let f = self.face();
        TextFontMetrics {
            ascent: f.ascender as f64 * scale,
            descent: -(f.descender as f64) * scale,
            leading: f.line_gap as f64 * scale,
        }
    }

    /// Glyph index of a character.
    pub fn glyph(&self, scalar: char) -> i64 {
        self.face().glyph_for(scalar)
    }

    /// Advance of a glyph in points.
    pub fn advance(&self, g: i64) -> f64 {
        self.face().advance_at(g, self.coords()) * self.scale()
    }

    /// Kerning between two glyphs in points.
    pub fn kern(&self, a: i64, b: i64) -> f64 {
        self.face().kern(a, b, self.coords()) * self.scale()
    }
}

/// Line widths from per-scalar advances, pair kerning and tracking after every glyph (as the Core Text kern attribute does).
struct PortableLines {
    /// `prefix[i]` = width of the first `i` UTF-16 units.
    prefix: Vec<f64>,
    /// Per UTF-16 unit.
    whitespace: Vec<bool>,
    metrics: TextFontMetrics,
}

impl PortableLines {
    fn new(para: &str, font: &PortableFont, tracking: f64) -> Self {
        let mut p = vec![0.0];
        let mut ws: Vec<bool> = Vec::new();
        let mut total = 0.0;
        let mut previous: Option<i64> = None;
        // Decode the scalars first so the fallback plan sees whole sequences.
        let scalars: Vec<char> = para.chars().collect();
        let plan = PortableFallback::plan_default(&scalars, &font.choice.font);
        for (idx, scalar) in scalars.iter().enumerate() {
            let n = scalar.len_utf16();
            let (pick, skip) = &plan[idx];
            if !skip {
                if let Some(e) = &pick.emoji {
                    total += e.advance(pick.glyph) as f64 * font.size / e.units_per_em as f64 + tracking;
                    previous = None;
                } else if let Some(fb) = &pick.font {
                    let adv = pick.advance.unwrap_or_else(|| fb.advance(pick.glyph));
                    total += adv as f64 * font.size / fb.units_per_em as f64 + tracking;
                    previous = None;
                } else {
                    let g = pick.glyph;
                    if let Some(prev) = previous {
                        total += font.kern(prev, g);
                    }
                    total += font.advance(g) + tracking;
                    previous = Some(g);
                }
            }
            let is_space = scalar.is_whitespace();
            for k in 0..n {
                let last = p[p.len() - 1];
                p.push(if k == n - 1 { total } else { last });
                ws.push(is_space);
            }
        }
        PortableLines { prefix: p, whitespace: ws, metrics: font.metrics() }
    }
}

impl LineTypesetting for PortableLines {
    fn line(&self, location: i64, length: i64) -> TextLineMetrics {
        let last = self.prefix.len() as i64 - 1;
        let a = 0.max(location).min(last);
        let b = a.max(location + length).min(last);
        let mut t = b;
        while t > a && self.whitespace[(t - 1) as usize] {
            t -= 1;
        }
        let (a, b, t) = (a as usize, b as usize, t as usize);
        TextLineMetrics {
            width: self.prefix[b] - self.prefix[a],
            trailing_whitespace: self.prefix[b] - self.prefix[t],
            ascent: self.metrics.ascent,
            descent: self.metrics.descent,
            leading: self.metrics.leading,
        }
    }
}

impl TextLayout {
    /// Vertical metrics of a font.
    pub(crate) fn font_metrics(font: &PlatformFont) -> TextFontMetrics {
        font.metrics()
    }

    /// Typesets a paragraph (the direction is not used by the portable backend).
    pub(crate) fn typesetter(
        para: &str,
        font: &PlatformFont,
        tracking: f64,
        _right_to_left: Option<bool>,
    ) -> Box<dyn LineTypesetting> {
        Box::new(PortableLines::new(para, font, tracking))
    }
}
