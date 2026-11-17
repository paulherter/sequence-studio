// Swift: Timeline+MatchFrame.swift
//! A clip frame matched back to its media (F) and the way back (Shift+R).

use sq_core_model::{Clip, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time};
use std::collections::BTreeSet;

/// The clip and media time that the playhead shows.
#[derive(Clone, Debug, PartialEq)]
pub struct MatchedFrame {
    /// The clip under the playhead.
    pub clip: Clip,
    /// Its media.
    pub media: Id,
    /// Time inside the media that the playhead shows.
    pub source_time: Time,
}

/// `extension Timeline` of Timeline+MatchFrame.swift.
pub trait TimelineMatchFrameExt {
    /// Match Frame: the clip the Source Monitor should load for the playhead `t`. A selected clip under the playhead
    /// wins, then the topmost targeted track, then the topmost video track, then any audio track. Generators and
    /// nested sequences have no media to match and are skipped.
    fn match_frame(&self, t: Time, selected: &BTreeSet<Id>) -> Option<MatchedFrame>;
    /// Reverse Match Frame: the sequence time that shows `source_time` of `media`. Prefers a selected clip, then one under
    /// the playhead, then the clip whose used range is nearest to the playhead. `None` when the media is not used there.
    fn reverse_match_frame(
        &self,
        media: Id,
        source_time: Time,
        playhead: Time,
        selected: &BTreeSet<Id>,
    ) -> Option<Time>;
}

fn hit_at(track: &Track, t: Time) -> Option<&Clip> {
    track.clips().iter().find(|c| c.timeline().contains(t) && !c.is_generator() && !c.is_nested())
}

fn distance(a: Time, b: Time) -> Time {
    let d = a - b;
    if d.is_negative() { -d } else { d }
}

impl TimelineMatchFrameExt for Timeline {
    fn match_frame(&self, t: Time, selected: &BTreeSet<Id>) -> Option<MatchedFrame> {
        let fd = self.frame_duration();
        let frame = |c: &Clip| MatchedFrame { clip: c.clone(), media: c.media, source_time: c.source_time(t, fd) };
        if !selected.is_empty() {
            for tr in self.tracks.iter().rev() {
                if let Some(c) = hit_at(tr, t).filter(|c| selected.contains(&c.id)) {
                    return Some(frame(c));
                }
            }
        }
        let ordered: Vec<&Track> = self
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .rev()
            .chain(self.tracks.iter().filter(|t| t.kind == TrackKind::Audio))
            .collect();
        for tr in ordered.iter().filter(|t| t.is_targeted) {
            if let Some(c) = hit_at(tr, t) {
                return Some(frame(c));
            }
        }
        ordered.iter().find_map(|tr| hit_at(tr, t)).map(frame)
    }

    fn reverse_match_frame(
        &self,
        media: Id,
        source_time: Time,
        playhead: Time,
        selected: &BTreeSet<Id>,
    ) -> Option<Time> {
        let fd = self.frame_duration();
        let all: Vec<&Clip> = self
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|c| {
                c.media == media
                    && !c.is_generator()
                    && !c.is_nested()
                    && c.source.start <= source_time
                    && source_time < c.source.end()
            })
            .collect();
        let at = |c: &Clip| c.timeline_time_for_source(source_time, fd);
        let pick = all
            .iter()
            .find(|c| selected.contains(&c.id))
            .or_else(|| all.iter().find(|c| c.timeline().contains(playhead)))
            .or_else(|| {
                // Swift `min(by:)` keeps the first of equals.
                let mut best: Option<&&Clip> = None;
                for c in &all {
                    if best.is_none_or(|b| distance(at(c), playhead) < distance(at(b), playhead)) {
                        best = Some(c);
                    }
                }
                best
            });
        pick.map(|c| at(c))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::SequenceFormat;
    use sq_core_time::TimeRange;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn clip(n: u128, start: i64, dur: i64, src: i64, media: u128) -> Clip {
        Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(media),
            TrackKind::Video,
            TimeRange::new(s(src), s(dur)),
            s(start),
        )
    }
    fn track(n: u128, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(Id::from_u128(n), TrackKind::Video);
        t.set_clips(clips);
        t
    }
    fn tl(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }
    fn none() -> BTreeSet<Id> {
        BTreeSet::new()
    }

    #[test]
    fn matches_topmost_clip_and_maps_source_time() {
        let t = tl(vec![track(10, vec![clip(1, 0, 10, 5, 71)]), track(11, vec![clip(2, 4, 4, 1, 72)])]);
        let top = t.match_frame(s(5), &none());
        assert_eq!(top.map(|m| (m.media, m.source_time)), Some((Id::from_u128(72), s(2))));
        let low = t.match_frame(s(2), &none());
        assert_eq!(low.map(|m| (m.media, m.source_time)), Some((Id::from_u128(71), s(7))));
        assert!(t.match_frame(s(20), &none()).is_none());
    }

    #[test]
    fn selected_clip_wins() {
        let a = clip(1, 0, 10, 0, 71);
        let t = tl(vec![track(10, vec![a.clone()]), track(11, vec![clip(2, 0, 10, 0, 72)])]);
        let sel: BTreeSet<Id> = [a.id].into_iter().collect();
        assert_eq!(t.match_frame(s(3), &sel).map(|m| m.media), Some(Id::from_u128(71)));
    }

    #[test]
    fn reverse_match_finds_clip_using_that_frame() {
        let t = tl(vec![track(10, vec![clip(1, 0, 4, 0, 71), clip(2, 10, 4, 2, 71)])]);
        let m = Id::from_u128(71);
        // Source second 3 is used by both clips (0..4 and 2..6): the playhead decides.
        assert_eq!(t.reverse_match_frame(m, s(3), s(11), &none()), Some(s(11)));
        assert_eq!(t.reverse_match_frame(m, s(3), s(1), &none()), Some(s(3)));
        assert_eq!(t.reverse_match_frame(m, s(9), s(1), &none()), None);
    }

    #[test]
    fn reverse_match_picks_nearest_clip_across_timescales() {
        // Candidate A maps source 0 to 3 s, candidate B to 2.5 s (timescale 2). Playhead 0: B is nearer.
        let mut b = clip(2, 0, 1, 0, 71);
        b.start = Time::new(5, 2);
        let t = tl(vec![track(10, vec![clip(1, 3, 1, 0, 71)]), track(11, vec![b])]);
        assert_eq!(t.reverse_match_frame(Id::from_u128(71), s(0), s(0), &none()), Some(Time::new(5, 2)));
    }
}
