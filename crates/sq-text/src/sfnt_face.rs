// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SfntFace.swift

use crate::sfnt_color_glyphs::{ColorGlyphs, GlyphSubstitution};
use crate::sfnt_kerning::PairKerning;
use crate::sfnt_tabular_figures::TabularFigures;
use crate::sfnt_variations::{FontBytes, FontVariations};
use std::collections::HashMap;
use std::path::Path;
use std::sync::OnceLock;

/// Minimal TrueType/OpenType reader for the portable text backend; the tables of a font file it reads.
#[derive(Debug)]
pub struct SfntFace {
    /// Font units per em, at least 16.
    pub units_per_em: i64,
    /// `hhea` ascender.
    pub ascender: i64,
    /// `hhea` descender (negative).
    pub descender: i64,
    /// `hhea` line gap.
    pub line_gap: i64,
    /// OS/2 weight class (400 without OS/2).
    pub weight_class: i64,
    /// `post` underline position (negative below the baseline).
    pub underline_position: i64,
    /// `post` underline thickness.
    pub underline_thickness: i64,
    /// OS/2 x height (0 before OS/2 v2).
    pub x_height: i64,
    /// OS/2 cap height (0 before OS/2 v2).
    pub cap_height: i64,
    /// The file.
    pub bytes: FontBytes,
    /// Variation axes, named instances and deltas (`None` for a static font).
    pub variations: Option<FontVariations>,
    /// GPOS pair kerning (`None` without a `kern` feature).
    pub kerning: Option<PairKerning>,
    /// Apple `trak` tracking (horizontal, normal track; `None` without one): the size-dependent letter spacing Core Text adds to
    /// every glyph of the system font.
    pub tracking: Option<SizeTracking>,
    table_offsets: HashMap<String, i64>,
    number_of_h_metrics: i64,
    hmtx: i64,
    cmap_subtable: Option<i64>,
    cmap_format: i64,
    tabular_digits: OnceLock<Option<TabularFigures>>,
    color_glyphs: OnceLock<Option<ColorGlyphs>>,
    substitution: OnceLock<Option<GlyphSubstitution>>,
}

impl SfntFace {
    /// Reads a font file (or the first font of a collection); `None` when a required table is missing.
    pub fn new(data: Vec<u8>) -> Option<SfntFace> {
        Self::new_face(data, 0)
    }

    /// Reads font number `face` of a collection file (any number for a single font file reads that font).
    pub fn new_face(data: Vec<u8>, face: u32) -> Option<SfntFace> {
        if data.len() <= 12 {
            return None;
        }
        let fb = FontBytes::with_face(data, face);
        let u16 = |o: i64| fb.u16(o);
        let u32 = |o: i64| fb.u32(o);
        let s16 = |o: i64| fb.s16(o);
        let mut tables: HashMap<String, i64> = HashMap::new();
        // A collection (ttc) starts with 'ttcf': its table directory for this face.
        let base = fb.table_base();
        let count = u16(base + 4);
        for i in 0..count {
            let rec = base + 12 + i * 16;
            if rec + 16 > fb.b.len() as i64 {
                return None;
            }
            tables.insert(fb.tag(rec), u32(rec + 8));
        }
        let head = *tables.get("head")?;
        let hhea = *tables.get("hhea")?;
        let hm = *tables.get("hmtx")?;
        let units_per_em = 16.max(u16(head + 18));
        let ascender = s16(hhea + 4);
        let descender = s16(hhea + 6);
        let line_gap = s16(hhea + 8);
        let number_of_h_metrics = 1.max(u16(hhea + 34));
        let weight_class = tables.get("OS/2").map(|&o| u16(o + 4)).unwrap_or(400);
        let underline_position = tables.get("post").map(|&o| s16(o + 8)).unwrap_or(0);
        let underline_thickness = tables.get("post").map(|&o| s16(o + 10)).unwrap_or(0);
        let os2v2 = tables.get("OS/2").copied().filter(|&o| u16(o) >= 2);
        let x_height = os2v2.map(|o| s16(o + 86)).unwrap_or(0);
        let cap_height = os2v2.map(|o| s16(o + 88)).unwrap_or(0);
        // (subtable offset, format); prefer full Unicode (format 12), then BMP (format 4)
        let mut best: Option<(i64, i64)> = None;
        if let Some(&cmap) = tables.get("cmap") {
            for i in 0..u16(cmap + 2) {
                let rec = cmap + 4 + i * 8;
                let platform = u16(rec);
                let encoding = u16(rec + 2);
                let off = cmap + u32(rec + 4);
                let fmt = u16(off);
                let unicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10));
                if !(unicode && (fmt == 4 || fmt == 12)) {
                    continue;
                }
                if best.is_none() || fmt == 12 {
                    best = Some((off, fmt));
                }
            }
        }
        let all = fb.tables();
        let variations = FontVariations::new(&fb, &all);
        let kerning = PairKerning::new(&fb, &all);
        let tracking = all.get("trak").and_then(|&o| SizeTracking::new(&fb, o));
        Some(SfntFace {
            units_per_em,
            ascender,
            descender,
            line_gap,
            weight_class,
            underline_position,
            underline_thickness,
            x_height,
            cap_height,
            bytes: fb,
            variations,
            kerning,
            tracking,
            table_offsets: all,
            number_of_h_metrics,
            hmtx: hm,
            cmap_subtable: best.map(|b| b.0),
            cmap_format: best.map(|b| b.1).unwrap_or(0),
            tabular_digits: OnceLock::new(),
            color_glyphs: OnceLock::new(),
            substitution: OnceLock::new(),
        })
    }

    /// The font says it is italic or oblique (`head` macStyle bit 1, or `OS/2` fsSelection bit 0).
    pub fn is_italic(&self) -> bool {
        let mac = self.table_offsets.get("head").is_some_and(|&h| self.bytes.u16(h + 44) & 2 != 0);
        mac || self.table_offsets.get("OS/2").is_some_and(|&o| self.bytes.u16(o + 62) & 1 != 0)
    }

    /// Reads the file at `path`; `None` when it cannot be read or parsed.
    pub fn from_path(path: &Path) -> Option<SfntFace> {
        let (file, face) = crate::system_fonts::split_face(path);
        Self::new_face(std::fs::read(file).ok()?, face)
    }

    /// Tabular-figure glyphs of the digits (`tnum`; `None` without them), read on first use.
    pub fn tabular_digits(&self) -> Option<&TabularFigures> {
        self.tabular_digits
            .get_or_init(|| {
                let digits: Vec<i64> =
                    (0x30u32..=0x39).map(|c| self.glyph_for(char::from_u32(c).unwrap_or('0'))).collect();
                TabularFigures::new(&self.bytes, &self.table_offsets, &digits)
            })
            .as_ref()
    }

    /// COLR/CPAL color layers (`None` without them), read on first use.
    pub fn color_glyphs(&self) -> Option<&ColorGlyphs> {
        self.color_glyphs.get_or_init(|| ColorGlyphs::new(&self.bytes, &self.table_offsets)).as_ref()
    }

    /// The emoji-sequence GSUB features (`None` without them), read on first use.
    pub fn substitution(&self) -> Option<&GlyphSubstitution> {
        self.substitution.get_or_init(|| GlyphSubstitution::new(&self.bytes, &self.table_offsets)).as_ref()
    }

    /// Glyph index of a character (0 = missing).
    pub fn glyph_for(&self, scalar: char) -> i64 {
        let Some(sub) = self.cmap_subtable else { return 0 };
        let by = &self.bytes;
        let c = i64::from(u32::from(scalar));
        if self.cmap_format == 12 {
            let groups = by.u32(sub + 12);
            let mut lo = 0;
            let mut hi = groups - 1;
            while lo <= hi {
                let mid = (lo + hi) / 2;
                let g = sub + 16 + mid * 12;
                let start = by.u32(g);
                let end = by.u32(g + 4);
                if c < start {
                    hi = mid - 1;
                } else if c > end {
                    lo = mid + 1;
                } else {
                    return by.u32(g + 8) + (c - start);
                }
            }
            return 0;
        }
        if c > 0xFFFF {
            return 0;
        }
        let seg_x2 = by.u16(sub + 6);
        let ends = sub + 14;
        let starts = ends + seg_x2 + 2;
        let deltas = starts + seg_x2;
        let ranges = deltas + seg_x2;
        for i in 0..(seg_x2 / 2) {
            if c > by.u16(ends + i * 2) {
                continue;
            }
            let start = by.u16(starts + i * 2);
            if c < start {
                return 0;
            }
            let ro = by.u16(ranges + i * 2);
            let delta = by.u16(deltas + i * 2);
            if ro == 0 {
                return (c + delta) & 0xFFFF;
            }
            let g = by.u16(ranges + i * 2 + ro + (c - start) * 2);
            return if g == 0 { 0 } else { (g + delta) & 0xFFFF };
        }
        0
    }

    /// Advance width in font units.
    pub fn advance(&self, glyph: i64) -> i64 {
        let i = glyph.min(self.number_of_h_metrics - 1);
        self.bytes.u16(self.hmtx + i * 4)
    }

    /// Advance width in font units at normalized variation `coords` (empty = default instance).
    pub fn advance_at(&self, glyph: i64, coords: &[f64]) -> f64 {
        let base = self.advance(glyph) as f64;
        match &self.variations {
            Some(v) if coords.iter().any(|&c| c != 0.0) => base + v.advance_delta(glyph, coords).unwrap_or(0.0),
            _ => base,
        }
    }

    /// GPOS kerning between two glyphs in font units.
    pub fn kern(&self, a: i64, b: i64, coords: &[f64]) -> f64 {
        self.kerning.as_ref().map(|k| k.kern(a, b, coords)).unwrap_or(0.0)
    }
}

/// The Apple `trak` table: tracking in font units per point size, for the normal track (0.0), linear between the sizes and
/// clamped outside them. Core Text applies it to every glyph of the system font (SF text gets looser below 12 pt and
/// tighter above it).
#[derive(Clone, Debug)]
pub struct SizeTracking {
    sizes: Vec<f64>,
    units: Vec<f64>,
}

impl SizeTracking {
    /// Reads the horizontal normal track at `o`.
    pub fn new(b: &FontBytes, o: i64) -> Option<SizeTracking> {
        let horiz = o + b.u16(o + 6);
        if b.u16(o + 6) == 0 {
            return None;
        }
        let tracks = b.u16(horiz);
        let count = b.u16(horiz + 2);
        let size_table = o + b.u32(horiz + 4);
        if !(count > 0 && tracks > 0 && count < 64) {
            return None;
        }
        let s: Vec<f64> = (0..count).map(|i| b.fixed(size_table + 4 * i)).collect();
        for t in 0..tracks {
            if b.fixed(horiz + 8 + 8 * t) == 0.0 {
                let values = o + b.u16(horiz + 8 + 8 * t + 6);
                let units = (0..count).map(|i| b.s16(values + 2 * i) as f64).collect();
                return Some(SizeTracking { sizes: s, units });
            }
        }
        None
    }

    /// Font units of tracking at `point_size`.
    pub fn at(&self, p: f64) -> f64 {
        if p <= self.sizes[0] {
            return self.units[0];
        }
        for i in 1..self.sizes.len() {
            if p <= self.sizes[i] {
                let t = (p - self.sizes[i - 1]) / (self.sizes[i] - self.sizes[i - 1]);
                return self.units[i - 1] + (self.units[i] - self.units[i - 1]) * t;
            }
        }
        self.units[self.units.len() - 1]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts::test_fonts_root;

    fn inter() -> Option<SfntFace> {
        SfntFace::from_path(&test_fonts_root().join("Inter-VariableFont_opsz,wght.ttf"))
    }

    #[test]
    fn reads_inter_metrics_and_cmap() {
        let f = inter();
        assert!(f.is_some());
        let Some(f) = f else { return };
        assert_eq!(f.units_per_em, 2048);
        assert!(f.ascender > 0 && f.descender < 0);
        let h = f.glyph_for('H');
        assert!(h != 0);
        assert!(f.advance(h) > 0);
        assert_eq!(f.glyph_for('\u{10FFFF}'), 0);
        assert!(f.variations.is_some());
    }

    #[test]
    fn rejects_short_and_table_less_data() {
        assert!(SfntFace::new(vec![0; 8]).is_none());
        assert!(SfntFace::new(vec![0; 64]).is_none());
    }

    #[test]
    fn tracking_interpolates_and_clamps() {
        let t = SizeTracking { sizes: vec![10.0, 20.0], units: vec![8.0, -4.0] };
        assert_eq!(t.at(5.0), 8.0);
        assert_eq!(t.at(15.0), 2.0);
        assert_eq!(t.at(30.0), -4.0);
    }
}
