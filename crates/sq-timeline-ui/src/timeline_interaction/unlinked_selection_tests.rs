//! Port of UnlinkedSelectionTests.swift (the reducer suites). Premiere "selected unlinked": a clip picked with Option (or
//! with Linked Selection off) is edited alone; its linked partner follows only when it is selected too. The
//! `EditorSession` suites of that file test the session crate.

use crate::test_support::*;
use crate::timeline_interaction::TimelineInteraction;
use sq_core_model::{Clip, Timeline, TrackKind};
use sq_core_time::Id;
use sq_editor_session::{EdgeEdits, EdgeRef, EdgeSelection, GestureModifiers as M, TimelineTool, ToolState};
use std::collections::BTreeSet;

// Rows: V2 y22..<62, V1 62..<102.
const Y_V2: f64 = 38.0;
const Y_V1: f64 = 70.0;

struct Fixture {
    link: Id,
    v: Clip,
    a: Clip,
}

impl Fixture {
    fn new() -> Fixture {
        let link = uid();
        Fixture { link, v: mk(0, 20, TrackKind::Video, Some(link)), a: mk(0, 20, TrackKind::Audio, Some(link)) }
    }

    fn timeline(&self) -> Timeline {
        timeline(vec![
            track(TrackKind::Video, vec![self.v.clone()]),
            track(TrackKind::Video, vec![]),
            track(TrackKind::Audio, vec![self.a.clone()]),
            track(TrackKind::Audio, vec![]),
        ])
    }

    fn interaction(&self, linked: bool) -> TimelineInteraction {
        let mut i = interaction_of(self.timeline());
        i.tool_state = ToolState::new(TimelineTool::Selection, false, linked);
        i
    }
}

fn ids(t: &Timeline, n: usize) -> Vec<Id> {
    t.tracks[n].clips().iter().map(|c| c.id).collect()
}

#[test]
fn option_selected_clip_moves_alone() {
    let f = Fixture::new();
    let mut i = f.interaction(true);
    i.mouse_down(pt(x(10.0), Y_V1), M::OPTION);
    i.mouse_up(pt(x(10.0), Y_V1), M::OPTION);
    assert_eq!(*i.selection(), BTreeSet::from([f.v.id]));
    let c = drag(&mut i, pt(x(10.0), Y_V1), pt(x(40.0), Y_V2), none()).unwrap();
    assert_eq!(clip_of(&c.timeline, f.v.id).map(|c| c.start), Some(FD * 30));
    assert_eq!(ids(&c.timeline, 1), vec![f.v.id]);
    assert_eq!(clip_of(&c.timeline, f.a.id).map(|c| c.start), Some(sq_core_time::Time::ZERO));
    assert_eq!(ids(&c.timeline, 2), vec![f.a.id]);
    assert_eq!(clip_of(&c.timeline, f.v.id).and_then(|c| c.link), Some(f.link)); // still linked, now out of sync
}

#[test]
fn plain_selected_clip_moves_with_partner() {
    let f = Fixture::new();
    let mut i = f.interaction(true);
    let c = drag(&mut i, pt(x(10.0), Y_V1), pt(x(40.0), Y_V1), none()).unwrap();
    assert_eq!(clip_of(&c.timeline, f.a.id).map(|c| c.start), Some(FD * 30));
}

#[test]
fn linked_selection_off_moves_alone() {
    let f = Fixture::new();
    let mut i = f.interaction(false);
    let c = drag(&mut i, pt(x(10.0), Y_V1), pt(x(40.0), Y_V1), none()).unwrap();
    assert_eq!(clip_of(&c.timeline, f.v.id).map(|c| c.start), Some(FD * 30));
    assert_eq!(clip_of(&c.timeline, f.a.id).map(|c| c.start), Some(sq_core_time::Time::ZERO));
}

#[test]
fn option_edge_trims_alone() {
    let f = Fixture::new();
    let mut i = f.interaction(true);
    let c = drag(&mut i, pt(x(20.0) - 1.0, Y_V1), pt(x(15.0) - 1.0, Y_V1), M::OPTION).unwrap();
    assert_eq!(clip_of(&c.timeline, f.v.id).map(|c| c.timeline().duration), Some(FD * 15));
    assert_eq!(clip_of(&c.timeline, f.a.id).map(|c| c.timeline().duration), Some(FD * 20));
    let mut j = f.interaction(true);
    let d = drag(&mut j, pt(x(20.0) - 1.0, Y_V1), pt(x(15.0) - 1.0, Y_V1), none()).unwrap();
    assert_eq!(clip_of(&d.timeline, f.a.id).map(|c| c.timeline().duration), Some(FD * 15)); // plain edge drag trims both
}

#[test]
fn option_delete_removes_only_that_clip() {
    let f = Fixture::new();
    let mut i = f.interaction(true);
    i.mouse_down(pt(x(10.0), Y_V1), M::OPTION);
    i.mouse_up(pt(x(10.0), Y_V1), M::OPTION);
    let c = i.delete_selection(false).unwrap();
    assert!(clip_of(&c.timeline, f.v.id).is_none());
    assert!(clip_of(&c.timeline, f.a.id).is_some());
    assert_eq!(clip_of(&c.timeline, f.a.id).and_then(|c| c.link), None); // lone partner loses its link
}

#[test]
fn option_drag_on_unselected_clip_copies_only_that_clip() {
    let f = Fixture::new();
    let mut i = f.interaction(true);
    let c = drag(&mut i, pt(x(10.0), Y_V1), pt(x(40.0), Y_V2), M::OPTION).unwrap();
    assert_eq!(c.timeline.tracks[1].clips().len(), 1); // the copy
    assert_eq!(ids(&c.timeline, 0), vec![f.v.id]); // original stays
    assert!(c.timeline.tracks[2].clips().len() == 1 && c.timeline.tracks[3].clips().is_empty());
    assert_eq!(c.timeline.tracks[1].clips()[0].link, None);
}

#[test]
fn option_drag_on_selected_pair_copies_both() {
    let f = Fixture::new();
    let mut i = f.interaction(true);
    i.mouse_down(pt(x(10.0), Y_V1), none());
    i.mouse_up(pt(x(10.0), Y_V1), none());
    let c = drag(&mut i, pt(x(10.0), Y_V1), pt(x(40.0), Y_V1), M::OPTION).unwrap();
    assert_eq!(c.timeline.tracks[0].clips().len(), 2);
    assert_eq!(c.timeline.tracks[2].clips().len(), 2);
}

// Review fixes: roll scope covers the left clip, edge `linked` survives prune/cycle.

/// V1: v0 0..<20, v1 20..<40; A1: a0, a1 the same, v0/a0 and v1/a1 linked.
struct Cut {
    v0: Clip,
    v1: Clip,
    a0: Clip,
    a1: Clip,
}

impl Cut {
    fn new() -> Cut {
        let (l0, l1) = (uid(), uid());
        Cut {
            v0: mk(0, 20, TrackKind::Video, Some(l0)),
            v1: mk(20, 20, TrackKind::Video, Some(l1)),
            a0: mk(0, 20, TrackKind::Audio, Some(l0)),
            a1: mk(20, 20, TrackKind::Audio, Some(l1)),
        }
    }

    fn timeline(&self) -> Timeline {
        let mut v = track(TrackKind::Video, vec![self.v0.clone(), self.v1.clone()]);
        v.is_targeted = true;
        timeline(vec![
            v,
            track(TrackKind::Video, vec![]),
            track(TrackKind::Audio, vec![self.a0.clone(), self.a1.clone()]),
        ])
    }

    fn interaction(&self, tool: TimelineTool, linked: bool) -> TimelineInteraction {
        let mut i = interaction_of(self.timeline());
        i.tool_state = ToolState::new(tool, false, linked);
        i
    }
}

#[test]
fn roll_tool_on_head_with_option_rolls_only_that_cut() {
    let f = Cut::new();
    for (linked, m) in [(true, M::OPTION), (false, none())] {
        let mut i = f.interaction(TimelineTool::RollEdit, linked);
        let c = drag(&mut i, pt(x(20.0) + 1.0, Y_V1), pt(x(25.0) + 1.0, Y_V1), m).unwrap();
        assert_eq!(clip_of(&c.timeline, f.v1.id).map(|c| c.start), Some(FD * 25));
        assert_eq!(clip_of(&c.timeline, f.v0.id).map(|c| c.timeline().duration), Some(FD * 25));
        assert_eq!(clip_of(&c.timeline, f.a1.id).map(|c| c.start), Some(FD * 20));
        assert_eq!(clip_of(&c.timeline, f.a0.id).map(|c| c.timeline().duration), Some(FD * 20));
    }
    let mut j = f.interaction(TimelineTool::RollEdit, true);
    let d = drag(&mut j, pt(x(20.0) + 1.0, Y_V1), pt(x(25.0) + 1.0, Y_V1), none()).unwrap();
    assert_eq!(clip_of(&d.timeline, f.a1.id).map(|c| c.start), Some(FD * 25)); // plain roll moves the linked cut too
}

#[test]
fn prune_and_cycle_keep_unlinked() {
    let f = Cut::new();
    let t = f.timeline();
    let sel = EdgeSelection::new(vec![EdgeRef::new(f.v0.id, sq_core_model::ClipEdge::Tail)], false, false);
    assert_eq!(EdgeEdits::pruned(&sel, &t).map(|s| s.linked), Some(false));
    let mut s = sel.clone();
    for _ in 0..4 {
        s = EdgeEdits::cycled(&s, &t);
        assert!(!s.linked);
    }
    let mut i = f.interaction(TimelineTool::Selection, true);
    i.set_edge_selection(Some(sel));
    i.reset(t);
    assert_eq!(i.edge_selection().map(|e| e.linked), Some(false));
}
