//! Port of TimelineInteractionTests.swift (the interaction and audit suites).

use crate::test_support::*;
use crate::timeline_interaction::TimelineInteraction;
use sq_core_model::{CaptionItem, Timeline, TrackKind};
use sq_core_time::{Id, Keyframe, KeyframeTrack, TimeRange};
use sq_editor_session::{GestureModifiers as M, TimelineEdit, TimelineTool, ToolState};
use std::collections::BTreeSet;

// Rows: V2 y22..<42, V1 42..<74, A1 74..<100, A2 100..<120.
const Y_V2: f64 = 42.0;
const Y_V1: f64 = 82.0;
const Y_A1: f64 = 116.0;
const Y_A2: f64 = 144.0;

struct Fixture {
    c1: sq_core_model::Clip, // V1, linked to a1
    c2: sq_core_model::Clip, // V1, adjacent to c1
    c3: sq_core_model::Clip, // V1
    a1: sq_core_model::Clip,
    a2c: sq_core_model::Clip, // A2, unlinked
    v1: sq_core_model::Track,
    v2: sq_core_model::Track,
    a_t1: sq_core_model::Track,
    a_t2: sq_core_model::Track,
}

impl Fixture {
    fn new() -> Fixture {
        let link = uid();
        let c1 = mk(0, 20, TrackKind::Video, Some(link));
        let c2 = mkv(20, 20);
        let c3 = mkv(60, 20);
        let a1 = mk(0, 20, TrackKind::Audio, Some(link));
        let a2c = mk(10, 10, TrackKind::Audio, None);
        Fixture {
            v1: track(TrackKind::Video, vec![c1.clone(), c2.clone(), c3.clone()]),
            v2: track(TrackKind::Video, vec![]),
            a_t1: track(TrackKind::Audio, vec![a1.clone()]),
            a_t2: track(TrackKind::Audio, vec![a2c.clone()]),
            c1,
            c2,
            c3,
            a1,
            a2c,
        }
    }

    fn timeline(&self) -> Timeline {
        timeline(vec![self.v1.clone(), self.v2.clone(), self.a_t1.clone(), self.a_t2.clone()])
    }

    fn interaction_with(
        &self,
        tool: TimelineTool,
        snapping: bool,
        linked: bool,
        playhead: Option<sq_core_time::Time>,
    ) -> TimelineInteraction {
        let mut i = interaction_of(self.timeline());
        i.tool_state = ToolState::new(tool, snapping, linked);
        i.playhead = playhead;
        i
    }

    fn interaction(&self) -> TimelineInteraction {
        self.interaction_with(TimelineTool::Selection, false, true, None)
    }

    fn tool(&self, tool: TimelineTool) -> TimelineInteraction {
        self.interaction_with(tool, false, true, None)
    }

    fn unlinked(&self) -> TimelineInteraction {
        self.interaction_with(TimelineTool::Selection, false, false, None)
    }
}

fn set(ids: &[Id]) -> BTreeSet<Id> {
    ids.iter().copied().collect()
}

// MARK: Selection

#[test]
fn click_selects_linked_group() {
    let f = Fixture::new();
    let mut i = f.interaction();
    assert!(click(&mut i, pt(x(10.0), Y_V1), none()).is_none());
    assert_eq!(*i.selection(), set(&[f.c1.id, f.a1.id]));
}

/// Monitor tools (Mask, Create, ...) act as Selection in the timeline: same click selection, same drag.
#[test]
fn monitor_tools_act_like_selection_in_the_timeline() {
    let f = Fixture::new();
    for tool in [TimelineTool::Mask, TimelineTool::Type] {
        let mut i = f.tool(tool);
        let mut s = f.tool(TimelineTool::Selection);
        assert!(click(&mut i, pt(x(30.0), Y_V1), none()).is_none());
        assert!(click(&mut s, pt(x(30.0), Y_V1), none()).is_none());
        assert!(i.selection() == s.selection() && *i.selection() == set(&[f.c2.id]));
        let a = drag(&mut i, pt(x(30.0), Y_V1), pt(x(50.0), Y_V1), none());
        let b = drag(&mut s, pt(x(30.0), Y_V1), pt(x(50.0), Y_V1), none());
        assert!(
            a.is_some()
                && a.as_ref().map(|c| &c.undo_name) == b.as_ref().map(|c| &c.undo_name)
                && a.as_ref().map(|c| &c.selection) == b.as_ref().map(|c| &c.selection)
                && a.as_ref().map(|c| &c.edits) == b.as_ref().map(|c| &c.edits),
            "{tool:?}"
        );
    }
}

/// A bundle selects together with linked selection on, like a link group; Option-click picks one clip.
#[test]
fn click_selects_the_bundle() {
    let mut f = Fixture::new();
    let b = uid();
    f.c3.bundle = Some(b);
    f.a2c.bundle = Some(b);
    f.v1 = track(TrackKind::Video, vec![f.c1.clone(), f.c2.clone(), f.c3.clone()]);
    f.a_t2 = track(TrackKind::Audio, vec![f.a2c.clone()]);
    let mut i = f.interaction();
    click(&mut i, pt(x(70.0), Y_V1), none());
    assert_eq!(*i.selection(), set(&[f.c3.id, f.a2c.id]));
    let mut j = f.interaction();
    click(&mut j, pt(x(70.0), Y_V1), M::OPTION);
    assert_eq!(*j.selection(), set(&[f.c3.id]));
    let mut k = f.unlinked();
    click(&mut k, pt(x(70.0), Y_V1), none());
    assert_eq!(*k.selection(), set(&[f.c3.id]));
}

#[test]
fn option_inverts_linked_selection_and_toggle_off_works() {
    let f = Fixture::new();
    let mut i = f.interaction();
    click(&mut i, pt(x(10.0), Y_V1), M::OPTION);
    assert_eq!(*i.selection(), set(&[f.c1.id]));
    let mut j = f.unlinked();
    click(&mut j, pt(x(10.0), Y_V1), none());
    assert_eq!(*j.selection(), set(&[f.c1.id]));
    click(&mut j, pt(x(10.0), Y_V1), M::OPTION); // option turns linking on
    assert_eq!(*j.selection(), set(&[f.c1.id, f.a1.id]));
}

#[test]
fn shift_click_toggles_and_gap_click_clears() {
    let f = Fixture::new();
    let mut i = f.unlinked();
    click(&mut i, pt(x(25.0), Y_V1), none());
    click(&mut i, pt(x(70.0), Y_V1), M::SHIFT);
    assert_eq!(*i.selection(), set(&[f.c2.id, f.c3.id]));
    click(&mut i, pt(x(25.0), Y_V1), M::SHIFT);
    assert_eq!(*i.selection(), set(&[f.c3.id]));
    click(&mut i, pt(x(50.0), Y_V1), none()); // gap
    assert!(i.selection().is_empty());
}

#[test]
fn click_inside_multi_selection_without_drag_reduces_to_that_clip() {
    let f = Fixture::new();
    let mut i = f.unlinked();
    click(&mut i, pt(x(25.0), Y_V1), none());
    click(&mut i, pt(x(70.0), Y_V1), M::SHIFT);
    click(&mut i, pt(x(25.0), Y_V1), none());
    assert_eq!(*i.selection(), set(&[f.c2.id]));
}

fn caption_track_of(items: Vec<CaptionItem>) -> sq_core_model::CaptionTrack {
    let mut t: sq_core_model::CaptionTrack =
        serde_json::from_value(serde_json::json!({"id": uid().to_string()})).unwrap();
    t.with_items(|v| *v = items);
    t
}

fn caption(lines: &[&str], a: i64, b: i64) -> CaptionItem {
    CaptionItem {
        id: uid(),
        lines: lines.iter().map(|s| s.to_string()).collect(),
        range: TimeRange::from_end(FD * a, FD * b),
        style_ref: String::new(),
        animation_ref: String::new(),
        style_overridden: false,
        words: vec![],
        position: None,
    }
}

#[test]
fn marquee_picks_up_captions_inside_the_rectangle() {
    let mut f = Fixture::new();
    f.v1 = track(TrackKind::Video, vec![f.c1.clone(), f.c3.clone()]);
    let mut tl = f.timeline();
    let early = caption(&["a"], 2, 10);
    let late = caption(&["b"], 70, 78);
    tl.caption_tracks = vec![caption_track_of(vec![early.clone(), late.clone()])];
    let geo = geo4();
    let mut i = TimelineInteraction::new(tl.clone(), geo.clone(), ID_SEED);
    i.tool_state = ToolState::new(TimelineTool::Selection, false, false);
    let row = geo.caption_rows(&tl)[0].clone();
    let y_c = row.y + row.height / 2.0;
    let y_clip = geo.rows(&tl).iter().find(|r| r.track == f.v1.id).map(|r| r.y).unwrap() + 4.0;
    // From below the first video clip up through the caption row: the early caption and the clip are in, the late one is out.
    i.mouse_down(pt(x(40.0), y_clip + 6.0), none());
    i.mouse_dragged(pt(x(1.0), y_c), none());
    assert_eq!(*i.caption_selection(), set(&[early.id]));
    assert_eq!(*i.selection(), set(&[f.c1.id]));
    i.mouse_up(pt(x(1.0), y_c), none());
    // Shift keeps the earlier caption selection and adds the late one.
    i.mouse_down(pt(x(90.0), y_c), M::SHIFT);
    i.mouse_dragged(pt(x(65.0), y_c + 2.0), M::SHIFT);
    assert_eq!(*i.caption_selection(), set(&[early.id, late.id]));
    i.mouse_up(pt(x(65.0), y_c + 2.0), M::SHIFT);
}

/// Option on a marquee flips Linked Selection for that sweep: the partner stays out (and with it off, comes in).
#[test]
fn option_marquee_leaves_linked_partners_out() {
    let f = Fixture::new();
    let mut i = f.interaction();
    i.mouse_down(pt(x(85.0), Y_V2), M::OPTION);
    i.mouse_dragged(pt(x(15.0), Y_V1), M::OPTION);
    i.mouse_up(pt(x(15.0), Y_V1), M::OPTION);
    assert_eq!(*i.selection(), set(&[f.c1.id, f.c2.id, f.c3.id]));
}

#[test]
fn marquee_selects_intersecting_clips_and_shift_extends() {
    let f = Fixture::new();
    let mut i = f.unlinked();
    i.mouse_down(pt(x(85.0), Y_V2), none());
    i.mouse_dragged(pt(x(15.0), Y_V1), none());
    assert!(i.marquee().is_some());
    assert_eq!(*i.selection(), set(&[f.c1.id, f.c2.id, f.c3.id]));
    assert!(i.mouse_up(pt(x(15.0), Y_V1), none()).is_none());
    assert!(i.marquee().is_none());
    // Linked selection pulls the partner in.
    let mut j = f.interaction();
    j.mouse_down(pt(x(85.0), Y_V2), none());
    j.mouse_dragged(pt(x(15.0), Y_V1), none());
    j.mouse_up(pt(x(15.0), Y_V1), none());
    assert_eq!(*j.selection(), set(&[f.c1.id, f.c2.id, f.c3.id, f.a1.id]));
    // Shift keeps the old selection.
    let mut k = f.unlinked();
    click(&mut k, pt(x(10.0), Y_V1), none());
    k.mouse_down(pt(x(55.0), Y_V2), M::SHIFT);
    k.mouse_dragged(pt(x(85.0), Y_V1), M::SHIFT);
    k.mouse_up(pt(x(85.0), Y_V1), M::SHIFT);
    assert_eq!(*k.selection(), set(&[f.c1.id, f.c3.id]));
}

// MARK: Move

#[test]
fn move_produces_preview_then_one_commit() {
    let f = Fixture::new();
    let mut i = f.interaction();
    i.mouse_down(pt(x(25.0), Y_V1), none());
    i.mouse_dragged(pt(x(30.0), Y_V1), none());
    assert_eq!(clip_of(i.preview(), f.c2.id).map(|c| c.start), Some(FD * 25));
    assert_eq!(clip_of(i.timeline(), f.c2.id).map(|c| c.start), Some(FD * 20)); // base untouched while dragging
    let c = i.mouse_up(pt(x(30.0), Y_V1), none()).unwrap();
    assert_eq!(c.undo_name, "Move Clip");
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.start), Some(FD * 25));
    assert_eq!(clip_of(i.timeline(), f.c2.id).map(|c| c.start), Some(FD * 25));
    assert_eq!(c.edits, vec![TimelineEdit::Move { clip: f.c2.id, to: FD * 25, track: None }]);
}

#[test]
fn moved_selection_keeps_relative_offsets() {
    let f = Fixture::new();
    let mut i = f.unlinked();
    click(&mut i, pt(x(25.0), Y_V1), none());
    click(&mut i, pt(x(70.0), Y_V1), M::SHIFT);
    let c = drag(&mut i, pt(x(25.0), Y_V1), pt(x(35.0), Y_V1), none()).unwrap();
    assert_eq!(c.undo_name, "Move Clips");
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.start), Some(FD * 30));
    assert_eq!(clip_of(&c.timeline, f.c3.id).map(|c| c.start), Some(FD * 70));
}

#[test]
fn move_clamps_at_zero() {
    let f = Fixture::new();
    let mut i = f.interaction();
    let c = drag(&mut i, pt(x(25.0), Y_V1), pt(x(-50.0), Y_V1), none()).unwrap();
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.start), Some(sq_core_time::Time::ZERO));
}

#[test]
fn move_snaps_clip_end_to_neighbour_start() {
    let f = Fixture::new();
    let mut on = f.interaction_with(TimelineTool::Selection, true, true, None);
    let c = drag(&mut on, pt(x(25.0), Y_V1), pt(x(44.0), Y_V1), none()).unwrap();
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.start), Some(FD * 40)); // end on 60
    let mut off = f.interaction();
    let d = drag(&mut off, pt(x(25.0), Y_V1), pt(x(44.0), Y_V1), none()).unwrap();
    assert_eq!(clip_of(&d.timeline, f.c2.id).map(|c| c.start), Some(FD * 39));
}

#[test]
fn move_snaps_to_playhead_and_reports_snap_time() {
    let f = Fixture::new();
    let mut i = f.interaction_with(TimelineTool::Selection, true, true, Some(FD * 100));
    i.mouse_down(pt(x(65.0), Y_V1), none());
    i.mouse_dragged(pt(x(84.0), Y_V1), none()); // c3 start 79 -> end 99 snaps to playhead 100
    assert_eq!(i.snap_time(), Some(FD * 100));
    assert_eq!(clip_of(i.preview(), f.c3.id).map(|c| c.start), Some(FD * 80));
    i.mouse_up(pt(x(84.0), Y_V1), none());
    assert_eq!(i.snap_time(), None);
}

#[test]
fn cross_track_move_onto_other_video_track() {
    let f = Fixture::new();
    let mut i = f.interaction();
    let c = drag(&mut i, pt(x(25.0), Y_V1), pt(x(25.0), Y_V2), none()).unwrap();
    let ids = |n: usize| c.timeline.tracks[n].clips().iter().map(|c| c.id).collect::<Vec<_>>();
    assert_eq!(ids(1), vec![f.c2.id]);
    assert_eq!(ids(0), vec![f.c1.id, f.c3.id]);
}

#[test]
fn video_clip_dragged_over_audio_rows_stays_on_video() {
    let f = Fixture::new();
    let mut i = f.interaction();
    i.mouse_down(pt(x(65.0), Y_V1), none());
    i.mouse_dragged(pt(x(70.0), Y_A2), none());
    let c = i.mouse_up(pt(x(70.0), Y_A2), none()).unwrap();
    assert_eq!(c.timeline.tracks.len(), 4);
    assert!(c.timeline.tracks[0].clips().iter().any(|k| k.id == f.c3.id)); // nearest video row is V1
}

#[test]
fn drag_above_top_track_adds_video_track() {
    let f = Fixture::new();
    let mut i = f.interaction();
    i.mouse_down(pt(x(65.0), Y_V1), none());
    i.mouse_dragged(pt(x(65.0), 4.0), none());
    assert_eq!(i.preview().tracks.len(), 5);
    let c = i.mouse_up(pt(x(65.0), 4.0), none()).unwrap();
    assert_eq!(c.timeline.tracks.len(), 5);
    let added = &c.timeline.tracks[4];
    assert_eq!(added.kind, TrackKind::Video);
    assert_eq!(added.clips().iter().map(|c| c.id).collect::<Vec<_>>(), vec![f.c3.id]);
    assert_eq!(c.undo_name, "Move Clip");
    assert_eq!(c.edits.len(), 2);
}

#[test]
fn drag_below_last_track_adds_audio_track() {
    let f = Fixture::new();
    let mut i = f.interaction();
    let c = drag(&mut i, pt(x(15.0), Y_A2), pt(x(15.0), 400.0), none()).unwrap();
    assert_eq!(c.timeline.tracks.len(), 5);
    assert_eq!(c.timeline.tracks[4].kind, TrackKind::Audio);
    assert_eq!(c.timeline.tracks[4].clips().iter().map(|c| c.id).collect::<Vec<_>>(), vec![f.a2c.id]);
    assert!(c.timeline.tracks[3].clips().is_empty());
}

/// A video clip dragged onto the "V+" ghost strip (under the last track) creates a new top video track.
#[test]
fn drag_onto_video_ghost_strip_adds_video_track() {
    let f = Fixture::new();
    let mut i = f.interaction();
    let ghost = i.geometry.ghost_rows(&f.timeline()).into_iter().find(|g| g.kind == TrackKind::Video).unwrap();
    let y = ghost.y + ghost.height / 2.0;
    let c = drag(&mut i, pt(x(65.0), Y_V1), pt(x(65.0), y), none()).unwrap();
    assert_eq!(c.timeline.tracks.len(), 5);
    assert_eq!(c.timeline.tracks[4].kind, TrackKind::Video);
    assert_eq!(c.timeline.tracks[4].clips().iter().map(|c| c.id).collect::<Vec<_>>(), vec![f.c3.id]);
}

#[test]
fn drag_back_inside_drops_the_new_track() {
    let f = Fixture::new();
    let mut i = f.interaction();
    i.mouse_down(pt(x(65.0), Y_V1), none());
    i.mouse_dragged(pt(x(65.0), 4.0), none());
    i.mouse_dragged(pt(x(70.0), Y_V1), none());
    assert_eq!(i.preview().tracks.len(), 4);
    let c = i.mouse_up(pt(x(70.0), Y_V1), none()).unwrap();
    assert_eq!(c.timeline.tracks.len(), 4);
}

#[test]
fn command_drag_is_insert_move() {
    let f = Fixture::new();
    let mut i = f.interaction();
    let c = drag(&mut i, pt(x(65.0), Y_V1), pt(x(25.0), Y_V1), M::COMMAND).unwrap();
    assert_eq!(c.undo_name, "Insert Move");
    assert_eq!(clip_of(&c.timeline, f.c3.id).map(|c| c.start), Some(FD * 20));
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.start), Some(FD * 40)); // pushed right
}

#[test]
fn moving_onto_locked_track_is_rejected() {
    let mut f = Fixture::new();
    f.v1.is_locked = true;
    let mut i = f.interaction();
    i.mouse_down(pt(x(25.0), Y_V1), none());
    i.mouse_dragged(pt(x(35.0), Y_V1), none());
    assert!(i.is_rejected());
    assert_eq!(i.preview(), i.timeline());
    assert_eq!(i.rejection_message(), Some("A selected clip is on a locked track."));
    assert!(i.mouse_up(pt(x(35.0), Y_V1), none()).is_none());
    assert_eq!(i.released_rejection(), Some("A selected clip is on a locked track."));
}

#[test]
fn cancel_restores_base() {
    let f = Fixture::new();
    let mut i = f.interaction();
    i.mouse_down(pt(x(25.0), Y_V1), none());
    i.mouse_dragged(pt(x(35.0), Y_V1), none());
    i.cancel();
    assert_eq!(i.preview(), i.timeline());
    assert!(i.mouse_up(pt(x(35.0), Y_V1), none()).is_none());
}

#[test]
fn tiny_jitter_is_a_click_not_a_move() {
    let f = Fixture::new();
    let mut i = f.interaction();
    i.mouse_down(pt(x(25.0), Y_V1), none());
    i.mouse_dragged(pt(x(25.0) + 2.0, Y_V1), none());
    assert!(i.mouse_up(pt(x(25.0) + 2.0, Y_V1), none()).is_none());
}

// MARK: Delete

#[test]
fn delete_lifts_and_shift_delete_ripples() {
    let f = Fixture::new();
    let mut i = f.unlinked();
    click(&mut i, pt(x(25.0), Y_V1), none());
    let mut j = i.clone();
    let lift = i.delete_selection(false).unwrap();
    assert_eq!(lift.undo_name, "Delete");
    assert_eq!(lift.timeline.tracks[0].clips().iter().map(|c| c.id).collect::<Vec<_>>(), vec![f.c1.id, f.c3.id]);
    assert_eq!(clip_of(&lift.timeline, f.c3.id).map(|c| c.start), Some(FD * 60));
    assert!(i.selection().is_empty());
    let rip = j.delete_selection(true).unwrap();
    assert_eq!(rip.undo_name, "Ripple Delete");
    assert_eq!(clip_of(&rip.timeline, f.c3.id).map(|c| c.start), Some(FD * 40));
}

#[test]
fn delete_with_empty_selection_does_nothing() {
    let mut i = Fixture::new().interaction();
    assert!(i.delete_selection(false).is_none());
}

// MARK: Edge trim (selection tool)

#[test]
fn selection_tool_trims_tail_and_head() {
    let f = Fixture::new();
    let mut i = f.interaction();
    // c3 tail: x end = X(80); handle 6 pt.
    let t = drag(&mut i, pt(x(80.0) - 1.0, Y_V1), pt(x(80.0) + 19.0, Y_V1), none()).unwrap();
    assert_eq!(t.undo_name, "Trim Clip");
    assert_eq!(clip_of(&t.timeline, f.c3.id).map(|c| c.timeline().end()), Some(FD * 85));
    let mut j = f.interaction();
    let h = drag(&mut j, pt(x(60.0) + 1.0, Y_V1), pt(x(60.0) + 21.0, Y_V1), none()).unwrap();
    let c3 = clip_of(&h.timeline, f.c3.id).unwrap();
    assert_eq!(c3.start, FD * 65); // head trim leaves a gap, tail stays
    assert_eq!(c3.timeline().end(), FD * 80);
    assert_eq!(c3.timeline().duration, FD * 15);
}

#[test]
fn trim_snaps_edge_to_neighbour() {
    let f = Fixture::new();
    let mut i = f.interaction_with(TimelineTool::Selection, true, true, None);
    // c2 tail 40 -> drag +19 frames = 59 -> snaps to c3 start 60 (within 2 frames).
    let t = drag(&mut i, pt(x(40.0) - 1.0, Y_V1), pt(x(59.0) - 1.0, Y_V1), none()).unwrap();
    assert_eq!(clip_of(&t.timeline, f.c2.id).map(|c| c.timeline().end()), Some(FD * 60));
}

// MARK: Ripple (B)

#[test]
fn ripple_tool_shortens_and_shifts_followers() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::RippleEdit);
    let c = drag(&mut i, pt(x(40.0) - 1.0, Y_V1), pt(x(35.0) - 1.0, Y_V1), none()).unwrap();
    assert_eq!(c.undo_name, "Ripple Trim");
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.timeline().end()), Some(FD * 35));
    assert_eq!(clip_of(&c.timeline, f.c3.id).map(|c| c.start), Some(FD * 55));
}

#[test]
fn ripple_tool_in_body_uses_nearest_edge() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::RippleEdit);
    // Left half of c3 -> head edge; dragging right by 5 shortens it, start stays (Premiere).
    let c = drag(&mut i, pt(x(63.0), Y_V1), pt(x(68.0), Y_V1), none()).unwrap();
    let c3 = clip_of(&c.timeline, f.c3.id).unwrap();
    assert_eq!(c3.start, FD * 60);
    assert_eq!(c3.timeline().duration, FD * 15);
}

// MARK: Roll (N)

#[test]
fn roll_moves_the_cut_between_neighbours() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::RollEdit);
    let c = drag(&mut i, pt(x(20.0) - 1.0, Y_V1), pt(x(23.0) - 1.0, Y_V1), none()).unwrap();
    assert_eq!(c.undo_name, "Move Edit");
    assert_eq!(clip_of(&c.timeline, f.c1.id).map(|c| c.timeline().end()), Some(FD * 23));
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.start), Some(FD * 23));
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.timeline().end()), Some(FD * 40));
    // Grabbing the right side of the cut (c2 head) does the same.
    let mut j = f.tool(TimelineTool::RollEdit);
    let d = drag(&mut j, pt(x(20.0) + 1.0, Y_V1), pt(x(17.0) + 1.0, Y_V1), none()).unwrap();
    assert_eq!(clip_of(&d.timeline, f.c2.id).map(|c| c.start), Some(FD * 17));
}

#[test]
fn roll_without_adjacent_clip_does_nothing() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::RollEdit);
    assert!(drag(&mut i, pt(x(80.0) - 1.0, Y_V1), pt(x(85.0), Y_V1), none()).is_none());
}

// MARK: Slip (Y) and slide (U)

#[test]
fn slip_shifts_source_and_keeps_position() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Slip);
    let c = drag(&mut i, pt(x(30.0), Y_V1), pt(x(34.0), Y_V1), none()).unwrap();
    assert_eq!(c.undo_name, "Slip Clip");
    let s = clip_of(&c.timeline, f.c2.id).unwrap();
    assert_eq!(s.start, FD * 20);
    assert_eq!(s.source.start, FD * 46); // dragging right pulls earlier media into view
    assert_eq!(s.timeline().duration, FD * 20);
}

#[test]
fn slip_two_up_follows_the_drag_and_ends_with_it() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Slip);
    assert!(i.slip_two_up().is_none());
    i.mouse_down(pt(x(30.0), Y_V1), none());
    i.mouse_dragged(pt(x(34.0), Y_V1), none());
    let t = i.slip_two_up().unwrap();
    assert_eq!(t.clip, f.c2.id);
    assert_eq!(t.head_time, FD * 20); // the clip stays, its content moves
    assert_eq!(t.tail_time, FD * 39);
    assert_eq!(t.source_head, FD * 46);
    assert_eq!(t.source_tail, FD * 65);
    assert_eq!(t.offset, FD * -4); // dragging right pulls earlier media
    assert_eq!(t.offset_label(FD), "-4 f");
    i.mouse_dragged(pt(x(26.0), Y_V1), none());
    assert_eq!(i.slip_two_up().map(|t| t.offset), Some(FD * 4));
    i.mouse_up(pt(x(26.0), Y_V1), none());
    assert!(i.slip_two_up().is_none());
}

#[test]
fn slip_moves_keyframes_with_content_and_variant_keeps_them() {
    let mut f = Fixture::new();
    let key = Keyframe::new(uid(), FD * 5, 0.5);
    let key_id = key.id;
    f.c2.animation.opacity.track = KeyframeTrack::with_keys(vec![key]);
    f.v1 = track(TrackKind::Video, vec![f.c1.clone(), f.c2.clone(), f.c3.clone()]);
    let mut i = f.tool(TimelineTool::Slip);
    let plain = drag(&mut i, pt(x(30.0), Y_V1), pt(x(34.0), Y_V1), none()).unwrap();
    let p = clip_of(&plain.timeline, f.c2.id).unwrap();
    assert_eq!(p.source.start, FD * 46);
    assert_eq!(p.animation.opacity.track.key(key_id).map(|k| k.time), Some(FD * 9)); // key stays on its source frame
    let mut j = f.tool(TimelineTool::Slip);
    j.tool_state.slip_keyframes_stay = true;
    let stay = drag(&mut j, pt(x(30.0), Y_V1), pt(x(34.0), Y_V1), none()).unwrap();
    assert_eq!(stay.undo_name, "Slip Clip (Keyframes Stay)");
    let s = clip_of(&stay.timeline, f.c2.id).unwrap();
    assert_eq!(s.source.start, FD * 46);
    assert_eq!(s.animation.opacity.track.key(key_id).map(|k| k.time), Some(FD * 5)); // key stays on the timeline
}

#[test]
fn slide_moves_clip_and_adjusts_neighbour() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Slide);
    let c = drag(&mut i, pt(x(30.0), Y_V1), pt(x(33.0), Y_V1), none()).unwrap();
    assert_eq!(c.undo_name, "Slide Clip");
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.start), Some(FD * 23));
    assert_eq!(clip_of(&c.timeline, f.c2.id).map(|c| c.source), Some(f.c2.source));
    assert_eq!(clip_of(&c.timeline, f.c1.id).map(|c| c.timeline().end()), Some(FD * 23));
}

#[test]
fn slip_and_slide_show_the_offset_while_dragging() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Slip);
    i.mouse_down(pt(x(30.0), Y_V1), none());
    i.mouse_dragged(pt(x(34.0), Y_V1), none());
    assert_eq!(i.move_hint(), Some("Slip -4 f"));
    i.mouse_dragged(pt(x(30.0), Y_V1), none());
    assert_eq!(i.move_hint(), None);
    i.mouse_up(pt(x(30.0), Y_V1), none());
    assert_eq!(i.move_hint(), None);
    let mut j = f.tool(TimelineTool::Slide);
    j.mouse_down(pt(x(30.0), Y_V1), none());
    j.mouse_dragged(pt(x(33.0), Y_V1), none());
    assert_eq!(j.move_hint(), Some("Slide +3 f"));
    j.mouse_up(pt(x(33.0), Y_V1), none());
    assert_eq!(j.move_hint(), None);
}

// MARK: Razor (C)

#[test]
fn razor_cuts_clip_and_linked_partner() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Razor);
    let c = click(&mut i, pt(x(10.0), Y_V1), none()).unwrap();
    assert_eq!(c.undo_name, "Blade");
    assert_eq!(c.timeline.tracks[0].clips().len(), 4);
    assert_eq!(c.timeline.tracks[2].clips().len(), 2); // partner cut too
    assert_eq!(c.timeline.tracks[0].clips()[1].start, FD * 10);
    assert_eq!(
        c.edits,
        vec![TimelineEdit::AddEdit {
            at: FD * 10,
            tracks: Some(vec![c.timeline.tracks[0].id, c.timeline.tracks[2].id])
        }]
    );
}

#[test]
fn dragging_the_razor_shows_a_hint_and_cuts_nothing_more() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Razor);
    i.mouse_down(pt(x(10.0), Y_V1), none());
    i.mouse_dragged(pt(x(20.0), Y_V1), none());
    assert_eq!(i.move_hint(), Some(TimelineInteraction::RAZOR_DRAG_HINT));
    i.mouse_up(pt(x(20.0), Y_V1), none());
    assert_eq!(i.move_hint(), None);
}

#[test]
fn razor_with_option_cuts_only_the_clicked_track() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Razor);
    let c = click(&mut i, pt(x(10.0), Y_V1), M::OPTION).unwrap();
    assert_eq!(c.timeline.tracks[0].clips().len(), 4);
    assert_eq!(c.timeline.tracks[2].clips().len(), 1);
}

#[test]
fn razor_with_shift_cuts_all_tracks() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Razor);
    let c = click(&mut i, pt(x(15.0), Y_V1), M::SHIFT).unwrap();
    assert_eq!(c.undo_name, "Blade All Tracks");
    assert_eq!(c.timeline.tracks[0].clips().len(), 4);
    assert_eq!(c.timeline.tracks[2].clips().len(), 2);
    assert_eq!(c.timeline.tracks[3].clips().len(), 2); // unlinked a2c spans frame 15 too (10..<20)
    assert_eq!(c.edits, vec![TimelineEdit::AddEdit { at: FD * 15, tracks: None }]);
}

#[test]
fn razor_in_gap_does_nothing_and_preview_shows_cut_before_release() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Razor);
    assert!(click(&mut i, pt(x(50.0), Y_V1), none()).is_none());
    i.mouse_down(pt(x(70.0), Y_V1), none());
    assert_eq!(i.preview().tracks[0].clips().len(), 4);
    assert_eq!(i.timeline().tracks[0].clips().len(), 3);
    assert!(i.mouse_up(pt(x(70.0), Y_V1), none()).is_some());
}

#[test]
fn razor_shift_click_in_gap_cuts_all_tracks_at_that_time() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Razor);
    // Frame 15 on V2 (empty row): all other tracks are cut at 15, in one undo step.
    let c = click(&mut i, pt(x(15.0), Y_V2), M::SHIFT).unwrap();
    assert_eq!(c.undo_name, "Blade All Tracks");
    assert_eq!(c.timeline.tracks[0].clips().len(), 4);
    assert_eq!(c.edits, vec![TimelineEdit::AddEdit { at: FD * 15, tracks: None }]);
    let mut j = f.tool(TimelineTool::Razor);
    assert!(click(&mut j, pt(x(15.0), Y_V2), none()).is_none()); // without Shift an empty spot does nothing
}

#[test]
fn razor_snaps_to_playhead() {
    let f = Fixture::new();
    let mut i = f.interaction_with(TimelineTool::Razor, true, true, Some(FD * 71));
    let c = click(&mut i, pt(x(70.0), Y_V1), none()).unwrap();
    assert_eq!(c.timeline.tracks[0].clips()[3].start, FD * 71);
}

// MARK: Track select forward (A)

#[test]
fn track_select_forward_selects_clip_and_everything_after_on_every_track() {
    let f = Fixture::new();
    let mut i = f.interaction_with(TimelineTool::TrackSelectForward, false, false, None);
    click(&mut i, pt(x(25.0), Y_V1), none());
    assert_eq!(*i.selection(), set(&[f.c2.id, f.c3.id])); // nothing else reaches past frame 20 except c2/c3
    let mut j = f.interaction_with(TimelineTool::TrackSelectForward, false, false, None);
    click(&mut j, pt(x(12.0), Y_V1), none()); // Premiere: a plain click spans all tracks
    assert_eq!(*j.selection(), set(&[f.c1.id, f.c2.id, f.c3.id, f.a1.id, f.a2c.id]));
    click(&mut j, pt(x(50.0), Y_V1), none()); // gap: from there on
    assert_eq!(*j.selection(), set(&[f.c3.id]));
}

#[test]
fn track_select_forward_with_shift_limits_to_the_clicked_track() {
    let f = Fixture::new();
    let mut i = f.interaction_with(TimelineTool::TrackSelectForward, false, false, None);
    click(&mut i, pt(x(12.0), Y_V1), M::SHIFT);
    assert_eq!(*i.selection(), set(&[f.c1.id, f.c2.id, f.c3.id])); // video track V1 only
}

#[test]
fn track_select_backward_selects_clip_and_everything_before_it() {
    let f = Fixture::new();
    let mut i = f.interaction_with(TimelineTool::TrackSelectForward, false, false, None);
    i.tool_state.select_backward = true;
    click(&mut i, pt(x(25.0), Y_V1), none()); // c2 ends at 40: everything starting before that
    assert_eq!(*i.selection(), set(&[f.c1.id, f.c2.id, f.a1.id, f.a2c.id]));
    click(&mut i, pt(x(50.0), Y_V1), none()); // gap: everything starting before the click
    assert_eq!(*i.selection(), set(&[f.c1.id, f.c2.id, f.a1.id, f.a2c.id]));
    click(&mut i, pt(x(25.0), Y_V1), M::SHIFT); // Shift: the clicked track only
    assert_eq!(*i.selection(), set(&[f.c1.id, f.c2.id]));
}

// MARK: Hand (H)

#[test]
fn hand_pans_the_view_and_never_edits() {
    let f = Fixture::new();
    let mut i = f.tool(TimelineTool::Hand);
    i.geometry.scroll_x = 100.0;
    i.geometry.scroll_y = 10.0;
    i.mouse_down(pt(400.0, 60.0), none());
    i.mouse_dragged(pt(370.0, 70.0), none());
    assert_eq!(i.geometry.scroll_x, 130.0);
    assert_eq!(i.geometry.scroll_y, 0.0);
    i.mouse_dragged(pt(600.0, 60.0), none());
    assert_eq!(i.geometry.scroll_x, 0.0); // clamped
    assert!(i.mouse_up(pt(600.0, 60.0), none()).is_none());
    assert_eq!(i.preview(), i.timeline());
}

// MARK: Keys

#[test]
fn tool_keys() {
    let pairs = [
        ('v', TimelineTool::Selection),
        ('A', TimelineTool::TrackSelectForward),
        ('b', TimelineTool::RippleEdit),
        ('n', TimelineTool::RollEdit),
        ('y', TimelineTool::Slip),
        ('u', TimelineTool::Slide),
        ('c', TimelineTool::Razor),
        ('h', TimelineTool::Hand),
        ('z', TimelineTool::Zoom),
    ];
    for (k, t) in pairs {
        assert_eq!(TimelineTool::from_key(k), Some(t));
        assert_eq!(TimelineTool::from_key(t.key()), Some(t));
    }
    assert_eq!(TimelineTool::from_key('k'), None);
}

#[test]
fn clicks_on_ruler_and_header_are_ignored() {
    let f = Fixture::new();
    let mut i = f.interaction();
    assert!(click(&mut i, pt(x(10.0), 5.0), none()).is_none());
    assert!(click(&mut i, pt(100.0, Y_V1), none()).is_none());
    assert!(i.selection().is_empty());
}

// Pre-release timeline audit.

/// Esc during a marquee: the selection the marquee made goes, the one from before the press comes back.
#[test]
fn cancelled_marquee_restores_selection() {
    let f = Fixture::new();
    let mut i = f.interaction();
    click(&mut i, pt(x(65.0), Y_V1), none());
    assert_eq!(*i.selection(), set(&[f.c3.id]));
    i.mouse_down(pt(x(45.0), Y_V2), M::SHIFT);
    i.mouse_dragged(pt(x(5.0), Y_A1), M::SHIFT);
    assert!(i.selection().contains(&f.c1.id));
    i.cancel();
    assert_eq!(*i.selection(), set(&[f.c3.id]));
    assert!(i.marquee().is_none());
}

/// Without Shift the press clears the selection first; Esc still brings back what was selected before it.
#[test]
fn cancelled_plain_marquee_restores_selection() {
    let f = Fixture::new();
    let mut i = f.interaction();
    click(&mut i, pt(x(65.0), Y_V1), none());
    assert_eq!(*i.selection(), set(&[f.c3.id]));
    i.mouse_down(pt(x(45.0), Y_V2), none());
    i.mouse_dragged(pt(x(5.0), Y_A1), none());
    assert!(!i.selection().contains(&f.c3.id));
    i.cancel();
    assert_eq!(*i.selection(), set(&[f.c3.id]));
}

/// A marquee sweeping over a locked track leaves its clips out (Premiere: locked clips cannot be selected), so a
/// following Delete is not refused for them.
#[test]
fn marquee_skips_locked_track_clips() {
    let mut f = Fixture::new();
    f.a_t2.is_locked = true;
    let mut i = f.unlinked();
    drag(&mut i, pt(x(45.0), Y_V2), pt(x(1.0), Y_A2), none());
    assert!(i.selection().contains(&f.c1.id));
    assert!(!i.selection().contains(&f.a2c.id));
    assert!(i.delete_selection(false).is_some());
}

// Gestures (w71): the track phase is the pointer, frame by frame, with no smoothing and no stickiness.

fn start_of(i: &TimelineInteraction, id: Id) -> Option<sq_core_time::Time> {
    clip_of(i.preview(), id).map(|c| c.start)
}

#[test]
fn a_clip_drag_follows_the_pointer_at_every_move() {
    let f = Fixture::new();
    let mut i = f.interaction();
    i.mouse_down(pt(x(65.0), Y_V1), none());
    for n in 1..=30 {
        i.mouse_dragged(pt(x(65.0 + f64::from(n)), Y_V1), none());
        assert_eq!(start_of(&i, f.c3.id), Some(FD * (60 + i64::from(n))), "move {n}");
    }
    // Coalesced moves: a jump straight to the last point lands exactly where the stepped path did.
    i.mouse_dragged(pt(x(80.0), Y_V1), none());
    assert_eq!(start_of(&i, f.c3.id), Some(FD * 75));
}

#[test]
fn snapping_is_not_sticky_outside_its_radius() {
    let f = Fixture::new();
    let mut i = f.interaction_with(TimelineTool::Selection, true, true, None);
    i.mouse_down(pt(x(65.0), Y_V1), none());
    // c2 ends at frame 40: the start is pulled onto it within 8 pt (under 2 frames), and only there.
    for (pointer, expect) in [(58.0, 58), (50.0, 50), (45.0, 45), (43.0, 43), (42.0, 42), (41.0, 40), (40.0, 40)] {
        i.mouse_dragged(pt(x(pointer + 5.0), Y_V1), none());
        assert_eq!(start_of(&i, f.c3.id), Some(FD * expect), "pointer at {pointer}");
        assert_eq!(i.snap_time().is_some(), expect == 40, "pointer at {pointer}");
    }
    // Leaving the radius again: back to the pointer at once, no hysteresis.
    i.mouse_dragged(pt(x(64.0), Y_V1), none());
    assert_eq!(start_of(&i, f.c3.id), Some(FD * 59));
    assert!(i.snap_time().is_none());
}

#[test]
fn a_trim_edge_drag_follows_the_pointer_at_every_move() {
    let f = Fixture::new();
    let mut i = f.interaction();
    i.mouse_down(pt(x(80.0) - 1.0, Y_V1), none());
    for n in 1..=10 {
        i.mouse_dragged(pt(x(80.0 - f64::from(n)) - 1.0, Y_V1), none());
        let end = clip_of(i.preview(), f.c3.id).map(|c| c.timeline().end());
        assert_eq!(end, Some(FD * (80 - i64::from(n))), "move {n}");
    }
}
