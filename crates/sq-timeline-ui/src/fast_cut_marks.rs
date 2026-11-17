// Swift: FastCutMarks.swift
//! Fast Cut geometry the timeline draws (attach hosts, spacers, attach threads), portable for the shared toolkit
//! timeline.

use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_model::{Timeline, Track};
use sq_core_time::{Id, Time, TimeRange};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};
use std::collections::BTreeSet;

/// Where the attach thread runs and the triangle that ends it.
#[derive(Clone, Debug, PartialEq)]
pub struct AttachThread {
    /// Start of the line.
    pub from: Point,
    /// End of the line.
    pub to: Point,
    /// The triangle on the host edge.
    pub triangle: [Point; 3],
}

/// Fast Cut marks.
pub struct FastCutMarks;

impl FastCutMarks {
    /// Fast Cut: the main-track clips the selected attached clips are attached to (their host highlight). Empty outside
    /// Fast Cut.
    pub fn attach_hosts(selection: &BTreeSet<Id>, t: &Timeline) -> BTreeSet<Id> {
        if !t.is_fast_cut() || selection.is_empty() {
            return BTreeSet::new();
        }
        t.tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| selection.contains(&c.id))
            .filter_map(|c| c.attachment.as_ref().map(|a| a.host))
            .collect()
    }

    /// Fast Cut spacers: the holes of the main track before its last clip (time ranges), empty outside Fast Cut.
    pub fn spacers(t: &Timeline) -> Vec<TimeRange> {
        if !t.is_fast_cut() {
            return Vec::new();
        }
        match t.main_track_index() {
            Some(mi) => Self::spacers_on(&t.tracks[mi]),
            None => Vec::new(),
        }
    }

    /// The holes of one (main) track as drawn, e.g. the live preview of a drag.
    pub fn spacers_on(track: &Track) -> Vec<TimeRange> {
        let mut out = Vec::new();
        let mut end = Time::ZERO;
        for c in track.clips() {
            if c.start > end {
                out.push(TimeRange::from_end(end, c.start));
            }
            end = end.max(c.timeline().end());
        }
        out
    }

    /// Where the attach thread of an attached clip runs (Fast Cut): a vertical line at the attach point `x` from the
    /// attached clip's near edge to the host's row on the main track (`host_min_y`...`host_max_y`), ending in a small
    /// triangle on the host edge that points into the host. `None` when the clip touches the host row.
    pub fn attach_thread_geometry(clip_rect: &Rect, x: f64, host_min_y: f64, host_max_y: f64) -> Option<AttachThread> {
        let above = clip_rect.mid_y() < (host_min_y + host_max_y) / 2.0; // attached clip above the host: the thread runs down
        let from = if above { clip_rect.max_y() } else { clip_rect.min_y() };
        let to = if above { host_min_y } else { host_max_y };
        if (to - from).abs() < 1.0 {
            return None;
        }
        let s = 3.0;
        let tip = if above { to + s + 1.0 } else { to - s - 1.0 };
        Some(AttachThread {
            from: Point::new(x, from),
            to: Point::new(x, to),
            triangle: [Point::new(x, tip), Point::new(x - s, to), Point::new(x + s, to)],
        })
    }

    /// The marker alone (no thread) for a clip whose row touches the host row: a triangle on the shared edge pointing
    /// into the host. `None` when the clip is not next to the host.
    pub fn attach_marker(clip_rect: &Rect, x: f64, host_min_y: f64, host_max_y: f64) -> Option<AttachThread> {
        let above = clip_rect.mid_y() < (host_min_y + host_max_y) / 2.0;
        let edge = if above { host_min_y } else { host_max_y };
        if ((if above { clip_rect.max_y() } else { clip_rect.min_y() }) - edge).abs() >= 1.0 {
            return None;
        }
        let s = 3.0;
        let tip = if above { edge + s + 1.0 } else { edge - s - 1.0 };
        Some(AttachThread {
            from: Point::new(x, edge),
            to: Point::new(x, edge),
            triangle: [Point::new(x, tip), Point::new(x - s, edge), Point::new(x + s, edge)],
        })
    }
}
