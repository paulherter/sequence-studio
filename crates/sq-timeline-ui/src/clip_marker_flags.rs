// Swift: ClipMarkerFlags.swift
//! Clip markers on the timeline: a small flag in the marker's color at the bottom edge of the clip. Drawn, hit-tested
//! (nearest flag within `HIT_RADIUS`), dragged along the clip and snapped to like ruler markers.

use crate::timeline_geometry::TimelineGeometry;
use sq_core_edit::clip_markers::ClipMarkersExt;
use sq_core_edit::snapping::{SnapPoint, SnappingTimelineExt, snap};
use sq_core_edit::timeline_clip_markers::TimelineClipMarkersExt;
use sq_core_model::Timeline;
use sq_core_time::{Id, Time};
use sq_uikit::keyframe_graph_geometry::Point;
use std::collections::BTreeSet;

/// The flag under the pointer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ClipMarkerHit {
    /// The clip.
    pub clip: Id,
    /// The marker.
    pub marker: Id,
    /// Sequence time of the flag.
    pub time: Time,
}

/// Clip marker flags.
pub struct ClipMarkerFlags;

impl ClipMarkerFlags {
    /// Flag width.
    pub const FLAG_WIDTH: f64 = 8.0;
    /// Flag height.
    pub const FLAG_HEIGHT: f64 = 7.0;
    /// How far (points) from a flag's pole a press still grabs it.
    pub const HIT_RADIUS: f64 = 5.0;
    /// Height of the strip along the clip's bottom edge where flags are grabbed.
    pub const HIT_STRIP: f64 = 12.0;
    /// Smallest clip width that shows flags.
    pub const MIN_CLIP_WIDTH: f64 = 16.0;

    /// The flag under `point`, `None` when the point is not in the bottom strip of a clip that has flags.
    pub fn hit(point: Point, timeline: &Timeline, geometry: &TimelineGeometry) -> Option<ClipMarkerHit> {
        if point.x < TimelineGeometry::CONTENT_ORIGIN_X {
            return None;
        }
        let row = geometry.rows(timeline).into_iter().find(|r| point.y >= r.y && point.y < r.max_y())?;
        if point.y < row.max_y() - Self::HIT_STRIP {
            return None;
        }
        let track = timeline.track(row.track)?;
        let mut best: Option<(ClipMarkerHit, f64)> = None;
        for c in track.clips().iter().filter(|c| c.markers.as_ref().is_some_and(|m| !m.is_empty())) {
            let w = geometry.x(c.timeline().end()) - geometry.x(c.start);
            if w < Self::MIN_CLIP_WIDTH {
                continue;
            }
            for m in c.visible_markers(timeline.frame_duration()) {
                let t = c.start + m.time;
                let d = (geometry.x(t) - point.x).abs();
                if d <= Self::HIT_RADIUS && best.is_none_or(|b| d < b.1) {
                    best = Some((ClipMarkerHit { clip: c.id, marker: m.id, time: t }, d));
                }
            }
        }
        best.map(|b| b.0)
    }

    /// Where a dragged flag lands: snaps to clip edges, the playhead, In/Out and markers (ruler and other clip flags) when
    /// snapping is on, else the frame grid. The core clamps it into the clip.
    pub fn target(
        time: Time,
        dragging: &ClipMarkerHit,
        timeline: &Timeline,
        playhead: Option<Time>,
        snapping: bool,
        geometry: &TimelineGeometry,
    ) -> (Time, Option<SnapPoint>) {
        let t = time.max(Time::ZERO);
        if !snapping {
            return (t.snapped(timeline.frame_duration()).max(Time::ZERO), None);
        }
        let mut others: Vec<Time> = timeline.markers.iter().map(|m| m.time).collect();
        others.extend(timeline.clip_marker_times());
        if let Some(i) = others.iter().position(|x| *x == dragging.time) {
            others.remove(i);
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use sq_core_model::{Clip, Marker, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};

    const F30: Time = Time::new(1, 30);

    fn setup() -> (Timeline, Clip, TimelineGeometry) {
        let mut c = Clip::new(
            uid(),
            "c",
            uid(),
            TrackKind::Video,
            TimeRange::new(Time::new(2, 1), Time::new(4, 1)),
            Time::new(1, 1),
        );
        c.media_duration = Some(Time::new(20, 1));
        c.markers = Some(vec![Marker {
            id: uid(),
            time: Time::new(3, 1),
            name: "m".to_string(),
            color: Default::default(),
            comment: String::new(),
            duration: Time::ZERO,
        }]); // at sequence time 2 s
        let mut tr = sq_core_model::Track::new(uid(), TrackKind::Video);
        tr.overwrite(c.clone(), &mut SequentialIds::default()).unwrap();
        let tl = Timeline::new(uid(), "T", sq_core_model::SequenceFormat::new(F30), vec![tr]);
        (tl, c, TimelineGeometry::with_points_per_frame(F30, 4.0))
    }

    #[test]
    fn hit_finds_the_flag_in_the_bottom_strip() {
        let (tl, c, g) = setup();
        let row = g.rows(&tl).remove(0);
        let x = g.x(Time::new(2, 1));
        let hit = ClipMarkerFlags::hit(pt(x + 2.0, row.max_y() - 4.0), &tl, &g).unwrap();
        assert_eq!(hit.clip, c.id);
        assert_eq!(Some(hit.marker), c.markers.as_ref().and_then(|m| m.first()).map(|m| m.id));
        assert_eq!(hit.time, Time::new(2, 1));
    }

    #[test]
    fn hit_misses_away_from_the_flag_or_the_strip() {
        let (tl, _, g) = setup();
        let row = g.rows(&tl).remove(0);
        let x = g.x(Time::new(2, 1));
        assert!(ClipMarkerFlags::hit(pt(x + 30.0, row.max_y() - 4.0), &tl, &g).is_none());
        assert!(ClipMarkerFlags::hit(pt(x, row.y + 4.0), &tl, &g).is_none());
    }

    #[test]
    fn clip_markers_are_snap_targets() {
        let (tl, c, g) = setup();
        let near = Time::new(5, 2); // 2.5 s, half a second from the flag at 2 s
        let drag = ClipMarkerHit { clip: c.id, marker: uid(), time: near };
        let r = ClipMarkerFlags::target(Time::new(2, 1) + F30, &drag, &tl, None, true, &g);
        assert_eq!(r.0, Time::new(2, 1));
        let off = ClipMarkerFlags::target(Time::new(2, 1) + F30, &drag, &tl, None, false, &g);
        assert_eq!(off.0, Time::new(2, 1) + F30);
    }
}
