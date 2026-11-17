//! Port of MirroredMoveTests.swift: a track change of k lanes mirrors to the linked partner of the other kind.

use crate::test_support::*;
use crate::timeline_interaction::TimelineInteraction;
use sq_core_edit::timeline_edits::TimelineEditsExt;
use sq_core_model::{Clip, Timeline, TrackKind};
use sq_core_time::{Id, TimeRange};
use sq_editor_session::{TimelineCommit, TimelineTool, ToolState};

// Rows (no captions): V2 y22..<42, V1 42..<74, A1 74..<100, A2 100..<120.
const Y_V2: f64 = 42.0;
const Y_V1: f64 = 82.0;
const Y_A1: f64 = 116.0;

struct Fx {
    v: Clip,
    a: Clip,
    timeline: Timeline,
}

fn fx() -> Fx {
    let link = uid();
    let mk20 = |name: &str, kind| {
        let mut c = Clip::new(uid(), name, uid(), kind, TimeRange::new(sq_core_time::Time::ZERO, FD * 20), FD * 10);
        c.link = Some(link);
        c
    };
    let v = mk20("v", TrackKind::Video);
    let a = mk20("a", TrackKind::Audio);
    let timeline = timeline(vec![
        track(TrackKind::Video, vec![v.clone()]),
        track(TrackKind::Video, vec![]),
        track(TrackKind::Audio, vec![a.clone()]),
        track(TrackKind::Audio, vec![]),
    ]);
    Fx { v, a, timeline }
}

fn interaction(t: Timeline) -> TimelineInteraction {
    let mut i = interaction_of(t);
    i.tool_state = ToolState::new(TimelineTool::Selection, false, true);
    i
}

fn track_of(t: &Timeline, id: Id) -> Option<usize> {
    t.tracks.iter().position(|tr| tr.clips().iter().any(|c| c.id == id))
}

fn commit(
    i: &mut TimelineInteraction,
    a: sq_uikit::keyframe_graph_geometry::Point,
    b: sq_uikit::keyframe_graph_geometry::Point,
) -> TimelineCommit {
    drag(i, a, b, none()).unwrap()
}

#[test]
fn video_up_moves_linked_audio_down() {
    let f = fx();
    let mut i = interaction(f.timeline.clone());
    let c = commit(&mut i, pt(x(15.0), Y_V1), pt(x(15.0), Y_V2));
    assert_eq!(track_of(&c.timeline, f.v.id), Some(1)); // V2
    assert_eq!(track_of(&c.timeline, f.a.id), Some(3)); // A2
    assert_eq!(c.undo_name, "Move Clip");
}

#[test]
fn audio_down_moves_linked_video_up() {
    let f = fx();
    let mut i = interaction(f.timeline.clone());
    let c = commit(&mut i, pt(x(15.0), Y_A1), pt(x(15.0), 144.0));
    assert_eq!(track_of(&c.timeline, f.a.id), Some(3));
    assert_eq!(track_of(&c.timeline, f.v.id), Some(1));
}

#[test]
fn drag_past_top_creates_video_and_mirrored_audio_tracks() {
    let f = fx();
    let mut i = interaction(f.timeline.clone());
    let c = commit(&mut i, pt(x(15.0), Y_V1), pt(x(15.0), 23.0 - 14.0));
    let t = &c.timeline;
    let video_idx: Vec<usize> = (0..t.tracks.len()).filter(|&k| t.tracks[k].kind == TrackKind::Video).collect();
    let audio_idx: Vec<usize> = (0..t.tracks.len()).filter(|&k| t.tracks[k].kind == TrackKind::Audio).collect();
    assert_eq!(video_idx.len(), 3);
    assert_eq!(audio_idx.len(), 3);
    assert_eq!(track_of(t, f.v.id), video_idx.last().copied());
    assert_eq!(track_of(t, f.a.id), audio_idx.last().copied());
}

#[test]
fn partner_stays_at_first_track_when_mirror_would_leave_the_timeline() {
    // Video on V2, audio on A1: moving the video down to V1 cannot move the audio above A1.
    let f = fx();
    let mut t = f.timeline.clone();
    let v2 = t.tracks[1].id;
    <Timeline as TimelineEditsExt>::move_clip(
        &mut t,
        f.v.id,
        FD * 10,
        Some(v2),
        &Default::default(),
        None,
        &mut sq_core_time::SequentialIds::default(),
    )
    .unwrap();
    let mut i = interaction(t);
    let c = commit(&mut i, pt(x(15.0), Y_V2), pt(x(15.0), Y_V1));
    assert_eq!(track_of(&c.timeline, f.v.id), Some(0));
    assert_eq!(track_of(&c.timeline, f.a.id), Some(2));
}

#[test]
fn small_wobble_inside_the_row_keeps_the_track() {
    let f = fx();
    let mut i = interaction(f.timeline.clone());
    // 4 pt below the V1 row bottom is still V1 (hysteresis), so a plain horizontal move commits without a track change.
    i.mouse_down(pt(x(15.0), Y_V1), none());
    i.mouse_dragged(pt(x(20.0), 74.0 + 4.0), none());
    let c = i.mouse_up(pt(x(20.0), 74.0 + 4.0), none()).unwrap();
    assert_eq!(track_of(&c.timeline, f.v.id), Some(0));
    assert_eq!(track_of(&c.timeline, f.a.id), Some(2));
}
