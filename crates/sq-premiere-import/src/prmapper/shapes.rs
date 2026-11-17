// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRMapper.swift (shape layers). `AE.ADBE Shape` components of templates -> Graphics layers.

use super::{ClipContext, Mapping};
use crate::prcontainer::{decode_base64_lenient, safe_int, utf16le_units};
use crate::prdocument::{PRComponent, PRParamValue};
use crate::primport_report::Status;
use crate::prtext_blob::Rgb;
use serde_json::Value;
use sq_core_model::{
    AnimatedProperty, ClipAnimation, ClipEffect, EffectColor, GraphicsContent, GraphicsLayer, ShapeKind,
};
use sq_core_time::Vec2;
use std::collections::BTreeSet;

pub(crate) const SHAPE_MATCH_NAME: &str = "AE.ADBE Shape";

fn sv(comp: &PRComponent, id: i64) -> Option<&str> {
    comp.param(id).and_then(|p| p.static_value.as_deref())
}

fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

/// Bounding box (px, the shape's own space) of an `AE.ADBE Shape` path blob (param 1), layout seen in all 140 real
/// instances: UInt32 2, UInt32 point count, then per point a Float32 (0) and three (x, y) Float32 pairs (vertex and its
/// tangents); one closing byte. `None` when the blob does not fit that layout.
pub(super) fn shape_bounds(b64: Option<&str>) -> Option<(Vec2, Vec2)> {
    let b = decode_base64_lenient(b64?).filter(|b| b.len() >= 8)?;
    let count = u32_at(&b, 4) as usize;
    if u32_at(&b, 0) != 2 || !(3..=4096).contains(&count) || b.len() < 8 + count * 28 {
        return None;
    }
    let mut lo = Vec2::new(f64::INFINITY, f64::INFINITY);
    let mut hi = Vec2::new(f64::NEG_INFINITY, f64::NEG_INFINITY);
    for i in 0..count {
        let x = f64::from(f32::from_bits(u32_at(&b, 8 + i * 28 + 4)));
        let y = f64::from(f32::from_bits(u32_at(&b, 8 + i * 28 + 8)));
        if !(x.is_finite() && y.is_finite()) {
            return None;
        }
        lo = Vec2::new(lo.x.min(x), lo.y.min(y));
        hi = Vec2::new(hi.x.max(x), hi.y.max(y));
    }
    Some((lo, hi))
}

/// True when a Shape layer's bounding box, through its own static transform (Position 4 and Anchor 10 as 0...1 of the
/// frame, Scale 5, Horizontal Scale 6 unless Uniform 7, no Rotation 8), covers the whole frame within a pixel.
pub(super) fn shape_covers_frame(comp: &PRComponent, frame: Vec2) -> bool {
    let Some((lo, hi)) = shape_bounds(comp.param(1).and_then(|p| p.blob.as_deref())) else { return false };
    if [4, 5, 6, 8, 10].iter().any(|&i| comp.param(i).is_some_and(PRParamValue::is_animated))
        || PRParamValue::double(sv(comp, 8)).unwrap_or(0.0) != 0.0
    {
        return false;
    }
    let pos = PRParamValue::point(sv(comp, 4)).unwrap_or(Vec2::new(0.5, 0.5));
    let anchor = PRParamValue::point(sv(comp, 10)).unwrap_or(Vec2::new(0.0, 0.0));
    let sy = PRParamValue::double(sv(comp, 5)).unwrap_or(100.0) / 100.0;
    let sx = if PRParamValue::bool(sv(comp, 7)) == Some(false) {
        PRParamValue::double(sv(comp, 6)).unwrap_or(100.0) / 100.0
    } else {
        sy
    };
    if !(sx > 0.0 && sy > 0.0) {
        return false;
    }
    let x = |q: f64| pos.x * frame.x + sx * (q - anchor.x * frame.x);
    let y = |q: f64| pos.y * frame.y + sy * (q - anchor.y * frame.y);
    x(lo.x) <= 1.0 && y(lo.y) <= 1.0 && x(hi.x) >= frame.x - 1.0 && y(hi.y) >= frame.y - 1.0
}

/// One vertex of a Shape path with its two tangent handles, all absolute px in the shape's own space.
#[derive(Clone, Copy)]
struct ShapePoint {
    v: Vec2,
    tin: Vec2,
    tout: Vec2,
}

#[derive(Clone, Copy, PartialEq)]
enum ShapeForm {
    Rectangle { radius: f64 },
    Ellipse,
    Polygon,
    Curved,
}

/// The vertices of an `AE.ADBE Shape` path blob (layout in `shape_bounds`); `None` when it does not fit.
fn shape_points(b64: Option<&str>) -> Option<Vec<ShapePoint>> {
    let b = decode_base64_lenient(b64?).filter(|b| b.len() >= 8)?;
    let count = u32_at(&b, 4) as usize;
    if u32_at(&b, 0) != 2 || !(3..=4096).contains(&count) || b.len() < 8 + count * 28 {
        return None;
    }
    let f = |o: usize| f64::from(f32::from_bits(u32_at(&b, o)));
    let mut out = Vec::new();
    for i in 0..count {
        let o = 8 + i * 28;
        let p = ShapePoint {
            v: Vec2::new(f(o + 4), f(o + 8)),
            tin: Vec2::new(f(o + 12), f(o + 16)),
            tout: Vec2::new(f(o + 20), f(o + 24)),
        };
        if ![p.v, p.tin, p.tout].iter().all(|q| q.x.is_finite() && q.y.is_finite()) {
            return None;
        }
        out.push(p);
    }
    Some(out)
}

/// What the Graphics model can draw for a path: an axis-aligned rectangle (4 corners, or 8 vertices of a rounded one), an
/// ellipse (4 curved vertices at the middle of the box edges), a straight polygon; anything else is `Curved`.
fn classify_shape(pts: &[ShapePoint]) -> (ShapeForm, Vec2, Vec2) {
    let min = |f: fn(&ShapePoint) -> f64| pts.iter().map(f).fold(f64::INFINITY, f64::min);
    let max = |f: fn(&ShapePoint) -> f64| pts.iter().map(f).fold(f64::NEG_INFINITY, f64::max);
    let lo =
        Vec2::new(if pts.is_empty() { 0.0 } else { min(|p| p.v.x) }, if pts.is_empty() { 0.0 } else { min(|p| p.v.y) });
    let hi =
        Vec2::new(if pts.is_empty() { 0.0 } else { max(|p| p.v.x) }, if pts.is_empty() { 0.0 } else { max(|p| p.v.y) });
    let (w, h, tol) = (hi.x - lo.x, hi.y - lo.y, 0.5);
    if !(w > tol && h > tol) {
        return (ShapeForm::Curved, lo, hi);
    }
    let near = |a: f64, b: f64| (a - b).abs() <= tol;
    let straight = pts.iter().all(|p| (p.tin - p.v).length() < 0.01 && (p.tout - p.v).length() < 0.01);
    let (cx, cy) = ((lo.x + hi.x) / 2.0, (lo.y + hi.y) / 2.0);
    let corner = |p: Vec2| (near(p.x, lo.x) || near(p.x, hi.x)) && (near(p.y, lo.y) || near(p.y, hi.y));
    if pts.len() == 4 {
        if straight && pts.iter().all(|p| corner(p.v)) {
            let distinct: BTreeSet<(i64, i64)> = pts
                .iter()
                .map(|p| {
                    (
                        safe_int(Some((p.v.x - lo.x).round())).unwrap_or(0),
                        safe_int(Some((p.v.y - lo.y).round())).unwrap_or(0),
                    )
                })
                .collect();
            if distinct.len() == 4 {
                return (ShapeForm::Rectangle { radius: 0.0 }, lo, hi);
            }
        }
        let mids = pts.iter().all(|p| {
            (near(p.v.x, cx) && (near(p.v.y, lo.y) || near(p.v.y, hi.y)))
                || (near(p.v.y, cy) && (near(p.v.x, lo.x) || near(p.v.x, hi.x)))
        });
        if mids && !straight {
            // Handles lie along the edge's tangent at about 0.5523 of the radius (a circle quadrant).
            let ok = pts.iter().all(|p| {
                let horizontal = near(p.v.y, lo.y) || near(p.v.y, hi.y);
                let r = if horizontal { w / 2.0 } else { h / 2.0 };
                [p.tin, p.tout].iter().all(|t| {
                    let d = *t - p.v;
                    let (along, across) = if horizontal { (d.x.abs(), d.y.abs()) } else { (d.y.abs(), d.x.abs()) };
                    (along - 0.5523 * r).abs() <= 0.08 * r && across <= tol
                })
            });
            if ok {
                return (ShapeForm::Ellipse, lo, hi);
            }
        }
    }
    if pts.len() == 8 {
        // Rounded rectangle: every vertex on the box edge, a corner radius away from its corner.
        let on_edge = |p: Vec2| near(p.x, lo.x) || near(p.x, hi.x) || near(p.y, lo.y) || near(p.y, hi.y);
        let gap = |p: Vec2| {
            // Distance along the edge to the nearest corner.
            let on_vertical = near(p.x, lo.x) || near(p.x, hi.x);
            if on_vertical {
                (p.y - lo.y).abs().min((p.y - hi.y).abs())
            } else {
                (p.x - lo.x).abs().min((p.x - hi.x).abs())
            }
        };
        if pts.iter().all(|p| on_edge(p.v) && !corner(p.v)) {
            let r = gap(pts[0].v);
            if r > tol && r * 2.0 <= w.min(h) + tol && pts.iter().all(|p| near(gap(p.v), r)) {
                return (ShapeForm::Rectangle { radius: r }, lo, hi);
            }
        }
    }
    (if straight { ShapeForm::Polygon } else { ShapeForm::Curved }, lo, hi)
}

/// Fill, outline and shadow switch of a Shape layer's Appearance (param 2: 8-byte header, UTF-16 JSON `mStyle`).
struct ShapeAppearance {
    fill: Option<Rgb>,
    stroke: Option<(Rgb, f64)>,
    has_shadow: bool,
}

fn shape_appearance(b64: Option<&str>) -> ShapeAppearance {
    let mut out =
        ShapeAppearance { fill: Some(Rgb { red: 0.0, green: 0.0, blue: 0.0 }), stroke: None, has_shadow: false };
    let Some(data) = b64.and_then(decode_base64_lenient).filter(|d| d.len() > 8) else { return out };
    let units: Vec<u16> = utf16le_units(&data[8..]);
    let Ok(mut s) = String::from_utf16(&units) else { return out };
    while s.ends_with('\0') {
        s.pop();
    }
    let Some(style) =
        serde_json::from_str::<Value>(&s).ok().and_then(|j| j.get("mStyle").and_then(Value::as_object).cloned())
    else {
        return out;
    };
    let num = |v: Option<&Value>| match v {
        Some(Value::Number(n)) => n.as_f64(),
        Some(Value::Bool(b)) => Some(f64::from(u8::from(*b))),
        _ => None,
    };
    let rgb = |v: Option<&Value>| {
        let n = num(v)? as i64;
        Some(Rgb {
            red: ((n >> 16) & 255) as f64 / 255.0,
            green: ((n >> 8) & 255) as f64 / 255.0,
            blue: (n & 255) as f64 / 255.0,
        })
    };
    let on = |k: &str| num(style.get(k)).is_some_and(|v| v != 0.0);
    out.fill = if on("mFillVisible") { rgb(style.get("mFillColor")) } else { None };
    if on("mStrokeVisible")
        && let Some(c) = rgb(style.get("mStrokeColor"))
        && let Some(w) = num(style.get("mStrokeWidth")).filter(|&w| w > 0.0)
    {
        out.stroke = Some((c, w));
    }
    out.has_shadow = on("mShadowVisible");
    out
}

impl Mapping<'_> {
    /// A Shape component as a Graphics layer: Rectangle / Ellipse (with fill, outline, corner radius, size and position) or
    /// a straight polygon as a closed path. Pen paths with curves stay out and are listed in the report.
    /// Position 4 and Anchor 10 are fractions of the frame, Scale 5 / Horizontal Scale 6 (unless Uniform 7), Rotation 8,
    /// Opacity 9 in percent; position and opacity keys carry over, other keys use their first value.
    pub(super) fn shape_layer(
        &mut self,
        comp: &PRComponent,
        ctx: &ClipContext,
        frame: Vec2,
        name: &str,
    ) -> Option<GraphicsLayer> {
        use Status::{Approximated, Dropped, Mapped};
        let Some(pts) = shape_points(comp.param(1).and_then(|p| p.blob.as_deref())) else {
            self.report.note("Shape layer", Dropped, "unreadable path");
            return None;
        };
        let (form, lo, hi) = classify_shape(&pts);
        if form == ShapeForm::Curved {
            self.report.note(
                "Shape layer",
                Dropped,
                &format!("pen path with curves ({} points) has no counterpart in the Graphics model", pts.len()),
            );
            return None;
        }
        let pos = PRParamValue::point(sv(comp, 4)).unwrap_or(Vec2::new(0.5, 0.5));
        let anchor = PRParamValue::point(sv(comp, 10)).unwrap_or(Vec2::ZERO);
        let sy = PRParamValue::double(sv(comp, 5)).unwrap_or(100.0) / 100.0;
        let sx = if PRParamValue::bool(sv(comp, 7)) == Some(false) {
            PRParamValue::double(sv(comp, 6)).unwrap_or(100.0) / 100.0
        } else {
            sy
        };
        let rot = PRParamValue::double(sv(comp, 8)).unwrap_or(0.0);
        let (cs, sn) = ((rot * std::f64::consts::PI / 180.0).cos(), (rot * std::f64::consts::PI / 180.0).sin());
        // The shape's local point as an offset from the frame center after anchor, scale, rotation (position added by the
        // caller).
        let offset = |q: Vec2| {
            let dx = sx * (q.x - anchor.x * frame.x);
            let dy = sy * (q.y - anchor.y * frame.y);
            Vec2::new(dx * cs - dy * sn, dx * sn + dy * cs)
        };
        let appearance = shape_appearance(comp.param(2).and_then(|p| p.blob.as_deref()));
        let width = (hi.x - lo.x) * sx;
        let height = (hi.y - lo.y) * sy;
        let stroke_width = appearance.stroke.map_or(0.0, |s| s.1) * (sx + sy) / 2.0;
        let mut layer: GraphicsLayer;
        let mut e: ClipEffect;
        match form {
            ShapeForm::Polygon => {
                let canvas: Vec<Vec2> = pts
                    .iter()
                    .map(|p| {
                        let o = offset(p.v);
                        Vec2::new(pos.x * frame.x + o.x - frame.x / 2.0, pos.y * frame.y + o.y - frame.y / 2.0)
                    })
                    .collect();
                layer = GraphicsLayer::path(self.ids, &canvas, true, EffectColor::WHITE, 1.0);
                layer.name = name.to_string();
                e = match layer.shape_effect() {
                    Some(e) => e.clone(),
                    None => self.make_effect(ClipEffect::SHAPE_EFFECT_KIND),
                };
                if comp.param(4).is_some_and(PRParamValue::is_animated) {
                    self.report.note("Shape layer position keys", Approximated, "polygon: first position");
                }
            }
            _ => {
                let kind = if form == ShapeForm::Ellipse { ShapeKind::Ellipse } else { ShapeKind::Rectangle };
                let o = offset(Vec2::new((lo.x + hi.x) / 2.0, (lo.y + hi.y) / 2.0));
                e = self.make_effect(ClipEffect::SHAPE_EFFECT_KIND);
                e.parameters.insert(ClipEffect::SHAPE_WIDTH_KEY.to_string(), AnimatedProperty::new(width));
                e.parameters.insert(ClipEffect::SHAPE_HEIGHT_KEY.to_string(), AnimatedProperty::new(height));
                if let ShapeForm::Rectangle { radius } = form
                    && radius > 0.0
                {
                    e.parameters.insert(
                        ClipEffect::SHAPE_CORNER_RADIUS_KEY.to_string(),
                        AnimatedProperty::new(radius * (sx + sy) / 2.0),
                    );
                }
                let mut a = ClipAnimation::default();
                let base = Vec2::new(o.x - frame.x / 2.0, o.y - frame.y / 2.0);
                a.position = self.anim(
                    ctx,
                    comp.param(4),
                    Vec2::new(pos.x * frame.x + base.x, pos.y * frame.y + base.y),
                    PRParamValue::point,
                    |p| Vec2::new(p.x * frame.x + base.x, p.y * frame.y + base.y),
                );
                a.rotation = AnimatedProperty::new(rot);
                layer = GraphicsLayer::new(self.ids.next_id(), name, GraphicsContent::Shape { kind });
                layer.animation = a;
                layer.effects = vec![e.clone()];
            }
        }
        if [5, 6, 8, 10].iter().any(|&i| comp.param(i).is_some_and(PRParamValue::is_animated)) {
            self.report.note("Shape layer keys", Approximated, "scale / rotation / anchor keys: the first value");
        }
        e.parameters.insert(
            ClipEffect::SHAPE_FILL_KEY.to_string(),
            AnimatedProperty::new(if appearance.fill.is_none() { 0.0 } else { 1.0 }),
        );
        if let Some(f) = appearance.fill {
            e.colors.insert(
                ClipEffect::SHAPE_FILL_COLOR_KEY.to_string(),
                AnimatedProperty::new(EffectColor { red: f.red, green: f.green, blue: f.blue, alpha: 1.0 }),
            );
        }
        e.parameters.insert(
            ClipEffect::SHAPE_STROKE_KEY.to_string(),
            AnimatedProperty::new(if appearance.stroke.is_none() { 0.0 } else { 1.0 }),
        );
        if let Some((c, _)) = appearance.stroke {
            e.colors.insert(
                ClipEffect::SHAPE_STROKE_COLOR_KEY.to_string(),
                AnimatedProperty::new(EffectColor { red: c.red, green: c.green, blue: c.blue, alpha: 1.0 }),
            );
            e.parameters.insert(ClipEffect::SHAPE_STROKE_WIDTH_KEY.to_string(), AnimatedProperty::new(stroke_width));
        }
        if let Some(i) = layer.effects.iter().position(|x| x.kind == ClipEffect::SHAPE_EFFECT_KIND) {
            layer.effects[i] = e;
        }
        layer.animation.opacity = self.anim(ctx, comp.param(9), 1.0, PRParamValue::double, |v| v / 100.0);
        if appearance.has_shadow {
            self.report.note("Shape layer shadow", Dropped, "the shadow of a shape has no counterpart");
        }
        let label = match form {
            ShapeForm::Ellipse => "ellipse",
            ShapeForm::Polygon => "polygon",
            _ => "rectangle",
        };
        self.report.note("Shape layer", Mapped, label);
        Some(layer)
    }
}
