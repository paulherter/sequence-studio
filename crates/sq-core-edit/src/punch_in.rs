//! W8.2 Punch-in toggle: one key puts a static scale-up on the selected video clips, the same key takes it off.
// Swift: PunchIn.swift

use sq_core_model::{AnimatedProperty, Clip, ClipEffect, EditError, Timeline, TrackKind};
use sq_core_time::Id;

/// W8.2 Punch-in toggle: one key puts a static scale-up on the selected video clips, the same key takes it off. Built from
/// what the model already has (an effect of kind `transform`, Scale = `DEFAULT_SCALE` %, multiplying onto Motion), so no file
/// format change. The stage carries a marker parameter (`MARKER_KEY`), so it is recognized on every clip that carries it:
/// renames, trims, moves, and the copies made by a razor cut, copy/paste or duplicate (new clip id, same effect), so the
/// toggle never stacks a second stage. A user's own Transform effects are never touched. Stages written before the marker
/// existed are still recognized by the id derived from their clip's id.
pub struct PunchIn;

impl PunchIn {
    /// Scale in percent (hard cut). The maintainer has not named his value yet (115, 110 or 126.5): change here only.
    pub const DEFAULT_SCALE: f64 = 115.0;
    /// Parameter that marks a transform stage as the punch-in (value 1, never animated or shown).
    pub const MARKER_KEY: &'static str = "sqPunchIn";

    /// True when `effect` is the punch-in stage of `clip`.
    pub fn is_punch_in(effect: &ClipEffect, clip: Id) -> bool {
        effect.kind == ClipEffect::TRANSFORM_KIND
            && (effect.parameters.contains_key(Self::MARKER_KEY) || effect.id == Self::effect_id(clip))
    }

    /// The id of the stage of `clip`: the clip's bytes offset by a fixed pattern, so old files find their stage again.
    pub fn effect_id(clip: Id) -> Id {
        let mut b = clip.as_u128().to_be_bytes();
        for (i, byte) in b.iter_mut().enumerate() {
            *byte = byte.wrapping_add(0x3D).wrapping_add((i as u8).wrapping_mul(31));
        }
        Id::from_u128(u128::from_be_bytes(b))
    }

    /// The marked punch-in stage for `clip` with the given scale property (percent). Shared by Shift+P and Punch In Cuts.
    pub(crate) fn make_stage(clip: Id, scale: AnimatedProperty<f64>) -> Option<ClipEffect> {
        let mut e = ClipEffect::make(Self::effect_id(clip), ClipEffect::TRANSFORM_KIND)?;
        e.parameters.insert(ClipEffect::STAGE_SCALE_KEY.to_string(), scale);
        e.parameters.insert(Self::MARKER_KEY.to_string(), AnimatedProperty::new(1.0));
        Some(e)
    }
}

/// Swift `Timeline.isPunchedIn` and `togglePunchIn`.
pub trait PunchInTimelineExt {
    /// The clip carries its punch-in stage.
    fn is_punched_in(&self, clip: &Clip) -> bool;

    /// Toggles the punch-in on the given clips: when every one has it, it is removed from all; otherwise the clips without it
    /// get it. Returns true when the clips are punched in afterwards. Errors `ClipNotFound`, `WrongTrackKind` (audio or
    /// generator) and `TrackLocked`; nothing changes then.
    fn toggle_punch_in(&mut self, ids: &[Id], scale: f64) -> Result<bool, EditError>;
}

impl PunchInTimelineExt for Timeline {
    fn is_punched_in(&self, clip: &Clip) -> bool {
        clip.effects.iter().any(|e| PunchIn::is_punch_in(e, clip.id))
    }

    fn toggle_punch_in(&mut self, ids: &[Id], scale: f64) -> Result<bool, EditError> {
        let mut work = self.clone();
        let mut targets: Vec<(usize, Clip)> = Vec::new();
        for id in ids {
            let m = work.find(*id).ok_or(EditError::ClipNotFound)?;
            if m.clip.kind != TrackKind::Video || m.clip.is_generator() {
                return Err(EditError::WrongTrackKind);
            }
            if work.tracks[m.track].is_locked {
                return Err(EditError::TrackLocked);
            }
            targets.push((m.track, m.clip));
        }
        if targets.is_empty() {
            return Ok(false);
        }
        let remove = targets.iter().all(|(_, c)| self.is_punched_in(c));
        for (ti, mut c) in targets {
            if remove {
                let id = c.id;
                c.effects.retain(|e| !PunchIn::is_punch_in(e, id));
            } else if !self.is_punched_in(&c) {
                let e = PunchIn::make_stage(c.id, AnimatedProperty::new(scale)).ok_or(EditError::ClipNotFound)?;
                c.effects.push(e);
            }
            work.tracks[ti].replace(c);
        }
        *self = work;
        Ok(!remove)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track};
    use sq_core_time::{IdSource, SequentialIds, Time, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn make(ids: &mut SequentialIds) -> (Timeline, Vec<Clip>) {
        let mut v = Track::new(ids.next_id(), TrackKind::Video);
        let mut clips = Vec::new();
        for i in 0..2 {
            let c = Clip::new(
                ids.next_id(),
                &format!("c{i}"),
                ids.next_id(),
                TrackKind::Video,
                TimeRange::new(Time::ZERO, s(2)),
                s(i * 2),
            );
            v.overwrite(c.clone(), ids).unwrap();
            clips.push(c);
        }
        (Timeline::new(ids.next_id(), "T", SequenceFormat::new(Time::new(1, 30)), vec![v]), clips)
    }
    fn clip_of(t: &Timeline, c: &Clip) -> Clip {
        t.find(c.id).unwrap().clip
    }

    #[test]
    fn punch_adds_transform_stage_at_default_scale() {
        let mut ids = SequentialIds::default();
        let (mut t, cs) = make(&mut ids);
        assert!(t.toggle_punch_in(&[cs[0].id], PunchIn::DEFAULT_SCALE).unwrap());
        let punched = clip_of(&t, &cs[0]);
        let e = punched.effects.iter().find(|e| e.id == PunchIn::effect_id(cs[0].id)).unwrap();
        assert_eq!(e.kind, ClipEffect::TRANSFORM_KIND);
        assert_eq!(e.parameters[ClipEffect::STAGE_SCALE_KEY].value, PunchIn::DEFAULT_SCALE);
        assert!(clip_of(&t, &cs[1]).effects.is_empty());
        assert_eq!(punched.animation, cs[0].animation);
    }

    #[test]
    fn toggle_twice_is_original() {
        let mut ids = SequentialIds::default();
        let (mut t, cs) = make(&mut ids);
        let before = t.clone();
        t.toggle_punch_in(&[cs[0].id], 115.0).unwrap();
        assert!(!t.toggle_punch_in(&[cs[0].id], 115.0).unwrap());
        assert_eq!(t, before);
    }

    #[test]
    fn mixed_selection_punches_all_then_removes_all() {
        let mut ids = SequentialIds::default();
        let (mut t, cs) = make(&mut ids);
        let all: Vec<Id> = cs.iter().map(|c| c.id).collect();
        t.toggle_punch_in(&[cs[0].id], 115.0).unwrap();
        assert!(t.toggle_punch_in(&all, 115.0).unwrap());
        assert!(cs.iter().all(|c| t.is_punched_in(&clip_of(&t, c))));
        assert!(!t.toggle_punch_in(&all, 115.0).unwrap());
        assert!(cs.iter().all(|c| !t.is_punched_in(&clip_of(&t, c))));
    }

    #[test]
    fn refuses_audio_and_locked() {
        let mut ids = SequentialIds::default();
        let (mut t, cs) = make(&mut ids);
        t.tracks[0].is_locked = true;
        assert_eq!(t.toggle_punch_in(&[cs[0].id], 115.0), Err(EditError::TrackLocked));
        t.tracks[0].is_locked = false;
        let mut a = Track::new(ids.next_id(), TrackKind::Audio);
        let ac = Clip::new(
            ids.next_id(),
            "a",
            ids.next_id(),
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, s(1)),
            Time::ZERO,
        );
        a.overwrite(ac.clone(), &mut ids).unwrap();
        t.tracks.push(a);
        assert_eq!(t.toggle_punch_in(&[ac.id], 115.0), Err(EditError::WrongTrackKind));
    }

    #[test]
    fn punch_survives_rename() {
        let mut ids = SequentialIds::default();
        let (mut t, cs) = make(&mut ids);
        t.toggle_punch_in(&[cs[0].id], 115.0).unwrap();
        let mut c = clip_of(&t, &cs[0]);
        c.name = "renamed".into();
        t.tracks[0].replace(c);
        assert!(t.is_punched_in(&clip_of(&t, &cs[0])));
    }
}
