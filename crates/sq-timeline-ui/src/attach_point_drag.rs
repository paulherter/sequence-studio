// Swift: AttachPointDrag.swift
//! Fast Cut: dragging the attach thread of an attached clip along its host clip. Pure geometry and snapping; the view
//! previews the drag on a copy of the timeline and commits once on mouse up (one undo step, no clip moves).

use crate::timeline_geometry::TimelineGeometry;
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_model::Timeline;
use sq_core_time::{Id, Time};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};
use std::ops::RangeInclusive;

/// Attach thread drag.
pub struct AttachPointDrag;

impl AttachPointDrag {
    /// Pointer distance (points) within which the attach time snaps to a cut or the playhead.
    const SNAP_REACH: f64 = 8.0;
    /// Half width of the thread's grab zone.
    const GRAB_REACH: f64 = 4.0;

    /// The attached clip whose thread (the line outside the clip plus the triangle on the host edge) lies under `p`, else `None`.
    pub fn hit(p: Point, timeline: &Timeline, geometry: &TimelineGeometry) -> Option<Id> {
        if !timeline.is_fast_cut() {
            return None;
        }
        let mi = timeline.main_track_index()?;
        let rows = geometry.rows(timeline);
        let main = rows.iter().find(|r| r.track == timeline.tracks[mi].id)?;
        for row in rows.iter().filter(|r| r.track != main.track) {
            let Some(track) = timeline.track(row.track).filter(|t| !t.is_locked) else { continue };
            for c in track.clips() {
                let Some(a) = c.attachment.as_ref().filter(|_| timeline.is_attachable(c.id)) else { continue };
                let x = geometry.x(c.start + a.point);
                if (p.x - x).abs() > Self::GRAB_REACH {
                    continue;
                }
                let rect = Rect::new(geometry.x(c.start), row.y, geometry.width(c.timeline().duration), row.height);
                if Self::attach_grab_span(&rect, main.y, main.max_y()).contains(&p.y) {
                    return Some(c.id);
                }
            }
        }
        None
    }

    /// Attach time for a pointer at `x`: kept on the host clip, snapped to a cut of the main track or the playhead
    /// within `SNAP_REACH` (when `snapping`), else to the frame grid.
    pub fn target(
        x: f64,
        id: Id,
        timeline: &Timeline,
        geometry: &TimelineGeometry,
        playhead: Time,
        snapping: bool,
    ) -> Option<Time> {
        let mi = timeline.main_track_index()?;
        let a = timeline.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id)?.attachment.as_ref()?;
        let host = timeline.tracks[mi].clips().iter().find(|c| c.id == a.host)?;
        let fd = timeline.frame_duration();
        let mut t = geometry.unsnapped_time(x).snapped(fd);
        if snapping {
            let mut cuts = vec![playhead];
            for c in timeline.tracks[mi].clips() {
                cuts.push(c.start);
                cuts.push(c.timeline().end());
            }
            let mut best: Option<(Time, f64)> = None;
            for c in cuts {
                let d = (geometry.x(c) - x).abs();
                if best.is_none_or(|b| d < b.1) {
                    best = Some((c, d));
                }
            }
            if let Some(best) = best
                && best.1 <= Self::SNAP_REACH
            {
                t = best.0;
            }
        }
        let hi = (host.timeline().end() - fd).max(host.start);
        Some(t.max(host.start).min(hi))
    }

    /// Vertical span (view y) where a pointer grabs the attach marker: the thread plus the triangle on the host edge.
    pub fn attach_grab_span(clip_rect: &Rect, host_min_y: f64, host_max_y: f64) -> RangeInclusive<f64> {
        let above = clip_rect.mid_y() < (host_min_y + host_max_y) / 2.0;
        let from = if above { clip_rect.max_y() } else { clip_rect.min_y() };
        let edge = if above { host_min_y } else { host_max_y };
        let depth = 6.0;
        if above { (from.min(edge) - 1.0)..=(edge + depth) } else { (edge - depth)..=(from.max(edge) + 1.0) }
    }
}
