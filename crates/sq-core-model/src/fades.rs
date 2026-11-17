// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Fades.swift

use crate::fades_curve::FadeCurve;
use crate::{AnimatedProperty, Clip, Timeline, TrackKind};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, IdSource, Keyframe, Time};
use std::collections::BTreeSet;

/// The keys a fade created, by ID (v20, optional on decode). A fade only ever modifies or removes the keys listed here;
/// every other key on the line belongs to the user (or to Auto Duck) and is never touched by a fade.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct FadeMarks {
    /// Head fade: the silent key at the clip start and the key where the line reaches its level (two IDs, in that
    /// order).
    pub head: Vec<Id>,
    /// Tail fade: the key where the fade starts and the silent key at the clip end.
    pub tail: Vec<Id>,
}

impl FadeMarks {
    /// No fade keys.
    pub fn is_empty(&self) -> bool {
        self.head.is_empty() && self.tail.is_empty()
    }
}

/// Fade handles on the edges of a clip, expressed as keys on an `AnimatedProperty<f64>` (clip-local time).
/// Shared by the audio volume line and, later, by video opacity: both call these functions, each with its own
/// `FadeMarks`.
///
/// A head fade is two keys: the first key silent (`floor`), the second key at the level the line had there, so the line
/// rises between them. A tail fade mirrors that. Both keys are recorded in `FadeMarks`, which is the only way a fade is
/// recognized: the length is read from the marked keys (so a fade shortened by a trim shows the remaining length), and
/// removing a fade removes just those keys.
///
/// Keys of the user or of Auto Duck that lie INSIDE the fade region are kept as they are and keep their own value: the
/// line goes floor, then through them, then to the level (they are not scaled). Only a key exactly on a fade's end
/// time is absorbed (it has the same value by construction). Lengths are whole frames: less than one frame means no
/// fade.
pub enum FadeKeys {}

type Pair<'a> = (&'a Keyframe<f64>, &'a Keyframe<f64>);

impl FadeKeys {
    /// Length of the head fade (time of its second key), `None` when there is none.
    pub fn head_length(p: &AnimatedProperty<f64>, marks: &FadeMarks) -> Option<Time> {
        let (_, b) = Self::keys(p, &marks.head)?;
        Some(b.time.max(Time::ZERO))
    }

    /// Length of the tail fade inside a clip of `duration`, `None` when there is none.
    pub fn tail_length(p: &AnimatedProperty<f64>, duration: Time, marks: &FadeMarks) -> Option<Time> {
        let (a, _) = Self::keys(p, &marks.tail)?;
        Some((duration - a.time).max(Time::ZERO))
    }

    /// The property with a head fade of `length` (snapped down to whole frames; below one frame = no fade, and an
    /// existing head fade is removed). `marks` is updated. The level the fade rises to is the level the line had there.
    pub fn setting_head(
        prop: &AnimatedProperty<f64>,
        marks: &mut FadeMarks,
        length: Time,
        duration: Time,
        frame_duration: Time,
        floor: f64,
        ids: &mut dyn IdSource,
    ) -> AnimatedProperty<f64> {
        let mut p = Self::removing_head(prop, marks);
        let tail_len = Self::tail_length(&p, duration, marks).unwrap_or(Time::ZERO);
        let l = Self::snap_down(length, frame_duration)
            .min(Self::snap_down(duration - tail_len, frame_duration).max(Time::ZERO));
        if l <= Time::ZERO {
            return p;
        }
        let level = p.value_at_local(l);
        let a = Self::place(Keyframe::new(ids.next_id(), Time::ZERO, floor), &mut p, &marks.tail);
        let b = Self::place(Keyframe::new(ids.next_id(), l, level), &mut p, &marks.tail);
        marks.head = vec![a, b];
        p
    }

    /// The property with a tail fade of `length`; same rules as `setting_head`.
    pub fn setting_tail(
        prop: &AnimatedProperty<f64>,
        marks: &mut FadeMarks,
        length: Time,
        duration: Time,
        frame_duration: Time,
        floor: f64,
        ids: &mut dyn IdSource,
    ) -> AnimatedProperty<f64> {
        let mut p = Self::removing_tail(prop, marks);
        let head_len = Self::head_length(&p, marks).unwrap_or(Time::ZERO);
        let l = Self::snap_down(length, frame_duration)
            .min(Self::snap_down(duration - head_len, frame_duration).max(Time::ZERO));
        if l <= Time::ZERO {
            return p;
        }
        let from = duration - l;
        let level = p.value_at_local(from);
        let a = Self::place(Keyframe::new(ids.next_id(), from, level), &mut p, &marks.head);
        let b = Self::place(Keyframe::new(ids.next_id(), duration, floor), &mut p, &marks.head);
        marks.tail = vec![a, b];
        p
    }

    /// Removes the head fade's two keys and nothing else. A line left without keys becomes a constant at the level the
    /// fade rose to.
    pub fn removing_head(prop: &AnimatedProperty<f64>, marks: &mut FadeMarks) -> AnimatedProperty<f64> {
        let out = Self::removing(prop, &marks.head, &marks.tail, 1);
        marks.head = Vec::new();
        out
    }

    /// Removes the tail fade's two keys and nothing else; see `removing_head`.
    pub fn removing_tail(prop: &AnimatedProperty<f64>, marks: &mut FadeMarks) -> AnimatedProperty<f64> {
        let out = Self::removing(prop, &marks.tail, &marks.head, 0);
        marks.tail = Vec::new();
        out
    }

    /// Marks that still point at both of their keys; a fade whose key was deleted or replaced is no longer a fade (its
    /// remaining key is an ordinary key).
    pub fn pruned(marks: &FadeMarks, p: &AnimatedProperty<f64>) -> FadeMarks {
        let keep = |ids: &Vec<Id>| if Self::keys(p, ids).is_none() { Vec::new() } else { ids.clone() };
        FadeMarks { head: keep(&marks.head), tail: keep(&marks.tail) }
    }

    /// The two marked keys in `ids` order, `None` unless both are on the line.
    pub(crate) fn keys<'a>(p: &'a AnimatedProperty<f64>, ids: &[Id]) -> Option<Pair<'a>> {
        if ids.len() != 2 {
            return None;
        }
        Some((p.track.key(ids[0])?, p.track.key(ids[1])?))
    }

    /// Inserts `key`, or, when a key of the OTHER fade (`shared`) already sits at that time (the two fades meet),
    /// reuses that key: both fades then point at it and it stays until both are gone. Returns the ID the mark should
    /// hold.
    fn place(key: Keyframe<f64>, p: &mut AnimatedProperty<f64>, shared: &[Id]) -> Id {
        if let Some(e) = p.track.keys.iter().find(|k| k.time == key.time && shared.contains(&k.id)) {
            return e.id;
        }
        let id = key.id;
        p.track.insert(key);
        id
    }

    fn removing(prop: &AnimatedProperty<f64>, ids: &[Id], other: &[Id], level_key: usize) -> AnimatedProperty<f64> {
        let Some((a, b)) = Self::keys(prop, ids) else { return prop.clone() };
        let level = if level_key == 0 { a.value } else { b.value };
        let mut p = prop.clone();
        p.track.keys.retain(|k| !(ids.contains(&k.id) && !other.contains(&k.id)));
        if p.track.keys.is_empty() {
            p.value = level;
        }
        p
    }

    /// Largest whole number of frames not above `t`.
    #[doc(hidden)]
    pub fn snap_down(t: Time, frame: Time) -> Time {
        if t <= Time::ZERO || frame <= Time::ZERO {
            return Time::ZERO;
        }
        frame * t.frame_index(frame)
    }
}

impl Clip {
    /// Audio fade handles: length (timeline time) of the head fade on the volume line.
    pub fn audio_fade_in(&self) -> Time {
        FadeKeys::head_length(&self.animation.volume, &self.audio_fades).unwrap_or(Time::ZERO)
    }

    /// Audio fade handles: length (timeline time) of the tail fade on the volume line.
    pub fn audio_fade_out(&self) -> Time {
        FadeKeys::tail_length(&self.animation.volume, self.timeline().duration, &self.audio_fades).unwrap_or(Time::ZERO)
    }

    /// Sets the head fade; a fade shape other than linear survives the change.
    pub fn set_audio_fade_in(&mut self, length: Time, frame_duration: Time, ids: &mut dyn IdSource) {
        let curve = self.audio_fade_in_curve();
        let duration = self.timeline().duration;
        self.animation.volume = FadeKeys::setting_head(
            &self.animation.volume,
            &mut self.audio_fades,
            length,
            duration,
            frame_duration,
            0.0,
            ids,
        );
        self.prune_audio_key_marks();
        if let Some(curve) = curve
            && curve != FadeCurve::Linear
            && self.audio_fade_in_curve().is_some()
        {
            self.set_audio_fade_curve(curve, true);
        }
    }

    /// Sets the tail fade; a fade shape other than linear survives the change.
    pub fn set_audio_fade_out(&mut self, length: Time, frame_duration: Time, ids: &mut dyn IdSource) {
        let curve = self.audio_fade_out_curve();
        let duration = self.timeline().duration;
        self.animation.volume = FadeKeys::setting_tail(
            &self.animation.volume,
            &mut self.audio_fades,
            length,
            duration,
            frame_duration,
            0.0,
            ids,
        );
        self.prune_audio_key_marks();
        if let Some(curve) = curve
            && curve != FadeCurve::Linear
            && self.audio_fade_out_curve().is_some()
        {
            self.set_audio_fade_curve(curve, false);
        }
    }

    /// Drops the IDs of keys that are gone: Auto Duck's `duck_key_ids` and fades that lost one of their keys.
    pub fn prune_audio_key_marks(&mut self) {
        let p = &self.animation.volume;
        if !self.duck_key_ids.is_empty() {
            self.duck_key_ids.retain(|id| p.track.key(*id).is_some());
        }
        if !self.audio_fades.is_empty() {
            self.audio_fades = FadeKeys::pruned(&self.audio_fades, p);
        }
    }
}

impl Timeline {
    /// Housekeeping after every edit (Swift `normalizeAudioKeyMarks`): prunes key marks, and lets an audio transition
    /// replace the fade on its edge (the transition wins, like Premiere where a transition takes the place of the fade
    /// handle): the fade's two keys on an edge that has a transition are removed. Returns the clips that changed; the
    /// caller replaces them in the timeline.
    pub fn audio_key_mark_fixes(&self) -> Vec<Clip> {
        let mut changed = Vec::new();
        for track in self.tracks.iter().filter(|t| t.kind == TrackKind::Audio) {
            let heads: BTreeSet<Id> = track.transitions.iter().filter_map(|t| t.incoming).collect();
            let tails: BTreeSet<Id> = track.transitions.iter().filter_map(|t| t.outgoing).collect();
            for original in track.clips().iter().filter(|c| !c.audio_fades.is_empty() || !c.duck_key_ids.is_empty()) {
                let mut c = original.clone();
                let mut m = c.audio_fades.clone();
                if heads.contains(&c.id) && !m.head.is_empty() {
                    c.animation.volume = FadeKeys::removing_head(&c.animation.volume, &mut m);
                }
                if tails.contains(&c.id) && !m.tail.is_empty() {
                    c.animation.volume = FadeKeys::removing_tail(&c.animation.volume, &mut m);
                }
                c.audio_fades = m;
                c.prune_audio_key_marks();
                if c != *original {
                    changed.push(c);
                }
            }
        }
        changed
    }

    /// Whether the head / tail edge of clip `id` carries an audio transition (no fade handle there).
    pub fn has_audio_transition(&self, id: Id, head: bool) -> bool {
        self.tracks.iter().any(|t| {
            t.transitions.iter().any(|tr| if head { tr.incoming == Some(id) } else { tr.outgoing == Some(id) })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clip_animation::test_util::clip;
    use sq_core_time::SequentialIds;

    fn frame() -> Time {
        Time::new(1, 30)
    }

    fn audio(secs: i64) -> Clip {
        clip(TrackKind::Audio, 0, secs)
    }

    #[test]
    fn fade_lengths_snap_to_whole_frames_and_below_one_frame_is_none() {
        let mut ids = SequentialIds::default();
        let mut c = audio(4);
        c.set_audio_fade_in(Time::new(1, 20), frame(), &mut ids); // 1.5 frames -> 1 frame
        assert_eq!(c.audio_fade_in(), Time::new(1, 30));
        c.set_audio_fade_in(Time::new(1, 60), frame(), &mut ids); // half a frame -> no fade
        assert_eq!(c.audio_fade_in(), Time::ZERO);
        assert!(c.audio_fades.is_empty() && c.animation.volume.track.is_empty());
    }

    #[test]
    fn head_and_tail_share_one_key_where_they_meet() {
        let mut ids = SequentialIds::default();
        let mut c = audio(4);
        c.set_audio_fade_in(Time::new(2, 1), frame(), &mut ids);
        c.set_audio_fade_out(Time::new(2, 1), frame(), &mut ids);
        assert_eq!(c.animation.volume.track.keys.len(), 3);
        assert_eq!(c.audio_fades.head[1], c.audio_fades.tail[0]);
        assert_eq!((c.audio_fade_in(), c.audio_fade_out()), (Time::new(2, 1), Time::new(2, 1)));
        // The tail cannot take more than what the head left.
        c.set_audio_fade_out(Time::new(3, 1), frame(), &mut ids);
        assert_eq!(c.audio_fade_out(), Time::new(2, 1));
        // Removing the head keeps the shared key for the tail.
        c.set_audio_fade_in(Time::ZERO, frame(), &mut ids);
        assert_eq!(c.animation.volume.track.keys.len(), 2);
        assert_eq!(c.audio_fade_out(), Time::new(2, 1));
    }

    #[test]
    fn user_keys_inside_the_fade_are_kept_and_removing_a_fade_leaves_a_constant() {
        let mut ids = SequentialIds::default();
        let mut c = audio(4);
        c.animation.volume.value = 0.8;
        c.set_audio_fade_in(Time::new(2, 1), frame(), &mut ids);
        let own = Keyframe::new(Id::from_u128(900), Time::new(1, 1), 0.3);
        c.animation.volume.track.insert(own);
        c.set_audio_fade_in(Time::new(2, 1), frame(), &mut ids);
        assert!(c.animation.volume.track.key(Id::from_u128(900)).is_some());
        c.set_audio_fade_in(Time::ZERO, frame(), &mut ids);
        assert_eq!(c.animation.volume.track.keys.len(), 1);
        let mut d = audio(4);
        d.animation.volume.value = 0.8;
        d.set_audio_fade_in(Time::new(1, 1), frame(), &mut ids);
        d.set_audio_fade_in(Time::ZERO, frame(), &mut ids);
        assert!(!d.animation.volume.is_animated());
        assert_eq!(d.animation.volume.value, 0.8);
    }

    #[test]
    fn marks_that_lost_a_key_are_pruned() {
        let mut ids = SequentialIds::default();
        let mut c = audio(4);
        c.set_audio_fade_in(Time::new(1, 1), frame(), &mut ids);
        c.duck_key_ids = vec![Id::from_u128(777), c.audio_fades.head[0]];
        let gone = c.audio_fades.head[1];
        c.animation.volume.track.remove(gone);
        c.prune_audio_key_marks();
        assert!(c.audio_fades.head.is_empty());
        assert_eq!(c.duck_key_ids.len(), 1);
        assert_eq!(c.audio_fade_in(), Time::ZERO);
    }

    #[test]
    fn a_transition_on_an_edge_takes_the_fade_place() {
        let mut ids = SequentialIds::default();
        let mut c = audio(4);
        c.set_audio_fade_in(Time::new(1, 1), frame(), &mut ids);
        c.set_audio_fade_out(Time::new(1, 1), frame(), &mut ids);
        let tl: Timeline = serde_json::from_value(serde_json::json!({
            "id": Id::from_u128(5), "name": "t",
            "format": {"width": 1920, "height": 1080, "frameDuration": {"value": 1, "timescale": 30}, "audioSampleRate": 48000},
            "tracks": [{"id": Id::from_u128(6), "kind": "audio", "clips": [serde_json::to_value(&c).unwrap_or_default()],
                "transitions": [{"id": Id::from_u128(50), "kind": "crossDissolve",
                    "duration": {"value": 1, "timescale": 1}, "alignment": "center",
                    "customBefore": {"value": 0, "timescale": 1}, "incoming": c.id}]}]
        }))
        .unwrap_or_else(|e| panic!("timeline: {e}"));
        assert!(tl.has_audio_transition(c.id, true) && !tl.has_audio_transition(c.id, false));
        let fixed = tl.audio_key_mark_fixes();
        assert_eq!(fixed.len(), 1);
        assert_eq!((fixed[0].audio_fade_in(), fixed[0].audio_fade_out()), (Time::ZERO, Time::new(1, 1)));
    }
}
