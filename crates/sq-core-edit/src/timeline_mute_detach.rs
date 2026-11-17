//! Mute of the audio tracks behind a selection.
// Swift: Timeline+MuteDetach.swift

use std::collections::BTreeSet;

use crate::timeline_clipboard::TimelineClipboardExt as _;
use sq_core_model::{EditError, Timeline, TrackKind};
use sq_core_time::Id;

/// Indices of the audio tracks that hold one of `ids` or a clip linked to one of them (also used by Solo).
pub(crate) fn audio_tracks_of_clips(timeline: &Timeline, ids: &BTreeSet<Id>) -> Vec<usize> {
    let links: BTreeSet<Id> =
        timeline.tracks.iter().flat_map(|t| t.clips()).filter(|c| ids.contains(&c.id)).filter_map(|c| c.link).collect();
    let mut touched = Vec::new();
    for (i, t) in timeline.tracks.iter().enumerate() {
        if t.kind == TrackKind::Audio
            && t.clips().iter().any(|c| ids.contains(&c.id) || c.link.is_some_and(|l| links.contains(&l)))
        {
            touched.push(i);
        }
    }
    touched
}

/// Swift `Timeline.toggleMute(forClips:)`.
pub trait TimelineMuteDetachExt {
    /// Mute of the audio tracks that hold the given clips or their linked partners (same reach as `toggle_solo`). All of
    /// them already muted: Mute goes off for them; otherwise it goes on. Returns the new state, None when no audio track
    /// was involved.
    fn toggle_mute(&mut self, ids: &BTreeSet<Id>) -> Option<bool>;

    /// Detach Audio: the audio clips linked to the given video clips lose their link and become independent clips that
    /// stay where they are on the audio track. Returns the detached audio clip ids (empty when nothing was linked).
    /// A locked track fails and the timeline is unchanged.
    fn detach_audio(&mut self, ids: &BTreeSet<Id>) -> Result<Vec<Id>, EditError>;
}

impl TimelineMuteDetachExt for Timeline {
    fn toggle_mute(&mut self, ids: &BTreeSet<Id>) -> Option<bool> {
        let touched = audio_tracks_of_clips(self, ids);
        if touched.is_empty() {
            return None;
        }
        let on = !touched.iter().all(|&i| self.tracks[i].is_muted);
        for i in touched {
            self.tracks[i].is_muted = on;
        }
        Some(on)
    }

    fn detach_audio(&mut self, ids: &BTreeSet<Id>) -> Result<Vec<Id>, EditError> {
        let video_links: BTreeSet<Id> = self
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .flat_map(|t| t.clips())
            .filter(|c| ids.contains(&c.id))
            .filter_map(|c| c.link)
            .collect();
        let audio: Vec<Id> = self
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Audio)
            .flat_map(|t| t.clips())
            .filter(|c| c.link.is_some_and(|l| video_links.contains(&l)))
            .map(|c| c.id)
            .collect();
        if audio.is_empty() {
            return Ok(Vec::new());
        }
        let mut copy = self.clone();
        copy.unlink(&audio.iter().copied().collect())?;
        *self = copy;
        Ok(audio)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track};
    use sq_core_time::{IdSource, SequentialIds, Time, TimeRange};

    fn clip(ids: &mut SequentialIds, start: i64, kind: TrackKind, link: Option<Id>) -> Clip {
        let mut c = Clip::new(
            ids.next_id(),
            "c",
            ids.next_id(),
            kind,
            TimeRange::new(Time::ZERO, Time::new(2, 1)),
            Time::new(start, 1),
        );
        c.link = link;
        c
    }

    fn setup(ids: &mut SequentialIds) -> (Timeline, Clip) {
        let l = ids.next_id();
        let (v, a, plain) = (
            clip(ids, 0, TrackKind::Video, Some(l)),
            clip(ids, 0, TrackKind::Audio, Some(l)),
            clip(ids, 5, TrackKind::Audio, None),
        );
        let mut tracks = vec![
            Track::new(ids.next_id(), TrackKind::Video),
            Track::new(ids.next_id(), TrackKind::Audio),
            Track::new(ids.next_id(), TrackKind::Audio),
        ];
        for (t, c) in tracks.iter_mut().zip([v.clone(), a, plain]) {
            t.overwrite(c, ids).unwrap();
        }
        (Timeline::new(ids.next_id(), "T", SequenceFormat::new(Time::new(1, 30)), tracks), v)
    }

    #[test]
    fn mute_toggles_audio_track_of_clip_and_partner() {
        let mut ids = SequentialIds::default();
        let (mut t, v) = setup(&mut ids);
        let sel = BTreeSet::from([v.id]);
        assert_eq!(t.toggle_mute(&sel), Some(true));
        assert!(t.tracks[1].is_muted && !t.tracks[2].is_muted);
        assert_eq!(t.toggle_mute(&sel), Some(false));
        assert!(!t.tracks[1].is_muted);
        let mut vt = Track::new(ids.next_id(), TrackKind::Video);
        let only = clip(&mut ids, 0, TrackKind::Video, None);
        vt.overwrite(only.clone(), &mut ids).unwrap();
        let mut only_video = Timeline::new(ids.next_id(), "V", SequenceFormat::new(Time::new(1, 30)), vec![vt]);
        assert_eq!(only_video.toggle_mute(&BTreeSet::from([only.id])), None);
    }

    #[test]
    fn detach_audio_unlinks_and_keeps_position_and_a_locked_track_refuses() {
        use crate::timeline_edits::fixtures as fx;
        let l = fx::link();
        let (v, a) =
            (fx::clip(2, 3, 0, TrackKind::Video, Some(l), None), fx::clip(2, 3, 0, TrackKind::Audio, Some(l), None));
        let plain = fx::v(10, 1);
        let mut t = fx::timeline(vec![
            fx::track(TrackKind::Video, vec![v.clone(), plain.clone()]),
            fx::track(TrackKind::Audio, vec![a.clone()]),
        ]);
        assert_eq!(t.detach_audio(&[v.id].into()), Ok(vec![a.id]));
        assert!(t.tracks[0].clips()[0].link.is_none() && t.tracks[1].clips()[0].link.is_none());
        assert_eq!(t.tracks[1].clips()[0].start, a.start);
        assert_eq!(t.detach_audio(&[v.id].into()), Ok(vec![]));
        assert_eq!(t.detach_audio(&[plain.id].into()), Ok(vec![]));

        let mut u = fx::timeline(vec![
            fx::track(TrackKind::Video, vec![v.clone()]),
            fx::locked(fx::track(TrackKind::Audio, vec![a])),
        ]);
        assert!(u.detach_audio(&[v.id].into()).is_err());
        assert!(u.tracks[0].clips()[0].link.is_some());
    }
}
