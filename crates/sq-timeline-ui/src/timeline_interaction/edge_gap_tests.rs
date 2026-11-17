//! Port of TimelineEdgeGapTests.swift.

use crate::test_support::*;
use crate::timeline_interaction::TimelineInteraction;
use sq_core_model::{ClipEdge, Timeline, TrackKind};
use sq_core_time::{Id, TimeRange};
use sq_editor_session::{
    EdgeEdits, EdgeRef, EdgeSelection, GestureModifiers as M, TimelineEdit, TimelineTool, ToolState,
};
use std::collections::BTreeSet;

// V1 y42..<74 (4 pt per frame).
const Y_V1: f64 = 70.0;

struct Fixture {
    c1: sq_core_model::Clip,
    c2: sq_core_model::Clip,
    c3: sq_core_model::Clip,
}

impl Fixture {
    fn new() -> Fixture {
        Fixture { c1: mkv(0, 20), c2: mkv(20, 20), c3: mkv(60, 20) }
    }

    fn timeline(&self) -> Timeline {
        timeline(vec![
            track(TrackKind::Video, vec![self.c1.clone(), self.c2.clone(), self.c3.clone()]),
            track(TrackKind::Video, vec![]),
        ])
    }

    fn interaction(&self) -> TimelineInteraction {
        let mut i = interaction_of(self.timeline());
        i.tool_state = ToolState::new(TimelineTool::Selection, false, true);
        i
    }
}

#[test]
fn escape_clears_a_selected_gap_but_changes_nothing() {
    let f = Fixture::new();
    let mut i = f.interaction();
    click(&mut i, pt(x(40.0), Y_V1), none());
    assert!(i.gap_selection().is_some());
    let before = i.timeline().clone();
    assert!(i.clear_gap_and_edge_selection());
    assert!(i.gap_selection().is_none());
    assert_eq!(*i.timeline(), before); // nothing deleted, no edit, so no undo step
    assert!(!i.clear_gap_and_edge_selection()); // nothing selected: Escape is not consumed
}

#[test]
fn click_on_edge_selects_the_edge_not_the_clip() {
    let f = Fixture::new();
    let mut i = f.interaction();
    click(&mut i, pt(x(40.0) - 1.0, Y_V1), none());
    assert!(i.selection().is_empty());
    assert_eq!(i.edge_selection(), Some(&EdgeSelection::new(vec![EdgeRef::new(f.c2.id, ClipEdge::Tail)], false, true)));
    click(&mut i, pt(x(40.0) - 1.0, Y_V1), M::COMMAND);
    assert_eq!(i.edge_selection().map(|e| e.ripple), Some(true));
    click(&mut i, pt(x(30.0), Y_V1), none());
    assert!(i.edge_selection().is_none());
    assert_eq!(*i.selection(), BTreeSet::from([f.c2.id]));
}

#[test]
fn command_drag_on_an_edge_ripples_later_clips() {
    let f = Fixture::new();
    let mut i = f.interaction();
    let c = drag(&mut i, pt(x(40.0) - 1.0, Y_V1), pt(x(35.0) - 1.0, Y_V1), M::COMMAND).unwrap();
    assert_eq!(c.undo_name, "Ripple Trim");
    let v1 = c.timeline.tracks[0].clips();
    assert_eq!(v1[1].timeline().end(), FD * 35);
    assert_eq!(v1[2].start, FD * 55);
}

#[test]
fn plain_drag_on_an_edge_trims_without_ripple() {
    let f = Fixture::new();
    let mut i = f.interaction();
    let c = drag(&mut i, pt(x(40.0) - 1.0, Y_V1), pt(x(35.0) - 1.0, Y_V1), none()).unwrap();
    assert_eq!(c.undo_name, "Trim Clip");
    assert_eq!(c.timeline.tracks[0].clips()[2].start, FD * 60);
}

#[test]
fn shift_clicking_both_sides_of_an_edit_rolls_it() {
    let f = Fixture::new();
    let mut i = f.interaction();
    click(&mut i, pt(x(20.0) - 1.0, Y_V1), none()); // c1 tail
    i.mouse_down(pt(x(20.0) + 1.0, Y_V1), M::SHIFT); // + c2 head
    i.mouse_up(pt(x(20.0) + 1.0, Y_V1), M::SHIFT);
    assert_eq!(i.edge_selection().map(|e| e.edges.len()), Some(2));
    let c = drag(&mut i, pt(x(20.0) + 1.0, Y_V1), pt(x(25.0) + 1.0, Y_V1), none()).unwrap();
    assert_eq!(c.undo_name, "Move Edit");
    let v1 = c.timeline.tracks[0].clips();
    assert!(v1[0].timeline().end() == FD * 25 && v1[1].start == FD * 25);
}

#[test]
fn click_on_a_gap_selects_it_and_click_elsewhere_clears_it() {
    let f = Fixture::new();
    let mut i = f.interaction();
    click(&mut i, pt(x(50.0), Y_V1), none());
    assert_eq!(i.gap_selection().map(|g| g.range), Some(TimeRange::from_end(FD * 40, FD * 60)));
    click(&mut i, pt(x(10.0), Y_V1), none());
    assert!(i.gap_selection().is_none());
}

#[test]
fn option_drag_copies_and_selects_the_copy() {
    let f = Fixture::new();
    let mut i = f.interaction();
    let c = drag(&mut i, pt(x(70.0), Y_V1), pt(x(90.0), Y_V1), M::OPTION).unwrap();
    assert_eq!(c.undo_name, "Copy Clip");
    let v1 = c.timeline.tracks[0].clips();
    assert_eq!(v1.len(), 4);
    assert!(v1.iter().any(|k| k.id == f.c3.id && k.start == FD * 60));
    let copy = v1.iter().find(|k| k.start == FD * 80).unwrap();
    assert_eq!(c.selection, BTreeSet::from([copy.id]));
}

#[test]
fn edge_edits_trim_roll_and_extend() {
    let f = Fixture::new();
    let t = f.timeline();
    let tail = EdgeRef::new(f.c1.id, ClipEdge::Tail);
    let head = EdgeRef::new(f.c2.id, ClipEdge::Head);
    let sel = |edges: Vec<EdgeRef>, ripple: bool| EdgeSelection::new(edges, ripple, true);
    assert_eq!(
        EdgeEdits::trim(&sel(vec![tail], false), FD * -1, &t),
        vec![TimelineEdit::Trim { clip: f.c1.id, edge: ClipEdge::Tail, by: FD * -1 }]
    );
    assert_eq!(
        EdgeEdits::trim(&sel(vec![tail], true), FD, &t),
        vec![TimelineEdit::RippleTrim { clip: f.c1.id, edge: ClipEdge::Tail, by: FD }]
    );
    assert_eq!(
        EdgeEdits::trim(&sel(vec![tail, head], false), FD * 5, &t),
        vec![TimelineEdit::Roll { clip: f.c1.id, by: FD * 5 }]
    );
    assert_eq!(
        EdgeEdits::extend(&sel(vec![head], false), FD * 25, &t),
        vec![TimelineEdit::Trim { clip: f.c2.id, edge: ClipEdge::Head, by: FD * 5 }]
    );
    assert!(EdgeEdits::trim(&sel(vec![tail], false), sq_core_time::Time::ZERO, &t).is_empty());
    // E past the clip's other end keeps one frame; E on a selected edit rolls through Timeline.extendEdit.
    assert_eq!(
        EdgeEdits::extend(&sel(vec![head], false), FD * 50, &t),
        vec![TimelineEdit::Trim { clip: f.c2.id, edge: ClipEdge::Head, by: FD * 19 }]
    );
    assert_eq!(
        EdgeEdits::extend(&sel(vec![head, tail], false), FD * 30, &t),
        vec![TimelineEdit::ExtendEdit { clip: f.c1.id, edge: ClipEdge::Tail, to: FD * 30 }]
    );
}

// Review fixes.

#[test]
fn programmatic_selection_clears_edge_and_gap_but_empty_echo_keeps_them() {
    let f = Fixture::new();
    let mut i = f.interaction();
    click(&mut i, pt(x(40.0) - 1.0, Y_V1), none());
    i.set_selection(BTreeSet::new());
    assert!(i.edge_selection().is_some());
    i.set_selection(BTreeSet::from([f.c1.id]));
    assert!(i.edge_selection().is_none());
    click(&mut i, pt(x(50.0), Y_V1), none());
    assert!(i.gap_selection().is_some());
    i.set_selection(BTreeSet::from([f.c3.id]));
    assert!(i.gap_selection().is_none());
}

#[test]
fn linked_edges_trim_once_per_group() {
    let l: Id = uid();
    let mut v = mkv(0, 20);
    let mut a = mkv(0, 20);
    v.link = Some(l);
    a.link = Some(l);
    let t = timeline(vec![track(TrackKind::Video, vec![v.clone()]), track(TrackKind::Video, vec![a.clone()])]);
    let sel =
        EdgeSelection::new(vec![EdgeRef::new(v.id, ClipEdge::Tail), EdgeRef::new(a.id, ClipEdge::Tail)], false, true);
    assert_eq!(EdgeEdits::trim(&sel, FD * -2, &t).len(), 1);
}

#[test]
fn dragging_a_multi_edge_selection_trims_all_edges() {
    let (mut c1, mut c2) = (mkv(0, 20), mkv(20, 20));
    c1.link = None;
    c2.link = None;
    let _ = c2;
    let t = timeline(vec![track(TrackKind::Video, vec![c1]), track(TrackKind::Video, vec![mkv(0, 20)])]);
    let mut i = interaction_of(t.clone());
    i.tool_state = ToolState::new(TimelineTool::Selection, false, true);
    let rows = i.geometry.rows(&t);
    let y_a = rows[0].y + 10.0;
    let y_b = rows[1].y + 10.0;
    click(&mut i, pt(x(20.0) - 1.0, y_a), none());
    i.mouse_down(pt(x(20.0) - 1.0, y_b), M::SHIFT);
    i.mouse_up(pt(x(20.0) - 1.0, y_b), M::SHIFT);
    assert_eq!(i.edge_selection().map(|e| e.edges.len()), Some(2));
    let c = drag(&mut i, pt(x(20.0) - 1.0, y_b), pt(x(15.0) - 1.0, y_b), none()).unwrap();
    assert_eq!(c.timeline.tracks[0].clips()[0].timeline().end(), FD * 15);
    assert_eq!(c.timeline.tracks[1].clips()[0].timeline().end(), FD * 15);
}
