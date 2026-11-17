// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectsEditing.swift, MosaicBlockSize.swift, Anonymize.swift (`addAnonymize`), StabilizeEffect.swift (`addStabilizer`),
//        Stabilizer.swift (`insertionIndex`)
//! Pure edits of a clip's applied effects and opacity. The session wraps each in one undo step.
//!
//! New effects, keys and copies take their ids from an `IdSource` (Swift draws random UUIDs).

use crate::effect_transform_stage::ClipEffectStage;
use sq_core_color::{COLOR_GRAPH_KIND, ClipEffectColorExt, ClipGradeExt};
use sq_core_masks::{
    AnonymizeCover, AnonymizeOrderExt, AnonymizeTargetExt, ClipMasksExt, ClipStabilizeExt, MaskInputsExt,
    MaskSourceExt, PictureMaskTimelineExt, RollingShutter, STABILIZE_KIND, StabilizationAnalysis, StabilizationPlan,
    Stabilizer, StabilizerEdgeFill, StabilizerMethod, StabilizerOptions, SubjectMaskClipExt,
    stabilize_perspective_keys,
};
use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_model::{
    AnimatedProperty, AnonymizeTarget, Clip, ClipEdge, ClipEffect, ClipMask, ColorGradeData, EditError, EffectCatalog,
    EffectColor, MagicSelection, MaskSource, Timeline, TrackKind,
};
use sq_core_time::{Id, IdSource, Keyframe, Time, Vec2};
use std::collections::{BTreeMap, BTreeSet};

/// Where a Stabilizer effect goes in `effects`: before the first transform stage (it corrects the source picture, so
/// Transform / Auto Reframe / motion presets act on the steadied picture), else at the end.
pub fn stabilizer_insertion_index(effects: &[ClipEffect]) -> usize {
    effects.iter().position(|e| e.is_transform_stage() && e.kind != STABILIZE_KIND).unwrap_or(effects.len())
}

/// A Stabilizer effect for `clip`: Position / Rotation / Scale keys at clip frames (the correction of the analyzed source
/// frame nearest to the source time shown there, through speed, reverse and time remapping; decimated within the
/// tolerances of `Stabilizer`), plus the settings. Pure: callers run it off the main thread.
pub fn stabilizer_effect(
    plan: &StabilizationPlan,
    analysis: &StabilizationAnalysis,
    clip: &Clip,
    fd: Time,
    options: &StabilizerOptions,
    id: Id,
    ids: &mut dyn IdSource,
) -> ClipEffect {
    let mut e = ClipEffect::make(id, STABILIZE_KIND).unwrap_or_else(|| ClipEffect::new(id, STABILIZE_KIND));
    let mut set = |key: &str, v: f64| e.parameters.insert(key.to_string(), AnimatedProperty::new(v));
    set(ClipEffect::STABILIZE_METHOD_KEY, StabilizerMethod::Standard as i64 as f64);
    set(ClipEffect::STABILIZE_MODE_KEY, options.mode as i64 as f64);
    set(ClipEffect::STABILIZE_SMOOTHNESS_KEY, options.smoothness);
    set(ClipEffect::STABILIZE_STRENGTH_KEY, options.strength * 100.0);
    set(ClipEffect::STABILIZE_MAX_CROP_KEY, options.max_crop * 100.0);
    if options.edge_fill != StabilizerEdgeFill::Zoom {
        set(ClipEffect::STABILIZE_EDGE_FILL_KEY, options.edge_fill as i64 as f64);
    }
    if let (Some(a), Some(b)) = (analysis.frame_times.first(), analysis.frame_times.last()) {
        set(ClipEffect::STABILIZE_FROM_KEY, a.value() as f64 / a.timescale() as f64);
        set(ClipEffect::STABILIZE_TO_KEY, b.value() as f64 / b.timescale() as f64);
    }
    set(ClipEffect::ROLLING_SHUTTER_KEY, if options.rolling_shutter { 1.0 } else { 0.0 });
    set(ClipEffect::ROLLING_SHUTTER_STRENGTH_KEY, options.rolling_shutter_strength);
    let frames = clip.duration().frame_index(fd);
    let source_time = |i: i64| clip.source_time(clip.start + fd * i, fd);
    if options.rolling_shutter && frames > 0 && !analysis.rolling.is_empty() {
        let shears = RollingShutter::shears(analysis, RollingShutter::estimate(analysis).readout);
        let (mut sx, mut sy) = (Vec::new(), Vec::new());
        for i in 0..frames {
            let s = RollingShutter::shear(&shears, analysis, source_time(i));
            sx.push(s.x);
            sy.push(s.y);
        }
        let along_x = analysis.rolling_scans_along_x();
        let extent = (if along_x { analysis.picture_width } else { analysis.picture_height }).max(1) as f64;
        // Half a pixel across the whole extent: a quarter pixel at the first and last row.
        let tol = 0.5 / extent;
        e.parameters.insert(ClipEffect::ROLLING_SHEAR_X_KEY.into(), Stabilizer::decimated_property(&sx, fd, tol, ids));
        e.parameters.insert(ClipEffect::ROLLING_SHEAR_Y_KEY.into(), Stabilizer::decimated_property(&sy, fd, tol, ids));
        if along_x {
            e.parameters.insert(ClipEffect::ROLLING_SCAN_AXIS_KEY.into(), AnimatedProperty::new(1.0));
        }
    }
    if frames > 0 && !plan.perspective.is_empty() {
        // Eight keys (the residual homography), written only when a frame needs a correction: none = no warp pass.
        let tol = Stabilizer::perspective_tolerances(analysis.picture_width, analysis.picture_height);
        let mut cols: Vec<Vec<f64>> = vec![Vec::new(); 8];
        for i in 0..frames {
            let v = Stabilizer::perspective_correction(plan, analysis, source_time(i)).values;
            for (c, col) in cols.iter_mut().enumerate() {
                col.push(v[c]);
            }
        }
        if cols.iter().any(|c| c.iter().any(|x| x.abs() > Stabilizer::PERSPECTIVE_FLOOR)) {
            for (c, key) in stabilize_perspective_keys().into_iter().enumerate() {
                e.parameters.insert(key, Stabilizer::decimated_property(&cols[c], fd, tol[c], ids));
            }
        }
    }
    if frames <= 0 || plan.corrections.is_empty() {
        return e;
    }
    // The full per-frame correction, then only the keys linear interpolation needs to stay within the tolerances (a key
    // per frame would make a 10-minute clip tens of MB in the file and in every undo step).
    let (mut px, mut py, mut rot, mut sc) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for i in 0..frames {
        let c = Stabilizer::correction(plan, analysis, source_time(i));
        px.push(c.position.x);
        py.push(c.position.y);
        rot.push(c.rotation);
        sc.push(c.scale * 100.0);
    }
    let mut prop = |key: &str, v: &[f64], tolerance: f64| {
        e.parameters.insert(key.to_string(), Stabilizer::decimated_property(v, fd, tolerance, ids));
    };
    prop(ClipEffect::STAGE_POSITION_X_KEY, &px, Stabilizer::POSITION_TOLERANCE);
    prop(ClipEffect::STAGE_POSITION_Y_KEY, &py, Stabilizer::POSITION_TOLERANCE);
    prop(ClipEffect::STAGE_ROTATION_KEY, &rot, Stabilizer::ROTATION_TOLERANCE);
    prop(ClipEffect::STAGE_SCALE_KEY, &sc, Stabilizer::SCALE_TOLERANCE * 100.0);
    e
}

/// Pure maths of the video fade preset.
pub struct OpacityFade;

impl OpacityFade {
    /// A fade never takes more than half the clip, so a fade in and a fade out cannot cross.
    pub fn clamped(requested: Time, clip_duration: Time) -> Time {
        requested.min(clip_duration.halved())
    }
}

/// A Mosaic grid: how many blocks across and down.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct MosaicGrid {
    /// Blocks across.
    pub columns: i64,
    /// Blocks down.
    pub rows: i64,
}

/// Columns / Rows range of the Mosaic effect (its catalog range).
const MOSAIC_GRID_RANGE: std::ops::RangeInclusive<i64> = 1..=4_000;

/// Mosaic by block size (the stored effect stays Columns / Rows; no new key in the project file).
pub struct MosaicBlockSize;

impl MosaicBlockSize {
    /// The grid whose blocks are squares of about `block_size` px on a `width` x `height` frame.
    pub fn grid(block_size: f64, width: i64, height: i64) -> MosaicGrid {
        let b = block_size.max(1.0);
        let count = |px: i64| -> i64 {
            let n = (px.max(1) as f64 / b).round();
            // Clamp in float first: Swift traps converting an out-of-range value, the range is far smaller anyway.
            (n.clamp(*MOSAIC_GRID_RANGE.start() as f64, *MOSAIC_GRID_RANGE.end() as f64)) as i64
        };
        MosaicGrid { columns: count(width), rows: count(height) }
    }

    /// A Mosaic effect with square blocks of about `block_size` px on a `width` x `height` frame.
    pub fn mosaic(id: Id, block_size: f64, width: i64, height: i64) -> ClipEffect {
        let g = Self::grid(block_size, width, height);
        let mut p = ClipEffect::default_parameters(ClipEffect::MOSAIC_KIND);
        p.insert(ClipEffect::MOSAIC_COLUMNS_KEY.to_string(), AnimatedProperty::new(g.columns as f64));
        p.insert(ClipEffect::MOSAIC_ROWS_KEY.to_string(), AnimatedProperty::new(g.rows as f64));
        let mut e = ClipEffect::new(id, ClipEffect::MOSAIC_KIND);
        e.parameters = p;
        e
    }

    /// Block size (px of the clip's frame) Anonymize starts with: about eight blocks across the covered subject, and never
    /// finer than 1/60 of the frame's short side, so a subject that is small in the frame is not left readable.
    pub fn anonymize_block_size(subject_width: f64, frame_width: i64, frame_height: i64) -> f64 {
        let floor = (frame_width.min(frame_height) as f64 / 60.0).round();
        (subject_width / 8.0).round().max(floor).max(1.0)
    }
}

/// A copy with a new id (for the effect and nothing else that is shared).
fn copy_effect(e: &ClipEffect, ids: &mut dyn IdSource) -> ClipEffect {
    let mut c = e.clone();
    c.id = ids.next_id();
    c
}

/// Edits of a clip's effects, opacity and Paste Attributes (Swift `extension Clip` in EffectsEditing.swift).
pub trait ClipEffectsEditingExt {
    /// Appends a new instance of `kind` (a second Gaussian Blur is fine) with default values (FB-W: the user default of
    /// the kind in `defaults` when there is one, else factory). Returns its id.
    /// Audio kinds only onto audio clips, every other kind only onto video clips.
    /// A Color effect goes behind the existing Color effects, in front of every other effect (color always renders
    /// first), and only onto clips that take color (`accepts_color`).
    fn add_effect(&mut self, kind: &str, defaults: Option<&EffectDefaults>, ids: &mut dyn IdSource) -> Option<Id>;
    /// Adds a fresh (unanalyzed) Stabilizer before the first other transform stage, so Transform / Auto Reframe act on the
    /// steadied picture. One per clip: `None` (no change) when the clip has one or cannot be stabilized.
    fn add_stabilizer(&mut self, e: ClipEffect) -> Option<Id>;
    /// Sets the static value of a parameter (keys stay). NaN and infinity are sanitized on write, the same rule as
    /// `ClipEffect::scalar` (catalog default for NaN, catalog range clamp).
    fn set_parameter(&mut self, id: Id, key: &str, value: f64);
    /// Sets the static value of a color parameter (keys stay).
    fn set_color(&mut self, id: Id, key: &str, value: EffectColor);
    /// Sets the static value of a point parameter (keys stay).
    fn set_point(&mut self, id: Id, key: &str, value: Vec2);
    /// Moves an effect to `index` in the list (clamped); the list order is the evaluation order. False when nothing moved
    /// (re-pinning an unpinned list counts as moved). Color effects are pinned: they render before every other effect and
    /// the first one is the footage conversion, so they do not move and nothing moves in front of them. Covers (effects
    /// limited to an Anonymize mask) come right behind them: a cover moves among the covers only and no other effect moves
    /// in front of one (`pin_covers`).
    fn move_effect(&mut self, id: Id, index: i64) -> bool;
    /// Copies an effect (values and keys, new ids) right behind the original. Returns the copy's id.
    fn duplicate_effect(&mut self, id: Id, ids: &mut dyn IdSource) -> Option<Id>;
    /// Removes an effect and its per-variant parameter overrides.
    fn remove_effect(&mut self, id: Id) -> bool;
    /// Cmd-click on the Opacity rubber band: a key at clip-local `t` holding the value shown there. `None` outside the clip.
    fn add_opacity_key(&mut self, t: Time, ids: &mut dyn IdSource) -> Option<Id>;
    /// Moves an opacity key to clip-local `time` (kept inside the clip) and `value` (0...1).
    fn move_opacity_key(&mut self, id: Id, time: Time, value: f64, frame_duration: Option<Time>);
    /// Removes an opacity key.
    fn remove_opacity_key(&mut self, id: Id);
    /// Raises or lowers the opacity line at clip-local `t` by `delta` (0...1 scale), like dragging the rubber band there:
    /// without keys the whole clip's opacity; with keys the segment under `t` (both of its keys), or the first / last
    /// key when `t` is before / after all of them.
    fn shift_opacity_line(&mut self, t: Time, delta: f64);
    /// Fade preset on the picture (Opacity keys): `Head` fades in from 0, `Tail` fades out to 0, over `requested`
    /// (clamped to half the clip). The opacity the clip has at the other end of the fade is kept as its target, and keys
    /// inside the fade span are replaced, so applying a fade again changes it.
    fn apply_video_fade(
        &mut self,
        edge: ClipEdge,
        requested: Time,
        frame_duration: Option<Time>,
        ids: &mut dyn IdSource,
    );
    /// Motion (switch, Position, Scale, Rotation, Anchor) taken from `source`, with its v10 Scale state: Scale and Anchor
    /// arrive in the source's semantics, so a still-pending target is converted no longer (or becomes pending when the
    /// source still is).
    fn replace_motion(&mut self, source: &Clip);
    /// Copy whose clip-local key times (Motion, effects, masks) are stretched so a key at the clip's current length lands
    /// at `new_duration` (Paste Attributes "Scale Attribute Times"). Same length or an empty clip: unchanged.
    fn key_times_scaled(&self, new_duration: Time) -> Clip;
    /// This clip with the attributes of `source` applied (Edit > Paste Attributes). Motion, Opacity (and the blend mode),
    /// Volume and color replace the target's; every other effect is added behind the existing ones with fresh ids.
    /// Key times are clip-local, so they land at the same offset from the target's first frame. Clips of another kind are
    /// left alone.
    fn pasting_attributes(&self, source: &Clip, ids: &mut dyn IdSource) -> Clip;
    /// Anonymize: one Magic mask per pick (named after the target, marked as one that must cover) and one Mosaic or Blur
    /// that takes those masks as its input. `subject_width`: px of the clip's frame the widest covered subject spans (sets
    /// the block size / blur amount). Returns the new masks' ids; nothing is added for no picks.
    fn add_anonymize(
        &mut self,
        picks: &[MagicSelection],
        target: AnonymizeTarget,
        cover: AnonymizeCover,
        subject_width: f64,
        frame: (i64, i64),
        ids: &mut dyn IdSource,
    ) -> Vec<Id>;
}

impl ClipEffectsEditingExt for Clip {
    fn add_effect(&mut self, kind: &str, defaults: Option<&EffectDefaults>, ids: &mut dyn IdSource) -> Option<Id> {
        if EffectCatalog::is_generator_owned(kind) {
            return None;
        }
        let made = match defaults {
            Some(d) => d.make_effect(kind, ids),
            None => None,
        };
        let mut e = match made {
            Some(e) => e,
            None => ClipEffect::make(ids.next_id(), kind)?,
        };
        // A user default of the kind wins; without one a neutral effect starts at its visible value.
        if !defaults.is_some_and(|d| d.has_default_effect(kind)) {
            let keys: Vec<String> = e.parameters.keys().cloned().collect();
            for key in keys {
                if let Some(v) = ClipEffect::applied_start_value(kind, &key) {
                    e.parameters.insert(key, AnimatedProperty::new(v));
                }
            }
        }
        // Audio effects run on the sound of audio clips only; picture effects never go onto an audio clip.
        if e.is_audio() != (self.kind == TrackKind::Audio) {
            return None;
        }
        if e.kind == STABILIZE_KIND {
            return self.add_stabilizer(e);
        }
        if e.is_color() {
            if !self.accepts_color() {
                return None;
            }
            let colors = self.color_effect_indices();
            // A later Color effect works on display-referred video: its Input LUT starts as none, not the camera LUT.
            if !colors.is_empty() {
                e.grade = Some(ColorGradeData { input_lut: None, ..ColorGradeData::default() });
            }
            let id = e.id;
            let at = colors.last().map_or(0, |i| i + 1);
            self.effects.insert(at, e);
            return Some(id);
        }
        let id = e.id;
        self.effects.push(e);
        Some(id)
    }

    fn add_stabilizer(&mut self, e: ClipEffect) -> Option<Id> {
        if !self.can_stabilize() || self.stabilizer_id().is_some() {
            return None;
        }
        let id = e.id;
        let at = stabilizer_insertion_index(&self.effects);
        self.effects.insert(at, e);
        Some(id)
    }

    fn set_parameter(&mut self, id: Id, key: &str, value: f64) {
        let Some(e) = self.effects.iter_mut().find(|e| e.id == id) else { return };
        let value = ClipEffect::sanitized(value, &e.kind, key);
        let mut p = e.parameters.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(value));
        p.value = value;
        e.parameters.insert(key.to_string(), p);
    }

    fn set_color(&mut self, id: Id, key: &str, value: EffectColor) {
        let Some(e) = self.effects.iter_mut().find(|e| e.id == id) else { return };
        let mut p = e.colors.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(value));
        p.value = value;
        e.colors.insert(key.to_string(), p);
    }

    fn set_point(&mut self, id: Id, key: &str, value: Vec2) {
        let Some(e) = self.effects.iter_mut().find(|e| e.id == id) else { return };
        let mut p = e.points.get(key).cloned().unwrap_or_else(|| AnimatedProperty::new(value));
        p.value = value;
        e.points.insert(key.to_string(), p);
    }

    fn move_effect(&mut self, id: Id, index: i64) -> bool {
        // An older, unpinned list may be reordered here; the result says so even when the move itself does nothing.
        let pinned0 = self.pin_covers();
        let Some(from) = self.effects.iter().position(|e| e.id == id) else { return pinned0 };
        if self.effects[from].is_color() {
            return pinned0;
        }
        let pinned = self.effects.iter().take_while(|e| e.is_color()).count();
        let covers = self.effects[pinned..].iter().take_while(|e| self.is_cover(e)).count();
        let cover = self.is_cover(&self.effects[from]);
        let (pinned, covers) = (pinned as i64, covers as i64);
        let low = if cover { pinned } else { pinned + covers };
        let high = if cover { pinned + covers - 1 } else { self.effects.len() as i64 - 1 };
        let to = index.max(low).min(low.max(high));
        if to == from as i64 {
            return pinned0;
        }
        let e = self.effects.remove(from);
        self.effects.insert(to as usize, e);
        true
    }

    fn duplicate_effect(&mut self, id: Id, ids: &mut dyn IdSource) -> Option<Id> {
        let i = self.effects.iter().position(|e| e.id == id)?;
        if EffectCatalog::is_generator_owned(&self.effects[i].kind) {
            return None;
        }
        let copy = copy_effect(&self.effects[i], ids);
        let new_id = copy.id;
        self.effects.insert(i + 1, copy);
        Some(new_id)
    }

    fn remove_effect(&mut self, id: Id) -> bool {
        // The one body lives in the color crate (below this one), whose grade edits remove effects too.
        sq_core_color::remove_effect(self, id)
    }

    fn add_opacity_key(&mut self, t: Time, ids: &mut dyn IdSource) -> Option<Id> {
        if t < Time::ZERO || t > self.duration() {
            return None;
        }
        let v = self.animation.opacity.value_at_local(t);
        let k = Keyframe::new(ids.next_id(), t, v);
        let id = k.id;
        self.animation.opacity.track.insert(k);
        Some(id)
    }

    fn move_opacity_key(&mut self, id: Id, time: Time, value: f64, frame_duration: Option<Time>) {
        let duration = self.duration();
        let mut t = time.max(Time::ZERO).min(duration);
        if let Some(fd) = frame_duration {
            t = t.snapped(fd).max(Time::ZERO).min(duration);
        }
        self.animation.opacity.track.move_key(id, t);
        self.animation.opacity.track.set(id, value.clamp(0.0, 1.0));
    }

    fn remove_opacity_key(&mut self, id: Id) {
        self.animation.opacity.track.remove(id);
    }

    fn shift_opacity_line(&mut self, t: Time, delta: f64) {
        if delta.abs() <= 1e-9 {
            return;
        }
        let shifted = |v: f64| (v + delta).clamp(0.0, 1.0);
        let keys = &self.animation.opacity.track.keys;
        if keys.is_empty() {
            self.animation.opacity.value = shifted(self.animation.opacity.value);
            return;
        }
        let ids: Vec<Id> = match keys.iter().rposition(|k| k.time <= t) {
            None => vec![keys[0].id],
            Some(n) if n == keys.len() - 1 => vec![keys[n].id],
            Some(n) => vec![keys[n].id, keys[n + 1].id],
        };
        for id in ids {
            if let Some(v) = self.animation.opacity.track.key(id).map(|k| k.value) {
                self.animation.opacity.track.set(id, shifted(v));
            }
        }
    }

    fn apply_video_fade(
        &mut self,
        edge: ClipEdge,
        requested: Time,
        frame_duration: Option<Time>,
        ids: &mut dyn IdSource,
    ) {
        let len = self.duration();
        let mut d = OpacityFade::clamped(requested, len);
        if let Some(fd) = frame_duration {
            d = d.snapped(fd).min(len); // keys sit on frames
        }
        if d <= Time::ZERO {
            return;
        }
        let mut track = self.animation.opacity.track.clone();
        match edge {
            ClipEdge::Head => {
                let target = self.animation.opacity.value_at_local(d);
                track.keys.retain(|k| k.time > d);
                track.insert(Keyframe::new(ids.next_id(), Time::ZERO, 0.0));
                track.insert(Keyframe::new(ids.next_id(), d, target));
            }
            ClipEdge::Tail => {
                let from = len - d;
                let start = self.animation.opacity.value_at_local(from);
                track.keys.retain(|k| k.time < from);
                track.insert(Keyframe::new(ids.next_id(), from, start));
                track.insert(Keyframe::new(ids.next_id(), len, 0.0));
            }
        }
        self.animation.opacity.track = track;
    }

    fn replace_motion(&mut self, source: &Clip) {
        self.motion_enabled = source.motion_enabled;
        self.animation.position = source.animation.position.clone();
        self.animation.scale = source.animation.scale.clone();
        self.animation.rotation = source.animation.rotation.clone();
        self.animation.anchor = source.animation.anchor.clone();
        self.animation.tilt_x = source.animation.tilt_x.clone();
        self.animation.tilt_y = source.animation.tilt_y.clone();
        self.animation.shutter_angle = source.animation.shutter_angle.clone();
        self.animation.anti_flicker = source.animation.anti_flicker.clone();
        self.set_pending_source_pixel_scale(source.pending_source_pixel_scale());
    }

    fn key_times_scaled(&self, new_duration: Time) -> Clip {
        let mut c = self.clone();
        let old = self.duration();
        if old <= Time::ZERO || new_duration <= Time::ZERO || old == new_duration {
            return c;
        }
        c.rescale_keys(old, new_duration, false);
        c
    }

    fn pasting_attributes(&self, source: &Clip, ids: &mut dyn IdSource) -> Clip {
        if source.kind != self.kind {
            return self.clone();
        }
        let mut out = self.clone();
        match self.kind {
            TrackKind::Video => {
                out.replace_motion(source);
                out.opacity_enabled = source.opacity_enabled;
                out.animation.opacity = source.animation.opacity.clone();
                // Subject masks only on clips that take one (no generators, no nests: the matte needs a decoded source
                // frame). Picture masks read another track, so any clip takes them (their track is remapped by the
                // timeline paste).
                let (pasted, map) = source.pasted_masks_with_map(ids);
                let takes_subject = out.accepts_subject_mask();
                out.set_masks(
                    pasted
                        .into_iter()
                        .filter(|m| !m.source().uses_matte() || m.source() == MaskSource::Picture || takes_subject)
                        .collect(),
                );
                out.blend_mode = source.blend_mode;
                // Color: the footage interpretation and every Color effect replace the target's (first in the list), on
                // clips that take color.
                if out.accepts_color() {
                    out.footage_color = source.footage_color.clone();
                    out.replace_color_grade(&source.color_grade_effects(), ids);
                    out.apply_copied_graph(source.color_graph(), ids);
                }
                let before: BTreeSet<Id> = out.effects.iter().map(|e| e.id).collect();
                out.paste_effects(source, ids, |e| !e.is_color() && e.kind != COLOR_GRAPH_KIND && !e.is_audio());
                // Pasted effects point at the pasted masks; the target's own effects lost theirs with the old masks.
                let kept: BTreeSet<Id> = out.masks().iter().map(|m| m.id).collect();
                for e in out.effects.iter_mut() {
                    e.mask_input = if before.contains(&e.id) {
                        e.mask_input.iter().copied().filter(|m| kept.contains(m)).collect()
                    } else {
                        e.mask_input.iter().filter_map(|m| map.get(m).copied()).filter(|m| kept.contains(m)).collect()
                    };
                }
                out.pin_covers(); // a pasted cover goes in front of the target's effects
            }
            TrackKind::Audio => {
                out.animation.volume = source.animation.volume.clone();
                out.audio_gain_db = source.audio_gain_db;
                out.paste_effects(source, ids, |e| e.is_audio()); // AUDIO-FX: the audio effect stack
            }
        }
        out
    }

    fn add_anonymize(
        &mut self,
        picks: &[MagicSelection],
        target: AnonymizeTarget,
        cover: AnonymizeCover,
        subject_width: f64,
        frame: (i64, i64),
        ids: &mut dyn IdSource,
    ) -> Vec<Id> {
        if picks.is_empty() {
            return Vec::new();
        }
        let (frame_width, frame_height) = frame;
        let short = frame_width.min(frame_height) as f64;
        let prefix = format!("{} ", target.mask_name());
        let mut n = self.masks().iter().filter(|m| m.name.starts_with(&prefix)).count();
        let mut mask_ids = Vec::new();
        let mut added: Vec<ClipMask> = Vec::new();
        for p in picks {
            n += 1;
            let mut m = ClipMask::make_magic(ids.next_id(), &format!("{} {}", target.mask_name(), n), p.points.clone());
            let mut sel = p.clone();
            sel.part = Some(target); // marks the mask as one that must cover, a whole person too
            m.magic = Some(sel);
            m.set_used_by_opacity(false);
            // A person's or skin's edge gets a little room (hair, fingers); the face ellipse already has it. The soft edge
            // of a blur is the mask's Feather; Mosaic blocks end hard unless the user raises it.
            if target != AnonymizeTarget::Face {
                m.expansion = AnimatedProperty::new((short / 180.0).round());
            }
            if cover == AnonymizeCover::Blur {
                m.feather = AnimatedProperty::new((short / 90.0).round());
            }
            mask_ids.push(m.id);
            added.push(m);
        }
        let mut masks = self.masks().to_vec();
        masks.extend(added);
        self.set_masks(masks);
        let mut effect = match cover {
            AnonymizeCover::Mosaic => {
                let block = MosaicBlockSize::anonymize_block_size(subject_width, frame_width, frame_height);
                MosaicBlockSize::mosaic(ids.next_id(), block, frame_width, frame_height)
            }
            AnonymizeCover::Blur => {
                let mut e = ClipEffect::new(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND);
                e.parameters = ClipEffect::default_parameters(ClipEffect::GAUSSIAN_BLUR_KIND);
                let blurriness = (subject_width / 4.0).round().max((short / 20.0).round());
                e.parameters.insert(ClipEffect::BLURRINESS_KEY.to_string(), AnimatedProperty::new(blurriness));
                e.parameters.insert(ClipEffect::REPEAT_EDGE_PIXELS_KEY.to_string(), AnimatedProperty::new(1.0));
                e
            }
        };
        effect.mask_input = mask_ids.clone();
        // In front of every other picture effect (behind the Color effects, which stay first): the mattes are tracked on
        // the source frame, so the cover has to act on the picture before any effect that moves pixels.
        let at = self.cover_insertion_index();
        self.effects.insert(at, effect);
        self.pin_covers();
        mask_ids
    }
}

/// Effects of `source` passing `include`: a kind the target has as many times as the source replaces those instances one
/// by one (so pasting twice does not stack copies); otherwise the copies are added behind the existing ones.
/// A generator-owned effect (a shape's look) only pastes onto a clip of the same generator, and only replaces.
trait PasteEffects {
    fn paste_effects(&mut self, source: &Clip, ids: &mut dyn IdSource, include: impl Fn(&ClipEffect) -> bool);
}

impl PasteEffects for Clip {
    fn paste_effects(&mut self, source: &Clip, ids: &mut dyn IdSource, include: impl Fn(&ClipEffect) -> bool) {
        let mut kinds: Vec<&str> = Vec::new();
        for e in source.effects.iter().filter(|e| include(e)) {
            if !kinds.contains(&e.kind.as_str()) {
                kinds.push(&e.kind);
            }
        }
        for kind in kinds {
            let srcs: Vec<&ClipEffect> = source.effects.iter().filter(|e| e.kind == kind).collect();
            let dsts: Vec<usize> = (0..self.effects.len()).filter(|&i| self.effects[i].kind == kind).collect();
            if let Some(owner) = EffectCatalog::owning_generator(kind) {
                let owns = |c: &Clip| c.generator.as_ref().is_some_and(|g| g.kind == owner);
                if !owns(self) || !owns(source) {
                    continue;
                }
                if let (Some(&d), Some(s)) = (dsts.first(), srcs.first()) {
                    self.effects[d] = copy_effect(s, ids);
                } else if let Some(s) = srcs.first() {
                    self.effects.insert(0, copy_effect(s, ids));
                }
            } else if dsts.len() == srcs.len() {
                for (i, d) in dsts.iter().enumerate() {
                    self.effects[*d] = copy_effect(srcs[i], ids);
                }
            } else {
                for s in srcs {
                    self.effects.push(copy_effect(s, ids));
                }
            }
        }
    }
}

/// Replaces a clip of the timeline in place (Swift `Timeline.replaceClip`, Timeline+Replace.swift).
///
/// shortcut: private copy until the edit crate ports Timeline+Replace; then call its `replace_clip`.
fn replace_clip(tl: &mut Timeline, clip: Clip) -> Result<(), EditError> {
    let ti = tl.tracks.iter().position(|t| t.clip(clip.id).is_some()).ok_or(EditError::ClipNotFound)?;
    if tl.tracks[ti].is_locked {
        return Err(EditError::TrackLocked);
    }
    let old = tl.tracks[ti].clip(clip.id).ok_or(EditError::ClipNotFound)?;
    if old.start != clip.start || old.source != clip.source || old.speed != clip.speed || old.reversed != clip.reversed
    {
        return Err(EditError::Collision);
    }
    tl.tracks[ti].replace(clip);
    Ok(())
}

/// Timeline-level effect edits (Swift `extension Timeline` in EffectsEditing.swift).
pub trait TimelineEffectsEditingExt {
    /// Fade In / Fade Out preset on the given video clips: one call, one undo step. Audio clips are skipped; refuses when
    /// none of the clips is a video clip.
    fn fade_video(
        &mut self,
        ids: &[Id],
        edge: ClipEdge,
        duration: Time,
        id_source: &mut dyn IdSource,
    ) -> Result<(), EditError>;
    /// Paste Attributes onto `ids` (the source clip itself is skipped). Returns how many clips changed.
    /// `source_lane` / `picture_lanes` (from the clipboard): where the source clip and its Picture masks' tracks sat, so a
    /// mask whose track is not in this sequence keeps its lane offset.
    fn paste_attributes(
        &mut self,
        source: &Clip,
        ids: &[Id],
        source_lane: Option<usize>,
        picture_lanes: &BTreeMap<Id, usize>,
        id_source: &mut dyn IdSource,
    ) -> Result<usize, EditError>;
}

impl TimelineEffectsEditingExt for Timeline {
    fn fade_video(
        &mut self,
        ids: &[Id],
        edge: ClipEdge,
        duration: Time,
        id_source: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let fd = self.frame_duration();
        let mut work = self.clone();
        let mut changed = 0;
        for id in ids {
            let Some(mut c) = work.find(*id).map(|m| m.clip).filter(|c| c.kind == TrackKind::Video) else { continue };
            c.apply_video_fade(edge, duration, Some(fd), id_source);
            replace_clip(&mut work, c)?;
            changed += 1;
        }
        if changed == 0 {
            return Err(EditError::WrongTrackKind);
        }
        *self = work;
        Ok(())
    }

    fn paste_attributes(
        &mut self,
        source: &Clip,
        ids: &[Id],
        source_lane: Option<usize>,
        picture_lanes: &BTreeMap<Id, usize>,
        id_source: &mut dyn IdSource,
    ) -> Result<usize, EditError> {
        let mut work = self.clone();
        let mut changed = 0;
        for id in ids.iter().filter(|id| **id != source.id) {
            let Some(c) = work.find(*id).map(|m| m.clip).filter(|c| c.kind == source.kind) else { continue };
            let pasted = c.pasting_attributes(source, id_source);
            let out = work.remapping_picture_tracks(&pasted, source_lane, picture_lanes);
            if out == c {
                continue;
            }
            replace_clip(&mut work, out)?;
            changed += 1;
        }
        if changed == 0 {
            return Err(EditError::EmptyClip);
        }
        *self = work;
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_masks::{CameraMotion, CameraPose, MagicSelectionAnonymizeExt as _};
    use sq_core_model::{GeneratorRef, MagicPoint};
    use sq_core_time::{SequentialIds, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn clip(ids: &mut SequentialIds, kind: TrackKind, start: i64, dur: i64) -> Clip {
        Clip::new(ids.next_id(), "v", ids.next_id(), kind, TimeRange::new(s(10), s(dur)), s(start))
    }

    fn video(ids: &mut SequentialIds) -> Clip {
        clip(ids, TrackKind::Video, 0, 5)
    }

    fn value(c: &Clip, id: Id, key: &str) -> Option<f64> {
        c.effects.iter().find(|e| e.id == id)?.parameters.get(key).map(|p| p.value)
    }

    fn fade_keys(c: &Clip) -> (Vec<Time>, Vec<f64>) {
        let k = &c.animation.opacity.track.keys;
        (k.iter().map(|k| k.time).collect(), k.iter().map(|k| k.value).collect())
    }

    #[test]
    fn applied_effects_start_visible() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        let b = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).unwrap();
        let sh = c.add_effect(ClipEffect::SHARPEN_KIND, None, &mut ids).unwrap();
        let sp = c.add_effect(ClipEffect::SPHERIZE_KIND, None, &mut ids).unwrap();
        assert_eq!(value(&c, b, ClipEffect::BLURRINESS_KEY), Some(20.0));
        assert_eq!(value(&c, sh, ClipEffect::SHARPEN_AMOUNT_KEY), Some(50.0));
        assert_eq!(value(&c, sp, ClipEffect::SPHERIZE_RADIUS_KEY), Some(400.0));
    }

    #[test]
    fn stereo_width_starts_at_one_hundred_percent() {
        let mut ids = SequentialIds::default();
        let mut a = clip(&mut ids, TrackKind::Audio, 0, 5);
        let id = a.add_effect(ClipEffect::AUDIO_STEREO_WIDTH_KIND, None, &mut ids).unwrap();
        assert_eq!(value(&a, id, ClipEffect::STEREO_WIDTH_KEY), Some(100.0));
    }

    #[test]
    fn catalog_defaults_and_internal_effects_stay_the_same() {
        let blur = ClipEffect::default_parameters(ClipEffect::GAUSSIAN_BLUR_KIND);
        assert_eq!(blur.get(ClipEffect::BLURRINESS_KEY).map(|p| p.value), Some(0.0));
        let sharpen = ClipEffect::default_parameters(ClipEffect::SHARPEN_KIND);
        assert_eq!(sharpen.get(ClipEffect::SHARPEN_AMOUNT_KEY).map(|p| p.value), Some(0.0));
        let width = ClipEffect::default_parameters(ClipEffect::AUDIO_STEREO_WIDTH_KIND);
        assert_eq!(width.get(ClipEffect::STEREO_WIDTH_KEY).map(|p| p.value), Some(150.0));
        let made = ClipEffect::make(Id::from_u128(1), ClipEffect::GAUSSIAN_BLUR_KIND);
        assert_eq!(made.and_then(|e| e.parameters.get(ClipEffect::BLURRINESS_KEY).map(|p| p.value)), Some(0.0));
    }

    #[test]
    fn user_default_of_the_kind_wins() {
        let mut ids = SequentialIds::default();
        let mut d = EffectDefaults::default();
        let mut e = ClipEffect::make(ids.next_id(), ClipEffect::GAUSSIAN_BLUR_KIND).unwrap();
        e.parameters.insert(ClipEffect::BLURRINESS_KEY.to_string(), AnimatedProperty::new(7.0));
        assert!(d.set_default_effect(&e, true, Time::ZERO, &mut ids));
        let mut c = video(&mut ids);
        let id = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, Some(&d), &mut ids).unwrap();
        assert_eq!(value(&c, id, ClipEffect::BLURRINESS_KEY), Some(7.0));
    }

    #[test]
    fn second_instance_gets_its_own_id_and_unknown_or_wrong_kind_is_refused() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        let a = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids);
        let b = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids);
        assert_ne!(a, b);
        assert_eq!(c.effects.iter().map(|e| Some(e.id)).collect::<Vec<_>>(), [a, b]);
        assert_eq!(c.add_effect("nonsense", None, &mut ids), None);
        assert_eq!(c.add_effect(ClipEffect::AUDIO_STEREO_WIDTH_KIND, None, &mut ids), None);
    }

    #[test]
    fn move_clamps_and_rejects_unknown() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        let a = c.add_effect(ClipEffect::CROP_KIND, None, &mut ids).unwrap();
        let b = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).unwrap();
        assert!(c.move_effect(a, 99));
        assert_eq!(c.effects.iter().map(|e| e.id).collect::<Vec<_>>(), [b, a]);
        assert!(!c.move_effect(ids.next_id(), 0));
        assert!(!c.move_effect(a, 1), "already there");
        assert!(c.move_effect(a, 0));
        assert_eq!(c.effects[0].id, a);
    }

    #[test]
    fn duplicate_copies_values_with_new_ids_right_after() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        let a = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).unwrap();
        c.add_effect(ClipEffect::CROP_KIND, None, &mut ids);
        c.set_parameter(a, ClipEffect::BLURRINESS_KEY, 7.0);
        let copy = c.duplicate_effect(a, &mut ids).unwrap();
        assert_ne!(copy, a);
        assert_eq!(c.effects[1].id, copy);
        assert_eq!(c.effects.len(), 3);
        assert_eq!(c.effects[1].parameters.get(ClipEffect::BLURRINESS_KEY).map(|p| p.value), Some(7.0));
    }

    #[test]
    fn remove_effect_by_id() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        let a = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).unwrap();
        let b = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).unwrap();
        assert!(c.remove_effect(a));
        assert_eq!(c.effects.iter().map(|e| e.id).collect::<Vec<_>>(), [b]);
        assert!(!c.remove_effect(a));
    }

    #[test]
    fn set_parameter_sanitizes_nan_and_clamps_to_the_catalog_range() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        let a = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).unwrap();
        c.set_parameter(a, ClipEffect::BLURRINESS_KEY, f64::NAN);
        assert_eq!(value(&c, a, ClipEffect::BLURRINESS_KEY), Some(0.0));
        c.set_parameter(a, ClipEffect::BLURRINESS_KEY, 1.0e9);
        let top = ClipEffect::sanitized(1.0e9, ClipEffect::GAUSSIAN_BLUR_KIND, ClipEffect::BLURRINESS_KEY);
        assert_eq!(value(&c, a, ClipEffect::BLURRINESS_KEY), Some(top));
        assert!(top < 1.0e9);
    }

    #[test]
    fn fade_in_and_out_on_a_five_second_clip() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        c.apply_video_fade(ClipEdge::Head, s(1), None, &mut ids);
        assert_eq!(fade_keys(&c), (vec![s(0), s(1)], vec![0.0, 1.0]));
        c.apply_video_fade(ClipEdge::Tail, s(1), None, &mut ids);
        assert_eq!(fade_keys(&c), (vec![s(0), s(1), s(4), s(5)], vec![0.0, 1.0, 1.0, 0.0]));
        c.apply_video_fade(ClipEdge::Head, s(2), None, &mut ids);
        assert_eq!(fade_keys(&c).0, vec![s(0), s(2), s(4), s(5)]);
    }

    #[test]
    fn short_clip_fade_clamps_to_half_and_keeps_static_opacity_as_target() {
        let mut ids = SequentialIds::default();
        let mut c = clip(&mut ids, TrackKind::Video, 0, 1);
        c.apply_video_fade(ClipEdge::Head, s(5), None, &mut ids);
        assert_eq!(fade_keys(&c).0, vec![s(0), Time::new(1, 2)]);
        assert_eq!(OpacityFade::clamped(s(5), s(1)), Time::new(1, 2));
        assert_eq!(OpacityFade::clamped(Time::new(1, 4), s(1)), Time::new(1, 4));
        let mut d = video(&mut ids);
        d.animation.opacity = AnimatedProperty::new(0.6);
        d.apply_video_fade(ClipEdge::Head, s(1), None, &mut ids);
        assert_eq!(fade_keys(&d).1, vec![0.0, 0.6]);
    }

    #[test]
    fn opacity_keys_sit_on_frames() {
        let fd = Time::new(1, 30);
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        c.apply_video_fade(ClipEdge::Head, Time::new(1, 40), Some(fd), &mut ids);
        let t = c.animation.opacity.track.keys.last().map(|k| k.time).unwrap_or(Time::ZERO);
        assert_eq!(t, t.snapped(fd));
        let id = c.add_opacity_key(s(1), &mut ids).unwrap();
        c.move_opacity_key(id, Time::new(1234, 1000), 0.4, Some(fd));
        let k = c.animation.opacity.track.key(id).map(|k| (k.time, k.value));
        let time = k.map_or(Time::ZERO, |k| k.0);
        assert_eq!(time, time.snapped(fd));
        assert_ne!(time, Time::new(1234, 1000));
        assert_eq!(c.add_opacity_key(s(9), &mut ids), None, "outside the clip");
    }

    #[test]
    fn shift_opacity_line_moves_the_segment_under_the_time() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        c.shift_opacity_line(s(1), -0.25);
        assert_eq!(c.animation.opacity.value, 0.75);
        let a = c.add_opacity_key(s(1), &mut ids).unwrap();
        let b = c.add_opacity_key(s(3), &mut ids).unwrap();
        c.shift_opacity_line(s(2), -0.5);
        let at = |id: Id| c.animation.opacity.track.key(id).map(|k| k.value);
        assert_eq!((at(a), at(b)), (Some(0.25), Some(0.25)));
    }

    #[test]
    fn fade_through_the_timeline_uses_the_frame_grid_and_refuses_audio() {
        let fd = Time::new(1, 30);
        let mut ids = SequentialIds::default();
        let c = video(&mut ids);
        let mut t = sq_core_model::Track::new(ids.next_id(), TrackKind::Video);
        assert!(t.overwrite(c.clone(), &mut ids).is_ok());
        let mut tl = Timeline::new(ids.next_id(), "t", sq_core_model::SequenceFormat::new(fd), vec![t]);
        assert!(tl.fade_video(&[c.id], ClipEdge::Tail, Time::new(1, 7), &mut ids).is_ok());
        for k in &tl.tracks[0].clips()[0].animation.opacity.track.keys {
            assert_eq!(k.time, k.time.snapped(fd));
        }
        let a = clip(&mut ids, TrackKind::Audio, 0, 5);
        let mut at = sq_core_model::Track::new(ids.next_id(), TrackKind::Audio);
        assert!(at.overwrite(a.clone(), &mut ids).is_ok());
        let mut atl = Timeline::new(ids.next_id(), "t", sq_core_model::SequenceFormat::new(fd), vec![at]);
        assert_eq!(atl.fade_video(&[a.id], ClipEdge::Head, s(1), &mut ids), Err(EditError::WrongTrackKind));
    }

    #[test]
    fn pasting_attributes_carries_toggles_and_replaces_instead_of_stacking() {
        let mut ids = SequentialIds::default();
        let mut src = video(&mut ids);
        src.motion_enabled = false;
        src.opacity_enabled = false;
        let out = clip(&mut ids, TrackKind::Video, 20, 5).pasting_attributes(&src, &mut ids);
        assert!(!out.motion_enabled && !out.opacity_enabled);

        let b = src.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).unwrap();
        src.set_parameter(b, ClipEffect::BLURRINESS_KEY, 9.0);
        let dst = clip(&mut ids, TrackKind::Video, 20, 5);
        let once = dst.pasting_attributes(&src, &mut ids);
        assert_eq!(once.effects.len(), 1);
        src.set_parameter(b, ClipEffect::BLURRINESS_KEY, 3.0);
        let twice = once.pasting_attributes(&src, &mut ids);
        assert_eq!(twice.effects.len(), 1);
        assert_eq!(twice.effects[0].parameters.get(ClipEffect::BLURRINESS_KEY).map(|p| p.value), Some(3.0));
    }

    #[test]
    fn pasting_with_different_counts_adds_and_other_kinds_are_left_alone() {
        let mut ids = SequentialIds::default();
        let mut src = video(&mut ids);
        src.add_effect(ClipEffect::CROP_KIND, None, &mut ids);
        let mut dst = clip(&mut ids, TrackKind::Video, 20, 5);
        dst.add_effect(ClipEffect::CROP_KIND, None, &mut ids);
        dst.add_effect(ClipEffect::CROP_KIND, None, &mut ids);
        assert_eq!(dst.pasting_attributes(&src, &mut ids).effects.len(), 3);
        let audio = clip(&mut ids, TrackKind::Audio, 0, 5);
        assert_eq!(audio.pasting_attributes(&src, &mut ids), audio);
    }

    #[test]
    fn key_times_scaled_stretches_opacity_keys() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        let k = c.add_opacity_key(s(1), &mut ids).unwrap();
        let out = c.key_times_scaled(s(10));
        assert_eq!(out.animation.opacity.track.key(k).map(|k| k.time), Some(s(2)));
        assert_eq!(c.key_times_scaled(s(5)), c);
    }

    #[test]
    fn a_stabilizer_goes_before_the_first_other_transform_stage_and_only_once() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids);
        c.add_effect(ClipEffect::TRANSFORM_KIND, None, &mut ids);
        let st = c.add_effect(STABILIZE_KIND, None, &mut ids);
        assert!(st.is_some());
        assert_eq!(c.effects.iter().position(|e| e.kind == STABILIZE_KIND), Some(1));
        assert_eq!(c.add_effect(STABILIZE_KIND, None, &mut ids), None, "one per clip");
    }

    #[test]
    fn mosaic_grid_makes_square_blocks() {
        assert_eq!(MosaicBlockSize::grid(100.0, 1920, 1080), MosaicGrid { columns: 19, rows: 11 });
        assert_eq!(MosaicBlockSize::grid(0.0, 10_000, 10), MosaicGrid { columns: 4000, rows: 10 });
        assert_eq!(MosaicBlockSize::anonymize_block_size(400.0, 1920, 1080), 50.0);
        assert_eq!(MosaicBlockSize::anonymize_block_size(8.0, 1920, 1080), 18.0);
    }

    fn pick(x: f64, part: Option<AnonymizeTarget>) -> MagicSelection {
        let point = MagicPoint { position: Vec2::new(x, 0.5), subtract: false, source_time: Time::new(1, 2) };
        MagicSelection { points: vec![point], part }
    }

    #[test]
    fn anonymize_adds_one_cover_limited_to_one_mask_per_person() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        let picks = [pick(0.3, Some(AnonymizeTarget::Face)), pick(0.7, Some(AnonymizeTarget::Face))];
        let made =
            c.add_anonymize(&picks, AnonymizeTarget::Face, AnonymizeCover::Mosaic, 400.0, (1920, 1080), &mut ids);
        assert_eq!(made.len(), 2);
        assert_eq!(c.masks().iter().map(|m| m.id).collect::<Vec<_>>(), made);
        assert_eq!(c.masks().iter().map(|m| m.name.as_str()).collect::<Vec<_>>(), ["Face 1", "Face 2"]);
        for m in c.masks() {
            assert!(m.source() == MaskSource::Magic && !m.used_by_opacity());
            assert_eq!(m.magic.as_ref().and_then(|s| s.part), Some(AnonymizeTarget::Face));
        }
        assert_eq!(c.effects.len(), 1);
        let e = &c.effects[0];
        assert!(e.kind == ClipEffect::MOSAIC_KIND && e.mask_input == made);
        // 50 px blocks on 1920 x 1080.
        let grid = |k: &str| e.parameters.get(k).map(|p| p.value);
        assert_eq!(grid(ClipEffect::MOSAIC_COLUMNS_KEY), Some(38.0));
        assert_eq!(grid(ClipEffect::MOSAIC_ROWS_KEY), Some(22.0));

        // A second run adds its own masks and cover and numbers on; a whole person made by Anonymize must cover too.
        let more = c.add_anonymize(
            &[pick(0.5, None)],
            AnonymizeTarget::Person,
            AnonymizeCover::Blur,
            300.0,
            (1920, 1080),
            &mut ids,
        );
        assert!(c.masks().len() == 3 && c.masks().last().map(|m| m.name.as_str()) == Some("Person 1"));
        let last = c.masks().last().and_then(|m| m.magic.clone());
        assert_eq!(last.as_ref().and_then(|s| s.part), Some(AnonymizeTarget::Person));
        assert!(last.is_some_and(|s| s.must_cover()));
        assert!(
            c.effects.len() == 2
                && c.effects[0].kind == ClipEffect::GAUSSIAN_BLUR_KIND
                && c.effects[0].mask_input == more
        );
        assert!(c.effects[0].parameters.get(ClipEffect::BLURRINESS_KEY).is_some_and(|p| p.value >= 54.0));
        assert!(
            c.add_anonymize(&[], AnonymizeTarget::Face, AnonymizeCover::Mosaic, 1.0, (10, 10), &mut ids).is_empty()
        );
        assert_eq!(c.effects.len(), 2);
    }

    #[test]
    fn the_cover_goes_in_front_of_a_horizontal_flip_added_earlier() {
        let mut ids = SequentialIds::default();
        let mut c = video(&mut ids);
        c.effects = vec![ClipEffect::make(ids.next_id(), ClipEffect::HORIZONTAL_FLIP_KIND).unwrap()];
        c.add_anonymize(
            &[pick(0.3, Some(AnonymizeTarget::Face))],
            AnonymizeTarget::Face,
            AnonymizeCover::Mosaic,
            400.0,
            (1920, 1080),
            &mut ids,
        );
        let kinds: Vec<&str> = c.effects.iter().map(|e| e.kind.as_str()).collect();
        assert_eq!(kinds, [ClipEffect::MOSAIC_KIND, ClipEffect::HORIZONTAL_FLIP_KIND]);
    }

    fn shaky(n: usize) -> StabilizationAnalysis {
        let mut state: u64 = 11;
        let mut rnd = || {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (state >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
        };
        let poses: Vec<CameraPose> = (0..n)
            .map(|k| CameraPose::new(Vec2::new(0.8 * k as f64 + 6.0 * rnd(), 6.0 * rnd()), 0.3 * rnd(), 0.0))
            .collect();
        let mut motions = vec![CameraMotion::new(0.0, 0.0, 0.0, 1.0)];
        motions.extend((1..n).map(|k| CameraMotion::from_poses(&poses[k - 1], &poses[k])));
        let fd30 = Time::new(1, 30);
        StabilizationAnalysis::new(1920, 1080, (0..n as i64).map(|i| fd30 * i).collect(), motions)
    }

    #[test]
    fn a_double_speed_clip_uses_every_second_source_correction() {
        let fd30 = Time::new(1, 30);
        let mut ids = SequentialIds::default();
        let a = shaky(120);
        let plan = Stabilizer::plan(&a, &StabilizerOptions::default()).unwrap();
        let mut c = Clip::new(
            ids.next_id(),
            "v",
            ids.next_id(),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, fd30 * 60),
            Time::ZERO,
        );
        c.speed = sq_core_model::ClipSpeed::new(2, 1);
        assert_eq!(c.duration(), fd30 * 30);
        let e = stabilizer_effect(&plan, &a, &c, fd30, &StabilizerOptions::default(), ids.next_id(), &mut ids);
        for i in [0, 7, 15, 29] {
            let s = e.stage_transform(fd30 * i, Some(c.duration()), Vec2::new(1920.0, 1080.0));
            assert!(
                (s.position.x - plan.corrections[2 * i as usize].position.x).abs()
                    <= Stabilizer::POSITION_TOLERANCE + 1e-9
            );
            assert!(
                (s.rotation - plan.corrections[2 * i as usize].rotation).abs() <= Stabilizer::ROTATION_TOLERANCE + 1e-9
            );
        }
        // The plan itself does not depend on the clip: same smoothing window in source frames at any speed.
        assert_eq!(Stabilizer::plan(&a, &StabilizerOptions::default()).map(|p| p.corrections), Some(plan.corrections));
    }

    #[test]
    fn an_analysed_stabilizer_records_standard_and_its_range_and_a_fresh_one_changes_nothing() {
        use sq_core_masks::ClipEffectStabilizeExt;
        let fd30 = Time::new(1, 30);
        let mut ids = SequentialIds::default();
        let a = shaky(120);
        let plan = Stabilizer::plan(&a, &StabilizerOptions::default()).unwrap();
        let c = clip(&mut ids, TrackKind::Video, 0, 4);
        let e = stabilizer_effect(&plan, &a, &c, fd30, &StabilizerOptions::default(), ids.next_id(), &mut ids);
        assert!(e.stabilize_is_analysed());
        assert_eq!(e.parameters.get(ClipEffect::STABILIZE_METHOD_KEY).map(|p| p.value), Some(0.0));
        // A Stabilizer written before the range was recorded still counts as analyzed (it carries stage keys).
        let mut old = e.clone();
        old.parameters.remove(ClipEffect::STABILIZE_FROM_KEY);
        old.parameters.remove(ClipEffect::STABILIZE_TO_KEY);
        assert!(old.stabilize_is_analysed());

        let mut fresh = video(&mut ids);
        assert!(fresh.add_effect(STABILIZE_KIND, None, &mut ids).is_some());
        let f = fresh.effects.iter().find(|e| e.kind == STABILIZE_KIND).unwrap();
        assert!(!f.stabilize_is_analysed());
        assert_eq!(
            f.stage_transform(fd30 * 10, Some(fresh.duration()), Vec2::new(1920.0, 1080.0)),
            sq_core_model::StageTransform::IDENTITY
        );
    }

    #[test]
    fn stabilize_only_goes_onto_clips_with_moving_pictures() {
        let mut ids = SequentialIds::default();
        let mut still = video(&mut ids);
        still.is_still = true;
        assert!(still.add_effect(STABILIZE_KIND, None, &mut ids).is_none());
        let mut held = video(&mut ids);
        held.hold_frame = Some(Time::ZERO);
        assert!(held.add_effect(STABILIZE_KIND, None, &mut ids).is_none());
        let mut nested = video(&mut ids);
        nested.sequence = Some(ids.next_id());
        assert!(nested.add_effect(STABILIZE_KIND, None, &mut ids).is_none());
        let mut audio = clip(&mut ids, TrackKind::Audio, 0, 5);
        assert!(audio.add_effect(STABILIZE_KIND, None, &mut ids).is_none());
        assert!(video(&mut ids).can_stabilize() && !still.can_stabilize());
    }

    fn picture(ids: &mut SequentialIds) -> Clip {
        let mut c = clip(ids, TrackKind::Video, 0, 4);
        c.media_duration = Some(s(10));
        c
    }

    #[test]
    fn colour_effects_stay_first_in_the_list_and_a_later_one_has_no_input_lut() {
        use sq_core_model::LUTRef;
        let mut ids = SequentialIds::default();
        let mut c = picture(&mut ids);
        let blur = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).unwrap();
        let a = c.add_effect(ClipEffect::COLOR_KIND, None, &mut ids).unwrap();
        let b = c.add_effect(ClipEffect::COLOR_KIND, None, &mut ids).unwrap();
        let order = |c: &Clip| c.effects.iter().map(|e| e.id).collect::<Vec<_>>();
        assert_eq!(order(&c), [a, b, blur], "added in front of the other effects");
        let luts: Vec<Option<LUTRef>> =
            c.effects.iter().filter(|e| e.is_color()).map(|e| e.color_data().input_lut).collect();
        assert_eq!(luts, [Some(LUTRef::Automatic), None]);
        // A Color effect does not move (the first one is the conversion) and nothing moves in front of one.
        assert!(!c.move_effect(b, 0) && !c.move_effect(a, 2) && !c.move_effect(blur, 0));
        assert_eq!(order(&c), [a, b, blur]);
        let sharpen = c.add_effect(ClipEffect::SHARPEN_KIND, None, &mut ids).unwrap();
        assert!(c.move_effect(sharpen, 0));
        assert_eq!(order(&c), [a, b, sharpen, blur]);
    }

    #[test]
    fn colour_is_refused_on_nested_and_generator_clips_and_pasting_skips_it() {
        let mut ids = SequentialIds::default();
        let mut nested = picture(&mut ids);
        nested.sequence = Some(ids.next_id());
        let mut solid = picture(&mut ids);
        solid.generator = Some(GeneratorRef { kind: "solid".into(), payload: vec![1, 2, 3], payload_version: 1 });
        let mut src = picture(&mut ids);
        src.add_effect(ClipEffect::COLOR_KIND, None, &mut ids);
        for mut c in [nested, solid] {
            assert!(!c.accepts_color());
            assert!(c.add_effect(ClipEffect::COLOR_KIND, None, &mut ids).is_none());
            assert!(c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).is_some());
            assert!(!c.pasting_attributes(&src, &mut ids).effects.iter().any(|e| e.is_color()));
        }
        assert!(picture(&mut ids).accepts_color());
    }

    #[test]
    fn pasting_the_grade_replaces_the_targets_and_does_not_stack() {
        let mut ids = SequentialIds::default();
        let mut src = picture(&mut ids);
        src.add_effect(ClipEffect::COLOR_KIND, None, &mut ids);
        src.add_effect(ClipEffect::COLOR_KIND, None, &mut ids);
        let mut dst = picture(&mut ids);
        dst.media = src.media;
        dst.add_effect(ClipEffect::COLOR_KIND, None, &mut ids);
        let out = dst.pasting_attributes(&src, &mut ids);
        assert_eq!(out.effects.iter().filter(|e| e.kind == ClipEffect::COLOR_KIND).count(), 2);
        assert_eq!(out.pasting_attributes(&src, &mut ids).effects.len(), out.effects.len());
    }

    #[test]
    fn removing_an_effect_drops_its_variant_override() {
        let mut ids = SequentialIds::default();
        let mut c = picture(&mut ids);
        let fx = c.add_effect(ClipEffect::GAUSSIAN_BLUR_KIND, None, &mut ids).unwrap();
        let variant = ids.next_id();
        let overrides = serde_json::from_value(serde_json::json!({
            variant.to_string(): {"effectParameters": {fx.to_string(): {"blurriness": {"value": 5.0}}}}
        }))
        .unwrap();
        c.variant_store = Some(overrides);
        assert!(c.remove_effect(fx));
        let left =
            c.variant_store.as_ref().and_then(|v| v.items.get(&variant)).map(|o| o.effect_parameters.contains_key(&fx));
        assert_ne!(left, Some(true));
    }
}
