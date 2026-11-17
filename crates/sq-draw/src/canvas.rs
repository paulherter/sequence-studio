//! A CGContext-shaped drawing API over a [`DrawList`] (Swift `Canvas`): coordinates are in points (y down), state is a
//! stack of translation + clip, and the canvas turns points into device pixels with `scale` and emits quads. Dashes,
//! polygons and icons are in `canvas_shapes`.

use crate::draw_list::{Color, DrawList, Rect};
use crate::glyph_atlas::{GlyphAtlas, TextAlign};
use crate::motion;
use crate::theme::{self, DrawTheme};
use sq_text::glyph_raster::GlyphRasterFont;
use sq_text::text_style::FontWeight;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

#[derive(Clone, Copy, Default)]
struct State {
    tx: f64,
    ty: f64,
    clip_depth: usize,
}

/// Point-space builder over a draw list. A concrete type, not a trait.
pub struct Canvas<'a> {
    /// The list being filled.
    pub list: DrawList,
    pub(crate) atlas: Option<&'a GlyphAtlas>,
    /// Device pixels per point.
    pub scale: f32,
    state: State,
    stack: Vec<State>,
    /// What [`Canvas::start_probe`] collects (layout tests).
    probe: Option<Vec<(Probe, CGRect)>>,
}

/// What a layout probe records: text lines of an empty state, and the controls (buttons) drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Probe {
    /// One line of an empty state's title or hint (its measured box).
    Text,
    /// A button.
    Control,
}

impl<'a> Canvas<'a> {
    /// A canvas over `list`.
    pub fn new(list: DrawList, atlas: Option<&'a GlyphAtlas>, scale: f32) -> Canvas<'a> {
        Canvas { list, atlas, scale, state: State::default(), stack: Vec::new(), probe: None }
    }
    /// A canvas over a fresh list of `width x height` pixels.
    pub fn with_size(width: f32, height: f32, atlas: Option<&'a GlyphAtlas>, scale: f32) -> Canvas<'a> {
        Self::new(DrawList::new(width, height), atlas, scale)
    }
    /// Starts recording the boxes of empty-state text and of buttons, for tests that fail when text runs under a control.
    pub fn start_probe(&mut self) {
        self.probe = Some(Vec::new());
    }
    /// What the probe recorded so far.
    pub fn probe(&self) -> &[(Probe, CGRect)] {
        self.probe.as_deref().unwrap_or(&[])
    }
    /// The empty-state text lines that intersect a button, as (text box, button): a layout test fails when this is not empty.
    pub fn probe_overlaps(&self) -> Vec<(CGRect, CGRect)> {
        let p = self.probe();
        let hit = |a: &CGRect, b: &CGRect| {
            a.min_x() < b.max_x() && b.min_x() < a.max_x() && a.min_y() < b.max_y() && b.min_y() < a.max_y()
        };
        let mut out = Vec::new();
        for (ka, a) in p {
            for (kb, b) in p {
                if *ka == Probe::Text && *kb == Probe::Control && hit(a, b) {
                    out.push((*a, *b));
                }
            }
        }
        out
    }
    /// Records `r` when a probe runs.
    pub(crate) fn note(&mut self, kind: Probe, r: CGRect) {
        if let Some(p) = self.probe.as_mut() {
            p.push((kind, r));
        }
    }
    /// The atlas, if any.
    pub fn atlas(&self) -> Option<&'a GlyphAtlas> {
        self.atlas
    }
    /// The SemiBold face index (0 without an atlas).
    pub fn semibold(&self) -> usize {
        self.atlas.map_or(0, |a| a.semibold_face())
    }
    /// The Medium face index (0 without an atlas).
    pub fn medium(&self) -> usize {
        self.atlas.map_or(0, |a| a.medium_face())
    }

    // State

    /// Pushes the translation and clip state.
    pub fn save_gstate(&mut self) {
        self.stack.push(self.state);
        self.state.clip_depth = 0;
    }
    /// Pops the state, dropping the clips pushed since the matching save.
    pub fn restore_gstate(&mut self) {
        for _ in 0..self.state.clip_depth {
            self.list.pop_clip();
        }
        self.state = self.stack.pop().unwrap_or_default();
    }
    /// Moves the origin by (x, y) points.
    pub fn translate_by(&mut self, x: f64, y: f64) {
        self.state.tx += x;
        self.state.ty += y;
    }
    /// Intersects the clip with `r` until the matching [`restore_gstate`](Self::restore_gstate).
    pub fn clip_to(&mut self, r: CGRect) {
        let p = self.px(r);
        self.list.push_clip(p);
        self.state.clip_depth += 1;
    }

    /// A rect in points (translation applied) as device pixels.
    pub fn px(&self, r: CGRect) -> Rect {
        let s = self.scale as f64;
        Rect::new(
            ((r.x + self.state.tx) * s) as f32,
            ((r.y + self.state.ty) * s) as f32,
            (r.width * s) as f32,
            (r.height * s) as f32,
        )
    }
    /// A point in points as device pixels.
    pub fn px_point(&self, p: CGPoint) -> (f32, f32) {
        let s = self.scale as f64;
        (((p.x + self.state.tx) * s) as f32, ((p.y + self.state.ty) * s) as f32)
    }

    /// `r` with its four edges moved to whole device pixels when the display scale is fractional (1.25, 1.5, 1.75: Linux
    /// and Windows desktops). At 1.5 every odd point lands half way into a pixel, so a body edge draws a soft half-covered
    /// row and its shadow starts under that row; on the Mac's 1x and 2x the points already sit on pixels. A whole scale
    /// returns `r` unchanged, so the Mac draws exactly what it drew before. A rect that has size keeps at least one pixel.
    pub fn snap_to_device(&self, r: CGRect) -> CGRect {
        let s = f64::from(self.scale);
        if s <= 0.0 || (s - s.round()).abs() < 1e-6 {
            return r;
        }
        let (tx, ty) = (self.state.tx, self.state.ty);
        let edge = |v: f64, t: f64| ((v + t) * s).round() / s - t;
        let (x0, y0) = (edge(r.x, tx), edge(r.y, ty));
        let (x1, y1) = (edge(r.x + r.width, tx), edge(r.y + r.height, ty));
        let keep = |size: f64, snapped: f64| if size > 0.0 { snapped.max(1.0 / s) } else { snapped };
        CGRect::new(x0, y0, keep(r.width, x1 - x0), keep(r.height, y1 - y0))
    }

    // Shapes

    /// Fills `r`.
    pub fn fill(&mut self, r: CGRect, c: Color) {
        let p = self.px(r);
        self.list.fill(p, c, 0.0);
    }
    /// Fills a rounded rect.
    pub fn fill_rounded(&mut self, r: CGRect, radius: f64, c: Color) {
        let p = self.px(r);
        self.list.fill(p, c, radius as f32 * self.scale);
    }
    /// Fills a rounded rect with `c` while `on` (hover on surfaces used hundreds of times a day): an instant state
    /// change, no fade, never asks for a frame.
    pub fn fill_rounded_if(&mut self, r: CGRect, radius: f64, c: Color, on: bool) {
        if on {
            self.fill_rounded(r, radius, c);
        }
    }
    /// Draws what `draw` adds as an opening popover, menu or dialog: it fades in and grows from
    /// [`motion::OPEN_SCALE`] over [`motion::duration::OPEN`]; `rect` (points) is what it grows about, `key` tells
    /// two open things apart (a moved or resized one keeps its level). Input is not delayed: the thing is open and hit-testable from frame one.
    pub fn open_motion(&mut self, rect: CGRect, key: u32, grow: bool, draw: impl FnOnce(&mut Canvas<'a>)) {
        self.open_motion_from(CGPoint::new(rect.mid_x(), rect.mid_y()), key, grow, draw);
    }
    /// [`Self::open_motion`] growing about `origin` (points) instead of the rect center: popovers and menus pass
    /// [`corner_toward`] their trigger so they open out of it.
    pub fn open_motion_from(&mut self, origin: CGPoint, key: u32, grow: bool, draw: impl FnOnce(&mut Canvas<'a>)) {
        let start = self.list.quads().len();
        draw(self);
        let o = self.px(CGRect::new(origin.x, origin.y, 0.0, 0.0));
        let id = motion::key_of(motion::role::OPEN + key, 0.0, 0.0, 0.0, 0.0);
        let level = motion::with_book(|b| b.open_level(id, motion::duration::OPEN, motion::Ease::OutCubic));
        if level < 1.0 {
            let scale = if grow && !motion::reduce_motion() {
                motion::OPEN_SCALE + (1.0 - motion::OPEN_SCALE) * level
            } else {
                1.0
            };
            self.list.transform_from(start, level, scale, (o.x, o.y));
        }
    }
    /// Strokes centered on the edge of `r` like NSBezierPath (half the width inside, half outside).
    pub fn stroke_rounded(&mut self, r: CGRect, radius: f64, width: f64, c: Color) {
        let o = r.inset_by(-width / 2.0, -width / 2.0);
        let p = self.px(o);
        self.list.stroke(p, c, (width as f32 * self.scale).max(0.5), (radius + width / 2.0) as f32 * self.scale);
    }
    /// Fills an ellipse.
    pub fn fill_ellipse(&mut self, r: CGRect, c: Color) {
        let d = self.px(r);
        self.list.fill(d, c, d.w.min(d.h) / 2.0);
    }
    /// Strokes an ellipse centered on its edge.
    pub fn stroke_ellipse(&mut self, r: CGRect, width: f64, c: Color) {
        let d = self.px(r.inset_by(-width / 2.0, -width / 2.0));
        self.list.stroke(d, c, width as f32 * self.scale, d.w.min(d.h) / 2.0);
    }
    /// Image slot `slot` into `r` (the renderer holds the pixels); `source` is the normalized part to show.
    pub fn draw_image_slot(&mut self, slot: usize, r: CGRect, source: [f32; 4], tint: Color) {
        let p = self.px(r);
        self.list.image(p, slot, source, tint);
    }
    /// A straight line with round caps.
    pub fn stroke_line(&mut self, a: CGPoint, b: CGPoint, width: f64, c: Color) {
        let ((x0, y0), (x1, y1)) = (self.px_point(a), self.px_point(b));
        self.list.segment(x0, y0, x1, y1, width as f32 * self.scale, c);
    }
    /// An open polyline (round joins come from the overlapping round caps).
    pub fn stroke_polyline(&mut self, points: &[CGPoint], width: f64, c: Color) {
        for w in points.windows(2) {
            self.stroke_line(w[0], w[1], width, c);
        }
    }
    /// A closed outline.
    pub fn stroke_polygon(&mut self, points: &[CGPoint], width: f64, c: Color) {
        if let Some(first) = points.first() {
            self.stroke_polyline(points, width, c);
            self.stroke_line(points[points.len() - 1], *first, width, c);
        }
    }
    /// A vertical linear gradient from `top` to `bottom`.
    /// shortcut: one quad per device row, upgrade to a gradient quad kind when a panel draws large gradients.
    pub fn fill_vertical_gradient(&mut self, r: CGRect, top: Color, bottom: Color) {
        let d = self.px(r);
        let rows = (d.h.ceil() as i32).max(1);
        for i in 0..rows {
            let t = if rows == 1 { 0.0 } else { i as f32 / (rows - 1) as f32 };
            let mix = |a: f32, b: f32| a + (b - a) * t;
            let c = Color::new(mix(top.r, bottom.r), mix(top.g, bottom.g), mix(top.b, bottom.b), mix(top.a, bottom.a));
            self.list.fill(Rect::new(d.x, d.y + i as f32, d.w, (d.h - i as f32).min(1.0)), c, 0.0);
        }
    }
    /// A soft drop shadow under a rounded rect (CSS/Figma blur `blur`, offset `dy`, y down): a Gaussian edge with
    /// sigma = blur / 2 and peak alpha `c.a`, as the design kit draws it.
    /// known limit: stacked translucent rounded rects approximate the Gaussian (rings of at most 1 pt, each layer's alpha
    /// solved so the stacked result equals the profile), upgrade to a blurred quad kind if it shows.
    /// `opaque_above`: an opaque card is drawn over `r` right after, so each layer is a ring around it.
    pub fn shadow(&mut self, r: CGRect, radius: f64, blur: f64, dy: f64, c: Color, opaque_above: bool) {
        if blur <= 0.0 {
            self.fill_rounded(CGRect::new(r.x, r.y + dy, r.width, r.height), radius, c);
            return;
        }
        let sigma = blur / 2.0;
        // Equal alpha steps, not equal distances: a GPU blends every layer into 8 bits, so a layer under about 0.02 alpha
        // would vanish on a dark ground. Layer j (1 = outermost) ends where the profile crosses (j - 0.5) / m of the peak.
        let m = ((c.a / 0.035).round() as i64).clamp(2, 8);
        for j in 1..=m {
            let peak = c.a * j as f32 / m as f32;
            let before = c.a * (j - 1) as f32 / m as f32;
            let a = if before >= 1.0 { 0.0 } else { 1.0 - (1.0 - peak) / (1.0 - before) };
            if a <= 0.0 {
                continue;
            }
            // Distance outside the offset edge where the Gaussian edge profile equals this level (negative: inside).
            let grow = -sigma * gaussian_quantile((j as f64 - 0.5) / m as f64);
            let rr = CGRect::new(r.x, r.y + dy, r.width, r.height).inset_by(-grow, -grow);
            if rr.width <= 0.0 || rr.height <= 0.0 {
                continue;
            }
            let layer = c.with_alpha(a);
            let rad = (radius + grow).max(0.0);
            // The ring reaches 1 pt past the offset into the card, so the band below the card keeps every layer.
            let width = grow + dy.abs() + 1.0;
            if opaque_above && width <= 0.0 {
                continue;
            }
            if opaque_above && width * 2.0 < rr.width.min(rr.height) {
                let p = self.px(rr);
                self.list.stroke(p, layer, width as f32 * self.scale, rad as f32 * self.scale);
            } else {
                self.fill_rounded(rr, rad, layer);
            }
        }
    }

    // Text

    /// Width and line height of `s` at `size` points.
    pub fn size_of(&self, s: &str, size: f64, face: usize) -> CGSize {
        let Some(atlas) = self.atlas else { return CGSize::default() };
        let p = size as f32 * self.scale;
        CGSize {
            width: (atlas.width_of(s, p, face) / self.scale) as f64,
            height: ((atlas.ascent(p, face) + atlas.descent(p, face)) / self.scale) as f64,
        }
    }

    /// The atlas face of a bundled font family (previews in the look's own font); 0 without an atlas, an unbundled name or
    /// a full atlas.
    pub fn face_family(&self, family: &str, weight: FontWeight, italic: bool) -> usize {
        match (self.atlas, GlyphRasterFont::bundled(family, weight, italic)) {
            (Some(a), Some(f)) => a.face_for(&f),
            _ => 0,
        }
    }

    /// `NSString.draw(at:)`: `p` is the top-left of the line box. Returns the width in points.
    pub fn draw_text(&mut self, s: &str, p: CGPoint, size: f64, c: Color, max_width: f64, face: usize) -> f64 {
        let Some(atlas) = self.atlas else { return 0.0 };
        let ps = size as f32 * self.scale;
        let (x, y) = self.px_point(p);
        let max = if max_width.is_finite() { max_width as f32 * self.scale } else { f32::INFINITY };
        let w = self.list.text(s, x, y + atlas.ascent(ps, face), ps, c, atlas, TextAlign::Left, max, face);
        (w / self.scale) as f64
    }

    /// One line vertically centered in `r`, aligned left, center or right (with `inset` from the side).
    #[allow(clippy::too_many_arguments)]
    pub fn draw_text_in(
        &mut self,
        s: &str,
        r: CGRect,
        size: f64,
        c: Color,
        align: TextAlign,
        inset: f64,
        face: usize,
    ) -> f64 {
        let Some(atlas) = self.atlas else { return 0.0 };
        let p = self.px(r);
        let w = self.list.text_in(s, p, size as f32 * self.scale, c, atlas, align, inset as f32 * self.scale, face);
        (w / self.scale) as f64
    }

    /// A group eyebrow: `s` in capitals, left-aligned and vertically centered in `r`, every letter `tracking` em further
    /// apart (the kit's `.eyebrow`: 10 pt, 600, +0.07 em). Returns the width in points. shortcut: letters are placed one by
    /// one without kerning pairs, fine for capitals at 10 pt; upgrade when the atlas shapes with a letter-spacing.
    pub fn draw_tracked_caps(&mut self, s: &str, r: CGRect, size: f64, c: Color, face: usize, tracking: f64) -> f64 {
        let mut x = r.x;
        for ch in s.to_uppercase().chars() {
            let mut buf = [0u8; 4];
            let g: &str = ch.encode_utf8(&mut buf);
            let w = self.size_of(g, size, face).width;
            if x + w > r.max_x() {
                break;
            }
            self.draw_text_in(g, CGRect::new(x, r.y, w + 1.0, r.height), size, c, TextAlign::Left, 0.0, face);
            x += w + size * tracking;
        }
        x - r.x
    }

    /// Word-wrapped text in `r`; returns the lines drawn.
    pub fn draw_wrapped(&mut self, s: &str, r: CGRect, size: f64, line_height: f64, c: Color) -> usize {
        let lines = self.wrap(s, r.width, size);
        for (i, line) in lines.iter().enumerate() {
            self.draw_text(line, CGPoint { x: r.x, y: r.y + i as f64 * line_height }, size, c, f64::INFINITY, 0);
        }
        lines.len()
    }

    /// Greedy word wrap at `width` points.
    pub fn wrap(&self, s: &str, width: f64, size: f64) -> Vec<String> {
        wrap_lines(s, width, |t| self.size_of(t, size, 0).width)
    }

    /// The first of `options` (longest first) that fits `max_width` whole; `None` when none does (draw nothing: a title
    /// is never cut inside a word). Without an atlas the first option.
    pub fn first_that_fits(&self, options: &[&str], size: f64, face: usize, max_width: f64) -> Option<String> {
        if self.atlas.is_none() {
            return options.first().map(|s| (*s).to_string());
        }
        options.iter().find(|o| self.size_of(o, size, face).width <= max_width).map(|o| (*o).to_string())
    }

    /// `text` cut to `max_width` with a trailing ellipsis at a word boundary ([`crate::glyph_atlas::fit_with_ellipsis`]); unchanged when it fits.
    pub fn ellipsized(&self, text: &str, size: f64, face: usize, max_width: f64) -> String {
        match crate::glyph_atlas::fit_with_ellipsis(text, |t| self.size_of(t, size, face).width <= max_width) {
            Some(t) if t != "\u{2026}" => t,
            _ => String::new(),
        }
    }

    /// `text` cut to `max_width` with the ellipsis in the middle (AppKit `byTruncatingMiddle`); unchanged when it fits.
    pub fn ellipsized_middle(&self, text: &str, size: f64, face: usize, max_width: f64) -> String {
        crate::middle_fit::fit_middle(text, |t| self.size_of(t, size, face).width <= max_width)
    }

    /// `prefix` (kept whole) and `path` cut to `max_width`: whole folders leave the middle, the start and the file name
    /// stay (`to ~/Movies/…/Sequence 01.mp4`; [`crate::middle_fit::fit_path`]). Unchanged when it fits.
    pub fn ellipsized_path(&self, prefix: &str, path: &str, size: f64, face: usize, max_width: f64) -> String {
        let cut =
            crate::middle_fit::fit_path(path, |p| self.size_of(&format!("{prefix}{p}"), size, face).width <= max_width);
        format!("{prefix}{cut}")
    }

    /// The empty-state text block: a 15 pt semibold title in `label`, a wrapped body hint (at most 3 lines) in `label2`,
    /// 4 pt apart, centered in `r`. `reserve` is the height kept free below for a button. Returns the bottom of the hint.
    pub fn draw_empty_state(&mut self, title: &str, hint: &str, r: CGRect, reserve: f64, t: &DrawTheme) -> f64 {
        self.draw_empty_state_art(title, hint, r, reserve, false, t)
    }

    /// [`Canvas::draw_empty_state`] with the mascot above the title when `art` is set, a hook is registered
    /// ([`Canvas::set_empty_state_art`]) and the pane is taller than 150 pt (Swift `drawEmptyState(art:)`,
    /// `Canvas.swift:256`): a 44 pt square, 12 pt above the title.
    pub fn draw_empty_state_art(
        &mut self,
        title: &str,
        hint: &str,
        r: CGRect,
        reserve: f64,
        art: bool,
        t: &DrawTheme,
    ) -> f64 {
        let art_side = 44.0;
        let draw_art = EMPTY_STATE_ART.get().filter(|_| art && r.height > 150.0);
        let art_h = if draw_art.is_some() { art_side + 12.0 } else { 0.0 };
        let (title_h, line_h, gap) = (20.0, 14.0, theme::spacing::XS as f64);
        let w = (r.width - 2.0 * theme::spacing::LG as f64).max(0.0);
        let semibold = self.semibold();
        // A narrow pane wraps the title (two lines at most) instead of cutting it to "No fav...".
        let title_lines: Vec<String> =
            wrap_lines(title, w, |t| self.size_of(t, 15.0, semibold).width).into_iter().take(2).collect();
        let title_block = title_h * title_lines.len().max(1) as f64;
        let lines: Vec<String> = self.wrap(hint, w, theme::type_size::BODY as f64).into_iter().take(3).collect();
        let block =
            art_h + title_block + if lines.is_empty() { 0.0 } else { gap + lines.len() as f64 * line_h } + reserve;
        let mut top = (r.mid_y() - block / 2.0).round();
        if let Some(draw) = draw_art {
            draw(CGRect::new(r.mid_x() - art_side / 2.0, top, art_side, art_side), self);
            top += art_h;
        }
        let x = r.x + theme::spacing::LG as f64;
        for (i, line) in title_lines.iter().enumerate() {
            let y = top + i as f64 * title_h;
            let lw = self.size_of(line, 15.0, semibold).width.min(w);
            self.note(Probe::Text, CGRect::new(r.mid_x() - lw / 2.0, y, lw, title_h));
            self.draw_text_in(line, CGRect::new(x, y, w, title_h), 15.0, t.label(), TextAlign::Center, 0.0, semibold);
        }
        for (i, line) in lines.iter().enumerate() {
            let y = top + title_block + gap + i as f64 * line_h;
            let lw = self.size_of(line, theme::type_size::BODY as f64, 0).width.min(w);
            self.note(Probe::Text, CGRect::new(r.mid_x() - lw / 2.0, y, lw, line_h));
            self.draw_text_in(
                line,
                CGRect::new(x, y, w, line_h),
                theme::type_size::BODY as f64,
                t.label2(),
                TextAlign::Center,
                0.0,
                0,
            );
        }
        top + block - art_h - reserve
    }

    /// Registers the empty-state mascot art (Swift `Canvas.emptyStateArt`, set by the shell host): drawn into a rect.
    pub fn set_empty_state_art(f: fn(CGRect, &mut Canvas)) {
        let _ = EMPTY_STATE_ART.set(f);
    }
}

static EMPTY_STATE_ART: std::sync::OnceLock<fn(CGRect, &mut Canvas)> = std::sync::OnceLock::new();

/// Greedy word wrap of `s` at `width` using `measure` (paragraphs split at newlines, words at spaces).
pub(crate) fn wrap_lines(s: &str, width: f64, measure: impl Fn(&str) -> f64) -> Vec<String> {
    let mut out = Vec::new();
    for para in s.split('\n') {
        let mut line = String::new();
        for word in para.split(' ').filter(|w| !w.is_empty()) {
            let cand = if line.is_empty() { word.to_string() } else { format!("{line} {word}") };
            if !line.is_empty() && measure(&cand) > width {
                out.push(std::mem::replace(&mut line, word.to_string()));
            } else {
                line = cand;
            }
        }
        out.push(line);
    }
    out
}

/// The corner of `frame` nearest to `trigger`: what a menu or popover grows from (never its center).
pub fn corner_toward(frame: CGRect, trigger: CGPoint) -> CGPoint {
    let x = if (trigger.x - frame.min_x()).abs() <= (trigger.x - frame.max_x()).abs() {
        frame.min_x()
    } else {
        frame.max_x()
    };
    let y = if (trigger.y - frame.min_y()).abs() <= (trigger.y - frame.max_y()).abs() {
        frame.min_y()
    } else {
        frame.max_y()
    };
    CGPoint::new(x, y)
}

/// Standard normal CDF (Abramowitz-Stegun 7.1.26 erf, error below 1.5e-7).
fn gaussian_cdf(x: f64) -> f64 {
    let z = x.abs() / std::f64::consts::SQRT_2;
    let t = 1.0 / (1.0 + 0.327_591_1 * z);
    let poly =
        t * (0.254_829_592 + t * (-0.284_496_736 + t * (1.421_413_741 + t * (-1.453_152_027 + t * 1.061_405_429))));
    let erf = 1.0 - poly * (-z * z).exp();
    0.5 * (1.0 + if x < 0.0 { -erf } else { erf })
}

/// Inverse of [`gaussian_cdf`] by bisection (p in 0..1).
fn gaussian_quantile(p: f64) -> f64 {
    let (mut lo, mut hi) = (-8.0, 8.0);
    for _ in 0..50 {
        let mid = 0.5 * (lo + hi);
        if gaussian_cdf(mid) < p { lo = mid } else { hi = mid }
    }
    0.5 * (lo + hi)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::glyph_atlas::tests::atlas;

    #[test]
    fn points_become_pixels_with_translation_and_scale() {
        let mut c = Canvas::with_size(100.0, 100.0, None, 2.0);
        c.translate_by(3.0, 4.0);
        c.fill(CGRect::new(1.0, 1.0, 5.0, 2.0), Color::WHITE);
        assert_eq!(c.list.quads()[0].rect, Rect::new(8.0, 10.0, 10.0, 4.0));
    }

    #[test]
    fn clip_lasts_until_restore() {
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        c.save_gstate();
        c.clip_to(CGRect::new(0.0, 0.0, 10.0, 10.0));
        c.fill(CGRect::new(0.0, 0.0, 50.0, 50.0), Color::WHITE);
        c.restore_gstate();
        c.fill(CGRect::new(0.0, 0.0, 50.0, 50.0), Color::WHITE);
        assert_eq!(c.list.quads()[0].clip, [0.0, 0.0, 10.0, 10.0]);
        assert_eq!(c.list.quads()[1].clip, [0.0, 0.0, 100.0, 100.0]);
    }

    #[test]
    fn stroke_is_centered_on_the_edge_and_never_thinner_than_half_a_pixel() {
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        let (width, hair) = (2.0, 0.1);
        c.stroke_rounded(CGRect::new(10.0, 10.0, 20.0, 20.0), f64::from(theme::radius::SMALL), width, Color::WHITE);
        let q = c.list.quads()[0];
        assert_eq!((q.rect, q.stroke, q.radius), (Rect::new(9.0, 9.0, 22.0, 22.0), 2.0, 5.0));
        c.stroke_rounded(CGRect::new(10.0, 10.0, 20.0, 20.0), f64::from(theme::radius::NONE), hair, Color::WHITE);
        assert_eq!(c.list.quads()[1].stroke, 0.5);
    }

    #[test]
    fn gradient_blends_row_by_row() {
        let mut c = Canvas::with_size(10.0, 10.0, None, 1.0);
        c.fill_vertical_gradient(CGRect::new(0.0, 0.0, 4.0, 3.0), Color::BLACK, Color::WHITE);
        let g: Vec<f32> = c.list.quads().iter().map(|q| q.color.r).collect();
        assert_eq!(g, vec![0.0, 0.5, 1.0]);
    }

    #[test]
    fn wrap_breaks_at_spaces_and_keeps_paragraphs() {
        let lines = wrap_lines("aa bb cc\n\ndd", 5.0, |t| t.len() as f64);
        assert_eq!(lines, vec!["aa bb", "cc", "", "dd"]);
    }

    #[test]
    fn tracked_caps_are_wider_than_plain_caps_by_the_tracking() {
        let a = atlas();
        let mut c = Canvas::with_size(200.0, 40.0, Some(&a), 1.0);
        let r = CGRect::new(0.0, 0.0, 150.0, 16.0);
        let tracked = c.draw_tracked_caps("Video", r, 10.0, Color::WHITE, 0, 0.07);
        let plain = c.size_of("VIDEO", 10.0, 0).width;
        assert!(tracked > plain && tracked < plain + 5.0 * 10.0 * 0.07 + 2.0, "{tracked} vs {plain}");
    }

    #[test]
    fn text_measures_in_points_and_ellipsizes() {
        let a = atlas();
        let c = Canvas::with_size(100.0, 100.0, Some(&a), 2.0);
        let one = Canvas::with_size(100.0, 100.0, Some(&a), 1.0);
        let (w2, w1) = (c.size_of("Timeline", 12.0, 0).width, one.size_of("Timeline", 12.0, 0).width);
        assert!((w2 - w1).abs() < 2.0, "the same text is about as wide in points at 1x and 2x");
        let cut = c.ellipsized("A rather long clip name", 12.0, 0, 50.0);
        assert!(cut.ends_with('…') && c.size_of(&cut, 12.0, 0).width <= 50.0);
        assert_eq!(c.ellipsized("Short", 12.0, 0, 500.0), "Short");
        assert_eq!(c.ellipsized("Long long text", 12.0, 0, 1.0), "");
        let mid = c.ellipsized_middle("A001_C002_long_camera_original_name.mov", 12.0, 0, 120.0);
        assert!(mid.contains('…') && mid.starts_with("A001") && mid.ends_with(".mov"));
        assert!(c.size_of(&mid, 12.0, 0).width <= 120.0);
        assert_eq!(c.ellipsized_middle("Short", 12.0, 0, 500.0), "Short");
        let path = "~/Movies/Client Work/Spring Campaign/Sequence 01.mp4";
        let cut = c.ellipsized_path("to ", path, 12.0, 0, 150.0);
        assert!(cut.starts_with("to ~/") && cut.ends_with("/Sequence 01.mp4") && cut.contains('\u{2026}'), "{cut}");
        assert!(c.size_of(&cut, 12.0, 0).width <= 150.0);
        assert_eq!(c.ellipsized_path("to ", "~/a.mp4", 12.0, 0, 500.0), "to ~/a.mp4");
    }

    #[test]
    fn empty_state_draws_title_and_at_most_three_hint_lines() {
        let a = atlas();
        let mut c = Canvas::with_size(400.0, 300.0, Some(&a), 1.0);
        let bottom = c.draw_empty_state(
            "Nothing here",
            &"word ".repeat(80),
            CGRect::new(0.0, 0.0, 200.0, 200.0),
            0.0,
            &DrawTheme::default(),
        );
        assert!(bottom > 100.0 && bottom < 200.0);
        let rows: std::collections::BTreeSet<i32> = c.list.quads().iter().map(|q| (q.rect.y / 7.0) as i32).collect();
        assert!(rows.len() >= 4);
    }
    #[test]
    fn an_instant_hover_fill_is_whole_at_once_and_asks_for_no_frame() {
        motion::begin_frame(50.0);
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        let r = CGRect::new(10.0, 10.0, 20.0, 20.0);
        c.fill_rounded_if(r, 4.0, Color::WHITE.with_alpha(0.5), true);
        assert_eq!(c.list.quads().first().map(|q| q.color.a), Some(0.5), "full alpha on the first frame");
        assert!(!motion::needs_frame());
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        c.fill_rounded_if(r, 4.0, Color::WHITE, false);
        assert!(c.list.quads().is_empty() && !motion::needs_frame(), "gone at once");
    }
    /// The red value at the middle of a 100 x 100 window with a dialog-like card, drawn at fake time `now`.
    fn dialog_pixel(now: f64, open: bool) -> u8 {
        motion::begin_frame(now);
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        let card = CGRect::new(20.0, 20.0, 60.0, 60.0);
        if open {
            c.open_motion(card, 0, true, |c| {
                c.fill(CGRect::new(0.0, 0.0, 100.0, 100.0), Color::BLACK.with_alpha(0.0));
                c.fill_rounded(card, f64::from(crate::theme::radius::OVERLAY), Color::WHITE);
            });
        }
        let img = crate::software::SoftwareRenderer::render(
            &c.list,
            100,
            100,
            Color::BLACK,
            &crate::software::Sources::default(),
        );
        img.pixels[(50 * 100 + 50) * 4]
    }

    #[test]
    fn a_dialog_opens_through_a_half_faded_frame_and_reopens_after_closing() {
        assert_eq!(dialog_pixel(0.0, true), 0, "frame one: card still invisible, but it is open (input works)");
        let mid = dialog_pixel(0.07, true);
        assert!(mid > 150 && mid < 255, "mid-open pixel {mid}");
        assert_eq!(dialog_pixel(0.3, true), 255);
        assert!(!motion::needs_frame());
        dialog_pixel(0.4, false);
        dialog_pixel(0.5, false);
        assert_eq!(dialog_pixel(0.6, true), 0, "a second open starts again");
    }

    #[test]
    fn the_card_grows_from_its_open_scale() {
        motion::begin_frame(0.0);
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        c.open_motion(CGRect::new(20.0, 20.0, 60.0, 60.0), 0, true, |c| {
            c.fill(CGRect::new(20.0, 20.0, 60.0, 60.0), Color::WHITE)
        });
        let q = c.list.quads()[0];
        assert!((q.rect.w - 60.0 * motion::OPEN_SCALE).abs() < 1e-4 && (q.rect.mid_x() - 50.0).abs() < 1e-4);
    }

    #[test]
    fn reduce_motion_fades_an_open_without_scaling_it() {
        motion::set_reduce_motion(true);
        motion::begin_frame(0.0);
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        let f = CGRect::new(20.0, 20.0, 60.0, 60.0);
        c.open_motion(f, 0, true, |c| c.fill(f, Color::WHITE));
        let q = c.list.quads()[0];
        motion::set_reduce_motion(false);
        assert!((q.rect.w - 60.0).abs() < 1e-4, "no scale");
        assert!(q.color.a < 1.0, "still fading in");
    }

    #[test]
    fn a_popover_grows_from_the_corner_nearest_its_trigger() {
        let f = CGRect::new(20.0, 20.0, 60.0, 40.0);
        assert_eq!(corner_toward(f, CGPoint::new(0.0, 0.0)), CGPoint::new(20.0, 20.0));
        assert_eq!(corner_toward(f, CGPoint::new(100.0, 90.0)), CGPoint::new(80.0, 60.0));
        motion::begin_frame(0.0);
        let mut c = Canvas::with_size(100.0, 100.0, None, 1.0);
        c.open_motion_from(CGPoint::new(20.0, 20.0), 0, true, |c| c.fill(f, Color::WHITE));
        let q = c.list.quads()[0];
        assert!((q.rect.x - 20.0).abs() < 1e-4 && (q.rect.y - 20.0).abs() < 1e-4, "the trigger corner stays put");
        assert!((q.rect.w - 60.0 * motion::OPEN_SCALE).abs() < 1e-4);
    }

    #[test]
    fn digits_measure_equally_wide_so_a_changing_number_does_not_jitter() {
        let c = Canvas::with_size(100.0, 100.0, None, 1.0);
        let one = c.size_of("1111", 13.0, 0).width;
        let zero = c.size_of("0000", 13.0, 0).width;
        let eight = c.size_of("8888", 13.0, 0).width;
        assert!((one - zero).abs() < 1e-6 && (zero - eight).abs() < 1e-6, "{one} {zero} {eight}");
    }
}
