// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PortableRaster/PortableTextRenderer.swift
//! The text raster without Core Graphics: the same drawing steps as `TextRenderer.draw` (spread shadow, group shadow,
//! background box, outside stroke, solid / gradient / karaoke fill, line bars, centered stroke), on `LinearCanvas` from
//! the font files' own outlines. Windows renders titles with it; on the Mac it is compiled for the parity test against
//! Core Text (`PortableTextRasterTests`).
//! Glyphs advance by their variable-font widths, GPOS pair kerning and tracking; weights are the family's named instances,
//! italic is the family's italic file (`PortableFontMatch`).
//! known limit: no ligatures, contextual alternates or right-to-left reordering; upgrade with HarfBuzz.

use crate::caption_karaoke::TextHighlight;
use crate::glyph_raster::Point;
use crate::linear_canvas::{LinearCanvas, MaskOps, PolygonMask};
use crate::portable_fallback::PortableFallback;
use crate::portable_font_match::PortableFontMatch;
use crate::text_decorations::TextDecorations;
use crate::text_layout::{TextLayout, TextLayoutResult, TextRect};
use crate::text_style::{RGBAColor, StrokePosition, TextStroke, TextStyle};
use crate::text_word_rects::TextWordRects;
use sq_core_time::Vec2;
use std::collections::BTreeMap;

/// A drawn block: premultiplied linear-light RGBA floats, `width` x `height`, top row first. Pixel (0, 0) is the
/// top-left of `bounds` (layout space) at `scale`.
#[derive(Clone, Debug, PartialEq)]
pub struct Picture {
    /// Width in pixels.
    pub width: usize,
    /// Height in pixels.
    pub height: usize,
    /// RGBA floats.
    pub pixels: Vec<f32>,
}

/// A rendered text block, the portable counterpart of `TextRaster` (same origin, scale and pixel size).
#[derive(Clone, Debug)]
pub struct Raster {
    /// The layout it was drawn from.
    pub layout: TextLayoutResult,
    /// Pixels per layout unit.
    pub scale: f64,
    /// Left of the raster in layout space (= `layout.inkBounds` origin), unscaled.
    pub origin_x: f64,
    /// Top of the raster in layout space, unscaled.
    pub origin_y: f64,
    /// The picture.
    pub picture: Picture,
}

/// Largest raster side in pixels (as `TextRenderer.maxRasterSide`).
const MAX_RASTER_SIDE: usize = 16_384;

/// Namespace of the portable text renderer.
pub enum PortableTextRenderer {}

impl PortableTextRenderer {
    /// `TextRenderer.render` without Core Graphics: same layout, same raster size and origin; nil for empty text or
    /// ink, or a raster side over `MAX_RASTER_SIDE`.
    /// shortcut: no `crop` (the whole ink box is drawn) and no memory budget; upgrade when Windows plays huge titles.
    pub fn render(
        text: &str,
        style: &TextStyle,
        max_width: Option<f64>,
        box_height: Option<f64>,
        scale: f64,
        highlight: Option<&TextHighlight>,
    ) -> Option<Raster> {
        let highlight = style.drawn_highlight(highlight.cloned());
        let style = style.drawn();
        let layout = TextLayout::layout(text, &style, max_width, box_height);
        let ink = layout.ink_bounds;
        if layout.lines.is_empty()
            || !scale.is_finite()
            || !ink.width.is_finite()
            || !ink.height.is_finite()
            || !ink.x.is_finite()
            || !ink.y.is_finite()
        {
            return None;
        }
        let s = scale.max(0.01);
        let raw_w = (ink.width * s).ceil();
        let raw_h = (ink.height * s).ceil();
        if !raw_w.is_finite()
            || !raw_h.is_finite()
            || raw_w <= 0.0
            || raw_h <= 0.0
            || raw_w > MAX_RASTER_SIDE as f64
            || raw_h > MAX_RASTER_SIDE as f64
        {
            return None;
        }
        let picture = Self::draw(&layout, &style, highlight.as_ref(), &ink, s, (raw_w as usize, raw_h as usize));
        Some(Raster { origin_x: ink.x, origin_y: ink.y, layout, scale: s, picture })
    }

    /// Draws `layout` (made from `style`) over `ink` at scale `s` into a `size` (width, height) picture. `style` and
    /// `highlight` as `TextRenderer.render` passes them (already `drawn`).
    pub fn draw(
        layout: &TextLayoutResult,
        style: &TextStyle,
        highlight: Option<&TextHighlight>,
        ink: &TextRect,
        s: f64,
        size: (usize, usize),
    ) -> Picture {
        let (width, height) = size;
        let only_lit = highlight.is_some_and(|h| h.only_lit);
        let glyphs = GlyphPlacer::new(layout, style, ink, s);
        let mask = |build: &dyn Fn(&mut PolygonMask)| -> Vec<f32> {
            let mut m = PolygonMask::new(width, height);
            build(&mut m);
            m.mask()
        };
        let px = |r: &TextRect| ((r.x - ink.x) * s, (r.y - ink.y) * s, r.width * s, r.height * s);
        let rect_polygon = |r: &TextRect| -> Vec<Vec2> {
            let (x, y, w, h) = px(r);
            vec![Vec2::new(x, y), Vec2::new(x + w, y), Vec2::new(x + w, y + h), Vec2::new(x, y + h)]
        };
        let bars = if only_lit { Vec::new() } else { TextDecorations::bars(layout, style) };
        let all_outlines = glyphs.outlines(None);
        let glyph_fill = mask(&|m| {
            for c in &all_outlines {
                m.add(c);
            }
        });

        let mut picture = LinearCanvas::new(width, height);
        // shortcut: sigma = blur / 2 approximates Core Graphics' kernel (coverage within 5%, PortableTextRasterTests); measure CG to upgrade
        let blur_sigma = |sh: &crate::text_style::TextShadow| sh.blur * s / 2.0;

        // Spread ("Size"): the shadow of the grown glyphs and bars, drawn first; the group itself casts none then.
        let spread_shadow = if only_lit { None } else { style.shadow.filter(|sh| sh.spread > 0.0) };
        if let Some(sh) = spread_shadow {
            let grown = mask(&|m| {
                for c in &all_outlines {
                    m.add(c);
                }
                m.stroke(&all_outlines, sh.spread * s);
                for b in &bars {
                    let r = rect_polygon(&b.rect);
                    m.add_positive(&r);
                    m.stroke(&[r], sh.spread * s);
                }
            });
            let cast = MaskOps::shift(
                &MaskOps::blur(&grown, width, height, blur_sigma(&sh)),
                width,
                height,
                sh.offset_x * s,
                sh.offset_y * s,
            );
            picture.fill(&cast, LinearCanvas::linear(&sh.color));
        }

        let mut group = LinearCanvas::new(width, height);
        if let (Some(bg), Some(r), false) = (style.background, layout.background_rect, only_lit) {
            let words = if TextWordRects::wants_per_word(highlight, style) {
                TextWordRects::rects(layout, style)
            } else {
                Vec::new()
            };
            let boxes = mask(&|m| {
                for w in if words.is_empty() { std::slice::from_ref(&r) } else { &words } {
                    let (x, y, bw, bh) = px(w);
                    m.add_positive(&PolygonMask::rounded_rect(x, y, bw, bh, bg.corner_radius * s));
                }
            });
            group.fill(&boxes, LinearCanvas::linear(&bg.color));
        }

        let stroke: Option<TextStroke> = if only_lit { None } else { style.stroke.filter(|st| st.width > 0.0) };
        let stroke_pass = |group: &mut LinearCanvas, st: &TextStroke| {
            // Outside: twice the width, the inner half is covered by the fill drawn after it. Centered: the width itself.
            let half = (if st.position == StrokePosition::Outside { st.width * 2.0 } else { st.width }) * s / 2.0;
            let m = mask(&|m| {
                m.stroke(&all_outlines, half);
                let polys: Vec<Vec<Vec2>> = bars.iter().map(|b| rect_polygon(&b.rect)).collect();
                m.stroke(&polys, half);
            });
            group.fill(&m, LinearCanvas::linear(&st.color));
        };
        if let Some(st) = stroke.as_ref().filter(|st| st.position == StrokePosition::Outside) {
            stroke_pass(&mut group, st);
        }

        let gradient_block =
            style.gradient.filter(|_| highlight.is_none()).and_then(|g| Self::line_block(layout).map(|b| (g, b)));
        if let Some((g, block)) = gradient_block {
            let (start, end) = g.axis(&block);
            let sx = (start.0 - ink.x) * s;
            let sy = (start.1 - ink.y) * s;
            let dx = (end.0 - start.0) * s;
            let dy = (end.1 - start.1) * s;
            let len2 = (dx * dx + dy * dy).max(1e-12);
            group.fill_with(&glyph_fill, |x, y| {
                let t = (((x as f64 + 0.5 - sx) * dx + (y as f64 + 0.5 - sy) * dy) / len2).clamp(0.0, 1.0);
                // Core Graphics interpolates in the gradient's (sRGB) space, then converts to the linear context.
                let mix = |p: f64, q: f64| p + (q - p) * t;
                LinearCanvas::linear(&RGBAColor::new(
                    mix(g.start.red, g.end.red),
                    mix(g.start.green, g.end.green),
                    mix(g.start.blue, g.end.blue),
                    mix(g.start.alpha, g.end.alpha),
                ))
            });
        } else {
            for (color, outlines) in glyphs.fill_groups(highlight) {
                let m = mask(&|m| {
                    for c in &outlines {
                        m.add(c);
                    }
                });
                group.fill(&m, LinearCanvas::linear(&color));
            }
        }
        for (color, outlines) in glyphs.color_layers(highlight) {
            let m = mask(&|m| {
                for c in &outlines {
                    m.add(c);
                }
            });
            group.fill(&m, LinearCanvas::linear(&color));
        }
        for b in &bars {
            let m = mask(&|m| m.add(&rect_polygon(&b.rect)));
            group.fill(&m, LinearCanvas::linear(&style.line_style(b.style_index).color));
        }
        if let Some(st) = stroke.as_ref().filter(|st| st.position == StrokePosition::Centre) {
            stroke_pass(&mut group, st);
        }

        // The shadow is cast by the whole group.
        if let (Some(sh), false, None) = (style.shadow, only_lit, spread_shadow) {
            let cast = MaskOps::shift(
                &MaskOps::blur(&group.alpha(), width, height, blur_sigma(&sh)),
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

    /// The union of the line boxes (the block a gradient fill spans), nil without lines.
    pub(crate) fn line_block(layout: &TextLayoutResult) -> Option<TextRect> {
        let mut block: Option<TextRect> = None;
        for l in &layout.lines {
            block = Some(match block {
                Some(b) => b.union(&l.rect()),
                None => l.rect(),
            });
        }
        block
    }
}

/// One color glyph layer: its outlines and its color (nil = the text color).
type ColorLayer = (Vec<Vec<Vec2>>, Option<RGBAColor>);

/// A placed glyph.
#[derive(Clone, Debug)]
pub struct Placed {
    /// Index of its line.
    pub line: usize,
    /// UTF-16 offset in its line's text.
    pub offset: i64,
    /// Its outlines (for a color glyph, all layers).
    pub outline: Vec<Vec<Vec2>>,
    /// Set for a color glyph (emoji): its stacked outlines with their colors (nil color = the text color);
    /// `outline` is then all of them (what strokes and shadows use).
    pub layers: Option<Vec<ColorLayer>>,
}

/// Glyph outlines of a layout in raster pixels (y down), with the UTF-16 offset of each glyph in its line's text.
pub struct GlyphPlacer<'a> {
    /// The placed glyphs.
    pub placed: Vec<Placed>,
    layout: &'a TextLayoutResult,
    style: &'a TextStyle,
    /// Per line: the pen (layout space, unscaled) at every UTF-16 offset of the line's text, the end included: the caret
    /// positions `CTLineGetOffsetForStringIndex` gives on the Mac (tracking follows each glyph).
    pub carets: Vec<BTreeMap<i64, f64>>,
}

impl<'a> GlyphPlacer<'a> {
    /// Places every glyph of `layout`.
    pub fn new(layout: &'a TextLayoutResult, style: &'a TextStyle, ink: &TextRect, s: f64) -> GlyphPlacer<'a> {
        let mut out: Vec<Placed> = Vec::new();
        let mut carets: Vec<BTreeMap<i64, f64>> = vec![BTreeMap::new(); layout.lines.len()];
        let shear = (12.0 * std::f64::consts::PI / 180.0).tan();
        for (li, l) in layout.lines.iter().enumerate().filter(|(_, l)| !l.text.is_empty()) {
            let ls = style.line_style(l.style_index);
            let Some(choice) =
                PortableFontMatch::choose(&ls.font_name, ls.weight, ls.italic, ls.size, ls.font_axes.as_ref())
            else {
                continue;
            };
            let font = &choice.font;
            let coords = &choice.coords;
            let unit = ls.size / font.units_per_em as f64; // layout px per font unit
            let mut pen = l.x;
            let baseline = l.y + l.baseline;
            let mut offset: i64 = 0;
            let mut previous: Option<i64> = None;
            let scalars: Vec<char> = l.text.chars().collect();
            let plan = PortableFallback::plan_default(&scalars, font);
            for (idx, scalar) in scalars.iter().enumerate() {
                let (pick, skip) = &plan[idx];
                carets[li].insert(offset, pen);
                let units = scalar.len_utf16() as i64;
                if *skip {
                    offset += units;
                    continue;
                }
                let face = pick.font.as_ref().unwrap_or(font);
                let g = pick.glyph;
                let gcoords: &[f64] = if pick.font.is_none() { coords } else { &[] };
                let gunit = ls.size / face.units_per_em as f64;
                if pick.font.is_none()
                    && let Some(p) = previous
                {
                    pen += font.face.kern(p, g, coords) * unit;
                }
                let k = gunit * s;
                let ox = (pen - ink.x) * s;
                let oy = (baseline - ink.y) * s;
                let italic = if choice.shear { shear } else { 0.0 };
                let shape = |glyph: i64| -> Vec<Vec<Vec2>> {
                    OutlineFonts::polylines(&face.contours(glyph, gcoords), k, |x, y| {
                        Vec2::new(ox + (x + italic * y) * k, oy - y * k)
                    })
                };
                let color_layers =
                    if pick.font.is_some() { face.face.color_glyphs().and_then(|c| c.layers(g)) } else { None };
                if let Some(color) = color_layers {
                    let layers: Vec<ColorLayer> = color.iter().map(|l| (shape(l.glyph), l.color)).collect();
                    out.push(Placed {
                        line: li,
                        offset,
                        outline: layers.iter().flat_map(|l| l.0.iter().cloned()).collect(),
                        layers: Some(layers),
                    });
                } else {
                    // Glyph 0 is the face's "no glyph" box: a scalar no face has draws as nothing, never as a box.
                    let contours = if g == 0 { Vec::new() } else { shape(g) };
                    if !contours.is_empty() {
                        out.push(Placed { line: li, offset, outline: contours, layers: None });
                    }
                }
                pen += pick.advance.map_or_else(|| face.advance_at(g, gcoords), |a| a as f64) * gunit + style.tracking;
                previous = if pick.font.is_none() { Some(g) } else { None };
                offset += units;
            }
            carets[li].insert(offset, pen);
        }
        GlyphPlacer { placed: out, layout, style, carets }
    }

    /// Every glyph outline (`line` nil) or those of one line.
    pub fn outlines(&self, line: Option<usize>) -> Vec<Vec<Vec2>> {
        self.placed
            .iter()
            .filter(|p| line.is_none() || Some(p.line) == line)
            .flat_map(|p| p.outline.iter().cloned())
            .collect()
    }

    /// Glyph outlines grouped by fill color: the line's look color, lit karaoke words in the highlight color; an
    /// `onlyLit` highlight keeps just the lit words.
    pub fn fill_groups(&self, highlight: Option<&TextHighlight>) -> Vec<(RGBAColor, Vec<Vec<Vec2>>)> {
        let paint = self.fill_colors(highlight);
        let mut groups: Vec<(RGBAColor, Vec<Vec<Vec2>>)> = Vec::new();
        for p in self.placed.iter().filter(|p| p.layers.is_none()) {
            let Some(c) = paint(p) else { continue };
            match groups.iter_mut().find(|g| g.0 == c) {
                Some(g) => g.1.extend(p.outline.iter().cloned()),
                None => groups.push((c, p.outline.clone())),
            }
        }
        groups
    }

    /// The layers of the color glyphs (emoji) with their colors; a layer without color takes the glyph's text color.
    pub fn color_layers(&self, highlight: Option<&TextHighlight>) -> Vec<(RGBAColor, Vec<Vec<Vec2>>)> {
        let paint = self.fill_colors(highlight);
        let mut out = Vec::new();
        for p in &self.placed {
            let (Some(layers), Some(text)) = (p.layers.as_ref(), paint(p)) else { continue };
            for (outline, color) in layers {
                if !outline.is_empty() {
                    out.push((color.unwrap_or(text), outline.clone()));
                }
            }
        }
        out
    }

    /// The fill color of one placed glyph (nil: not drawn, an unlit word of an `onlyLit` highlight).
    pub fn fill_colors<'b>(
        &'b self,
        highlight: Option<&'b TextHighlight>,
    ) -> impl Fn(&Placed) -> Option<RGBAColor> + 'b {
        let layout = self.layout;
        let style = self.style;
        let lit: Vec<(i64, i64)> = highlight
            .map(|h| {
                h.words
                    .clone()
                    .filter_map(|i| layout.word_spans.get(i).map(|r| (r.location as i64, r.length as i64)))
                    .collect()
            })
            .unwrap_or_default();
        let only_lit = highlight.is_some_and(|h| h.only_lit);
        move |p: &Placed| {
            let l = &layout.lines[p.line];
            let at = l.location + p.offset - l.marker_length;
            let is_lit = p.offset >= l.marker_length && lit.iter().any(|&(loc, len)| at >= loc && at < loc + len);
            if let (true, Some(h)) = (is_lit, highlight) {
                return Some(h.color);
            }
            if only_lit {
                return None;
            }
            Some(if style.has_line_looks() || highlight.is_some() {
                style.line_style(l.style_index).color
            } else {
                style.color
            })
        }
    }
}

/// Outline helpers for the portable raster (the faces come from `PortableFontMatch`).
pub enum OutlineFonts {}

impl OutlineFonts {
    /// TrueType contours (quadratic) to closed polylines through `map` (font units to pixels).
    pub fn polylines(contours: &[Vec<Point>], k: f64, map: impl Fn(f64, f64) -> Vec2) -> Vec<Vec<Vec2>> {
        let mid = |a: &Point, b: &Point| Point { x: (a.x + b.x) / 2.0, y: (a.y + b.y) / 2.0, on_curve: true };
        let mut out = Vec::new();
        for c in contours.iter().filter(|c| c.len() > 1) {
            let mut pts: Vec<Point> = c.clone();
            if let Some(i) = pts.iter().position(|p| p.on_curve) {
                pts.rotate_left(i);
            } else {
                let m = mid(&pts[0], &pts[1]);
                pts.insert(1, m);
                pts.rotate_left(1);
            }
            let mut poly: Vec<Vec2> = vec![map(pts[0].x, pts[0].y)];
            let mut cur = pts[0];
            let mut ctrl: Option<Point> = None;
            let quad = |poly: &mut Vec<Vec2>, p0: &Point, q: &Point, p1: &Point| {
                let len = ((q.x - p0.x).hypot(q.y - p0.y) + (p1.x - q.x).hypot(p1.y - q.y)) * k;
                let n = ((len / 1.5).ceil() as i64).clamp(1, 64);
                for i in 1..=n {
                    let t = i as f64 / n as f64;
                    let u = 1.0 - t;
                    poly.push(map(
                        u * u * p0.x + 2.0 * u * t * q.x + t * t * p1.x,
                        u * u * p0.y + 2.0 * u * t * q.y + t * t * p1.y,
                    ));
                }
            };
            let tail = pts[1..].iter().chain(std::iter::once(&pts[0]));
            for p in tail {
                if p.on_curve {
                    match ctrl {
                        Some(q) => quad(&mut poly, &cur, &q, p),
                        None => poly.push(map(p.x, p.y)),
                    }
                    cur = *p;
                    ctrl = None;
                } else if let Some(q) = ctrl {
                    let m = mid(&q, p);
                    quad(&mut poly, &cur, &q, &m);
                    cur = m;
                    ctrl = Some(*p);
                } else {
                    ctrl = Some(*p);
                }
            }
            if poly.len() > 1 && poly.first() == poly.last() {
                poly.pop();
            }
            out.push(poly);
        }
        out
    }
}
