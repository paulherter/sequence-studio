// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SfntVariations.swift
//! Variable fonts for the portable text backend (OpenType `fvar`, `avar`, `gvar`, `HVAR` and item variation stores),
//! written from the OpenType 1.9 specification.

use crate::glyph_raster::Point;
use sq_core_time::Vec2;
use std::collections::HashMap;
use std::sync::Arc;

/// Big-endian reads over a font file; reads outside the file give 0.
#[derive(Clone, Debug)]
pub struct FontBytes {
    /// The file.
    pub b: Arc<[u8]>,
    /// Which font of a collection (`.ttc` / `.otc`) this is; 0 for a single font.
    pub face: u32,
}

impl FontBytes {
    /// Wraps a font file.
    pub fn new(bytes: Vec<u8>) -> FontBytes {
        FontBytes { b: bytes.into(), face: 0 }
    }

    /// Wraps a collection file and picks its font number `face` (a single font file has only face 0).
    pub fn with_face(bytes: Vec<u8>, face: u32) -> FontBytes {
        FontBytes { b: bytes.into(), face }
    }

    /// The offset of this font's table directory: 0 in a single font, the face's entry in a collection.
    pub fn table_base(&self) -> i64 {
        if self.tag(0) == "ttcf" { self.u32(12 + 4 * i64::from(self.face)) } else { 0 }
    }

    /// Unsigned byte at `o`.
    pub fn u8(&self, o: i64) -> i64 {
        match usize::try_from(o).ok().and_then(|i| self.b.get(i)) {
            Some(v) => i64::from(*v),
            None => 0,
        }
    }

    /// Signed byte at `o`.
    pub fn s8(&self, o: i64) -> i64 {
        let v = self.u8(o);
        if v >= 0x80 { v - 0x100 } else { v }
    }

    /// Unsigned 16-bit value at `o`.
    pub fn u16(&self, o: i64) -> i64 {
        if o >= 0 && o + 2 <= self.b.len() as i64 { self.u8(o) << 8 | self.u8(o + 1) } else { 0 }
    }

    /// Signed 16-bit value at `o`.
    pub fn s16(&self, o: i64) -> i64 {
        let v = self.u16(o);
        if v >= 0x8000 { v - 0x10000 } else { v }
    }

    /// Unsigned 32-bit value at `o`.
    pub fn u32(&self, o: i64) -> i64 {
        self.u16(o) << 16 | self.u16(o + 2)
    }

    /// Signed 32-bit value at `o`.
    pub fn s32(&self, o: i64) -> i64 {
        let v = self.u32(o);
        if v >= 0x8000_0000 { v - 0x1_0000_0000 } else { v }
    }

    /// F2Dot14 fixed-point value at `o`.
    pub fn f2dot14(&self, o: i64) -> f64 {
        self.s16(o) as f64 / 16384.0
    }

    /// 16.16 fixed-point value at `o`.
    pub fn fixed(&self, o: i64) -> f64 {
        self.s32(o) as f64 / 65536.0
    }

    /// Four-byte tag at `o`.
    pub fn tag(&self, o: i64) -> String {
        let bytes: Vec<u8> = (0..4).map(|i| self.u8(o + i) as u8).collect();
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// Table offsets by tag (of this font's face in a collection).
    pub fn tables(&self) -> HashMap<String, i64> {
        let base = self.table_base();
        let mut out = HashMap::new();
        for i in 0..self.u16(base + 4) {
            let rec = base + 12 + i * 16;
            if rec + 16 > self.b.len() as i64 {
                break;
            }
            out.insert(self.tag(rec), self.u32(rec + 8));
        }
        out
    }
}

/// One region of the variation space: per axis (start, peak, end) in normalized coordinates.
pub enum VariationTent {}

impl VariationTent {
    /// The scalar of a tuple at `coords` (OpenType "Algorithm for interpolation of instance values").
    pub fn scalar(peak: &[f64], start: Option<&[f64]>, end: Option<&[f64]>, coords: &[f64]) -> f64 {
        let mut s = 1.0;
        for (i, &p) in peak.iter().enumerate() {
            if p == 0.0 {
                continue;
            }
            let lo = start.map_or_else(|| p.min(0.0), |v| v[i]);
            let hi = end.map_or_else(|| p.max(0.0), |v| v[i]);
            if lo > p || p > hi || (lo < 0.0 && hi > 0.0) {
                continue;
            }
            let v = coords.get(i).copied().unwrap_or(0.0);
            if v == p {
                continue;
            }
            if v <= lo || v >= hi {
                return 0.0;
            }
            s *= if v < p { (v - lo) / (p - lo) } else { (hi - v) / (hi - p) };
        }
        s
    }
}

/// An item variation store (HVAR, GDEF): delta sets by (outer, inner) index, scaled by their regions.
#[derive(Clone, Debug)]
pub struct ItemVariationStore {
    bytes: FontBytes,
    regions: Vec<Vec<(f64, f64, f64)>>,
    data: Vec<i64>,
}

impl ItemVariationStore {
    /// Reads the store at `o`; nil for offset 0 or an unknown format.
    pub fn new(bytes: &FontBytes, o: i64) -> Option<ItemVariationStore> {
        if o <= 0 || bytes.u16(o) != 1 {
            return None;
        }
        let rl = o + bytes.u32(o + 2);
        let axes = bytes.u16(rl);
        let count = bytes.u16(rl + 2);
        let regions = (0..count)
            .map(|r| {
                (0..axes)
                    .map(|a| {
                        let p = rl + 4 + (r * axes + a) * 6;
                        (bytes.f2dot14(p), bytes.f2dot14(p + 2), bytes.f2dot14(p + 4))
                    })
                    .collect()
            })
            .collect();
        let data = (0..bytes.u16(o + 6)).map(|i| o + bytes.u32(o + 8 + i * 4)).collect();
        Some(ItemVariationStore { bytes: bytes.clone(), regions, data })
    }

    /// The delta of one item at `coords`.
    pub fn delta(&self, outer: i64, inner: i64, coords: &[f64]) -> f64 {
        let bytes = &self.bytes;
        let Some(&d) = usize::try_from(outer).ok().and_then(|i| self.data.get(i)) else { return 0.0 };
        let items = bytes.u16(d);
        let word_field = bytes.u16(d + 2);
        let region_count = bytes.u16(d + 4);
        if inner >= items {
            return 0.0;
        }
        let long = (word_field & 0x8000) != 0;
        let words = word_field & 0x7FFF;
        let row_size = if long { words * 4 + (region_count - words) * 2 } else { words * 2 + (region_count - words) };
        let mut p = d + 6 + region_count * 2 + inner * row_size;
        let mut sum = 0.0;
        for j in 0..region_count {
            let v;
            if j < words {
                v = if long { bytes.s32(p) } else { bytes.s16(p) };
                p += if long { 4 } else { 2 };
            } else {
                v = if long { bytes.s16(p) } else { bytes.s8(p) };
                p += if long { 2 } else { 1 };
            }
            let ri = bytes.u16(d + 6 + j * 2);
            let Some(r) = usize::try_from(ri).ok().and_then(|i| self.regions.get(i)) else { continue };
            if v == 0 {
                continue;
            }
            let peak: Vec<f64> = r.iter().map(|t| t.1).collect();
            let start: Vec<f64> = r.iter().map(|t| t.0).collect();
            let end: Vec<f64> = r.iter().map(|t| t.2).collect();
            sum += v as f64 * VariationTent::scalar(&peak, Some(&start), Some(&end), coords);
        }
        sum
    }
}

/// One variation axis of a font.
#[derive(Clone, Debug, PartialEq)]
pub struct Axis {
    /// Four-letter axis tag (`wght`, `opsz`, ...).
    pub tag: String,
    /// Smallest user value.
    pub minimum: f64,
    /// Default user value.
    pub default_value: f64,
    /// Largest user value.
    pub maximum: f64,
}

/// The variation tables of a font: axes, named instances, normalization, glyph point deltas and advance deltas.
#[derive(Clone, Debug)]
pub struct FontVariations {
    /// The axes in file order.
    pub axes: Vec<Axis>,
    /// Named instances, user coordinates in axis order.
    pub instances: Vec<Vec<f64>>,
    bytes: FontBytes,
    avar: Vec<Vec<(f64, f64)>>,
    gvar: Option<i64>,
    gvar_long: bool,
    gvar_data: i64,
    gvar_glyphs: i64,
    shared_tuples: Vec<Vec<f64>>,
    hvar: Option<ItemVariationStore>,
    hvar_map: Option<i64>,
}

impl FontVariations {
    /// Reads the variation tables; nil for a font without `fvar` or axes.
    pub fn new(bytes: &FontBytes, t: &HashMap<String, i64>) -> Option<FontVariations> {
        let fvar = *t.get("fvar")?;
        let axes_at = fvar + bytes.u16(fvar + 4);
        let axis_count = bytes.u16(fvar + 8);
        let axis_size = bytes.u16(fvar + 10);
        let instance_count = bytes.u16(fvar + 12);
        let instance_size = bytes.u16(fvar + 14);
        if axis_count <= 0 {
            return None;
        }
        let axes = (0..axis_count)
            .map(|i| {
                let a = axes_at + i * axis_size;
                Axis {
                    tag: bytes.tag(a),
                    minimum: bytes.fixed(a + 4),
                    default_value: bytes.fixed(a + 8),
                    maximum: bytes.fixed(a + 12),
                }
            })
            .collect();
        let instances_at = axes_at + axis_count * axis_size;
        let instances = (0..instance_count)
            .map(|i| (0..axis_count).map(|k| bytes.fixed(instances_at + i * instance_size + 4 + k * 4)).collect())
            .collect();
        let mut avar = Vec::new();
        if let Some(&a) = t.get("avar") {
            let mut p = a + 8;
            for _ in 0..bytes.u16(a + 6) {
                let n = bytes.u16(p);
                avar.push((0..n).map(|k| (bytes.f2dot14(p + 2 + k * 4), bytes.f2dot14(p + 4 + k * 4))).collect());
                p += 2 + n * 4;
            }
        }
        let (gvar, gvar_glyphs, gvar_long, gvar_data, shared_tuples);
        match t.get("gvar") {
            Some(&g) if bytes.u16(g + 4) == axis_count => {
                gvar = Some(g);
                gvar_glyphs = bytes.u16(g + 12);
                gvar_long = (bytes.u16(g + 14) & 1) != 0;
                gvar_data = g + bytes.u32(g + 16);
                let shared = g + bytes.u32(g + 8);
                shared_tuples = (0..bytes.u16(g + 6))
                    .map(|i| (0..axis_count).map(|k| bytes.f2dot14(shared + (i * axis_count + k) * 2)).collect())
                    .collect();
            }
            _ => {
                gvar = None;
                gvar_glyphs = 0;
                gvar_long = false;
                gvar_data = 0;
                shared_tuples = Vec::new();
            }
        }
        let (hvar, hvar_map);
        if let Some(&h) = t.get("HVAR") {
            hvar = ItemVariationStore::new(bytes, h + bytes.u32(h + 4));
            let m = bytes.u32(h + 8);
            hvar_map = if m > 0 { Some(h + m) } else { None };
        } else {
            hvar = None;
            hvar_map = None;
        }
        Some(FontVariations {
            axes,
            instances,
            bytes: bytes.clone(),
            avar,
            gvar,
            gvar_long,
            gvar_data,
            gvar_glyphs,
            shared_tuples,
            hvar,
            hvar_map,
        })
    }

    /// The index of the axis with `tag`.
    pub fn axis_index(&self, tag: &str) -> Option<usize> {
        self.axes.iter().position(|a| a.tag == tag)
    }

    /// User coordinates (axis order) to normalized ones: default 0, ends -1 / 1, `avar` applied, F2Dot14 precision.
    pub fn normalized(&self, user: &[f64]) -> Vec<f64> {
        self.axes
            .iter()
            .enumerate()
            .map(|(i, a)| {
                let v = user.get(i).copied().unwrap_or(a.default_value).max(a.minimum).min(a.maximum);
                let mut n = 0.0;
                if v < a.default_value && a.default_value > a.minimum {
                    n = (v - a.default_value) / (a.default_value - a.minimum);
                }
                if v > a.default_value && a.maximum > a.default_value {
                    n = (v - a.default_value) / (a.maximum - a.default_value);
                }
                if let Some(mapped) = self.avar.get(i).and_then(|seg| Self::map(n, seg)) {
                    n = mapped;
                }
                (n * 16384.0).round() / 16384.0
            })
            .collect()
    }

    fn map(v: f64, seg: &[(f64, f64)]) -> Option<f64> {
        if seg.len() < 2 {
            return None;
        }
        if v <= seg[0].0 {
            return Some(seg[0].1);
        }
        for k in 1..seg.len() {
            if v <= seg[k].0 {
                let (a, b) = (seg[k - 1], seg[k]);
                return Some(if b.0 == a.0 { b.1 } else { a.1 + (v - a.0) * (b.1 - a.1) / (b.0 - a.0) });
            }
        }
        Some(seg[seg.len() - 1].1)
    }

    /// The advance width delta of a glyph in font units (HVAR), nil when the font has no HVAR (use the phantom points).
    pub fn advance_delta(&self, g: i64, coords: &[f64]) -> Option<f64> {
        let hvar = self.hvar.as_ref()?;
        let bytes = &self.bytes;
        let (mut outer, mut inner) = (0, g);
        if let Some(m) = self.hvar_map {
            let format = bytes.u8(m);
            let entry = bytes.u8(m + 1);
            let count = if format == 0 { bytes.u16(m + 2) } else { bytes.u32(m + 2) };
            let at = m + if format == 0 { 4 } else { 6 };
            let size = (entry >> 4 & 3) + 1;
            let inner_bits = (entry & 0xF) + 1;
            let i = g.min((count - 1).max(0));
            let mut v = 0;
            for k in 0..size {
                v = v << 8 | bytes.u8(at + i * size + k);
            }
            outer = v >> inner_bits;
            inner = v & ((1 << inner_bits) - 1);
        }
        Some(hvar.delta(outer, inner, coords))
    }

    /// Point deltas (x, y) of glyph `g` at `coords`: `point_count` outline points (or composite components) then the four
    /// phantom points. `original` and `ends` (simple glyphs) let untouched points be interpolated (IUP); composite glyphs
    /// pass nil and untouched components stay put. nil when the glyph does not vary.
    pub fn deltas(
        &self,
        g: i64,
        point_count: i64,
        original: Option<&[Point]>,
        ends: &[i64],
        coords: &[f64],
    ) -> Option<Vec<Vec2>> {
        let gvar = self.gvar?;
        if g < 0 || g >= self.gvar_glyphs || !coords.iter().any(|&c| c != 0.0) {
            return None;
        }
        let bytes = &self.bytes;
        let offs = gvar + 20;
        let (a, b) = if self.gvar_long {
            (bytes.u32(offs + g * 4), bytes.u32(offs + g * 4 + 4))
        } else {
            (bytes.u16(offs + g * 2) * 2, bytes.u16(offs + g * 2 + 2) * 2)
        };
        if b <= a {
            return None;
        }
        let o = self.gvar_data + a;
        let raw = bytes.u16(o);
        let tuple_count = raw & 0x0FFF;
        let mut serialized = o + bytes.u16(o + 2);
        let total = (point_count + 4) as usize;
        let mut shared = None;
        if (raw & 0x8000) != 0 {
            shared = self.read_points(&mut serialized);
        }
        let mut out = vec![Vec2::ZERO; total];
        let mut header = o + 4;
        let n = self.axes.len() as i64;
        let mut changed = false;
        for _ in 0..tuple_count {
            let size = bytes.u16(header);
            let index = bytes.u16(header + 2);
            header += 4;
            let peak: Vec<f64>;
            if (index & 0x8000) != 0 {
                peak = (0..n).map(|k| bytes.f2dot14(header + k * 2)).collect();
                header += n * 2;
            } else {
                let k = (index & 0x0FFF) as usize;
                peak = self.shared_tuples.get(k).cloned().unwrap_or_else(|| vec![0.0; n as usize]);
            }
            let (mut start, mut end) = (None, None);
            if (index & 0x4000) != 0 {
                start = Some((0..n).map(|k| bytes.f2dot14(header + k * 2)).collect::<Vec<f64>>());
                header += n * 2;
                end = Some((0..n).map(|k| bytes.f2dot14(header + k * 2)).collect::<Vec<f64>>());
                header += n * 2;
            }
            let mut p = serialized;
            serialized += size;
            let s = VariationTent::scalar(&peak, start.as_deref(), end.as_deref(), coords);
            if s == 0.0 {
                continue;
            }
            let points = if (index & 0x2000) != 0 { self.read_points(&mut p) } else { shared.clone() };
            let count = points.as_ref().map_or(total, Vec::len);
            let xs = self.read_deltas(&mut p, count);
            let ys = self.read_deltas(&mut p, count);
            changed = true;
            let Some(points) = points else {
                for i in 0..total {
                    out[i] = out[i] + Vec2::new(xs[i], ys[i]) * s;
                }
                continue;
            };
            let mut tuple = vec![Vec2::ZERO; total];
            let mut touched = vec![false; total];
            for (k, &i) in points.iter().enumerate() {
                if (i as usize) < total {
                    tuple[i as usize] = Vec2::new(xs[k], ys[k]);
                    touched[i as usize] = true;
                }
            }
            if let Some(original) = original {
                Self::interpolate_untouched(&mut tuple, &touched, original, ends);
            }
            for i in 0..total {
                out[i] = out[i] + tuple[i] * s;
            }
        }
        if changed { Some(out) } else { None }
    }

    /// Packed point numbers; nil = every point.
    fn read_points(&self, p: &mut i64) -> Option<Vec<i64>> {
        let bytes = &self.bytes;
        let mut count = bytes.u8(*p);
        *p += 1;
        if (count & 0x80) != 0 {
            count = (count & 0x7F) << 8 | bytes.u8(*p);
            *p += 1;
        }
        if count == 0 {
            return None;
        }
        let mut out: Vec<i64> = Vec::with_capacity(count as usize);
        let mut last = 0;
        while (out.len() as i64) < count {
            let control = bytes.u8(*p);
            *p += 1;
            let run = (control & 0x7F) + 1;
            let words = (control & 0x80) != 0;
            for _ in 0..run {
                if (out.len() as i64) >= count {
                    break;
                }
                last += if words { bytes.u16(*p) } else { bytes.u8(*p) };
                *p += if words { 2 } else { 1 };
                out.push(last);
            }
            if *p >= bytes.b.len() as i64 {
                break;
            }
        }
        Some(out)
    }

    fn read_deltas(&self, p: &mut i64, count: usize) -> Vec<f64> {
        let bytes = &self.bytes;
        let mut out: Vec<f64> = Vec::with_capacity(count);
        while out.len() < count {
            let control = bytes.u8(*p);
            *p += 1;
            let run = (control & 0x3F) + 1;
            for _ in 0..run {
                if out.len() >= count {
                    break;
                }
                match control & 0xC0 {
                    0x80 => out.push(0.0),
                    0x40 => {
                        out.push(bytes.s16(*p) as f64);
                        *p += 2;
                    }
                    0xC0 => {
                        out.push(bytes.s32(*p) as f64);
                        *p += 4;
                    }
                    _ => {
                        out.push(bytes.s8(*p) as f64);
                        *p += 1;
                    }
                }
            }
            if *p >= bytes.b.len() as i64 {
                break;
            }
        }
        while out.len() < count {
            out.push(0.0);
        }
        out
    }

    /// Interpolation of untouched points per contour (OpenType "Inferred deltas for un-referenced point numbers").
    pub fn interpolate_untouched(d: &mut [Vec2], touched: &[bool], original: &[Point], ends: &[i64]) {
        let mut start = 0usize;
        for &end in ends {
            let Ok(end) = usize::try_from(end) else { break };
            if end < start || end >= original.len() {
                break;
            }
            let first = start;
            start = end + 1;
            let idx: Vec<usize> = (first..=end).filter(|&i| touched[i]).collect();
            if idx.is_empty() || idx.len() == end - first + 1 {
                continue;
            }
            if idx.len() == 1 {
                for i in first..=end {
                    if !touched[i] {
                        d[i] = d[idx[0]];
                    }
                }
                continue;
            }
            for (k, &a) in idx.iter().enumerate() {
                let b = idx[(k + 1) % idx.len()];
                let mut i = a + 1;
                loop {
                    if i > end {
                        i = first;
                    }
                    if i == b {
                        break;
                    }
                    for axis in 0..2 {
                        let pick = |x: f64, y: f64| if axis == 0 { x } else { y };
                        let c = pick(original[i].x, original[i].y);
                        let mut c1 = pick(original[a].x, original[a].y);
                        let mut c2 = pick(original[b].x, original[b].y);
                        let mut d1 = pick(d[a].x, d[a].y);
                        let mut d2 = pick(d[b].x, d[b].y);
                        if c1 > c2 {
                            std::mem::swap(&mut c1, &mut c2);
                            std::mem::swap(&mut d1, &mut d2);
                        }
                        let value = if c1 == c2 {
                            if c == c1 {
                                if d1 == d2 { d1 } else { 0.0 }
                            } else if c < c1 {
                                d1
                            } else {
                                d2
                            }
                        } else if c <= c1 {
                            d1
                        } else if c >= c2 {
                            d2
                        } else {
                            d1 + (c - c1) * (d2 - d1) / (c2 - c1)
                        };
                        if axis == 0 {
                            d[i].x = value;
                        } else {
                            d[i].y = value;
                        }
                    }
                    i += 1;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::path::Path;

    /// The Swift dumper's Doubles (`oracle/sq-text/run.sh`) for the bundled Inter, by case.
    fn golden() -> (Vec<String>, BTreeMap<String, Vec<f64>>) {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../oracle/sq-text/golden/font-variations.tsv");
        let mut tags = Vec::new();
        let mut out: BTreeMap<String, Vec<f64>> = BTreeMap::new();
        for line in std::fs::read_to_string(path).unwrap().lines() {
            let f: Vec<&str> = line.split('\t').collect();
            if f[0] == "axis_tags" {
                tags = f[2].split(',').map(str::to_string).collect();
            } else {
                out.entry(f[0].to_string()).or_default().push(f64::from_bits(u64::from_str_radix(f[2], 16).unwrap()));
            }
        }
        (tags, out)
    }

    fn inter() -> (FontBytes, FontVariations) {
        let path = crate::bundled_fonts::test_fonts_root().join("Inter-VariableFont_opsz,wght.ttf");
        let bytes = FontBytes::new(std::fs::read(path).unwrap());
        let v = FontVariations::new(&bytes, &bytes.tables()).unwrap();
        (bytes, v)
    }

    fn same(name: &str, got: &[f64], want: &[f64]) {
        assert_eq!(got.len(), want.len(), "{name} length");
        for (i, (g, w)) in got.iter().zip(want).enumerate() {
            assert!((g - w).abs() < 1e-9, "{name}[{i}]: {g} vs {w}");
        }
    }

    #[test]
    fn axes_instances_and_normalization_match_the_swift_reader() {
        let (tags, g) = golden();
        let (_, v) = inter();
        assert_eq!(v.axes.iter().map(|a| a.tag.clone()).collect::<Vec<_>>(), tags);
        let axes: Vec<f64> = v.axes.iter().flat_map(|a| [a.minimum, a.default_value, a.maximum]).collect();
        same("axes", &axes, &g["axes"]);
        same("instances", &v.instances.concat(), &g["instances"]);
        let users = [[14.0, 700.0], [32.0, 100.0], [20.0, 900.0], [14.0, 400.0], [20.0, 350.0]];
        for (n, u) in users.iter().enumerate() {
            same(&format!("normalized{n}"), &v.normalized(u), &g[&format!("normalized{n}")]);
        }
    }

    #[test]
    fn advance_and_point_deltas_match_the_swift_reader() {
        let (_, g) = golden();
        let (_, v) = inter();
        let coords = v.normalized(&[20.0, 700.0]);
        let glyphs = [36, 41, 68, 100, 400];
        let advance: Vec<f64> = glyphs.iter().map(|&gl| v.advance_delta(gl, &coords).unwrap_or(-1.0)).collect();
        same("advance", &advance, &g["advance"]);
        let original: Vec<Point> =
            (0..40).map(|i| Point { x: f64::from(i * 7 % 53), y: f64::from(i * 11 % 37), on_curve: true }).collect();
        for gl in glyphs {
            let d = v.deltas(gl, 40, Some(&original), &[19, 39], &coords);
            let flat: Vec<f64> = d.map(|d| d.iter().flat_map(|p| [p.x, p.y]).collect()).unwrap_or_default();
            same(&format!("deltas{gl}"), &flat, g.get(&format!("deltas{gl}")).map_or(&[][..], Vec::as_slice));
        }
    }

    #[test]
    fn reads_outside_the_file_give_zero() {
        let b = FontBytes::new(vec![0x80, 0x01, 0xFF, 0xFE]);
        assert_eq!((b.u8(-1), b.u8(4), b.u16(3), b.u16(0), b.s16(2), b.s8(0)), (0, 0, 0, 0x8001, -2, -128));
        assert_eq!(b.u32(0), 0x8001_FFFE);
        assert_eq!(b.s32(0), 0x8001_FFFE - 0x1_0000_0000);
        assert_eq!(b.tag(0), "\u{FFFD}\u{1}\u{FFFD}\u{FFFD}");
    }

    #[test]
    fn a_tent_is_one_at_its_peak_and_zero_outside() {
        assert_eq!(VariationTent::scalar(&[1.0], None, None, &[1.0]), 1.0);
        assert_eq!(VariationTent::scalar(&[1.0], None, None, &[0.5]), 0.5);
        assert_eq!(VariationTent::scalar(&[1.0], None, None, &[-0.5]), 0.0);
        assert_eq!(VariationTent::scalar(&[0.0], None, None, &[0.7]), 1.0);
    }
}
