// Swift: Timeline+Navigation.swift
//! Selection navigation and marker clearing used by Select Next/Previous Clip, Go to Selected Clip Start/End,
//! Clear Marker and Clear All Markers.

use sq_core_model::Timeline;
use sq_core_time::{Id, Time, TimeRange};
use std::collections::BTreeSet;

/// `extension Timeline` of Timeline+Navigation.swift.
pub trait TimelineNavigationExt {
    /// The clip after (or before) `id` on the same track; `None` at the end of the track or for an unknown id.
    fn neighbour_clip(&self, id: Id, forward: bool) -> Option<Id>;
    /// Smallest range covering the timeline spans of the given clips; `None` when none of them exists.
    fn extent(&self, ids: &BTreeSet<Id>) -> Option<TimeRange>;
    /// Removes the marker on the frame of `time` (Clear Selected Marker acts on the marker at the playhead).
    fn clear_marker(&mut self, time: Time) -> Option<Id>;
    /// Removes every sequence marker; returns how many there were.
    fn clear_all_markers(&mut self) -> usize;
}

impl TimelineNavigationExt for Timeline {
    fn neighbour_clip(&self, id: Id, forward: bool) -> Option<Id> {
        for track in &self.tracks {
            let Some(i) = track.clips().iter().position(|c| c.id == id) else { continue };
            return if forward { i.checked_add(1) } else { i.checked_sub(1) }
                .and_then(|j| track.clips().get(j))
                .map(|c| c.id);
        }
        None
    }

    fn extent(&self, ids: &BTreeSet<Id>) -> Option<TimeRange> {
        let spans: Vec<TimeRange> =
            self.tracks.iter().flat_map(|t| t.clips()).filter(|c| ids.contains(&c.id)).map(|c| c.timeline()).collect();
        let lo = spans.iter().map(|s| s.start).min()?;
        let hi = spans.iter().map(|s| s.end()).max()?;
        Some(TimeRange::from_end(lo, hi))
    }

    fn clear_marker(&mut self, time: Time) -> Option<Id> {
        let frame = time.snapped(self.frame_duration()).max(Time::ZERO);
        let id = self.markers.iter().find(|m| m.time == frame)?.id;
        self.markers.retain(|m| m.id != id);
        Some(id)
    }

    fn clear_all_markers(&mut self) -> usize {
        let n = self.markers.len();
        self.markers.clear();
        n
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_markers::TimelineMarkersExt;
    use sq_core_model::{Clip, SequenceFormat, Track, TrackKind};
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn timeline() -> (Timeline, Vec<Clip>) {
        let cs: Vec<Clip> = [(0, 2), (2, 3), (8, 2)]
            .iter()
            .enumerate()
            .map(|(i, (st, d))| {
                Clip::new(
                    Id::from_u128(100 + i as u128),
                    "c",
                    Id::from_u128(7),
                    TrackKind::Video,
                    TimeRange::new(s(0), s(*d)),
                    s(*st),
                )
            })
            .collect();
        let mut tr = Track::new(Id::from_u128(10), TrackKind::Video);
        tr.set_clips(cs.clone());
        (Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), vec![tr]), cs)
    }

    #[test]
    fn neighbour_clip_walks_the_same_track() {
        let (t, v) = timeline();
        assert_eq!(t.neighbour_clip(v[0].id, true), Some(v[1].id));
        assert_eq!(t.neighbour_clip(v[1].id, true), Some(v[2].id)); // across a gap
        assert_eq!(t.neighbour_clip(v[2].id, true), None);
        assert_eq!(t.neighbour_clip(v[2].id, false), Some(v[1].id));
        assert_eq!(t.neighbour_clip(v[0].id, false), None);
        assert_eq!(t.neighbour_clip(Id::from_u128(9), true), None);
    }

    #[test]
    fn extent_covers_the_selection() {
        let (t, v) = timeline();
        let set = |ids: &[Id]| ids.iter().copied().collect::<BTreeSet<Id>>();
        assert_eq!(t.extent(&set(&[v[1].id])), Some(TimeRange::new(s(2), s(3))));
        assert_eq!(t.extent(&set(&[v[0].id, v[2].id])), Some(TimeRange::new(s(0), s(10))));
        assert_eq!(t.extent(&set(&[])), None);
        assert_eq!(t.extent(&set(&[Id::from_u128(9)])), None);
    }

    #[test]
    fn clear_marker_removes_only_the_one_on_that_frame() {
        let (mut t, _) = timeline();
        let mut ids = SequentialIds::default();
        t.add_marker(s(1), "", &mut ids);
        t.add_marker(s(2), "", &mut ids);
        assert_eq!(t.clear_marker(Time::new(45, 30)), None); // 1.5 s: no marker there
        assert!(t.clear_marker(s(1)).is_some());
        assert_eq!(t.markers.iter().map(|m| m.time).collect::<Vec<_>>(), vec![s(2)]);
        assert_eq!(t.clear_marker(s(1)), None);
    }

    #[test]
    fn clear_all_markers_counts_and_empties() {
        let (mut t, _) = timeline();
        let mut ids = SequentialIds::default();
        assert_eq!(t.clear_all_markers(), 0);
        t.add_marker(s(1), "", &mut ids);
        t.add_marker(s(2), "", &mut ids);
        assert_eq!(t.clear_all_markers(), 2);
        assert!(t.markers.is_empty());
    }
}
