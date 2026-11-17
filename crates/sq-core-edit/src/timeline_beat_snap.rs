// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+BeatSnap.swift

use sq_core_model::Timeline;
use sq_core_time::{Id, Time};

use crate::timeline_beat_markers::BEAT_MARKER_NAME;

/// Which beat markers act as snap targets.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BeatSnapLevel {
    /// Every beat marker snaps (the default).
    EveryBeat,
    /// Only the first beat of each bar (downbeat) snaps.
    BarsOnly,
}

impl BeatSnapLevel {
    /// The stored text (`everyBeat`, `barsOnly`).
    pub fn raw_value(self) -> &'static str {
        match self {
            BeatSnapLevel::EveryBeat => "everyBeat",
            BeatSnapLevel::BarsOnly => "barsOnly",
        }
    }

    /// The level stored as `raw`.
    pub fn from_raw(raw: &str) -> Option<BeatSnapLevel> {
        match raw {
            "everyBeat" => Some(BeatSnapLevel::EveryBeat),
            "barsOnly" => Some(BeatSnapLevel::BarsOnly),
            _ => None,
        }
    }
}

/// Beat snapping.
pub trait TimelineBeatSnapExt {
    /// Beat marker times in order (markers named `BEAT_MARKER_NAME`).
    fn beat_marker_times(&self) -> Vec<Time>;

    /// Snap candidates from markers: every non-beat marker always, beat markers by `level`.
    // Beat markers carry no bar info, so downbeats are every `beats_per_bar`-th beat marker from the first one (as in Swift).
    fn marker_snap_times(&self, level: BeatSnapLevel, beats_per_bar: usize) -> Vec<Time>;

    /// Sets a marker's duration (clamped at 0, frame grid). False if the id is unknown.
    fn set_marker_duration(&mut self, id: Id, duration: Time) -> bool;
}

impl TimelineBeatSnapExt for Timeline {
    fn beat_marker_times(&self) -> Vec<Time> {
        let mut v: Vec<Time> = self.markers.iter().filter(|m| m.name == BEAT_MARKER_NAME).map(|m| m.time).collect();
        v.sort();
        v
    }

    fn marker_snap_times(&self, level: BeatSnapLevel, beats_per_bar: usize) -> Vec<Time> {
        let mut out: Vec<Time> = self.markers.iter().filter(|m| m.name != BEAT_MARKER_NAME).map(|m| m.time).collect();
        let beats = self.beat_marker_times();
        match level {
            BeatSnapLevel::EveryBeat => out.extend(beats),
            BeatSnapLevel::BarsOnly => {
                let n = beats_per_bar.max(1);
                out.extend(beats.into_iter().enumerate().filter(|(i, _)| i % n == 0).map(|(_, t)| t));
            }
        }
        out
    }

    fn set_marker_duration(&mut self, id: Id, duration: Time) -> bool {
        let d = duration.snapped(self.frame_duration()).max(Time::ZERO);
        match self.markers.iter_mut().find(|m| m.id == id) {
            Some(m) => {
                m.duration = d;
                true
            }
            None => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_beat_markers::TimelineBeatMarkersExt as _;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::{Marker, MarkerColor};
    use sq_core_time::{IdSource as _, SequentialIds, TimeRange};

    fn tl() -> Timeline {
        let mut t = timeline(vec![]);
        let mut ids = SequentialIds::default();
        let beats: Vec<Time> = (0..8).map(s).collect();
        t.replace_beat_markers(TimeRange::new(Time::ZERO, s(20)), &beats, &mut ids);
        t.markers.push(Marker {
            id: ids.next_id(),
            time: Time::new(3, 2),
            name: "Note".to_string(),
            color: MarkerColor::default(),
            comment: String::new(),
            duration: Time::ZERO,
        });
        t.markers.sort_by(|a, b| a.time.cmp(&b.time).then(a.id.cmp(&b.id)));
        t
    }

    #[test]
    fn every_beat_keeps_all() {
        assert_eq!(tl().marker_snap_times(BeatSnapLevel::EveryBeat, 4).len(), 9);
    }

    #[test]
    fn bars_only_keeps_downbeats_and_plain_markers() {
        let mut times = tl().marker_snap_times(BeatSnapLevel::BarsOnly, 4);
        times.sort();
        assert_eq!(times, [Time::ZERO, Time::new(3, 2), s(4)]);
    }

    #[test]
    fn duration_clamps_at_zero() {
        let mut t = tl();
        let id = t.markers[0].id;
        assert!(t.set_marker_duration(id, s(-5)));
        assert_eq!(t.markers.iter().find(|m| m.id == id).map(|m| m.duration), Some(Time::ZERO));
        assert!(t.set_marker_duration(id, s(2)));
        assert_eq!(t.markers.iter().find(|m| m.id == id).map(|m| m.duration), Some(s(2)));
        assert!(!t.set_marker_duration(Id::from_u128(99), s(1)));
    }
}
