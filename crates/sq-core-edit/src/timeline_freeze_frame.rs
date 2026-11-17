// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+FreezeFrame.swift (Frame Hold)

use sq_core_color::ClipEffectColorExt as _;
use sq_core_masks::ClipMasksExt as _;
use sq_core_model::{
    AnimatedProperty, BakedEffect, Clip, ClipAnimation, EditError, Member, Timeline, TrackKind, VariantOverride,
};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeMap;

/// The animated values of `v` replaced by their value at clip-local `t` (an inserted frame hold is a pause in time).
// shortcut: belongs to `VariantOverride` (FormatVariants.swift `frozen(atLocal:)`) in sq-core-model; move it there with the
// rest of that file's logic.
fn frozen_variant(v: &VariantOverride, t: Time) -> VariantOverride {
    fn fz<V: sq_core_time::KeyframeValue>(p: &Option<AnimatedProperty<V>>, t: Time) -> Option<AnimatedProperty<V>> {
        p.as_ref().map(|p| AnimatedProperty::new(p.value_at_local(t)))
    }
    let mut o = v.clone();
    o.position = fz(&v.position, t);
    o.scale = fz(&v.scale, t);
    o.rotation = fz(&v.rotation, t);
    o.anchor = fz(&v.anchor, t);
    o.tilt_x = fz(&v.tilt_x, t);
    o.tilt_y = fz(&v.tilt_y, t);
    o.effect_parameters = v
        .effect_parameters
        .iter()
        .map(|(k, m)| (*k, m.iter().map(|(n, p)| (n.clone(), AnimatedProperty::new(p.value_at_local(t)))).collect()))
        .collect();
    o
}

/// Every key of a baked effect frozen at clip-local `t` (an inserted frame hold).
// shortcut: belongs to `BakedEffect` (UserPresetBake.swift `frozen(atLocal:)`) in sq-core-model; move it there with the
// rest of that file's logic.
fn frozen_baked(b: &BakedEffect, t: Time) -> BakedEffect {
    let mut out = b.clone();
    out.effect = b.effect.frozen_at_local(t);
    let m = &b.motion;
    out.motion.position = AnimatedProperty::new(m.position.value_at_local(t));
    out.motion.scale = AnimatedProperty::new(m.scale.value_at_local(t));
    out.motion.rotation = AnimatedProperty::new(m.rotation.value_at_local(t));
    out.motion.opacity = AnimatedProperty::new(m.opacity.value_at_local(t));
    out.motion.anchor = AnimatedProperty::new(m.anchor.value_at_local(t));
    out
}

/// Frame hold clips.
pub trait ClipFreezeExt {
    /// Static copy of the raw animation values at timeline time `t` (the stored values, whatever the fx toggles say).
    fn frozen_animation(&self, t: Time) -> ClipAnimation;

    /// A held clip: shows source frame `frame` for `duration` from `new_start`. Like Premiere's Frame Hold (Hold Filters off)
    /// it freezes the picture only: Motion, Opacity and effect keys keep animating, so a Fade Out at the tail survives. Keys
    /// stay on the same timeline frames (`keeps_animation`). An inserted segment (`keeps_animation` false) is a pause in
    /// time, so it shows the values of the original at `t` as static ones. The fx toggles and the blend mode are kept.
    fn holding(
        &self,
        frame: Time,
        t: Time,
        new_start: Time,
        duration: Time,
        keeps_animation: bool,
        ids: &mut dyn IdSource,
    ) -> Clip;
}

impl ClipFreezeExt for Clip {
    fn frozen_animation(&self, t: Time) -> ClipAnimation {
        let mut a = self.animation.clone();
        let l = t - self.start;
        a.position = AnimatedProperty::new(self.animation.position.value_at_local(l));
        a.scale = AnimatedProperty::new(self.animation.scale.value_at_local(l));
        a.rotation = AnimatedProperty::new(self.animation.rotation.value_at_local(l));
        a.opacity = AnimatedProperty::new(self.animation.opacity.value_at_local(l));
        a.anchor = AnimatedProperty::new(self.animation.anchor.value_at_local(l));
        a
    }

    fn holding(
        &self,
        frame: Time,
        t: Time,
        new_start: Time,
        duration: Time,
        keeps_animation: bool,
        ids: &mut dyn IdSource,
    ) -> Clip {
        let mut h = self.clone();
        h.id = ids.next_id();
        h.link = None;
        h.start = new_start;
        h.source = TimeRange::new(frame, duration);
        h.speed = sq_core_model::ClipSpeed::NORMAL;
        h.speed_keys = None;
        h.reversed = false;
        h.hold_frame = Some(frame);
        if keeps_animation {
            let by = self.start - new_start;
            h.animation = self.animation.shifted(by);
            h.effects = self.effects.iter().map(|e| e.shifted(by)).collect();
            h.shift_variant_keys(by);
        } else {
            let l = t - self.start;
            h.animation = self.frozen_animation(t);
            // A range grade shows on the hold exactly when it graded the held frame: then over the whole hold, else not at all.
            h.effects = self
                .effects
                .iter()
                .filter_map(|e| {
                    let mut f = e.frozen_at_local(l);
                    let Some(r) = e.color_range.filter(|_| e.is_color()) else { return Some(f) };
                    if !r.contains(l) {
                        return None;
                    }
                    f.color_range = Some(TimeRange::new(Time::ZERO, duration));
                    f.color_fade_in = None;
                    f.color_fade_out = None;
                    Some(f)
                })
                .collect();
            if let Some(vo) = h.variant_store.as_mut() {
                vo.items = vo.items.iter().map(|(k, v)| (*k, frozen_variant(v, l))).collect::<BTreeMap<_, _>>();
            }
            if let Some(b) = h.baked_store.as_mut() {
                *b = b.iter().map(|x| frozen_baked(x, l)).collect();
            }
            h.freeze_masks(l);
        }
        h
    }
}

/// Frame Hold edits.
pub trait TimelineFreezeFrameExt {
    /// Insert Frame Hold Segment: cuts the clip at `time` and inserts a held copy of the frame shown there, `duration`
    /// long; everything after ripples later on all ripple tracks (like an insert edit). One undo step. `clip` is the clip
    /// to hold (`None` = the topmost video clip under `time`). Returns the held clip's id.
    fn insert_frame_hold(
        &mut self,
        clip: Option<Id>,
        time: Time,
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;

    /// Add Frame Hold: from `time` to the end of the clip the picture is frozen on the frame shown there. The length of the
    /// clip and everything around it stay as they are. One undo step. Returns the held clip's id.
    fn add_frame_hold(&mut self, clip: Option<Id>, time: Time, ids: &mut dyn IdSource) -> Result<Id, EditError>;
}

/// The video clip a frame hold works on: `clip_id` when given, else the topmost video clip under `t`.
fn hold_target(tl: &Timeline, clip_id: Option<Id>, t: Time) -> Result<Member, EditError> {
    if let Some(id) = clip_id {
        let m = tl.find(id).ok_or(EditError::ClipNotFound)?;
        if m.clip.kind != TrackKind::Video || m.clip.is_generator() {
            return Err(EditError::WrongTrackKind);
        }
        if !m.clip.timeline().contains(t) {
            return Err(EditError::ClipNotFound);
        }
        return Ok(m);
    }
    for i in (0..tl.tracks.len()).rev().filter(|i| tl.tracks[*i].kind == TrackKind::Video) {
        if let Some(c) = tl.tracks[i].clips().iter().find(|c| c.timeline().contains(t)).filter(|c| !c.is_generator()) {
            return Ok(Member { track: i, clip: c.clone() });
        }
    }
    if !tl.tracks.iter().any(|t| t.kind == TrackKind::Video) {
        return Err(EditError::WrongTrackKind);
    }
    Err(EditError::ClipNotFound)
}

impl TimelineFreezeFrameExt for Timeline {
    fn insert_frame_hold(
        &mut self,
        clip: Option<Id>,
        time: Time,
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        if duration <= Time::ZERO {
            return Err(EditError::EmptyClip);
        }
        let fd = self.frame_duration();
        let t = time.snapped(fd);
        let target = hold_target(self, clip, t)?;
        if self.tracks[target.track].is_locked {
            return Err(EditError::TrackLocked);
        }
        let held = target.clip.source_time(t, fd);
        let hold = target.clip.holding(held, t, t, duration, false, ids);
        let mut work = self.tracks.clone();
        let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
        let none = std::collections::BTreeSet::new();
        for (i, track) in work.iter_mut().enumerate() {
            if i == target.track || track.follows_ripple() {
                track.split_relinking(t, &mut relinks, ids)?;
                track.shift(t, duration, &none);
            }
        }
        work[target.track].overwrite_relinking(hold.clone(), &mut relinks, ids)?;
        self.tracks = work;
        self.open_caption_gap(t, duration);
        Ok(hold.id)
    }

    fn add_frame_hold(&mut self, clip: Option<Id>, time: Time, ids: &mut dyn IdSource) -> Result<Id, EditError> {
        let fd = self.frame_duration();
        let t = time.snapped(fd);
        let target = hold_target(self, clip, t)?;
        if self.tracks[target.track].is_locked {
            return Err(EditError::TrackLocked);
        }
        let held = target.clip.source_time(t, fd);
        let mut work = self.tracks.clone();
        work[target.track].split_relinking(t, &mut BTreeMap::new(), ids)?;
        let piece = work[target.track]
            .clips()
            .iter()
            .find(|c| c.start == t && c.timeline().end() == target.clip.timeline().end())
            .cloned()
            .ok_or(EditError::ClipNotFound)?;
        let mut hold = target.clip.holding(held, t, t, piece.timeline().duration, true, ids);
        hold.id = piece.id;
        hold.link = piece.link;
        let id = hold.id;
        work[target.track].replace(hold);
        self.tracks = work;
        Ok(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::SequentialIds;

    fn sample() -> (Timeline, Clip) {
        let x = clip(0, 10, 5, Video, None, Some(30));
        (timeline(vec![track(Video, vec![x.clone()]), track(Audio, vec![a(12, 2)])]), x)
    }

    #[test]
    fn add_frame_hold_freezes_the_tail_without_changing_the_length() {
        let (mut tl, x) = sample();
        let id = tl.add_frame_hold(Some(x.id), s(4), &mut SequentialIds::default());
        assert_eq!(spans(&tl.tracks[0]), [[0, 4], [4, 10]]);
        let held = &tl.tracks[0].clips()[1];
        assert_eq!(id, Ok(held.id));
        assert_eq!((held.hold_frame, held.source.duration), (Some(s(9)), s(6)));
        assert_eq!(tl.tracks[0].clips()[0].hold_frame, None);
    }

    #[test]
    fn insert_frame_hold_pushes_everything_after_it_later() {
        let (mut tl, x) = sample();
        let id = tl.insert_frame_hold(Some(x.id), s(4), s(2), &mut SequentialIds::default());
        assert_eq!(spans(&tl.tracks[0]), [[0, 4], [4, 6], [6, 12]]);
        assert_eq!(spans(&tl.tracks[1]), [[14, 16]]);
        assert_eq!(id, Ok(tl.tracks[0].clips()[1].id));
        assert_eq!(tl.tracks[0].clips()[1].hold_frame, Some(s(9)));
    }

    #[test]
    fn the_target_must_be_a_video_clip_under_the_time_and_unlocked() {
        let (mut tl, x) = sample();
        let mut ids = SequentialIds::default();
        let audio_id = tl.tracks[1].clips()[0].id;
        assert_eq!(tl.add_frame_hold(Some(audio_id), s(13), &mut ids), Err(EditError::WrongTrackKind));
        assert_eq!(tl.add_frame_hold(Some(x.id), s(11), &mut ids), Err(EditError::ClipNotFound));
        assert_eq!(tl.insert_frame_hold(Some(x.id), s(4), Time::ZERO, &mut ids), Err(EditError::EmptyClip));
        tl.tracks[0].is_locked = true;
        assert_eq!(tl.add_frame_hold(None, s(4), &mut ids), Err(EditError::TrackLocked));
    }
}
