// Swift: TransitionLayerLayout.swift
//! Transition layer geometry on the timeline: drop target, center marker and hit zones. Pure.

use crate::timeline_geometry::TimelineGeometry;
use sq_core_effects::transition_layer::{ClipTransitionLayer, TransitionKindLayer};
use sq_core_model::{Timeline, TrackKind, TransitionKind};
use sq_core_time::{Id, Time};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

/// Where a transition dropped on an empty track spot becomes a transition layer.
#[derive(Clone, Debug, PartialEq)]
pub struct TransitionLayerDropTarget {
    /// The track.
    pub track: Id,
    /// Start of the layer clip.
    pub start: Time,
    /// Length of the layer clip.
    pub duration: Time,
    /// The cut (center marker) on the timeline.
    pub cut: Time,
    /// Highlight box in view coordinates.
    pub rect: Rect,
    /// An Adjustment Layer drop: no center marker (there is no cut).
    pub adjustment: bool,
}

/// The part of a transition layer clip under the pointer that has its own drag.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransitionLayerZone {
    /// The center marker: moves the cut (the split between lead-in and lead-out).
    Cut,
    /// The start end: resizes symmetrically around the cut (Option = this end only).
    Head,
    /// The finish end: resizes symmetrically around the cut (Option = this end only).
    Tail,
}

/// A transition layer clip under the pointer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TransitionLayerHit {
    /// The layer clip.
    pub id: Id,
    /// Its track.
    pub track: Id,
    /// The zone.
    pub zone: TransitionLayerZone,
}

/// Transition layer geometry.
pub struct TransitionLayerLayout;

impl TransitionLayerLayout {
    /// Pointer distance (points) within which the cut snaps to an edit below or the playhead.
    const SNAP_REACH: f64 = 8.0;
    /// Half width of the center marker's grab zone.
    const MARKER_REACH: f64 = 5.0;

    /// Width of an end's grab zone (at most a quarter of the box).
    fn edge_width(w: f64) -> f64 {
        8.0_f64.min(w / 4.0)
    }

    /// Edit points the cut snaps to: clip starts and ends on the video tracks below `track`, and the playhead.
    pub fn snap_times(track: Id, timeline: &Timeline, playhead: Time) -> Vec<Time> {
        let Some(k) = timeline.tracks.iter().position(|t| t.id == track) else { return vec![playhead] };
        let mut out = vec![playhead];
        for tr in timeline.tracks[..k].iter().filter(|t| t.kind == TrackKind::Video) {
            for c in tr.clips().iter().filter(|c| !c.is_transition_layer()) {
                out.push(c.start);
                out.push(c.timeline().end());
            }
        }
        out
    }

    /// `t` moved onto the nearest snap time within `SNAP_REACH`, else onto the frame grid.
    pub fn snapped(t: Time, times: &[Time], geometry: &TimelineGeometry) -> Time {
        let x = geometry.x(t);
        let mut best: Option<(Time, f64)> = None;
        for s in times {
            let d = (geometry.x(*s) - x).abs();
            if best.is_none_or(|b| d < b.1) {
                best = Some((*s, d));
            }
        }
        if let Some(best) = best
            && best.1 <= Self::SNAP_REACH
        {
            return best.0;
        }
        t.snapped(geometry.frame_duration)
    }

    /// A layer kind dropped at `p` on an unlocked video track where no clip is: `duration` (whole frames) centered on the
    /// pointer, whose time snaps to an edit below or the playhead, fitted into the gap (shortened when the gap is smaller).
    /// `None` on a clip, another track kind or a kind that cannot be a layer.
    pub fn drop_target(
        p: Point,
        kind: TransitionKind,
        timeline: &Timeline,
        geometry: &TimelineGeometry,
        playhead: Time,
        duration: Time,
    ) -> Option<TransitionLayerDropTarget> {
        if !kind.is_layer_kind() {
            return None;
        }
        Self::gap_target(p, timeline, geometry, playhead, duration)
    }

    /// An Adjustment Layer dropped at `p`: the empty spot on the video track under the pointer (`drop_target`'s rules);
    /// over a clip it goes on the video track directly above, when that is free there.
    pub fn adjustment_drop_target(
        p: Point,
        timeline: &Timeline,
        geometry: &TimelineGeometry,
        playhead: Time,
        duration: Time,
    ) -> Option<TransitionLayerDropTarget> {
        let found = Self::gap_target(p, timeline, geometry, playhead, duration).or_else(|| {
            let rows = geometry.rows(timeline);
            let k = rows.iter().position(|r| p.y >= r.y && p.y < r.max_y())?;
            let above = rows.get(k.checked_sub(1)?)?;
            Self::gap_target(Point::new(p.x, above.y + 1.0), timeline, geometry, playhead, duration)
        });
        found.map(|t| TransitionLayerDropTarget { adjustment: true, ..t })
    }

    fn gap_target(
        p: Point,
        timeline: &Timeline,
        geometry: &TimelineGeometry,
        playhead: Time,
        duration: Time,
    ) -> Option<TransitionLayerDropTarget> {
        if p.x < TimelineGeometry::CONTENT_ORIGIN_X {
            return None;
        }
        let row = geometry.rows(timeline).into_iter().find(|r| p.y >= r.y && p.y < r.max_y())?;
        if row.kind != TrackKind::Video {
            return None;
        }
        let track = timeline.track(row.track).filter(|t| !t.is_locked)?;
        let fd = timeline.format.frame_duration;
        let at = Time::ZERO.max(geometry.unsnapped_time(p.x));
        if track.clips().iter().any(|c| c.timeline().contains(at)) {
            return None;
        }
        let gap_start = track
            .clips()
            .iter()
            .filter(|c| c.timeline().end() <= at)
            .map(|c| c.timeline().end())
            .max()
            .unwrap_or(Time::ZERO);
        let gap_end = track.clips().iter().filter(|c| c.start > at).map(|c| c.start).min();
        let mut cut = Self::snapped(at, &Self::snap_times(track.id, timeline, playhead), geometry);
        cut = cut.max(gap_start);
        if let Some(gap_end) = gap_end {
            cut = cut.min(gap_end);
        }
        let mut d = duration.snapped(fd).max(fd);
        if let Some(gap_end) = gap_end {
            d = d.min(gap_end - gap_start);
        }
        if d < fd {
            return None;
        }
        let mut start = cut - fd * (d.frame_index(fd) / 2);
        if let Some(gap_end) = gap_end {
            start = start.min(gap_end - d);
        }
        start = start.max(gap_start);
        Some(TransitionLayerDropTarget {
            track: track.id,
            start,
            duration: d,
            cut,
            rect: Rect::new(geometry.x(start), row.y + 1.0, geometry.width(d), (row.height - 2.0).max(1.0)),
            adjustment: false,
        })
    }

    /// The transition layer clip and zone under `p` (center marker first, then the ends), or `None`.
    pub fn hit_test(p: Point, timeline: &Timeline, geometry: &TimelineGeometry) -> Option<TransitionLayerHit> {
        let row = geometry.rows(timeline).into_iter().find(|r| p.y >= r.y && p.y < r.max_y())?;
        if row.kind != TrackKind::Video {
            return None;
        }
        let track = timeline.track(row.track).filter(|t| !t.is_locked)?;
        let fd = timeline.format.frame_duration;
        for c in track.clips().iter().filter(|c| c.is_transition_layer()) {
            let Some(r) = c.resolved_transition_layer(fd) else { continue };
            let x0 = geometry.x(r.span.start);
            let x1 = geometry.x(r.span.end());
            if !(p.x >= x0 && p.x <= x1) {
                continue;
            }
            let hit = |zone| Some(TransitionLayerHit { id: c.id, track: track.id, zone });
            if (p.x - geometry.x(r.cut)).abs() <= Self::MARKER_REACH {
                return hit(TransitionLayerZone::Cut);
            }
            let e = Self::edge_width(x1 - x0);
            if p.x <= x0 + e {
                return hit(TransitionLayerZone::Head);
            }
            if p.x >= x1 - e {
                return hit(TransitionLayerZone::Tail);
            }
        }
        None
    }
}
