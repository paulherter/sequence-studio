// Swift: KeystoneBar.swift
//! The bar of the keystone applied last, drawn along the bottom of its clip in the timeline; its edges stretch it.
//! Portable: the Mac view and the shared-toolkit timeline panel read the same geometry.

use crate::timeline_geometry::{TimelineGeometry, TrackRow};
use sq_core_effects::keystone::{Keystone, KeystoneSpan};
use sq_core_model::Clip;
use sq_core_time::{Id, Time};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

/// Keystone drags as a string: the payload JSON (self-contained, so the drop ghost knows its length). The Mac puts it on
/// the pasteboard, the shared toolkit hands it to the timeline panel directly.
pub struct KeystoneDrag;

impl KeystoneDrag {
    /// The drag string of a keystone.
    pub fn string(keystone: &Keystone) -> Option<String> {
        keystone.payload().ok().and_then(|d| String::from_utf8(d).ok())
    }

    /// The keystone in a drag string.
    pub fn keystone(s: &str) -> Option<Keystone> {
        Keystone::from_payload(s.as_bytes(), Keystone::PAYLOAD_VERSION).ok()
    }
}

/// Which edge of the bar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeystoneEdge {
    /// The start edge.
    Start,
    /// The end edge.
    End,
}

/// The bar of the keystone applied last.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeystoneBar {
    /// The clip.
    pub clip: Id,
    /// Where the keystone sits on the clip.
    pub span: KeystoneSpan,
    /// Shown name.
    pub name: String,
}

impl KeystoneBar {
    /// Bar height.
    pub const HEIGHT: f64 = 12.0;
    /// Grab distance of an edge.
    pub const EDGE_SLOP: f64 = 5.0;
    /// Rows lower than this show no bar (too little room above the clip name).
    pub const MINIMUM_ROW_HEIGHT: f64 = 34.0;

    /// The bar inside a clip drawn in `row` (bottom strip).
    pub fn rect(span: &KeystoneSpan, clip_start: Time, row: &TrackRow, geometry: &TimelineGeometry) -> Rect {
        let x0 = geometry.x(clip_start + span.start);
        let x1 = geometry.x(clip_start + span.end());
        Rect::new(x0, row.max_y() - Self::HEIGHT - 2.0, (x1 - x0).max(2.0), Self::HEIGHT)
    }

    /// Which edge of the bar is under `p` (a few points either side; within the bar's height).
    pub fn edge(p: Point, bar_rect: &Rect) -> Option<KeystoneEdge> {
        if !(p.y >= bar_rect.min_y() - 2.0 && p.y <= bar_rect.max_y() + 2.0) {
            return None;
        }
        if (p.x - bar_rect.min_x()).abs() <= Self::EDGE_SLOP {
            return Some(KeystoneEdge::Start);
        }
        if (p.x - bar_rect.max_x()).abs() <= Self::EDGE_SLOP {
            return Some(KeystoneEdge::End);
        }
        None
    }

    /// `span` with `edge` dragged to clip-local `t`: the other edge stays, the result stays inside the clip and is at least
    /// `minimum` long.
    pub fn dragged(
        span: &KeystoneSpan,
        edge: KeystoneEdge,
        t: Time,
        clip_duration: Time,
        minimum: Time,
    ) -> KeystoneSpan {
        let mut r = span.clone();
        match edge {
            KeystoneEdge::End => {
                let end = t.max(span.start + minimum).min(clip_duration.max(span.start + minimum));
                r.duration = end - span.start;
            }
            KeystoneEdge::Start => {
                let start = t.min(span.end() - minimum).max(Time::ZERO);
                r.start = start;
                r.duration = span.end() - start;
            }
        }
        r
    }
}

/// State of one keystone edge drag.
#[derive(Clone, Debug, PartialEq)]
pub struct KeystoneEdgeDrag {
    /// The bar being dragged.
    pub bar: KeystoneBar,
    /// The grabbed edge.
    pub edge: KeystoneEdge,
    /// The clip before the drag: every update restretches from it, so the preview never accumulates rounding.
    pub original: Clip,
    /// The span now.
    pub current: KeystoneSpan,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    fn span(start: i64, dur: i64) -> KeystoneSpan {
        KeystoneSpan { start: Time::seconds(start), duration: Time::seconds(dur), properties: BTreeSet::new() }
    }

    #[test]
    fn dragging_an_edge_keeps_the_other_and_the_minimum() {
        let s = span(2, 4);
        let end = KeystoneBar::dragged(&s, KeystoneEdge::End, Time::seconds(9), Time::seconds(8), Time::new(1, 2));
        assert_eq!(end.end(), Time::seconds(8)); // stays inside the clip
        let short = KeystoneBar::dragged(&s, KeystoneEdge::End, Time::seconds(0), Time::seconds(8), Time::new(1, 2));
        assert_eq!(short.duration, Time::new(1, 2));
        let start = KeystoneBar::dragged(&s, KeystoneEdge::Start, Time::seconds(-3), Time::seconds(8), Time::new(1, 2));
        assert!(start.start == Time::ZERO && start.end() == Time::seconds(6));
    }

    #[test]
    fn edges_are_grabbed_within_the_slop() {
        let r = Rect::new(100.0, 40.0, 80.0, 12.0);
        assert_eq!(KeystoneBar::edge(Point::new(103.0, 45.0), &r), Some(KeystoneEdge::Start));
        assert_eq!(KeystoneBar::edge(Point::new(178.0, 45.0), &r), Some(KeystoneEdge::End));
        assert_eq!(KeystoneBar::edge(Point::new(140.0, 45.0), &r), None);
        assert_eq!(KeystoneBar::edge(Point::new(103.0, 60.0), &r), None);
    }
}
