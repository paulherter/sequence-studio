// Swift: MarkerDrag.swift
//! Dragging a marker flag in the ruler (pure): the new time is clamped at 0, snaps to clip edges, the playhead and the
//! In/Out marks when snapping is on (other markers count too, the dragged one does not), else lands on the frame grid.

use crate::timeline_geometry::TimelineGeometry;
use sq_core_edit::snapping::{SnapPoint, SnappingTimelineExt, snap};
use sq_core_edit::timeline_beat_snap::{BeatSnapLevel, TimelineBeatSnapExt};
use sq_core_model::Timeline;
use sq_core_time::{Id, Time};
use std::collections::BTreeSet;

/// Marker flag drag.
pub struct MarkerDrag;

impl MarkerDrag {
    /// The time the dragged marker `id` lands on and the snap point it hit.
    pub fn target(
        time: Time,
        id: Id,
        timeline: &Timeline,
        playhead: Option<Time>,
        snapping: bool,
        geometry: &TimelineGeometry,
        beat_level: BeatSnapLevel,
    ) -> (Time, Option<SnapPoint>) {
        let t = time.max(Time::ZERO);
        if !snapping {
            return (t.snapped(timeline.frame_duration()).max(Time::ZERO), None);
        }
        let mut rest = timeline.clone();
        rest.markers.retain(|m| m.id != id);
        let others = rest.marker_snap_times(beat_level, 4);
        let points = timeline.snap_points(&BTreeSet::new(), playhead, &others, false);
        let r = snap(
            t,
            &points,
            geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS),
            Some(timeline.frame_duration()),
        );
        (r.0.max(Time::ZERO), r.1)
    }
}
