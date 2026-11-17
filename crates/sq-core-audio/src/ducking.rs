// Swift: Ducking.swift
//! Auto Duck: lowers a music clip's volume line while dialogue plays. Pure: the caller supplies the dialogue ranges
//! (clip-local times), the function returns volume keys. Rational time throughout.

use sq_core_model::Clip;
use sq_core_time::{IdSource, Keyframe, Time, TimeRange};
use std::collections::BTreeSet;

/// Namespace of the Auto Duck maths.
pub enum Ducking {}

impl Ducking {
    /// Default depth of the duck in dB.
    pub const DEFAULT_AMOUNT_DB: f64 = 12.0;
    /// Ramp length of 0.3 s as a rational (no Double time).
    pub const DEFAULT_FADE: Time = Time::new(3, 10);

    /// Keys that duck `base` (the clip's own volume line, evaluated at a clip-local time) by `amount_db` wherever one of
    /// `dialogue` is, with linear ramps of `fade` before and after. Ranges closer than two ramps are merged so the ramps
    /// never overlap. Everything is clamped to `0 ... duration`. Empty without dialogue.
    pub fn keys(
        dialogue: &[TimeRange],
        duration: Time,
        amount_db: f64,
        fade: Time,
        recovery: Option<Time>,
        base: impl Fn(Time) -> f64,
        ids: &mut dyn IdSource,
    ) -> Vec<Keyframe<f64>> {
        let rec = recovery.unwrap_or(fade);
        if duration <= Time::ZERO || amount_db <= 0.0 {
            return Vec::new();
        }
        let factor = 10.0_f64.powf(-amount_db / 20.0);
        let spans = Self::spans(dialogue, duration, fade, rec);
        let mut out: Vec<Keyframe<f64>> = Vec::new();
        let mut add = |t: Time, ducked: bool| {
            let v = base(t);
            out.push(Keyframe::new(ids.next_id(), t, if ducked { v * factor } else { v }));
        };
        for (a, b) in spans {
            if a - fade > Time::ZERO {
                add(a - fade, false);
                add(a, true);
            } else {
                add(Time::ZERO, true);
            }
            if b + rec < duration {
                add(b, true);
                add(b + rec, false);
            } else {
                add(duration, true);
            }
        }
        out
    }

    /// The stretches that are fully ducked (start, end): the dialogue clamped to `0 ... duration`, ranges closer than
    /// two ramps merged.
    pub(crate) fn spans(dialogue: &[TimeRange], duration: Time, fade: Time, rec: Time) -> Vec<(Time, Time)> {
        let mut spans: Vec<(Time, Time)> = Vec::new();
        let mut sorted = dialogue.to_vec();
        sorted.sort_by_key(|r| r.start);
        for r in sorted {
            let (a, b) = (r.start.max(Time::ZERO), r.end().min(duration));
            if b <= a {
                continue;
            }
            match spans.last_mut() {
                Some(last) if a - last.1 <= fade + rec => last.1 = last.1.max(b),
                _ => spans.push((a, b)),
            }
        }
        spans
    }
}

/// Auto Duck on a clip.
pub trait DuckingClipExt {
    /// Drops exactly the keys an earlier duck run generated (the clip's own volume line stays). Returns how many went.
    /// The explicit way to remove duck keys: `apply_ducking(&[], ..)` does the same only as a side effect of "no dialogue".
    fn remove_duck_keys(&mut self) -> usize;
    /// Runs Auto Duck on this (music) clip: removes the keys of the previous run, then adds the new ones. `dialogue` is in
    /// timeline time. The clip's own keys stay; a generated key never replaces one of them. Returns the number of keys
    /// added (0 when there is no dialogue over the clip).
    ///
    /// A generated key that follows a Hold Ahead is the key it shows: the step to the ducked level falls on the Hold
    /// Ahead's own time, inside the fade.
    fn apply_ducking(
        &mut self,
        dialogue: &[TimeRange],
        amount_db: f64,
        fade: Time,
        recovery: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> usize;
}

impl DuckingClipExt for Clip {
    fn remove_duck_keys(&mut self) -> usize {
        let generated: BTreeSet<_> = self.duck_key_ids.iter().copied().collect();
        if generated.is_empty() {
            return 0;
        }
        let before = self.animation.volume.track.keys.len();
        self.animation.volume.track.keys.retain(|k| !generated.contains(&k.id));
        self.duck_key_ids = Vec::new();
        before - self.animation.volume.track.keys.len()
    }

    fn apply_ducking(
        &mut self,
        dialogue: &[TimeRange],
        amount_db: f64,
        fade: Time,
        recovery: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> usize {
        let mut v = self.animation.volume.clone();
        let generated: BTreeSet<_> = self.duck_key_ids.iter().copied().collect();
        v.track.keys.retain(|k| !generated.contains(&k.id));
        let local: Vec<TimeRange> = dialogue.iter().map(|d| TimeRange::new(d.start - self.start, d.duration)).collect();
        let base = v.clone();
        let keys = Ducking::keys(&local, self.duration(), amount_db, fade, recovery, |t| base.value_at_local(t), ids);
        let mut added = Vec::new();
        for k in keys {
            if !v.track.keys.iter().any(|x| x.time == k.time) {
                added.push(k.id);
                v.track.insert(k);
            }
        }
        self.animation.volume = v;
        let n = added.len();
        self.duck_key_ids = added;
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_role::tests::clip;
    use sq_core_time::SequentialIds;

    fn sec(a: i64, len: i64) -> TimeRange {
        TimeRange::new(Time::new(a, 1), Time::new(len, 1))
    }

    #[test]
    fn keys_ramp_around_dialogue_and_merge_close_ranges() {
        let mut ids = SequentialIds::default();
        let keys = Ducking::keys(
            &[sec(10, 2), TimeRange::new(Time::new(25, 2), Time::new(2, 1))],
            Time::new(30, 1),
            12.0,
            Time::new(1, 2),
            None,
            |_| 1.0,
            &mut ids,
        );
        let f = 10.0_f64.powf(-12.0 / 20.0);
        let got: Vec<(Time, f64)> = keys.iter().map(|k| (k.time, k.value)).collect();
        // 10..14.5 is one span (the 0.5 s gap is not wider than two ramps of 0.5 s).
        assert_eq!(
            got,
            vec![(Time::new(19, 2), 1.0), (Time::new(10, 1), f), (Time::new(29, 2), f), (Time::new(15, 1), 1.0)]
        );
    }

    #[test]
    fn keys_clamp_to_the_clip_and_need_dialogue() {
        let mut ids = SequentialIds::default();
        let none = Ducking::keys(&[], Time::new(30, 1), 12.0, Ducking::DEFAULT_FADE, None, |_| 1.0, &mut ids);
        assert!(none.is_empty());
        let off = Ducking::keys(&[sec(1, 2)], Time::new(30, 1), 0.0, Ducking::DEFAULT_FADE, None, |_| 1.0, &mut ids);
        assert!(off.is_empty());
        let edge =
            Ducking::keys(&[sec(-5, 100)], Time::new(30, 1), 12.0, Ducking::DEFAULT_FADE, None, |_| 1.0, &mut ids);
        assert_eq!(edge.iter().map(|k| k.time).collect::<Vec<_>>(), vec![Time::ZERO, Time::new(30, 1)]);
    }

    #[test]
    fn removes_only_generated_keys_and_reports_count() {
        let (mut c, mut ids) = (clip(0, 30, None), SequentialIds::default());
        assert_eq!(c.remove_duck_keys(), 0);
        let added = c.apply_ducking(&[sec(10, 5)], 12.0, Ducking::DEFAULT_FADE, None, &mut ids);
        assert!(added > 0);
        assert_eq!(c.remove_duck_keys(), added);
        assert!(c.duck_key_ids.is_empty() && c.animation.volume.track.is_empty());
    }

    #[test]
    fn a_new_run_replaces_the_keys_of_the_old_one_and_keeps_own_keys() {
        let (mut c, mut ids) = (clip(0, 30, None), SequentialIds::default());
        let own = Keyframe::new(ids.next_id(), Time::new(1, 1), 0.8);
        c.animation.volume.track.insert(own.clone());
        let first = c.apply_ducking(&[sec(10, 5)], 12.0, Ducking::DEFAULT_FADE, None, &mut ids);
        let second = c.apply_ducking(&[sec(20, 5)], 12.0, Ducking::DEFAULT_FADE, None, &mut ids);
        assert!(first > 0 && second > 0);
        assert_eq!(c.animation.volume.track.keys.len(), second + 1);
        assert!(c.animation.volume.track.key(own.id).is_some());
    }
}
