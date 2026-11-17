//! Keyboard trims of selected clip edges (Trim Backward/Forward, Extend Edit) as replayable edits. Pure.

use std::collections::BTreeSet;

use sq_core_model::{Clip, ClipEdge, Timeline, Track};
use sq_core_time::{Id, Time};

use crate::{EdgeRef, EdgeSelection, TimelineEdit};

/// Namespace of the edge edit rules.
pub enum EdgeEdits {}

fn clip_in(id: Id, t: &Timeline) -> Option<(&Clip, &Track)> {
    t.tracks.iter().find_map(|tr| tr.clips().iter().find(|c| c.id == id).map(|c| (c, tr)))
}

impl EdgeEdits {
    /// The edge refs that still exist in `t`.
    // Swift: EdgeEdits.swift:12
    pub fn pruned(sel: &EdgeSelection, t: &Timeline) -> Option<EdgeSelection> {
        let alive: Vec<EdgeRef> = sel.edges.iter().copied().filter(|r| clip_in(r.clip, t).is_some()).collect();
        (!alive.is_empty()).then_some(EdgeSelection { edges: alive, ripple: sel.ripple, linked: sel.linked })
    }

    /// The time of the edge `r` points at.
    // Swift: EdgeEdits.swift:16
    pub fn time(r: EdgeRef, t: &Timeline) -> Option<Time> {
        clip_in(r.clip, t).map(|(c, _)| if r.edge == ClipEdge::Head { c.start } else { c.timeline().end() })
    }

    /// The other side of the edit `r` sits on (same track, touching), if any.
    // Swift: EdgeEdits.swift:22
    pub fn partner(r: EdgeRef, t: &Timeline) -> Option<EdgeRef> {
        let (c, tr) = clip_in(r.clip, t)?;
        if r.edge == ClipEdge::Tail {
            return tr
                .clips()
                .iter()
                .find(|o| o.start == c.timeline().end())
                .map(|o| EdgeRef { clip: o.id, edge: ClipEdge::Head });
        }
        tr.clips().iter().find(|o| o.timeline().end() == c.start).map(|o| EdgeRef { clip: o.id, edge: ClipEdge::Tail })
    }

    /// Both sides of one edit are selected: a drag or trim rolls the edit.
    // Swift: EdgeEdits.swift:31
    pub fn is_roll(sel: &EdgeSelection, t: &Timeline) -> bool {
        sel.edges.iter().any(|r| Self::partner(*r, t).is_some_and(|p| sel.edges.contains(&p)))
    }

    /// Ctrl+T: the next trim type of the selected edit: regular trim, ripple, rolling (only where the edit has a clip on
    /// both sides), then regular again. The order is ours.
    // Swift: EdgeEdits.swift:38
    pub fn cycled(sel: &EdgeSelection, t: &Timeline) -> EdgeSelection {
        let Some(&first) = sel.edges.first() else { return sel.clone() };
        let linked = sel.linked;
        if Self::is_roll(sel, t) {
            return EdgeSelection { edges: vec![first], ripple: false, linked };
        }
        if !sel.ripple {
            return EdgeSelection { edges: sel.edges.clone(), ripple: true, linked };
        }
        if let Some(p) = Self::partner(first, t) {
            return EdgeSelection { edges: vec![first, p], ripple: false, linked };
        }
        EdgeSelection { edges: sel.edges.clone(), ripple: false, linked }
    }

    /// Moves the selected edges by `delta` (positive = later). Regular trim, ripple trim with Cmd-selected edges,
    /// rolling edit when both sides of an edit are selected.
    // Swift: EdgeEdits.swift:49
    pub fn trim(sel: &EdgeSelection, delta: Time, t: &Timeline) -> Vec<TimelineEdit> {
        if delta == Time::ZERO {
            return Vec::new();
        }
        let mut out = Vec::new();
        let mut done: BTreeSet<(Id, bool)> = BTreeSet::new();
        // Edits act on the whole link group: one per group and kind, or the delta would apply twice.
        let mut seen: BTreeSet<(Id, &'static str)> = BTreeSet::new();
        let mut fresh = |r: EdgeRef, kind: &'static str| match clip_in(r.clip, t).and_then(|(c, _)| c.link) {
            Some(l) => seen.insert((l, kind)),
            None => true,
        };
        let key = |r: EdgeRef| (r.clip, r.edge == ClipEdge::Head);
        for &r in &sel.edges {
            if done.contains(&key(r)) {
                continue;
            }
            if let Some(p) = Self::partner(r, t).filter(|p| sel.edges.contains(p)) {
                done.insert(key(r));
                done.insert(key(p));
                let left = if r.edge == ClipEdge::Tail { r } else { p };
                if fresh(left, "roll") {
                    out.push(TimelineEdit::Roll { clip: left.clip, by: delta });
                }
            } else {
                done.insert(key(r));
                let kind = if r.edge == ClipEdge::Head { "head" } else { "tail" };
                if !fresh(r, kind) {
                    continue;
                }
                out.push(if sel.ripple {
                    TimelineEdit::RippleTrim { clip: r.clip, edge: r.edge, by: delta }
                } else {
                    TimelineEdit::Trim { clip: r.clip, edge: r.edge, by: delta }
                });
            }
        }
        out
    }

    /// E: moves the first selected edit to `time` (the playhead). A selected edit (both sides) rolls with the linked
    /// partners of both clips; a single edge trims. Either way a clip keeps at least one frame instead of the edit failing.
    // Swift: EdgeEdits.swift:75
    pub fn extend(sel: &EdgeSelection, time: Time, t: &Timeline) -> Vec<TimelineEdit> {
        let Some(&first) = sel.edges.first() else { return Vec::new() };
        let Some(at) = Self::time(first, t) else { return Vec::new() };
        if time == at {
            return Vec::new();
        }
        if let Some(p) = Self::partner(first, t).filter(|p| sel.edges.contains(p)) {
            let left = if first.edge == ClipEdge::Tail { first } else { p };
            return vec![TimelineEdit::ExtendEdit { clip: left.clip, edge: ClipEdge::Tail, to: time }];
        }
        // Shortening: every trimmed clip (and its linked partners, which get the same change) keeps one frame.
        let mut delta = time - at;
        let fd = t.frame_duration();
        for r in &sel.edges {
            let Some((c, _)) = clip_in(r.clip, t) else { continue };
            for g in t
                .tracks
                .iter()
                .flat_map(|tr| tr.clips())
                .filter(|g| g.id == c.id || (c.link.is_some() && g.link == c.link))
            {
                if r.edge == ClipEdge::Tail && delta < Time::ZERO {
                    delta = delta.max((fd - g.duration()).min(Time::ZERO));
                }
                if r.edge == ClipEdge::Head && delta > Time::ZERO {
                    delta = delta.min((g.duration() - fd).max(Time::ZERO));
                }
            }
        }
        Self::trim(sel, delta, t)
    }
}
