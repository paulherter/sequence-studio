// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: EffectPreset.swift (`TransitionPreset` is a model type; its capture/apply verbs wait on the transition port)
//! A saved look: Motion/Opacity properties and applied effects, with their keyframes and easing. Key times are stored
//! clip-local as they were on the clip the preset was saved from (`reference_duration` long); `anchor` decides how they
//! land on a clip of another length.

use crate::sequence_conform::{SequenceConform, TEXT_KIND};
use serde::{Deserialize, Serialize};
use sq_core_color::{ClipEffectColorExt, ClipGradeExt};
use sq_core_model::effect_defaults::{PayloadError, PayloadReadError};
use sq_core_model::{AnimatedProperty, Clip, ClipAnimation, ClipEffect, EditError, Timeline, TrackKind};
use sq_core_time::{EncodeContext, Id, IdSource, Keyframe, KeyframeTrack, KeyframeValue, Time, Vec2};
use std::collections::BTreeSet;

/// How a key saved on a clip of one length lands on a clip of another.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Anchor {
    /// Keys keep their distance to the clip's first frame.
    Start,
    /// Keys keep their distance to the clip's end.
    End,
    /// Key times scale with the clip length.
    Stretch,
}

/// A Motion property a preset can hold.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MotionProperty {
    /// Position.
    Position,
    /// Scale.
    Scale,
    /// Rotation.
    Rotation,
    /// Opacity.
    Opacity,
    /// Anchor point.
    AnchorPoint,
    /// Motion's Shutter Angle (absent in presets saved before it).
    ShutterAngle,
}

/// How a preset's Motion/Opacity land on a clip that already has its own.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ApplyMode {
    /// The preset's values and keys replace the clip's.
    Absolute,
    /// The preset adds onto the clip: Position, Rotation and Anchor are added, Scale and Opacity multiply (the preset is
    /// read against its own 100 %). The clip's keys stay, the preset's keys join them.
    Relative,
}

/// A saved look: Motion/Opacity properties and applied effects.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EffectPreset {
    /// How keys land on a clip of another length.
    pub anchor: Anchor,
    /// Length of the clip the preset was saved from (the reference for `End` and `Stretch`).
    pub reference_duration: Time,
    /// Position.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<AnimatedProperty<Vec2>>,
    /// Scale.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<AnimatedProperty<Vec2>>,
    /// Rotation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rotation: Option<AnimatedProperty<f64>>,
    /// Opacity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opacity: Option<AnimatedProperty<f64>>,
    /// Anchor point.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anchor_point: Option<AnimatedProperty<Vec2>>,
    /// Shutter Angle.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shutter_angle: Option<AnimatedProperty<f64>>,
    /// Appended to the target's effects (new ids), in this order.
    pub effects: Vec<ClipEffect>,
    /// Width x height of the sequence the preset was made on. Applied to a sequence of another size, the spatial values
    /// (Position, Anchor Point, effect points, spatial tangents) scale by the ratio per axis, so a placement keeps its
    /// share of the frame. `None` (presets saved before it, built-in stacks) = applied as stored. Only written when set,
    /// so the payload version stays 1 and older builds read it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame_size: Option<Vec2>,
}

impl EffectPreset {
    /// Version of the JSON payload (`PresetItem.payloadVersion` for effect presets).
    pub const PAYLOAD_VERSION: i64 = 1;

    /// An empty preset.
    pub fn new(anchor: Anchor, reference_duration: Time) -> EffectPreset {
        EffectPreset {
            anchor,
            reference_duration,
            position: None,
            scale: None,
            rotation: None,
            opacity: None,
            anchor_point: None,
            shutter_angle: None,
            effects: Vec::new(),
            frame_size: None,
        }
    }

    /// The Motion properties the preset holds.
    pub fn motion_properties(&self) -> BTreeSet<MotionProperty> {
        let mut out = BTreeSet::new();
        let held = [
            (MotionProperty::Position, self.position.is_some()),
            (MotionProperty::Scale, self.scale.is_some()),
            (MotionProperty::Rotation, self.rotation.is_some()),
            (MotionProperty::Opacity, self.opacity.is_some()),
            (MotionProperty::AnchorPoint, self.anchor_point.is_some()),
            (MotionProperty::ShutterAngle, self.shutter_angle.is_some()),
        ];
        for (p, on) in held {
            if on {
                out.insert(p);
            }
        }
        out
    }

    /// Holds neither Motion properties nor effects.
    pub fn is_empty(&self) -> bool {
        self.motion_properties().is_empty() && self.effects.is_empty()
    }

    /// Only audio effects (no Motion/Opacity): applies to audio clips instead of video clips (an imported voice chain).
    pub fn is_audio_only(&self) -> bool {
        self.motion_properties().is_empty() && !self.effects.is_empty() && self.effects.iter().all(|e| e.is_audio())
    }

    /// The track kind this preset applies to.
    pub fn track_kind(&self) -> TrackKind {
        if self.is_audio_only() { TrackKind::Audio } else { TrackKind::Video }
    }

    /// Preset from `clip`. `motion` `None` = every property that is keyframed or differs from its default; `effects`
    /// `None` = all applied effects (in list order). `frame_size`: the sequence's width x height.
    pub fn capture(
        clip: &Clip,
        anchor: Anchor,
        motion: Option<&BTreeSet<MotionProperty>>,
        effects: Option<&BTreeSet<Id>>,
        frame_size: Option<Vec2>,
    ) -> EffectPreset {
        let (a, d) = (&clip.animation, ClipAnimation::default());
        fn take<V: KeyframeValue>(
            motion: Option<&BTreeSet<MotionProperty>>,
            p: MotionProperty,
            v: &AnimatedProperty<V>,
            def: &AnimatedProperty<V>,
        ) -> Option<AnimatedProperty<V>> {
            if let Some(m) = motion {
                return m.contains(&p).then(|| v.clone());
            }
            (v.is_animated() || v.value != def.value).then(|| v.clone())
        }
        EffectPreset {
            anchor,
            reference_duration: clip.duration(),
            position: take(motion, MotionProperty::Position, &a.position, &d.position),
            scale: take(motion, MotionProperty::Scale, &a.scale, &d.scale),
            rotation: take(motion, MotionProperty::Rotation, &a.rotation, &d.rotation),
            opacity: take(motion, MotionProperty::Opacity, &a.opacity, &d.opacity),
            anchor_point: take(motion, MotionProperty::AnchorPoint, &a.anchor, &d.anchor),
            shutter_angle: take(motion, MotionProperty::ShutterAngle, &a.shutter_angle, &d.shutter_angle),
            effects: clip.effects.iter().filter(|e| effects.is_none_or(|set| set.contains(&e.id))).cloned().collect(),
            frame_size,
        }
    }

    /// The one uniform factor that maps `frame_size` onto `target`, as Change Format's default conform (fill:
    /// `SequenceConform::frame_factor`); `None` when either is unknown, not positive, or they are equal. Uniform, so a
    /// circular motion path stays circular.
    pub fn spatial_scale(&self, target: Option<Vec2>) -> Option<f64> {
        let (from, target) = (self.frame_size?, target?);
        if from.x <= 0.0 || from.y <= 0.0 || target.x <= 0.0 || target.y <= 0.0 || from == target {
            return None;
        }
        Some((target.x / from.x).max(target.y / from.y))
    }

    /// Where a key saved at clip-local `t` (on a `reference`-long clip) lands on a `target`-long clip. `Stretch` with a
    /// zero reference behaves like `Start`.
    pub fn map_time(t: Time, anchor: Anchor, reference: Time, target: Time) -> Time {
        match anchor {
            Anchor::Start => t,
            Anchor::End => t + (target - reference),
            Anchor::Stretch => {
                if reference <= Time::ZERO {
                    return t;
                }
                Self::scaled(t, target, reference)
            }
        }
    }

    /// `t * num / den` exactly when it fits Int64, else rounded to microseconds. `den` must be positive.
    pub(crate) fn scaled(t: Time, num: Time, den: Time) -> Time {
        let n = i128::from(t.value()) * i128::from(num.value()) * i128::from(den.timescale());
        let d = i128::from(t.timescale()) * i128::from(num.timescale()) * i128::from(den.value());
        let mut g = gcd128(n.unsigned_abs(), d.unsigned_abs());
        if g == 0 {
            g = 1;
        }
        let (rn, rd) = (n / g as i128, d / g as i128);
        if let (Ok(v), Ok(s)) = (i64::try_from(rn), i64::try_from(rd))
            && s > 0
        {
            return Time::new(v, s);
        }
        let micro = (n as f64 / d as f64 * 1_000_000.0).round();
        // Swift traps converting a value out of range; saturating keeps the result finite.
        Time::new(micro as i64, 1_000_000)
    }

    /// Versioned JSON stored in `PresetItem.payload`, keys sorted.
    pub fn payload(&self) -> Result<Vec<u8>, serde_json::Error> {
        let _plain = EncodeContext::plain();
        // A `Value` keeps its object keys sorted (`preserve_order` is on in the app build: use `sq_core_time::json_sorted`).
        serde_json::to_vec(&sq_core_time::json_sorted::to_value(self)?)
    }

    /// Decodes a payload; a newer `version` than this build understands is refused. New key ids of upgraded effects come
    /// from `ids`.
    pub fn from_payload(
        payload: &[u8],
        version: i64,
        ids: &mut dyn IdSource,
    ) -> Result<EffectPreset, PayloadReadError> {
        if version > Self::PAYLOAD_VERSION {
            return Err(PayloadError::NewerVersion { found: version, supported: Self::PAYLOAD_VERSION }.into());
        }
        let mut p: EffectPreset = serde_json::from_slice(payload).map_err(PayloadReadError::Json)?;
        // Saved before v24: a Drop Shadow color may still be three channels.
        p.effects = p.effects.iter().map(|e| e.upgrading_legacy_shadow_color(ids)).collect();
        Ok(p)
    }
}

fn gcd128(mut a: u128, mut b: u128) -> u128 {
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

/// Key times through `f`, every key with a fresh id (keeps values and easing).
fn preset_mapped<V: KeyframeValue>(
    p: &AnimatedProperty<V>,
    f: &dyn Fn(Time) -> Time,
    ids: &mut dyn IdSource,
) -> AnimatedProperty<V> {
    let mut c = p.clone();
    c.track = KeyframeTrack::with_keys(
        p.track
            .keys
            .iter()
            .map(|k| {
                let mut k = k.clone();
                k.id = ids.next_id();
                k.time = f(k.time);
                k
            })
            .collect(),
    );
    c
}

/// `own` (the clip's) combined with `preset` (already time-mapped, fresh key ids) through `op`. Exact when one side is
/// static (the other side's curve keeps its easing); with keys on both sides the result has a key at every key time of
/// either, value = op(clip(t), preset(t)), easing from the key that sits there (preset first).
fn combined<V: KeyframeValue>(
    own: &AnimatedProperty<V>,
    preset: &AnimatedProperty<V>,
    op: &dyn Fn(&V, &V) -> V,
) -> AnimatedProperty<V> {
    if !preset.is_animated() {
        let mut c = own.clone();
        c.value = op(&own.value, &preset.value);
        c.track = KeyframeTrack::with_keys(
            own.track
                .keys
                .iter()
                .map(|k| {
                    let mut k = k.clone();
                    k.value = op(&k.value, &preset.value);
                    k
                })
                .collect(),
        );
        return c;
    }
    if !own.is_animated() {
        let mut c = preset.clone();
        c.value = op(&own.value, &preset.value);
        c.track = KeyframeTrack::with_keys(
            preset
                .track
                .keys
                .iter()
                .map(|k| {
                    let mut k = k.clone();
                    k.value = op(&own.value, &k.value);
                    k
                })
                .collect(),
        );
        return c;
    }
    // Where both sides have a key the preset's is the one kept, under its own id. A Hold or Hold Ahead of the clip's key
    // there wins over the preset's shape: a step never becomes a ramp.
    let (mine, theirs) = (&own.track.keys, &preset.track.keys);
    let times: BTreeSet<Time> = mine.iter().chain(theirs.iter()).map(|k| k.time).collect();
    let keys: Vec<Keyframe<V>> = times
        .into_iter()
        .filter_map(|t| {
            let mine_here = mine.iter().find(|k| k.time == t);
            let mut k = theirs.iter().find(|k| k.time == t).or(mine_here)?.clone();
            if let Some(o) = mine_here.filter(|o| o.interpolation.is_hold()) {
                k.interpolation = o.interpolation;
            }
            k.value = op(&own.value_at_local(t), &preset.value_at_local(t));
            Some(k)
        })
        .collect();
    AnimatedProperty { value: op(&own.value, &preset.value), track: KeyframeTrack::with_keys(keys) }
}

/// Applying a preset to a clip (Swift `extension Clip` in EffectPreset.swift).
pub trait ClipEffectPresetExt {
    /// Applies `preset`. `Absolute`: its Motion/Opacity properties replace the clip's (value and keys); `Relative`: they
    /// add onto the clip's own (see `ApplyMode`). Its effects are appended with new ids either way. Keys are placed by the
    /// preset's anchor; keys that land outside the clip are kept, they only shape the curve at the edge. `frame_size`: the
    /// target sequence's width x height; spatial values scale to it from the preset's own `frame_size`, `None` keeps them as
    /// stored.
    fn apply_preset(
        &mut self,
        preset: &EffectPreset,
        mode: ApplyMode,
        frame_size: Option<Vec2>,
        ids: &mut dyn IdSource,
    );
}

impl ClipEffectPresetExt for Clip {
    fn apply_preset(
        &mut self,
        preset: &EffectPreset,
        mode: ApplyMode,
        frame_size: Option<Vec2>,
        ids: &mut dyn IdSource,
    ) {
        let mut preset = preset.clone();
        if let (Some(k), Some(from), Some(to)) = (preset.spatial_scale(frame_size), preset.frame_size, frame_size) {
            // Only what Change Format conforms: Motion Position (canvas px) and a Group Transform's Position/Anchor. Anchor
            // Point (layer px), Scale and other effects' points (clip px) stay. A picture uses the uniform fill factor, a
            // text clip one factor per axis (a lower third stays a lower third).
            let is_text = self.generator.as_ref().is_some_and(|g| g.kind == TEXT_KIND);
            let (sx, sy) = if is_text { (to.x / from.x, to.y / from.y) } else { (k, k) };
            preset.position = preset.position.as_ref().map(|p| SequenceConform::scaled(p, sx, sy));
            preset.effects = preset.effects.iter().map(|e| SequenceConform::conform_group_stage(e, sx, sy)).collect();
        }
        let target = self.duration();
        let (anchor, reference) = (preset.anchor, preset.reference_duration);
        let f = move |t: Time| EffectPreset::map_time(t, anchor, reference, target);
        let anim = &mut self.animation;
        match mode {
            ApplyMode::Absolute => {
                if let Some(p) = &preset.position {
                    anim.position = preset_mapped(p, &f, ids);
                }
                if let Some(p) = &preset.scale {
                    anim.scale = preset_mapped(p, &f, ids);
                    self.set_pending_source_pixel_scale(false); // an absolute Scale in source pixels; nothing is owed any more
                }
                let anim = &mut self.animation;
                if let Some(p) = &preset.rotation {
                    anim.rotation = preset_mapped(p, &f, ids);
                }
                if let Some(p) = &preset.opacity {
                    anim.opacity = preset_mapped(p, &f, ids);
                }
                if let Some(p) = &preset.anchor_point {
                    anim.anchor = preset_mapped(p, &f, ids);
                }
                if let Some(p) = &preset.shutter_angle {
                    anim.shutter_angle = preset_mapped(p, &f, ids);
                }
            }
            ApplyMode::Relative => {
                let add = |a: &Vec2, b: &Vec2| Vec2::new(a.x + b.x, a.y + b.y);
                let mul = |a: &Vec2, b: &Vec2| Vec2::new(a.x * b.x, a.y * b.y);
                if let Some(p) = &preset.position {
                    anim.position = combined(&anim.position, &preset_mapped(p, &f, ids), &add);
                }
                if let Some(p) = &preset.scale {
                    anim.scale = combined(&anim.scale, &preset_mapped(p, &f, ids), &mul);
                }
                if let Some(p) = &preset.rotation {
                    anim.rotation = combined(&anim.rotation, &preset_mapped(p, &f, ids), &|a, b| a + b);
                }
                if let Some(p) = &preset.opacity {
                    anim.opacity = combined(&anim.opacity, &preset_mapped(p, &f, ids), &|a, b| a * b);
                }
                if let Some(p) = &preset.anchor_point {
                    anim.anchor = combined(&anim.anchor, &preset_mapped(p, &f, ids), &add);
                }
                // A shutter does not add up: the preset's replaces the clip's.
                if let Some(p) = &preset.shutter_angle {
                    anim.shutter_angle = preset_mapped(p, &f, ids);
                }
            }
        }
        // Fresh ids for the effect and every key, so applying twice never duplicates key ids. Presets saved before v24 may
        // still hold a Drop Shadow color as three channels.
        let added: Vec<ClipEffect> = preset
            .effects
            .iter()
            .map(|fx| {
                let mut e = fx.upgrading_legacy_shadow_color(ids);
                e.id = ids.next_id();
                e.parameters = e.parameters.iter().map(|(k, p)| (k.clone(), preset_mapped(p, &f, ids))).collect();
                e.colors = e.colors.iter().map(|(k, p)| (k.clone(), preset_mapped(p, &f, ids))).collect();
                e.points = e.points.iter().map(|(k, p)| (k.clone(), preset_mapped(p, &f, ids))).collect();
                e
            })
            .collect();
        // Color effects stay first (behind the clip's own), and only on clips that take color.
        let colors: Vec<&ClipEffect> = added.iter().filter(|e| e.is_color()).collect();
        if !colors.is_empty() && self.accepts_color() {
            let at = self.color_effect_indices().last().map_or(0, |i| i + 1);
            let adapted: Vec<ClipEffect> =
                colors.iter().enumerate().map(|(i, e)| e.adapting_luts(self.media, at + i == 0)).collect();
            self.effects.splice(at..at, adapted);
        }
        self.effects.extend(added.into_iter().filter(|e| !e.is_color()));
    }
}

/// Applying a preset to clips (Swift `extension Timeline` in EffectPreset.swift).
pub trait TimelineEffectPresetExt {
    /// Applies `preset` to the clips among `ids` of its kind (`EffectPreset::track_kind`: video, or audio for an audio-only
    /// preset; the others are skipped). Returns how many changed. `WrongTrackKind` when none is of that kind,
    /// `TrackLocked` for a clip on a locked track.
    fn apply_preset(
        &mut self,
        preset: &EffectPreset,
        ids: &BTreeSet<Id>,
        mode: ApplyMode,
        id_source: &mut dyn IdSource,
    ) -> Result<usize, EditError>;
}

impl TimelineEffectPresetExt for Timeline {
    fn apply_preset(
        &mut self,
        preset: &EffectPreset,
        ids: &BTreeSet<Id>,
        mode: ApplyMode,
        id_source: &mut dyn IdSource,
    ) -> Result<usize, EditError> {
        let mut work = self.clone();
        let mut changed = 0;
        let kind = preset.track_kind();
        let size = Vec2::new(work.format.display_width() as f64, work.format.height as f64);
        for tr in work.tracks.iter_mut().filter(|t| t.kind == kind) {
            let clips: Vec<Clip> = tr.clips().iter().filter(|c| ids.contains(&c.id)).cloned().collect();
            for c in clips {
                if tr.is_locked {
                    return Err(EditError::TrackLocked);
                }
                let mut n = c;
                n.apply_preset(preset, mode, Some(size), id_source);
                tr.replace(n);
                changed += 1;
            }
        }
        if changed == 0 {
            return Err(EditError::WrongTrackKind);
        }
        *self = work;
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{EffectColor, GeneratorRef, SequenceFormat, Track};
    use sq_core_time::{EaseHandle, Interpolation, SequentialIds, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn ms(n: i64) -> Time {
        Time::new(n, 1000)
    }

    const EASE_OUT: EaseHandle = EaseHandle { dx: 0.6, dy: 0.0 };
    const EASE_IN: EaseHandle = EaseHandle { dx: 0.4, dy: 0.1 };

    fn clip(ids: &mut SequentialIds, seconds: i64, start: Time, kind: TrackKind) -> Clip {
        Clip::new(ids.next_id(), "c", ids.next_id(), kind, TimeRange::new(Time::ZERO, s(seconds)), start)
    }

    fn video(ids: &mut SequentialIds, seconds: i64) -> Clip {
        clip(ids, seconds, Time::ZERO, TrackKind::Video)
    }

    fn key<V: KeyframeValue>(ids: &mut SequentialIds, t: Time, v: V) -> Keyframe<V> {
        Keyframe::new(ids.next_id(), t, v)
    }

    fn eased<V: KeyframeValue>(
        ids: &mut SequentialIds,
        t: Time,
        v: V,
        in_h: EaseHandle,
        out_h: EaseHandle,
    ) -> Keyframe<V> {
        let mut k = key(ids, t, v);
        k.interpolation = Interpolation::Bezier;
        k.in_handle = in_h;
        k.out_handle = out_h;
        k
    }

    /// Pop-in: Scale 0 to 1 and Opacity 0 to 1 over the first 500 ms, eased.
    fn pop_in_clip(ids: &mut SequentialIds, seconds: i64) -> Clip {
        let mut c = video(ids, seconds);
        let lin = EaseHandle::LINEAR;
        c.animation.scale.track = KeyframeTrack::with_keys(vec![
            eased(ids, Time::ZERO, Vec2::new(0.0, 0.0), lin, EASE_OUT),
            eased(ids, ms(500), Vec2::new(1.0, 1.0), EASE_IN, lin),
        ]);
        c.animation.opacity.track = KeyframeTrack::with_keys(vec![
            eased(ids, Time::ZERO, 0.0, lin, EASE_OUT),
            eased(ids, ms(500), 1.0, EASE_IN, lin),
        ]);
        c
    }

    fn effect(ids: &mut SequentialIds, kind: &str) -> ClipEffect {
        ClipEffect::new(ids.next_id(), kind)
    }

    fn times<V>(p: &AnimatedProperty<V>) -> Vec<Time> {
        p.track.keys.iter().map(|k| k.time).collect()
    }

    fn apply(c: &mut Clip, p: &EffectPreset, ids: &mut SequentialIds) {
        c.apply_preset(p, ApplyMode::Absolute, None, ids);
    }

    #[test]
    fn capture_takes_animated_and_changed_motion_and_all_effects() {
        let mut ids = SequentialIds::default();
        let mut c = pop_in_clip(&mut ids, 4);
        c.animation.rotation = AnimatedProperty::new(15.0);
        let mut blur = effect(&mut ids, ClipEffect::GAUSSIAN_BLUR_KIND);
        blur.parameters.insert(ClipEffect::BLURRINESS_KEY.into(), AnimatedProperty::new(8.0));
        c.effects = vec![blur];
        let p = EffectPreset::capture(&c, Anchor::Start, None, None, None);
        let want: BTreeSet<_> = [MotionProperty::Scale, MotionProperty::Opacity, MotionProperty::Rotation].into();
        assert_eq!(p.motion_properties(), want);
        assert!(p.position.is_none() && p.anchor_point.is_none());
        assert!(p.effects.len() == 1 && p.effects[0].kind == ClipEffect::GAUSSIAN_BLUR_KIND);
        assert_eq!((p.reference_duration, p.anchor), (s(4), Anchor::Start));
        assert!(!p.is_empty());
        let plain = video(&mut ids, 3);
        assert!(EffectPreset::capture(&plain, Anchor::Start, None, None, None).is_empty());
    }

    #[test]
    fn capture_can_be_limited_to_chosen_properties_and_effects() {
        let mut ids = SequentialIds::default();
        let mut c = pop_in_clip(&mut ids, 4);
        let blur = effect(&mut ids, ClipEffect::GAUSSIAN_BLUR_KIND);
        c.effects = vec![blur.clone(), effect(&mut ids, ClipEffect::CROP_KIND)];
        let motion: BTreeSet<_> = [MotionProperty::Opacity].into();
        let chosen: BTreeSet<_> = [blur.id].into();
        let p = EffectPreset::capture(&c, Anchor::Start, Some(&motion), Some(&chosen), None);
        assert_eq!(p.motion_properties(), motion);
        assert_eq!(p.effects.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(), [ClipEffect::GAUSSIAN_BLUR_KIND]);
    }

    #[test]
    fn pop_in_lands_at_start_of_short_and_long_clips() {
        let mut ids = SequentialIds::default();
        let preset = EffectPreset::capture(&pop_in_clip(&mut ids, 4), Anchor::Start, None, None, None);
        for length in [2, 10] {
            let mut target = clip(&mut ids, length, s(7), TrackKind::Video);
            apply(&mut target, &preset, &mut ids);
            let (scale, opacity) = (&target.animation.scale.track.keys, &target.animation.opacity.track.keys);
            assert_eq!(scale.iter().map(|k| k.time).collect::<Vec<_>>(), [Time::ZERO, ms(500)]);
            assert_eq!(opacity.iter().map(|k| k.time).collect::<Vec<_>>(), [Time::ZERO, ms(500)]);
            assert_eq!(scale.iter().map(|k| k.value).collect::<Vec<_>>(), [Vec2::new(0.0, 0.0), Vec2::new(1.0, 1.0)]);
            assert_eq!(opacity.iter().map(|k| k.value).collect::<Vec<_>>(), [0.0, 1.0]);
            assert!(scale[0].out_handle == EASE_OUT && scale[1].in_handle == EASE_IN);
            assert_eq!(opacity[0].interpolation, Interpolation::Bezier);
            let src = pop_in_clip(&mut ids, 4);
            assert_eq!(target.animation.opacity.value_at_local(ms(200)), src.animation.opacity.value_at_local(ms(200)));
            assert_eq!(target.animation.opacity.value_at_local(s(1)), 1.0);
        }
    }

    #[test]
    fn apply_gives_fresh_key_ids_also_when_applied_twice() {
        let mut ids = SequentialIds::default();
        let source = pop_in_clip(&mut ids, 4);
        let mut target = video(&mut ids, 2);
        let preset = EffectPreset::capture(&source, Anchor::Start, None, None, None);
        apply(&mut target, &preset, &mut ids);
        let src_ids: BTreeSet<Id> = source.animation.scale.track.keys.iter().map(|k| k.id).collect();
        assert!(target.animation.scale.track.keys.iter().all(|k| !src_ids.contains(&k.id)));

        let mut src = video(&mut ids, 4);
        let mut blur = effect(&mut ids, ClipEffect::GAUSSIAN_BLUR_KIND);
        let mut p = AnimatedProperty::new(0.0);
        p.track = KeyframeTrack::with_keys(vec![key(&mut ids, Time::ZERO, 10.0), key(&mut ids, s(1), 0.0)]);
        blur.parameters.insert(ClipEffect::BLURRINESS_KEY.into(), p);
        src.effects = vec![blur.clone()];
        let preset = EffectPreset::capture(&src, Anchor::Start, None, None, None);
        let mut target = video(&mut ids, 2);
        apply(&mut target, &preset, &mut ids);
        apply(&mut target, &preset, &mut ids);
        let all: Vec<Id> = target
            .effects
            .iter()
            .flat_map(|e| e.parameters.values().flat_map(|p| p.track.keys.iter().map(|k| k.id)))
            .chain(blur.parameters.values().flat_map(|p| p.track.keys.iter().map(|k| k.id)))
            .collect();
        assert_eq!((all.len(), all.iter().collect::<BTreeSet<_>>().len()), (6, 6));
    }

    #[test]
    fn colour_and_point_keys_get_fresh_ids_and_are_remapped() {
        let mut ids = SequentialIds::default();
        let mut src = video(&mut ids, 4);
        let mut fx = effect(&mut ids, ClipEffect::DROP_SHADOW_KIND);
        let mut col = AnimatedProperty::new(EffectColor::BLACK);
        col.track = KeyframeTrack::with_keys(vec![
            key(&mut ids, s(3), EffectColor::BLACK),
            key(&mut ids, s(4), EffectColor::WHITE),
        ]);
        fx.colors.insert(ClipEffect::SHADOW_COLOR_KEY.into(), col);
        let mut pt = AnimatedProperty::new(Vec2::new(0.0, 0.0));
        pt.track = KeyframeTrack::with_keys(vec![
            key(&mut ids, s(3), Vec2::new(0.0, 0.0)),
            key(&mut ids, s(4), Vec2::new(10.0, 10.0)),
        ]);
        fx.points.insert("center".into(), pt);
        src.effects = vec![fx.clone()];
        let preset = EffectPreset::capture(&src, Anchor::End, None, None, None);
        let mut target = video(&mut ids, 10);
        apply(&mut target, &preset, &mut ids);
        apply(&mut target, &preset, &mut ids);
        let colour: Vec<_> =
            target.effects.iter().flat_map(|e| e.colors.values().flat_map(|p| p.track.keys.iter())).collect();
        let point: Vec<_> =
            target.effects.iter().flat_map(|e| e.points.values().flat_map(|p| p.track.keys.iter())).collect();
        let src_ids: BTreeSet<Id> = fx
            .colors
            .values()
            .flat_map(|p| p.track.keys.iter().map(|k| k.id))
            .chain(fx.points.values().flat_map(|p| p.track.keys.iter().map(|k| k.id)))
            .collect();
        let all: Vec<Id> = colour.iter().map(|k| k.id).chain(point.iter().map(|k| k.id)).collect();
        assert!(
            all.len() == 8
                && all.iter().collect::<BTreeSet<_>>().len() == 8
                && all.iter().all(|i| !src_ids.contains(i))
        );
        assert_eq!(colour.iter().map(|k| k.time).collect::<Vec<_>>(), [s(9), s(10), s(9), s(10)]);
        assert_eq!(point.iter().map(|k| k.time).collect::<Vec<_>>(), [s(9), s(10), s(9), s(10)]);
    }

    #[test]
    fn legacy_drop_shadow_preset_applies_with_its_colour() {
        let mut ids = SequentialIds::default();
        let mut legacy = effect(&mut ids, ClipEffect::DROP_SHADOW_KIND);
        for (k, v) in [
            (ClipEffect::SHADOW_RED_KEY, 255.0),
            (ClipEffect::SHADOW_GREEN_KEY, 51.0),
            (ClipEffect::SHADOW_BLUE_KEY, 0.0),
            (ClipEffect::SHADOW_OPACITY_KEY, 50.0),
        ] {
            legacy.parameters.insert(k.into(), AnimatedProperty::new(v));
        }
        let mut old = EffectPreset::new(Anchor::Start, s(4));
        old.effects = vec![legacy];
        let payload = old.payload().unwrap();
        let decoded = EffectPreset::from_payload(&payload, 1, &mut ids).unwrap();
        let mut target = video(&mut ids, 2);
        apply(&mut target, &decoded, &mut ids);
        let e = &target.effects[0];
        assert!(!e.parameters.contains_key(ClipEffect::SHADOW_RED_KEY));
        assert!(!e.parameters.contains_key(ClipEffect::SHADOW_GREEN_KEY));
        assert!(!e.parameters.contains_key(ClipEffect::SHADOW_BLUE_KEY));
        let c = e.colors.get(ClipEffect::SHADOW_COLOR_KEY).map(|p| p.value);
        assert_eq!(c, Some(EffectColor { red: 1.0, green: 0.2, blue: 0.0, alpha: 1.0 }));
        assert_eq!(e.parameters.get(ClipEffect::SHADOW_OPACITY_KEY).map(|p| p.value), Some(50.0));
    }

    #[test]
    fn apply_replaces_a_motion_property_but_leaves_others_and_appends_effects_with_new_ids() {
        let mut ids = SequentialIds::default();
        let mut target = video(&mut ids, 2);
        target.animation.position = AnimatedProperty::new(Vec2::new(10.0, 20.0));
        target.animation.scale = AnimatedProperty::new(Vec2::new(3.0, 3.0));
        let pop = pop_in_clip(&mut ids, 4);
        apply(&mut target, &EffectPreset::capture(&pop, Anchor::Start, None, None, None), &mut ids);
        assert_eq!(target.animation.position.value, Vec2::new(10.0, 20.0));
        assert_eq!(target.animation.scale.track.keys.len(), 2);

        let mut source = video(&mut ids, 4);
        let mut blur = effect(&mut ids, ClipEffect::GAUSSIAN_BLUR_KIND);
        let mut p = AnimatedProperty::new(0.0);
        p.track = KeyframeTrack::with_keys(vec![key(&mut ids, s(3), 0.0), key(&mut ids, s(4), 20.0)]);
        blur.parameters.insert(ClipEffect::BLURRINESS_KEY.into(), p);
        source.effects = vec![blur.clone()];
        let mut target = video(&mut ids, 10);
        target.effects = vec![effect(&mut ids, ClipEffect::CROP_KIND)];
        apply(&mut target, &EffectPreset::capture(&source, Anchor::End, None, None, None), &mut ids);
        assert_eq!(
            target.effects.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(),
            [ClipEffect::CROP_KIND, ClipEffect::GAUSSIAN_BLUR_KIND]
        );
        assert_ne!(target.effects[1].id, blur.id);
        let keys = target.effects[1].parameters.get(ClipEffect::BLURRINESS_KEY).map(times);
        assert_eq!(keys, Some(vec![s(9), s(10)]));
    }

    #[test]
    fn end_anchor_keeps_distance_to_clip_end_and_stretch_scales_exactly() {
        let mut ids = SequentialIds::default();
        let mut preset = EffectPreset::new(Anchor::End, s(4));
        let mut op = AnimatedProperty::new(1.0);
        op.track = KeyframeTrack::with_keys(vec![key(&mut ids, s(3), 1.0), key(&mut ids, s(4), 0.0)]);
        preset.opacity = Some(op);
        let mut a = video(&mut ids, 2);
        apply(&mut a, &preset, &mut ids);
        assert_eq!(times(&a.animation.opacity), [s(1), s(2)]);
        let mut b = video(&mut ids, 10);
        apply(&mut b, &preset, &mut ids);
        assert_eq!(times(&b.animation.opacity), [s(9), s(10)]);

        let mut stretch = EffectPreset::new(Anchor::Stretch, s(4));
        let mut rot = AnimatedProperty::new(0.0);
        rot.track = KeyframeTrack::with_keys(vec![
            key(&mut ids, Time::ZERO, 0.0),
            key(&mut ids, s(1), 90.0),
            key(&mut ids, s(4), 360.0),
        ]);
        stretch.rotation = Some(rot);
        let mut a = video(&mut ids, 2);
        apply(&mut a, &stretch, &mut ids);
        assert_eq!(times(&a.animation.rotation), [Time::ZERO, ms(500), s(2)]);
        let mut b = video(&mut ids, 10);
        apply(&mut b, &stretch, &mut ids);
        assert_eq!(times(&b.animation.rotation), [Time::ZERO, Time::new(5, 2), s(10)]);
        // NTSC-ish durations stay rational.
        let mut c = Clip::new(
            ids.next_id(),
            "c",
            ids.next_id(),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(1001 * 90, 30000)),
            Time::ZERO,
        );
        apply(&mut c, &stretch, &mut ids);
        assert_eq!(c.animation.rotation.track.keys.last().map(|k| k.time), Some(Time::new(1001 * 90, 30000)));
        assert_eq!(c.animation.rotation.track.keys[1].time, Time::new(1001 * 90, 120000));
    }

    #[test]
    fn map_time_helper() {
        assert_eq!(EffectPreset::map_time(s(1), Anchor::Stretch, s(3), s(1)), Time::new(1, 3));
        assert_eq!(EffectPreset::map_time(s(1), Anchor::Start, s(3), s(1)), s(1));
        assert_eq!(EffectPreset::map_time(s(1), Anchor::End, s(3), s(1)), s(-1));
        assert_eq!(EffectPreset::map_time(s(1), Anchor::Stretch, Time::ZERO, s(5)), s(1));
    }

    #[test]
    fn relative_mode_adds_position_and_multiplies_opacity() {
        let mut ids = SequentialIds::default();
        let mut p = EffectPreset::new(Anchor::Start, s(1));
        p.position = Some(AnimatedProperty::new(Vec2::new(100.0, 100.0)));
        p.opacity = Some(AnimatedProperty::new(0.5));
        let mut t = video(&mut ids, 4);
        t.animation.position = AnimatedProperty::new(Vec2::new(10.0, 10.0));
        t.animation.opacity = AnimatedProperty::new(0.8);
        t.apply_preset(&p, ApplyMode::Relative, None, &mut ids);
        assert_eq!(t.animation.position.value, Vec2::new(110.0, 110.0));
        assert_eq!(t.animation.opacity.value, 0.8 * 0.5);
    }

    #[test]
    fn relative_mode_with_keys_on_both_sides_keeps_a_key_at_every_time() {
        let mut ids = SequentialIds::default();
        let mut p = EffectPreset::new(Anchor::Start, s(4));
        let mut rot = AnimatedProperty::new(0.0);
        rot.track = KeyframeTrack::with_keys(vec![key(&mut ids, s(1), 10.0), key(&mut ids, s(2), 30.0)]);
        p.rotation = Some(rot);
        let mut t = video(&mut ids, 4);
        let mut own = AnimatedProperty::new(0.0);
        own.track = KeyframeTrack::with_keys(vec![key(&mut ids, s(0), 0.0), key(&mut ids, s(2), 100.0)]);
        t.animation.rotation = own;
        t.apply_preset(&p, ApplyMode::Relative, None, &mut ids);
        assert_eq!(times(&t.animation.rotation), [s(0), s(1), s(2)]);
        let v: Vec<f64> = t.animation.rotation.track.keys.iter().map(|k| k.value).collect();
        assert_eq!(v, [10.0, 60.0, 130.0]);
    }

    fn timeline(ids: &mut SequentialIds, tracks: Vec<Track>, w: i64, h: i64) -> Timeline {
        let mut f = SequenceFormat::new(Time::new(1, 30));
        f.width = w;
        f.height = h;
        Timeline::new(ids.next_id(), "t", f, tracks)
    }

    fn track_of(ids: &mut SequentialIds, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(ids.next_id(), kind);
        for c in clips {
            assert!(t.overwrite(c, ids).is_ok());
        }
        t
    }

    #[test]
    fn timeline_applies_to_clips_of_the_presets_kind_only() {
        let mut ids = SequentialIds::default();
        let a = video(&mut ids, 2);
        let b = clip(&mut ids, 10, s(2), TrackKind::Video);
        let sound = clip(&mut ids, 2, Time::ZERO, TrackKind::Audio);
        let (vt, at) = (
            track_of(&mut ids, TrackKind::Video, vec![a.clone(), b.clone()]),
            track_of(&mut ids, TrackKind::Audio, vec![sound.clone()]),
        );
        let mut tl = timeline(&mut ids, vec![vt, at], 1920, 1080);
        let pop = pop_in_clip(&mut ids, 4);
        let preset = EffectPreset::capture(&pop, Anchor::Start, None, None, None);
        let set: BTreeSet<Id> = [a.id, b.id, sound.id].into();
        assert_eq!(tl.apply_preset(&preset, &set, ApplyMode::Absolute, &mut ids), Ok(2));
        assert!(tl.tracks[0].clips().iter().all(|c| times(&c.animation.scale) == [Time::ZERO, ms(500)]));
        assert!(tl.tracks[1].clips()[0].animation.opacity.track.is_empty());
        let only_sound: BTreeSet<Id> = [sound.id].into();
        assert_eq!(
            tl.apply_preset(&preset, &only_sound, ApplyMode::Absolute, &mut ids),
            Err(EditError::WrongTrackKind)
        );
    }

    #[test]
    fn audio_only_preset_applies_to_audio_clips() {
        let mut ids = SequentialIds::default();
        let pic = video(&mut ids, 2);
        let sound = clip(&mut ids, 2, Time::ZERO, TrackKind::Audio);
        let (vt, at) = (
            track_of(&mut ids, TrackKind::Video, vec![pic.clone()]),
            track_of(&mut ids, TrackKind::Audio, vec![sound.clone()]),
        );
        let mut tl = timeline(&mut ids, vec![vt, at], 1920, 1080);
        let mut eq = ClipEffect::make(ids.next_id(), ClipEffect::AUDIO_PARAMETRIC_EQ_KIND).unwrap();
        let gain = ClipEffect::peq_key("b4", "Gain");
        eq.parameters.insert(gain.clone(), AnimatedProperty::new(1.0));
        let mut preset = EffectPreset::new(Anchor::Stretch, s(3));
        preset.effects = vec![eq.clone()];
        assert!(preset.is_audio_only());
        let pop = pop_in_clip(&mut ids, 4);
        assert!(!EffectPreset::capture(&pop, Anchor::Start, None, None, None).is_audio_only());
        let set: BTreeSet<Id> = [pic.id, sound.id].into();
        assert_eq!(tl.apply_preset(&preset, &set, ApplyMode::Absolute, &mut ids), Ok(1));
        let fx = &tl.tracks[1].clips()[0].effects;
        assert_eq!(fx.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(), [ClipEffect::AUDIO_PARAMETRIC_EQ_KIND]);
        assert_ne!(fx[0].id, eq.id);
        assert_eq!(fx[0].parameters.get(&gain).map(|p| p.value), Some(1.0));
        assert!(tl.tracks[0].clips()[0].effects.is_empty());
        let only_pic: BTreeSet<Id> = [pic.id].into();
        assert_eq!(tl.apply_preset(&preset, &only_pic, ApplyMode::Absolute, &mut ids), Err(EditError::WrongTrackKind));
    }

    #[test]
    fn payload_round_trips_is_additive_and_refuses_a_newer_version() {
        let mut ids = SequentialIds::default();
        let mut c = pop_in_clip(&mut ids, 4);
        let mut k0 = key(&mut ids, Time::ZERO, Vec2::new(0.1, -3.3));
        k0.out_tangent = Vec2::new(4.0, 5.0);
        c.animation.position.track = KeyframeTrack::with_keys(vec![k0, key(&mut ids, s(1), Vec2::new(7.0, 8.0))]);
        let mut blur = effect(&mut ids, ClipEffect::GAUSSIAN_BLUR_KIND);
        blur.parameters.insert(ClipEffect::BLURRINESS_KEY.into(), AnimatedProperty::new(0.3));
        c.effects = vec![blur];
        let p = EffectPreset::capture(&c, Anchor::Stretch, None, None, None);
        let bytes = p.payload().unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains("frameSize"));
        let back = EffectPreset::from_payload(&bytes, EffectPreset::PAYLOAD_VERSION, &mut ids).unwrap();
        assert_eq!(back, p);
        let sized = EffectPreset::capture(&c, Anchor::Start, None, None, Some(Vec2::new(1080.0, 1920.0)));
        let back = EffectPreset::from_payload(&sized.payload().unwrap(), 1, &mut ids).unwrap();
        assert!(back == sized && back.frame_size == Some(Vec2::new(1080.0, 1920.0)));
        let newer = EffectPreset::from_payload(&bytes, 99, &mut ids);
        assert!(matches!(
            newer,
            Err(PayloadReadError::Version(PayloadError::NewerVersion { found: 99, supported: 1 }))
        ));
    }

    // C7: frame size

    const PORTRAIT: Vec2 = Vec2 { x: 1080.0, y: 1920.0 };
    const UHD: Vec2 = Vec2 { x: 3840.0, y: 2160.0 };

    fn near(a: Vec2, b: Vec2) -> bool {
        (a.x - b.x).abs() <= 1e-9 && (a.y - b.y).abs() <= 1e-9
    }

    /// Position keyed with a spatial tangent, a static anchor offset and a Radial Blur center point.
    fn source_clip(ids: &mut SequentialIds) -> Clip {
        let mut c = video(ids, 4);
        let mut k0 = key(ids, Time::ZERO, Vec2::new(-300.0, 600.0));
        k0.out_tangent = Vec2::new(108.0, -192.0);
        let mut k1 = key(ids, s(1), Vec2::new(270.0, -480.0));
        k1.in_tangent = Vec2::new(-54.0, 96.0);
        c.animation.position.track = KeyframeTrack::with_keys(vec![k0, k1]);
        c.animation.anchor = AnimatedProperty::new(Vec2::new(54.0, 96.0));
        c.animation.scale = AnimatedProperty::new(Vec2::new(1.5, 1.5));
        let mut fx = effect(ids, ClipEffect::RADIAL_BLUR_KIND);
        fx.points.insert(ClipEffect::RADIAL_CENTER_KEY.into(), AnimatedProperty::new(Vec2::new(-108.0, 192.0)));
        fx.parameters.insert(ClipEffect::RADIAL_AMOUNT_KEY.into(), AnimatedProperty::new(40.0));
        c.effects = vec![fx];
        c
    }

    fn with_size(c: &Clip, size: Vec2) -> EffectPreset {
        EffectPreset::capture(c, Anchor::Start, None, None, Some(size))
    }

    #[test]
    fn spatial_values_scale_to_the_target_frame() {
        let mut ids = SequentialIds::default();
        let p = with_size(&source_clip(&mut ids), PORTRAIT);
        let mut t = video(&mut ids, 4);
        t.apply_preset(&p, ApplyMode::Absolute, Some(UHD), &mut ids);
        let k = 3840.0 / 1080.0;
        assert_eq!(p.spatial_scale(Some(UHD)), Some(k));
        let keys = &t.animation.position.track.keys;
        assert!(near(keys[0].value, Vec2::new(-300.0 * k, 600.0 * k)));
        assert!(near(keys[1].value, Vec2::new(270.0 * k, -480.0 * k)));
        assert!(near(keys[0].out_tangent, Vec2::new(108.0 * k, -192.0 * k)));
        assert!(near(keys[1].in_tangent, Vec2::new(-54.0 * k, 96.0 * k)));
        assert_eq!(t.animation.anchor.value, Vec2::new(54.0, 96.0));
        assert_eq!(t.animation.scale.value, Vec2::new(1.5, 1.5));
        assert_eq!(t.effects[0].parameters.get(ClipEffect::RADIAL_AMOUNT_KEY).map(|p| p.value), Some(40.0));
        assert_eq!(
            t.effects[0].points.get(ClipEffect::RADIAL_CENTER_KEY).map(|p| p.value),
            Some(Vec2::new(-108.0, 192.0))
        );
    }

    #[test]
    fn capture_records_the_frame_size_and_the_factor_is_uniform() {
        let mut ids = SequentialIds::default();
        let src = source_clip(&mut ids);
        assert_eq!(with_size(&src, PORTRAIT).frame_size, Some(PORTRAIT));
        assert_eq!(EffectPreset::capture(&src, Anchor::Start, None, None, None).frame_size, None);
        let mut circle = video(&mut ids, 4);
        circle.animation.position.track = KeyframeTrack::with_keys(vec![
            key(&mut ids, Time::ZERO, Vec2::new(100.0, 0.0)),
            key(&mut ids, s(1), Vec2::new(0.0, 100.0)),
        ]);
        let mut t = video(&mut ids, 4);
        t.apply_preset(&with_size(&circle, Vec2::new(1920.0, 1080.0)), ApplyMode::Absolute, Some(PORTRAIT), &mut ids);
        let v: Vec<Vec2> = t.animation.position.track.keys.iter().map(|k| k.value).collect();
        assert!((v[0].x - v[1].y).abs() < 1e-9);
    }

    #[test]
    fn group_transform_scales_position_and_anchor_only() {
        let mut ids = SequentialIds::default();
        let mut src = video(&mut ids, 4);
        let mut g = effect(&mut ids, ClipEffect::GROUP_TRANSFORM_KIND);
        g.points.insert(ClipEffect::GROUP_SCALE_KEY.into(), AnimatedProperty::new(Vec2::new(1.0, 1.0)));
        g.points.insert(ClipEffect::GROUP_POSITION_KEY.into(), AnimatedProperty::new(Vec2::new(100.0, 50.0)));
        g.points.insert(ClipEffect::GROUP_ANCHOR_KEY.into(), AnimatedProperty::new(Vec2::new(10.0, 20.0)));
        let group_scale = g.points.get(ClipEffect::GROUP_SCALE_KEY).cloned();
        let mut tw = effect(&mut ids, ClipEffect::TWIRL_KIND);
        tw.points.insert(ClipEffect::TWIRL_CENTER_KEY.into(), AnimatedProperty::new(Vec2::new(30.0, 40.0)));
        src.effects = vec![g, tw];
        let mut t = video(&mut ids, 4);
        t.apply_preset(&with_size(&src, Vec2::new(1920.0, 1080.0)), ApplyMode::Absolute, Some(PORTRAIT), &mut ids);
        let k = (1080.0_f64 / 1920.0).max(1920.0 / 1080.0);
        let at = |i: usize, key: &str| t.effects[i].points.get(key).map(|p| p.value).unwrap_or(Vec2::ZERO);
        assert!(near(at(0, ClipEffect::GROUP_POSITION_KEY), Vec2::new(100.0 * k, 50.0 * k)));
        assert!(near(at(0, ClipEffect::GROUP_ANCHOR_KEY), Vec2::new(10.0 * k, 20.0 * k)));
        assert_eq!(t.effects[0].points.get(ClipEffect::GROUP_SCALE_KEY), group_scale.as_ref());
        assert_eq!(at(1, ClipEffect::TWIRL_CENTER_KEY), Vec2::new(30.0, 40.0));
    }

    #[test]
    fn text_clip_scales_per_axis_like_change_format() {
        let mut ids = SequentialIds::default();
        let mut src = video(&mut ids, 4);
        src.generator = Some(GeneratorRef { kind: TEXT_KIND.into(), payload: b"t".to_vec(), payload_version: 1 });
        src.animation.position = AnimatedProperty::new(Vec2::new(-700.0, 380.0));
        let mut g = effect(&mut ids, ClipEffect::GROUP_TRANSFORM_KIND);
        g.points.insert(ClipEffect::GROUP_POSITION_KEY.into(), AnimatedProperty::new(Vec2::new(100.0, 50.0)));
        g.points.insert(ClipEffect::GROUP_ANCHOR_KEY.into(), AnimatedProperty::new(Vec2::new(10.0, 20.0)));
        src.effects = vec![g];
        let mut wide = SequenceFormat::new(Time::new(1, 25));
        wide.width = 1920;
        wide.height = 1080;
        let mut tall = wide.clone();
        tall.width = 1080;
        tall.height = 1920;
        let expected = SequenceConform::conform_text(&src, &wide, &tall, None);
        let mut t = src.clone();
        t.animation = ClipAnimation::default();
        t.effects = Vec::new();
        t.apply_preset(&with_size(&src, Vec2::new(1920.0, 1080.0)), ApplyMode::Absolute, Some(PORTRAIT), &mut ids);
        assert!(near(t.animation.position.value, expected.animation.position.value));
        for key in [ClipEffect::GROUP_POSITION_KEY, ClipEffect::GROUP_ANCHOR_KEY] {
            let (a, b) = (t.effects[0].points.get(key), expected.effects[0].points.get(key));
            assert!(near(a.map_or(Vec2::ZERO, |p| p.value), b.map_or(Vec2::ZERO, |p| p.value)));
        }
        let mut v = video(&mut ids, 4);
        v.apply_preset(&with_size(&src, Vec2::new(1920.0, 1080.0)), ApplyMode::Absolute, Some(PORTRAIT), &mut ids);
        let k = 1920.0 / 1080.0;
        assert!(near(v.animation.position.value, Vec2::new(-700.0 * k, 380.0 * k)));
    }

    #[test]
    fn hd_to_uhd_and_back_gives_the_original_and_unknown_sizes_keep_values() {
        let mut ids = SequentialIds::default();
        let src = source_clip(&mut ids);
        let hd = Vec2::new(1920.0, 1080.0);
        let mut big = video(&mut ids, 4);
        big.apply_preset(&with_size(&src, hd), ApplyMode::Absolute, Some(UHD), &mut ids);
        assert!(near(big.animation.position.track.keys[0].value, Vec2::new(-600.0, 1200.0)));
        let mut back = video(&mut ids, 4);
        back.apply_preset(&with_size(&big, UHD), ApplyMode::Absolute, Some(hd), &mut ids);
        for (a, b) in back.animation.position.track.keys.iter().zip(&src.animation.position.track.keys) {
            assert!(near(a.value, b.value) && near(a.in_tangent, b.in_tangent) && near(a.out_tangent, b.out_tangent));
        }
        assert_eq!(back.animation.anchor.value, src.animation.anchor.value);

        let want: Vec<Vec2> = src.animation.position.track.keys.iter().map(|k| k.value).collect();
        let got = |preset: &EffectPreset, target: Option<Vec2>, ids: &mut SequentialIds| {
            let mut t = video(ids, 4);
            t.apply_preset(preset, ApplyMode::Absolute, target, ids);
            t.animation.position.track.keys.iter().map(|k| k.value).collect::<Vec<_>>()
        };
        assert_eq!(got(&with_size(&src, PORTRAIT), Some(PORTRAIT), &mut ids), want);
        assert_eq!(got(&with_size(&src, PORTRAIT), None, &mut ids), want);
        assert_eq!(got(&EffectPreset::capture(&src, Anchor::Start, None, None, None), Some(UHD), &mut ids), want);
        assert_eq!(got(&with_size(&src, Vec2::new(0.0, 1920.0)), Some(UHD), &mut ids), want);
    }

    #[test]
    fn relative_mode_scales_the_presets_offset_and_the_timeline_uses_its_own_format() {
        let mut ids = SequentialIds::default();
        let mut p = EffectPreset::new(Anchor::Start, s(1));
        p.position = Some(AnimatedProperty::new(Vec2::new(100.0, 100.0)));
        p.frame_size = Some(PORTRAIT);
        let mut t = video(&mut ids, 4);
        t.animation.position = AnimatedProperty::new(Vec2::new(10.0, 10.0));
        t.apply_preset(&p, ApplyMode::Relative, Some(UHD), &mut ids);
        assert!(near(
            t.animation.position.value,
            Vec2::new(10.0 + 100.0 * 3840.0 / 1080.0, 10.0 + 100.0 * 3840.0 / 1080.0)
        ));

        let c = video(&mut ids, 4);
        let track = track_of(&mut ids, TrackKind::Video, vec![c.clone()]);
        let mut tl = timeline(&mut ids, vec![track], 3840, 2160);
        let src = source_clip(&mut ids);
        let set: BTreeSet<Id> = [c.id].into();
        assert!(tl.apply_preset(&with_size(&src, PORTRAIT), &set, ApplyMode::Absolute, &mut ids).is_ok());
        let got = tl.tracks[0].clips()[0].animation.position.track.keys[0].value;
        assert!(near(got, Vec2::new(-300.0 * 3840.0 / 1080.0, 600.0 * 3840.0 / 1080.0)));
    }
}
