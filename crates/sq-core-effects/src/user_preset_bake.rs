// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: UserPresetBake.swift (Convert to Keyframes / Re-open as Effect)

//! W7.5 user presets that bake. Built-in effects stay live; a user can still turn one Transform-stage effect into plain
//! Motion keys ("Convert to Keyframes"). The clip remembers what was baked (recipe = the effect kind, plus the effect with
//! all its parameters and the Motion it was baked onto), so "Re-open as Effect" gives the live effect back.
//!
//! Bake: the stage is composed onto Motion at every frame of the clip (`render_transform`), so each frame renders as
//! before; per-frame keys are then thinned to the ones a linear curve needs (a linear move keeps two keys). Only the last
//! enabled stage can be baked. Refused as well: an open Shutter Angle, text generators, and a format variant that
//! overrides Motion or this effect. Records stack: only the newest can be re-opened.

use crate::effect_transform_stage::ClipEffectStage as _;
use crate::effect_transform_stage::ClipStageEval as _;
use sq_core_masks::AnonymizeOrderExt as _;
use sq_core_model::{AnimatedProperty, BakedEffect, Clip, ClipEffect, EditError, Timeline};
use sq_core_time::{Id, IdSource, Keyframe, KeyframeTrack, KeyframeValue, Time, Vec2};

/// `GeneratorRef.text`.
const TEXT_GENERATOR: &str = "text";

/// Why a bake edit was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BakeError {
    /// Not a Transform-stage effect, disabled, followed by another stage, overridden by a format variant, or the clip's
    /// Motion / Opacity is switched off.
    NotConvertible,
    /// The baked record is not on the clip.
    RecordNotFound,
    /// Re-open on a record that is not the newest (`can_reopen_as_effect`).
    NotNewest,
}

impl BakeError {
    /// The message the session shows.
    pub fn message(self) -> &'static str {
        match self {
            BakeError::NotConvertible => {
                "This effect cannot be converted to keyframes (it must be the last enabled transform effect, with Motion on, and no format variant or open shutter)."
            }
            BakeError::RecordNotFound => "There is nothing to re-open.",
            BakeError::NotNewest => "Only the most recent conversion can be re-opened.",
        }
    }
}

/// Why a timeline-level bake edit failed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BakeFailure {
    /// `ClipNotFound` or `TrackLocked`.
    Edit(EditError),
    /// The clip refused.
    Bake(BakeError),
}

impl From<EditError> for BakeFailure {
    fn from(e: EditError) -> Self {
        BakeFailure::Edit(e)
    }
}

impl From<BakeError> for BakeFailure {
    fn from(e: BakeError) -> Self {
        BakeFailure::Bake(e)
    }
}

/// `extension Clip` of UserPresetBake.swift.
pub trait ClipBakeExt {
    /// Effects baked into Motion, newest last.
    fn baked_effects(&self) -> &[BakedEffect];
    /// Replaces the baked records; an empty list stores nothing.
    fn set_baked_effects(&mut self, records: Vec<BakedEffect>);
    /// Whether Convert to Keyframes is offered for the effect `id`.
    fn can_convert_to_keyframes(&self, id: Id) -> bool;
    /// Only the newest record can be re-opened: an older bake lies underneath the newer one's keys.
    fn can_reopen_as_effect(&self, record: Id) -> bool;
    /// Bakes the effect `id` into Motion keys sampled every `frame_duration`, removes it and records it.
    fn convert_to_keyframes(
        &mut self,
        id: Id,
        frame_duration: Time,
        frame: Vec2,
        ids: &mut dyn IdSource,
    ) -> Result<(), BakeError>;
    /// Puts the baked effect `record` back where it was and restores the Motion it was baked onto.
    fn reopen_as_effect(&mut self, record: Id, ids: &mut dyn IdSource) -> Result<(), BakeError>;
}

impl ClipBakeExt for Clip {
    fn baked_effects(&self) -> &[BakedEffect] {
        self.baked_store.as_deref().unwrap_or(&[])
    }

    fn set_baked_effects(&mut self, records: Vec<BakedEffect>) {
        self.baked_store = (!records.is_empty()).then_some(records);
    }

    fn can_convert_to_keyframes(&self, id: Id) -> bool {
        if !self.motion_enabled || !self.opacity_enabled {
            return false;
        }
        let Some(i) = self.effects.iter().position(|e| e.id == id) else { return false };
        let e = &self.effects[i];
        if !e.enabled || !e.is_transform_stage() {
            return false;
        }
        if self.effects[i + 1..].iter().any(|o| o.enabled && o.is_transform_stage()) {
            return false;
        }
        // A variant's own Motion replaces the baked keys wholesale: the stage would vanish there.
        if self.variant_store.as_ref().is_some_and(|v| {
            v.items.values().any(|o| {
                o.effect_parameters.contains_key(&id)
                    || o.position.is_some()
                    || o.scale.is_some()
                    || o.rotation.is_some()
                    || o.anchor.is_some()
            })
        }) {
            return false;
        }
        // Text conform scales Position per axis, which a baked R·S·offset does not survive when the axes differ.
        if self.generator.as_ref().is_some_and(|g| g.kind == TEXT_GENERATOR) {
            return false;
        }
        // An open shutter blurs the picture; Motion has no shutter, so the bake would change the render.
        if let Some(sh) = e.parameters.get(ClipEffect::STAGE_SHUTTER_ANGLE_KEY)
            && (sh.value > 0.0 || sh.track.keys.iter().any(|k| k.value > 0.0))
        {
            return false;
        }
        true
    }

    fn can_reopen_as_effect(&self, record: Id) -> bool {
        self.baked_effects().last().is_some_and(|b| b.id == record)
    }

    fn convert_to_keyframes(&mut self, id: Id, fd: Time, frame: Vec2, ids: &mut dyn IdSource) -> Result<(), BakeError> {
        if fd <= Time::ZERO || !self.can_convert_to_keyframes(id) {
            return Err(BakeError::NotConvertible);
        }
        let i = self.effects.iter().position(|e| e.id == id).ok_or(BakeError::NotConvertible)?;
        let fx = self.effects[i].clone();
        let mut single = self.clone();
        single.effects = vec![fx.clone()];
        let a = &self.animation;
        let animated = a.position.is_animated()
            || a.scale.is_animated()
            || a.rotation.is_animated()
            || a.opacity.is_animated()
            || a.anchor.is_animated()
            || fx.parameters.values().any(|p| p.is_animated())
            || fx.is_motion_preset(); // motion effects animate without keys (their curve runs over the clip time)
        let mut times = vec![Time::ZERO];
        if animated {
            let mut t = fd;
            while t < self.duration() {
                times.push(t);
                t += fd;
            }
        }
        let samples: Vec<_> = times.iter().map(|t| single.render_transform(self.start + *t, frame)).collect();
        let mut records = self.baked_effects().to_vec();
        records.push(BakedEffect {
            id: ids.next_id(),
            recipe_id: fx.kind.clone(),
            effect: fx,
            index: i as i64,
            motion: self.animation.clone(),
        });
        self.set_baked_effects(records);
        let vec2 = |f: fn(&sq_core_model::ClipTransform) -> Vec2| -> Vec<Vec2> { samples.iter().map(f).collect() };
        self.animation.position = baked_vec2(&times, &vec2(|s| s.position), ids);
        self.animation.scale = baked_vec2(&times, &vec2(|s| s.scale), ids);
        self.animation.rotation = baked_f64(&times, &samples.iter().map(|s| s.rotation).collect::<Vec<_>>(), ids);
        self.animation.opacity = baked_f64(&times, &samples.iter().map(|s| s.opacity).collect::<Vec<_>>(), ids);
        self.effects.remove(i);
        Ok(())
    }

    fn reopen_as_effect(&mut self, record: Id, ids: &mut dyn IdSource) -> Result<(), BakeError> {
        let r = self.baked_effects().iter().find(|b| b.id == record).cloned().ok_or(BakeError::RecordNotFound)?;
        if !self.can_reopen_as_effect(record) {
            return Err(BakeError::NotNewest);
        }
        let mut fx = r.effect;
        if self.effects.iter().any(|e| e.id == fx.id) {
            fx.id = ids.next_id();
        }
        let volume = self.animation.volume.clone();
        self.animation = r.motion;
        self.animation.volume = volume;
        let at = usize::try_from(r.index.max(0)).unwrap_or(0).min(self.effects.len());
        self.effects.insert(at, fx);
        self.pin_covers();
        let rest: Vec<BakedEffect> = self.baked_effects().iter().filter(|b| b.id != record).cloned().collect();
        self.set_baked_effects(rest);
        Ok(())
    }
}

/// `extension Timeline` of UserPresetBake.swift.
pub trait TimelineBakeExt {
    /// Whether Convert to Keyframes is offered for the effect `effect` of clip `clip` (never for a transition).
    fn can_convert_to_keyframes(&self, effect: Id, clip: Id) -> bool;
    /// Whether the baked record `record` of `clip` can be re-opened.
    fn can_reopen_as_effect(&self, record: Id, clip: Id) -> bool;
    /// Convert to Keyframes at the sequence's frame rate. Fails with `ClipNotFound`, `TrackLocked`, `BakeError`.
    fn convert_to_keyframes(&mut self, effect: Id, clip: Id, ids: &mut dyn IdSource) -> Result<(), BakeFailure>;
    /// Re-open as Effect. Fails with `ClipNotFound`, `TrackLocked`, `RecordNotFound` / `NotNewest`.
    fn reopen_as_effect(&mut self, record: Id, clip: Id, ids: &mut dyn IdSource) -> Result<(), BakeFailure>;
}

impl TimelineBakeExt for Timeline {
    fn can_convert_to_keyframes(&self, effect: Id, clip: Id) -> bool {
        self.find(clip).is_some_and(|m| m.clip.can_convert_to_keyframes(effect))
    }

    fn can_reopen_as_effect(&self, record: Id, clip: Id) -> bool {
        self.find(clip).is_some_and(|m| m.clip.can_reopen_as_effect(record))
    }

    fn convert_to_keyframes(&mut self, effect: Id, clip: Id, ids: &mut dyn IdSource) -> Result<(), BakeFailure> {
        let fd = self.frame_duration();
        let frame = Vec2 { x: self.format.display_width() as f64, y: self.format.height as f64 };
        edit_baked(self, clip, |c| c.convert_to_keyframes(effect, fd, frame, ids))
    }

    fn reopen_as_effect(&mut self, record: Id, clip: Id, ids: &mut dyn IdSource) -> Result<(), BakeFailure> {
        edit_baked(self, clip, |c| c.reopen_as_effect(record, ids))
    }
}

fn edit_baked(
    tl: &mut Timeline,
    id: Id,
    body: impl FnOnce(&mut Clip) -> Result<(), BakeError>,
) -> Result<(), BakeFailure> {
    let m = tl.find(id).ok_or(EditError::ClipNotFound)?;
    if tl.tracks[m.track].is_locked {
        return Err(EditError::TrackLocked.into());
    }
    let mut c = m.clip;
    body(&mut c)?;
    tl.tracks[m.track].replace(c);
    Ok(())
}

// MARK: Thinning

/// A property from per-frame samples: static when every sample is the same, else linear keys where the curve bends.
fn baked_f64(times: &[Time], v: &[f64], ids: &mut dyn IdSource) -> AnimatedProperty<f64> {
    let keep = thinned(v.len(), |i, a, b| near(v[i], lerp(v[a], v[b], i, a, b)));
    property(times, v, &keep, ids)
}

fn baked_vec2(times: &[Time], v: &[Vec2], ids: &mut dyn IdSource) -> AnimatedProperty<Vec2> {
    let keep = thinned(v.len(), |i, a, b| {
        near(v[i].x, lerp(v[a].x, v[b].x, i, a, b)) && near(v[i].y, lerp(v[a].y, v[b].y, i, a, b))
    });
    property(times, v, &keep, ids)
}

fn property<V: KeyframeValue>(times: &[Time], v: &[V], keep: &[usize], ids: &mut dyn IdSource) -> AnimatedProperty<V> {
    if keep.len() <= 1 {
        return AnimatedProperty::new(v[keep.first().copied().unwrap_or(0)].clone());
    }
    let keys = keep.iter().map(|&k| Keyframe::new(ids.next_id(), times[k], v[k].clone())).collect();
    AnimatedProperty { value: v[keep[0]].clone(), track: KeyframeTrack::with_keys(keys) }
}

/// Indices to keep: interior samples that lie on the line between their kept neighbors go, and so do flat runs at either
/// end (a track holds its first value before the first key and its last after the last).
/// `on_line(i, a, b)`: sample i lies on the line from sample a to sample b.
fn thinned(n: usize, on_line: impl Fn(usize, usize, usize) -> bool) -> Vec<usize> {
    if n <= 1 {
        return vec![0];
    }
    let mut keep = vec![0];
    for i in 1..n - 1 {
        let a = keep[keep.len() - 1];
        // Drop i when every sample from a to i + 1 is on the line a -> i + 1.
        if !(a + 1..=i).all(|j| on_line(j, a, i + 1)) {
            keep.push(i);
        }
    }
    keep.push(n - 1);
    // Flat ends: the hold before the first key and after the last key already give those values.
    let flat = |p: usize, q: usize| on_line(p, q, q);
    while keep.len() > 1 && flat(keep[keep.len() - 1], keep[keep.len() - 2]) {
        keep.pop();
    }
    while keep.len() > 1 && flat(keep[0], keep[1]) {
        keep.remove(0);
    }
    keep
}

fn lerp(va: f64, vb: f64, i: usize, a: usize, b: usize) -> f64 {
    if b == a { vb } else { va + (vb - va) * (i as f64 - a as f64) / (b as f64 - a as f64) }
}

fn near(x: f64, y: f64) -> bool {
    (x - y).abs() <= 1e-9 * 1.0_f64.max(x.abs()).max(y.abs())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{ClipTransform, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn fd() -> Time {
        Time::new(1, 30)
    }

    const FRAME: Vec2 = Vec2 { x: 1920.0, y: 1080.0 };

    fn clip() -> Clip {
        Clip::new(
            Id::from_u128(1),
            "c",
            Id::from_u128(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, s(2)),
            Time::ZERO,
        )
    }

    fn transform(id: u128, params: &[(&str, AnimatedProperty<f64>)]) -> ClipEffect {
        let mut e = ClipEffect::make(Id::from_u128(id), ClipEffect::TRANSFORM_KIND).unwrap();
        for (k, v) in params {
            e.parameters.insert(k.to_string(), v.clone());
        }
        e
    }

    fn linear(pairs: &[(Time, f64)]) -> AnimatedProperty<f64> {
        let mut ids = SequentialIds::default();
        let keys = pairs.iter().map(|(t, v)| Keyframe::new(ids.next_id(), *t, *v)).collect();
        AnimatedProperty { value: pairs[0].1, track: KeyframeTrack::with_keys(keys) }
    }

    fn close(a: &ClipTransform, b: &ClipTransform) -> bool {
        let e = 1e-6;
        (a.position.x - b.position.x).abs() < e
            && (a.position.y - b.position.y).abs() < e
            && (a.scale.x - b.scale.x).abs() < e
            && (a.scale.y - b.scale.y).abs() < e
            && (a.rotation - b.rotation).abs() < e
            && (a.opacity - b.opacity).abs() < e
            && (a.anchor.x - b.anchor.x).abs() < e
            && (a.anchor.y - b.anchor.y).abs() < e
    }

    /// Every frame of the clip renders the same.
    fn same_render(a: &Clip, b: &Clip) -> bool {
        let mut t = a.start;
        while t < a.start + a.duration() {
            if !close(&a.render_transform(t, FRAME), &b.render_transform(t, FRAME)) {
                return false;
            }
            t += fd();
        }
        true
    }

    /// Ids that never repeat across several edits of one test.
    struct Counter(u128);

    impl IdSource for Counter {
        fn next_id(&mut self) -> Id {
            self.0 += 1;
            Id::from_u128(self.0)
        }
    }

    fn convert(c: &mut Clip, id: Id) -> Result<(), BakeError> {
        let next = 5000 + c.baked_effects().len() as u128 * 1000;
        c.convert_to_keyframes(id, fd(), FRAME, &mut Counter(next))
    }

    #[test]
    fn convert_static_stage_bakes_into_motion() {
        let mut c = clip();
        c.animation.scale = AnimatedProperty::new(Vec2 { x: 1.2, y: 1.2 });
        let fx = transform(10, &[(ClipEffect::STAGE_SCALE_KEY, AnimatedProperty::new(110.0))]);
        c.effects = vec![fx.clone()];
        let before = c.clone();
        convert(&mut c, fx.id).unwrap();
        assert!(c.effects.is_empty());
        assert!((c.animation.scale.value.x - 1.32).abs() < 1e-9);
        assert!(!c.animation.scale.is_animated());
        assert!(same_render(&before, &c));
        assert_eq!(c.baked_effects().len(), 1);
        assert_eq!(c.baked_effects()[0].recipe_id, ClipEffect::TRANSFORM_KIND);
        assert_eq!(c.baked_effects()[0].effect, fx);
    }

    #[test]
    fn convert_animated_stage_matches_every_frame_with_few_keys() {
        let mut c = clip();
        c.animation.position = AnimatedProperty::new(Vec2 { x: 20.0, y: 0.0 });
        let fx = transform(10, &[(ClipEffect::STAGE_POSITION_X_KEY, linear(&[(Time::ZERO, 0.0), (s(1), 100.0)]))]);
        c.effects = vec![fx.clone()];
        let before = c.clone();
        convert(&mut c, fx.id).unwrap();
        assert!(same_render(&before, &c));
        // A linear move needs no per-frame keys: start, end of the move, nothing redundant.
        assert_eq!(c.animation.position.track.keys.len(), 2);
        assert!(!c.animation.scale.is_animated() && !c.animation.rotation.is_animated());
    }

    #[test]
    fn reopen_as_effect_restores_the_parameters_and_motion() {
        let mut c = clip();
        let blur = ClipEffect::make(Id::from_u128(11), "gaussianBlur").unwrap();
        let fx = transform(
            10,
            &[
                (ClipEffect::STAGE_POSITION_X_KEY, linear(&[(Time::ZERO, 0.0), (s(1), 100.0)])),
                (ClipEffect::STAGE_OPACITY_KEY, AnimatedProperty::new(80.0)),
            ],
        );
        c.effects = vec![fx.clone(), blur.clone()];
        c.animation.scale = AnimatedProperty::new(Vec2 { x: 1.2, y: 1.2 });
        let before = c.clone();
        convert(&mut c, fx.id).unwrap();
        assert_eq!(c.effects, vec![blur]);
        let rec = c.baked_effects()[0].id;
        c.reopen_as_effect(rec, &mut SequentialIds::default()).unwrap();
        assert_eq!(c.effects, before.effects);
        assert_eq!(c.animation, before.animation);
        assert!(c.baked_effects().is_empty());
    }

    #[test]
    fn convert_refuses_effects_without_transform_stage_and_earlier_stages() {
        let mut c = clip();
        let blur = ClipEffect::make(Id::from_u128(11), "gaussianBlur").unwrap();
        c.effects = vec![blur.clone()];
        assert!(!c.can_convert_to_keyframes(blur.id));
        assert_eq!(convert(&mut c, blur.id), Err(BakeError::NotConvertible));
        let (a, b) = (transform(20, &[]), transform(21, &[]));
        c.effects = vec![a.clone(), b.clone()];
        assert!(!c.can_convert_to_keyframes(a.id) && c.can_convert_to_keyframes(b.id));
    }

    #[test]
    fn only_the_newest_record_can_be_reopened() {
        let mut c = clip();
        let (a, b) =
            (transform(20, &[(ClipEffect::STAGE_SCALE_KEY, AnimatedProperty::new(110.0))]), transform(21, &[]));
        c.effects = vec![a.clone(), b.clone()];
        convert(&mut c, b.id).unwrap();
        convert(&mut c, a.id).unwrap();
        let (old, new) = (c.baked_effects()[0].id, c.baked_effects()[1].id);
        assert!(!c.can_reopen_as_effect(old) && c.can_reopen_as_effect(new));
        assert_eq!(c.reopen_as_effect(old, &mut SequentialIds::default()), Err(BakeError::NotNewest));
        assert_eq!(
            c.reopen_as_effect(Id::from_u128(99), &mut SequentialIds::default()),
            Err(BakeError::RecordNotFound)
        );
    }
}
