// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SfntTabularFigures.swift

use crate::sfnt_variations::FontBytes;
use std::collections::{BTreeSet, HashMap};

/// The `tnum` (tabular figures) substitutions of a font's GSUB table: single substitutions (lookup type 1, also behind the
/// extension type 7) of every lookup the `tnum` features name. AppKit's `monospacedDigitSystemFont` turns this feature on, so
/// every digit of the Mac UI has one width; the shared UI does the same for the glyphs it draws.
#[derive(Clone, Debug)]
pub struct TabularFigures {
    /// Original glyph -> tabular glyph.
    pub map: HashMap<i64, i64>,
}

impl TabularFigures {
    /// Reads the substitutions for `digits`; `None` without a GSUB `tnum` feature or any digit substitution.
    pub fn new(b: &FontBytes, tables: &HashMap<String, i64>, digits: &[i64]) -> Option<TabularFigures> {
        let gsub = *tables.get("GSUB")?;
        if b.u16(gsub) != 1 {
            return None;
        }
        let features = gsub + b.u16(gsub + 6);
        let lookups = gsub + b.u16(gsub + 8);
        let mut wanted = BTreeSet::new();
        for i in 0..b.u16(features) {
            if b.tag(features + 2 + 6 * i) == "tnum" {
                let f = features + b.u16(features + 2 + 6 * i + 4);
                for k in 0..b.u16(f + 2) {
                    wanted.insert(b.u16(f + 4 + 2 * k));
                }
            }
        }
        if wanted.is_empty() {
            return None;
        }
        let digit_set: BTreeSet<i64> = digits.iter().copied().collect();
        let mut out: HashMap<i64, i64> = HashMap::new();
        for index in wanted {
            if index >= b.u16(lookups) {
                continue;
            }
            let lookup = lookups + b.u16(lookups + 2 + 2 * index);
            let mut ty = b.u16(lookup);
            for s in 0..b.u16(lookup + 4) {
                let mut sub = lookup + b.u16(lookup + 6 + 2 * s);
                if ty == 7 {
                    // extension: the real lookup type and a 32-bit offset
                    if b.u16(sub) != 1 {
                        continue;
                    }
                    ty = b.u16(sub + 2);
                    sub += b.u32(sub + 4);
                }
                if ty != 1 {
                    continue;
                }
                let format = b.u16(sub);
                let coverage = sub + b.u16(sub + 2);
                for &g in &digit_set {
                    if out.contains_key(&g) {
                        continue;
                    }
                    let Some(ci) = Self::coverage_index(b, coverage, g) else { continue };
                    if format == 1 {
                        out.insert(g, (g + b.s16(sub + 4)) & 0xFFFF);
                    } else if format == 2 && ci < b.u16(sub + 4) {
                        out.insert(g, b.u16(sub + 6 + 2 * ci));
                    }
                }
            }
        }
        if out.is_empty() {
            return None;
        }
        Some(TabularFigures { map: out })
    }

    fn coverage_index(b: &FontBytes, o: i64, g: i64) -> Option<i64> {
        let n = b.u16(o + 2);
        if b.u16(o) == 1 {
            return (0..n).find(|&i| b.u16(o + 4 + 2 * i) == g);
        }
        for i in 0..n {
            let r = o + 4 + 6 * i;
            if g >= b.u16(r) && g <= b.u16(r + 2) {
                return Some(b.u16(r + 4) + g - b.u16(r));
            }
        }
        None
    }
}
