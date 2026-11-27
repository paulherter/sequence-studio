//! The Lottie rasterizer in pure Rust on tiny-skia (BSD-3-Clause): shape layers (rect, ellipse, star with roundness, path,
//! fill, stroke with dashes, linear and radial gradients with highlights, trim paths (simultaneous and individually), merge
//! paths, round corners, repeaters, groups), solids, PNG and JPEG image layers, text layers, null parents, precomps (clipped to their
//! size) with time remap, layer transforms with parenting, skew and auto-orient, opacity, bezier-eased keyframes with spatial
//! motion paths, masks (add, subtract, intersect, inverted), track mattes and a small expression subset (`lottie_expr`).
//!
//! Limits (skipped, never fatal): 3D, text animators, zig-zag and pucker/bloat modifiers, layer effects.

use crate::lottie_geometry::{ellipse, path_from_flat, rect, star, trim, trim_individually};
use crate::lottie_modifiers::round_corners;
use crate::lottie_props::{eval, num, scalar};
use crate::lottie_renderer::{LottieDrawing, LottieEngine};
use serde_json::Value;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;
use tiny_skia::{
    BlendMode, Color, FillRule, FilterQuality, GradientStop, IntSize, LineCap, LineJoin, LinearGradient, Mask, Paint,
    Path, PathBuilder, Pixmap, PixmapPaint, Point, RadialGradient, Rect, SpreadMode, Stroke, StrokeDash, Transform,
};

/// Opens documents with the tiny-skia rasterizer.
pub struct SkiaEngine;

/// Namespace for the ready-made renderer.
pub struct LottieRendererSkia;

impl LottieRendererSkia {
    /// A `LottieRenderer` over the tiny-skia engine.
    pub fn renderer() -> crate::lottie_document::LottieRenderer {
        crate::lottie_document::LottieRenderer::new(Box::new(SkiaEngine))
    }
}

impl LottieEngine for SkiaEngine {
    fn open(&self, json: &[u8]) -> Option<Box<dyn LottieDrawing>> {
        let root: Value = serde_json::from_slice(json).ok()?;
        let (w, h) = (num(&root, "w", 0.0), num(&root, "h", 0.0));
        if w <= 0.0 || h <= 0.0 || !root["layers"].is_array() {
            return None;
        }
        let images = load_images(&root);
        let has_expr = has_expression(&root);
        Some(Box::new(Drawing {
            ip: num(&root, "ip", 0.0),
            fr: num(&root, "fr", 30.0),
            w,
            h,
            root,
            images,
            has_expr,
            font: None,
        }))
    }
}

impl SkiaEngine {
    /// Opens a document whose text layers all use `font` (tests and hosts that bring their own face).
    pub fn open_with_font(
        &self,
        json: &[u8],
        font: (Arc<sq_text::glyph_raster::GlyphRasterFont>, Vec<f64>),
    ) -> Option<Box<dyn LottieDrawing>> {
        let root: Value = serde_json::from_slice(json).ok()?;
        let (w, h) = (num(&root, "w", 0.0), num(&root, "h", 0.0));
        let images = load_images(&root);
        let has_expr = has_expression(&root);
        Some(Box::new(Drawing {
            ip: num(&root, "ip", 0.0),
            fr: num(&root, "fr", 30.0),
            w,
            h,
            root,
            images,
            has_expr,
            font: Some(font),
        }))
    }
}

type FontChoice = (Arc<sq_text::glyph_raster::GlyphRasterFont>, Vec<f64>);

fn has_expression(v: &Value) -> bool {
    match v {
        Value::Object(o) => {
            (o.get("x").is_some_and(Value::is_string) && o.contains_key("k")) || o.values().any(has_expression)
        }
        Value::Array(a) => a.iter().any(has_expression),
        _ => false,
    }
}

fn b64(s: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => continue,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    out
}

/// A PNG or JPEG (ThorVG's two image loaders) as a premultiplied pixmap.
fn decode_image(bytes: &[u8]) -> Option<Pixmap> {
    if bytes.starts_with(&[0xFF, 0xD8]) { decode_jpeg(bytes) } else { decode_png(bytes) }
}

/// A JPEG as an opaque pixmap (RGB output; gray and CMYK are converted by the decoder).
fn decode_jpeg(bytes: &[u8]) -> Option<Pixmap> {
    use zune_jpeg::zune_core::{bytestream::ZCursor, colorspace::ColorSpace, options::DecoderOptions};
    let opts = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
    let mut dec = zune_jpeg::JpegDecoder::new_with_options(ZCursor::new(bytes), opts);
    let rgb = dec.decode().ok()?;
    let info = dec.info()?;
    let mut pm = Pixmap::new(u32::from(info.width), u32::from(info.height))?;
    for (dst, src) in pm.data_mut().as_chunks_mut::<4>().0.iter_mut().zip(rgb.as_chunks::<3>().0) {
        dst.copy_from_slice(&[src[0], src[1], src[2], 255]);
    }
    Some(pm)
}

/// A PNG as a premultiplied pixmap.
fn decode_png(bytes: &[u8]) -> Option<Pixmap> {
    let mut dec = png::Decoder::new(std::io::Cursor::new(bytes));
    dec.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = dec.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buf).ok()?;
    let mut pm = Pixmap::new(info.width, info.height)?;
    let n = info.color_type.samples();
    for (dst, src) in pm.data_mut().as_chunks_mut::<4>().0.iter_mut().zip(buf.chunks_exact(n)) {
        let (r, g, b, a) = match info.color_type {
            png::ColorType::Rgba => (src[0], src[1], src[2], src[3]),
            png::ColorType::Rgb => (src[0], src[1], src[2], 255),
            png::ColorType::GrayscaleAlpha => (src[0], src[0], src[0], src[1]),
            _ => (src[0], src[0], src[0], 255),
        };
        let m = |c: u8| ((u32::from(c) * u32::from(a) + 127) / 255) as u8;
        dst.copy_from_slice(&[m(r), m(g), m(b), a]);
    }
    Some(pm)
}

/// Image assets by id: embedded data URIs and files (relative paths resolve against the process directory).
#[allow(clippy::print_stderr)]
fn load_images(root: &Value) -> HashMap<String, Pixmap> {
    let mut out = HashMap::new();
    for a in root["assets"].as_array().into_iter().flatten() {
        let (Some(id), Some(p)) = (a.get("id").and_then(Value::as_str), a.get("p").and_then(Value::as_str)) else {
            continue;
        };
        let bytes = match p.strip_prefix("data:") {
            Some(rest) => rest.split_once("base64,").map(|(_, d)| b64(d)),
            None => std::fs::read(std::path::Path::new(a.get("u").and_then(Value::as_str).unwrap_or("")).join(p)).ok(),
        };
        match bytes.as_deref().and_then(decode_image) {
            Some(pm) => {
                out.insert(id.to_owned(), pm);
            }
            None => sq_os::errln!("sq-lottie: image asset {id} is missing or not a PNG or JPEG, layer skipped"),
        }
    }
    out
}

struct Drawing {
    root: Value,
    w: f64,
    h: f64,
    ip: f64,
    fr: f64,
    images: HashMap<String, Pixmap>,
    has_expr: bool,
    font: Option<FontChoice>,
}

impl LottieDrawing for Drawing {
    fn render(&mut self, frame: f32, width: usize, height: usize) -> Option<Vec<u8>> {
        let mut pm = Pixmap::new(u32::try_from(width).ok()?, u32::try_from(height).ok()?)?;
        let cx = Ctx {
            assets: &self.root["assets"],
            fonts: &self.root["fonts"],
            fr: self.fr,
            images: &self.images,
            has_expr: self.has_expr,
            font: self.font.clone(),
        };
        let prev =
            self.has_expr.then(|| crate::lottie_expr::set_comp(self.fr, Some(Rc::new(self.root["layers"].clone()))));
        let base = Transform::from_scale((width as f64 / self.w) as f32, (height as f64 / self.h) as f32);
        draw_layers(&cx, self.root["layers"].as_array()?, f64::from(frame) + self.ip, base, &mut pm, 0);
        if let Some(prev) = prev {
            crate::lottie_expr::restore_comp(prev);
        }
        let mut out = pm.take();
        for px in out.as_chunks_mut::<4>().0 {
            let a = u32::from(px[3]);
            if a > 0 && a < 255 {
                for c in &mut px[..3] {
                    *c = ((u32::from(*c) * 255 + a / 2) / a).min(255) as u8;
                }
            }
        }
        Some(out)
    }
}

struct Ctx<'a> {
    assets: &'a Value,
    fonts: &'a Value,
    fr: f64,
    images: &'a HashMap<String, Pixmap>,
    has_expr: bool,
    font: Option<FontChoice>,
}

fn f(v: f64) -> f32 {
    v as f32
}

fn flag(v: &Value, key: &str) -> bool {
    v.get(key).and_then(Value::as_bool).unwrap_or(false)
}

/// Local transform of a `ks` / group `tr` object at frame `t`; `extra_rotation` (degrees) is added for auto-orient.
fn transform_with(ks: &Value, t: f64, extra_rotation: f64) -> Transform {
    let a = eval(&ks["a"], t);
    let p = if flag(&ks["p"], "s") {
        vec![scalar(&ks["p"]["x"], t, 0.0), scalar(&ks["p"]["y"], t, 0.0)]
    } else {
        eval(&ks["p"], t)
    };
    let s = eval(&ks["s"], t);
    let r = if ks.get("r").is_some() { scalar(&ks["r"], t, 0.0) } else { scalar(&ks["rz"], t, 0.0) } + extra_rotation;
    let at = |v: &[f64], i: usize, d: f64| v.get(i).copied().unwrap_or(d);
    let (sk, sa) = (scalar(&ks["sk"], t, 0.0), scalar(&ks["sa"], t, 0.0));
    // Skew along the axis `sa`: shear x by -tan(sk) * y in the axis frame (after scale, before rotation).
    let skew = if sk == 0.0 {
        Transform::identity()
    } else {
        Transform::from_rotate(f(sa))
            .pre_concat(Transform::from_row(1.0, 0.0, -f(sk.to_radians().tan()), 1.0, 0.0, 0.0))
            .pre_concat(Transform::from_rotate(-f(sa)))
    };
    Transform::from_translate(f(at(&p, 0, 0.0)), f(at(&p, 1, 0.0)))
        .pre_concat(Transform::from_rotate(f(r)))
        .pre_concat(skew)
        .pre_concat(Transform::from_scale(f(at(&s, 0, 100.0) / 100.0), f(at(&s, 1, 100.0) / 100.0)))
        .pre_concat(Transform::from_translate(-f(at(&a, 0, 0.0)), -f(at(&a, 1, 0.0))))
}

fn transform_of(ks: &Value, t: f64) -> Transform {
    transform_with(ks, t, 0.0)
}

/// A layer's local transform; with auto-orient (`ao`) the layer turns along its motion path.
fn layer_transform(l: &Value, t: f64) -> Transform {
    let ks = &l["ks"];
    if num(l, "ao", 0.0) != 1.0 {
        return transform_of(ks, t);
    }
    let pos = |t: f64| eval(&ks["p"], t);
    let (a, b) = (pos(t), pos(t + 0.05));
    let (a, b) = if (b.first(), b.get(1)) == (a.first(), a.get(1)) { (pos(t - 0.05), a) } else { (a, b) };
    let (dx, dy) =
        (b.first().unwrap_or(&0.0) - a.first().unwrap_or(&0.0), b.get(1).unwrap_or(&0.0) - a.get(1).unwrap_or(&0.0));
    let angle = if dx == 0.0 && dy == 0.0 { 0.0 } else { dy.atan2(dx).to_degrees() };
    transform_with(ks, t, angle)
}

fn opacity_of(ks: &Value, t: f64) -> f32 {
    f((scalar(&ks["o"], t, 100.0) / 100.0).clamp(0.0, 1.0))
}

fn world_transform(l: &Value, layers: &[Value], t: f64, base: Transform, depth: usize) -> Transform {
    let parent = l.get("parent").and_then(Value::as_i64).filter(|_| depth < 16).and_then(|ind| {
        layers.iter().find(|p| p.get("ind").and_then(Value::as_i64) == Some(ind) && !std::ptr::eq(*p, l))
    });
    let base = match parent {
        Some(p) => world_transform(p, layers, t, base, depth + 1),
        None => base,
    };
    base.pre_concat(layer_transform(l, t))
}

fn draw_layers(cx: &Ctx, layers: &[Value], t: f64, base: Transform, target: &mut Pixmap, depth: usize) {
    if depth > 8 {
        return;
    }
    for i in (0..layers.len()).rev() {
        let l = &layers[i];
        if cx.has_expr {
            crate::lottie_expr::set_index(num(l, "ind", (i + 1) as f64));
        }
        if flag(l, "hd") || num(l, "td", 0.0) == 1.0 || t < num(l, "ip", f64::MIN) || t >= num(l, "op", f64::MAX) {
            continue;
        }
        let tt = num(l, "tt", 0.0) as i32;
        let matte = if tt > 0 {
            match l.get("tp").and_then(Value::as_i64) {
                Some(ind) => layers.iter().find(|m| m.get("ind").and_then(Value::as_i64) == Some(ind)),
                None => i.checked_sub(1).map(|j| &layers[j]),
            }
        } else {
            None
        };
        let Some(matte) = matte else {
            draw_layer(cx, l, layers, t, base, target, depth);
            continue;
        };
        let (Some(mut body), Some(mut mpm)) =
            (Pixmap::new(target.width(), target.height()), Pixmap::new(target.width(), target.height()))
        else {
            continue;
        };
        draw_layer(cx, l, layers, t, base, &mut body, depth);
        draw_layer(cx, matte, layers, t, base, &mut mpm, depth);
        let inverted = tt == 2 || tt == 4;
        let luma = tt >= 3;
        for (bp, mp) in body.data_mut().as_chunks_mut::<4>().0.iter_mut().zip(mpm.data().as_chunks::<4>().0) {
            let mut k = if luma {
                // `mp` is premultiplied, so this is luminance times alpha.
                (0.2126 * f32::from(mp[0]) + 0.7152 * f32::from(mp[1]) + 0.0722 * f32::from(mp[2])) / 255.0
            } else {
                f32::from(mp[3]) / 255.0
            };
            if inverted {
                k = 1.0 - k;
            }
            for c in bp.iter_mut() {
                *c = (f32::from(*c) * k).round() as u8;
            }
        }
        target.draw_pixmap(0, 0, body.as_ref(), &PixmapPaint::default(), Transform::identity(), None);
    }
}

fn draw_layer(cx: &Ctx, l: &Value, layers: &[Value], t: f64, base: Transform, target: &mut Pixmap, depth: usize) {
    let world = world_transform(l, layers, t, base, 0);
    let opacity = opacity_of(&l["ks"], t);
    let masks = l["masksProperties"].as_array().filter(|m| !m.is_empty());
    let isolate = masks.is_some() || (num(l, "ty", 4.0) == 0.0 && opacity < 1.0);
    if !isolate {
        draw_content(cx, l, t, world, opacity, target, depth);
        return;
    }
    let Some(mut tmp) = Pixmap::new(target.width(), target.height()) else { return };
    draw_content(cx, l, t, world, 1.0, &mut tmp, depth);
    if let Some(masks) = masks {
        apply_masks(masks, t, world, &mut tmp);
    }
    let paint = PixmapPaint { opacity, ..PixmapPaint::default() };
    target.draw_pixmap(0, 0, tmp.as_ref(), &paint, Transform::identity(), None);
}

fn apply_masks(masks: &[Value], t: f64, world: Transform, pm: &mut Pixmap) {
    let (w, h) = (pm.width(), pm.height());
    let mut cover: Option<Vec<f32>> = None;
    for m in masks {
        let mode = m.get("mode").and_then(Value::as_str).unwrap_or("a");
        if mode == "n" {
            continue;
        }
        let Some(path) = path_from_flat(&eval(&m["pt"], t)) else { continue };
        let Some(mut mask) = Mask::new(w, h) else { continue };
        mask.fill_path(&path, FillRule::Winding, true, world);
        let o = f((scalar(&m["o"], t, 100.0) / 100.0).clamp(0.0, 1.0));
        let inv = flag(m, "inv");
        let this = mask.data().iter().map(|&b| {
            let v = f32::from(b) / 255.0;
            (if inv { 1.0 - v } else { v }) * o
        });
        let prev = cover.take();
        let cur: Vec<f32> = match (mode, prev) {
            ("a", None) => this.collect(),
            ("s" | "i", None) => {
                let all = vec![1.0; (w * h) as usize];
                combine(mode, &all, this)
            }
            (_, Some(p)) => combine(mode, &p, this),
            (_, None) => this.collect(),
        };
        cover = Some(cur);
    }
    if let Some(c) = cover {
        for (px, k) in pm.data_mut().as_chunks_mut::<4>().0.iter_mut().zip(c) {
            for v in px.iter_mut() {
                *v = (f32::from(*v) * k).round() as u8;
            }
        }
    }
}

fn combine(mode: &str, prev: &[f32], this: impl Iterator<Item = f32>) -> Vec<f32> {
    prev.iter()
        .zip(this)
        .map(|(&a, b)| match mode {
            "s" => a * (1.0 - b),
            "i" => a * b,
            "l" => a.max(b),
            _ => a + b - a * b,
        })
        .collect()
}

fn hex_color(s: &str) -> Option<Color> {
    let s = s.trim_start_matches('#');
    let v = u32::from_str_radix(s.get(..6)?, 16).ok()?;
    Some(Color::from_rgba8((v >> 16) as u8, (v >> 8) as u8, v as u8, 255))
}

fn draw_content(cx: &Ctx, l: &Value, t: f64, world: Transform, alpha: f32, target: &mut Pixmap, depth: usize) {
    match num(l, "ty", 4.0) as i32 {
        4 => {
            if let Some(items) = l["shapes"].as_array() {
                draw_shapes(items, t, world, alpha, target);
            }
        }
        1 => {
            let Some(mut c) = l.get("sc").and_then(Value::as_str).and_then(hex_color) else { return };
            c.set_alpha(alpha);
            let Some(p) = rect(
                (f(num(l, "sw", 0.0)) / 2.0, f(num(l, "sh", 0.0)) / 2.0),
                (f(num(l, "sw", 0.0)), f(num(l, "sh", 0.0))),
                0.0,
            ) else {
                return;
            };
            let mut paint = Paint::default();
            paint.set_color(c);
            target.fill_path(&p, &paint, FillRule::Winding, world, None);
        }
        0 => {
            let Some(asset) = l
                .get("refId")
                .and_then(Value::as_str)
                .and_then(|id| cx.assets.as_array()?.iter().find(|a| a.get("id").and_then(Value::as_str) == Some(id)))
            else {
                return;
            };
            let Some(children) = asset["layers"].as_array() else { return };
            let local = if l.get("tm").is_some() {
                scalar(&l["tm"], t, 0.0) * cx.fr
            } else {
                (t - num(l, "st", 0.0)) / num(l, "sr", 1.0).max(1e-6)
            };
            let (w, h) = (num(l, "w", 0.0), num(l, "h", 0.0));
            let prev = cx.has_expr.then(|| crate::lottie_expr::set_comp(cx.fr, Some(Rc::new(asset["layers"].clone()))));
            if w > 0.0 && h > 0.0 {
                // Clip to the precomp's own size.
                let (Some(mut tmp), Some(mut clip), Some(r)) = (
                    Pixmap::new(target.width(), target.height()),
                    Mask::new(target.width(), target.height()),
                    rect((f(w) / 2.0, f(h) / 2.0), (f(w), f(h)), 0.0),
                ) else {
                    return;
                };
                draw_layers(cx, children, local, world, &mut tmp, depth + 1);
                clip.fill_path(&r, FillRule::Winding, true, world);
                tmp.apply_mask(&clip);
                let paint = PixmapPaint { opacity: alpha, ..PixmapPaint::default() };
                target.draw_pixmap(0, 0, tmp.as_ref(), &paint, Transform::identity(), None);
            } else {
                draw_layers(cx, children, local, world, target, depth + 1);
            }
            if let Some(prev) = prev {
                crate::lottie_expr::restore_comp(prev);
            }
        }
        2 => {
            let Some(pm) = l.get("refId").and_then(Value::as_str).and_then(|id| cx.images.get(id)) else { return };
            let paint = PixmapPaint { opacity: alpha, quality: FilterQuality::Bilinear, ..PixmapPaint::default() };
            target.draw_pixmap(0, 0, pm.as_ref(), &paint, world, None);
        }
        5 => draw_text(cx, l, t, world, alpha, target),
        _ => {}
    }
}

#[allow(clippy::print_stderr)]
fn draw_text(cx: &Ctx, l: &Value, t: f64, world: Transform, alpha: f32, target: &mut Pixmap) {
    let Some(doc) = crate::lottie_text::document(l, cx.fonts, t) else { return };
    let Some((font, coords)) = cx.font.clone().or_else(|| crate::lottie_text::choose_font(&doc)) else {
        sq_os::errln!("sq-lottie: no font for text layer, skipped");
        return;
    };
    let Some(path) = crate::lottie_text::text_path(&doc, &font, &coords) else { return };
    let paint_of = |c: [f32; 3]| {
        let mut p = Paint { anti_alias: true, ..Paint::default() };
        p.set_color(
            Color::from_rgba(c[0].clamp(0.0, 1.0), c[1].clamp(0.0, 1.0), c[2].clamp(0.0, 1.0), alpha)
                .unwrap_or(Color::BLACK),
        );
        p
    };
    if let Some(c) = doc.fill {
        target.fill_path(&path, &paint_of(c), FillRule::Winding, world, None);
    }
    if let Some((c, w)) = doc.stroke {
        let stroke = Stroke { width: w, line_join: LineJoin::Round, ..Stroke::default() };
        target.stroke_path(&path, &paint_of(c), &stroke, world, None);
    }
}

enum Op<'a> {
    Group(&'a Value),
    Paint(Shapes, &'a Value),
}

/// The geometry a paint sees after the modifiers.
struct Shapes {
    paths: Vec<Path>,
    /// Merge Paths mode (1 merge, 2 add, 3 subtract, 4 intersect, 5 exclude).
    merge: Option<u8>,
}

fn ty_of(i: &Value) -> &str {
    i.get("ty").and_then(Value::as_str).unwrap_or("")
}

fn is_geometry(ty: &str) -> bool {
    matches!(ty, "rc" | "el" | "sr" | "sh")
}

fn geometry(it: &Value, t: f64) -> Option<Path> {
    let two = |k: &str, d: f64| {
        let v = eval(&it[k], t);
        (f(v.first().copied().unwrap_or(d)), f(v.get(1).copied().unwrap_or(d)))
    };
    match it.get("ty")?.as_str()? {
        "rc" => rect(two("p", 0.0), two("s", 0.0), f(scalar(&it["r"], t, 0.0))),
        "el" => ellipse(two("p", 0.0), two("s", 0.0)),
        "sr" => {
            let polygon = num(it, "sy", 1.0) == 2.0;
            let inner = (!polygon).then(|| f(scalar(&it["ir"], t, 0.0)));
            star(
                two("p", 0.0),
                scalar(&it["pt"], t, 5.0).round() as usize,
                f(scalar(&it["or"], t, 0.0)),
                inner,
                f(scalar(&it["r"], t, 0.0)),
                f(scalar(&it["os"], t, 0.0) / 100.0),
                f(scalar(&it["is"], t, 0.0) / 100.0),
            )
        }
        "sh" => path_from_flat(&eval(&it["ks"], t)),
        _ => None,
    }
}

fn rgb(v: &[f64]) -> Option<(f32, f32, f32)> {
    Some((f(*v.first()?), f(*v.get(1)?), f(*v.get(2)?)))
}

fn paint_for(it: &Value, t: f64, alpha: f32) -> Option<Paint<'static>> {
    let ty = it.get("ty")?.as_str()?;
    let a = alpha * f((scalar(&it["o"], t, 100.0) / 100.0).clamp(0.0, 1.0));
    let mut paint = Paint { anti_alias: true, blend_mode: BlendMode::SourceOver, ..Paint::default() };
    if ty == "fl" || ty == "st" {
        let c = eval(&it["c"], t);
        let (r, g, b) = rgb(&c)?;
        paint.set_color(Color::from_rgba(r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0), a.clamp(0.0, 1.0))?);
        return Some(paint);
    }
    let (s, e) = (eval(&it["s"], t), eval(&it["e"], t));
    let (start, end) = (Point::from_xy(f(*s.first()?), f(*s.get(1)?)), Point::from_xy(f(*e.first()?), f(*e.get(1)?)));
    let count = num(&it["g"], "p", 0.0) as usize;
    let k = eval(&it["g"]["k"], t);
    let has_alpha = k.len() >= count * 6;
    let stops: Vec<GradientStop> = (0..count)
        .filter_map(|i| {
            let (r, g, b) = rgb(k.get(i * 4 + 1..)?)?;
            let ga = if has_alpha { f(*k.get(count * 4 + i * 2 + 1)?) } else { 1.0 };
            Some(GradientStop::new(
                f(*k.get(i * 4)?).clamp(0.0, 1.0),
                Color::from_rgba(r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0), (ga * a).clamp(0.0, 1.0))?,
            ))
        })
        .collect();
    if stops.len() < 2 {
        return None;
    }
    let radius = ((end.x - start.x).powi(2) + (end.y - start.y).powi(2)).sqrt();
    paint.shader = if num(it, "t", 1.0) == 2.0 {
        // Highlight: the focal point moves from the center toward `angle` by `h` percent of the radius.
        let h = (scalar(&it["h"], t, 0.0) / 100.0).clamp(-0.99, 0.99);
        let theta =
            f64::from(end.y - start.y).atan2(f64::from(end.x - start.x)) + scalar(&it["a"], t, 0.0).to_radians();
        let focal = Point::from_xy(start.x + f(theta.cos() * h) * radius, start.y + f(theta.sin() * h) * radius);
        RadialGradient::new(focal, start, radius, stops, SpreadMode::Pad, Transform::identity())?
    } else {
        LinearGradient::new(start, end, stops, SpreadMode::Pad, Transform::identity())?
    };
    Some(paint)
}

fn stroke_for(it: &Value, t: f64) -> Stroke {
    let mut s = Stroke {
        width: f(scalar(&it["w"], t, 1.0)),
        miter_limit: f(num(it, "ml", 4.0)),
        line_cap: match num(it, "lc", 2.0) as i32 {
            1 => LineCap::Butt,
            3 => LineCap::Square,
            _ => LineCap::Round,
        },
        line_join: match num(it, "lj", 2.0) as i32 {
            1 => LineJoin::Miter,
            3 => LineJoin::Bevel,
            _ => LineJoin::Round,
        },
        dash: None,
    };
    if let Some(d) = it["d"].as_array() {
        let mut offset = 0.0;
        let mut arr: Vec<f32> = Vec::new();
        for e in d {
            let v = f(scalar(&e["v"], t, 0.0));
            match e.get("n").and_then(Value::as_str) {
                Some("o") => offset = v,
                _ => arr.push(v),
            }
        }
        if arr.len() % 2 == 1 {
            arr.extend(arr.clone());
        }
        s.dash = StrokeDash::new(arr, offset);
    }
    s
}

/// Geometry above item `paint_idx`, run through every modifier (trim, round corners, merge) in list order.
fn shapes_for(items: &[Value], paint_idx: usize, t: f64) -> Shapes {
    let mut sh = Shapes { paths: Vec::new(), merge: None };
    for (i, it) in items.iter().enumerate() {
        if flag(it, "hd") {
            continue;
        }
        match ty_of(it) {
            ty if i < paint_idx && is_geometry(ty) => sh.paths.extend(geometry(it, t)),
            "tm" => {
                let (s, e, o) = (
                    f(scalar(&it["s"], t, 0.0) / 100.0),
                    f(scalar(&it["e"], t, 100.0) / 100.0),
                    f(scalar(&it["o"], t, 0.0) / 360.0),
                );
                sh.paths = if num(it, "m", 1.0) == 2.0 {
                    trim_individually(&sh.paths, s, e, o).into_iter().collect()
                } else {
                    sh.paths.iter().filter_map(|p| trim(p, s, e, o)).collect()
                };
            }
            "rd" => {
                let r = f(scalar(&it["r"], t, 0.0));
                sh.paths = sh.paths.iter().filter_map(|p| round_corners(p, r)).collect();
            }
            "mm" => sh.merge = Some(num(it, "mm", 1.0) as u8),
            _ => {}
        }
    }
    sh
}

/// Fills the subtraction (mode 3: the last shape minus the others) or intersection (mode 4) of `paths` through coverage masks.
fn fill_merged(paths: &[Path], mode: u8, mut paint: Paint<'static>, xf: Transform, target: &mut Pixmap) {
    let (w, h) = (target.width(), target.height());
    let covs: Vec<Vec<u8>> = paths
        .iter()
        .filter_map(|p| {
            let mut m = Mask::new(w, h)?;
            m.fill_path(p, FillRule::Winding, true, xf);
            Some(m.data().to_vec())
        })
        .collect();
    let Some(last) = covs.last() else { return };
    let out: Vec<u8> = (0..last.len())
        .map(|i| {
            let v = if mode == 4 {
                covs.iter().map(|c| f32::from(c[i])).fold(255.0, f32::min)
            } else {
                let others = covs[..covs.len() - 1].iter().map(|c| f32::from(c[i])).fold(0.0, f32::max);
                f32::from(last[i]) * (1.0 - others / 255.0)
            };
            v.round() as u8
        })
        .collect();
    let (Some(size), Some(rect)) = (IntSize::from_wh(w, h), Rect::from_xywh(0.0, 0.0, w as f32, h as f32)) else {
        return;
    };
    let Some(mask) = Mask::from_vec(out, size) else { return };
    paint.shader.transform(xf);
    target.fill_rect(rect, &paint, Transform::identity(), Some(&mask));
}

fn draw_shapes(items: &[Value], t: f64, xf: Transform, alpha: f32, target: &mut Pixmap) {
    let tr = items.iter().find(|i| ty_of(i) == "tr");
    let (xf, alpha) = match tr {
        Some(tr) => (xf.pre_concat(transform_of(tr, t)), alpha * opacity_of(tr, t)),
        None => (xf, alpha),
    };
    let Some(r) = items.iter().position(|i| ty_of(i) == "rp" && !flag(i, "hd")) else {
        draw_items(items, t, xf, alpha, target);
        return;
    };
    // Repeater: everything above it is drawn `c` times, each copy moved by one more step of the repeater transform.
    let rep = &items[r];
    let copies = scalar(&rep["c"], t, 1.0).round().clamp(0.0, 256.0) as usize;
    let offset = scalar(&rep["o"], t, 0.0);
    let step = transform_of(&rep["tr"], t);
    let back = step.invert().unwrap_or_else(Transform::identity);
    let (so, eo) = (scalar(&rep["tr"]["so"], t, 100.0) / 100.0, scalar(&rep["tr"]["eo"], t, 100.0) / 100.0);
    let order: Vec<usize> = if num(rep, "m", 1.0) == 2.0 { (0..copies).rev().collect() } else { (0..copies).collect() };
    for k in order {
        let n = (k as f64 + offset).round() as i32;
        let mut m = Transform::identity();
        for _ in 0..n.unsigned_abs() {
            m = m.pre_concat(if n > 0 { step } else { back });
        }
        let frac = if copies > 1 { k as f64 / (copies - 1) as f64 } else { 0.0 };
        let op = f((so + (eo - so) * frac).clamp(0.0, 1.0));
        draw_items(&items[..r], t, xf.pre_concat(m), alpha * op, target);
    }
}

fn draw_items(items: &[Value], t: f64, xf: Transform, alpha: f32, target: &mut Pixmap) {
    let mut ops: Vec<Op> = Vec::new();
    for (idx, it) in items.iter().enumerate() {
        if flag(it, "hd") {
            continue;
        }
        match ty_of(it) {
            "gr" => ops.push(Op::Group(it)),
            "fl" | "st" | "gf" | "gs" => ops.push(Op::Paint(shapes_for(items, idx, t), it)),
            _ => {}
        }
    }
    for op in ops.iter().rev() {
        match op {
            Op::Group(g) => {
                if let Some(sub) = g["it"].as_array() {
                    draw_shapes(sub, t, xf, alpha, target);
                }
            }
            Op::Paint(sh, it) => {
                let Some(paint) = paint_for(it, t, alpha) else { continue };
                let is_fill = matches!(ty_of(it), "fl" | "gf");
                if is_fill && matches!(sh.merge, Some(3 | 4)) && sh.paths.len() >= 2 {
                    fill_merged(&sh.paths, sh.merge.unwrap_or(3), paint, xf, target);
                    continue;
                }
                let mut pb = PathBuilder::new();
                for p in &sh.paths {
                    pb.push_path(p);
                }
                let Some(path) = pb.finish() else { continue };
                if is_fill {
                    let even_odd = num(it, "r", 1.0) == 2.0 || sh.merge == Some(5);
                    let rule = if even_odd { FillRule::EvenOdd } else { FillRule::Winding };
                    target.fill_path(&path, &paint, rule, xf, None);
                } else {
                    target.stroke_path(&path, &paint, &stroke_for(it, t), xf, None);
                }
            }
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use serde_json::json;

    fn render(doc: Value, frame: f32) -> Vec<u8> {
        let bytes = serde_json::to_vec(&doc).unwrap();
        let mut d = SkiaEngine.open(&bytes).expect("open");
        d.render(frame, 100, 100).expect("render")
    }

    fn px(buf: &[u8], x: usize, y: usize) -> [u8; 4] {
        let i = (y * 100 + x) * 4;
        [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
    }

    fn doc(layers: Value) -> Value {
        json!({"w":100,"h":100,"fr":30,"ip":0,"op":30,"layers":layers})
    }

    fn st(v: Value) -> Value {
        json!({"a":0,"k":v})
    }

    fn rect_layer(color: [f64; 3], extra: Value) -> Value {
        let mut l = json!({"ty":4,"ind":1,"ip":0,"op":30,"ks":{},"shapes":[{"ty":"gr","it":[
            {"ty":"rc","p":st(json!([50,50])),"s":st(json!([40,40])),"r":st(json!(0))},
            {"ty":"fl","c":st(json!(color)),"o":st(json!(100))},
            {"ty":"tr","p":st(json!([0,0]))}]}]});
        if let (Some(o), Some(e)) = (l.as_object_mut(), extra.as_object()) {
            o.extend(e.clone());
        }
        l
    }

    #[test]
    fn fills_a_rectangle() {
        let b = render(doc(json!([rect_layer([1.0, 0.0, 0.0], json!({}))])), 0.0);
        assert_eq!(px(&b, 50, 50), [255, 0, 0, 255]);
        assert_eq!(px(&b, 10, 10)[3], 0);
    }

    #[test]
    fn layer_opacity_and_scaling_to_the_raster() {
        let mut d = doc(json!([rect_layer([0.0, 1.0, 0.0], json!({"ks":{"o":st(json!(50))}}))]));
        d["w"] = json!(50);
        d["h"] = json!(50);
        let b = render(d, 0.0);
        // A 50 px comp drawn at 100 px: the 40 px square covers 80 px around the centre (50,50 of comp is off canvas).
        let a = px(&b, 60, 60)[3];
        assert!((125..=130).contains(&a), "alpha {a}");
    }

    #[test]
    fn animated_position_with_ease() {
        let pos = json!({"a":1,"k":[
            {"t":0,"s":[0,0],"o":{"x":0.0,"y":0.0},"i":{"x":1.0,"y":1.0}},
            {"t":10,"s":[40,0]}]});
        let l = rect_layer([0.0, 0.0, 1.0], json!({"ks":{"p":pos}}));
        let d = doc(json!([l]));
        assert_eq!(px(&render(d.clone(), 0.0), 75, 50)[3], 0);
        assert_eq!(px(&render(d.clone(), 10.0), 75, 50), [0, 0, 255, 255]);
        let mid = render(d, 5.0);
        assert_eq!(px(&mid, 60, 50), [0, 0, 255, 255]);
        assert_eq!(px(&mid, 95, 50)[3], 0);
        assert_eq!(px(&mid, 40, 50)[3], 0);
    }

    #[test]
    fn stroke_with_trim_path() {
        let l = json!({"ty":4,"ip":0,"op":30,"ks":{},"shapes":[{"ty":"gr","it":[
            {"ty":"sh","ks":st(json!({"c":false,"v":[[10,50],[90,50]],"i":[[0,0],[0,0]],"o":[[0,0],[0,0]]}))},
            {"ty":"st","c":st(json!([1,1,1])),"o":st(json!(100)),"w":st(json!(10)),"lc":1,"lj":1},
            {"ty":"tm","s":st(json!(0)),"e":st(json!(50)),"o":st(json!(0))},
            {"ty":"tr"}]}]});
        let b = render(doc(json!([l])), 0.0);
        assert_eq!(px(&b, 30, 50), [255, 255, 255, 255]);
        assert_eq!(px(&b, 70, 50)[3], 0);
    }

    #[test]
    fn linear_gradient_fill() {
        let l = json!({"ty":4,"ip":0,"op":30,"ks":{},"shapes":[{"ty":"gr","it":[
            {"ty":"rc","p":st(json!([50,50])),"s":st(json!([100,100])),"r":st(json!(0))},
            {"ty":"gf","t":1,"s":st(json!([0,0])),"e":st(json!([100,0])),"o":st(json!(100)),
             "g":{"p":2,"k":st(json!([0,1,0,0, 1,0,0,1]))}},
            {"ty":"tr"}]}]});
        let b = render(doc(json!([l])), 0.0);
        assert!(px(&b, 5, 50)[0] > 230 && px(&b, 5, 50)[2] < 30);
        assert!(px(&b, 94, 50)[2] > 230 && px(&b, 94, 50)[0] < 30);
    }

    #[test]
    fn mask_subtract_and_track_matte() {
        let hole = json!([{"mode":"s","pt":st(json!({"c":true,"v":[[40,40],[60,40],[60,60],[40,60]],
            "i":[[0,0],[0,0],[0,0],[0,0]],"o":[[0,0],[0,0],[0,0],[0,0]]})),"o":st(json!(100))}]);
        let b = render(doc(json!([rect_layer([1.0, 0.0, 0.0], json!({"masksProperties":hole}))])), 0.0);
        assert_eq!(px(&b, 50, 50)[3], 0);
        assert_eq!(px(&b, 35, 35), [255, 0, 0, 255]);
        // Matte: the first layer (circle) clips the second (square) through an alpha matte.
        let circle = json!({"ty":4,"ind":2,"td":1,"ip":0,"op":30,"ks":{},"shapes":[{"ty":"gr","it":[
            {"ty":"el","p":st(json!([50,50])),"s":st(json!([20,20]))},
            {"ty":"fl","c":st(json!([1,1,1])),"o":st(json!(100))},{"ty":"tr"}]}]});
        let square = rect_layer([0.0, 1.0, 0.0], json!({"tt":1}));
        let b = render(doc(json!([circle, square])), 0.0);
        assert_eq!(px(&b, 50, 50), [0, 255, 0, 255]);
        assert_eq!(px(&b, 33, 33)[3], 0);
    }

    #[test]
    fn precomp_with_parent_and_time_offset() {
        let inner = rect_layer([1.0, 1.0, 0.0], json!({}));
        let mut d = doc(json!([
            {"ty":0,"ind":1,"refId":"c","ip":0,"op":30,"st":5,"sr":1,"w":100,"h":100,"ks":{"p":st(json!([20,0]))}},
        ]));
        d["assets"] = json!([{"id":"c","layers":[inner]}]);
        assert_eq!(px(&render(d.clone(), 0.0), 70, 50)[3], 0);
        let b = render(d.clone(), 5.0);
        assert_eq!(px(&b, 70, 50), [255, 255, 0, 255]);
        assert_eq!(px(&b, 35, 50)[3], 0);
    }

    #[test]
    fn solid_layer_and_unreadable_json() {
        let b = render(doc(json!([{"ty":1,"ip":0,"op":30,"ks":{},"sc":"#00ff00","sw":100,"sh":100}])), 0.0);
        assert_eq!(px(&b, 3, 3), [0, 255, 0, 255]);
        assert!(SkiaEngine.open(b"not json").is_none());
    }

    fn shape_layer(items: Value) -> Value {
        json!({"ty":4,"ip":0,"op":30,"ks":{},"shapes":[{"ty":"gr","it":items}]})
    }

    fn line(y: f64) -> Value {
        json!({"ty":"sh","ks":st(json!({"c":false,"v":[[10,y],[90,y]],"i":[[0,0],[0,0]],"o":[[0,0],[0,0]]}))})
    }

    fn white_stroke() -> Value {
        json!({"ty":"st","c":st(json!([1,1,1])),"o":st(json!(100)),"w":st(json!(10)),"lc":1,"lj":1})
    }

    fn opaque(b: &[u8], x: usize, y: usize) -> bool {
        px(b, x, y)[3] > 200
    }

    fn clear(b: &[u8], x: usize, y: usize) -> bool {
        px(b, x, y)[3] < 20
    }

    #[test]
    fn trim_individually_runs_over_all_paths_as_one() {
        let tm = |m: i32| json!({"ty":"tm","s":st(json!(0)),"e":st(json!(50)),"o":st(json!(0)),"m":m});
        let layer = |m: i32| shape_layer(json!([line(30.0), line(70.0), white_stroke(), tm(m), {"ty":"tr"}]));
        // Individually: 50 % of both lines together is exactly the first line.
        let b = render(doc(json!([layer(2)])), 0.0);
        assert!(opaque(&b, 70, 30) && clear(&b, 30, 70));
        // Simultaneously: half of each line.
        let b = render(doc(json!([layer(1)])), 0.0);
        assert!(opaque(&b, 30, 30) && opaque(&b, 30, 70) && clear(&b, 70, 30) && clear(&b, 70, 70));
    }

    #[test]
    fn round_corners_modifier_cuts_the_corner() {
        let rc = json!({"ty":"rc","p":st(json!([50,50])),"s":st(json!([40,40])),"r":st(json!(0))});
        let fl = json!({"ty":"fl","c":st(json!([1,0,0])),"o":st(json!(100))});
        let sharp = render(doc(json!([shape_layer(json!([rc.clone(), fl.clone(), {"ty":"tr"}]))])), 0.0);
        assert!(opaque(&sharp, 31, 31));
        let rd = json!({"ty":"rd","r":st(json!(10))});
        let b = render(doc(json!([shape_layer(json!([rc, fl, rd, {"ty":"tr"}]))])), 0.0);
        assert!(clear(&b, 31, 31) && opaque(&b, 50, 31) && opaque(&b, 50, 50));
    }

    #[test]
    fn merge_paths_subtract_leaves_a_hole() {
        let small = json!({"ty":"rc","p":st(json!([50,50])),"s":st(json!([20,20])),"r":st(json!(0))});
        let big = json!({"ty":"rc","p":st(json!([50,50])),"s":st(json!([60,60])),"r":st(json!(0))});
        let fl = json!({"ty":"fl","c":st(json!([0,1,0])),"o":st(json!(100))});
        let mm = |m: i32| json!({"ty":"mm","mm":m});
        let b =
            render(doc(json!([shape_layer(json!([small.clone(), big.clone(), mm(3), fl.clone(), {"ty":"tr"}]))])), 0.0);
        assert!(clear(&b, 50, 50) && opaque(&b, 30, 30));
        let b = render(doc(json!([shape_layer(json!([small, big, mm(4), fl, {"ty":"tr"}]))])), 0.0);
        assert!(opaque(&b, 50, 50) && clear(&b, 30, 30));
    }

    #[test]
    fn star_roundness_changes_the_outline() {
        let star = |os: f64, is: f64| {
            json!([{"ty":"sr","sy":1,"p":st(json!([50,50])),"pt":st(json!(5)),"or":st(json!(40)),"ir":st(json!(20)),
                    "r":st(json!(0)),"os":st(json!(os)),"is":st(json!(is))},
                   {"ty":"fl","c":st(json!([1,1,1])),"o":st(json!(100))},{"ty":"tr"}])
        };
        let area = |b: &[u8]| b.as_chunks::<4>().0.iter().map(|p| u32::from(p[3])).sum::<u32>();
        let sharp = area(&render(doc(json!([shape_layer(star(0.0, 0.0))])), 0.0));
        let round = area(&render(doc(json!([shape_layer(star(100.0, 100.0))])), 0.0));
        assert!(sharp > 0 && (round as f64 - sharp as f64).abs() > sharp as f64 * 0.03, "{sharp} {round}");
    }

    #[test]
    fn skew_shears_the_layer() {
        let l = rect_layer(
            [1.0, 1.0, 1.0],
            json!({"ks":{"a":st(json!([50,50])),"p":st(json!([50,50])),"sk":st(json!(45)),"sa":st(json!(0))}}),
        );
        let b = render(doc(json!([l])), 0.0);
        // The rectangle spans x 30..70; 8 px above the center it moves right by 8, below it left by 8.
        assert!(opaque(&b, 76, 42) && clear(&b, 33, 42));
        assert!(opaque(&b, 24, 58) && clear(&b, 67, 58));
    }

    #[test]
    fn radial_gradient_highlight_moves_the_focus() {
        let gf = |h: f64| {
            shape_layer(json!([{"ty":"rc","p":st(json!([50,50])),"s":st(json!([100,100])),"r":st(json!(0))},
                {"ty":"gf","t":2,"s":st(json!([50,50])),"e":st(json!([100,50])),"h":st(json!(h)),"a":st(json!(0)),"o":st(json!(100)),
                 "g":{"p":2,"k":st(json!([0,1,0,0, 1,0,0,1]))}},{"ty":"tr"}]))
        };
        let plain = render(doc(json!([gf(0.0)])), 0.0);
        assert!(px(&plain, 50, 50)[0] > 240);
        let hi = render(doc(json!([gf(60.0)])), 0.0);
        assert!(px(&hi, 80, 50)[0] > px(&hi, 50, 50)[0] + 20, "{:?} {:?}", px(&hi, 80, 50), px(&hi, 50, 50));
    }

    #[test]
    fn spatial_path_and_auto_orient() {
        let pos = json!({"a":1,"k":[
            {"t":0,"s":[10,50],"to":[0,-30],"ti":[0,-30],"o":{"x":[0.0],"y":[0.0]},"i":{"x":[1.0],"y":[1.0]}},
            {"t":10,"s":[90,50]}]});
        let mk = |ao: i32| {
            let mut l = shape_layer(json!([{"ty":"rc","p":st(json!([0,0])),"s":st(json!([30,6])),"r":st(json!(0))},
                {"ty":"fl","c":st(json!([1,1,1])),"o":st(json!(100))},{"ty":"tr"}]));
            l["ks"] = json!({"p":pos});
            l["ao"] = json!(ao);
            l
        };
        // Halfway the layer is lifted by the curve (center near y = 27.5).
        let b = render(doc(json!([mk(0)])), 5.0);
        assert!(opaque(&b, 50, 28) && clear(&b, 50, 50));
        // Auto-orient at the start: the motion goes straight up, so the 30 x 6 bar stands upright.
        let b = render(doc(json!([mk(1)])), 0.0);
        assert!(opaque(&b, 10, 40) && clear(&b, 22, 50));
        let b = render(doc(json!([mk(0)])), 0.0);
        assert!(opaque(&b, 22, 50) && clear(&b, 10, 40));
    }

    #[test]
    fn precomp_is_clipped_to_its_size() {
        let mut d = doc(json!([{"ty":0,"ind":1,"refId":"c","ip":0,"op":30,"st":0,"sr":1,"w":50,"h":50,"ks":{}}]));
        d["assets"] = json!([{"id":"c","layers":[{"ty":1,"ip":0,"op":30,"ks":{},"sc":"#ff0000","sw":100,"sh":100}]}]);
        let b = render(d, 0.0);
        assert!(opaque(&b, 25, 25) && clear(&b, 75, 75));
    }

    #[test]
    fn repeater_copies_the_shapes() {
        let l = shape_layer(json!([
            {"ty":"rc","p":st(json!([20,50])),"s":st(json!([10,10])),"r":st(json!(0))},
            {"ty":"fl","c":st(json!([1,1,1])),"o":st(json!(100))},
            {"ty":"rp","c":st(json!(3)),"o":st(json!(0)),"m":1,
             "tr":{"p":st(json!([25,0])),"a":st(json!([0,0])),"s":st(json!([100,100])),"r":st(json!(0)),"so":st(json!(100)),"eo":st(json!(0))}},
            {"ty":"tr"}]));
        let b = render(doc(json!([l])), 0.0);
        assert!(opaque(&b, 20, 50) && clear(&b, 32, 50) && clear(&b, 58, 50));
        // Opacity fades from start (100) to end (0): the last copy is transparent, the middle one half.
        assert!(
            px(&b, 70, 50)[3] < 5 && (120..135).contains(&px(&b, 45, 50)[3]),
            "{:?} {:?}",
            px(&b, 45, 50),
            px(&b, 70, 50)
        );
    }

    fn b64_encode(data: &[u8]) -> String {
        const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for c in data.chunks(3) {
            let n = (u32::from(c[0]) << 16)
                | (u32::from(*c.get(1).unwrap_or(&0)) << 8)
                | u32::from(*c.get(2).unwrap_or(&0));
            for k in 0..4 {
                if k <= c.len() {
                    out.push(T[((n >> (18 - 6 * k)) & 63) as usize] as char);
                } else {
                    out.push('=');
                }
            }
        }
        out
    }

    #[test]
    fn embedded_jpeg_image_layer() {
        let mut jpg = Vec::new();
        let rgb: Vec<u8> = (0..16 * 16).flat_map(|_| [255u8, 0, 0]).collect();
        jpeg_encoder::Encoder::new(&mut jpg, 100).encode(&rgb, 16, 16, jpeg_encoder::ColorType::Rgb).unwrap();
        let uri = format!("data:image/jpeg;base64,{}", b64_encode(&jpg));
        let mut d = doc(json!([{"ty":2,"ind":1,"refId":"img","ip":0,"op":30,"ks":{"s":st(json!([312.5,312.5]))}}]));
        d["assets"] = json!([{"id":"img","w":16,"h":16,"u":"","p":uri,"e":1}]);
        // 16 px scaled by 3.125 = 50 px red square in the top left corner.
        let b = render(d, 0.0);
        assert!(px(&b, 25, 25)[0] > 230 && px(&b, 25, 25)[1] < 30 && px(&b, 25, 25)[3] == 255, "{:?}", px(&b, 25, 25));
        assert!(clear(&b, 75, 75));
    }

    #[test]
    fn embedded_png_image_layer() {
        let mut png_bytes = Vec::new();
        {
            let mut enc = png::Encoder::new(&mut png_bytes, 2, 2);
            enc.set_color(png::ColorType::Rgba);
            enc.set_depth(png::BitDepth::Eight);
            let mut w = enc.write_header().unwrap();
            w.write_image_data(&[255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255]).unwrap();
        }
        let uri = format!("data:image/png;base64,{}", b64_encode(&png_bytes));
        let mut d = doc(json!([{"ty":2,"ind":1,"refId":"img","ip":0,"op":30,"ks":{"s":st(json!([2500,2500]))}}]));
        d["assets"] = json!([{"id":"img","w":2,"h":2,"u":"","p":uri,"e":1}]);
        // 2 px scaled by 25 = 50 px square: red above, blue below.
        let b = render(d, 0.0);
        assert!(px(&b, 25, 5)[0] > 200 && px(&b, 25, 5)[2] < 50, "{:?}", px(&b, 25, 5));
        assert!(px(&b, 25, 45)[2] > 200 && clear(&b, 75, 75), "{:?}", px(&b, 25, 45));
    }

    #[test]
    fn text_layer_draws_glyph_outlines() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts/Families/anton/Anton-Regular.ttf");
        let Some(font) = sq_text::glyph_raster::GlyphRasterFont::from_path(&path) else { return };
        let l = json!({"ty":5,"ind":1,"ip":0,"op":30,"ks":{"p":st(json!([10,80]))},
            "t":{"d":{"k":[{"s":{"s":60,"f":"F","t":"H","fc":[1,1,1],"j":0},"t":0}]}}});
        let mut d = doc(json!([l]));
        d["fonts"] = json!({"list":[{"fName":"F","fFamily":"Anton","fStyle":"Regular"}]});
        let bytes = serde_json::to_vec(&d).unwrap();
        let mut dr = SkiaEngine.open_with_font(&bytes, (Arc::new(font), Vec::new())).expect("open");
        let b = dr.render(0.0, 100, 100).expect("render");
        let lit = |x0: usize, x1: usize, y0: usize, y1: usize| {
            (y0..y1).flat_map(|y| (x0..x1).map(move |x| (x, y))).filter(|&(x, y)| px(&b, x, y)[3] > 128).count()
        };
        // The H stands on the baseline (y = 80), about 50 px tall, and nothing is drawn above it.
        assert!(lit(10, 50, 45, 80) > 300, "{}", lit(10, 50, 45, 80));
        assert_eq!(lit(0, 100, 0, 20), 0);
        assert_eq!(lit(0, 100, 85, 100), 0);
    }

    #[test]
    fn expression_moves_a_layer_with_time() {
        let pos = json!({"a":0,"k":[0,0],"x":"[value[0] + time * 60, value[1]]"});
        let d = doc(json!([rect_layer([1.0, 1.0, 1.0], json!({"ks":{"p":pos}}))]));
        let b = render(d.clone(), 0.0);
        assert!(opaque(&b, 40, 50) && clear(&b, 90, 50));
        // Frame 15 at 30 fps is 0.5 s: 30 px to the right.
        let b = render(d, 15.0);
        assert!(clear(&b, 40, 50) && opaque(&b, 95, 50));
    }
}
