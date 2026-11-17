// Swift: MarkerRange.swift
//! Range markers in the ruler (pure): the duration bar and its draggable end.

use crate::timeline_geometry::TimelineGeometry;
use sq_core_edit::snapping::{SnappingTimelineExt, snap};
use sq_core_edit::timeline_beat_snap::{BeatSnapLevel, TimelineBeatSnapExt};
use sq_core_model::{Marker, Timeline};
use sq_core_time::{Id, Time};
use sq_uikit::keyframe_graph_geometry::Rect;
use std::collections::BTreeSet;
use std::ops::RangeInclusive;

/// Range marker helpers.
pub struct MarkerRange;

impl MarkerRange {
    /// Reach of the end handle in points.
    pub const HANDLE_REACH: f64 = 5.0;
    /// Height of the duration bar.
    pub const BAR_HEIGHT: f64 = 4.0;

    /// Vertical band of the ruler where a marker dot or bar end can be grabbed: the 7 pt dot (4 pt above the bottom
    /// edge) plus 3 pt slack. Above it the ruler belongs to the playhead handle, even when a marker sits under the playhead.
    pub fn grab_band(ruler_height: f64) -> RangeInclusive<f64> {
        (ruler_height - 11.0 - 3.0)..=ruler_height
    }

    /// Bar from the marker's start to its end, 4 pt tall at the ruler's bottom edge. `None` for point markers.
    pub fn bar_rect(m: &Marker, geometry: &TimelineGeometry, ruler_height: f64) -> Option<Rect> {
        if m.duration <= Time::ZERO {
            return None;
        }
        let x0 = geometry.x(m.time).round();
        let x1 = geometry.x(m.time + m.duration).round();
        Some(Rect::new(x0, ruler_height - Self::BAR_HEIGHT, (x1 - x0).max(1.0), Self::BAR_HEIGHT))
    }

    /// The range marker whose bar end is within `HANDLE_REACH` of `x` (nearest wins). Point markers have no handle.
    pub fn end_handle(x: f64, markers: &[Marker], geometry: &TimelineGeometry) -> Option<Id> {
        let mut best: Option<(Id, f64)> = None;
        for m in markers.iter().filter(|m| m.duration > Time::ZERO) {
            let d = (geometry.x(m.time + m.duration) - x).abs();
            if d <= Self::HANDLE_REACH && best.is_none_or(|b| d < b.1) {
                best = Some((m.id, d));
            }
        }
        best.map(|b| b.0)
    }

    /// New duration for an end dragged to `drag.time`: at least 0, snapped to other markers, clip edges, the playhead
    /// (and beat markers per `drag.beat_level`) when snapping is on, else the frame grid.
    pub fn duration(drag: &MarkerEndDrag, timeline: &Timeline, geometry: &TimelineGeometry) -> Time {
        let mut end = drag.time.max(drag.start);
        if drag.snapping {
            let mut rest = timeline.clone();
            rest.markers.retain(|m| m.id != drag.marker_id);
            let points =
                rest.snap_points(&BTreeSet::new(), drag.playhead, &rest.marker_snap_times(drag.beat_level, 4), false);
            end = snap(
                end,
                &points,
                geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS),
                Some(timeline.frame_duration()),
            )
            .0;
        } else {
            end = end.snapped(timeline.frame_duration());
        }
        (end - drag.start).max(Time::ZERO)
    }
}

/// An end handle of a range marker dragged to `time`.
#[derive(Clone, Copy, Debug)]
pub struct MarkerEndDrag {
    /// Where the end is dragged to.
    pub time: Time,
    /// The marker's start.
    pub start: Time,
    /// The dragged marker (not a snap target).
    pub marker_id: Id,
    /// Snapping on.
    pub snapping: bool,
    /// Playhead (a snap target).
    pub playhead: Option<Time>,
    /// Which beat markers snap.
    pub beat_level: BeatSnapLevel,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::playhead_logic::PlayheadSnap;
    use crate::test_support::*;
    use sq_core_edit::timeline_beat_markers::TimelineBeatMarkersExt;
    use sq_core_edit::timeline_markers::TimelineMarkersExt;
    use sq_core_model::{SequenceFormat, Timeline};
    use sq_core_time::{SequentialIds, TimeRange};

    fn rig() -> (Timeline, Id, TimelineGeometry) {
        let mut ids = SequentialIds::default();
        let mut t = Timeline::new(uid(), "T", SequenceFormat::new(Time::new(1, 30)), vec![]);
        let beats: Vec<Time> = (1..9).map(|k| Time::new(k, 1)).collect();
        t.replace_beat_markers(TimeRange::new(Time::ZERO, Time::new(20, 1)), &beats, &mut ids);
        let id = t.add_marker(Time::new(10, 1), "Range", &mut ids);
        t.set_marker_duration(id, Time::new(2, 1));
        let g = TimelineGeometry::new(t.frame_duration(), 100.0);
        (t, id, g)
    }

    fn end_drag(t: Time, id: Id, level: BeatSnapLevel) -> MarkerEndDrag {
        MarkerEndDrag { time: t, start: Time::ZERO, marker_id: id, snapping: true, playhead: None, beat_level: level }
    }

    #[test]
    fn bar_spans_duration() {
        let (t, id, g) = rig();
        let m = t.markers.iter().find(|m| m.id == id).unwrap();
        let r = MarkerRange::bar_rect(m, &g, 28.0).unwrap();
        assert_eq!(r.min_x(), g.x(m.time).round());
        assert!(r.width > 1.0);
        let mut point = m.clone();
        point.duration = Time::ZERO;
        assert!(MarkerRange::bar_rect(&point, &g, 28.0).is_none());
    }

    #[test]
    fn end_handle_hits_only_near_end() {
        let (t, id, g) = rig();
        let end_x = g.x(Time::new(12, 1));
        assert_eq!(MarkerRange::end_handle(end_x + 2.0, &t.markers, &g), Some(id));
        assert_eq!(MarkerRange::end_handle(end_x + 40.0, &t.markers, &g), None);
    }

    #[test]
    fn end_snaps_to_bar_downbeat_only() {
        let (t, id, g) = rig();
        // Beats at 1...8; bar downbeats are 1 and 5. Dragging to 5.01 s (start 0 stand-in) lands on 5 in bars mode.
        let bars =
            MarkerRange::duration(&end_drag(Time::new(5, 1) + Time::new(1, 100), id, BeatSnapLevel::BarsOnly), &t, &g);
        assert_eq!(bars, Time::new(5, 1));
        let beat =
            MarkerRange::duration(&end_drag(Time::new(6, 1) + Time::new(1, 100), id, BeatSnapLevel::EveryBeat), &t, &g);
        assert_eq!(beat, Time::new(6, 1));
        let skipped =
            MarkerRange::duration(&end_drag(Time::new(6, 1) + Time::new(1, 25), id, BeatSnapLevel::BarsOnly), &t, &g);
        assert_ne!(skipped, Time::new(6, 1));
    }

    #[test]
    fn playhead_snap_honors_level() {
        let (t, _, g) = rig();
        let at = Time::new(3, 1) + Time::new(1, 60);
        let every = PlayheadSnap::resolve(at, &t, &g, BeatSnapLevel::EveryBeat);
        assert_eq!(every.0, Time::new(3, 1));
        let bars = PlayheadSnap::resolve(at, &t, &g, BeatSnapLevel::BarsOnly);
        assert!(bars.1.is_none());
    }
}
