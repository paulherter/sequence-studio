// Swift: Timeline+FollowSelection.swift
//! "Selection follows playhead": which clips the playhead is over on the targeted tracks, and how long that answer
//! stays valid (so a playing playhead only re-asks at a clip boundary).

use sq_core_model::Timeline;
use sq_core_time::{Id, Time};
use std::collections::BTreeSet;

/// The clips under the playhead on the targeted tracks and the span the answer holds for.
#[derive(Clone, Debug, PartialEq)]
pub struct PlayheadFollow {
    /// Clips under the playhead, one per targeted track at most. Linked partners are added by the caller.
    pub ids: BTreeSet<Id>,
    /// The answer holds for every time in `valid_from ..< valid_until`.
    pub valid_from: Time,
    /// `None` = no later boundary on any targeted track.
    pub valid_until: Option<Time>,
}

impl PlayheadFollow {
    /// True while `t` is inside the span the answer holds for.
    pub fn covers(&self, t: Time) -> bool {
        t >= self.valid_from && self.valid_until.is_none_or(|u| t < u)
    }
}

/// `extension Timeline` of Timeline+FollowSelection.swift.
pub trait TimelineFollowSelectionExt {
    /// The clip under `t` on every targeted track (untargeted tracks never take part). Nothing targeted or empty space
    /// gives an empty set.
    fn followed_clips(&self, t: Time) -> PlayheadFollow;
}

impl TimelineFollowSelectionExt for Timeline {
    fn followed_clips(&self, t: Time) -> PlayheadFollow {
        let mut ids = BTreeSet::new();
        let mut from = Time::ZERO;
        let mut until: Option<Time> = None;
        let mut narrow = |lo: Option<Time>, hi: Option<Time>| {
            if let Some(lo) = lo.filter(|lo| *lo > from) {
                from = lo;
            }
            if let Some(hi) = hi.filter(|hi| until.is_none_or(|u| *hi < u)) {
                until = Some(hi);
            }
        };
        for track in self.tracks.iter().filter(|t| t.is_targeted) {
            let mut hit = None;
            let mut prev_end: Option<Time> = None;
            let mut next_start: Option<Time> = None;
            for c in track.clips() {
                let r = c.timeline();
                if r.start <= t && t < r.end() {
                    hit = Some(c);
                    break;
                }
                if r.end() <= t {
                    if prev_end.is_none_or(|p| r.end() > p) {
                        prev_end = Some(r.end());
                    }
                } else if r.start > t && next_start.is_none_or(|n| r.start < n) {
                    next_start = Some(r.start);
                }
            }
            if let Some(hit) = hit {
                ids.insert(hit.id);
                narrow(Some(hit.timeline().start), Some(hit.timeline().end()));
            } else {
                narrow(prev_end, next_start);
            }
        }
        PlayheadFollow { ids, valid_from: from, valid_until: until }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track, TrackKind};
    use sq_core_time::TimeRange;

    fn fd() -> Time {
        Time::new(1, 24)
    }
    fn clip(n: u128, s: i64, len: i64, kind: TrackKind) -> Clip {
        Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(n + 5000),
            kind,
            TimeRange::new(Time::ZERO, fd() * len),
            fd() * s,
        )
    }
    fn track(n: u128, kind: TrackKind, clips: Vec<Clip>, targeted: bool) -> Track {
        let mut t = Track::new(Id::from_u128(n), kind);
        t.set_clips(clips);
        t.is_targeted = targeted;
        t
    }
    fn tl(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(fd()), tracks)
    }
    fn set(ids: &[Id]) -> BTreeSet<Id> {
        ids.iter().copied().collect()
    }

    #[test]
    fn targeted_tracks_only() {
        let (a, b, c) =
            (clip(1, 0, 10, TrackKind::Video), clip(2, 0, 10, TrackKind::Video), clip(3, 0, 10, TrackKind::Audio));
        let t = tl(vec![
            track(10, TrackKind::Video, vec![a.clone()], true),
            track(11, TrackKind::Video, vec![b], false),
            track(12, TrackKind::Audio, vec![c.clone()], true),
        ]);
        assert_eq!(t.followed_clips(fd() * 3).ids, set(&[a.id, c.id]));
    }

    #[test]
    fn nothing_targeted_selects_nothing() {
        let t = tl(vec![track(10, TrackKind::Video, vec![clip(1, 0, 10, TrackKind::Video)], false)]);
        assert!(t.followed_clips(fd() * 3).ids.is_empty());
    }

    #[test]
    fn gap_and_boundaries() {
        let (a, b) = (clip(1, 0, 10, TrackKind::Video), clip(2, 20, 10, TrackKind::Video));
        let t = tl(vec![track(10, TrackKind::Video, vec![a.clone(), b.clone()], true)]);
        let in_a = t.followed_clips(fd() * 9);
        assert!(in_a.ids == set(&[a.id]) && in_a.covers(Time::ZERO) && !in_a.covers(fd() * 10));
        let gap = t.followed_clips(fd() * 10);
        assert!(gap.ids.is_empty() && gap.valid_from == fd() * 10 && gap.valid_until == Some(fd() * 20));
        assert_eq!(t.followed_clips(fd() * 20).ids, set(&[b.id]));
        let after = t.followed_clips(fd() * 30);
        assert!(after.ids.is_empty() && after.valid_until.is_none());
    }

    #[test]
    fn range_is_intersection_of_tracks() {
        let t = tl(vec![
            track(10, TrackKind::Video, vec![clip(1, 0, 10, TrackKind::Video)], true),
            track(11, TrackKind::Video, vec![clip(2, 5, 10, TrackKind::Video)], true),
        ]);
        let r = t.followed_clips(fd() * 7);
        assert!(r.valid_from == fd() * 5 && r.valid_until == Some(fd() * 10));
    }
}
