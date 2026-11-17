//! Keyframe stepping and Solo: small verbs the key commands call.
// Swift: Timeline+KeyframeNavigation.swift

use std::collections::BTreeSet;

use sq_core_model::{ClipEdge, EditError, Timeline};
use sq_core_time::{Id, IdSource, Time, TimeRange};

use crate::timeline_edits::TimelineEditsExt as _;
use crate::timeline_magnetic_ops::MagneticOpsExt as _;
use crate::timeline_magnetic_verbs::MagneticVerbsExt as _;

use crate::snapping::keyframe_times;
use crate::timeline_mute_detach::audio_tracks_of_clips;

/// Swift `Timeline.keyframeTimes(of:)`, `nextKeyframe`, `previousKeyframe` and `toggleSolo(forClips:)`.
pub trait TimelineKeyframeNavigationExt {
    /// Timeline times of every key of the given clips that lie inside the clip, sorted and unique.
    fn keyframe_times_of(&self, ids: &BTreeSet<Id>) -> Vec<Time>;
    /// First key of `clips` after `t` (timeline time), None when there is none.
    fn next_keyframe(&self, t: Time, clips: &BTreeSet<Id>) -> Option<Time>;
    /// Last key of `clips` before `t`, None when there is none.
    fn previous_keyframe(&self, t: Time, clips: &BTreeSet<Id>) -> Option<Time>;
    /// Solo of the audio tracks that hold the given clips or their linked partners. All of them already solo: Solo goes off
    /// for them; otherwise it goes on. Returns the new state, None when no audio track was involved.
    fn toggle_solo(&mut self, ids: &BTreeSet<Id>) -> Option<bool>;

    /// Trim to Range (Final Cut's Trim to Selection): every given clip is cut back to `range`. Position is kept (a gap
    /// stays), Fast Cut closes up. Linked partners follow through the plain trim. Returns how many clips changed.
    fn trim_to_range(
        &mut self,
        ids: &BTreeSet<Id>,
        range: TimeRange,
        src: &mut dyn IdSource,
    ) -> Result<usize, EditError>;
}

impl TimelineKeyframeNavigationExt for Timeline {
    fn keyframe_times_of(&self, ids: &BTreeSet<Id>) -> Vec<Time> {
        let mut out = BTreeSet::new();
        for c in self.tracks.iter().flat_map(|t| t.clips()).filter(|c| ids.contains(&c.id)) {
            for k in keyframe_times(c) {
                if c.timeline().contains(c.start + k) {
                    out.insert(c.start + k);
                }
            }
        }
        out.into_iter().collect()
    }

    fn next_keyframe(&self, t: Time, clips: &BTreeSet<Id>) -> Option<Time> {
        self.keyframe_times_of(clips).into_iter().find(|&k| k > t)
    }

    fn previous_keyframe(&self, t: Time, clips: &BTreeSet<Id>) -> Option<Time> {
        self.keyframe_times_of(clips).into_iter().rev().find(|&k| k < t)
    }

    fn toggle_solo(&mut self, ids: &BTreeSet<Id>) -> Option<bool> {
        let touched = audio_tracks_of_clips(self, ids);
        if touched.is_empty() {
            return None;
        }
        let on = !touched.iter().all(|&i| self.tracks[i].is_solo);
        for i in touched {
            self.tracks[i].is_solo = on;
        }
        Some(on)
    }

    fn trim_to_range(
        &mut self,
        ids: &BTreeSet<Id>,
        range: TimeRange,
        src: &mut dyn IdSource,
    ) -> Result<usize, EditError> {
        let find = |tl: &Timeline, id: Id| tl.find(id).map(|m| m.clip);
        let mut changed = 0;
        for id in ids {
            let Some(mut c) = find(self, *id) else { continue };
            let mut did = false;
            if c.start < range.start && range.start < c.timeline().end() {
                trim_clip_edge(self, *id, ClipEdge::Head, range.start - c.start, src)?;
                did = true;
                let Some(n) = find(self, *id) else { continue };
                c = n;
            }
            if c.timeline().end() > range.end() && range.end() > c.start {
                trim_clip_edge(self, *id, ClipEdge::Tail, range.end() - c.timeline().end(), src)?;
                did = true;
            }
            if did {
                changed += 1;
            }
        }
        Ok(changed)
    }
}

/// Fast Cut: a ripple trim; Normal: the plain trim.
fn trim_clip_edge(
    tl: &mut Timeline,
    id: Id,
    edge: ClipEdge,
    delta: Time,
    src: &mut dyn IdSource,
) -> Result<(), EditError> {
    if tl.is_fast_cut() {
        tl.magnetic_ripple_trim(id, edge, delta, src)?;
    } else {
        tl.trim(id, edge, delta)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track, TrackKind};
    use sq_core_time::{IdSource, Keyframe, KeyframeTrack, SequentialIds, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn clip(ids: &mut SequentialIds, start: i64, dur: i64, kind: TrackKind, link: Option<Id>, keys: &[i64]) -> Clip {
        let mut c = Clip::new(ids.next_id(), "c", ids.next_id(), kind, TimeRange::new(s(0), s(dur)), s(start));
        c.link = link;
        c.media_duration = Some(s(1000));
        if !keys.is_empty() {
            let keys = keys.iter().map(|&k| Keyframe::new(ids.next_id(), s(k), 1.0)).collect();
            c.animation.opacity.track = KeyframeTrack::with_keys(keys);
        }
        c
    }

    fn track(ids: &mut SequentialIds, clips: Vec<Clip>, kind: TrackKind) -> Track {
        let mut t = Track::new(ids.next_id(), kind);
        for c in clips {
            t.overwrite(c, ids).unwrap();
        }
        t
    }

    fn timeline(ids: &mut SequentialIds, tracks: Vec<Track>) -> Timeline {
        Timeline::new(ids.next_id(), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    #[test]
    fn next_and_previous_use_timeline_time_of_clip_keys() {
        let mut ids = SequentialIds::default();
        let c = clip(&mut ids, 10, 20, TrackKind::Video, None, &[2, 5, 9]);
        let t = track(&mut ids, vec![c.clone()], TrackKind::Video);
        let tl = timeline(&mut ids, vec![t]);
        let sel = BTreeSet::from([c.id]);
        assert_eq!(tl.next_keyframe(s(0), &sel), Some(s(12)));
        assert_eq!(tl.next_keyframe(s(12), &sel), Some(s(15)));
        assert_eq!(tl.next_keyframe(s(19), &sel), None);
        assert_eq!(tl.previous_keyframe(s(19), &sel), Some(s(15)));
        assert_eq!(tl.previous_keyframe(s(12), &sel), None);
    }

    #[test]
    fn solos_audio_tracks_of_selection_and_linked_partners() {
        let mut ids = SequentialIds::default();
        let l = ids.next_id();
        let v = clip(&mut ids, 0, 5, TrackKind::Video, Some(l), &[]);
        let a = clip(&mut ids, 0, 5, TrackKind::Audio, Some(l), &[]);
        let other = clip(&mut ids, 0, 5, TrackKind::Audio, None, &[]);
        let tracks = vec![
            track(&mut ids, vec![v.clone()], TrackKind::Video),
            track(&mut ids, vec![a], TrackKind::Audio),
            track(&mut ids, vec![other], TrackKind::Audio),
        ];
        let mut tl = timeline(&mut ids, tracks);
        let sel = BTreeSet::from([v.id]);
        assert_eq!(tl.toggle_solo(&sel), Some(true));
        assert_eq!(tl.tracks.iter().map(|t| t.is_solo).collect::<Vec<_>>(), [false, true, false]);
        assert_eq!(tl.toggle_solo(&sel), Some(false));
        assert_eq!(tl.tracks.iter().map(|t| t.is_solo).collect::<Vec<_>>(), [false, false, false]);
    }

    #[test]
    fn video_only_selection_changes_nothing() {
        let mut ids = SequentialIds::default();
        let v = clip(&mut ids, 0, 5, TrackKind::Video, None, &[]);
        let t = track(&mut ids, vec![v.clone()], TrackKind::Video);
        let mut tl = timeline(&mut ids, vec![t]);
        assert_eq!(tl.toggle_solo(&BTreeSet::from([v.id])), None);
    }

    #[test]
    fn trim_to_range_cuts_back_both_ends_and_leaves_clips_inside_alone() {
        use crate::timeline_edits::fixtures as fx;
        let c = fx::clip(0, 20, 0, TrackKind::Video, None, Some(1000));
        let mut tl = fx::timeline(vec![fx::track(TrackKind::Video, vec![c.clone()])]);
        let range = fx::r(5, 15);
        assert_eq!(tl.trim_to_range(&[c.id].into(), range, &mut sq_core_time::SequentialIds::default()), Ok(1));
        assert_eq!(fx::spans(&tl.tracks[0]), [[5, 15]]);

        let (inside, outside) = (fx::v(6, 4), fx::v(30, 4));
        let mut tl = fx::timeline(vec![fx::track(TrackKind::Video, vec![inside.clone(), outside.clone()])]);
        let both = [inside.id, outside.id].into();
        assert_eq!(tl.trim_to_range(&both, range, &mut sq_core_time::SequentialIds::default()), Ok(0));
    }
}
