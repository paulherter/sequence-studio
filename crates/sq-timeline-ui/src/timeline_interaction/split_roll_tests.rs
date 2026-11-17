//! Port of SplitRollTests.swift: Opt-drag on a cut between linked A/V clips moves only the audio edit (J / L cut).

use crate::test_support::*;
use crate::timeline_interaction::TimelineInteraction;
use sq_core_model::TrackKind;
use sq_core_time::Time;
use sq_editor_session::{GestureModifiers as M, TimelineTool, ToolState};

const Y_V1: f64 = 70.0;

fn make() -> TimelineInteraction {
    let c = |start: i64, kind: TrackKind, l| {
        let mut c = mk(start, 20, kind, Some(l));
        c.source = sq_core_time::TimeRange::new(FD * 50, FD * 20);
        c
    };
    let (l1, l2) = (uid(), uid());
    let v = track(TrackKind::Video, vec![c(0, TrackKind::Video, l1), c(20, TrackKind::Video, l2)]);
    let a = track(TrackKind::Audio, vec![c(0, TrackKind::Audio, l1), c(20, TrackKind::Audio, l2)]);
    let t = timeline(vec![v, track(TrackKind::Video, vec![]), a, track(TrackKind::Audio, vec![])]);
    let mut i = interaction_of(t);
    i.tool_state = ToolState::new(TimelineTool::Selection, false, true);
    i
}

#[test]
fn option_drag_on_a_cut_moves_only_the_audio_edit() {
    let mut i = make();
    let m = M::OPTION;
    i.mouse_down(pt(x(20.0) - 1.0, Y_V1), m);
    i.mouse_dragged(pt(x(15.0), Y_V1), m);
    i.mouse_dragged(pt(x(12.0), Y_V1), m);
    let ghost = i.split_roll_ghost().unwrap();
    assert_eq!(ghost.cut, FD * 20);
    assert_eq!(ghost.offset, FD * -8);
    assert!(ghost.label(FD).starts_with("J cut"));
    let commit = i.mouse_up(pt(x(12.0), Y_V1), m).unwrap();
    assert_eq!(commit.undo_name, "Split Edit Audio");
    let v = &commit.timeline.tracks[0];
    let a = &commit.timeline.tracks[2];
    assert_eq!(v.clips().iter().map(|c| c.start).collect::<Vec<_>>(), vec![Time::ZERO, FD * 20]); // picture stays
    assert_eq!(a.clips().iter().map(|c| c.start).collect::<Vec<_>>(), vec![Time::ZERO, FD * 12]); // audio of the second clip leads
    assert!(i.split_roll_ghost().is_none());
}

#[test]
fn drag_right_makes_an_l_cut() {
    let mut i = make();
    let m = M::OPTION;
    i.mouse_down(pt(x(20.0) - 1.0, Y_V1), m);
    i.mouse_dragged(pt(x(24.0), Y_V1), m);
    i.mouse_dragged(pt(x(26.0), Y_V1), m);
    assert!(i.split_roll_ghost().is_some_and(|g| g.label(FD).starts_with("L cut")));
    let commit = i.mouse_up(pt(x(26.0), Y_V1), m).unwrap();
    assert_eq!(
        commit.timeline.tracks[2].clips().iter().map(|c| c.start).collect::<Vec<_>>(),
        vec![Time::ZERO, FD * 26]
    );
}

#[test]
fn without_option_the_edge_still_trims() {
    let mut i = make();
    i.mouse_down(pt(x(20.0) - 1.0, Y_V1), none());
    i.mouse_dragged(pt(x(18.0), Y_V1), none());
    i.mouse_dragged(pt(x(16.0), Y_V1), none());
    assert!(i.split_roll_ghost().is_none());
    i.mouse_up(pt(x(16.0), Y_V1), none());
}
