// SPDX-License-Identifier: GPL-3.0-or-later
//! Premiere masks as SQ clip masks (`ClipMask`, the one mask system of sq-core-masks).
//!
//! A mask is a `SubComponent` of Opacity (it cuts the picture) or of an effect (it limits that effect). Two layouts exist:
//! `AE.ADBE AEMask` (path param 6) and `AE.ADBE AEMask2` (path param 7, the Premiere 2022+ mask). Layouts checked
//! 2026-11-25 on the 324 masks of the maintainer's projects; the path blobs are little-endian:
//!   AEMask : "2cin" u32 | 2 u32 | 0 u32 | count u32 | flag u32, then per vertex 6 f32 (point, in tangent, out tangent, all
//!            absolute, fractions of the frame) + u32 1 + u32 0 (the last vertex has no trailing 0).
//!   AEMask2: 2 u32 | 1 u32 | 0x7956 u32 | 0 u8 | 2 u32 | count u32 | flag u32, then per vertex 6 f32 + u32 0 (the last
//!            vertex ends with the single byte 1 = closed).
//! A mask without vertices stores the 8 bytes `2, 0`. Mask feather, opacity and expansion are the params next to the
//! path; Inverted is the checkbox right after Expansion (10 / 17).

use super::{ClipContext, Mapping};
use crate::prcontainer::decode_base64_lenient;
use crate::prdocument::{PRComponent, PRParamValue};
use crate::primport_report::Status;
use sq_core_model::{AnimatedProperty, ClipMask, MaskPath, MaskShapeKind, MaskVertex};
use sq_core_time::{Keyframe, KeyframeTrack, Time, Vec2};

/// `MatchName`s of a mask component.
pub(crate) const MASK_V1: &str = "AE.ADBE AEMask";
pub(crate) const MASK_V2: &str = "AE.ADBE AEMask2";

/// Param ids of one mask layout.
struct Layout {
    path: i64,
    feather: i64,
    opacity: i64,
    expansion: i64,
    inverted: i64,
    /// The Transform group of AEMask2 (a tracked mask moves through it).
    transform: Option<TransformIds>,
}

/// Param ids of the AEMask2 Transform group.
struct TransformIds {
    position: i64,
    anchor: i64,
    scale_height: i64,
    scale_width: i64,
    rotation: i64,
}

const LAYOUT_V1: Layout = Layout { path: 6, feather: 7, opacity: 8, expansion: 9, inverted: 10, transform: None };
const LAYOUT_V2: Layout = Layout {
    path: 7,
    feather: 14,
    opacity: 15,
    expansion: 16,
    inverted: 17,
    transform: Some(TransformIds { position: 9, anchor: 10, scale_height: 26, scale_width: 27, rotation: 12 }),
};
const MAX_VERTICES: usize = 20_000;

fn rd_u32(d: &[u8], o: usize) -> Option<u32> {
    Some(u32::from_le_bytes(<[u8; 4]>::try_from(d.get(o..o.checked_add(4)?)?).ok()?))
}

fn rd_f32(d: &[u8], o: usize) -> Option<f64> {
    let v = f32::from_le_bytes(<[u8; 4]>::try_from(d.get(o..o.checked_add(4)?)?).ok()?);
    v.is_finite().then_some(f64::from(v))
}

/// The bezier path in a mask's path blob; `None` for an empty or unknown blob.
pub(crate) fn decode_path(d: &[u8]) -> Option<MaskPath> {
    let (count, first, stride) = if rd_u32(d, 0)? == 0x6E69_6332 && rd_u32(d, 4)? == 2 {
        (rd_u32(d, 12)? as usize, 20, 32)
    } else if rd_u32(d, 0)? == 2 && rd_u32(d, 4)? == 1 {
        (rd_u32(d, 17)? as usize, 25, 28)
    } else {
        return None;
    };
    if !(2..=MAX_VERTICES).contains(&count) {
        return None;
    }
    let mut vertices = Vec::with_capacity(count);
    for i in 0..count {
        let o = first + i * stride;
        let f = |k: usize| rd_f32(d, o + 4 * k);
        let point = Vec2::new(f(0)?, f(1)?);
        let (tin, tout) = (Vec2::new(f(2)?, f(3)?), Vec2::new(f(4)?, f(5)?));
        // Premiere stores the handles as absolute positions; SQ keeps offsets from the point.
        vertices.push(MaskVertex { point, in_tangent: tin - point, out_tangent: tout - point });
    }
    Some(MaskPath { vertices })
}

fn path_of(b64: &str) -> Option<MaskPath> {
    decode_path(&decode_base64_lenient(b64.trim())?)
}

impl Mapping<'_> {
    /// The masks hung under `owner`, as SQ masks (all enabled, Add, named "Mask n"). Reports the ones that cannot come over.
    pub(crate) fn masks_of(&mut self, owner: &PRComponent, ctx: &ClipContext) -> Vec<ClipMask> {
        let mut out = Vec::new();
        for sub in &owner.sub_components {
            let layout = match sub.match_name.as_str() {
                MASK_V1 => &LAYOUT_V1,
                MASK_V2 => &LAYOUT_V2,
                _ => continue,
            };
            let name = format!("Mask ({})", out.len() + 1);
            match self.mask(sub, layout, ctx, &name) {
                Some(m) => out.push(m),
                None => self.report.note("Mask", Status::Dropped, "empty path (no vertices)"),
            }
        }
        out
    }

    fn mask(&mut self, comp: &PRComponent, l: &Layout, ctx: &ClipContext, name: &str) -> Option<ClipMask> {
        let p = comp.param(l.path)?;
        let first = p.blob.as_deref().and_then(path_of).or_else(|| p.keys.iter().find_map(|k| path_of(&k.value)))?;
        let mut m = ClipMask::new(self.ids.next_id(), name, MaskShapeKind::Bezier, first.clone());
        // Tracked or hand-keyed shapes: one key per Premiere key, like every other animated value.
        let keys: Vec<Keyframe<MaskPath>> = p
            .keys
            .iter()
            .filter_map(|k| Some(Keyframe::new(self.ids.next_id(), ctx.local(k.ticks), path_of(&k.value)?)))
            .collect();
        if !keys.is_empty() {
            let value = keys[0].value.clone();
            m.path = AnimatedProperty { value, track: KeyframeTrack::with_keys(keys) };
        }
        let num = |me: &mut Self, id: i64, fallback: f64, lo: f64, hi: f64| {
            me.anim(ctx, comp.param(id), fallback, PRParamValue::double, move |v| v.clamp(lo, hi))
        };
        m.feather = num(self, l.feather, 0.0, 0.0, f64::MAX);
        m.opacity = num(self, l.opacity, 100.0, 0.0, 100.0);
        m.expansion = num(self, l.expansion, 0.0, f64::MIN, f64::MAX);
        m.inverted =
            comp.param(l.inverted).and_then(|p| PRParamValue::bool(p.static_value.as_deref())).unwrap_or(false);
        if let Some(x) = &l.transform {
            self.apply_transform(&mut m, comp, ctx, x);
        }
        Some(m)
    }

    /// AEMask2 Transform (Position, Anchor Point, Scale Width / Height in %, Rotation): turns the path into where Premiere
    /// draws it. `Transformieren` itself is only the group's twirl, the values always count; Position equals Anchor Point
    /// until the mask is moved or tracked. Fractions of the frame, rotated in sequence pixels (shortcut: the sequence frame
    /// stands in for the clip's own frame, exact for a clip that fills the sequence).
    fn apply_transform(&mut self, m: &mut ClipMask, comp: &PRComponent, ctx: &ClipContext, x: &TransformIds) {
        let half = Vec2::new(0.5, 0.5);
        let pos = self.anim(ctx, comp.param(x.position), half, PRParamValue::point, |v| v);
        let anchor = self.anim(ctx, comp.param(x.anchor), half, PRParamValue::point, |v| v);
        let sw = self.anim(ctx, comp.param(x.scale_width), 100.0, PRParamValue::double, |v| v);
        let sh = self.anim(ctx, comp.param(x.scale_height), 100.0, PRParamValue::double, |v| v);
        let rot = self.anim(ctx, comp.param(x.rotation), 0.0, PRParamValue::double, |v| v);
        let animated =
            pos.is_animated() || anchor.is_animated() || sw.is_animated() || sh.is_animated() || rot.is_animated();
        let canvas = Vec2::new(ctx.sequence.width as f64, ctx.sequence.height as f64);
        let at = |t: Option<Time>, path: &MaskPath| {
            let g = |t: Option<Time>| {
                t.map_or((pos.value, anchor.value, sw.value, sh.value, rot.value), |t| {
                    (
                        pos.value_at_local(t),
                        anchor.value_at_local(t),
                        sw.value_at_local(t),
                        sh.value_at_local(t),
                        rot.value_at_local(t),
                    )
                })
            };
            let (p, a, w, h, r) = g(t);
            transform_path(path, p, a, Vec2::new(w / 100.0, h / 100.0), r, canvas)
        };
        if !animated {
            let (p, a) = (pos.value, anchor.value);
            if p == a && sw.value == 100.0 && sh.value == 100.0 && rot.value == 0.0 {
                return;
            }
            m.path.value = at(None, &m.path.value);
            for k in &mut m.path.track.keys {
                k.value = at(None, &k.value);
            }
            return;
        }
        let mut times: Vec<Time> = m.path.track.keys.iter().map(|k| k.time).collect();
        for t in [&pos, &anchor] {
            times.extend(t.track.keys.iter().map(|k| k.time));
        }
        for t in [&sw, &sh, &rot] {
            times.extend(t.track.keys.iter().map(|k| k.time));
        }
        times.sort();
        times.dedup();
        let keys: Vec<Keyframe<MaskPath>> = times
            .into_iter()
            .map(|t| Keyframe::new(self.ids.next_id(), t, at(Some(t), &m.path.value_at_local(t))))
            .collect();
        m.path = AnimatedProperty { value: keys[0].value.clone(), track: KeyframeTrack::with_keys(keys) };
    }

    /// Hands the masks of `owner` to the clip: Opacity masks cut the picture, an effect's masks only limit that effect.
    pub(crate) fn attach_masks(
        &mut self,
        owner: &PRComponent,
        masks: Vec<ClipMask>,
        effect: Option<&mut sq_core_model::ClipEffect>,
    ) {
        if masks.is_empty() {
            return;
        }
        match effect {
            None if owner.match_name == "AE.ADBE Opacity" => {
                for _ in &masks {
                    self.report.note("Mask", Status::Mapped, "Opacity mask");
                }
                self.pending_masks.extend(masks);
            }
            Some(e) => {
                for mut m in masks {
                    m.set_used_by_opacity(false);
                    e.mask_input.push(m.id);
                    self.report.note("Mask", Status::Mapped, "limits an effect");
                    self.pending_masks.push(m);
                }
            }
            None => {
                for _ in &masks {
                    self.report.note(
                        "Mask",
                        Status::Dropped,
                        &format!("its effect ({}) is not imported", owner.match_name),
                    );
                }
            }
        }
    }
}

/// The path moved by Premiere's mask Transform: `pos + R(rot) * S * (p - anchor)`, rotating clockwise in pixel space
/// (`canvas` px); handles are offsets, so they scale and rotate but do not move.
pub(crate) fn transform_path(
    path: &MaskPath,
    pos: Vec2,
    anchor: Vec2,
    scale: Vec2,
    degrees: f64,
    canvas: Vec2,
) -> MaskPath {
    let (sin, cos) = degrees.to_radians().sin_cos();
    let turn = |d: Vec2| {
        let (x, y) = (d.x * canvas.x * scale.x, d.y * canvas.y * scale.y);
        Vec2::new((x * cos - y * sin) / canvas.x, (x * sin + y * cos) / canvas.y)
    };
    MaskPath {
        vertices: path
            .vertices
            .iter()
            .map(|v| MaskVertex {
                point: pos + turn(v.point - anchor),
                in_tangent: turn(v.in_tangent),
                out_tangent: turn(v.out_tangent),
            })
            .collect(),
    }
}
