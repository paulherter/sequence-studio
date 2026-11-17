//! Ported from `TimelineMacParityTests` (SQDrawTimeline): zoom ease, fit toggle and the zoom tool on the shared panel.

use crate::panel::{SessionView, TimelinePanel};
use crate::tests::{clip, panel_over, timeline, track};
use sq_core_edit::source_edit_placement::SourceEditPlacementExt as _;
use sq_core_model::{LabelResolver, TrackKind};
use sq_core_time::{Time, TimeRange};
use sq_draw::{InputEvent, InputKey, InputModifiers, UiCx};
use sq_timeline_ui::{TimelineGeometry, TimelineZoom};
use sq_uikit::design_tokens::sq_tokens::spacing;
use sq_uikit::editor_command::EditorTool;
use std::cell::Cell;
use std::collections::BTreeSet;
use std::rc::Rc;

const FD: Time = Time::new(1, 25);

/// 1000 x 400 pt, two tracks with a 30 s clip each.
fn panel() -> (TimelinePanel, Rc<Cell<f64>>) {
    let t = timeline(vec![
        track(1, TrackKind::Video, vec![clip(1, 0, 750, TrackKind::Video)]),
        track(2, TrackKind::Video, vec![clip(2, 0, 750, TrackKind::Video)]),
    ]);
    panel_over(&t, 1000.0, 400.0)
}

fn key(p: &mut TimelinePanel, k: InputKey) {
    p.key(k, InputModifiers::NONE, &mut UiCx::new());
}

#[test]
fn a_zoom_key_lands_on_the_key_step_at_once() {
    let (mut p, _) = panel();
    p.set_zoom(p.geometry.points_per_second * 4.0, Some(TimelineGeometry::CONTENT_ORIGIN_X));
    let start = p.geometry.points_per_second;
    key(&mut p, InputKey::Character('='));
    assert!((p.geometry.points_per_second - start * TimelineZoom::KEY_STEP).abs() < 1e-6 && !p.is_zooming());
}

#[test]
fn a_second_zoom_key_continues_from_the_first() {
    let (mut p, _) = panel();
    p.set_zoom(p.geometry.points_per_second * 2.0, Some(TimelineGeometry::CONTENT_ORIGIN_X));
    let start = p.geometry.points_per_second;
    key(&mut p, InputKey::Character('='));
    key(&mut p, InputKey::Character('='));
    let want = (start * TimelineZoom::KEY_STEP * TimelineZoom::KEY_STEP).min(*p.zoom_limits().end());
    assert!((p.geometry.points_per_second - want).abs() < 1e-6 && !p.is_zooming());
}

#[test]
fn a_wheel_scroll_ends_the_running_ease() {
    let (mut p, _) = panel();
    p.zoom_to_fit();
    assert!(p.is_zooming());
    p.set_zoom(p.geometry.points_per_second * 1.5, None);
    assert!(!p.is_zooming());
}

#[test]
fn backslash_fits_then_returns_to_the_previous_level() {
    let (mut p, now) = panel();
    p.set_zoom(p.geometry.points_per_second * 6.0, Some(TimelineGeometry::CONTENT_ORIGIN_X));
    p.geometry.scroll_x = 100.0;
    let before = (p.geometry.points_per_second, p.geometry.scroll_x);
    p.zoom_to_fit();
    now.set(now.get() + 1.0);
    p.tick();
    assert!((p.geometry.points_per_second - p.fit_scale()).abs() < 1e-6);
    p.zoom_to_fit();
    now.set(now.get() + 1.0);
    p.tick();
    assert!((p.geometry.points_per_second - before.0).abs() < 1e-6 && (p.geometry.scroll_x - before.1).abs() < 1e-3);
}

#[test]
fn backslash_fits_in_out_when_set_but_zoom_limits_keep_the_whole_sequence() {
    let (mut p, now) = panel();
    let mut t = p.timeline.clone();
    t.set_marked_range(Some(TimeRange::new(FD * 50, FD * 50)));
    p.sync(SessionView {
        timeline: &t,
        selection: &BTreeSet::new(),
        captions: &BTreeSet::new(),
        playhead: Time::ZERO,
        selected_transition: None,
        labels: LabelResolver::default(),
        line_keys: BTreeSet::new(),
    });
    let whole = p.whole_sequence_fit_scale();
    assert!(p.fit_scale() > whole * 5.0, "2 s of 30 s fill the width");
    assert!(*p.zoom_limits().start() <= whole);
    p.zoom_to_fit();
    now.set(now.get() + 1.0);
    p.tick();
    assert!((p.geometry.points_per_second - p.fit_scale()).abs() < 1e-6);
    assert_eq!(p.geometry.x(FD * 50), TimelineGeometry::CONTENT_ORIGIN_X + f64::from(spacing::LG));
}

#[test]
fn a_zoom_tool_click_zooms_around_the_pointer_at_once() {
    let (mut p, _) = panel();
    let start = p.geometry.points_per_second;
    p.tool_state_mut().select(EditorTool::Zoom);
    let y = (TimelineGeometry::RULER_HEIGHT + 20.0) as f32;
    let mut ui = UiCx::new();
    p.handle(&InputEvent::MouseDown { x: 500.0, y, modifiers: InputModifiers::NONE }, &mut ui);
    p.handle(&InputEvent::MouseUp { x: 500.0, y }, &mut ui);
    assert!(!p.is_zooming() && p.geometry.points_per_second > start);
}

#[test]
fn a_new_sequence_forgets_the_zoom_remembered_for_the_old_one() {
    let (mut p, now) = panel();
    let fit = p.geometry.points_per_second;
    p.set_zoom(fit * 6.0, Some(TimelineGeometry::CONTENT_ORIGIN_X));
    p.zoom_to_fit();
    now.set(now.get() + 1.0);
    p.tick();
    assert!((p.geometry.points_per_second - fit).abs() < 1e-6, "fitted; the 6x level is remembered");
    // Another sequence (an 8 s one) opens and fits itself.
    let mut other = timeline(vec![track(1, TrackKind::Video, vec![clip(1, 0, 200, TrackKind::Video)])]);
    other.id = sq_core_time::Id::from_u128(4242);
    p.sync(SessionView {
        timeline: &other,
        selection: &BTreeSet::new(),
        captions: &BTreeSet::new(),
        playhead: Time::ZERO,
        selected_transition: None,
        labels: LabelResolver::default(),
        line_keys: BTreeSet::new(),
    });
    p.layout_px(sq_draw::Rect::new(0.0, 0.0, 1000.0, 400.0), 1.0);
    let fit_other = p.geometry.points_per_second;
    assert!((fit_other - p.fit_scale()).abs() < 1e-6 && fit_other > fit * 3.0);
    // The first Fit press there stays at its own fit; it must not jump to the 6x level of the old sequence.
    p.zoom_to_fit();
    now.set(now.get() + 1.0);
    p.tick();
    assert!((p.geometry.points_per_second - fit_other).abs() < 1e-6);
}
