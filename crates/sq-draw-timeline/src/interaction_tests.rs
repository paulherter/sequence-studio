//! The timeline gestures end to end: a real session behind a panel, pointer and key events in, the session result and a
//! drawn frame checked out (the same route the app takes through `session_bridge`).

use crate::panel_tests::{Rig, uid};
use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Time, TimeRange};
use sq_draw::{InputEvent, InputKey, InputModifiers};
use sq_editor_session::TimelineTool;

const FD: Time = Time::new(1, 25);

fn clip(n: u128, start: i64) -> Clip {
    // Source starts at frame 50 so slip has room on both sides.
    Clip::new(uid(n), "c", uid(n + 500), TrackKind::Video, TimeRange::new(FD * 50, FD * 100), FD * start)
}

/// V1 with three adjacent 100-frame clips, V2 empty; a 1000 x 400 pt panel.
fn rig() -> Rig {
    let mut v1 = Track::new(uid(1), TrackKind::Video);
    v1.set_clips(vec![clip(10, 0), clip(11, 100), clip(12, 200)]);
    let v2 = Track::new(uid(2), TrackKind::Video);
    Rig::new(Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v1, v2]), 1000.0, 400.0)
}

fn row_y(r: &Rig, track: usize) -> f64 {
    let id = r.tl().tracks[track].id;
    let row = r.p.rows().into_iter().find(|x| x.track == id).expect("row");
    row.y + row.height / 2.0
}

/// Pixel x of a (fractional) frame.
fn x(r: &Rig, frame: f64) -> f64 {
    let x0 = r.p.geometry.x(Time::ZERO);
    x0 + frame * (r.p.geometry.x(FD) - x0)
}

fn starts(r: &Rig, track: usize) -> Vec<Time> {
    r.tl().tracks[track].clips().iter().map(|c| c.start).collect()
}

/// A frame drawn from the panel's current state paints something.
fn painted(r: &mut Rig) -> bool {
    let mut cv = sq_draw::Canvas::with_size(1000.0, 400.0, None, 1.0);
    r.p.draw_timeline(&mut cv);
    cv.list.quads().len() > 10
}

/// Press at frame `a`, drag in ten steps to frame `b` (rows `ya`, `yb`), release.
fn gesture(r: &mut Rig, a: f64, ya: f64, b: f64, yb: f64) {
    let (from, to) = ((x(r, a), ya), (x(r, b), yb));
    r.down(from.0, from.1);
    for i in 1..=10 {
        let k = f64::from(i) / 10.0;
        r.drag(from.0 + (to.0 - from.0) * k, from.1 + (to.1 - from.1) * k);
    }
    r.up(to.0, to.1);
}

fn with_tool(r: &mut Rig, tool: TimelineTool) {
    r.p.tool_state_mut().tool = tool;
}

#[test]
fn a_drag_moves_a_clip_along_its_track_and_snaps_to_the_neighbor() {
    let mut r = rig();
    // Free the room first: move the last clip far right, then drag the first one near the gap start.
    let y = row_y(&r, 0);
    gesture(&mut r, 250.0, y, 450.0, y);
    assert_eq!(starts(&r, 0)[2], FD * 400, "the third clip moved 200 frames");
    r.down(x(&r, 150.0), y);
    r.drag(x(&r, 150.0) + 40.0, y);
    assert!(painted(&mut r), "a frame during the drag is drawn");
    r.up(x(&r, 150.0) + 40.0, y);
    assert!(r.tl().tracks[0].clips().len() == 3 && painted(&mut r));
}

#[test]
fn a_drag_across_tracks_lands_the_clip_on_the_other_track() {
    let mut r = rig();
    let (ya, yb) = (row_y(&r, 0), row_y(&r, 1));
    gesture(&mut r, 250.0, ya, 250.0, yb);
    assert_eq!(r.tl().tracks[1].clips().len(), 1, "the clip is on V2");
    assert_eq!(r.tl().tracks[0].clips().len(), 2);
    assert!(painted(&mut r));
}

#[test]
fn trimming_the_tail_and_the_head_changes_the_clip() {
    let mut r = rig();
    let y = row_y(&r, 0);
    gesture(&mut r, 300.0 - 1.0, y, 280.0, y); // grabs one frame inside the edge
    assert_eq!(r.tl().tracks[0].clips()[2].timeline().duration, FD * 81, "tail trimmed by 19 frames");
    gesture(&mut r, 200.0 + 1.0, y, 210.0, y);
    assert!(r.tl().tracks[0].clips()[2].start != FD * 200, "head trimmed");
    assert!(painted(&mut r));
}

#[test]
fn the_ripple_tool_pulls_the_following_clips_along() {
    let mut r = rig();
    with_tool(&mut r, TimelineTool::RippleEdit);
    let y = row_y(&r, 0);
    gesture(&mut r, 100.0 - 1.0, y, 80.0, y);
    assert_eq!(starts(&r, 0), vec![Time::ZERO, FD * 81, FD * 181]);
    assert!(painted(&mut r));
}

#[test]
fn the_roll_tool_moves_a_cut_without_changing_the_length() {
    let mut r = rig();
    with_tool(&mut r, TimelineTool::RollEdit);
    let y = row_y(&r, 0);
    gesture(&mut r, 100.0, y, 120.0, y);
    assert_eq!(starts(&r, 0), vec![Time::ZERO, FD * 120, FD * 200]);
    assert!(painted(&mut r));
}

#[test]
fn the_slip_tool_moves_the_content_of_the_clip() {
    let mut r = rig();
    with_tool(&mut r, TimelineTool::Slip);
    let y = row_y(&r, 0);
    gesture(&mut r, 150.0, y, 170.0, y);
    let c = &r.tl().tracks[0].clips()[1];
    assert_eq!((c.start, c.source.start), (FD * 100, FD * 30), "same place, other part of the source");
}

#[test]
fn the_slide_tool_moves_the_clip_and_trims_the_neighbors() {
    let mut r = rig();
    let y = row_y(&r, 0);
    with_tool(&mut r, TimelineTool::Slide);
    // Leftwards: the right neighbor still has source before its head, the left one only gives up its tail.
    gesture(&mut r, 150.0, y, 130.0, y);
    assert_eq!(starts(&r, 0)[1], FD * 80, "the middle clip slid ({:?})", r.s.last_error());
    assert_eq!(starts(&r, 0)[2], FD * 180, "the next clip grew at its head");
    assert!(painted(&mut r));
}

#[test]
fn a_razor_click_cuts_the_clip() {
    let mut r = rig();
    with_tool(&mut r, TimelineTool::Razor);
    let y = row_y(&r, 0);
    r.down(x(&r, 150.0), y);
    r.up(x(&r, 150.0), y);
    assert_eq!(r.tl().tracks[0].clips().len(), 4);
    assert!(painted(&mut r));
}

#[test]
fn a_press_in_the_ruler_scrubs_the_playhead() {
    let mut r = rig();
    r.down(x(&r, 120.0), 8.0);
    r.drag(x(&r, 140.0), 8.0);
    assert_eq!(r.s.playhead(), FD * 140);
    r.up(x(&r, 140.0), 8.0);
    assert!(painted(&mut r));
}

#[test]
fn a_marquee_over_empty_space_selects_the_clips_it_touches() {
    let mut r = rig();
    let (y0, y1) = (row_y(&r, 1), row_y(&r, 0));
    gesture(&mut r, 20.0, y0 + 8.0, 130.0, y1 - 8.0);
    assert_eq!(r.s.selection().len(), 2);
    assert!(painted(&mut r));
}

#[test]
fn delete_removes_the_selected_clip() {
    let mut r = rig();
    let y = row_y(&r, 0);
    r.down(x(&r, 150.0), y);
    r.up(x(&r, 150.0), y);
    assert_eq!(r.s.selection().len(), 1);
    assert!(r.key(InputKey::Delete, InputModifiers::NONE).is_some());
    assert!(r.tl().tracks[0].clips().len() < 3);
}

// Gestures (w71): the track phase is the pointer, move by move.

#[test]
fn a_ruler_scrub_is_the_pointer_at_every_move() {
    let mut r = rig();
    r.down(x(&r, 120.0), 8.0);
    assert_eq!(r.s.playhead(), FD * 120);
    for f in 121..=135 {
        r.drag(x(&r, f64::from(f)), 8.0);
        assert_eq!(r.s.playhead(), FD * i64::from(f), "frame {f}");
    }
    // Coalesced: a jump lands where the stepped path would have.
    r.drag(x(&r, 128.0), 8.0);
    assert_eq!(r.s.playhead(), FD * 128);
    r.up(x(&r, 128.0), 8.0);
}

#[test]
fn a_clip_drag_follows_the_pointer_and_escape_restores() {
    let mut r = rig();
    let y = row_y(&r, 0);
    let before = starts(&r, 0);
    r.down(x(&r, 250.0), y);
    let moved: Vec<Time> = (1..=6)
        .map(|n| {
            r.drag(x(&r, 250.0 + f64::from(n) * 6.0), y);
            r.p.interaction.preview().tracks[0].clips()[2].start
        })
        .collect();
    for (n, s) in moved.iter().enumerate() {
        assert_eq!(*s, FD * (200 + 6 * (n as i64 + 1)), "move {}", n + 1);
    }
    assert!(r.key(InputKey::Escape, InputModifiers::NONE).is_some());
    r.up(x(&r, 286.0), y);
    assert_eq!(starts(&r, 0), before, "Esc leaves the project as it was");
}

#[test]
fn the_zoom_bar_pan_moves_one_to_one() {
    let mut r = rig();
    let pps = r.p.geometry.points_per_second * 6.0;
    r.p.set_zoom(pps, Some(sq_timeline_ui::TimelineGeometry::CONTENT_ORIGIN_X));
    let (lo, hi) = r.p.zoom_bar_handles();
    let bar = r.p.zoom_bar_rect();
    let y = bar.y + bar.height / 2.0;
    let start = bar.x + (lo + hi) / 2.0 * bar.width;
    r.down(start, y);
    let h0 = r.p.zoom_bar_handles().0;
    let mut last = h0;
    let mut first_step = 0.0;
    for n in 1..=5 {
        r.drag(start + f64::from(n) * 3.0, y);
        let h = r.p.zoom_bar_handles().0;
        if n == 1 {
            first_step = h - h0;
            // 3 pt of pointer is 3 / track width of the bar (the track may be inset a little).
            assert!((first_step * bar.width / 3.0 - 1.0).abs() < 0.1, "knob step {first_step}");
        }
        assert!(h > last, "step {n}: the bar knob follows the pointer");
        assert!((h - h0 - f64::from(n) * first_step).abs() < 1e-9, "step {n}: linear in the pointer");
        last = h;
    }
    r.up(start + 15.0, y);
}

#[test]
fn dragging_a_zoom_bar_end_changes_the_zoom() {
    let mut r = rig();
    let pps = r.p.geometry.points_per_second * 6.0;
    r.p.set_zoom(pps, Some(sq_timeline_ui::TimelineGeometry::CONTENT_ORIGIN_X));
    let (lo, hi) = r.p.zoom_bar_handles();
    let bar = r.p.zoom_bar_rect();
    let y = bar.y + bar.height / 2.0;
    let before = r.p.geometry.points_per_second;
    // The upper end knob: dragging it left shows less of the timeline, so the zoom grows.
    let start = bar.x + sq_uikit::zoom_scroll_bar_gesture::KeyframeZoomBarGeometry::new(bar.width).x_for_fraction(hi);
    r.down(start, y);
    for n in 1..=5 {
        r.drag(start - f64::from(n) * 8.0, y);
    }
    r.up(start - 40.0, y);
    let after = r.p.geometry.points_per_second;
    assert!(after != before, "a handle drag changes the zoom ({before} -> {after}), lo {lo} hi {hi}");
}

fn click(r: &mut Rig, frame: f64, y: f64) {
    r.down(x(r, frame), y);
    r.up(x(r, frame), y);
}

fn selected(r: &Rig) -> Vec<sq_core_time::Id> {
    r.s.selection().iter().copied().collect()
}

#[test]
fn pressing_an_unselected_clip_selects_it_alone_and_a_drag_moves_only_it() {
    let mut r = rig();
    let (y, y2) = (row_y(&r, 0), row_y(&r, 1));
    click(&mut r, 50.0, y);
    assert_eq!(selected(&r), vec![uid(10)], "the first click selects the first clip");
    gesture(&mut r, 250.0, y, 250.0, y2);
    assert_eq!(selected(&r), vec![uid(12)], "the press replaced the selection");
    assert_eq!(starts(&r, 0), vec![Time::ZERO, FD * 100], "the selected neighbor stays on V1");
    assert_eq!(starts(&r, 1), vec![FD * 200], "only the dragged clip moved to V2");
}

#[test]
fn undo_then_pressing_an_unselected_clip_still_drags_only_it() {
    let mut r = rig();
    let (y, y2) = (row_y(&r, 0), row_y(&r, 1));
    gesture(&mut r, 50.0, y, 50.0, y2); // the first clip to V2, selected
    r.s.undo();
    r.sync();
    click(&mut r, 150.0, y);
    gesture(&mut r, 250.0, y, 250.0, y2);
    assert_eq!(starts(&r, 0), vec![Time::ZERO, FD * 100], "the clip selected before stays");
    assert_eq!(starts(&r, 1), vec![FD * 200]);
}

/// The undo reveals the clips it changed as the selection (the Swift `revealChange`), so a clip a ripple pushed is
/// selected afterwards and a drag on it moves the whole selection, as for any selected clip.
#[test]
fn after_an_undo_the_changed_clips_are_the_selection_and_a_drag_moves_them_together() {
    let mut r = rig();
    let (y, y2) = (row_y(&r, 0), row_y(&r, 1));
    click(&mut r, 150.0, y);
    r.key(InputKey::Backspace, InputModifiers::SHIFT);
    r.s.undo();
    r.sync();
    assert_eq!(r.tl().tracks[0].clips().len(), 3, "the delete is undone");
    assert_eq!(selected(&r), vec![uid(11), uid(12)], "the restored clip and the one the ripple pushed");
    gesture(&mut r, 250.0, y, 250.0, y2);
    assert_eq!(starts(&r, 0), vec![Time::ZERO], "both selected clips left V1 together");
    assert_eq!(starts(&r, 1), vec![FD * 100, FD * 200]);
}

#[test]
fn dragging_a_selected_clip_moves_the_whole_selection() {
    let mut r = rig();
    let y = row_y(&r, 0);
    click(&mut r, 150.0, y);
    r.send(InputEvent::MouseDown { x: x(&r, 250.0) as f32, y: y as f32, modifiers: InputModifiers::SHIFT });
    r.up(x(&r, 250.0), y);
    assert_eq!(selected(&r), vec![uid(11), uid(12)], "the second clip joined the selection");
    gesture(&mut r, 150.0, y, 200.0, y);
    assert_eq!(starts(&r, 0), vec![Time::ZERO, FD * 150, FD * 250], "both selected clips moved by the drag");
}

#[test]
fn dragging_the_left_of_two_selected_clips_to_another_track_moves_both() {
    let mut r = rig();
    let (y, y2) = (row_y(&r, 0), row_y(&r, 1));
    click(&mut r, 150.0, y);
    r.send(InputEvent::MouseDown { x: x(&r, 250.0) as f32, y: y as f32, modifiers: InputModifiers::SHIFT });
    r.up(x(&r, 250.0), y);
    gesture(&mut r, 150.0, y, 150.0, y2);
    assert_eq!(starts(&r, 1), vec![FD * 100, FD * 200], "v1 {:?} err {:?}", starts(&r, 0), r.s.last_error());
}
