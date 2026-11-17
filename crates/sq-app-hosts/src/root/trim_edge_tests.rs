//! A press in a clip's edge zone trims, through the whole root with the event shape a real window sends: a hover onto
//! the edge, the press, several small drags, the release (PRUEF-LIN-3 D1).

use super::dead_commands_tests::{Scenario, demo_session};
use super::*;
use sq_core_time::Time;
use sq_draw::InputModifiers;
use sq_runtime::FakeClock;
use std::sync::Arc;

fn standard(scale: f32) -> (AppRoot, crate::test_rig::Rig) {
    let dir = crate::test_rig::unique_dir("sq-trim-edge");
    std::fs::create_dir_all(&dir).expect("dir");
    let mut root = crate::standard_root_with_source(
        &dir,
        Arc::new(FakeClock::new()),
        DrawTheme::default(),
        crate::MonitorPicture::default(),
        Box::new(sq_editor_session::StubProgramEngine::new()),
        crate::MonitorPicture::default(),
    )
    .expect("root");
    let mut rig = crate::test_rig::Rig::new(demo_session(Scenario::Plain)).at_scale(scale);
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    root.sync(&rig.session);
    (root, rig)
}

/// (start, duration) of the first video clip.
fn first_video(rig: &crate::test_rig::Rig) -> (Time, Time) {
    let t = rig.session.active_timeline().expect("sequence");
    let c =
        t.tracks.iter().find(|k| k.kind == sq_core_model::TrackKind::Video).and_then(|k| k.clips().first().cloned());
    let c = c.expect("a video clip");
    (c.start, c.timeline().duration)
}

fn video_track(rig: &crate::test_rig::Rig) -> sq_core_time::Id {
    let t = rig.session.active_timeline().expect("sequence");
    t.tracks.iter().find(|k| k.kind == sq_core_model::TrackKind::Video).map(|k| k.id).expect("video track")
}

/// Hover onto `from`, press, drag in 2-point steps to `to` (all in points x scale), release.
fn gesture(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, y: f32, from_px: f32, to_px: f32) {
    let none = InputModifiers::NONE;
    r.handle(&InputEvent::MouseMoved { x: from_px, y }, &mut rig.cx());
    r.handle(&InputEvent::MouseDown { x: from_px, y, modifiers: none }, &mut rig.cx());
    let step = 2.0 * rig.scale * if to_px < from_px { -1.0 } else { 1.0 };
    let mut x = from_px;
    while (to_px - x) * step.signum() > step.abs() {
        x += step;
        r.handle(&InputEvent::MouseDragged { x, y, modifiers: none }, &mut rig.cx());
        r.pump(&mut rig.cx());
    }
    r.handle(&InputEvent::MouseDragged { x: to_px, y, modifiers: none }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x: to_px, y }, &mut rig.cx());
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
}

fn edge_trim(scale: f32, tail: bool, inside_pt: f32, dx_pt: f32, y_frac: f32) -> ((Time, Time), (Time, Time)) {
    edge_trim_with(scale, tail, inside_pt, dx_pt, y_frac, false)
}

/// `selected`: the clip (with its linked audio) is selected before the gesture, as in the real window test.
fn edge_trim_with(
    scale: f32,
    tail: bool,
    inside_pt: f32,
    dx_pt: f32,
    y_frac: f32,
    selected: bool,
) -> ((Time, Time), (Time, Time)) {
    let (mut r, mut rig) = standard(scale);
    if selected {
        let ids: std::collections::BTreeSet<_> = {
            let t = rig.session.active_timeline().expect("sequence");
            let v = t.tracks.iter().find(|k| k.kind == sq_core_model::TrackKind::Video).expect("video");
            let first = v.clips().first().cloned().expect("clip");
            t.tracks
                .iter()
                .flat_map(|k| k.clips())
                .filter(|c| c.id == first.id || c.link == first.link)
                .map(|c| c.id)
                .collect()
        };
        rig.session.select(ids, Default::default());
        r.sync(&rig.session);
    }
    let track = video_track(&rig);
    let before = first_video(&rig);
    let (x_edge, y) = {
        let p = &r.timeline.inner().panel;
        let t = if tail { before.0 + before.1 } else { before.0 };
        let y = p.pixel_y_body_of(track).expect("row");
        (p.pixel_x(t), y)
    };
    let _ = y_frac;
    let from = if tail { x_edge - inside_pt * scale } else { x_edge + inside_pt * scale };
    gesture(&mut r, &mut rig, y, from, from + dx_pt * scale);
    (before, first_video(&rig))
}

#[test]
fn dragging_the_tail_edge_left_shortens_the_clip_at_scale_1_and_2() {
    for scale in [1.0_f32, 2.0] {
        for inside in [0.5_f32, 2.0, 3.0, 5.0] {
            let (b, a) = edge_trim(scale, true, inside, -60.0, 0.7);
            assert!(a.1 < b.1, "scale {scale}, {inside} pt inside the tail: {b:?} -> {a:?}");
            assert_eq!(a.0, b.0, "the head stays");
        }
    }
}

#[test]
fn dragging_the_head_edge_right_shortens_the_clip_at_scale_1_and_2() {
    for scale in [1.0_f32, 2.0] {
        for inside in [0.5_f32, 2.0, 3.0, 5.0] {
            let (b, a) = edge_trim(scale, false, inside, 60.0, 0.7);
            assert!(a.1 < b.1, "scale {scale}, {inside} pt inside the head: {b:?} -> {a:?}");
        }
    }
}

#[test]
fn dragging_the_tail_edge_right_without_media_handles_changes_nothing() {
    let (b, a) = edge_trim(1.0, true, 2.0, 60.0, 0.7);
    assert_eq!(b, a, "the clip uses all its media; it cannot grow");
}

#[test]
fn a_trimmed_tail_can_be_dragged_out_again_while_the_media_has_handles() {
    let (mut r, mut rig) = standard(1.0);
    let track = video_track(&rig);
    let b = first_video(&rig);
    let y = r.timeline.inner().panel.pixel_y_body_of(track).expect("row");
    let x0 = r.timeline.inner().panel.pixel_x(b.0 + b.1);
    gesture(&mut r, &mut rig, y, x0 - 2.0, x0 - 62.0);
    let mid = first_video(&rig);
    assert!(mid.1 < b.1, "shortened: {b:?} -> {mid:?}");
    let x1 = r.timeline.inner().panel.pixel_x(mid.0 + mid.1);
    gesture(&mut r, &mut rig, y, x1 - 2.0, x1 + 30.0);
    let after = first_video(&rig);
    assert!(after.1 > mid.1, "the handle media came back: {mid:?} -> {after:?}");
}

#[test]
fn a_selected_clip_trims_from_either_edge_at_scale_1_and_2() {
    for scale in [1.0_f32, 2.0] {
        for tail in [true, false] {
            let dx = if tail { -60.0 } else { 60.0 };
            let (b, a) = edge_trim_with(scale, tail, 2.0, dx, 0.7, true);
            assert!(a.1 < b.1, "scale {scale}, tail {tail}, selected: {b:?} -> {a:?}");
        }
    }
}

/// Every pixel row of the clip, 3 px apart: no dead strip (name band, thumbnails, bars) may swallow an edge press.
#[test]
fn no_height_of_the_clip_row_swallows_an_edge_press() {
    for scale in [1.0_f32, 2.0] {
        for tail in [true, false] {
            let (mut probe, rig0) = standard(scale);
            let track = video_track(&rig0);
            let (top, bottom) = probe.timeline.inner().panel.pixel_row_of(track).expect("row");
            let mut y = top + 1.0;
            let mut dead = Vec::new();
            // The last pixels of a row are the track-height handle (deliberate), not a clip.
            while y < bottom - 5.0 * scale {
                let (mut r, mut rig) = standard(scale);
                let b = first_video(&rig);
                let x_edge = r.timeline.inner().panel.pixel_x(if tail { b.0 + b.1 } else { b.0 });
                let from = if tail { x_edge - 2.0 * scale } else { x_edge + 2.0 * scale };
                let dx = if tail { -60.0 } else { 60.0 } * scale;
                gesture(&mut r, &mut rig, y, from, from + dx);
                if first_video(&rig).1 >= b.1 {
                    dead.push(y);
                }
                y += 3.0;
            }
            assert!(dead.is_empty(), "scale {scale}, tail {tail}: no trim from y {dead:?} (row {top}..{bottom})");
        }
    }
}

/// The hover onto the edge zone shows the trim cursor before the press (head: trim in, tail: trim out).
#[test]
fn the_edge_zone_shows_the_trim_cursor_on_hover() {
    for scale in [1.0_f32, 2.0] {
        let (mut r, rig) = standard(scale);
        let track = video_track(&rig);
        let b = first_video(&rig);
        let p = &r.timeline.inner().panel;
        let y = p.pixel_y_body_of(track).expect("row");
        let none = InputModifiers::NONE;
        let tail = p.pixel_x(b.0 + b.1) - 3.0 * scale;
        let head = p.pixel_x(b.0) + 3.0 * scale;
        assert_eq!(p.cursor_at(tail, y, none), Some(sq_draw::ui_cx::DrawCursor::TrimOut), "tail at scale {scale}");
        assert_eq!(p.cursor_at(head, y, none), Some(sq_draw::ui_cx::DrawCursor::TrimIn), "head at scale {scale}");
    }
}

// MARK: Cuts (PRUEF-LIN-FEATURES-1 finding 8)
//
// The hot zone of an edge is `TimelineGeometry::MAX_TRIM_HANDLE_WIDTH` (6 pt, the Swift value) inside the clip, so a
// cut has a full zone on each side: the first clip's tail left of it, the second clip's head right of it.

/// (start, duration) of every V1 clip.
type Layout = Vec<(Time, Time)>;

fn v1_layout(rig: &crate::test_rig::Rig) -> Layout {
    let t = rig.session.active_timeline().expect("sequence");
    let v = t.tracks.iter().find(|k| k.kind == sq_core_model::TrackKind::Video).expect("video track");
    v.clips().iter().map(|c| (c.start, c.timeline().duration)).collect()
}

/// The demo clips as 8 s cuts of 10 s media, touching at 8 s: a 1 s handle on both sides of the cut, so a trim can
/// grow as well as shrink.
fn give_handles(rig: &mut crate::test_rig::Rig) {
    rig.session
        .perform_timeline("Handles", None, |t| {
            for track in &mut t.tracks {
                let clips: Vec<_> = track
                    .clips()
                    .iter()
                    .enumerate()
                    .map(|(n, c)| {
                        let mut c = c.clone();
                        c.source = sq_core_time::TimeRange::new(Time::seconds(1), Time::seconds(8));
                        c.media_duration = Some(Time::seconds(10));
                        c.start = Time::seconds(8 * i64::try_from(n).unwrap_or(0));
                        c
                    })
                    .collect();
                track.set_clips(clips);
            }
            Ok(())
        })
        .expect("handles");
}

/// A press `off_pt` points from the cut between the two demo clips (negative: inside the first clip's tail, positive:
/// inside the second clip's head), dragged `dx_pt` points, with `tool`. Returns V1 before and after.
fn cut_press(scale: f32, tool: sq_editor_session::TimelineTool, off_pt: f32, dx_pt: f32) -> (Layout, Layout) {
    let (mut r, mut rig) = standard(scale);
    give_handles(&mut rig);
    r.sync(&rig.session);
    r.timeline.inner().panel.tool_state_mut().tool = tool;
    let track = video_track(&rig);
    let before = v1_layout(&rig);
    let cut = before.first().map(|c| c.0 + c.1).expect("a clip");
    assert_eq!(before.get(1).map(|c| c.0), Some(cut), "the demo clips touch");
    let (x_cut, y) = {
        let p = &r.timeline.inner().panel;
        (p.pixel_x(cut), p.pixel_y_body_of(track).expect("row"))
    };
    let from = x_cut + off_pt * scale;
    gesture(&mut r, &mut rig, y, from, from + dx_pt * scale);
    (before, v1_layout(&rig))
}

const SCALES: [f32; 3] = [1.0, 1.5, 2.0];
/// Points inside the clip, from the very edge to just short of the zone's end.
const INSIDE: [f32; 5] = [0.5, 1.0, 3.0, 5.0, 5.9];

#[test]
fn select_tool_trims_the_tail_and_the_head_at_a_cut() {
    use sq_editor_session::TimelineTool::Selection;
    for scale in SCALES {
        for inside in INSIDE {
            // tail of the first clip: dragged left it ends earlier, start and the next clip stay
            let (b, a) = cut_press(scale, Selection, -inside, -40.0);
            assert_eq!((a[0].0, a[1]), (b[0].0, b[1]), "tail {inside} pt, scale {scale}: only the tail moves");
            assert!(a[0].1 < b[0].1, "tail {inside} pt, scale {scale}: {b:?} -> {a:?}");
            // head of the second clip: dragged right it starts later and keeps its end, the first clip stays
            let (b, a) = cut_press(scale, Selection, inside, 40.0);
            assert_eq!(a[0], b[0], "head {inside} pt, scale {scale}: the first clip stays");
            assert!(a[1].0 > b[1].0, "head {inside} pt, scale {scale}: {b:?} -> {a:?}");
            assert_eq!(a[1].0 + a[1].1, b[1].0 + b[1].1, "head {inside} pt, scale {scale}: the end stays");
        }
    }
}

#[test]
fn ripple_tool_trims_the_tail_and_the_head_at_a_cut() {
    use sq_editor_session::TimelineTool::RippleEdit;
    for scale in SCALES {
        for inside in INSIDE {
            // tail: the first clip ends earlier and the second clip follows it
            let (b, a) = cut_press(scale, RippleEdit, -inside, -40.0);
            assert!(a[0].1 < b[0].1, "tail {inside} pt, scale {scale}: {b:?} -> {a:?}");
            assert_eq!(a[1].0, a[0].0 + a[0].1, "tail {inside} pt, scale {scale}: the next clip follows the tail");
            // head: the second clip gets shorter, the first clip stays
            let (b, a) = cut_press(scale, RippleEdit, inside, 40.0);
            assert_eq!(a[0], b[0], "head {inside} pt, scale {scale}: the first clip stays");
            assert!(a[1].1 < b[1].1, "head {inside} pt, scale {scale}: {b:?} -> {a:?}");
        }
        // the handle lets the ripple tail grow, pushing the next clip right
        let (b, a) = cut_press(scale, RippleEdit, -1.0, 20.0);
        assert!(a[0].1 > b[0].1 && a[1].0 > b[1].0, "growing tail, scale {scale}: {b:?} -> {a:?}");
    }
}

/// Just past the zone the press is on the clip body: the whole clip moves, nothing is trimmed.
#[test]
fn a_press_past_the_zone_moves_the_clip_instead_of_trimming_it() {
    use sq_editor_session::TimelineTool::Selection;
    for scale in SCALES {
        let (b, a) = cut_press(scale, Selection, 6.5, 40.0);
        assert!(a[1].0 > b[1].0, "scale {scale}: the second clip moved: {b:?} -> {a:?}");
        assert_eq!(a[1].1, b[1].1, "scale {scale}: its length stays: {b:?} -> {a:?}");
    }
}
