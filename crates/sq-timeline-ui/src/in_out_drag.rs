// Swift: InOutDrag.swift
//! Dragging the In/Out band in the ruler: the ends trim, the middle moves the whole range. Pure math.

use crate::timeline_geometry::TimelineGeometry;
use sq_core_edit::source_edit_placement::MarkedRangeDragPart;
use sq_core_time::{Time, TimeRange};

/// Which part of the In/Out band is dragged.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InOutPart {
    /// The In edge.
    Start,
    /// The Out edge.
    End,
    /// The whole band.
    Body,
}

impl InOutPart {
    /// The part the edit logic needs so an In-only or Out-only mark is never inferred from the range.
    pub fn marked_part(self) -> MarkedRangeDragPart {
        match self {
            InOutPart::Start => MarkedRangeDragPart::InEdge,
            InOutPart::End => MarkedRangeDragPart::OutEdge,
            InOutPart::Body => MarkedRangeDragPart::Body,
        }
    }
}

/// In/Out band drag math.
pub struct InOutDrag;

impl InOutDrag {
    /// Pointer distance from an end that still grabs the end (the band's 2 pt edge plus slack).
    pub const EDGE_ZONE: f64 = 5.0;

    /// Which part of the band the pointer at `x` grabs; `None` outside the band (ends reach `EDGE_ZONE` past it).
    pub fn part(x: f64, range: &TimeRange, geometry: &TimelineGeometry) -> Option<InOutPart> {
        let x0 = geometry.x(range.start);
        let x1 = geometry.x(range.end());
        if !(x >= x0 - Self::EDGE_ZONE && x <= x1 + Self::EDGE_ZONE) {
            return None;
        }
        if x1 - x0 <= 2.0 * Self::EDGE_ZONE {
            // a narrow band: split in halves, no body
            return Some(if x < (x0 + x1) / 2.0 { InOutPart::Start } else { InOutPart::End });
        }
        if x <= x0 + Self::EDGE_ZONE {
            return Some(InOutPart::Start);
        }
        if x >= x1 - Self::EDGE_ZONE {
            return Some(InOutPart::End);
        }
        Some(InOutPart::Body)
    }

    /// The range after dragging `part` of `original` from `down_time` to `time` (frame aligned by the caller). Never before
    /// zero, never shorter than one frame; a moved body keeps its length.
    pub fn target(
        part: InOutPart,
        original: &TimeRange,
        down_time: Time,
        time: Time,
        frame_duration: Time,
    ) -> TimeRange {
        match part {
            InOutPart::Start => {
                let s = time.max(Time::ZERO).min(original.end() - frame_duration);
                TimeRange::from_end(s, original.end())
            }
            InOutPart::End => {
                let e = time.max(original.start + frame_duration);
                TimeRange::from_end(original.start, e)
            }
            InOutPart::Body => {
                let s = (original.start + (time - down_time)).max(Time::ZERO);
                TimeRange::new(s, original.duration)
            }
        }
    }
}
