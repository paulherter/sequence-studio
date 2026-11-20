//! Canvas shapes built from the existing quad kinds (Swift `Canvas+Dash`, `Canvas+Icon`, polygon fills and the span
//! cache), so every renderer draws them unchanged.

use crate::canvas::Canvas;
use crate::draw_list::{Color, Rect};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqicon_path_data::{SQIconPathSink, SQIconSVG, SQIconWeight};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Cache key: caller key, sub-pixel offset bits (x, y) and scale bits.
type SpanKey = (u64, u32, u32, u32);

/// Row spans of polygon sets (a panel owns one per static artwork).
/// shortcut: cleared whole once it holds `limit` sets (no LRU); upgrade when many differently sized wheels alternate.
pub struct PolygonSpanCache {
    sets: HashMap<SpanKey, Vec<(Rect, Color)>>,
    limit: usize,
}

impl PolygonSpanCache {
    /// A cache holding at most `limit` span sets.
    pub fn new(limit: usize) -> PolygonSpanCache {
        PolygonSpanCache { sets: HashMap::new(), limit }
    }
    /// The span sets held.
    pub fn count(&self) -> usize {
        self.sets.len()
    }
}

impl Default for PolygonSpanCache {
    fn default() -> Self {
        Self::new(32)
    }
}

/// An icon outline on its own grid as polylines: the path sink of the shared toolkit. Curves are flattened.
#[derive(Default)]
pub struct IconOutline {
    polylines: Vec<Vec<CGPoint>>,
    current: Vec<CGPoint>,
    start: CGPoint,
}

fn near(a: CGPoint, b: CGPoint) -> bool {
    a.x == b.x && a.y == b.y
}

impl IconOutline {
    /// Segments per curve (an icon curve spans a few grid units, 8 keeps it smooth at 32 px).
    const CURVE_STEPS: usize = 8;

    fn flush(&mut self) {
        if self.current.len() > 1 {
            self.polylines.push(std::mem::take(&mut self.current));
        } else {
            self.current.clear();
        }
    }
    fn begin(&mut self) -> CGPoint {
        if self.current.is_empty() {
            self.current.push(self.start);
        }
        self.current[self.current.len() - 1]
    }
    fn finish(mut self) -> Vec<Vec<CGPoint>> {
        self.flush();
        self.polylines
    }
}

impl SQIconPathSink for IconOutline {
    fn sink_move(&mut self, p: CGPoint) {
        self.flush();
        self.current = vec![p];
        self.start = p;
    }
    fn sink_line(&mut self, p: CGPoint) {
        self.begin();
        self.current.push(p);
    }
    fn sink_curve(&mut self, p: CGPoint, c1: CGPoint, c2: CGPoint) {
        let p0 = self.begin();
        for i in 1..=Self::CURVE_STEPS {
            let t = i as f64 / Self::CURVE_STEPS as f64;
            let u = 1.0 - t;
            let (a, b, c, d) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
            self.current.push(CGPoint {
                x: a * p0.x + b * c1.x + c * c2.x + d * p.x,
                y: a * p0.y + b * c1.y + c * c2.y + d * p.y,
            });
        }
    }
    fn sink_quad(&mut self, p: CGPoint, q: CGPoint) {
        let p0 = self.begin();
        for i in 1..=Self::CURVE_STEPS {
            let t = i as f64 / Self::CURVE_STEPS as f64;
            let u = 1.0 - t;
            self.current.push(CGPoint {
                x: u * u * p0.x + 2.0 * u * t * q.x + t * t * p.x,
                y: u * u * p0.y + 2.0 * u * t * q.y + t * t * p.y,
            });
        }
    }
    fn sink_close(&mut self) {
        if !self.current.is_empty() && !near(self.current[self.current.len() - 1], self.start) {
            self.current.push(self.start);
        }
        self.flush();
    }
}

/// The flattened glyph of an icon: contours to fill and polylines to stroke, on a `grid` square.
#[derive(Clone, Debug)]
pub struct IconGlyph {
    /// Grid edge.
    pub grid: f64,
    /// Line width of stroked drawings in grid units.
    pub line_width: f64,
    /// Contours filled with nonzero winding.
    pub fills: Vec<Vec<CGPoint>>,
    /// Polylines stroked round-capped.
    pub strokes: Vec<Vec<CGPoint>>,
}

static ICON_CACHE: Mutex<Option<HashMap<(&'static str, bool), Arc<IconGlyph>>>> = Mutex::new(None);

impl IconOutline {
    /// The flattened glyph of `icon` (cached; empty when the file is missing).
    pub fn glyph(icon: SQIcon) -> Arc<IconGlyph> {
        let name = icon.resource();
        let mut guard = ICON_CACHE.lock().unwrap_or_else(|e| e.into_inner());
        let cache = guard.get_or_insert_with(HashMap::new);
        let key = (name, icon.is_filled()); // a solid icon shares its file with the outline one
        if let Some(g) = cache.get(&key) {
            return Arc::clone(g);
        }
        let mut g = IconGlyph { grid: 24.0, line_width: 1.5, fills: Vec::new(), strokes: Vec::new() };
        if let Some(svg) = icon.svg_source() {
            let doc = SQIconSVG::document(svg);
            g.grid = doc.grid;
            g.line_width = doc.line_width;
            for (outline, shape) in SQIconSVG::shapes(svg, IconOutline::default) {
                let lines = outline.finish();
                if shape.fill || icon.is_filled() {
                    g.fills.extend(lines.iter().cloned());
                }
                if shape.stroke {
                    g.strokes.extend(lines);
                }
            }
        }
        let g = Arc::new(g);
        cache.insert(key, Arc::clone(&g));
        g
    }
}

/// The row spans of a device-pixel polygon (even-odd), one rect per span, top to bottom.
fn spans(p: &[(f32, f32)], mut emit: impl FnMut(Rect)) {
    let (mut min_y, mut max_y) = (p[0].1, p[0].1);
    for q in p {
        min_y = min_y.min(q.1);
        max_y = max_y.max(q.1);
    }
    let mut xs: Vec<f32> = Vec::with_capacity(8);
    let mut y = min_y.floor();
    while y < max_y {
        let sy = y + 0.5;
        xs.clear();
        let mut j = p.len() - 1;
        for i in 0..p.len() {
            let ((x0, y0), (x1, y1)) = (p[j], p[i]);
            if (y0 <= sy && y1 > sy) || (y1 <= sy && y0 > sy) {
                xs.push(x0 + (sy - y0) / (y1 - y0) * (x1 - x0));
            }
            j = i;
        }
        xs.sort_by(f32::total_cmp);
        for pair in xs.as_chunks::<2>().0 {
            if pair[1] > pair[0] {
                emit(Rect::new(pair[0], y, pair[1] - pair[0], 1.0));
            }
        }
        y += 1.0;
    }
}

impl Canvas<'_> {
    /// A filled polygon (even-odd): key diamonds, arrows, curve areas.
    /// shortcut: one span quad per device row, upgrade to a triangle-fan quad kind for large shapes.
    pub fn fill_polygon(&mut self, points: &[CGPoint], c: Color) {
        if points.len() < 3 {
            return;
        }
        let p: Vec<(f32, f32)> = points.iter().map(|q| self.px_point(*q)).collect();
        let mut out = Vec::new();
        spans(&p, |r| out.push(r));
        for r in out {
            self.list.fill(r, c, 0.0);
        }
    }

    /// Polygons (points relative to `origin`) through `cache`: their row spans are built once per `key`, scale and
    /// sub-pixel offset of `origin`, then replayed at whole-pixel shifts. For static many-wedge art (the color wheels).
    pub fn fill_polygons(
        &mut self,
        polygons: impl FnOnce() -> Vec<(Vec<CGPoint>, Color)>,
        origin: CGPoint,
        key: u64,
        cache: &mut PolygonSpanCache,
    ) {
        let (ox, oy) = self.px_point(origin);
        let (ix, iy) = (ox.floor(), oy.floor());
        let k = (key, (ox - ix).to_bits(), (oy - iy).to_bits(), self.scale.to_bits());
        if !cache.sets.contains_key(&k) {
            if cache.sets.len() >= cache.limit {
                cache.sets.clear();
            }
            let (s, fx, fy) = (self.scale as f64, (ox - ix) as f64, (oy - iy) as f64);
            let mut built = Vec::new();
            for (pts, c) in polygons().iter().filter(|(p, _)| p.len() > 2) {
                let dev: Vec<(f32, f32)> = pts.iter().map(|p| ((p.x * s + fx) as f32, (p.y * s + fy) as f32)).collect();
                spans(&dev, |r| built.push((r, *c)));
            }
            cache.sets.insert(k, built);
        }
        if let Some(set) = cache.sets.get(&k) {
            for (r, c) in set {
                self.list.fill(Rect::new(r.x + ix, r.y + iy, r.w, r.h), *c, 0.0);
            }
        }
    }

    /// The outline of a rounded rectangle as a closed point path (corner arcs in `steps` pieces each), clockwise from the
    /// top edge, in points.
    pub fn rounded_rect_path(r: CGRect, radius: f64, steps: usize) -> Vec<CGPoint> {
        let rad = radius.min(r.width / 2.0).min(r.height / 2.0).max(0.0);
        let pt = |x, y| CGPoint { x, y };
        if rad <= 0.0 {
            return vec![pt(r.x, r.y), pt(r.max_x(), r.y), pt(r.max_x(), r.max_y()), pt(r.x, r.max_y())];
        }
        use std::f64::consts::{FRAC_PI_2, PI};
        let corners = [
            (pt(r.max_x() - rad, r.y + rad), -FRAC_PI_2),
            (pt(r.max_x() - rad, r.max_y() - rad), 0.0),
            (pt(r.x + rad, r.max_y() - rad), FRAC_PI_2),
            (pt(r.x + rad, r.y + rad), PI),
        ];
        let mut out = Vec::new();
        for (c, a0) in corners {
            for i in 0..=steps {
                let a = a0 + i as f64 / steps as f64 * FRAC_PI_2;
                out.push(pt(c.x + rad * a.cos(), c.y + rad * a.sin()));
            }
        }
        out
    }

    /// A dashed line along `points` (`closed` joins the last point to the first): `on` points drawn, `off` skipped, starting
    /// at `phase` into the pattern; butt-ended segments of `width`.
    #[allow(clippy::too_many_arguments)]
    pub fn stroke_dashed(
        &mut self,
        points: &[CGPoint],
        closed: bool,
        width: f64,
        on: f64,
        off: f64,
        phase: f64,
        c: Color,
    ) {
        if points.len() < 2 || on <= 0.0 || off < 0.0 {
            return;
        }
        let mut path = points.to_vec();
        if closed {
            path.push(points[0]);
        }
        let period = on + off;
        let mut at = phase % period;
        for w in path.windows(2) {
            let (a, b) = (w[0], w[1]);
            let len = (b.x - a.x).hypot(b.y - a.y);
            if len <= 0.0 {
                continue;
            }
            let mut s = 0.0;
            while s < len {
                let drawing = at < on;
                let step = (if drawing { on - at } else { period - at }).min(len - s);
                if drawing {
                    let lerp = |d: f64| CGPoint { x: a.x + (b.x - a.x) * d / len, y: a.y + (b.y - a.y) * d / len };
                    self.stroke_butt(lerp(s), lerp(s + step), width, c);
                }
                s += step;
                at = (at + step) % period;
            }
        }
    }

    /// A dashed rounded-rectangle outline, centered on the edge like `stroke_rounded`.
    pub fn stroke_dashed_rounded(&mut self, r: CGRect, radius: f64, width: f64, on: f64, off: f64, c: Color) {
        let path = Self::rounded_rect_path(r, radius, 6);
        self.stroke_dashed(&path, true, width, on, off, 0.0, c);
    }

    /// `r` filled only where it lies inside the rounded rectangle `clip` (a strip along a clip body keeps the round
    /// corners): full rows as one quad, the rows in the corner bands as one span quad per device row.
    pub fn fill_inside_rounded(&mut self, r: CGRect, clip: CGRect, radius: f64, c: Color) {
        let (x0, y0) = (r.x.max(clip.x), r.y.max(clip.y));
        let (x1, y1) = (r.max_x().min(clip.max_x()), r.max_y().min(clip.max_y()));
        if x1 <= x0 || y1 <= y0 {
            return;
        }
        let b = CGRect::new(x0, y0, x1 - x0, y1 - y0);
        let rad = radius.min(clip.width / 2.0).min(clip.height / 2.0).max(0.0);
        let (top_band, bottom_band) = (clip.y + rad, clip.max_y() - rad);
        let (mid_top, mid_bottom) = (b.y.max(top_band), b.max_y().min(bottom_band));
        if mid_bottom > mid_top {
            self.fill(CGRect::new(b.x, mid_top, b.width, mid_bottom - mid_top), c);
        }
        if rad <= 0.0 {
            return;
        }
        let row_h = 1.0 / self.scale as f64;
        let span = |this: &mut Self, from: f64, to: f64| {
            let mut y = from;
            while y < to {
                let h = row_h.min(to - y);
                let cy = y + h / 2.0;
                let dy = if cy < top_band { top_band - cy } else { cy - bottom_band };
                let inset = rad - (rad * rad - dy * dy).max(0.0).sqrt();
                let (sx0, sx1) = (b.x.max(clip.x + inset), b.max_x().min(clip.max_x() - inset));
                if sx1 > sx0 {
                    this.fill(CGRect::new(sx0, y, sx1 - sx0, h), c);
                }
                y += h;
            }
        };
        if b.y < top_band {
            span(self, b.y, b.max_y().min(top_band));
        }
        if b.max_y() > bottom_band {
            span(self, b.y.max(bottom_band), b.max_y());
        }
    }

    /// A butt-ended line of `width` (an axis-aligned one is one rect; others a round-capped segment).
    fn stroke_butt(&mut self, a: CGPoint, b: CGPoint, width: f64, c: Color) {
        if a.y == b.y {
            self.fill(CGRect::new(a.x.min(b.x), a.y - width / 2.0, (b.x - a.x).abs(), width), c);
        } else if a.x == b.x {
            self.fill(CGRect::new(a.x - width / 2.0, a.y.min(b.y), width, (b.y - a.y).abs()), c);
        } else {
            self.stroke_line(a, b, width, c);
        }
    }

    /// Closed contours filled with nonzero winding, antialiased: 4 sub-scanlines per pixel row, exact horizontal coverage,
    /// equal-coverage pixels merged into one quad per run.
    pub fn fill_contours(&mut self, contours: &[Vec<CGPoint>], c: Color) {
        let polys: Vec<Vec<(f32, f32)>> =
            contours.iter().filter(|p| p.len() > 2).map(|p| p.iter().map(|q| self.px_point(*q)).collect()).collect();
        if polys.is_empty() {
            return;
        }
        let (mut min_x, mut max_x, mut min_y, mut max_y) = (f32::MAX, f32::MIN, f32::MAX, f32::MIN);
        for q in polys.iter().flatten() {
            min_x = min_x.min(q.0);
            max_x = max_x.max(q.0);
            min_y = min_y.min(q.1);
            max_y = max_y.max(q.1);
        }
        let x0 = min_x.floor() as i32;
        let width = ((max_x.ceil() as i32 - x0 + 1).max(1)) as usize;
        const SUB: usize = 4;
        let mut cov = vec![0f32; width];
        let mut hits: Vec<(f32, i32)> = Vec::new();
        let mut y = min_y.floor();
        while y < max_y {
            cov.fill(0.0);
            for s in 0..SUB {
                let sy = y + (s as f32 + 0.5) / SUB as f32;
                hits.clear();
                for p in &polys {
                    let mut j = p.len() - 1;
                    for i in 0..p.len() {
                        let ((ax, ay), (bx, by)) = (p[j], p[i]);
                        if (ay <= sy && by > sy) || (by <= sy && ay > sy) {
                            hits.push((ax + (sy - ay) / (by - ay) * (bx - ax), if by > ay { 1 } else { -1 }));
                        }
                        j = i;
                    }
                }
                hits.sort_by(|a, b| a.0.total_cmp(&b.0));
                let (mut wind, mut span_start) = (0, 0.0f32);
                for &(hx, dir) in &hits {
                    let before = wind;
                    wind += dir;
                    if before == 0 && wind != 0 {
                        span_start = hx - x0 as f32;
                    }
                    if before != 0 && wind == 0 {
                        let b = hx - x0 as f32;
                        let mut i = span_start.floor().max(0.0) as usize;
                        while i < width && (i as f32) < b {
                            let (l, r) = (span_start.max(i as f32), b.min(i as f32 + 1.0));
                            if r > l {
                                cov[i] += (r - l) / SUB as f32;
                            }
                            i += 1;
                        }
                    }
                }
            }
            let mut i = 0;
            while i < width {
                let v = cov[i].min(1.0);
                if v < 0.004 {
                    i += 1;
                    continue;
                }
                let mut j = i + 1;
                while j < width && (cov[j].min(1.0) - v).abs() < 0.004 {
                    j += 1;
                }
                self.list.fill(Rect::new((x0 + i as i32) as f32, y, (j - i) as f32, 1.0), c.with_alpha(c.a * v), 0.0);
                i = j;
            }
            y += 1.0;
        }
    }

    /// `icon` drawn at `origin` (square `size`, top-left): Lucide drawings as strokes of the file's line width (solid icons
    /// are also filled). No line is thinner than `SQIconWeight::MIN_LINE` points. `stroke` (grid units) overrides the line width of stroked drawings.
    pub fn draw_icon(&mut self, icon: SQIcon, origin: CGPoint, size: f64, c: Color, stroke: Option<f64>) {
        self.draw_icon_turned(icon, origin, size, c, stroke, 0.0);
    }

    /// [`draw_icon`](Self::draw_icon) turned `degrees` clockwise around the icon's center (the spinner).
    pub fn draw_icon_turned(
        &mut self,
        icon: SQIcon,
        origin: CGPoint,
        size: f64,
        c: Color,
        stroke: Option<f64>,
        degrees: f64,
    ) {
        let g = IconOutline::glyph(icon);
        let k = size / g.grid;
        let (sin, cos) = degrees.to_radians().sin_cos();
        let half = g.grid / 2.0;
        let map = |line: &Vec<CGPoint>| -> Vec<CGPoint> {
            line.iter()
                .map(|p| {
                    let (dx, dy) = (p.x - half, p.y - half);
                    CGPoint {
                        x: origin.x + (half + dx * cos - dy * sin) * k,
                        y: origin.y + (half + dx * sin + dy * cos) * k,
                    }
                })
                .collect()
        };
        let thin = SQIconWeight::MIN_LINE / k;
        if !g.fills.is_empty() {
            let contours: Vec<Vec<CGPoint>> = g.fills.iter().map(map).collect();
            self.fill_contours(&contours, c);
            let extra = if icon.is_filled() { 0.0 } else { (thin - g.grid / 16.0).max(0.0) };
            if extra > 0.0 {
                for line in &contours {
                    self.stroke_polyline(line, extra * k, c);
                }
            }
        }
        // Stroked icons draw at the design's one on-screen line width (`size/icon_stroke`, 1.5 pt at every size), not at the
        // file's grid width; solid icons keep the file's width.
        let width = stroke.unwrap_or_else(|| {
            if icon.is_filled() {
                g.line_width
            } else {
                f64::from(sq_uikit::tokens::size::ICON_STROKE) / k
            }
        });
        for line in &g.strokes {
            self.stroke_polyline(&map(line), width * k, c);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// G2: every icon the UI maps resolves to an SVG and draws something.
    #[test]
    fn every_icon_renders_non_empty() {
        for icon in SQIcon::ALL {
            let g = IconOutline::glyph(icon);
            assert!(
                !g.fills.is_empty() || !g.strokes.is_empty(),
                "{} ({}) draws nothing",
                icon.raw_value(),
                icon.resource()
            );
        }
    }

    fn xs(c: &Canvas) -> Vec<(f32, f32)> {
        c.list.quads().iter().map(|q| (q.rect.x, q.rect.w)).collect()
    }

    /// Swift `CanvasDashTests`.
    #[test]
    fn dashed_line_draws_only_the_on_parts() {
        let mut cv = Canvas::with_size(100.0, 20.0, None, 1.0);
        cv.stroke_dashed(
            &[CGPoint { x: 0.0, y: 5.0 }, CGPoint { x: 21.0, y: 5.0 }],
            false,
            1.0,
            4.0,
            3.0,
            0.0,
            Color::WHITE,
        );
        assert_eq!(xs(&cv), vec![(0.0, 4.0), (7.0, 4.0), (14.0, 4.0)], "21 ends in the gap");
    }

    #[test]
    fn dashed_rounded_rect_follows_the_outline() {
        let mut cv = Canvas::with_size(100.0, 100.0, None, 1.0);
        cv.stroke_dashed_rounded(CGRect::new(10.0, 10.0, 60.0, 30.0), 4.0, 1.0, 4.0, 3.0, Color::WHITE);
        assert!(cv.list.quads().len() > 15);
        for q in cv.list.quads() {
            assert!(q.rect.x >= 8.0 && q.rect.max_x() <= 72.0 && q.rect.y >= 8.0 && q.rect.max_y() <= 42.0);
        }
    }

    #[test]
    fn fill_inside_rounded_rect_keeps_the_corners() {
        let mut cv = Canvas::with_size(100.0, 40.0, None, 1.0);
        let body = CGRect::new(0.0, 0.0, 50.0, 20.0);
        cv.fill_inside_rounded(CGRect::new(0.0, 17.0, 50.0, 3.0), body, 4.0, Color::WHITE);
        let bottom = cv.list.quads().iter().max_by(|a, b| a.rect.y.total_cmp(&b.rect.y)).map(|q| q.rect);
        let bottom = bottom.unwrap_or_default();
        assert!(bottom.x > 0.5 && bottom.max_x() < 49.5, "the last row is cut by the corner arcs");
        assert!(cv.list.quads().iter().all(|q| q.rect.y >= 17.0 && q.rect.max_y() <= 20.001));
    }

    /// Swift `DrawCostTests.spanCacheReplaysThePolygonsAtAnyOrigin`.
    fn wedges(r: f64) -> Vec<(Vec<CGPoint>, Color)> {
        (0..24)
            .map(|i| {
                let a0 = i as f64 / 24.0 * std::f64::consts::TAU;
                let a1 = (i + 1) as f64 / 24.0 * std::f64::consts::TAU + 0.01;
                let p = |a: f64, rr: f64| CGPoint { x: r + rr * a.cos(), y: r - rr * a.sin() };
                (vec![p(a0, r * 0.25), p(a0, r), p(a1, r), p(a1, r * 0.25)], Color::new(i as f32 / 24.0, 0.5, 0.2, 0.6))
            })
            .collect()
    }

    #[test]
    fn span_cache_replays_the_polygons_at_any_origin() {
        let mut cache = PolygonSpanCache::default();
        for (origin, scale) in [((20.0, 30.0), 1.0), ((20.25, 30.5), 1.0), ((120.0, 7.5), 2.0), ((20.0, 31.0), 1.0)] {
            let mut direct = Canvas::with_size(800.0, 600.0, None, scale);
            direct.translate_by(3.0, 4.0);
            for (pts, c) in wedges(40.0) {
                let moved: Vec<CGPoint> =
                    pts.iter().map(|p| CGPoint { x: p.x + origin.0, y: p.y + origin.1 }).collect();
                direct.fill_polygon(&moved, c);
            }
            let mut cached = Canvas::with_size(800.0, 600.0, None, scale);
            cached.translate_by(3.0, 4.0);
            cached.fill_polygons(|| wedges(40.0), CGPoint { x: origin.0, y: origin.1 }, 40, &mut cache);
            assert_eq!(cached.list.quads().len(), direct.list.quads().len());
            for (a, b) in cached.list.quads().iter().zip(direct.list.quads()) {
                assert!((a.rect.x - b.rect.x).abs() < 1e-3 && (a.rect.y - b.rect.y).abs() < 1e-3);
                assert!((a.rect.w - b.rect.w).abs() < 1e-3 && a.rect.h == b.rect.h && a.color == b.color);
            }
        }
        let mut c = Canvas::with_size(800.0, 600.0, None, 1.0);
        let mut built = 0;
        for x in [10.0, 50.0, 90.0] {
            c.fill_polygons(
                || {
                    built += 1;
                    wedges(30.0)
                },
                CGPoint { x, y: 10.0 },
                30,
                &mut cache,
            );
        }
        assert!(built == 1 && cache.count() >= 1);
        assert!(!c.list.quads().is_empty() && c.list.quads().len().is_multiple_of(3));
    }

    #[test]
    fn a_solid_icon_fills_while_its_outline_twin_does_not() {
        assert_eq!(SQIcon::Star.resource(), SQIcon::StarFilled.resource());
        let (outline, solid) = (IconOutline::glyph(SQIcon::Star), IconOutline::glyph(SQIcon::StarFilled));
        assert!(outline.fills.is_empty() && !solid.fills.is_empty());
        // Either call order gives the same answer (the cache must not mix them up).
        assert!(IconOutline::glyph(SQIcon::Star).fills.is_empty());
    }

    #[test]
    fn icon_draws_strokes_for_a_lucide_glyph() {
        let mut c = Canvas::with_size(64.0, 64.0, None, 1.0);
        c.draw_icon(SQIcon::ChevronRight, CGPoint { x: 4.0, y: 4.0 }, 24.0, Color::WHITE, None);
        assert!(!c.list.quads().is_empty());
        for q in c.list.quads() {
            assert!(q.rect.x >= 3.0 && q.rect.max_x() <= 29.0 && q.rect.y >= 3.0 && q.rect.max_y() <= 29.0);
        }
    }

    #[test]
    fn round_rect_path_is_clockwise_from_the_top() {
        let p = Canvas::rounded_rect_path(CGRect::new(0.0, 0.0, 20.0, 10.0), 4.0, 6);
        assert_eq!(p.len(), 28);
        assert!((p[0].x - 16.0).abs() < 1e-9 && p[0].y.abs() < 1e-9);
        assert_eq!(Canvas::rounded_rect_path(CGRect::new(0.0, 0.0, 20.0, 10.0), 0.0, 6).len(), 4);
    }
}
