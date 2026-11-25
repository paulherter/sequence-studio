// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PortableRaster/PortableAnimatedText.swift

//! Text animators on the portable raster (Windows): the drawing of `TextRenderer.render(… characterStates:)`
//! (TextAnimatorRenderer.swift) without Core Graphics. Every character is its own layer (outside stroke, fill, its pieces
//! of the line bars, centered stroke) with its alpha, its transform (scale about its unit's center, offset) and its blur;
//! the background box stays put, the group casts the shadow (or, with a spread, every character casts its grown shape).

use crate::caption_karaoke::TextHighlight;
use crate::linear_canvas::{LinearCanvas, MaskOps, PolygonMask};
use crate::portable_text_renderer::{GlyphPlacer, Picture, PortableTextRenderer, Raster};
use crate::text_decorations::TextDecorations;
use crate::text_layout::{TextLayout, TextLayoutResult, TextRect};
use crate::text_style::{RGBAColor, StrokePosition, TextStroke, TextStyle};
use crate::text_units_layout::TextUnitsLayoutExt;
use crate::text_word_rects::TextWordRects;
use sq_core_graphics::text_animator_model::{TextCharacterState, TextUnitCharacter, TextUnitState, TextUnits};
use sq_core_model::anchored_animation::TextAnimatorUnit;
use sq_core_time::Vec2;
use std::collections::HashMap;

/// Same value as the private `MAX_RASTER_SIDE` of `portable_text_renderer`.
const MAX_RASTER_SIDE: usize = 16_384;

/// A fill color and the outlines it paints.
type ColoredOutlines = (RGBAColor, Vec<Vec<Vec2>>);

const REST_STATE: TextCharacterState =
    TextCharacterState { in_state: TextUnitState::REST, out_state: TextUnitState::REST, in_unit: None, out_unit: None };

impl PortableTextRenderer {
    /// `render` with one state per `TextUnits::segment_layout` character (missing ones are at rest). The raster
    /// grows to hold every moved or blurred character, as on the Mac; `origin_x/y` say where it starts in layout space.
    /// All-rest states give the static raster's size and origin.
    /// shortcut: no `tight` crop (the whole animated box is drawn every frame); add it when big animated captions are slow.
    pub fn render_with_states(
        text: &str,
        style: &TextStyle,
        max_width: Option<f64>,
        box_height: Option<f64>,
        scale: f64,
        highlight: Option<&TextHighlight>,
        character_states: &[TextCharacterState],
    ) -> Option<Raster> {
        let highlight = style.drawn_highlight(highlight.cloned());
        let style = style.drawn();
        let layout = TextLayout::layout(text, &style, max_width, box_height);
        if layout.lines.is_empty() || !scale.is_finite() {
            return None;
        }
        let s = 0.01_f64.max(scale);
        let ink = layout.ink_bounds;
        if !(ink.width.is_finite() && ink.height.is_finite() && ink.x.is_finite() && ink.y.is_finite()) {
            return None;
        }
        // Outlines once, in pixels from the ink origin; the animated bounds only move them.
        let glyphs = GlyphPlacer::new(&layout, &style, &ink, s);
        let geo = PortableAnimatedGeometry::new(&layout, &style, &glyphs, character_states);
        let b = geo.bounds;
        if !(b.width.is_finite() && b.height.is_finite() && b.x.is_finite() && b.y.is_finite()) {
            return None;
        }
        let raw_w = (b.width * s).ceil();
        let raw_h = (b.height * s).ceil();
        let max_side = MAX_RASTER_SIDE as f64;
        if !(raw_w > 0.0 && raw_h > 0.0 && raw_w <= max_side && raw_h <= max_side) {
            return None;
        }
        let picture = Self::draw_animated(
            &layout,
            &style,
            highlight.as_ref(),
            &glyphs,
            &geo,
            ink,
            s,
            raw_w as usize,
            raw_h as usize,
        );
        Some(Raster { layout, scale: s, origin_x: b.x, origin_y: b.y, picture })
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_animated(
        layout: &TextLayoutResult,
        style: &TextStyle,
        highlight: Option<&TextHighlight>,
        glyphs: &GlyphPlacer,
        geo: &PortableAnimatedGeometry,
        ink: TextRect,
        s: f64,
        width: usize,
        height: usize,
    ) -> Picture {
        let only_lit = highlight.is_some_and(|h| h.only_lit);
        let b = geo.bounds;
        let full = PixelBox { x: 0, y: 0, width: width as i64, height: height as i64 };
        let transform = |c: Option<usize>| c.map(|c| geo.transforms[c]).unwrap_or(TextAffine::IDENTITY);
        // A point of the glyph placer (pixels from the ink origin) through character `c`'s transform into raster pixels.
        let place = |c: Option<usize>, p: Vec2| {
            let q = transform(c).apply(Vec2::new(p.x / s + ink.x, p.y / s + ink.y));
            Vec2::new((q.x - b.x) * s, (q.y - b.y) * s)
        };
        // A rectangle in layout space through character `c`'s transform into raster pixels.
        let rect_polygon = |r: &TextRect, c: Option<usize>| -> Vec<Vec2> {
            let t = transform(c);
            [Vec2::new(r.x, r.y), Vec2::new(r.max_x(), r.y), Vec2::new(r.max_x(), r.max_y()), Vec2::new(r.x, r.max_y())]
                .iter()
                .map(|&p| {
                    let q = t.apply(p);
                    Vec2::new((q.x - b.x) * s, (q.y - b.y) * s)
                })
                .collect()
        };

        // Glyphs and line-bar pieces of every character.
        let paint = glyphs.fill_colors(highlight);
        let mut outlines: HashMap<usize, Vec<Vec<Vec2>>> = HashMap::new();
        let mut fills: HashMap<usize, Vec<ColoredOutlines>> = HashMap::new();
        // Bitmap emoji per character: they are one unit with their character's transform, opacity and blur.
        let mut bitmaps: HashMap<usize, Vec<&crate::portable_text_renderer::PlacedBitmap>> = HashMap::new();
        for p in &glyphs.placed {
            let Some(&c) = geo.line_maps[p.line].get(&p.offset) else { continue };
            if let (Some(b), Some(_)) = (&p.bitmap, paint(p)) {
                bitmaps.entry(c).or_default().push(b);
            }
            let o: Vec<Vec<Vec2>> =
                p.outline.iter().map(|poly| poly.iter().map(|&q| place(Some(c), q)).collect()).collect();
            outlines.entry(c).or_default().extend(o.iter().cloned());
            if let Some(color) = paint(p) {
                fills.entry(c).or_default().push((color, o));
            }
        }
        let bars = if only_lit { Vec::new() } else { TextDecorations::bars(layout, style) };
        let mut order: HashMap<usize, Vec<usize>> = HashMap::new();
        if !bars.is_empty() {
            for ch in &geo.units.characters {
                order.entry(ch.line).or_default().push(ch.index);
            }
            for list in order.values_mut() {
                list.sort_by(|&a, &b| geo.character_rects[a].x.total_cmp(&geo.character_rects[b].x));
            }
        }
        // The bar pieces of character `c` in layout space (the Mac's `pieces`): a piece reaches to the next character on
        // its line, the first back to the bar's start, the last to its end, so the bar has no gaps.
        let pieces = |c: usize| -> Vec<(TextRect, usize)> {
            let line = geo.units.characters[c].line;
            let Some(list) = order.get(&line) else { return Vec::new() };
            let Some(pos) = list.iter().position(|&i| i == c) else { return Vec::new() };
            let r = geo.character_rects[c];
            bars.iter()
                .filter(|bar| bar.line_index == line)
                .map(|bar| {
                    let x0 = if pos == 0 { bar.rect.x.min(r.x) } else { r.x };
                    let x1 = if pos == list.len() - 1 {
                        bar.rect.max_x().max(r.max_x())
                    } else {
                        geo.character_rects[list[pos + 1]].x
                    };
                    (TextRect::new(x0, bar.rect.y, 0.0_f64.max(x1 - x0), bar.rect.height), bar.style_index)
                })
                .collect()
        };

        let mut picture = LinearCanvas::new(width, height);
        let blur_sigma = |v: f64| v * s / 2.0; // as the static raster (Core Graphics' shadow blur)
        let count = geo.units.characters.len();

        // Spread ("Size"): every character casts the shadow of its grown shape, at its opacity; the group casts none then.
        let spread_shadow = if only_lit { None } else { style.shadow.filter(|sh| sh.spread > 0.0) };
        if let Some(sh) = spread_shadow {
            // known limit: the characters' grown shapes are laid together (source-over at their opacity) and blurred once,
            // where Core Graphics blurs each character's shadow on its own (the same where they do not overlap).
            let mut cast = vec![0.0f32; width * height];
            for c in 0..count {
                let st = geo.state(c);
                let Some(o) = outlines.get(&c).filter(|_| st.opacity() > 0.0) else { continue };
                let bar_rects: Vec<Vec<Vec2>> = pieces(c).iter().map(|p| rect_polygon(&p.0, Some(c))).collect();
                let k = geo.transforms[c].scale();
                let mut m = PolygonMask::new(width, height);
                for p in o {
                    m.add(p);
                }
                m.stroke(o, sh.spread * s * k);
                for r in &bar_rects {
                    m.add_positive(r);
                    m.stroke(std::slice::from_ref(r), sh.spread * s * k);
                }
                let a = 1.0_f64.min(st.opacity()) as f32;
                for (i, v) in m.mask().into_iter().enumerate() {
                    if v > 0.0 {
                        cast[i] += v * a * (1.0 - cast[i]);
                    }
                }
            }
            let blurred = MaskOps::shift(
                &MaskOps::blur(&cast, width, height, blur_sigma(sh.blur)),
                width,
                height,
                sh.offset_x * s,
                sh.offset_y * s,
            );
            picture.fill(&blurred, LinearCanvas::linear(&sh.color));
        }

        let mut group = LinearCanvas::new(width, height);
        if let (Some(bg), Some(r), false) = (style.background, layout.background_rect, only_lit) {
            let words = if TextWordRects::wants_per_word(highlight, style) {
                TextWordRects::rects(layout, style)
            } else {
                Vec::new()
            };
            let mut m = PolygonMask::new(width, height);
            let boxes = if bg.follow_reveal {
                // The box shows the words that are in: a word counts as far as its most visible character.
                let mut amounts = vec![0.0_f64; layout.word_spans.len().max(1)];
                for c in &geo.units.characters {
                    if let Some(a) = amounts.get_mut(c.word) {
                        *a = a.max(geo.state(c.index).opacity());
                    }
                }
                vec![TextWordRects::reveal_pill(layout, style, &amounts).unwrap_or(r)]
            } else if words.is_empty() {
                vec![r]
            } else {
                words
            };
            for w in &boxes {
                m.add_positive(&PolygonMask::rounded_rect(
                    (w.x - b.x) * s,
                    (w.y - b.y) * s,
                    w.width * s,
                    w.height * s,
                    bg.corner_radius * s,
                ));
            }
            group.fill(&m.mask(), LinearCanvas::linear(&bg.color));
        }

        // One layer per character (stroke and fill together, so a fading character never shows its outline through its
        // fill), drawn only over the pixels it can reach.
        let stroke: Option<TextStroke> = if only_lit { None } else { style.stroke.filter(|st| st.width > 0.0) };
        for c in 0..count {
            let st = geo.state(c);
            let bar_pieces = pieces(c);
            let o: Vec<Vec<Vec2>> = outlines.get(&c).cloned().unwrap_or_default();
            let emoji = bitmaps.get(&c).map(Vec::as_slice).unwrap_or_default();
            if !(st.opacity() > 0.0 && (outlines.contains_key(&c) || !bar_pieces.is_empty() || !emoji.is_empty())) {
                continue;
            }
            let blur = st.in_state.blur.max(st.out_state.blur);
            let k = geo.transforms[c].scale();
            let bar_polys: Vec<(Vec<Vec2>, usize)> =
                bar_pieces.iter().map(|p| (rect_polygon(&p.0, Some(c)), p.1)).collect();
            // The pixels this character can paint: its outlines and bars, grown by the stroke and the blur.
            let reach = stroke
                .map(|sk| if sk.position == StrokePosition::Outside { sk.width } else { sk.width / 2.0 })
                .unwrap_or(0.0)
                * s
                * k
                + blur * s * 1.5
                + 2.0;
            let emoji_boxes: Vec<Vec<Vec2>> =
                emoji.iter().map(|b| b.corners().into_iter().map(|q| place(Some(c), q)).collect()).collect();
            let all: Vec<Vec<Vec2>> = o
                .iter()
                .cloned()
                .chain(bar_polys.iter().map(|p| p.0.clone()))
                .chain(emoji_boxes.iter().cloned())
                .collect();
            let Some(bx) = PixelBox::around(&all, reach).and_then(|b| b.clipped_to(&full)) else { continue };
            let shifted = |ps: &[Vec<Vec2>]| -> Vec<Vec<Vec2>> {
                ps.iter()
                    .map(|poly| poly.iter().map(|q| Vec2::new(q.x - bx.x as f64, q.y - bx.y as f64)).collect())
                    .collect()
            };
            let mask = |build: &dyn Fn(&mut PolygonMask)| -> Vec<f32> {
                let mut m = PolygonMask::new(bx.width as usize, bx.height as usize);
                build(&mut m);
                m.mask()
            };
            let mut layer = LinearCanvas::new(bx.width as usize, bx.height as usize);
            let stroke_pass = |layer: &mut LinearCanvas, sk: &TextStroke| {
                let half =
                    (if sk.position == StrokePosition::Outside { sk.width * 2.0 } else { sk.width }) * s * k / 2.0;
                let bar_only: Vec<Vec<Vec2>> = bar_polys.iter().map(|p| p.0.clone()).collect();
                let m = mask(&|m| {
                    m.stroke(&shifted(&o), half);
                    m.stroke(&shifted(&bar_only), half);
                });
                layer.fill(&m, LinearCanvas::linear(&sk.color));
            };
            if let Some(sk) = stroke.as_ref().filter(|sk| sk.position == StrokePosition::Outside) {
                stroke_pass(&mut layer, sk);
            }
            if let Some(list) = fills.get(&c) {
                for (color, polys) in list {
                    let m = mask(&|m| {
                        for p in shifted(polys) {
                            m.add(&p);
                        }
                    });
                    layer.fill(&m, LinearCanvas::linear(color));
                }
            }
            if let Some(inv) = geo.transforms[c].inverse() {
                for b in emoji {
                    layer.draw_bitmap_mapped(&b.bmp, |lx, ly| {
                        // layer pixel -> raster pixel -> layout space -> before the character's transform -> ink pixels
                        let q = inv.apply(Vec2::new((lx + bx.x as f64) / s + geo.bounds.x, (ly + bx.y as f64) / s + geo.bounds.y));
                        ((q.x - ink.x) * s - b.x, (q.y - ink.y) * s - b.y)
                    });
                }
            }
            for (poly, si) in &bar_polys {
                let m = mask(&|m| m.add(&shifted(std::slice::from_ref(poly))[0]));
                layer.fill(&m, LinearCanvas::linear(&style.line_style(*si).color));
            }
            if let Some(sk) = stroke.as_ref().filter(|sk| sk.position == StrokePosition::Centre) {
                stroke_pass(&mut layer, sk);
            }
            if blur > 0.0 {
                layer.blur(blur_sigma(blur));
            }
            group.composite(&layer, &bx, 1.0_f64.min(st.opacity()) as f32);
        }

        // The group's shadow (no spread): cast by everything painted.
        if let (Some(sh), false, None) = (style.shadow, only_lit, spread_shadow) {
            let cast = MaskOps::shift(
                &MaskOps::blur(&group.alpha(), width, height, blur_sigma(sh.blur)),
                width,
                height,
                sh.offset_x * s,
                sh.offset_y * s,
            );
            picture.fill(&cast, LinearCanvas::linear(&sh.color));
        }
        group.place(&picture);
        Picture { width, height, pixels: group.pixels }
    }
}

/// A pixel rectangle of a raster.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PixelBox {
    /// Left.
    pub x: i64,
    /// Top.
    pub y: i64,
    /// Width.
    pub width: i64,
    /// Height.
    pub height: i64,
}

impl PixelBox {
    /// The whole pixels around `polygons`, grown by `margin`; `None` without points.
    pub fn around(polygons: &[Vec<Vec2>], margin: f64) -> Option<PixelBox> {
        let (mut lo, mut hi) =
            (Vec2::new(f64::INFINITY, f64::INFINITY), Vec2::new(f64::NEG_INFINITY, f64::NEG_INFINITY));
        for p in polygons {
            for q in p {
                lo = Vec2::new(lo.x.min(q.x), lo.y.min(q.y));
                hi = Vec2::new(hi.x.max(q.x), hi.y.max(q.y));
            }
        }
        if !(lo.x.is_finite() && hi.x.is_finite() && lo.y.is_finite() && hi.y.is_finite()) {
            return None;
        }
        let x0 = (lo.x - margin).floor() as i64;
        let y0 = (lo.y - margin).floor() as i64;
        let x1 = (hi.x + margin).ceil() as i64;
        let y1 = (hi.y + margin).ceil() as i64;
        Some(PixelBox { x: x0, y: y0, width: x1 - x0, height: y1 - y0 })
    }

    /// The part inside `o`; `None` when nothing is left.
    pub fn clipped_to(&self, o: &PixelBox) -> Option<PixelBox> {
        let x0 = self.x.max(o.x);
        let y0 = self.y.max(o.y);
        let x1 = (self.x + self.width).min(o.x + o.width);
        let y1 = (self.y + self.height).min(o.y + o.height);
        if x1 > x0 && y1 > y0 { Some(PixelBox { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }) } else { None }
    }
}

impl LinearCanvas {
    /// Gaussian blur of every (premultiplied) channel, zero outside.
    pub fn blur(&mut self, sigma: f64) {
        let n = self.width * self.height;
        for k in 0..4 {
            let channel: Vec<f32> = (0..n).map(|i| self.pixels[i * 4 + k]).collect();
            let out = MaskOps::blur(&channel, self.width, self.height, sigma);
            for (i, v) in out.iter().enumerate().take(n) {
                self.pixels[i * 4 + k] = *v;
            }
        }
    }

    /// Source-over of `layer` (lying at `bx`) at `opacity`.
    pub fn composite(&mut self, layer: &LinearCanvas, bx: &PixelBox, opacity: f32) {
        for y in 0..bx.height {
            for x in 0..bx.width {
                let si = ((y * bx.width + x) * 4) as usize;
                let a = layer.pixels[si + 3] * opacity;
                if a <= 0.0 {
                    continue;
                }
                let di = (((bx.y + y) * self.width as i64 + bx.x + x) * 4) as usize;
                let keep = 1.0 - a;
                for c in 0..3 {
                    self.pixels[di + c] = layer.pixels[si + c] * opacity + self.pixels[di + c] * keep;
                }
                self.pixels[di + 3] = a + self.pixels[di + 3] * keep;
            }
        }
    }
}

/// An affine map of layout space (column vectors: x' = a x + c y + tx, y' = b x + d y + ty), the `CGAffineTransform`
/// the Mac builds per character.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextAffine {
    /// x scale.
    pub a: f64,
    /// y shear.
    pub b: f64,
    /// x shear.
    pub c: f64,
    /// y scale.
    pub d: f64,
    /// x offset.
    pub tx: f64,
    /// y offset.
    pub ty: f64,
}

impl TextAffine {
    /// The identity map.
    pub const IDENTITY: TextAffine = TextAffine { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0 };

    /// The image of `p`.
    pub fn apply(&self, p: Vec2) -> Vec2 {
        Vec2::new(self.a * p.x + self.c * p.y + self.tx, self.b * p.x + self.d * p.y + self.ty)
    }

    /// The map that undoes this one; `None` when it flattens the plane.
    pub fn inverse(&self) -> Option<TextAffine> {
        let det = self.a * self.d - self.b * self.c;
        if det.abs() < 1e-12 {
            return None;
        }
        let (a, b, c, d) = (self.d / det, -self.b / det, -self.c / det, self.a / det);
        Some(TextAffine { a, b, c, d, tx: -(a * self.tx + c * self.ty), ty: -(b * self.tx + d * self.ty) })
    }

    /// `self` first, then `o` (`CGAffineTransform.concatenating`).
    pub fn then(&self, o: &TextAffine) -> TextAffine {
        TextAffine {
            a: self.a * o.a + self.b * o.c,
            b: self.a * o.b + self.b * o.d,
            c: self.c * o.a + self.d * o.c,
            d: self.c * o.b + self.d * o.d,
            tx: self.tx * o.a + self.ty * o.c + o.tx,
            ty: self.tx * o.b + self.ty * o.d + o.ty,
        }
    }

    /// The uniform scale it applies (scales about a point only).
    pub fn scale(&self) -> f64 {
        (self.a * self.a + self.b * self.b).sqrt()
    }

    /// Scale about `p`, then move by `offset`: the unit state's move.
    pub fn move_state(st: &TextUnitState, about: Vec2) -> TextAffine {
        TextAffine {
            a: st.scale,
            b: 0.0,
            c: 0.0,
            d: st.scale,
            tx: about.x + st.offset_x - st.scale * about.x,
            ty: about.y + st.offset_y - st.scale * about.y,
        }
    }

    /// The bounds of the rect's image.
    pub fn apply_rect(&self, r: &TextRect) -> TextRect {
        let ps: Vec<Vec2> = [
            Vec2::new(r.x, r.y),
            Vec2::new(r.max_x(), r.y),
            Vec2::new(r.max_x(), r.max_y()),
            Vec2::new(r.x, r.max_y()),
        ]
        .iter()
        .map(|&p| self.apply(p))
        .collect();
        let lo = ps[1..].iter().fold(ps[0], |m, q| Vec2::new(m.x.min(q.x), m.y.min(q.y)));
        let hi = ps[1..].iter().fold(ps[0], |m, q| Vec2::new(m.x.max(q.x), m.y.max(q.y)));
        TextRect::new(lo.x, lo.y, hi.x - lo.x, hi.y - lo.y)
    }
}

/// `AnimatedGeometry` without Core Text: character advance boxes from the portable pen, unit centers, per-character
/// transforms and the raster bounds (the ink box grown by every moved or blurred character).
pub struct PortableAnimatedGeometry {
    /// The characters.
    pub units: TextUnits,
    /// One state per character.
    pub states: Vec<TextCharacterState>,
    /// One transform per character.
    pub transforms: Vec<TextAffine>,
    /// The raster bounds.
    pub bounds: TextRect,
    /// The advance box of every character in layout space.
    pub character_rects: Vec<TextRect>,
    /// Per line: line-local UTF-16 offset -> character index (whitespace has none).
    pub line_maps: Vec<HashMap<i64, usize>>,
}

impl PortableAnimatedGeometry {
    /// Builds the geometry for `states` (missing ones are at rest).
    pub fn new(
        layout: &TextLayoutResult,
        style: &TextStyle,
        glyphs: &GlyphPlacer,
        states: &[TextCharacterState],
    ) -> Self {
        let units = TextUnits::segment_layout(layout);
        let mut maps: Vec<HashMap<i64, usize>> = vec![HashMap::new(); layout.lines.len()];
        let mut rects: Vec<TextRect> = Vec::new();
        for c in &units.characters {
            let l = &layout.lines[c.line];
            let o = c.range.location as i64 - l.location + l.marker_length;
            for k in 0..c.range.length as i64 {
                maps[c.line].insert(o + k, c.index);
            }
            let carets = &glyphs.carets[c.line];
            let x0 = carets.get(&o).copied().unwrap_or(l.x);
            let x1 = carets.get(&(o + c.range.length as i64)).copied().unwrap_or(x0);
            rects.push(TextRect::new(x0.min(x1), l.y, (x1 - x0).abs(), l.height));
        }

        let mut unit_rects: [Option<HashMap<usize, TextRect>>; 3] = [None, None, None];
        let mut centre = |c: &TextUnitCharacter, unit: TextAnimatorUnit| -> Vec2 {
            let slot = match unit {
                TextAnimatorUnit::Character => 0,
                TextAnimatorUnit::Word => 1,
                TextAnimatorUnit::Line => 2,
            };
            let map = unit_rects[slot].get_or_insert_with(|| {
                let mut r: HashMap<usize, TextRect> = HashMap::new();
                for ch in &units.characters {
                    let i = units.index_of(ch, unit);
                    let merged = match r.get(&i) {
                        Some(prev) => prev.union(&rects[ch.index]),
                        None => rects[ch.index],
                    };
                    r.insert(i, merged);
                }
                r
            });
            let r = map.get(&units.index_of(c, unit)).copied().unwrap_or(rects[c.index]);
            Vec2::new(r.x + r.width / 2.0, r.y + r.height / 2.0)
        };

        let mut tr: Vec<TextAffine> = Vec::new();
        let mut b = layout.ink_bounds;
        for c in &units.characters {
            let st = states.get(c.index).copied().unwrap_or(REST_STATE);
            let mut t = TextAffine::IDENTITY;
            if let (Some(u), false) = (st.in_unit, st.in_state.is_rest()) {
                t = t.then(&TextAffine::move_state(&st.in_state, centre(c, u)));
            }
            if let (Some(u), false) = (st.out_unit, st.out_state.is_rest()) {
                t = t.then(&TextAffine::move_state(&st.out_state, centre(c, u)));
            }
            tr.push(t);
            if st.opacity() <= 0.0 {
                continue;
            }
            let blur = st.in_state.blur.max(st.out_state.blur);
            if t == TextAffine::IDENTITY && blur <= 0.0 {
                continue;
            }
            let m = t.apply_rect(&TextLayout::ink_rect(&rects[c.index], style).expanded_by(blur * 1.5 + 1.0));
            if m.width > 0.0 && m.height > 0.0 && m.width.is_finite() && m.height.is_finite() {
                b = b.union(&m);
            }
        }
        PortableAnimatedGeometry {
            units,
            states: states.to_vec(),
            transforms: tr,
            bounds: b,
            character_rects: rects,
            line_maps: maps,
        }
    }

    /// The state of character `c` (at rest when missing).
    pub fn state(&self, c: usize) -> TextCharacterState {
        self.states.get(c).copied().unwrap_or(REST_STATE)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts::test_fonts_root;
    use crate::portable_font_match::set_fonts_root;

    fn style() -> TextStyle {
        set_fonts_root(&test_fonts_root());
        TextStyle::new("Inter", 80.0, crate::text_style::FontWeight::Bold, RGBAColor::WHITE)
    }

    #[test]
    fn all_rest_states_give_the_static_raster() {
        let s = style();
        let plain = PortableTextRenderer::render("Hi", &s, None, None, 1.0, None);
        let animated = PortableTextRenderer::render_with_states("Hi", &s, None, None, 1.0, None, &[]);
        let (Some(a), Some(b)) = (plain, animated) else { panic!("rasters") };
        assert_eq!((a.picture.width, a.picture.height), (b.picture.width, b.picture.height));
        assert_eq!((a.origin_x, a.origin_y), (b.origin_x, b.origin_y));
    }

    #[test]
    fn a_moved_character_grows_the_raster() {
        let s = style();
        let moved = TextCharacterState {
            in_state: TextUnitState { offset_y: -100.0, ..TextUnitState::REST },
            out_state: TextUnitState::REST,
            in_unit: Some(TextAnimatorUnit::Character),
            out_unit: None,
        };
        let rest = PortableTextRenderer::render_with_states("Hi", &s, None, None, 1.0, None, &[]);
        let up = PortableTextRenderer::render_with_states("Hi", &s, None, None, 1.0, None, &[moved]);
        let (Some(rest), Some(up)) = (rest, up) else { panic!("rasters") };
        assert!(up.picture.height > rest.picture.height);
        assert!(up.origin_y < rest.origin_y);
    }

    #[test]
    fn affine_composes_scale_about_a_point_and_offset() {
        let st = TextUnitState { scale: 2.0, offset_x: 5.0, ..TextUnitState::REST };
        let t = TextAffine::move_state(&st, Vec2::new(10.0, 10.0));
        let p = t.apply(Vec2::new(10.0, 10.0));
        assert_eq!((p.x, p.y), (15.0, 10.0));
        assert_eq!(t.scale(), 2.0);
        let r = t.apply_rect(&TextRect::new(10.0, 10.0, 2.0, 2.0));
        assert_eq!((r.width, r.height), (4.0, 4.0));
        assert_eq!(TextAffine::IDENTITY.then(&t), t);
    }

    #[test]
    fn pixel_box_grows_and_clips() {
        let poly = vec![vec![Vec2::new(2.2, 3.7), Vec2::new(5.1, 6.0)]];
        assert_eq!(PixelBox::around(&poly, 1.0), Some(PixelBox { x: 1, y: 2, width: 6, height: 5 }));
        assert!(PixelBox::around(&[], 1.0).is_none());
        let full = PixelBox { x: 0, y: 0, width: 4, height: 4 };
        assert_eq!(
            PixelBox { x: 2, y: 2, width: 9, height: 9 }.clipped_to(&full),
            Some(PixelBox { x: 2, y: 2, width: 2, height: 2 })
        );
        assert!(PixelBox { x: 9, y: 9, width: 2, height: 2 }.clipped_to(&full).is_none());
    }

    /// A bitmap emoji is one character of the animator: it moves and fades with its character like a letter.
    #[test]
    fn a_bitmap_emoji_moves_and_fades_with_its_character() {
        let _lock = crate::portable_fallback::FALLBACK_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let Some(font) = crate::portable_fallback::PortableFallback::system_bitmap_emoji() else {
            eprintln!("skipped: no color emoji font");
            return;
        };
        crate::portable_fallback::PortableFallback::set_bitmap_emoji(Some(font));
        let s = style();
        let state = |opacity: f64, offset_x: f64| TextCharacterState {
            in_state: TextUnitState { opacity, offset_x, ..TextUnitState::REST },
            out_state: TextUnitState::REST,
            in_unit: Some(TextAnimatorUnit::Character),
            out_unit: None,
        };
        // (mean x in layout space, summed alpha) of the colored pixels
        let measure = |st: TextCharacterState| {
            let r = PortableTextRenderer::render_with_states("\u{1F525}", &s, None, None, 1.0, None, &[st]).unwrap();
            let p = &r.picture;
            let (mut sx, mut n, mut a) = (0.0_f64, 0.0_f64, 0.0_f64);
            for y in 0..p.height {
                for x in 0..p.width {
                    let c = &p.pixels[(y * p.width + x) * 4..][..4];
                    if c[3] > 0.0 && c[0] > c[2] + 0.1 * c[3] {
                        sx += x as f64 + r.origin_x;
                        n += 1.0;
                        a += f64::from(c[3]);
                    }
                }
            }
            (sx / n.max(1.0), a, n)
        };
        let (x0, a0, n0) = measure(state(1.0, 0.0));
        let (x1, a1, _) = measure(state(1.0, 120.0));
        let (_, a2, _) = measure(state(0.5, 0.0));
        assert!(n0 > 500.0, "the emoji drew {n0} colored pixels");
        assert!((x1 - x0 - 120.0).abs() < 8.0, "moved by {}", x1 - x0);
        assert!((a1 / a0 - 1.0).abs() < 0.05, "same ink after the move: {a0} vs {a1}");
        assert!((a2 / a0 - 0.5).abs() < 0.08, "half opacity: {a0} vs {a2}");
    }
}
