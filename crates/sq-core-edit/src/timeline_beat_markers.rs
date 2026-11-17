// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+BeatMarkers.swift
//
// Beat markers (Add Beat Markers): ordinary sequence markers named "Beat", so snapping, jumping and the marker list treat
// them like any other. A re-run replaces the beat markers inside the range and leaves everything else alone.

use sq_core_model::{Marker, MarkerColor, Timeline};
use sq_core_time::{IdSource, Time, TimeRange};
use std::collections::BTreeSet;

/// The name of beat markers.
pub const BEAT_MARKER_NAME: &str = "Beat";

/// Add Beat Markers.
pub trait TimelineBeatMarkersExt {
    /// Replaces the beat markers inside `range` (timeline time) with markers at `times`. Times outside the range are
    /// dropped; times are snapped to frames, and a frame that already holds another marker gets none. Returns the number
    /// of markers added.
    fn replace_beat_markers(&mut self, range: TimeRange, times: &[Time], ids: &mut dyn IdSource) -> usize;
}

impl TimelineBeatMarkersExt for Timeline {
    fn replace_beat_markers(&mut self, range: TimeRange, times: &[Time], ids: &mut dyn IdSource) -> usize {
        self.markers.retain(|m| !(m.name == BEAT_MARKER_NAME && range.contains(m.time)));
        let mut taken: BTreeSet<Time> = self.markers.iter().map(|m| m.time).collect();
        let mut sorted = times.to_vec();
        sorted.sort();
        let mut added = 0;
        for t in sorted.into_iter().filter(|t| range.contains(*t)) {
            let frame = t.snapped(self.frame_duration()).max(Time::ZERO);
            if !taken.insert(frame) {
                continue;
            }
            self.markers.push(Marker {
                id: ids.next_id(),
                time: frame,
                name: BEAT_MARKER_NAME.to_string(),
                color: MarkerColor::Cyan,
                comment: String::new(),
                duration: Time::ZERO,
            });
            self.markers.sort_by(|a, b| a.time.cmp(&b.time).then(a.id.cmp(&b.id)));
            added += 1;
        }
        added
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_time::SequentialIds;

    fn range() -> TimeRange {
        TimeRange::new(s(10), s(10))
    }

    fn marker(time: i64, name: &str, id: u128) -> Marker {
        Marker {
            id: sq_core_time::Id::from_u128(id),
            time: s(time),
            name: name.to_string(),
            color: MarkerColor::default(),
            comment: String::new(),
            duration: Time::ZERO,
        }
    }

    #[test]
    fn adds_cyan_beat_markers_at_frame_snapped_times() {
        let mut tl = timeline(vec![]);
        let times = [Time::new(21, 2), Time::new(10003, 1000)];
        assert_eq!(tl.replace_beat_markers(range(), &times, &mut SequentialIds::default()), 2);
        assert!(tl.markers.iter().all(|m| m.name == "Beat" && m.color == MarkerColor::Cyan));
        assert_eq!(tl.markers[0].time, Time::new(10003, 1000).snapped(Time::new(1, 30)));
    }

    #[test]
    fn a_second_run_replaces_the_first_and_keeps_other_markers() {
        let mut tl = timeline(vec![]);
        tl.markers.push(marker(12, "Drop", 7001));
        tl.markers.push(marker(30, "Beat", 7002)); // a beat marker outside the range stays
        let mut ids = SequentialIds::default();
        tl.replace_beat_markers(range(), &[s(10), s(11), s(13)], &mut ids);
        tl.replace_beat_markers(range(), &[s(10), s(12), s(14)], &mut ids);
        let beats: Vec<Time> =
            tl.markers.iter().filter(|m| m.name == "Beat" && range().contains(m.time)).map(|m| m.time).collect();
        assert_eq!(beats, [s(10), s(14)]);
        assert!(tl.markers.iter().any(|m| m.id == sq_core_time::Id::from_u128(7001) && m.name == "Drop"));
        assert!(tl.markers.iter().any(|m| m.id == sq_core_time::Id::from_u128(7002)));
    }

    #[test]
    fn beats_outside_the_range_are_dropped() {
        let mut tl = timeline(vec![]);
        let times = [s(9), s(10), s(19), s(20), s(25)];
        assert_eq!(tl.replace_beat_markers(range(), &times, &mut SequentialIds::default()), 2);
    }

    #[test]
    fn no_beats_still_clears_the_old_ones() {
        let mut tl = timeline(vec![]);
        let mut ids = SequentialIds::default();
        tl.replace_beat_markers(range(), &[s(10), s(11)], &mut ids);
        assert_eq!(tl.replace_beat_markers(range(), &[], &mut ids), 0);
        assert!(tl.markers.is_empty());
    }
}
