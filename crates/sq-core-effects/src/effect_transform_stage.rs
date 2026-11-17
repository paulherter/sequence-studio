// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectTransformStage.swift, Grouping.swift (the group-stage evaluation, moved up from the edit side)
//! W7.1 effect transform stage. An effect of kind `transform` (Effects panel > Transform) or `reframe` (written by Auto
//! Reframe, not offered in the panel) carries its own Position / Scale / Rotation / Anchor / Opacity that start at its own
//! 100 % and multiply onto the clip's Motion: a 110 % stage on a clip at 120 % renders at 132 %, and the user's own
//! Motion values and keys are never touched.
//!
//! Order: the stages act on the clip's own frame (source px from the frame center, y down) in list order, then Motion
//! places the result: render = Motion . stage_n . ... . stage_1. One stage maps p to R s (p - anchor) + anchor + position.
//! Pixel effects (Crop, Blur, Shadow, ...) are applied before every stage, whatever their place in the list.
//! The composed result is one `ClipTransform`; it is exact unless Motion's scale is non-uniform and the stages rotate
//! (that needs a skew): then the frame center lands exactly and the picture is scaled after the summed rotation.
//!
//! Shutter Angle (Transform, and Motion's own since FB-G) blurs the clip's whole rendered motion (Motion and stages): the
//! largest angle of Motion and the enabled stages opens a shutter centered on the frame, sampled `sample_count` times
//! (`LayerRequest::motion_blur`). Nested-sequence clips get the stage but no motion blur.

use crate::motion_effects::MotionEffects;
use crate::temporal_effects::{MotionBlurShutter, ShutterSide};
use sq_core_masks::{ClipEffectStabilizeExt, MaskInputsExt, StabilizerMethod};
use sq_core_model::{
    Affine2, AnimatedProperty, Clip, ClipEffect, ClipTransform, Project, SequenceFormat, StageTransform,
};
use sq_core_time::{Id, IdSource, Keyframe, KeyframeTrack, Time, Vec2};
use std::f64::consts::PI;

/// Sub-frame transforms of one layer for motion blur: `transforms` (oldest first, same opacity as the layer) are drawn
/// with 1 / count of the opacity each and summed in a transparent `format` image.
#[derive(Clone, Debug, PartialEq)]
pub struct MotionBlurSamples {
    /// The canvas of the sequence the layer lives in.
    pub format: SequenceFormat,
    /// The sub-frame transforms, oldest first.
    pub transforms: Vec<ClipTransform>,
    /// The clip-local time of each sample (parallel to `transforms`): a text layer evaluates its own In/Out animation
    /// there, because that motion is not part of the clip's transform.
    pub local_times: Vec<Time>,
}

/// Evaluation of the effect transform stage (Swift `extension ClipEffect`).
pub trait ClipEffectStage {
    /// Transform, Auto Reframe, Dynamic Zoom, Stabilizer or a motion preset: an effect with its own transform stage.
    fn is_transform_stage(&self) -> bool;

    /// The stage at clip-local `t` (identity for any other kind). Reads the stage keys directly (defaults and ranges as in
    /// the catalog), no catalog lookup: this runs per sub-frame sample on the render tick.
    ///
    /// Motion presets (Move, Zoom, Pop, Fade, Shake) also need the clip's timeline length (Out and In & Out anchor to its
    /// end; `None` = no end edge) and the canvas size in px (distances are a share of the canvas). Their Move and Shake
    /// positions come back in CANVAS px; `ClipStageEval::render_transform` converts them to the stage's source px.
    fn stage_transform(&self, t: Time, clip_duration: Option<Time>, frame: Vec2) -> StageTransform;

    /// Shutter Angle at clip-local `t`: Transform's, and a motion preset's when it carries one (the element transitions
    /// write it from their Motion Blur; a preset applied as an effect has none). 0 for any other kind.
    fn stage_shutter_angle(&self, t: Time) -> f64;
}

impl ClipEffectStage for ClipEffect {
    fn is_transform_stage(&self) -> bool {
        self.kind == ClipEffect::TRANSFORM_KIND
            || self.kind == ClipEffect::REFRAME_KIND
            || self.kind == ClipEffect::DYNAMIC_ZOOM_KIND
            || self.kind == ClipEffect::STABILIZE_KIND
            || self.is_motion_preset()
    }

    fn stage_transform(&self, t: Time, clip_duration: Option<Time>, frame: Vec2) -> StageTransform {
        if !self.is_transform_stage() {
            return StageTransform::IDENTITY;
        }
        // A Gyroflow Stabilizer renders in its own pass; leftover Standard keys must not move the picture as well.
        if self.kind == ClipEffect::STABILIZE_KIND && self.stabilize_method() != StabilizerMethod::Standard {
            return StageTransform::IDENTITY;
        }
        if self.is_motion_preset() {
            return MotionEffects::stage(self, t, clip_duration, frame);
        }
        let v = |k: &str, d: f64, lo: f64, hi: f64| -> f64 {
            self.parameters.get(k).map_or(d, |p| p.value_at_local(t)).clamp(lo, hi)
        };
        let p = 100_000.0;
        StageTransform {
            position: Vec2::new(
                v(ClipEffect::STAGE_POSITION_X_KEY, 0.0, -p, p),
                v(ClipEffect::STAGE_POSITION_Y_KEY, 0.0, -p, p),
            ),
            scale: v(ClipEffect::STAGE_SCALE_KEY, 100.0, 0.0, 10_000.0) / 100.0,
            scale_y_override: if self.parameters.contains_key(ClipEffect::STAGE_SCALE_Y_KEY) {
                Some(v(ClipEffect::STAGE_SCALE_Y_KEY, 100.0, 0.0, 10_000.0) / 100.0)
            } else {
                None
            },
            rotation: v(ClipEffect::STAGE_ROTATION_KEY, 0.0, -36_000.0, 36_000.0),
            anchor: Vec2::new(
                v(ClipEffect::STAGE_ANCHOR_X_KEY, 0.0, -p, p),
                v(ClipEffect::STAGE_ANCHOR_Y_KEY, 0.0, -p, p),
            ),
            opacity: v(ClipEffect::STAGE_OPACITY_KEY, 100.0, 0.0, 100.0) / 100.0,
        }
    }

    fn stage_shutter_angle(&self, t: Time) -> f64 {
        if self.kind != ClipEffect::TRANSFORM_KIND && !self.is_motion_preset() {
            return 0.0;
        }
        self.parameters.get(ClipEffect::STAGE_SHUTTER_ANGLE_KEY).map_or(0.0, |p| p.value_at_local(t)).clamp(0.0, 360.0)
    }
}

/// The stage helpers that are not tied to a clip.
pub enum EffectTransformStage {}

impl EffectTransformStage {
    /// Sub-frame samples for a shutter of `angle` degrees: none when closed, 2 at the least, 16 for a full 360.
    pub fn sample_count(angle: f64) -> i64 {
        if !angle.is_finite() || angle <= 0.0 {
            return 0;
        }
        ((angle.min(360.0) / 22.5).ceil() as i64).clamp(2, 16)
    }

    /// The Auto Reframe stage for a clip whose Motion is `base` (static, at the clip's first frame): together they put the
    /// picture at the absolute framing the planner chose (uniform `scale`, the base anchor at `position`). Position keys
    /// become X and Y keys at the same times with the same easing. `id` is the effect's id; the new keys draw theirs from
    /// `ids`.
    pub fn reframe_effect(
        scale: f64,
        position: &AnimatedProperty<Vec2>,
        base: &ClipTransform,
        id: Id,
        ids: &mut dyn IdSource,
    ) -> ClipEffect {
        // Motion maps q to B (q - a) + P0 with B = R S. With the stage anchor at a: render(p) = B s (p - a) + B pos + P0.
        // The plan wants scale_plan (p - a) + P(t): s = scale_plan / S, pos = B^-1 (P(t) - P0).
        let (sx, sy) = (base.scale.x, base.scale.y);
        let bs = if sx > 0.0 && sy > 0.0 { (sx + sy) / 2.0 } else { 1.0 };
        let inv = Affine2::rot_scale(base.rotation, if sx > 0.0 { sx } else { 1.0 }, if sy > 0.0 { sy } else { 1.0 });
        let det = inv.a * inv.d - inv.b * inv.c;
        let local = |p: Vec2| -> Vec2 {
            let q = p - base.position;
            Vec2::new((inv.d * q.x - inv.b * q.y) / det, (-inv.c * q.x + inv.a * q.y) / det)
        };
        let mut split = |axis: fn(&Vec2) -> f64| -> AnimatedProperty<f64> {
            let keys = position
                .track
                .keys
                .iter()
                .map(|k| {
                    let mut n = Keyframe::new(ids.next_id(), k.time, axis(&local(k.value)));
                    n.interpolation = k.interpolation;
                    n.in_handle = k.in_handle;
                    n.out_handle = k.out_handle;
                    n
                })
                .collect();
            AnimatedProperty { value: axis(&local(position.value)), track: KeyframeTrack::with_keys(keys) }
        };
        let position_x = split(|v| v.x);
        let position_y = split(|v| v.y);
        // `reframe` is a catalog kind, so `make` always finds it; an unknown kind would give a bare effect.
        let mut e = ClipEffect::make(id, ClipEffect::REFRAME_KIND)
            .unwrap_or_else(|| ClipEffect::new(id, ClipEffect::REFRAME_KIND));
        e.parameters.insert(ClipEffect::STAGE_ANCHOR_X_KEY.to_string(), AnimatedProperty::new(base.anchor.x));
        e.parameters.insert(ClipEffect::STAGE_ANCHOR_Y_KEY.to_string(), AnimatedProperty::new(base.anchor.y));
        e.parameters.insert(ClipEffect::STAGE_SCALE_KEY.to_string(), AnimatedProperty::new(scale / bs * 100.0));
        e.parameters.insert(ClipEffect::STAGE_POSITION_X_KEY.to_string(), position_x);
        e.parameters.insert(ClipEffect::STAGE_POSITION_Y_KEY.to_string(), position_y);
        e
    }
}

/// Clip-level evaluation of the transform stages and motion blur (Swift `extension Clip`).
pub trait ClipStageEval {
    /// Has an enabled Transform / Auto Reframe effect.
    fn has_transform_stage(&self) -> bool;

    /// `e` is an enabled stage of the clip's transform. A Transform with a live mask input is not: it warps the picture
    /// inside its masks instead (`EffectSegment::filter` = `ImageFilter::StageWarp`).
    fn moves_clip(&self, e: &ClipEffect) -> bool;

    /// What the renderer draws at timeline time `t`: Motion (`transform`) after the clip's enabled transform stages. Equal
    /// to `transform` when there is no stage. `frame` is the canvas the clip renders on (motion presets measure distances
    /// against it). Group Transform effects (an ungrouped Group's Motion) then act on the result in canvas px.
    fn render_transform(&self, t: Time, frame: Vec2) -> ClipTransform;

    /// `render_transform` with the first enabled stage's index known (no rescan per motion-blur sample).
    fn render_transform_from(&self, t: Time, stages_from: usize, frame: Vec2) -> ClipTransform;

    /// Nothing that places the picture changes over time: no keyed Motion or Opacity property, no keyed parameter on an
    /// enabled transform or group stage, no live motion preset (they evaluate from the clip time). An open shutter then
    /// has nothing to blur, so `motion_blur` skips the sub-frame samples.
    fn transform_is_static(&self) -> bool;

    /// Motion-blur samples at `t` for a clip whose Motion or transform stages open a shutter; `None` when it is closed or
    /// nothing moves.
    fn motion_blur(&self, t: Time, fd: Time, format: &SequenceFormat, opacity_factor: f64)
    -> Option<MotionBlurSamples>;
}

fn staged_transform(c: &Clip, t: Time, first: usize, frame: Vec2) -> ClipTransform {
    let base = c.transform(t);
    let local = t - c.start;
    let length = c.duration();
    let motion = Affine2::rot_scale(base.rotation, base.scale.x, base.scale.y);
    // Motion presets (Move, Shake) work in canvas px: a stage position p becomes (Motion after the later stages)^-1 p, so
    // the on-canvas shift is right whatever the clip's scale, Motion rotation or later stages. Collected first, converted
    // last-to-first.
    let mut staged: Vec<(usize, StageTransform)> = Vec::new();
    for i in first..c.effects.len() {
        if c.moves_clip(&c.effects[i]) {
            staged.push((i, c.effects[i].stage_transform(local, Some(length), frame)));
        }
    }
    let mut later = motion;
    for k in (0..staged.len()).rev() {
        let mut s = staged[k].1;
        s.scale = s.scale.max(0.0);
        s.scale_y_override = Some(s.scale_y().max(0.0));
        if c.effects[staged[k].0].is_motion_preset() && s.position != Vec2::ZERO {
            let det = later.a * later.d - later.b * later.c;
            if det.abs() > 1e-12 {
                let p = s.position;
                s.position = Vec2::new((later.d * p.x - later.b * p.y) / det, (-later.c * p.x + later.a * p.y) / det);
            } else {
                s.position = Vec2::ZERO;
            }
        }
        staged[k].1 = s;
        later = later.after(&Affine2::rot_scale(s.rotation, s.scale, s.scale_y()));
    }
    let mut f = Affine2::IDENTITY;
    let mut rotation = 0.0;
    let mut scale = Vec2::new(1.0, 1.0);
    let mut opacity = 1.0;
    let mut any = false;
    for (_, s) in &staged {
        opacity *= s.opacity.clamp(0.0, 1.0);
        if s.is_identity() {
            continue;
        }
        let mut cs = *s;
        cs.scale = s.scale.max(0.0);
        cs.scale_y_override = Some(s.scale_y().max(0.0));
        f = Affine2::from(&cs).after(&f);
        rotation += cs.rotation;
        scale = Vec2::new(scale.x * cs.scale, scale.y * cs.scale_y());
        any = true;
    }
    let mut out = base;
    out.opacity = base.opacity * opacity;
    if !any {
        return out;
    }
    // Exact center: Motion after the stages, evaluated at the frame center.
    let centre = motion.linear(f.t - base.anchor) + base.position;
    out.rotation = base.rotation + rotation;
    out.scale = Vec2::new(base.scale.x * scale.x, base.scale.y * scale.y);
    // Keep Motion's anchor: position = center + L anchor, so map(.zero) == center.
    out.position = centre + Affine2::rot_scale(out.rotation, out.scale.x, out.scale.y).linear(base.anchor);
    out
}

/// The widest shutter open at clip-local `local`: Motion's own (when Motion is on) and every enabled stage's, 0...360.
fn shutter_angle(c: &Clip, local: Time, stages_from: Option<usize>) -> f64 {
    let mut angle =
        if c.motion_enabled { c.animation.shutter_angle.value_at_local(local).clamp(0.0, 360.0) } else { 0.0 };
    if let Some(first) = stages_from {
        for e in c.effects.iter().skip(first) {
            if e.enabled && !c.has_live_mask_input(e) {
                angle = angle.max(e.stage_shutter_angle(local));
            }
        }
    }
    angle
}

impl ClipStageEval for Clip {
    fn has_transform_stage(&self) -> bool {
        self.effects.iter().any(|e| self.moves_clip(e))
    }

    fn moves_clip(&self, e: &ClipEffect) -> bool {
        e.enabled && e.is_transform_stage() && !self.has_live_mask_input(e) && !e.stabilize_fills_edges()
    }

    fn render_transform(&self, t: Time, frame: Vec2) -> ClipTransform {
        match self.effects.iter().position(|e| self.moves_clip(e)) {
            Some(first) => self.render_transform_from(t, first, frame),
            None => self.applying_group_stages(&self.transform(t), t),
        }
    }

    fn render_transform_from(&self, t: Time, stages_from: usize, frame: Vec2) -> ClipTransform {
        self.applying_group_stages(&staged_transform(self, t, stages_from, frame), t)
    }

    fn transform_is_static(&self) -> bool {
        let a = &self.animation;
        if self.motion_enabled
            && (a.position.is_animated()
                || a.scale.is_animated()
                || a.rotation.is_animated()
                || a.anchor.is_animated()
                || a.tilt_x.is_animated()
                || a.tilt_y.is_animated())
        {
            return false;
        }
        if self.opacity_enabled && a.opacity.is_animated() {
            return false;
        }
        for e in &self.effects {
            if self.moves_clip(e) || (e.enabled && e.kind == ClipEffect::GROUP_TRANSFORM_KIND) {
                if e.is_motion_preset() {
                    return false;
                }
                if e.parameters.values().any(|p| p.is_animated()) || e.points.values().any(|p| p.is_animated()) {
                    return false;
                }
            }
        }
        true
    }

    fn motion_blur(
        &self,
        t: Time,
        fd: Time,
        format: &SequenceFormat,
        opacity_factor: f64,
    ) -> Option<MotionBlurSamples> {
        let first = self.effects.iter().position(|e| self.moves_clip(e));
        let has_effect = self.effects.iter().any(|e| e.enabled && e.kind == ClipEffect::MOTION_BLUR_KIND);
        if first.is_none() && !has_effect && !(self.motion_enabled && self.animation.is_shutter_open_or_keyed()) {
            return None;
        }
        let local = t - self.start;
        // The widest shutter wins: Motion's / a transform stage's (centered, its own sample count) or the Motion Blur
        // effect's (its own side and smoothness).
        let mut shutter = MotionBlurShutter::new(shutter_angle(self, local, first));
        if has_effect
            && let Some(fx) = MotionBlurShutter::of(&self.effects, local)
            && fx.angle >= shutter.angle
        {
            shutter = fx;
        }
        let n = shutter.sample_count();
        if n < 2 || fd.value() <= 0 {
            return None;
        }
        // Sample k at t + fd * A/360 * s_k, A whole degrees, s_k = k/(n-1) - 1/2 (both sides), k/(n-1) - 1 (from the
        // previous frame) or k/(n-1) (toward the next): rational offsets, never Double time.
        let a = shutter.angle.min(360.0).round() as i64;
        // A text layer also moves through its own In/Out animation, evaluated at the raster stage per sample time
        // (`MotionBlurSamples::local_times`), so a still Motion does not make it sharp.
        // shortcut: a text clip with an open shutter always takes the sampled path, even when no animation moves; upgrade
        // by asking the text animation whether it is static.
        let text = self.generator.as_ref().is_some_and(|g| g.kind == crate::sequence_conform::TEXT_KIND);
        if a <= 0 || (!text && self.transform_is_static()) {
            return None;
        }
        let den = 720 * (n - 1);
        let shift: i64 = match shutter.side {
            ShutterSide::Both => -(n - 1),
            ShutterSide::FromPrevious => -2 * (n - 1),
            ShutterSide::TowardNext => 0,
        };
        let frame = Vec2::new(format.display_width() as f64, format.height as f64);
        let mut out: Vec<ClipTransform> = Vec::with_capacity(n as usize);
        let mut local_times: Vec<Time> = Vec::with_capacity(n as usize);
        for k in 0..n {
            let tk = t + Time::scaled_int(fd, a * (2 * k + shift), den);
            local_times.push(tk - self.start);
            let mut tr = match first {
                Some(f) => self.render_transform_from(tk, f, frame),
                None => self.render_transform(tk, frame),
            };
            tr.opacity *= opacity_factor;
            out.push(tr);
        }
        if !text && !out.iter().any(|x| *x != out[0]) {
            return None;
        }
        Some(MotionBlurSamples { format: format.clone(), transforms: out, local_times })
    }
}

/// Project-level shutter query (Swift `extension Project`).
pub trait ProjectMotionShutter {
    /// Some clip opens Motion's own Shutter Angle (v40).
    fn contains_motion_shutter(&self) -> bool;
}

impl ProjectMotionShutter for Project {
    fn contains_motion_shutter(&self) -> bool {
        // Also a baked effect's Motion: Re-open as Effect restores it, and older builds would drop its shutter.
        self.timelines.iter().any(|tl| {
            tl.tracks.iter().any(|tr| {
                tr.clips().iter().any(|c| {
                    c.animation.is_shutter_open_or_keyed()
                        || c.baked_store.iter().flatten().any(|b| b.motion.is_shutter_open_or_keyed())
                })
            })
        })
    }
}

// Group stages (Grouping.swift): an ungrouped Group's Motion lives on its clips as Group Transform effects.

/// Group Transform evaluation of one effect.
pub trait ClipEffectGroupStage {
    /// The group's transform at clip-local `t` (clamped like `Clip::transform`).
    fn group_stage(&self, t: Time) -> ClipTransform;
}

impl ClipEffectGroupStage for ClipEffect {
    fn group_stage(&self, t: Time) -> ClipTransform {
        let s = self.points.get(ClipEffect::GROUP_SCALE_KEY).map_or(Vec2::new(1.0, 1.0), |p| p.value_at_local(t));
        ClipTransform {
            position: self.points.get(ClipEffect::GROUP_POSITION_KEY).map_or(Vec2::ZERO, |p| p.value_at_local(t)),
            scale: Vec2::new(s.x.max(0.0), s.y.max(0.0)),
            rotation: self.parameters.get(ClipEffect::GROUP_ROTATION_KEY).map_or(0.0, |p| p.value_at_local(t)),
            opacity: self
                .parameters
                .get(ClipEffect::GROUP_OPACITY_KEY)
                .map_or(1.0, |p| p.value_at_local(t))
                .clamp(0.0, 1.0),
            anchor: self.points.get(ClipEffect::GROUP_ANCHOR_KEY).map_or(Vec2::ZERO, |p| p.value_at_local(t)),
            ..ClipTransform::IDENTITY
        }
    }
}

/// Composition of group transforms.
pub trait ClipTransformGroup {
    /// `self` (an outer, group transform) applied after `inner`: one transform that maps a point as
    /// `self.map(inner.map(p))`. Exact when `self`'s scale is uniform or `inner` is not rotated; otherwise the anchor
    /// lands exactly and the picture is scaled after the summed rotation (no skew). Opacities multiply.
    fn composed(&self, inner: &ClipTransform) -> ClipTransform;

    /// Inverse of `composed` for a chain: `self` drawn after the group `stages` (in list order) becomes the transform the
    /// clip had before them. A stage with zero scale or opacity cannot be undone and leaves that component unchanged.
    fn removing_group_stages(&self, stages: &[ClipTransform]) -> ClipTransform;
}

impl ClipTransformGroup for ClipTransform {
    fn composed(&self, inner: &ClipTransform) -> ClipTransform {
        let l = Affine2::rot_scale(self.rotation, self.scale.x, self.scale.y);
        ClipTransform {
            position: l.linear(inner.position - self.anchor) + self.position,
            scale: Vec2::new(self.scale.x * inner.scale.x, self.scale.y * inner.scale.y),
            rotation: self.rotation + inner.rotation,
            opacity: self.opacity * inner.opacity,
            anchor: inner.anchor,
            tilt_x: inner.tilt_x,
            tilt_y: inner.tilt_y,
        }
    }

    fn removing_group_stages(&self, stages: &[ClipTransform]) -> ClipTransform {
        let mut out = *self;
        for g in stages.iter().rev() {
            let a = -g.rotation * PI / 180.0;
            let d = out.position - g.position;
            let r = Vec2::new(d.x * a.cos() - d.y * a.sin(), d.x * a.sin() + d.y * a.cos());
            let sx = if g.scale.x.abs() > 1e-9 { g.scale.x } else { 1.0 };
            let sy = if g.scale.y.abs() > 1e-9 { g.scale.y } else { 1.0 };
            out.position = Vec2::new(r.x / sx + g.anchor.x, r.y / sy + g.anchor.y);
            out.scale = Vec2::new(out.scale.x / sx, out.scale.y / sy);
            out.rotation -= g.rotation;
            if g.opacity > 1e-9 {
                out.opacity /= g.opacity;
            }
        }
        out
    }
}

/// Group stages of a clip.
pub trait ClipGroupStages {
    /// `tr` after the clip's enabled Group Transform effects, in list order (the first is the innermost group).
    fn applying_group_stages(&self, tr: &ClipTransform, t: Time) -> ClipTransform;

    /// The enabled Group Transform effects of this clip at `t` as transforms, in list order (the first is the innermost
    /// group).
    fn group_stage_transforms(&self, t: Time) -> Vec<ClipTransform>;
}

impl ClipGroupStages for Clip {
    fn applying_group_stages(&self, tr: &ClipTransform, t: Time) -> ClipTransform {
        let mut out = *tr;
        let local = t - self.start;
        for e in self.effects.iter().filter(|e| e.enabled && e.kind == ClipEffect::GROUP_TRANSFORM_KIND) {
            out = e.group_stage(local).composed(&out);
        }
        out
    }

    fn group_stage_transforms(&self, t: Time) -> Vec<ClipTransform> {
        self.effects
            .iter()
            .filter(|e| e.enabled && e.kind == ClipEffect::GROUP_TRANSFORM_KIND)
            .map(|e| e.group_stage(t - self.start))
            .collect()
    }
}

/// Test helpers shared by the tests of the evaluation modules.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use sq_core_model::{Timeline, Track, TrackKind};
    use sq_core_time::TimeRange;

    pub fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    pub fn fd() -> Time {
        Time::new(1, 25)
    }

    pub fn clip(effects: Vec<ClipEffect>) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(1),
            "v",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, s(4)),
            Time::ZERO,
        );
        c.effects = effects;
        c
    }

    pub fn stage(values: &[(&str, f64)], kind: &str) -> ClipEffect {
        let mut e = ClipEffect::make(Id::from_u128(7), kind).expect("catalog kind");
        for (k, v) in values {
            e.parameters.insert((*k).to_string(), AnimatedProperty::new(*v));
        }
        e
    }

    pub fn transform_stage(values: &[(&str, f64)]) -> ClipEffect {
        stage(values, ClipEffect::TRANSFORM_KIND)
    }

    pub fn close(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() <= tol
    }

    pub fn close2(a: Vec2, b: Vec2, tol: f64) -> bool {
        close(a.x, b.x, tol) && close(a.y, b.y, tol)
    }

    pub fn ramp(key: &str, from: f64, to: f64, secs: i64) -> (String, AnimatedProperty<f64>) {
        let mut ids = sq_core_time::SequentialIds::default();
        let keys = vec![Keyframe::new(ids.next_id(), Time::ZERO, from), Keyframe::new(ids.next_id(), s(secs), to)];
        (key.to_string(), AnimatedProperty { value: from, track: KeyframeTrack::with_keys(keys) })
    }

    pub fn canvas() -> SequenceFormat {
        SequenceFormat {
            width: 640,
            height: 360,
            frame_duration: fd(),
            audio_sample_rate: 48_000,
            pixel_aspect_store: None,
            unknown: sq_core_model::UnknownKeys::default(),
        }
    }

    pub fn timeline_of(c: Clip) -> Timeline {
        let mut track = Track::new(Id::from_u128(51), TrackKind::Video);
        let mut ids = sq_core_time::SequentialIds::default();
        // The clip is the only one on the track, so the insert cannot overlap.
        let _ = track.insert(c, &mut ids);
        Timeline::new(Id::from_u128(50), "S", canvas(), vec![track])
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::*;
    use super::*;
    use sq_core_model::EffectCatalog;

    const FRAME: Vec2 = Vec2::new(1920.0, 1080.0);

    fn render(c: &Clip, t: Time) -> ClipTransform {
        c.render_transform(t, FRAME)
    }

    fn tstage(values: &[(&str, f64)]) -> ClipEffect {
        transform_stage(values)
    }

    #[test]
    fn motion_shutter_blurs_a_text_clips_keyed_scale() {
        use sq_core_model::GeneratorRef;
        let mut ids = sq_core_time::SequentialIds::default();
        let mut c = clip(vec![]);
        c.generator = Some(GeneratorRef { kind: "text".into(), payload: b"t".to_vec(), payload_version: 1 });
        let keys = KeyframeTrack::with_keys(vec![
            Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(3.0, 3.0)),
            Keyframe::new(ids.next_id(), s(2), Vec2::new(1.0, 1.0)),
        ]);
        c.animation.scale = AnimatedProperty { value: Vec2::new(3.0, 3.0), track: keys };
        assert!(c.motion_blur(s(1), fd(), &canvas(), 1.0).is_none(), "closed shutter is sharp");
        c.animation.shutter_angle = AnimatedProperty::new(180.0);
        let mb = c.motion_blur(s(1), fd(), &canvas(), 1.0).expect("samples");
        assert!(mb.transforms.first().unwrap().scale.x > mb.transforms.last().unwrap().scale.x);
        assert_eq!(mb.local_times.len(), mb.transforms.len());
    }

    #[test]
    fn a_text_clip_with_still_motion_still_takes_the_sampled_path() {
        use sq_core_model::GeneratorRef;
        let mut c = clip(vec![]);
        c.generator = Some(GeneratorRef { kind: "text".into(), payload: b"t".to_vec(), payload_version: 1 });
        c.animation.shutter_angle = AnimatedProperty::new(180.0);
        let mb = c.motion_blur(s(1), fd(), &canvas(), 1.0).expect("samples");
        assert!(mb.local_times.len() >= 2);
        let mut shape = clip(vec![]);
        shape.animation.shutter_angle = AnimatedProperty::new(180.0);
        assert!(shape.motion_blur(s(1), fd(), &canvas(), 1.0).is_none());
    }

    #[test]
    fn transform_is_offered_and_reframe_is_known_but_hidden() {
        assert!(EffectCatalog::all().iter().any(|s| s.kind == ClipEffect::TRANSFORM_KIND));
        assert!(!EffectCatalog::all().iter().any(|s| s.kind == ClipEffect::REFRAME_KIND));
        assert!(EffectCatalog::spec_for(ClipEffect::REFRAME_KIND).is_some());
        assert!(EffectCatalog::param(ClipEffect::TRANSFORM_KIND, ClipEffect::STAGE_SHUTTER_ANGLE_KEY).is_some());
    }

    #[test]
    fn fresh_stage_starts_at_its_own_hundred_percent() {
        let e = tstage(&[]);
        assert!(e.is_transform_stage());
        assert_eq!(e.stage_transform(Time::ZERO, None, FRAME), StageTransform::IDENTITY);
        assert_eq!(render(&clip(vec![e]), s(1)), clip(vec![]).transform(s(1)));
    }

    #[test]
    fn effect_scale_multiplies_onto_base_scale() {
        let mut c = clip(vec![tstage(&[(ClipEffect::STAGE_SCALE_KEY, 110.0)])]);
        c.animation.scale = AnimatedProperty::new(Vec2::new(1.2, 1.2));
        let r = render(&c, s(1));
        assert!(close(r.scale.x, 1.32, 1e-9) && close(r.scale.y, 1.32, 1e-9));
        // The user's own value is untouched.
        assert_eq!(c.transform(s(1)).scale, Vec2::new(1.2, 1.2));
        assert_eq!(c.animation.scale.value, Vec2::new(1.2, 1.2));
    }

    #[test]
    fn user_scale_keys_stay_untouched_and_still_animate() {
        let mut c = clip(vec![tstage(&[(ClipEffect::STAGE_SCALE_KEY, 110.0)])]);
        let mut ids = sq_core_time::SequentialIds::default();
        let keys = KeyframeTrack::with_keys(vec![
            Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(1.0, 1.0)),
            Keyframe::new(ids.next_id(), s(2), Vec2::new(1.2, 1.2)),
        ]);
        c.animation.scale = AnimatedProperty { value: Vec2::new(1.0, 1.0), track: keys };
        let before = c.animation.clone();
        assert!(close(render(&c, Time::ZERO).scale.x, 1.1, 1e-9));
        assert!(close(render(&c, s(1)).scale.x, 1.21, 1e-9));
        assert!(close(render(&c, s(2)).scale.x, 1.32, 1e-9));
        assert_eq!(c.animation, before);
    }

    #[test]
    fn position_is_in_the_clips_own_pixels_so_it_scales_with_motion() {
        let mut c =
            clip(vec![tstage(&[(ClipEffect::STAGE_POSITION_X_KEY, 10.0), (ClipEffect::STAGE_POSITION_Y_KEY, -5.0)])]);
        c.animation.scale = AnimatedProperty::new(Vec2::new(2.0, 2.0));
        c.animation.position = AnimatedProperty::new(Vec2::new(100.0, 50.0));
        assert!(close2(render(&c, s(1)).map(Vec2::ZERO), Vec2::new(120.0, 40.0), 1e-9));
    }

    #[test]
    fn rotation_adds_and_pivots_about_the_effect_anchor() {
        let c = clip(vec![tstage(&[(ClipEffect::STAGE_ROTATION_KEY, 90.0), (ClipEffect::STAGE_ANCHOR_X_KEY, 100.0)])]);
        let r = render(&c, s(1));
        assert!(close(r.rotation, 90.0, 1e-9));
        assert!(close2(r.map(Vec2::new(100.0, 0.0)), Vec2::new(100.0, 0.0), 1e-9)); // the anchor stays where it is
        assert!(close2(r.map(Vec2::new(0.0, 0.0)), Vec2::new(100.0, -100.0), 1e-9)); // clockwise on screen (y down)
    }

    #[test]
    fn scale_about_the_effect_anchor_keeps_that_point() {
        let mut c = clip(vec![tstage(&[
            (ClipEffect::STAGE_SCALE_KEY, 200.0),
            (ClipEffect::STAGE_ANCHOR_X_KEY, -50.0),
            (ClipEffect::STAGE_ANCHOR_Y_KEY, 20.0),
        ])]);
        c.animation.position = AnimatedProperty::new(Vec2::new(7.0, 3.0));
        let r = render(&c, s(1));
        assert!(close2(r.map(Vec2::new(-50.0, 20.0)), Vec2::new(-43.0, 23.0), 1e-9));
        assert!(close2(r.map(Vec2::new(-40.0, 20.0)), Vec2::new(-23.0, 23.0), 1e-9));
    }

    #[test]
    fn stages_compose_in_list_order() {
        let mv = tstage(&[(ClipEffect::STAGE_POSITION_X_KEY, 100.0)]);
        let turn = tstage(&[(ClipEffect::STAGE_ROTATION_KEY, 90.0)]);
        // Move first, then turn about the frame center: the moved center swings down.
        let a = render(&clip(vec![mv.clone(), turn.clone()]), s(1)).map(Vec2::ZERO);
        assert!(close2(a, Vec2::new(0.0, 100.0), 1e-9));
        // Turn first, then move.
        let b = render(&clip(vec![turn, mv]), s(1)).map(Vec2::ZERO);
        assert!(close2(b, Vec2::new(100.0, 0.0), 1e-9));
    }

    #[test]
    fn base_anchor_and_rotation_still_apply_after_the_stage() {
        let mut c = clip(vec![tstage(&[(ClipEffect::STAGE_POSITION_X_KEY, 10.0)])]);
        c.animation.anchor = AnimatedProperty::new(Vec2::new(30.0, 0.0));
        c.animation.rotation = AnimatedProperty::new(90.0);
        c.animation.position = AnimatedProperty::new(Vec2::new(5.0, 5.0));
        // Base alone maps p to R90 (p - anchor) + position; the stage moved p by (10, 0) first.
        let r = render(&c, s(1));
        assert!(close2(r.map(Vec2::ZERO), Vec2::new(5.0, 5.0 + (10.0 - 30.0)), 1e-9));
        assert!(close2(r.map(Vec2::new(30.0, 0.0)), Vec2::new(5.0, 5.0 + 10.0), 1e-9));
    }

    #[test]
    fn opacity_multiplies() {
        let mut c = clip(vec![tstage(&[(ClipEffect::STAGE_OPACITY_KEY, 50.0)])]);
        c.animation.opacity = AnimatedProperty::new(0.8);
        assert!(close(render(&c, s(1)).opacity, 0.4, 1e-9));
    }

    #[test]
    fn disabled_stage_is_ignored_and_other_effects_are_no_stage() {
        let mut e = tstage(&[(ClipEffect::STAGE_SCALE_KEY, 300.0)]);
        e.enabled = false;
        let blur = ClipEffect::make(Id::from_u128(8), ClipEffect::GAUSSIAN_BLUR_KIND).expect("blur");
        let mut c = clip(vec![e, blur]);
        c.animation.scale = AnimatedProperty::new(Vec2::new(1.5, 1.5));
        assert_eq!(render(&c, s(1)), c.transform(s(1)));
        assert!(!c.has_transform_stage());
    }

    #[test]
    fn stage_works_with_motion_switched_off() {
        let mut c = clip(vec![tstage(&[(ClipEffect::STAGE_SCALE_KEY, 150.0)])]);
        c.animation.scale = AnimatedProperty::new(Vec2::new(3.0, 3.0));
        c.motion_enabled = false;
        assert!(close(render(&c, s(1)).scale.x, 1.5, 1e-9));
    }

    #[test]
    fn non_uniform_base_with_stage_rotation_keeps_the_centre_right() {
        let mut c =
            clip(vec![tstage(&[(ClipEffect::STAGE_ROTATION_KEY, 30.0), (ClipEffect::STAGE_POSITION_X_KEY, 40.0)])]);
        c.animation.scale = AnimatedProperty::new(Vec2::new(2.0, 1.0));
        c.animation.position = AnimatedProperty::new(Vec2::new(10.0, 0.0));
        let r = render(&c, s(1));
        // The stage moves the center by 40 clip px, the base stretches x by 2: the center lands at 10 + 80.
        assert!(close2(r.map(Vec2::ZERO), Vec2::new(90.0, 0.0), 1e-9));
        assert!(close(r.rotation, 30.0, 1e-9) && r.scale == Vec2::new(2.0, 1.0));
    }

    #[test]
    fn keyed_stage_parameters_animate() {
        let mut e = tstage(&[]);
        let (k, p) = ramp(ClipEffect::STAGE_SCALE_KEY, 100.0, 200.0, 2);
        e.parameters.insert(k, p);
        assert!(close(render(&clip(vec![e]), s(1)).scale.x, 1.5, 1e-9));
    }

    #[test]
    fn sample_count_grows_with_the_angle() {
        assert_eq!(EffectTransformStage::sample_count(0.0), 0);
        assert!(EffectTransformStage::sample_count(10.0) >= 2);
        assert!(EffectTransformStage::sample_count(180.0) < EffectTransformStage::sample_count(360.0));
        assert_eq!(EffectTransformStage::sample_count(720.0), EffectTransformStage::sample_count(360.0));
    }

    #[test]
    fn reframe_stage_reaches_the_planned_framing_on_top_of_the_base() {
        let mut ids = sq_core_time::SequentialIds::default();
        let keys = KeyframeTrack::with_keys(vec![
            Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(100.0, 0.0)),
            Keyframe::new(ids.next_id(), s(2), Vec2::new(-100.0, 20.0)),
        ]);
        let plan = AnimatedProperty { value: Vec2::new(100.0, 0.0), track: keys };
        let mut c = clip(vec![]);
        c.animation.scale = AnimatedProperty::new(Vec2::new(0.5, 0.5));
        c.animation.position = AnimatedProperty::new(Vec2::new(30.0, -10.0));
        c.animation.anchor = AnimatedProperty::new(Vec2::new(12.0, 4.0));
        let before = c.animation.clone();
        let e = EffectTransformStage::reframe_effect(1.8, &plan, &c.transform(c.start), Id::from_u128(9), &mut ids);
        assert_eq!(e.kind, ClipEffect::REFRAME_KIND);
        c.effects.push(e);
        for t in [Time::ZERO, s(1), s(2)] {
            let want = plan.value_at_local(t);
            let r = render(&c, t);
            assert!(close(r.scale.x, 1.8, 1e-9) && close(r.scale.y, 1.8, 1e-9));
            assert!(close2(r.map(Vec2::new(12.0, 4.0)), want, 1e-9), "anchor lands on the planned position at {t:?}");
            assert!(close2(r.map(Vec2::new(112.0, 4.0)), want + Vec2::new(180.0, 0.0), 1e-9));
        }
        assert_eq!(c.animation, before);
    }

    #[test]
    fn stage_parameters_split_into_scalar_keys_for_variant_overrides() {
        let mut ids = sq_core_time::SequentialIds::default();
        let keys = KeyframeTrack::with_keys(vec![
            Keyframe::new(ids.next_id(), Time::ZERO, Vec2::new(10.0, 0.0)),
            Keyframe::new(ids.next_id(), s(1), Vec2::new(-10.0, 4.0)),
        ]);
        let plan = AnimatedProperty { value: Vec2::new(10.0, 0.0), track: keys };
        let e = EffectTransformStage::reframe_effect(2.0, &plan, &ClipTransform::IDENTITY, Id::from_u128(9), &mut ids);
        let values = |key: &str| e.parameters[key].track.keys.iter().map(|k| k.value).collect::<Vec<_>>();
        assert_eq!(values(ClipEffect::STAGE_POSITION_X_KEY), vec![10.0, -10.0]);
        assert_eq!(values(ClipEffect::STAGE_POSITION_Y_KEY), vec![0.0, 4.0]);
        assert_eq!(e.parameters[ClipEffect::STAGE_SCALE_KEY].value, 200.0);
    }

    #[test]
    fn fresh_transform_has_no_scale_y_and_is_linked() {
        let e = tstage(&[]);
        assert!(!e.parameters.contains_key(ClipEffect::STAGE_SCALE_Y_KEY));
        assert!(EffectCatalog::param(ClipEffect::TRANSFORM_KIND, ClipEffect::STAGE_SCALE_Y_KEY).is_some());
        let spec = EffectCatalog::spec_for(ClipEffect::TRANSFORM_KIND).expect("transform spec");
        let pair = spec.pair_containing(ClipEffect::STAGE_SCALE_KEY).expect("scale pair");
        assert!(pair.linkable && pair.y == ClipEffect::STAGE_SCALE_Y_KEY);
    }

    #[test]
    fn missing_scale_y_follows_scale() {
        let t = tstage(&[(ClipEffect::STAGE_SCALE_KEY, 150.0)]).stage_transform(Time::ZERO, None, FRAME);
        assert!(close(t.scale, 1.5, 1e-9) && close(t.scale_y(), 1.5, 1e-9));
    }

    #[test]
    fn separate_height_stretches_only_y() {
        let c = clip(vec![tstage(&[(ClipEffect::STAGE_SCALE_KEY, 200.0), (ClipEffect::STAGE_SCALE_Y_KEY, 50.0)])]);
        let r = render(&c, s(1));
        assert!(close(r.scale.x, 2.0, 1e-9) && close(r.scale.y, 0.5, 1e-9));
    }

    #[test]
    fn separate_height_multiplies_onto_motion_and_stages() {
        let mut c = clip(vec![
            tstage(&[(ClipEffect::STAGE_SCALE_KEY, 200.0), (ClipEffect::STAGE_SCALE_Y_KEY, 50.0)]),
            tstage(&[(ClipEffect::STAGE_SCALE_KEY, 110.0)]),
        ]);
        c.animation.scale = AnimatedProperty::new(Vec2::new(1.2, 1.0));
        let r = render(&c, s(1));
        assert!(close(r.scale.x, 1.2 * 2.0 * 1.1, 1e-9) && close(r.scale.y, 0.5 * 1.1, 1e-9));
    }

    #[test]
    fn separate_height_maps_frame_points_like_the_stage_map() {
        // Scale about the stage anchor (100, 40): (x, y) -> anchor + (2 (x - 100), 0.5 (y - 40)).
        let c = clip(vec![tstage(&[
            (ClipEffect::STAGE_SCALE_KEY, 200.0),
            (ClipEffect::STAGE_SCALE_Y_KEY, 50.0),
            (ClipEffect::STAGE_ANCHOR_X_KEY, 100.0),
            (ClipEffect::STAGE_ANCHOR_Y_KEY, 40.0),
        ])]);
        let p = render(&c, s(1)).map(Vec2::new(300.0, 240.0));
        assert!(close2(p, Vec2::new(100.0 + 2.0 * 200.0, 40.0 + 0.5 * 200.0), 1e-6));
    }

    #[test]
    fn scale_y_keys_animate() {
        let mut e = tstage(&[(ClipEffect::STAGE_SCALE_KEY, 100.0)]);
        let (k, p) = ramp(ClipEffect::STAGE_SCALE_Y_KEY, 100.0, 50.0, 2);
        e.parameters.insert(k, p);
        let c = clip(vec![e]);
        assert!(close(render(&c, s(1)).scale.y, 0.75, 1e-9));
        assert!(close(render(&c, s(1)).scale.x, 1.0, 1e-9));
        assert!(!c.transform_is_static());
    }

    #[test]
    fn group_stage_composes_after_the_clip_and_removes_again() {
        let mut g = ClipEffect::new(Id::from_u128(11), ClipEffect::GROUP_TRANSFORM_KIND);
        g.points.insert(ClipEffect::GROUP_POSITION_KEY.to_string(), AnimatedProperty::new(Vec2::new(10.0, 20.0)));
        g.points.insert(ClipEffect::GROUP_SCALE_KEY.to_string(), AnimatedProperty::new(Vec2::new(2.0, 2.0)));
        g.parameters.insert(ClipEffect::GROUP_ROTATION_KEY.to_string(), AnimatedProperty::new(30.0));
        g.parameters.insert(ClipEffect::GROUP_OPACITY_KEY.to_string(), AnimatedProperty::new(0.5));
        let mut c = clip(vec![g]);
        c.animation.position = AnimatedProperty::new(Vec2::new(5.0, -3.0));
        c.animation.opacity = AnimatedProperty::new(0.8);
        let own = c.transform(s(1));
        let drawn = render(&c, s(1));
        let p = Vec2::new(17.0, 4.0);
        assert!(close2(drawn.map(p), c.group_stage_transforms(s(1))[0].map(own.map(p)), 1e-9));
        assert!(close(drawn.opacity, 0.4, 1e-9));
        let back = drawn.removing_group_stages(&c.group_stage_transforms(s(1)));
        assert!(close2(back.position, own.position, 1e-9) && close(back.rotation, own.rotation, 1e-9));
        assert!(close2(back.scale, own.scale, 1e-9) && close(back.opacity, own.opacity, 1e-9));
    }
}
