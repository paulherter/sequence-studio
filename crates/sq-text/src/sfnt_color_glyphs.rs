// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SfntColorGlyphs.swift
//! COLR color glyphs and GSUB emoji substitution for the portable text backend.

use crate::sfnt_variations::FontBytes;
use crate::text_style::RGBAColor;
use std::collections::{BTreeSet, HashMap};

/// One layer of a color glyph: an outline glyph and its palette color.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Layer {
    /// The outline glyph.
    pub glyph: i64,
    /// `None` = the text color (palette index 0xFFFF).
    pub color: Option<RGBAColor>,
}

/// COLR version 0 color glyphs with their CPAL palette (the emoji layers of Segoe UI Emoji): a base glyph is drawn as a
/// stack of outline glyphs, each in one palette color. COLRv1 paint graphs are not read (the font keeps v0 records for
/// every glyph).
/// known limit: palette 0 only, no COLRv1 gradients or transforms; upgrade when a font ships v1 only.
#[derive(Clone, Debug)]
pub struct ColorGlyphs {
    bytes: FontBytes,
    base_records: i64,
    base_count: i64,
    layer_records: i64,
    layer_count: i64,
    colors: Vec<RGBAColor>,
}

impl ColorGlyphs {
    /// Reads `COLR` and `CPAL`; nil when either is missing or empty.
    pub fn new(b: &FontBytes, tables: &HashMap<String, i64>) -> Option<ColorGlyphs> {
        let colr = *tables.get("COLR")?;
        let cpal = *tables.get("CPAL")?;
        let base_count = b.u16(colr + 2);
        let base_records = colr + b.u32(colr + 4);
        let layer_records = colr + b.u32(colr + 8);
        let layer_count = b.u16(colr + 12);
        if base_count <= 0 {
            return None;
        }
        let entries = b.u16(cpal + 2);
        let palettes = b.u16(cpal + 4);
        let array = cpal + b.u32(cpal + 8);
        if palettes <= 0 {
            return None;
        }
        let first = b.u16(cpal + 12);
        let colors = (0..entries)
            .map(|i| {
                let o = array + 4 * (first + i);
                RGBAColor::new(
                    b.u8(o + 2) as f64 / 255.0,
                    b.u8(o + 1) as f64 / 255.0,
                    b.u8(o) as f64 / 255.0,
                    b.u8(o + 3) as f64 / 255.0,
                )
            })
            .collect();
        Some(ColorGlyphs { bytes: b.clone(), base_records, base_count, layer_records, layer_count, colors })
    }

    /// The layers of `glyph`, bottom first; nil when it is a plain outline glyph.
    pub fn layers(&self, glyph: i64) -> Option<Vec<Layer>> {
        let bytes = &self.bytes;
        let (mut lo, mut hi) = (0, self.base_count - 1);
        while lo <= hi {
            let mid = (lo + hi) / 2;
            let r = self.base_records + mid * 6;
            let id = bytes.u16(r);
            if glyph < id {
                hi = mid - 1;
            } else if glyph > id {
                lo = mid + 1;
            } else {
                let first = bytes.u16(r + 2);
                let n = bytes.u16(r + 4);
                if first + n > self.layer_count {
                    return None;
                }
                return Some(
                    (0..n)
                        .map(|i| {
                            let l = self.layer_records + (first + i) * 4;
                            let p = bytes.u16(l + 2);
                            let color = if p == 0xFFFF {
                                None
                            } else {
                                Some(
                                    usize::try_from(p)
                                        .ok()
                                        .and_then(|k| self.colors.get(k))
                                        .copied()
                                        .unwrap_or(RGBAColor::BLACK),
                                )
                            };
                            Layer { glyph: bytes.u16(l), color }
                        })
                        .collect(),
                );
            }
        }
        None
    }
}

/// The glyph substitutions of the GSUB features an emoji sequence needs (`ccmp`, `liga`, `rlig`, `calt`): single (1),
/// ligature (4), chaining context by coverage (6.3) and extension (7) lookups. This is how Segoe UI Emoji turns a ZWJ
/// family, a skin tone or a pair of regional indicators into one glyph.
/// shortcut: no lookup flags, no script/language selection (every listed feature applies), no contextual formats 1 and 2.
#[derive(Clone, Debug)]
pub struct GlyphSubstitution {
    bytes: FontBytes,
    lookup_list: i64,
    /// Lookup indexes of the features, ascending.
    order: Vec<i64>,
}

impl GlyphSubstitution {
    /// Reads the `GSUB` features; nil without the table or any listed feature.
    pub fn new(b: &FontBytes, tables: &HashMap<String, i64>) -> Option<GlyphSubstitution> {
        let gsub = *tables.get("GSUB")?;
        let features = gsub + b.u16(gsub + 6);
        let lookup_list = gsub + b.u16(gsub + 8);
        let mut set = BTreeSet::new();
        for i in 0..b.u16(features) {
            let rec = features + 2 + i * 6;
            if !["ccmp", "liga", "rlig", "calt"].contains(&b.tag(rec).as_str()) {
                continue;
            }
            let f = features + b.u16(rec + 4);
            for k in 0..b.u16(f + 2) {
                set.insert(b.u16(f + 4 + 2 * k));
            }
        }
        if set.is_empty() {
            return None;
        }
        Some(GlyphSubstitution { bytes: b.clone(), lookup_list, order: set.into_iter().collect() })
    }

    /// Runs every lookup over `glyphs` in order.
    pub fn apply(&self, glyphs: &[i64]) -> Vec<i64> {
        let mut g = glyphs.to_vec();
        for &l in &self.order {
            let mut i = 0;
            while i < g.len() {
                i += self.step(l, &mut g, i).max(1);
            }
        }
        g
    }

    /// Applies one lookup at `pos`; returns how far to move on (0 = nothing matched, stay and move one), and updates `g`.
    fn step(&self, index: i64, g: &mut Vec<i64>, pos: usize) -> usize {
        let bytes = &self.bytes;
        let l = self.lookup_list + bytes.u16(self.lookup_list + 2 + 2 * index);
        for s in 0..bytes.u16(l + 4) {
            let mut sub = l + bytes.u16(l + 6 + 2 * s);
            let mut kind = bytes.u16(l);
            if kind == 7 {
                kind = bytes.u16(sub + 2);
                sub += bytes.u32(sub + 4);
            }
            match kind {
                1 => {
                    if self.single(sub, g, pos) {
                        return 1;
                    }
                }
                4 => {
                    if let Some(n) = self.ligature(sub, g, pos) {
                        return n;
                    }
                }
                6 => {
                    if bytes.u16(sub) == 3
                        && let Some(n) = self.chain(sub, g, pos)
                    {
                        return n;
                    }
                }
                _ => {}
            }
        }
        1
    }

    /// The coverage index of `glyph` in the table at `o`.
    pub fn coverage(&self, o: i64, glyph: i64) -> Option<i64> {
        let bytes = &self.bytes;
        match bytes.u16(o) {
            1 => {
                let (mut lo, mut hi) = (0, bytes.u16(o + 2) - 1);
                while lo <= hi {
                    let mid = (lo + hi) / 2;
                    let v = bytes.u16(o + 4 + 2 * mid);
                    if glyph < v {
                        hi = mid - 1;
                    } else if glyph > v {
                        lo = mid + 1;
                    } else {
                        return Some(mid);
                    }
                }
            }
            2 => {
                for r in 0..bytes.u16(o + 2) {
                    let rec = o + 4 + 6 * r;
                    let start = bytes.u16(rec);
                    if glyph >= start && glyph <= bytes.u16(rec + 2) {
                        return Some(bytes.u16(rec + 4) + glyph - start);
                    }
                }
            }
            _ => {}
        }
        None
    }

    fn single(&self, sub: i64, g: &mut [i64], pos: usize) -> bool {
        let bytes = &self.bytes;
        let Some(c) = self.coverage(sub + bytes.u16(sub + 2), g[pos]) else { return false };
        if bytes.u16(sub) == 1 {
            g[pos] = (g[pos] + bytes.s16(sub + 4)) & 0xFFFF;
        } else {
            if c >= bytes.u16(sub + 4) {
                return false;
            }
            g[pos] = bytes.u16(sub + 6 + 2 * c);
        }
        true
    }

    fn ligature(&self, sub: i64, g: &mut Vec<i64>, pos: usize) -> Option<usize> {
        let bytes = &self.bytes;
        if bytes.u16(sub) != 1 {
            return None;
        }
        let c = self.coverage(sub + bytes.u16(sub + 2), g[pos])?;
        if c >= bytes.u16(sub + 4) {
            return None;
        }
        let set = sub + bytes.u16(sub + 6 + 2 * c);
        for k in 0..bytes.u16(set) {
            let lig = set + bytes.u16(set + 2 + 2 * k);
            let n = bytes.u16(lig + 2);
            if n < 1 || pos + n as usize > g.len() {
                continue;
            }
            if (1..n).all(|i| g[pos + i as usize] == bytes.u16(lig + 4 + 2 * (i - 1))) {
                g.splice(pos..pos + n as usize, [bytes.u16(lig)]);
                return Some(1);
            }
        }
        None
    }

    fn chain(&self, sub: i64, g: &mut Vec<i64>, pos: usize) -> Option<usize> {
        let bytes = &self.bytes;
        let mut o = sub + 2;
        let back = bytes.u16(o);
        o += 2;
        let back_cov: Vec<i64> = (0..back).map(|i| sub + bytes.u16(o + 2 * i)).collect();
        o += 2 * back;
        let input = bytes.u16(o);
        o += 2;
        let in_cov: Vec<i64> = (0..input).map(|i| sub + bytes.u16(o + 2 * i)).collect();
        o += 2 * input;
        let ahead = bytes.u16(o);
        o += 2;
        let ahead_cov: Vec<i64> = (0..ahead).map(|i| sub + bytes.u16(o + 2 * i)).collect();
        o += 2 * ahead;
        let records = bytes.u16(o);
        o += 2;
        if input <= 0 || (pos as i64) < back || pos as i64 + input + ahead > g.len() as i64 {
            return None;
        }
        let input = input as usize;
        for (i, &c) in back_cov.iter().enumerate() {
            self.coverage(c, g[pos - 1 - i])?;
        }
        for (i, &c) in in_cov.iter().enumerate() {
            self.coverage(c, g[pos + i])?;
        }
        for (i, &c) in ahead_cov.iter().enumerate() {
            self.coverage(c, g[pos + input + i])?;
        }
        let before = g.len() as i64;
        for r in 0..records {
            let seq = bytes.u16(o + 4 * r);
            let lookup = bytes.u16(o + 4 * r + 2);
            let at = pos + seq as usize;
            if at < g.len() {
                let _ = self.step(lookup, g, at);
            }
        }
        Some((input as i64 + g.len() as i64 - before).max(1) as usize)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn be16(v: i64) -> Vec<u8> {
        vec![(v >> 8 & 0xFF) as u8, (v & 0xFF) as u8]
    }

    fn be32(v: i64) -> Vec<u8> {
        [be16(v >> 16), be16(v & 0xFFFF)].concat()
    }

    /// An sfnt directory around the given tables (4-byte aligned, checksums zero).
    fn sfnt(tables: &[(&str, Vec<u8>)]) -> FontBytes {
        let mut dir = [be32(0x10000), be16(tables.len() as i64), vec![0; 6]].concat();
        let mut body: Vec<u8> = Vec::new();
        let mut offset = 12 + 16 * tables.len() as i64;
        for (tag, data) in tables {
            dir.extend([tag.as_bytes().to_vec(), be32(0), be32(offset), be32(data.len() as i64)].concat());
            let mut padded = data.clone();
            padded.resize(data.len() + (4 - data.len() % 4) % 4, 0);
            offset += padded.len() as i64;
            body.extend(padded);
        }
        dir.extend(body);
        FontBytes::new(dir)
    }

    /// COLR v0: glyph 10 = layers (3 red, 4 foreground); CPAL: one palette, red.
    fn colr() -> Vec<u8> {
        [
            be16(0),
            be16(1),
            be32(14),
            be32(20),
            be16(2),
            be16(10),
            be16(0),
            be16(2),
            be16(3),
            be16(0),
            be16(4),
            be16(0xFFFF),
        ]
        .concat()
    }

    fn cpal() -> Vec<u8> {
        [be16(0), be16(1), be16(1), be16(1), be32(14), be16(0), vec![0, 0, 255, 255]].concat() // BGRA red
    }

    /// GSUB feature ccmp -> lookup 0 (ligature 5 6 7 -> 10, 5 6 -> 9), lookup 1 (single 9 -> 11 by delta).
    fn gsub() -> Vec<u8> {
        let coverage = [be16(1), be16(1), be16(5)].concat();
        let lig3 = [be16(10), be16(3), be16(6), be16(7)].concat();
        let lig2 = [be16(9), be16(2), be16(6)].concat();
        let set = [be16(2), be16(6), be16(6 + lig3.len() as i64), lig3, lig2].concat();
        let sub0 = [be16(1), be16(8 + set.len() as i64), be16(1), be16(8), set, coverage].concat();
        // single subtable format 1: coverage, delta 2 (9 -> 11)
        let sub1 = [be16(1), be16(6), be16(2), be16(1), be16(1), be16(9)].concat();
        let lookup0 = [be16(4), be16(0), be16(1), be16(8), sub0].concat();
        let lookup1 = [be16(1), be16(0), be16(1), be16(8), sub1].concat();
        let lookup_list = [be16(2), be16(6), be16(6 + lookup0.len() as i64), lookup0, lookup1].concat();
        let feature = [be16(0), be16(2), be16(0), be16(1)].concat();
        let feature_list = [be16(1), b"ccmp".to_vec(), be16(8), feature].concat();
        let header = [be32(0x10000), be16(10), be16(10), be16(10 + feature_list.len() as i64)].concat();
        [header, feature_list, lookup_list].concat()
    }

    #[test]
    fn color_layers_are_read_with_their_palette_colors() {
        let b = sfnt(&[("COLR", colr()), ("CPAL", cpal())]);
        let colors = ColorGlyphs::new(&b, &b.tables()).unwrap();
        let layers = colors.layers(10).unwrap();
        assert_eq!(layers.iter().map(|l| l.glyph).collect::<Vec<_>>(), [3, 4]);
        assert_eq!(layers[0].color, Some(RGBAColor::new(1.0, 0.0, 0.0, 1.0)));
        assert_eq!(layers[1].color, None);
        assert!(colors.layers(11).is_none());
    }

    #[test]
    fn ligatures_join_the_longest_sequence_first_and_later_lookups_see_the_result() {
        let b = sfnt(&[("GSUB", gsub())]);
        let sub = GlyphSubstitution::new(&b, &b.tables()).unwrap();
        assert_eq!(sub.apply(&[5, 6, 7]), [10]);
        assert_eq!(sub.apply(&[5, 6]), [11]); // ligature 9, then the single lookup 9 -> 11
        assert_eq!(sub.apply(&[1, 5, 6, 7, 2]), [1, 10, 2]);
        assert_eq!(sub.apply(&[5, 7]), [5, 7]);
    }
}
