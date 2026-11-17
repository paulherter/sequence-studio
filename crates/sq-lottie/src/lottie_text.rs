//! Lottie text layers: the first text document of the layer laid out with a font from `sq-text` and turned into one path.
//!
//! Matches Swift: its ThorVG build has no fonts (config.h), so text layers are skipped there; no text animators (`a`), no box
//! text wrapping (`ps`/`sz`), no per-glyph kerning here either: the baseline starts at the layer origin.

use serde_json::Value;
use sq_text::glyph_raster::{GlyphRasterFont, Point as GPoint};
use sq_text::portable_font_match::PortableFontMatch;
use sq_text::text_style::FontWeight;
use std::sync::Arc;
use tiny_skia::{Path, PathBuilder};

/// What a text layer shows at one frame.
pub struct TextDoc {
    pub text: String,
    pub size: f32,
    pub family: String,
    pub style: String,
    /// 0 left, 1 right, 2 center.
    pub justify: i32,
    /// Extra advance per glyph, thousandths of an em.
    pub tracking: f32,
    pub line_height: f32,
    pub fill: Option<[f32; 3]>,
    pub stroke: Option<([f32; 3], f32)>,
}

fn rgb(v: &Value) -> Option<[f32; 3]> {
    let a = v.as_array()?;
    let c = |i: usize| a.get(i).and_then(Value::as_f64).map(|x| x as f32);
    Some([c(0)?, c(1)?, c(2)?])
}

/// The text document of layer `l` at frame `t` (the last keyframe at or before `t`).
pub fn document(l: &Value, root_fonts: &Value, t: f64) -> Option<TextDoc> {
    let keys = l["t"]["d"]["k"].as_array()?;
    let key = keys.iter().rfind(|k| k.get("t").and_then(Value::as_f64).unwrap_or(0.0) <= t).or(keys.first())?;
    let s = &key["s"];
    let font = s.get("f").and_then(Value::as_str).unwrap_or("");
    let entry = root_fonts["list"]
        .as_array()
        .and_then(|list| list.iter().find(|f| f.get("fName").and_then(Value::as_str) == Some(font)));
    let family = entry.and_then(|e| e["fFamily"].as_str()).unwrap_or(font).to_owned();
    let style = entry.and_then(|e| e["fStyle"].as_str()).unwrap_or("").to_owned();
    let size = s.get("s").and_then(Value::as_f64).unwrap_or(12.0) as f32;
    Some(TextDoc {
        text: s.get("t").and_then(Value::as_str)?.to_owned(),
        size,
        family,
        style,
        justify: s.get("j").and_then(Value::as_i64).unwrap_or(0) as i32,
        tracking: s.get("tr").and_then(Value::as_f64).unwrap_or(0.0) as f32,
        line_height: s.get("lh").and_then(Value::as_f64).map_or(size * 1.2, |v| v as f32),
        fill: s.get("fc").and_then(rgb),
        stroke: s.get("sc").and_then(rgb).map(|c| (c, s.get("sw").and_then(Value::as_f64).unwrap_or(1.0) as f32)),
    })
}

/// The bundled or system face for the document's font (unknown families draw in Inter); `None` without any font.
pub fn choose_font(doc: &TextDoc) -> Option<(Arc<GlyphRasterFont>, Vec<f64>)> {
    let st = doc.style.to_lowercase();
    let weight = if st.contains("black") || st.contains("heavy") {
        FontWeight::Heavy
    } else if st.contains("bold") {
        FontWeight::Bold
    } else if st.contains("semi") {
        FontWeight::Semibold
    } else if st.contains("medium") {
        FontWeight::Medium
    } else if st.contains("light") {
        FontWeight::Light
    } else if st.contains("thin") {
        FontWeight::Thin
    } else {
        FontWeight::Regular
    };
    let c = PortableFontMatch::choose(&doc.family, weight, st.contains("italic"), f64::from(doc.size), None)?;
    Some((c.font, c.coords))
}

fn contour(pts: &[GPoint], pb: &mut PathBuilder, sc: f32, ox: f32, oy: f32) {
    let n = pts.len();
    if n < 2 {
        return;
    }
    let mut e: Vec<GPoint> = Vec::with_capacity(n * 2);
    for i in 0..n {
        let (a, b) = (pts[i], pts[(i + 1) % n]);
        e.push(a);
        if !a.on_curve && !b.on_curve {
            e.push(GPoint { x: (a.x + b.x) / 2.0, y: (a.y + b.y) / 2.0, on_curve: true });
        }
    }
    let Some(start) = e.iter().position(|p| p.on_curve) else { return };
    e.rotate_left(start);
    let at = |p: &GPoint| (ox + p.x as f32 * sc, oy - p.y as f32 * sc);
    let len = e.len();
    let (x, y) = at(&e[0]);
    pb.move_to(x, y);
    let mut i = 1;
    while i <= len {
        let p = e[i % len];
        if p.on_curve {
            let (x, y) = at(&p);
            pb.line_to(x, y);
            i += 1;
        } else {
            let (cx, cy) = at(&p);
            let (x, y) = at(&e[(i + 1) % len]);
            pb.quad_to(cx, cy, x, y);
            i += 2;
        }
    }
    pb.close();
}

/// All glyph outlines of the document, baseline of the first line at y = 0, y down.
pub fn text_path(doc: &TextDoc, font: &GlyphRasterFont, coords: &[f64]) -> Option<Path> {
    let upm = (font.units_per_em as f32).max(1.0);
    let sc = doc.size / upm;
    let track = doc.tracking / 1000.0 * doc.size;
    let mut pb = PathBuilder::new();
    for (row, line) in doc.text.split(['\r', '\n']).enumerate() {
        let glyphs: Vec<(i64, f32)> = line
            .chars()
            .map(|c| {
                let g = font.glyph_for(c);
                (g, font.advance_at(g, coords) as f32 * sc + track)
            })
            .collect();
        let width: f32 = glyphs.iter().map(|g| g.1).sum::<f32>() - track;
        let mut x = match doc.justify {
            1 => -width,
            2 => -width / 2.0,
            _ => 0.0,
        };
        let y = row as f32 * doc.line_height;
        for (g, adv) in glyphs {
            for c in font.contours(g, coords) {
                contour(&c, &mut pb, sc, x, y);
            }
            x += adv;
        }
    }
    pb.finish()
}
