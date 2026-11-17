//! Ported from `TimelineKeyParityTests` and `TimelineDeleteKeyTests` (SQDrawTimeline): tool key holds, Esc, held Delete,
//! and Delete on a gap or a selected transition.

use crate::panel_tests::{Rig, uid};
use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_draw::{InputKey, InputModifiers, UiCx};
use sq_editor_session::TimelineTool;
use sq_library::library_folder_store::MemorySettings;
use sq_uikit::editor_command::EditorCommand;
use std::cell::Cell;
use std::collections::BTreeSet;
use std::rc::Rc;

const FD: Time = Time::new(1, 25);
const NONE: InputModifiers = InputModifiers::NONE;

fn clip(n: u128, start: i64, frames: i64) -> Clip {
    Clip::new(uid(n), "c", uid(n + 500), TrackKind::Video, TimeRange::new(Time::ZERO, FD * frames), FD * start)
}

/// One 100-frame clip; the panel clock is `now`.
fn rig() -> (Rig, Rc<Cell<f64>>) {
    let mut v1 = Track::new(uid(1), TrackKind::Video);
    v1.set_clips(vec![clip(10, 0, 100)]);
    let mut r = Rig::new(Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v1]), 1000.0, 400.0);
    let now = Rc::new(Cell::new(100.0));
    let c = Rc::clone(&now);
    r.p.clock = Box::new(move || c.get());
    (r, now)
}

/// A at 0-2 s, a gap, B at 4-6 s; the gap is selected with a click.
fn gap_rig() -> Rig {
    let mut v1 = Track::new(uid(1), TrackKind::Video);
    v1.set_clips(vec![clip(10, 0, 50), clip(11, 100, 50)]);
    let mut r = Rig::new(Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v1]), 1000.0, 400.0);
    let row = r.p.rows()[0].clone();
    let (x, y) = (r.p.geometry.x(Time::new(3, 1)), row.y + row.height / 2.0);
    r.down(x, y);
    r.up(x, y);
    r
}

fn tool(r: &Rig) -> TimelineTool {
    r.p.tool_state().timeline_tool()
}

#[test]
fn escape_goes_back_to_the_selection_tool() {
    let (mut r, _) = rig();
    r.key(InputKey::Character('b'), NONE);
    assert_ne!(tool(&r), TimelineTool::Selection);
    assert_eq!(r.key(InputKey::Escape, NONE), Some(Vec::new()));
    assert_eq!(tool(&r), TimelineTool::Selection);
    assert_eq!(r.key(InputKey::Escape, NONE), None); // the second Esc is the host's
}

#[test]
fn a_held_delete_is_swallowed() {
    let (mut r, _) = rig();
    let mut ui = UiCx::new();
    let out = ui.with_key_repeat(true, |ui| r.p.key(InputKey::Backspace, NONE, ui));
    assert_eq!(out, Some(Vec::new()));
}

#[test]
fn a_held_tool_key_is_temporary() {
    let (mut r, now) = rig();
    r.key(InputKey::Character('b'), NONE);
    assert_eq!(tool(&r), TimelineTool::RippleEdit);
    now.set(now.get() + 0.6);
    r.p.key_up(InputKey::Character('b'));
    assert_eq!(tool(&r), TimelineTool::Selection); // a long hold returns to the tool from before
}

#[test]
fn a_tapped_tool_key_stays() {
    let (mut r, now) = rig();
    r.key(InputKey::Character('c'), NONE);
    now.set(now.get() + 0.1);
    r.p.key_up(InputKey::Character('c'));
    assert_eq!(tool(&r), TimelineTool::Razor);
}

#[test]
fn a_repeat_of_the_tool_key_does_not_restart_the_hold() {
    let (mut r, now) = rig();
    r.key(InputKey::Character('b'), NONE);
    now.set(now.get() + 0.5);
    let mut ui = UiCx::new();
    ui.with_key_repeat(true, |ui| r.p.key(InputKey::Character('b'), NONE, ui));
    r.p.key_up(InputKey::Character('b'));
    assert_eq!(tool(&r), TimelineTool::Selection);
}

#[test]
fn losing_the_window_ends_a_tool_hold() {
    let (mut r, now) = rig();
    r.key(InputKey::Character('h'), NONE);
    now.set(now.get() + 1.0);
    r.p.release_held_keys();
    assert_eq!(tool(&r), TimelineTool::Selection);
    r.p.key_up(InputKey::Character('h'));
    assert_eq!(tool(&r), TimelineTool::Selection); // the late key up changes nothing
}

#[test]
fn escape_ends_the_hold_for_good() {
    let (mut r, now) = rig();
    r.key(InputKey::Character('b'), NONE);
    r.key(InputKey::Escape, NONE);
    r.key(InputKey::Character('c'), NONE);
    now.set(now.get() + 1.0);
    r.p.key_up(InputKey::Character('b'));
    assert_eq!(tool(&r), TimelineTool::Razor); // the stale hold of B must not undo the later tool
}

#[test]
fn delete_on_a_selected_gap_closes_it() {
    let mut r = gap_rig();
    assert!(r.p.interaction.gap_selection().is_some(), "the click selected the gap");
    let actions = r.key(InputKey::Backspace, NONE).unwrap_or_default();
    assert!(!actions.is_empty(), "Delete on a gap is not swallowed");
    let clips = r.tl().tracks[0].clips();
    assert!(clips.len() == 2 && clips[1].start == clips[0].start + clips[0].source.duration, "B moved up against A");
    r.s.undo();
    assert_eq!(r.tl().tracks[0].clips()[1].start, FD * 100);
}

#[test]
fn the_delete_command_from_a_menu_closes_the_gap_too() {
    let mut r = gap_rig();
    let mut d = MemorySettings::default();
    let line = r.p.run_view_command(&EditorCommand::Delete, &mut r.s, true, None, true, &mut d);
    assert!(line.is_some(), "taken by the timeline");
    let clips = r.tl().tracks[0].clips();
    assert_eq!(clips[1].start, clips[0].start + clips[0].source.duration);
}

#[test]
fn a_selected_transition_is_removed_before_the_clip_selection() {
    let mut r = gap_rig();
    r.p.sync(crate::panel::SessionView {
        timeline: r.s.active_timeline().expect("timeline"),
        selection: &BTreeSet::from([uid(10)]),
        captions: &BTreeSet::new(),
        playhead: Time::ZERO,
        selected_transition: Some(Id::from_u128(77)),
        labels: Default::default(),
        line_keys: BTreeSet::new(),
    });
    assert_eq!(r.key(InputKey::Backspace, NONE), None, "the host removes the transition first (the Mac order)");
}

#[test]
fn hold_s_flips_snapping_only_during_a_drag() {
    let mut r = gap_rig();
    let before = r.p.snapping();
    r.key(InputKey::Character('s'), NONE); // no drag: nothing flips
    assert_eq!(r.p.snapping(), before);
    let row = r.p.rows()[0].clone();
    r.down(r.p.geometry.x(FD * 50), row.y + row.height / 2.0);
    r.key(InputKey::Character('s'), NONE);
    assert_eq!(r.p.snapping(), !before);
    r.p.set_snap_inverted(false);
    assert_eq!(r.p.snapping(), before);
}
