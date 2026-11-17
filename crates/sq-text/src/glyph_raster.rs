// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: GlyphRaster.swift

use crate::inter_font;
use crate::sfnt_face::SfntFace;
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

/// A glyph's coverage bitmap: 8-bit alpha, rows top to bottom. `left`/`top` place it relative to the pen position on the
/// baseline (pixels, y down: the bitmap's top row sits `top` pixels above the baseline).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GlyphBitmap {
    /// Width in pixels.
    pub width: i64,
    /// Height in pixels.
    pub height: i64,
    /// Offset of the left column from the pen.
    pub left: i64,
    /// Offset of the top row above the baseline.
    pub top: i64,
    /// Coverage, rows top to bottom.
    pub coverage: Vec<u8>,
}

impl GlyphBitmap {
    /// No pixels.
    pub fn empty() -> GlyphBitmap {
        GlyphBitmap { width: 0, height: 0, left: 0, top: 0, coverage: Vec::new() }
    }
}

/// One outline point in font units.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Point {
    /// Horizontal.
    pub x: f64,
    /// Vertical (up).
    pub y: f64,
    /// On the curve (not a control point).
    pub on_curve: bool,
}

/// A line segment (x0, y0, x1, y1).
type Segment = (f64, f64, f64, f64);

/// A TrueType (`glyf`) font that maps characters, measures them and rasterizes outlines on the CPU, the same on every
/// platform (the portable UI draws its text with it: Windows and the Mac comparison renderer get identical pixels).
/// CFF outlines (brand fonts such as `.otf` files) are read with `ttf-parser` and converted to quadratic contours.
/// known limit: no hinting; a CFF cubic becomes 4 quadratic pieces, upgrade to cubic flattening if curves look faceted.
#[derive(Clone, Debug)]
pub struct GlyphRasterFont {
    /// Font units per em.
    pub units_per_em: i64,
    /// Ascender in font units.
    pub ascender: i64,
    /// Descender in font units (negative).
    pub descender: i64,
    /// Line gap in font units.
    pub line_gap: i64,
    /// The parsed tables.
    pub face: Arc<SfntFace>,
    loca: i64,
    glyf: i64,
    long_loca: bool,
    glyph_count: i64,
    /// Outlines come from a `CFF ` table (no `glyf`).
    cff: bool,
    /// Normalized variation coordinates every outline and advance uses (empty: the default instance).
    pub coords: Vec<f64>,
    /// The axis values (user units) this instance was made with; `instance_weight` keeps the others (optical size).
    pub settings: BTreeMap<String, f64>,
}

impl GlyphRasterFont {
    /// Parses a font file; `None` for a non-TrueType-outline font.
    pub fn new(data: Vec<u8>) -> Option<GlyphRasterFont> {
        Self::new_face(data, 0)
    }

    /// Parses font number `face` of a collection file.
    pub fn new_face(data: Vec<u8>, face: u32) -> Option<GlyphRasterFont> {
        let face = SfntFace::new_face(data, face)?;
        let b = &face.bytes;
        let tables = b.tables();
        let head = *tables.get("head")?;
        let cff = !tables.contains_key("glyf") && tables.contains_key("CFF ");
        let loca = if cff { 0 } else { *tables.get("loca")? };
        let glyf = if cff { 0 } else { *tables.get("glyf")? };
        let maxp = *tables.get("maxp")?;
        let long_loca = b.u16(head + 50) == 1;
        let glyph_count = b.u16(maxp + 4);
        Some(GlyphRasterFont {
            units_per_em: face.units_per_em,
            ascender: face.ascender,
            descender: face.descender,
            line_gap: face.line_gap,
            face: Arc::new(face),
            loca,
            glyf,
            long_loca,
            glyph_count,
            cff,
            coords: Vec::new(),
            settings: BTreeMap::new(),
        })
    }

    /// Reads a font file from `path`.
    pub fn from_path(path: &Path) -> Option<GlyphRasterFont> {
        let (file, face) = crate::system_fonts::split_face(path);
        Self::new_face(std::fs::read(file).ok()?, face)
    }

    /// The same font at `weight` on its `wght` axis (100...900; `None` for a font without one): one file, several weights.
    /// Other axes keep this instance's settings.
    pub fn instance_weight(&self, weight: f64) -> Option<GlyphRasterFont> {
        self.face.variations.as_ref()?.axis_index("wght")?;
        let mut merged = self.settings.clone();
        merged.insert("wght".to_string(), weight);
        self.instance(&merged)
    }

    /// The same font with the given axis values (user units, by tag; tags the font lacks are ignored, the rest stay at
    /// their defaults). `None` for a font without variations.
    pub fn instance(&self, axes: &BTreeMap<String, f64>) -> Option<GlyphRasterFont> {
        let v = self.face.variations.as_ref()?;
        let mut user: Vec<f64> = v.axes.iter().map(|a| a.default_value).collect();
        let mut kept = BTreeMap::new();
        for (tag, value) in axes {
            if let Some(i) = v.axis_index(tag) {
                user[i] = *value;
                kept.insert(tag.clone(), *value);
            }
        }
        Some(GlyphRasterFont { coords: v.normalized(&user), settings: kept, ..self.clone() })
    }

    /// The Mac system UI font (San Francisco, the variable `SFNS.ttf` at text optical size), the face AppKit's
    /// `NSFont.systemFont` draws: the Mac shared UI's text font. `None` elsewhere or when the file is missing or unreadable.
    /// known limit: reads the system file by path and sets one optical size (13 pt) for every UI size; upgrade to a per-size
    /// optical size when small captions look too loose.
    pub fn mac_system_ui() -> Option<GlyphRasterFont> {
        if !cfg!(target_os = "macos") {
            return None;
        }
        let f = Self::from_path(Path::new("/System/Library/Fonts/SFNS.ttf"))?;
        if f.glyph_for('H') == 0 {
            return None;
        }
        let axes = BTreeMap::from([("opsz".to_string(), 13.0), ("wght".to_string(), 400.0)]);
        Some(f.instance(&axes).unwrap_or(f))
    }

    /// The bundled Inter (regular instance of the variable font) from `fonts_root` (the package's `Resources/Fonts`).
    pub fn inter(fonts_root: &Path) -> Option<GlyphRasterFont> {
        inter_font::font_urls(fonts_root).iter().find_map(|p| Self::from_path(p))
    }

    /// Inter SemiBold (600), the weight the Mac UI sets panel titles and empty-state titles in.
    pub fn inter_semibold(fonts_root: &Path) -> Option<GlyphRasterFont> {
        Self::inter(fonts_root)?.instance_weight(600.0)
    }

    /// Inter Medium (500), the Mac UI's weight for tab titles, clip names and button labels.
    pub fn inter_medium(fonts_root: &Path) -> Option<GlyphRasterFont> {
        Self::inter(fonts_root)?.instance_weight(500.0)
    }

    /// Whether this font carries the system font's typography (`trak` tracking, tabular digits): the Mac system UI font
    /// does, the bundled Inter and the Windows fonts have no `trak` table.
    pub fn has_system_typography(&self) -> bool {
        self.face.tracking.is_some()
    }

    /// The tracking Core Text adds after every glyph at `point_size`, in font units (0 without a `trak` table).
    pub fn tracking_units(&self, point_size: f64) -> f64 {
        self.face.tracking.as_ref().map(|t| t.at(point_size)).unwrap_or(0.0)
    }

    /// Pair kerning between two glyphs in font units (GPOS `kern`; 0 when the font has none). Every face is kerned, as
    /// Core Text and DirectWrite do for the same font.
    pub fn kern_units(&self, a: i64, b: i64) -> f64 {
        self.face.kern(a, b, &self.coords)
    }

    /// The tabular (equal width) form of a digit glyph, as AppKit's `monospacedDigitSystemFont` draws it (system typography
    /// only; any other glyph comes back unchanged).
    pub fn tabular_glyph(&self, g: i64) -> i64 {
        if self.face.tracking.is_none() {
            return g;
        }
        self.face.tabular_digits().and_then(|t| t.map.get(&g).copied()).unwrap_or(g)
    }

    /// Glyph index of a character.
    pub fn glyph_for(&self, scalar: char) -> i64 {
        self.face.glyph_for(scalar)
    }

    /// Advance width in font units.
    pub fn advance(&self, glyph: i64) -> i64 {
        if self.coords.is_empty() {
            self.face.advance(glyph)
        } else {
            self.face.advance_at(glyph, &self.coords).round() as i64
        }
    }

    /// Advance width in font units at normalized variation coordinates.
    pub fn advance_at(&self, glyph: i64, coords: &[f64]) -> f64 {
        self.face.advance_at(glyph, coords)
    }

    /// Contours of a CFF glyph: lines are on-curve points, cubics are split into quadratic pieces.
    fn cff_contours(&self, g: i64) -> Vec<Vec<Point>> {
        struct Out {
            done: Vec<Vec<Point>>,
            cur: Vec<Point>,
            at: (f64, f64),
        }
        impl Out {
            fn on(&mut self, x: f64, y: f64) {
                self.cur.push(Point { x, y, on_curve: true });
                self.at = (x, y);
            }
            fn quad(&mut self, cx: f64, cy: f64, x: f64, y: f64) {
                self.cur.push(Point { x: cx, y: cy, on_curve: false });
                self.on(x, y);
            }
        }
        impl ttf_parser::OutlineBuilder for Out {
            fn move_to(&mut self, x: f32, y: f32) {
                self.close();
                self.on(x as f64, y as f64);
            }
            fn line_to(&mut self, x: f32, y: f32) {
                self.on(x as f64, y as f64);
            }
            fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
                self.quad(x1 as f64, y1 as f64, x as f64, y as f64);
            }
            fn curve_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
                // Split the cubic at t = 1/4, 1/2, 3/4 (de Casteljau); each piece is approximated by one quadratic whose
                // control point is where the end tangents meet: (3 (c1 + c2) - (p0 + p3)) / 4 of the piece.
                let (p0, p1, p2, p3) = (self.at, (x1 as f64, y1 as f64), (x2 as f64, y2 as f64), (x as f64, y as f64));
                let at = |t: f64| {
                    let u = 1.0 - t;
                    let f = |a: f64, b: f64, c: f64, d: f64| {
                        u * u * u * a + 3.0 * u * u * t * b + 3.0 * u * t * t * c + t * t * t * d
                    };
                    (f(p0.0, p1.0, p2.0, p3.0), f(p0.1, p1.1, p2.1, p3.1))
                };
                let d = |t: f64| {
                    let u = 1.0 - t;
                    let f = |a: f64, b: f64, c: f64, e: f64| {
                        3.0 * (u * u * (b - a) + 2.0 * u * t * (c - b) + t * t * (e - c))
                    };
                    (f(p0.0, p1.0, p2.0, p3.0), f(p0.1, p1.1, p2.1, p3.1))
                };
                const N: usize = 4;
                for k in 0..N {
                    let (t0, t1) = (k as f64 / N as f64, (k + 1) as f64 / N as f64);
                    let (a, b) = (at(t0), at(t1));
                    let (da, db) = (d(t0), d(t1));
                    let h = t1 - t0;
                    // Control point from the two end tangents (average of the two single-tangent estimates).
                    let c = (
                        ((a.0 + da.0 * h / 2.0) + (b.0 - db.0 * h / 2.0)) / 2.0,
                        ((a.1 + da.1 * h / 2.0) + (b.1 - db.1 * h / 2.0)) / 2.0,
                    );
                    self.quad(c.0, c.1, b.0, b.1);
                }
            }
            fn close(&mut self) {
                if self.cur.len() > 1 {
                    let c = std::mem::take(&mut self.cur);
                    self.done.push(c);
                } else {
                    self.cur.clear();
                }
            }
        }
        let Ok(face) = ttf_parser::Face::parse(&self.face.bytes.b, self.face.bytes.face) else { return Vec::new() };
        let mut out = Out { done: Vec::new(), cur: Vec::new(), at: (0.0, 0.0) };
        if g < 0 || g > u16::MAX as i64 {
            return Vec::new();
        }
        let _ = face.outline_glyph(ttf_parser::GlyphId(g as u16), &mut out);
        ttf_parser::OutlineBuilder::close(&mut out);
        out.done
    }

    fn glyph_range(&self, g: i64) -> Option<(i64, i64)> {
        if g < 0 || g >= self.glyph_count {
            return None;
        }
        let b = &self.face.bytes;
        let (a, e) = if self.long_loca {
            (b.u32(self.loca + g * 4), b.u32(self.loca + g * 4 + 4))
        } else {
            (b.u16(self.loca + g * 2) * 2, b.u16(self.loca + g * 2 + 2) * 2)
        };
        if e > a { Some((self.glyf + a, self.glyf + e)) } else { None }
    }

    /// The closed contours of a glyph (composite glyphs resolved), font units, y up. `coords`: normalized variation
    /// coordinates (`gvar` deltas applied, untouched points interpolated); empty = the default instance.
    pub fn contours(&self, g: i64, coords: &[f64]) -> Vec<Vec<Point>> {
        self.contours_at_depth(g, coords, 0)
    }

    fn contours_at_depth(&self, g: i64, coords: &[f64], depth: i64) -> Vec<Vec<Point>> {
        if self.cff {
            return self.cff_contours(g);
        }
        let Some((start, _)) = self.glyph_range(g).filter(|_| depth < 8) else { return Vec::new() };
        let b = &self.face.bytes;
        let n = b.s16(start);
        let varies = self.face.variations.is_some() && coords.iter().any(|&c| c != 0.0);
        if n >= 0 {
            let contours = self.simple_contours(start, n);
            if !varies {
                return contours;
            }
            let flat: Vec<Point> = contours.iter().flatten().copied().collect();
            let mut ends = Vec::new();
            let mut total = 0;
            for c in &contours {
                total += c.len() as i64;
                ends.push(total - 1);
            }
            let deltas =
                self.face.variations.as_ref().and_then(|v| v.deltas(g, flat.len() as i64, Some(&flat), &ends, coords));
            let Some(d) = deltas else { return contours };
            let mut k = 0;
            return contours
                .iter()
                .map(|c| {
                    c.iter()
                        .map(|p| {
                            let q = Point { x: p.x + d[k].x, y: p.y + d[k].y, on_curve: p.on_curve };
                            k += 1;
                            q
                        })
                        .collect()
                })
                .collect();
        }
        // Composite: the component offsets are the glyph's variation points.
        let mut components = 0;
        let mut scan = start + 10;
        loop {
            let flags = b.u16(scan);
            components += 1;
            scan += 4
                + if flags & 0x1 != 0 { 4 } else { 2 }
                + if flags & 0x8 != 0 {
                    2
                } else if flags & 0x40 != 0 {
                    4
                } else if flags & 0x80 != 0 {
                    8
                } else {
                    0
                };
            if flags & 0x20 == 0 || components > 256 {
                break;
            }
        }
        let deltas = if varies {
            self.face.variations.as_ref().and_then(|v| v.deltas(g, components, None, &[], coords))
        } else {
            None
        };
        let mut component = 0usize;
        let mut out: Vec<Vec<Point>> = Vec::new();
        let mut o = start + 10;
        loop {
            let flags = b.u16(o);
            let child = b.u16(o + 2);
            o += 4;
            let (mut dx, mut dy);
            if flags & 0x1 != 0 {
                dx = b.s16(o) as f64;
                dy = b.s16(o + 2) as f64;
                o += 4;
            } else {
                dx = b.s8(o) as f64;
                dy = b.s8(o + 1) as f64;
                o += 2;
            }
            if flags & 0x2 == 0 {
                // point matching: unused by UI fonts
                dx = 0.0;
                dy = 0.0;
            }
            if let Some(d) = &deltas
                && component < d.len()
                && flags & 0x2 != 0
            {
                dx += d[component].x;
                dy += d[component].y;
            }
            component += 1;
            let mut m = (1.0, 0.0, 0.0, 1.0);
            let f2 = |p: i64| b.s16(p) as f64 / 16384.0;
            if flags & 0x8 != 0 {
                let s = f2(o);
                m = (s, 0.0, 0.0, s);
                o += 2;
            } else if flags & 0x40 != 0 {
                m = (f2(o), 0.0, 0.0, f2(o + 2));
                o += 4;
            } else if flags & 0x80 != 0 {
                m = (f2(o), f2(o + 2), f2(o + 4), f2(o + 6));
                o += 8;
            }
            for c in self.contours_at_depth(child, coords, depth + 1) {
                out.push(
                    c.iter()
                        .map(|p| Point {
                            x: p.x * m.0 + p.y * m.2 + dx,
                            y: p.x * m.1 + p.y * m.3 + dy,
                            on_curve: p.on_curve,
                        })
                        .collect(),
                );
            }
            if flags & 0x20 == 0 {
                break;
            }
        }
        out
    }

    fn simple_contours(&self, start: i64, n: i64) -> Vec<Vec<Point>> {
        if n <= 0 {
            return Vec::new();
        }
        let b = &self.face.bytes;
        let ends: Vec<i64> = (0..n).map(|i| b.u16(start + 10 + i * 2)).collect();
        let points = ends.last().copied().unwrap_or(-1) + 1;
        let mut o = start + 10 + n * 2;
        o += 2 + b.u16(o);
        let mut flags: Vec<i64> = Vec::new();
        let len = b.b.len() as i64;
        while (flags.len() as i64) < points && o < len {
            let f = b.u8(o);
            o += 1;
            flags.push(f);
            if f & 0x8 != 0 && o < len {
                let r = b.u8(o);
                o += 1;
                for _ in 0..r {
                    if (flags.len() as i64) < points {
                        flags.push(f);
                    }
                }
            }
        }
        let mut coords = |short: i64, same: i64| -> Vec<f64> {
            let mut v = 0;
            let mut out = Vec::with_capacity(points as usize);
            for &f in &flags {
                if f & short != 0 {
                    let d = b.u8(o);
                    o += 1;
                    v += if f & same != 0 { d } else { -d };
                } else if f & same == 0 {
                    v += b.s16(o);
                    o += 2;
                }
                out.push(v as f64);
            }
            out
        };
        let xs = coords(0x2, 0x10);
        let ys = coords(0x4, 0x20);
        let mut result = Vec::new();
        let mut first = 0;
        for &e in &ends {
            if e < points && e >= first {
                result.push(
                    (first..=e)
                        .map(|i| Point { x: xs[i as usize], y: ys[i as usize], on_curve: flags[i as usize] & 1 != 0 })
                        .collect(),
                );
                first = e + 1;
            }
        }
        result
    }

    /// Rasterizes a glyph at `pixels_per_em` (pen on an integer pixel, no hinting).
    pub fn rasterize(&self, g: i64, pixels_per_em: f64) -> GlyphBitmap {
        let s = pixels_per_em / self.units_per_em as f64;
        let lines = Self::flatten(&self.contours(g, &self.coords), s);
        if lines.is_empty() {
            return GlyphBitmap::empty();
        }
        let (mut min_x, mut max_x, mut min_y, mut max_y) =
            (f64::INFINITY, f64::NEG_INFINITY, f64::INFINITY, f64::NEG_INFINITY);
        for l in &lines {
            min_x = min_x.min(l.0).min(l.2);
            max_x = max_x.max(l.0).max(l.2);
            min_y = min_y.min(l.1).min(l.3);
            max_y = max_y.max(l.1).max(l.3);
        }
        let left = min_x.floor() as i64;
        let right = max_x.ceil() as i64;
        let bottom = min_y.floor() as i64;
        let top = max_y.ceil() as i64;
        let w = 1.max(right - left);
        let h = 1.max(top - bottom);
        let mut r = CoverageRasterizer::new(w, h);
        for l in &lines {
            r.line(
                (l.0 - left as f64) as f32,
                (top as f64 - l.1) as f32,
                (l.2 - left as f64) as f32,
                (top as f64 - l.3) as f32,
            );
        }
        GlyphBitmap { width: w, height: h, left, top, coverage: r.coverage() }
    }

    /// Contours to line segments (x0, y0, x1, y1) in pixels, y up; quadratic curves split by their size.
    pub fn flatten(contours: &[Vec<Point>], s: f64) -> Vec<Segment> {
        fn quad(out: &mut Vec<Segment>, p0: Point, c: Point, p1: Point) {
            let len = (c.x - p0.x).hypot(c.y - p0.y) + (p1.x - c.x).hypot(p1.y - c.y);
            let n = 1.max(16.min((len / 2.0).ceil() as i64));
            let (mut px, mut py) = (p0.x, p0.y);
            for k in 1..=n {
                let t = k as f64 / n as f64;
                let u = 1.0 - t;
                let x = u * u * p0.x + 2.0 * u * t * c.x + t * t * p1.x;
                let y = u * u * p0.y + 2.0 * u * t * c.y + t * t * p1.y;
                out.push((px, py, x, y));
                px = x;
                py = y;
            }
        }
        let mut out: Vec<Segment> = Vec::new();
        for c in contours.iter().filter(|c| c.len() > 1) {
            // Start on an on-curve point (or the midpoint of two off-curve points).
            let mut pts: Vec<Point> =
                c.iter().map(|p| Point { x: p.x * s, y: p.y * s, on_curve: p.on_curve }).collect();
            if let Some(i) = pts.iter().position(|p| p.on_curve) {
                pts.rotate_left(i);
            } else {
                let m = Point { x: (pts[0].x + pts[1].x) / 2.0, y: (pts[0].y + pts[1].y) / 2.0, on_curve: true };
                pts.insert(1, m);
                pts.rotate_left(1);
            }
            let mut cur = pts[0];
            let mut ctrl: Option<Point> = None;
            let walk: Vec<Point> = pts[1..].iter().copied().chain(std::iter::once(pts[0])).collect();
            for p in walk {
                if p.on_curve {
                    match ctrl {
                        Some(c) => quad(&mut out, cur, c, p),
                        None => out.push((cur.x, cur.y, p.x, p.y)),
                    }
                    cur = p;
                    ctrl = None;
                } else if let Some(c) = ctrl {
                    let mid = Point { x: (c.x + p.x) / 2.0, y: (c.y + p.y) / 2.0, on_curve: true };
                    quad(&mut out, cur, c, mid);
                    cur = mid;
                    ctrl = Some(p);
                } else {
                    ctrl = Some(p);
                }
            }
        }
        out
    }
}

/// Exact-area coverage of a nonzero path from line segments: each segment adds its signed area to an accumulation
/// buffer, a running sum per row gives the coverage. The accumulation approach follows font-rs (Raph Levien,
/// Apache-2.0/MIT, docs/THIRD_PARTY.md); written here from the algorithm.
#[derive(Clone, Debug)]
pub struct CoverageRasterizer {
    /// Width in pixels.
    pub width: i64,
    /// Height in pixels.
    pub height: i64,
    acc: Vec<f32>,
}

impl CoverageRasterizer {
    /// An empty canvas.
    pub fn new(width: i64, height: i64) -> Self {
        CoverageRasterizer { width, height, acc: vec![0.0; (width * height + 4).max(0) as usize] }
    }

    fn add(&mut self, row: i64, i: i64, v: f32) {
        let k = row + i;
        if k >= 0 && (k as usize) < self.acc.len() {
            self.acc[k as usize] += v;
        }
    }

    /// A segment in pixels (y down).
    pub fn line(&mut self, x0: f32, y0: f32, x1: f32, y1: f32) {
        if (y0 - y1).abs() <= 1e-6 {
            return;
        }
        let (dir, ax, ay, bx, by): (f32, f32, f32, f32, f32) =
            if y0 < y1 { (1.0, x0, y0, x1, y1) } else { (-1.0, x1, y1, x0, y0) };
        let dxdy = (bx - ax) / (by - ay);
        let mut x = ax;
        if ay < 0.0 {
            x -= ay * dxdy;
        }
        let y_start = 0.max(ay as i64);
        let y_end = self.height.min(by.ceil() as i64);
        if y_start >= y_end {
            return;
        }
        for y in y_start..y_end {
            let row = y * self.width;
            let dy = ((y + 1) as f32).min(by) - (y as f32).max(ay);
            let x_next = x + dxdy * dy;
            let d = dy * dir;
            let (lo, hi) = if x < x_next { (x, x_next) } else { (x_next, x) };
            let lo_floor = lo.floor();
            let hi_ceil = hi.ceil();
            let lo_i = lo_floor as i64;
            let hi_i = hi_ceil as i64;
            if hi_i <= lo_i + 1 {
                let mid = 0.5 * (x + x_next) - lo_floor;
                self.add(row, lo_i, d - d * mid);
                self.add(row, lo_i + 1, d * mid);
            } else {
                let s = 1.0 / (hi - lo);
                let lo_f = lo - lo_floor;
                let a0 = 0.5 * s * (1.0 - lo_f) * (1.0 - lo_f);
                let hi_f = hi - hi_ceil + 1.0;
                let am = 0.5 * s * hi_f * hi_f;
                self.add(row, lo_i, d * a0);
                if hi_i == lo_i + 2 {
                    self.add(row, lo_i + 1, d * (1.0 - a0 - am));
                } else {
                    let a1 = s * (1.5 - lo_f);
                    self.add(row, lo_i + 1, d * (a1 - a0));
                    for xi in (lo_i + 2)..(hi_i - 1) {
                        self.add(row, xi, d * s);
                    }
                    let a2 = a1 + (hi_i - lo_i - 3) as f32 * s;
                    self.add(row, hi_i - 1, d * (1.0 - a2 - am));
                }
                self.add(row, hi_i, d * am);
            }
            x = x_next;
        }
    }

    /// 8-bit coverage, rows top to bottom.
    pub fn coverage(&self) -> Vec<u8> {
        let n = (self.width * self.height).max(0) as usize;
        let mut sum = 0.0f32;
        self.acc[..n]
            .iter()
            .map(|a| {
                sum += a;
                (1.0f32.min(sum.abs()) * 255.0 + 0.5) as u8
            })
            .collect()
    }

    /// Coverage 0...1, rows top to bottom (the portable text raster blends in float).
    pub fn coverage_values(&self) -> Vec<f32> {
        let n = (self.width * self.height).max(0) as usize;
        let mut sum = 0.0f32;
        self.acc[..n]
            .iter()
            .map(|a| {
                sum += a;
                1.0f32.min(sum.abs())
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts::test_fonts_root;

    #[test]
    fn square_coverage_is_exact() {
        // A 2x2 square from (1,1) to (3,3) in a 4x4 grid, clockwise in y-down pixels.
        let mut r = CoverageRasterizer::new(4, 4);
        r.line(1.0, 1.0, 3.0, 1.0);
        r.line(3.0, 1.0, 3.0, 3.0);
        r.line(3.0, 3.0, 1.0, 3.0);
        r.line(1.0, 3.0, 1.0, 1.0);
        assert_eq!(r.coverage(), vec![0, 0, 0, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 0, 0, 0]);
    }

    #[test]
    fn half_pixel_edge_gives_half_coverage() {
        let mut r = CoverageRasterizer::new(2, 1);
        r.line(0.0, 0.0, 1.5, 0.0);
        r.line(1.5, 0.0, 1.5, 1.0);
        r.line(1.5, 1.0, 0.0, 1.0);
        r.line(0.0, 1.0, 0.0, 0.0);
        let c = r.coverage();
        assert_eq!(c[0], 255);
        assert!((i32::from(c[1]) - 128).abs() <= 1);
    }

    #[test]
    fn inter_letters_rasterize() {
        let font = GlyphRasterFont::inter(&test_fonts_root());
        assert!(font.is_some());
        let Some(font) = font else { return };
        let h = font.glyph_for('H');
        assert!(h != 0);
        assert!(font.advance(h) > 0);
        let bmp = font.rasterize(h, 20.0);
        // Cap height of Inter is ~0.73 em: about 15 px at 20 px/em, sitting on the baseline.
        assert!((13..=17).contains(&bmp.height));
        assert_eq!(bmp.top, bmp.height);
        // The crossbar row is covered across the middle; the counters above it are open.
        let mid_row = bmp.height / 2;
        let mid = bmp.width / 2;
        assert!(bmp.coverage[(mid_row * bmp.width + mid) as usize] > 200);
        assert!(bmp.coverage[(2 * bmp.width + mid) as usize] < 30);
        // Composite or simple, 'é' and 'g' carry ink; space has none.
        assert!(font.rasterize(font.glyph_for('é'), 20.0).coverage.iter().any(|&c| c > 200));
        let g = font.rasterize(font.glyph_for('g'), 20.0);
        assert!(g.top < g.height);
        assert_eq!(font.rasterize(font.glyph_for(' '), 20.0), GlyphBitmap::empty());
    }

    /// The Mac shared UI sets its text in the system font, as the AppKit UI does (`NSFont.systemFont`), not Inter.
    #[cfg(target_os = "macos")]
    #[test]
    fn mac_system_font_loads_with_weights() {
        let font = GlyphRasterFont::mac_system_ui();
        assert!(font.is_some());
        let (Some(font), Some(inter)) = (font, GlyphRasterFont::inter(&test_fonts_root())) else { return };
        let h = font.glyph_for('H');
        assert!(h != 0);
        let bmp = font.rasterize(h, 20.0);
        assert!((12..=16).contains(&bmp.height));
        // Wider than Inter's "m" is not the point: it must be another face, and a weight instance keeps the optical size.
        assert_ne!(
            font.advance(font.glyph_for('m')) * inter.units_per_em,
            inter.advance(inter.glyph_for('m')) * font.units_per_em
        );
        let semibold = font.instance_weight(600.0);
        assert!(semibold.is_some());
        let Some(semibold) = semibold else { return };
        assert_ne!(semibold.coords, font.coords);
        assert_eq!(semibold.settings.get("opsz"), font.settings.get("opsz"));
        let ink = |f: &GlyphRasterFont| {
            f.rasterize(f.glyph_for('H'), 40.0).coverage.iter().map(|&c| i64::from(c)).sum::<i64>()
        };
        assert!(ink(&semibold) > ink(&font));
    }
}
