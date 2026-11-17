// Swift: AudioGain.swift, AudioGain+Loudness.swift, AudioGain+Runs.swift
//! Audio Gain (Clip > Audio Options > Audio Gain, key G) and the maths around it. Pure, no media access: the caller
//! supplies the clip's source peak for the normalize modes. Also the volume line (the rubber band on an audio clip).

use crate::audio_role::TimelineRoleExt;
use sq_core_model::{AudioTag, Clip, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Keyframe, Time};
use std::collections::BTreeSet;

/// Namespace of the gain maths.
pub enum AudioGain {}

/// What a gain change does to one clip.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AudioGainMode {
    /// Gain becomes this value.
    Set(f64),
    /// Gain changes by this many dB.
    Adjust(f64),
    /// Gain makes the source's peak reach this level.
    Normalize {
        /// Target peak in dB.
        target_db: f64,
    },
}

impl AudioGain {
    /// dB shown for silence (linear 0), same as the Volume level in Effect Controls.
    pub const SILENCE_DB: f64 = -60.0;
    /// Lowest Audio Gain.
    pub const MIN_GAIN_DB: f64 = -96.0;
    /// Highest Audio Gain.
    pub const MAX_GAIN_DB: f64 = 96.0;
    /// Volume level limit (Premiere's Level goes to +15 dB).
    pub const MAX_VOLUME_DB: f64 = 15.0;
    /// Below this the clip counts as silent: nothing to match (BS.1770 absolute gate).
    pub const SILENT_LUFS: f64 = -70.0;
    /// Longest pause (between two clips of one track) that still counts as one spoken run for Match Loudness.
    pub const RUN_GAP: Time = Time::new(1, 2);

    /// dB of a linear level; silence and below is `SILENCE_DB`.
    pub fn db_from_linear(v: f64) -> f64 {
        if v <= 0.0 { Self::SILENCE_DB } else { (20.0 * v.log10()).max(Self::SILENCE_DB) }
    }

    /// Linear level of a dB value. Silence (or below) is exactly 0.
    pub fn linear_from_db(d: f64) -> f64 {
        if d <= Self::SILENCE_DB { 0.0 } else { 10.0_f64.powf(d / 20.0) }
    }

    /// New gain in dB of one clip. `peak` is the linear sample peak of the clip's source range (needed to normalize).
    /// `None` when normalizing silence or without a peak.
    pub fn apply(mode: AudioGainMode, current: f64, peak: Option<f64>) -> Option<f64> {
        let clamp = |v: f64| v.clamp(Self::MIN_GAIN_DB, Self::MAX_GAIN_DB);
        match mode {
            AudioGainMode::Set(v) => Some(clamp(v)),
            AudioGainMode::Adjust(d) => Some(clamp(current + d)),
            AudioGainMode::Normalize { target_db } => {
                let p = peak.filter(|p| *p > 0.0)?;
                Some(clamp(target_db - Self::db_from_linear(p)))
            }
        }
    }

    /// "Normalize All Peaks": one gain for all clips so the loudest peak reaches the target; the balance between the
    /// clips stays as it was. One value per input (all equal); `None` when everything is silent.
    pub fn normalize_together(peaks: &[f64], target_db: f64) -> Option<Vec<f64>> {
        let loudest = peaks.iter().copied().reduce(f64::max).filter(|l| *l > 0.0)?;
        let g = (target_db - Self::db_from_linear(loudest)).clamp(Self::MIN_GAIN_DB, Self::MAX_GAIN_DB);
        Some(peaks.iter().map(|_| g).collect())
    }

    /// Match Loudness: the Audio Gain (dB) that brings a clip whose source measures `measured_lufs` (integrated, before
    /// any gain) to `target_lufs`. `None` for silence or an unmeasured clip, so the caller leaves it unchanged. Clamped
    /// to the Audio Gain limits.
    pub fn match_loudness(measured_lufs: Option<f64>, target_lufs: f64) -> Option<f64> {
        let m = measured_lufs.filter(|m| m.is_finite() && *m > Self::SILENT_LUFS)?;
        Some((target_lufs - m).clamp(Self::MIN_GAIN_DB, Self::MAX_GAIN_DB))
    }

    /// Integrated loudness target for a clip of `t`: the Loudness target its track chose, else its role's default (clip
    /// tag, else track role), else dialogue's.
    pub fn target_lufs_for_clip(clip: &Clip, t: &Timeline) -> f64 {
        let track_choice = t
            .tracks
            .iter()
            .find(|tr| tr.clips().iter().any(|c| c.id == clip.id))
            .and_then(|tr| tr.loudness_target_lufs);
        track_choice.unwrap_or_else(|| t.role_of(clip).unwrap_or(AudioTag::Dialogue).target_lufs())
    }

    /// The one target a loudness row starts at for `clips`: their shared role target, dialogue's when the roles differ.
    pub fn target_lufs_for_clips(clips: &[Clip], t: &Timeline) -> f64 {
        let targets: Vec<f64> = clips.iter().map(|c| Self::target_lufs_for_clip(c, t)).collect();
        match targets.first() {
            Some(first) if targets.iter().all(|x| x == first) => *first,
            _ => AudioTag::Dialogue.target_lufs(),
        }
    }

    /// Match Loudness runs: for each audio clip of `selected`, the run it belongs to, meaning the clips of its track that
    /// follow each other (pause at most `max_gap`) with the same role. Cut dialogue is then measured as one piece, so the
    /// pieces get one gain and stay even. A run may contain clips that are not selected (they are measured, not
    /// changed). Runs come back ordered by start; a clip lands in exactly one run. Generator clips and video clips are
    /// ignored.
    pub fn loudness_runs(selected: &BTreeSet<Id>, t: &Timeline, max_gap: Time) -> Vec<Vec<Clip>> {
        fn flush(run: &mut Vec<Clip>, selected: &BTreeSet<Id>, out: &mut Vec<Vec<Clip>>) {
            if run.iter().any(|c| selected.contains(&c.id)) {
                out.push(std::mem::take(run));
            }
            run.clear();
        }
        let mut out: Vec<Vec<Clip>> = Vec::new();
        for tr in t.tracks.iter().filter(|tr| tr.kind == TrackKind::Audio) {
            let mut clips: Vec<Clip> = tr.clips().iter().filter(|c| !c.is_generator()).cloned().collect();
            clips.sort_by_key(|c| c.start);
            let mut run: Vec<Clip> = Vec::new();
            for c in clips {
                if let Some(last) = run.last() {
                    let joined = c.start - last.timeline().end() <= max_gap && t.role_of(&c) == t.role_of(last);
                    if !joined {
                        flush(&mut run, selected, &mut out);
                    }
                }
                run.push(c);
            }
            flush(&mut run, selected, &mut out);
        }
        out.sort_by_key(|r| r[0].start);
        out
    }
}

/// Closest two volume keys may get (one sample at 48 kHz).
pub const MIN_KEY_GAP: Time = Time::new(1, 48_000);

/// The volume line of an audio clip.
pub trait VolumeLineExt {
    /// Raises or lowers the volume line at clip-local time `t` by `delta_db`, like dragging the rubber band there:
    /// without keys the whole clip's level; with keys the segment under `t` (both of its keys), or the first / last key
    /// when `t` is before / after all of them.
    fn shift_volume_line(&mut self, t: Time, delta_db: f64);
    /// Adds a volume key at clip-local `t` on the current line (the first key keeps the constant level). Returns its id.
    fn add_volume_key(&mut self, t: Time, ids: &mut dyn IdSource) -> Id;
    /// Moves a volume key to clip-local `time` (kept inside the clip) and level `gain_db` (silence below the floor, at
    /// most +15 dB).
    fn move_volume_key(&mut self, id: Id, time: Time, gain_db: f64);
    /// Removes a volume key.
    fn remove_volume_key(&mut self, id: Id);
}

impl VolumeLineExt for Clip {
    fn shift_volume_line(&mut self, t: Time, delta_db: f64) {
        if delta_db.abs() <= 1e-6 {
            return; // a click without movement changes nothing (no dB round trip)
        }
        let shifted =
            |v: f64| AudioGain::linear_from_db((AudioGain::db_from_linear(v) + delta_db).min(AudioGain::MAX_VOLUME_DB));
        let keys = &self.animation.volume.track.keys;
        if keys.is_empty() {
            self.animation.volume.value = shifted(self.animation.volume.value);
            return;
        }
        let ids: Vec<Id> = match keys.iter().rposition(|k| k.time <= t) {
            None => vec![keys[0].id],
            Some(n) if n == keys.len() - 1 => vec![keys[n].id],
            Some(n) => vec![keys[n].id, keys[n + 1].id],
        };
        for id in ids {
            if let Some(v) = self.animation.volume.track.key(id).map(|k| k.value) {
                self.animation.volume.track.set(id, shifted(v));
            }
        }
    }

    fn add_volume_key(&mut self, t: Time, ids: &mut dyn IdSource) -> Id {
        let v = self.animation.volume.value_at_local(t);
        let k = Keyframe::new(ids.next_id(), t, v);
        let id = k.id;
        self.animation.volume.track.insert(k);
        id
    }

    fn move_volume_key(&mut self, id: Id, time: Time, gain_db: f64) {
        let mut t = time.max(Time::ZERO).min(self.duration());
        // A key never crosses or lands on its neighbors (that would reorder the line or delete the neighbor).
        let keys = &self.animation.volume.track.keys;
        if let Some(i) = keys.iter().position(|k| k.id == id) {
            if i > 0 {
                t = t.max(keys[i - 1].time + MIN_KEY_GAP);
            }
            if i + 1 < keys.len() {
                t = t.min(keys[i + 1].time - MIN_KEY_GAP);
            }
        }
        self.animation.volume.track.move_key(id, t);
        self.animation.volume.track.set(id, AudioGain::linear_from_db(gain_db.min(AudioGain::MAX_VOLUME_DB)));
    }

    fn remove_volume_key(&mut self, id: Id) {
        self.animation.volume.track.remove(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_role::tests::{clip, timeline, track};
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn audio() -> Clip {
        clip(0, 10, None)
    }

    #[test]
    fn gain_is_applied_on_top_of_volume() {
        let mut c = audio();
        assert!(c.audio_gain_db == 0.0 && c.volume(s(1)) == 1.0);
        c.audio_gain_db = 6.0206;
        assert!((c.volume(s(1)) - 2.0).abs() < 1e-3);
        c.animation.volume = sq_core_model::AnimatedProperty::new(0.5);
        assert!((c.volume(s(1)) - 1.0).abs() < 1e-3);
    }

    #[test]
    fn db_conversions() {
        assert!((AudioGain::db_from_linear(1.0) - 0.0).abs() < 1e-12);
        assert!((AudioGain::db_from_linear(0.5) + 6.0206).abs() < 1e-3);
        assert_eq!(AudioGain::db_from_linear(0.0), AudioGain::SILENCE_DB);
        assert!((AudioGain::linear_from_db(20.0) - 10.0).abs() < 1e-12);
        assert_eq!(AudioGain::linear_from_db(AudioGain::SILENCE_DB), 0.0);
    }

    #[test]
    fn gain_modes() {
        use AudioGainMode::*;
        assert_eq!(AudioGain::apply(Set(3.0), 10.0, None), Some(3.0));
        assert_eq!(AudioGain::apply(Adjust(-2.0), 3.0, None), Some(1.0));
        assert_eq!(AudioGain::apply(Set(500.0), 0.0, None), Some(AudioGain::MAX_GAIN_DB));
        assert_eq!(AudioGain::apply(Adjust(-500.0), 0.0, None), Some(AudioGain::MIN_GAIN_DB));
    }

    #[test]
    fn normalize_to_peak() {
        let n = AudioGainMode::Normalize { target_db: -3.0 };
        let g = AudioGain::apply(n, 0.0, Some(0.25)).unwrap_or(f64::NAN);
        assert!((g - 9.0412).abs() < 1e-3);
        // The result does not depend on the gain the clip already had: the peak is of the source.
        assert!((AudioGain::apply(n, 5.0, Some(0.25)).unwrap_or(f64::NAN) - g).abs() < 1e-9);
        assert_eq!(AudioGain::apply(n, 0.0, Some(0.0)), None);
        assert_eq!(AudioGain::apply(n, 0.0, None), None);
    }

    #[test]
    fn normalize_all_peaks_together_keeps_the_balance() {
        let gains = AudioGain::normalize_together(&[0.5, 0.25], 0.0).unwrap_or_default();
        assert!((gains[0] - 6.0206).abs() < 1e-3 && (gains[1] - 6.0206).abs() < 1e-3);
        assert_eq!(AudioGain::normalize_together(&[0.0, 0.0], 0.0), None);
        assert_eq!(AudioGain::normalize_together(&[], 0.0), None);
    }

    #[test]
    fn match_loudness_leaves_silence_and_unmeasured_alone() {
        assert_eq!(AudioGain::match_loudness(Some(-26.0), -14.0), Some(12.0));
        assert_eq!(AudioGain::match_loudness(Some(-80.0), -14.0), None);
        assert_eq!(AudioGain::match_loudness(None, -14.0), None);
        assert_eq!(AudioGain::match_loudness(Some(f64::NAN), -14.0), None);
        assert_eq!(AudioGain::match_loudness(Some(-69.0), 100.0), Some(AudioGain::MAX_GAIN_DB));
    }

    #[test]
    fn a_track_loudness_choice_beats_the_role_default_and_none_keeps_it() {
        let music = clip(0, 5, Some(AudioTag::Music));
        let plain = clip(10, 5, None);
        let mut tr = track(1, Some(AudioTag::Dialogue), vec![music.clone(), plain.clone()]);
        tr.loudness_target_lufs = Some(-23.0);
        let t = timeline(vec![tr]);
        assert_eq!(AudioGain::target_lufs_for_clip(&music, &t), -23.0);
        assert_eq!(AudioGain::target_lufs_for_clip(&plain, &t), -23.0);
        assert_eq!(AudioGain::target_lufs_for_clips(&[music, plain], &t), -23.0);
    }

    #[test]
    fn loudness_targets_follow_the_role() {
        let music = clip(0, 5, Some(AudioTag::Music));
        let plain = clip(10, 5, None);
        let t = timeline(vec![track(1, Some(AudioTag::Dialogue), vec![music.clone(), plain.clone()])]);
        assert_eq!(AudioGain::target_lufs_for_clip(&music, &t), -20.0);
        assert_eq!(AudioGain::target_lufs_for_clip(&plain, &t), -14.0);
        assert_eq!(AudioGain::target_lufs_for_clips(&[music.clone(), music.clone()], &t), -20.0);
        assert_eq!(AudioGain::target_lufs_for_clips(&[music, plain], &t), -14.0);
        assert_eq!(AudioGain::target_lufs_for_clips(&[], &t), -14.0);
    }

    #[test]
    fn loudness_runs_join_close_clips_of_one_role() {
        let a = clip(0, 5, None);
        let b = clip(5, 5, None); // touches a
        let c = clip(11, 5, None); // 1 s pause after b: a new run
        let d = clip(20, 2, Some(AudioTag::Music)); // other role
        let t = timeline(vec![track(1, Some(AudioTag::Dialogue), vec![a.clone(), b.clone(), c.clone(), d.clone()])]);
        let all: BTreeSet<Id> = [a.id, b.id, c.id, d.id].into_iter().collect();
        let runs = AudioGain::loudness_runs(&all, &t, AudioGain::RUN_GAP);
        let ids: Vec<Vec<Id>> = runs.iter().map(|r| r.iter().map(|c| c.id).collect()).collect();
        assert_eq!(ids, vec![vec![a.id, b.id], vec![c.id], vec![d.id]]);
        // Only runs holding a selected clip come back.
        let only_c: BTreeSet<Id> = [c.id].into_iter().collect();
        assert_eq!(AudioGain::loudness_runs(&only_c, &t, AudioGain::RUN_GAP).len(), 1);
    }

    #[test]
    fn drag_without_keys_changes_the_whole_clip() {
        let mut c = audio();
        c.shift_volume_line(s(3), -6.0206);
        assert!((c.animation.volume.value - 0.5).abs() < 1e-3);
        assert!(!c.animation.volume.is_animated());
    }

    #[test]
    fn drag_of_a_segment_moves_both_keys() {
        let (mut c, mut ids) = (audio(), SequentialIds::default());
        let a = c.add_volume_key(s(2), &mut ids);
        let b = c.add_volume_key(s(6), &mut ids);
        assert_eq!(c.animation.volume.track.keys.len(), 2);
        c.shift_volume_line(s(4), 6.0206);
        let t = &c.animation.volume.track;
        let v = |id| t.key(id).map_or(f64::NAN, |k| k.value);
        assert!((v(a) - 2.0).abs() < 1e-3 && (v(b) - 2.0).abs() < 1e-3);
    }

    #[test]
    fn drag_before_first_key_moves_that_key_only() {
        let (mut c, mut ids) = (audio(), SequentialIds::default());
        let a = c.add_volume_key(s(4), &mut ids);
        let b = c.add_volume_key(s(8), &mut ids);
        c.shift_volume_line(s(1), -6.0206);
        let t = &c.animation.volume.track;
        assert!((t.key(a).map_or(f64::NAN, |k| k.value) - 0.5).abs() < 1e-3);
        assert!((t.key(b).map_or(f64::NAN, |k| k.value) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn added_key_takes_the_current_value_and_keeps_the_shape() {
        let (mut c, mut ids) = (audio(), SequentialIds::default());
        c.animation.volume = sq_core_model::AnimatedProperty::new(0.5);
        let k = c.add_volume_key(s(5), &mut ids);
        assert_eq!(c.animation.volume.track.key(k).map(|k| k.value), Some(0.5));
        assert!(c.volume(s(0)) == 0.5 && c.volume(s(9)) == 0.5);
        // A key in the middle of a ramp lies on the ramp.
        let mut r = audio();
        let a = r.add_volume_key(s(0), &mut ids);
        let b = r.add_volume_key(s(10), &mut ids);
        r.animation.volume.track.set(a, 0.0);
        r.animation.volume.track.set(b, 1.0);
        let m = r.add_volume_key(s(5), &mut ids);
        assert!((r.animation.volume.track.key(m).map_or(f64::NAN, |k| k.value) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn moving_a_key_changes_time_and_level_and_stays_inside_the_clip() {
        let (mut c, mut ids) = (audio(), SequentialIds::default());
        let k = c.add_volume_key(s(5), &mut ids);
        c.move_volume_key(k, s(7), 3.0);
        let key = c.animation.volume.track.key(k).cloned();
        assert_eq!(key.as_ref().map(|k| k.time), Some(s(7)));
        assert!((key.map_or(f64::NAN, |k| k.value) - AudioGain::linear_from_db(3.0)).abs() < 1e-9);
        c.move_volume_key(k, s(99), 3.0);
        assert_eq!(c.animation.volume.track.key(k).map(|k| k.time), Some(s(10)));
        c.move_volume_key(k, s(-4), -200.0);
        let key = c.animation.volume.track.key(k);
        assert_eq!(key.map(|k| k.time), Some(Time::ZERO));
        assert_eq!(key.map(|k| k.value), Some(0.0)); // below the floor = silence
    }

    #[test]
    fn moved_volume_key_keeps_order_and_gain_cap() {
        let (mut c, mut ids) = (audio(), SequentialIds::default());
        let a = c.add_volume_key(s(1), &mut ids);
        let b = c.add_volume_key(s(4), &mut ids);
        c.move_volume_key(a, s(8), 40.0);
        let t = &c.animation.volume.track;
        assert_eq!(t.keys.iter().map(|k| k.id).collect::<Vec<_>>(), vec![a, b]);
        let (ka, kb) = (t.key(a).map(|k| k.time), t.key(b).map(|k| k.time));
        assert!(ka < kb);
        let v = t.key(a).map_or(f64::NAN, |k| k.value);
        assert!((AudioGain::db_from_linear(v) - AudioGain::MAX_VOLUME_DB).abs() < 1e-6);
    }

    #[test]
    fn remove_key_keeps_the_rest() {
        let (mut c, mut ids) = (audio(), SequentialIds::default());
        let a = c.add_volume_key(s(1), &mut ids);
        c.add_volume_key(s(2), &mut ids);
        c.remove_volume_key(a);
        assert_eq!(c.animation.volume.track.keys.len(), 1);
    }
}
