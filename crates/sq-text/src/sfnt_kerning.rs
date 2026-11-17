// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SfntKerning.swift

use crate::sfnt_variations::{FontBytes, ItemVariationStore};
use std::collections::{BTreeSet, HashMap};

/// Pair kerning from a font's GPOS table: the lookups of every `kern` feature, pair adjustment (format 1 glyph pairs,
/// format 2 class pairs, also behind extension lookups), x advance of the first glyph with its variation delta (GDEF
/// item variation store). Written from the OpenType 1.9 specification.
/// known limit: only the x advance of the first glyph (no placement, no mark skipping, no script / language selection: all
/// `kern` lookups apply); enough for Latin titles, upgrade with HarfBuzz for complex scripts.
#[derive(Clone, Debug)]
pub struct PairKerning {
    bytes: FontBytes,
    /// Per lookup, its pair adjustment subtables (first match wins inside a lookup).
    lookups: Vec<Vec<i64>>,
    store: Option<ItemVariationStore>,
}

impl PairKerning {
    /// Reads the `kern` lookups; `None` without GPOS version 1 or any pair adjustment lookup.
    pub fn new(bytes: &FontBytes, t: &HashMap<String, i64>) -> Option<PairKerning> {
        let gpos = *t.get("GPOS")?;
        if bytes.u16(gpos) != 1 {
            return None;
        }
        let features = gpos + bytes.u16(gpos + 6);
        let lookup_list = gpos + bytes.u16(gpos + 8);
        let mut indices = BTreeSet::new();
        for i in 0..bytes.u16(features) {
            let rec = features + 2 + i * 6;
            if bytes.tag(rec) != "kern" {
                continue;
            }
            let f = features + bytes.u16(rec + 4);
            for k in 0..bytes.u16(f + 2) {
                indices.insert(bytes.u16(f + 4 + k * 2));
            }
        }
        let mut out: Vec<Vec<i64>> = Vec::new();
        for li in indices {
            if li >= bytes.u16(lookup_list) {
                continue;
            }
            let l = lookup_list + bytes.u16(lookup_list + 2 + li * 2);
            let ty = bytes.u16(l);
            let mut subs = Vec::new();
            for k in 0..bytes.u16(l + 4) {
                let s = l + bytes.u16(l + 6 + k * 2);
                if ty == 2 {
                    subs.push(s);
                } else if ty == 9 && bytes.u16(s + 2) == 2 {
                    subs.push(s + bytes.u32(s + 4));
                }
            }
            if !subs.is_empty() {
                out.push(subs);
            }
        }
        if out.is_empty() {
            return None;
        }
        let store = match t.get("GDEF") {
            Some(&gdef) if bytes.u16(gdef) == 1 && bytes.u16(gdef + 2) >= 3 && bytes.u32(gdef + 14) > 0 => {
                ItemVariationStore::new(bytes, gdef + bytes.u32(gdef + 14))
            }
            _ => None,
        };
        Some(PairKerning { bytes: bytes.clone(), lookups: out, store })
    }

    /// The advance adjustment between glyphs `a` and `b` (font units), at normalized `coords`.
    pub fn kern(&self, a: i64, b: i64, coords: &[f64]) -> f64 {
        let mut total = 0.0;
        for subs in &self.lookups {
            for &s in subs {
                if let Some(v) = self.pair(s, a, b, coords) {
                    total += v;
                    break;
                }
            }
        }
        total
    }

    fn value_size(f: i64) -> i64 {
        (0..8).fold(0, |acc, i| acc + (f >> i & 1)) * 2
    }

    fn pair(&self, s: i64, a: i64, b: i64, coords: &[f64]) -> Option<f64> {
        let by = &self.bytes;
        let ci = self.coverage(s + by.u16(s + 2), a)?;
        let f1 = by.u16(s + 4);
        let f2 = by.u16(s + 6);
        let size1 = Self::value_size(f1);
        let size2 = Self::value_size(f2);
        match by.u16(s) {
            1 => {
                if ci >= by.u16(s + 8) {
                    return None;
                }
                let set = s + by.u16(s + 10 + ci * 2);
                let record = 2 + size1 + size2;
                let mut lo = 0;
                let mut hi = by.u16(set) - 1;
                while lo <= hi {
                    let mid = (lo + hi) / 2;
                    let r = set + 2 + mid * record;
                    let g = by.u16(r);
                    if g < b {
                        lo = mid + 1;
                    } else if g > b {
                        hi = mid - 1;
                    } else {
                        return Some(self.x_advance(r + 2, f1, set, coords));
                    }
                }
                None
            }
            2 => {
                let c1 = self.class_of(s + by.u16(s + 8), a);
                let c2 = self.class_of(s + by.u16(s + 10), b);
                let n1 = by.u16(s + 12);
                let n2 = by.u16(s + 14);
                if c1 >= n1 || c2 >= n2 {
                    return None;
                }
                Some(self.x_advance(s + 16 + (c1 * n2 + c2) * (size1 + size2), f1, s, coords))
            }
            _ => None,
        }
    }

    /// `base`: where device offsets start (the pair set in format 1, the subtable in format 2, as HarfBuzz reads them).
    fn x_advance(&self, r: i64, format: i64, base: i64, coords: &[f64]) -> f64 {
        if format & 0x4 == 0 && format & 0x40 == 0 {
            return 0.0;
        }
        let at = |bit: i64| r + Self::value_size(format & (bit - 1));
        let by = &self.bytes;
        let mut v = if format & 0x4 != 0 { by.s16(at(0x4)) as f64 } else { 0.0 };
        if format & 0x40 != 0
            && coords.iter().any(|&c| c != 0.0)
            && let Some(store) = &self.store
        {
            let off = by.u16(at(0x40));
            let d = base + off;
            if off > 0 && by.u16(d + 4) == 0x8000 {
                v += store.delta(by.u16(d), by.u16(d + 2), coords);
            }
        }
        v
    }

    fn coverage(&self, c: i64, g: i64) -> Option<i64> {
        let by = &self.bytes;
        match by.u16(c) {
            1 => {
                let mut lo = 0;
                let mut hi = by.u16(c + 2) - 1;
                while lo <= hi {
                    let mid = (lo + hi) / 2;
                    let v = by.u16(c + 4 + mid * 2);
                    if v < g {
                        lo = mid + 1;
                    } else if v > g {
                        hi = mid - 1;
                    } else {
                        return Some(mid);
                    }
                }
            }
            2 => {
                let mut lo = 0;
                let mut hi = by.u16(c + 2) - 1;
                while lo <= hi {
                    let mid = (lo + hi) / 2;
                    let r = c + 4 + mid * 6;
                    if by.u16(r + 2) < g {
                        lo = mid + 1;
                    } else if by.u16(r) > g {
                        hi = mid - 1;
                    } else {
                        return Some(by.u16(r + 4) + g - by.u16(r));
                    }
                }
            }
            _ => {}
        }
        None
    }

    fn class_of(&self, c: i64, g: i64) -> i64 {
        let by = &self.bytes;
        match by.u16(c) {
            1 => {
                let start = by.u16(c + 2);
                let n = by.u16(c + 4);
                if g >= start && g < start + n { by.u16(c + 6 + (g - start) * 2) } else { 0 }
            }
            2 => {
                let mut lo = 0;
                let mut hi = by.u16(c + 2) - 1;
                while lo <= hi {
                    let mid = (lo + hi) / 2;
                    let r = c + 4 + mid * 6;
                    if by.u16(r + 2) < g {
                        lo = mid + 1;
                    } else if by.u16(r) > g {
                        hi = mid - 1;
                    } else {
                        return by.u16(r + 4);
                    }
                }
                0
            }
            _ => 0,
        }
    }
}
