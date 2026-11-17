//! Tests ported from `TimelinePanelTests`, `TimelineWheelTests`, `TimelineLaneCacheTests` and `TimelineSkinTokensTests`
//! (the pure-logic ones; the ones that need the header, band, item lane or caption code come with their owners).

use crate::action::TimelineAction;
use crate::panel::{SessionView, TimelinePanel};
use crate::skin::TimelineSkin;
use sq_core_model::{Clip, LabelResolver, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_draw::scroll::{ScrollGesture, ScrollPhase};
use sq_draw::{Color, DrawTheme, InputEvent, InputKey, InputModifiers, Rect, UiCx};
use sq_timeline_ui::{RubberBand, TimelineGeometry, TimelineZoom};
use sq_uikit::controls_grid::CGPoint;
use std::cell::Cell;
use std::collections::BTreeSet;
use std::rc::Rc;

const FD: Time = Time::new(1, 25);

pub(crate) fn uid(n: u128) -> Id {
    Id::from_u128((1 << 80) + n)
}

pub(crate) fn clip(n: u128, start: i64, frames: i64, kind: TrackKind) -> Clip {
    Clip::new(uid(n), "c", uid(n + 500), kind, TimeRange::new(Time::new(0, 1), FD * frames), FD * start)
}

pub(crate) fn track(n: u128, kind: TrackKind, clips: Vec<Clip>) -> Track {
    let mut t = Track::new(uid(n), kind);
    t.set_clips(clips);
    t
}

pub(crate) fn timeline(tracks: Vec<Track>) -> Timeline {
    Timeline::new(uid(9000), "t", SequenceFormat::new(FD), tracks)
}

/// A panel of `w x h` points at scale 1 over `t`, with a clock the test moves.
pub(crate) fn panel_over(t: &Timeline, w: f32, h: f32) -> (TimelinePanel, Rc<Cell<f64>>) {
    let now = Rc::new(Cell::new(100.0));
    let mut p = TimelinePanel::new(DrawTheme::default());
    let c = Rc::clone(&now);
    p.clock = Box::new(move || c.get());
    p.layout_px(Rect::new(0.0, 0.0, w, h), 1.0);
    p.sync(SessionView {
        timeline: t,
        selection: &BTreeSet::new(),
        captions: &BTreeSet::new(),
        playhead: Time::ZERO,
        selected_transition: None,
        labels: LabelResolver::default(),
        line_keys: BTreeSet::new(),
    });
    (p, now)
}

/// 1000 x 200 pt, ten video tracks (the tracks overflow vertically), 30 s of clips, zoomed in so time scrolls.
fn wheel_panel() -> (TimelinePanel, Rc<Cell<f64>>) {
    let mut tracks = vec![track(1, TrackKind::Video, vec![clip(1, 0, 750, TrackKind::Video)])];
    tracks.extend((0..9).map(|i| track(10 + i, TrackKind::Video, Vec::new())));
    let (mut p, now) = panel_over(&timeline(tracks), 1000.0, 200.0);
    let pps = p.geometry.points_per_second * 8.0;
    p.set_zoom(pps, Some(TimelineGeometry::CONTENT_ORIGIN_X));
    // These tests scroll from the top; the opening position (the base) is `ship_a_tests`' subject.
    p.geometry.scroll_y = 0.0;
    (p, now)
}

fn pad(dx: f64, dy: f64, phase: ScrollPhase, momentum: ScrollPhase) -> ScrollGesture {
    ScrollGesture {
        delta_x: dx,
        delta_y: dy,
        precise: true,
        phase,
        momentum_phase: momentum,
        ..ScrollGesture::default()
    }
}

pub(crate) fn at(x: f64, y: f64) -> CGPoint {
    CGPoint { x, y }
}

#[test]
fn a_mouse_wheel_line_is_one_notch_and_follows_the_appkit_sign() {
    let (mut p, _) = wheel_panel();
    p.geometry.scroll_x = 200.0;
    let wheel = |dy: f64| ScrollGesture { delta_y: dy, ..ScrollGesture::default() };
    p.scroll_wheel(at(500.0, 100.0), &wheel(-1.0), InputModifiers::NONE);
    assert_eq!(p.geometry.scroll_y, 48.0); // toward the user: the tracks move up
    p.scroll_wheel(at(500.0, 100.0), &wheel(0.5), InputModifiers::NONE);
    assert_eq!(p.geometry.scroll_y, 24.0);
    p.scroll_wheel(at(500.0, 100.0), &wheel(1.0), InputModifiers::SHIFT);
    assert_eq!((p.geometry.scroll_x, p.geometry.scroll_y), (152.0, 24.0)); // Shift: time only
}

#[test]
fn a_trackpad_swipe_locks_to_its_first_axis_at_the_trackpad_gain() {
    let (mut p, _) = wheel_panel();
    p.geometry.scroll_x = 200.0;
    p.geometry.scroll_y = 20.0;
    let y0 = p.geometry.scroll_y;
    // Mostly sideways start: horizontal, the held-back movement released at 1.6x; vertical is dropped.
    p.scroll_wheel(at(500.0, 100.0), &pad(-10.0, -3.0, ScrollPhase::Began, ScrollPhase::None), InputModifiers::NONE);
    assert_eq!((p.geometry.scroll_x, p.geometry.scroll_y), (216.0, y0));
    p.scroll_wheel(at(500.0, 100.0), &pad(0.0, -20.0, ScrollPhase::Changed, ScrollPhase::None), InputModifiers::NONE);
    assert_eq!((p.geometry.scroll_x, p.geometry.scroll_y), (216.0, y0));
    // A new, clearly vertical gesture scrolls the tracks 1:1.
    p.scroll_wheel(at(500.0, 100.0), &pad(0.0, -12.0, ScrollPhase::Began, ScrollPhase::None), InputModifiers::NONE);
    assert_eq!((p.geometry.scroll_x, p.geometry.scroll_y), (216.0, y0 + 12.0));
}

#[test]
fn option_scroll_zooms_and_the_momentum_tail_keeps_zooming() {
    let (mut p, _) = wheel_panel();
    let s0 = p.geometry.points_per_second;
    p.scroll_wheel(at(600.0, 100.0), &pad(0.0, 10.0, ScrollPhase::Began, ScrollPhase::None), InputModifiers::OPTION);
    let s1 = p.geometry.points_per_second;
    assert!((s1 / s0 - (10.0 * TimelineZoom::PRECISE_SCROLL_GAIN).exp()).abs() < 1e-9);
    p.scroll_wheel(at(600.0, 100.0), &pad(0.0, 0.0, ScrollPhase::Ended, ScrollPhase::None), InputModifiers::NONE);
    // Key released, the tail still zooms instead of scrolling sideways.
    p.scroll_wheel(at(600.0, 100.0), &pad(0.0, -5.0, ScrollPhase::None, ScrollPhase::Changed), InputModifiers::NONE);
    assert!((p.geometry.points_per_second / s1 - (-5.0 * TimelineZoom::PRECISE_SCROLL_GAIN).exp()).abs() < 1e-9);
}

#[test]
fn a_pinch_zooms_about_the_pointer_and_its_residue_does_not_scroll() {
    let (mut p, now) = wheel_panel();
    p.geometry.scroll_x = 100.0;
    let anchor = 400.0;
    let t = p.geometry.unsnapped_time(anchor);
    let secs = |t: Time| t.value() as f64 / t.timescale() as f64;
    let s0 = p.geometry.points_per_second;
    let pinch = |m: f64, phase| ScrollGesture {
        kind: sq_draw::scroll::GestureKind::Magnify(m),
        precise: true,
        phase,
        ..ScrollGesture::default()
    };
    p.scroll_wheel(at(anchor, 100.0), &pinch(0.1, ScrollPhase::Changed), InputModifiers::NONE);
    assert!((p.geometry.points_per_second / s0 - (0.1 * TimelineZoom::PINCH_GAIN).exp()).abs() < 1e-9);
    assert!((secs(p.geometry.unsnapped_time(anchor)) - secs(t)).abs() < 0.01);
    p.scroll_wheel(at(anchor, 100.0), &pinch(0.0, ScrollPhase::Ended), InputModifiers::NONE);
    let y = p.geometry.scroll_y;
    p.scroll_wheel(at(anchor, 100.0), &pad(0.0, -20.0, ScrollPhase::Began, ScrollPhase::None), InputModifiers::NONE);
    assert_eq!(p.geometry.scroll_y, y); // inside the pinch tail
    now.set(now.get() + 1.0);
    p.scroll_wheel(at(anchor, 100.0), &pad(0.0, -20.0, ScrollPhase::Began, ScrollPhase::None), InputModifiers::NONE);
    assert_eq!(p.geometry.scroll_y, y + 20.0);
}

#[test]
fn the_ends_rubber_band_back_in_fast_cut() {
    let mut tracks = vec![track(1, TrackKind::Video, vec![clip(1, 0, 750, TrackKind::Video)])];
    tracks.extend((0..9).map(|i| track(10 + i, TrackKind::Video, Vec::new())));
    let mut t = timeline(tracks);
    t.set_edit_mode(sq_core_model::TimelineEditMode::Magnetic);
    let (mut p, now) = panel_over(&t, 1000.0, 200.0);
    let pps = p.geometry.points_per_second * 8.0;
    p.set_zoom(pps, Some(TimelineGeometry::CONTENT_ORIGIN_X));
    p.geometry.scroll_x = 0.0;
    // Pull past the start: damped, kept through layout, then sprung back by `tick`.
    p.scroll_wheel(at(500.0, 100.0), &pad(30.0, 0.0, ScrollPhase::Began, ScrollPhase::None), InputModifiers::NONE);
    assert!(p.geometry.scroll_x < 0.0 && p.geometry.scroll_x > -30.0);
    p.layout_px(Rect::new(0.0, 0.0, 1000.0, 200.0), 1.0);
    assert!(p.geometry.scroll_x < 0.0);
    p.scroll_wheel(at(500.0, 100.0), &pad(0.0, 0.0, ScrollPhase::Ended, ScrollPhase::None), InputModifiers::NONE);
    assert!(p.is_springing_back());
    let pulled = p.geometry.scroll_x;
    now.set(now.get() + RubberBand::SPRING_DURATION / 2.0);
    p.tick();
    assert!(p.geometry.scroll_x > pulled && p.geometry.scroll_x < 0.0);
    now.set(now.get() + RubberBand::SPRING_DURATION);
    p.tick();
    assert!(p.geometry.scroll_x == 0.0 && !p.is_springing_back());
}

#[test]
fn a_press_during_the_spring_back_stops_it_at_once() {
    let mut tracks = vec![track(1, TrackKind::Video, vec![clip(1, 0, 750, TrackKind::Video)])];
    tracks.extend((0..9).map(|i| track(10 + i, TrackKind::Video, Vec::new())));
    let mut t = timeline(tracks);
    t.set_edit_mode(sq_core_model::TimelineEditMode::Magnetic);
    let (mut p, now) = panel_over(&t, 1000.0, 200.0);
    let pps = p.geometry.points_per_second * 8.0;
    p.set_zoom(pps, Some(TimelineGeometry::CONTENT_ORIGIN_X));
    p.geometry.scroll_x = 0.0;
    p.scroll_wheel(at(500.0, 100.0), &pad(30.0, 0.0, ScrollPhase::Began, ScrollPhase::None), InputModifiers::NONE);
    p.scroll_wheel(at(500.0, 100.0), &pad(0.0, 0.0, ScrollPhase::Ended, ScrollPhase::None), InputModifiers::NONE);
    assert!(p.is_springing_back());
    now.set(now.get() + RubberBand::SPRING_DURATION / 3.0);
    p.tick();
    p.handle(&down(500.0, 100.0), &mut UiCx::new());
    assert!(!p.is_springing_back(), "the press ends the spring");
    assert!(p.geometry.scroll_x == 0.0, "and the view rests inside its range");
}

/// Pulls past the start, optionally keeps pulling at speed, lifts, and returns how deep the view still is 0.1 s later
/// relative to the depth at the lift.
fn depth_after_release(keep_moving: bool) -> f64 {
    let mut tracks = vec![track(1, TrackKind::Video, vec![clip(1, 0, 750, TrackKind::Video)])];
    tracks.extend((0..9).map(|i| track(10 + i, TrackKind::Video, Vec::new())));
    let mut t = timeline(tracks);
    t.set_edit_mode(sq_core_model::TimelineEditMode::Magnetic);
    let (mut p, now) = panel_over(&t, 1000.0, 200.0);
    let pps = p.geometry.points_per_second * 8.0;
    p.set_zoom(pps, Some(TimelineGeometry::CONTENT_ORIGIN_X));
    p.geometry.scroll_x = 0.0;
    p.scroll_wheel(at(500.0, 100.0), &pad(30.0, 0.0, ScrollPhase::Began, ScrollPhase::None), InputModifiers::NONE);
    if keep_moving {
        for _ in 0..3 {
            now.set(now.get() + 0.016);
            p.scroll_wheel(
                at(500.0, 100.0),
                &pad(30.0, 0.0, ScrollPhase::Changed, ScrollPhase::None),
                InputModifiers::NONE,
            );
        }
        now.set(now.get() + 0.016);
    } else {
        now.set(now.get() + 0.3); // the fingers rested before they lifted
    }
    p.scroll_wheel(at(500.0, 100.0), &pad(0.0, 0.0, ScrollPhase::Ended, ScrollPhase::None), InputModifiers::NONE);
    assert!(p.is_springing_back());
    let lifted = p.geometry.scroll_x;
    now.set(now.get() + 0.1);
    p.tick();
    p.geometry.scroll_x / lifted
}

#[test]
fn the_release_velocity_seeds_the_spring_back() {
    let carried = depth_after_release(true);
    let rested = depth_after_release(false);
    assert!(carried > rested, "momentum outward keeps the view deeper at 0.1 s: {carried} vs {rested}");
    assert!(rested > 0.0 && rested < 1.0, "a rested release still eases back: {rested}");
}

#[test]
fn reduced_motion_lands_the_overscroll_at_once() {
    sq_draw::motion::set_reduce_motion(true);
    let mut tracks = vec![track(1, TrackKind::Video, vec![clip(1, 0, 750, TrackKind::Video)])];
    tracks.extend((0..9).map(|i| track(10 + i, TrackKind::Video, Vec::new())));
    let mut t = timeline(tracks);
    t.set_edit_mode(sq_core_model::TimelineEditMode::Magnetic);
    let (mut p, _now) = panel_over(&t, 1000.0, 200.0);
    let pps = p.geometry.points_per_second * 8.0;
    p.set_zoom(pps, Some(TimelineGeometry::CONTENT_ORIGIN_X));
    p.geometry.scroll_x = 0.0;
    p.scroll_wheel(at(500.0, 100.0), &pad(30.0, 0.0, ScrollPhase::Began, ScrollPhase::None), InputModifiers::NONE);
    p.scroll_wheel(at(500.0, 100.0), &pad(0.0, 0.0, ScrollPhase::Ended, ScrollPhase::None), InputModifiers::NONE);
    sq_draw::motion::set_reduce_motion(false);
    assert!(!p.is_springing_back(), "no spring");
    assert!(p.geometry.scroll_x == 0.0, "the view rests inside its range at once");
}

fn four_row_panel() -> (TimelinePanel, Timeline) {
    let v1 = track(1, TrackKind::Video, vec![clip(1, 0, 50, TrackKind::Video), clip(2, 100, 50, TrackKind::Video)]);
    let a1 = track(3, TrackKind::Audio, vec![clip(3, 0, 50, TrackKind::Audio)]);
    let t = timeline(vec![v1, track(2, TrackKind::Video, Vec::new()), a1, track(4, TrackKind::Audio, Vec::new())]);
    let (p, _) = panel_over(&t, 1000.0, 400.0);
    (p, t)
}

#[test]
fn row_facts_match_the_mac_view() {
    let (p, _) = four_row_panel();
    let rows = p.rows();
    assert_eq!(TimelinePanel::split_row(&rows), Some(1)); // V1 above the split (rows: V2, V1, A1, A2)
    assert!(!TimelinePanel::is_alt_lane(1, &rows)); // the track next to the split is plain
    assert!(TimelinePanel::is_alt_lane(0, &rows));
    assert!(TimelinePanel::is_alt_lane(2, &rows)); // A1 shaded under V1, as on the Mac
    assert!(!TimelinePanel::is_alt_lane(3, &rows));
}

pub(crate) fn down(x: f64, y: f64) -> InputEvent {
    InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE }
}

#[test]
fn a_ruler_press_scrubs_and_the_release_ends() {
    let (mut p, _) = four_row_panel();
    let mut ui = UiCx::new();
    let x = TimelineGeometry::CONTENT_ORIGIN_X + 200.0;
    let out = p.handle(&down(x, 5.0), &mut ui);
    assert!(matches!(out.as_slice(), [TimelineAction::BeginScrub, TimelineAction::Scrub(_)]));
    assert!(p.is_dragging());
    let out = p.handle(&InputEvent::dragged((x + 40.0) as f32, 5.0), &mut ui);
    assert!(matches!(out.as_slice(), [TimelineAction::Scrub(_)]));
    let out = p.handle(&InputEvent::MouseUp { x: (x + 40.0) as f32, y: 5.0 }, &mut ui);
    assert_eq!(out, vec![TimelineAction::EndScrub]);
    assert!(!p.is_dragging());
}

#[test]
fn escape_without_a_drag_is_not_a_timeline_key_but_a_drag_cancels() {
    let (mut p, _) = four_row_panel();
    let mut ui = UiCx::new();
    assert_eq!(p.key(InputKey::Escape, InputModifiers::NONE, &mut ui), None);
    let x = TimelineGeometry::CONTENT_ORIGIN_X + 200.0;
    p.handle(&down(x, 5.0), &mut ui);
    assert!(p.is_dragging());
    assert_eq!(p.key(InputKey::Escape, InputModifiers::NONE, &mut ui), Some(Vec::new()));
    assert!(!p.is_dragging());
}

#[test]
fn zoom_keys_land_at_once_with_no_frames_asked_for() {
    let (mut p, _) = four_row_panel();
    let mut ui = UiCx::new();
    let s0 = p.geometry.points_per_second;
    assert_eq!(p.key(InputKey::Plus, InputModifiers::NONE, &mut ui), Some(Vec::new()));
    assert!(!p.is_zooming() && p.geometry.points_per_second > s0, "keyboard: immediate, no ease");
}

#[test]
fn cache_bars_merge_close_spans_and_drop_slivers() {
    let g = TimelineGeometry::new(FD, 100.0);
    let r = |s: i64, d: i64| TimeRange::new(Time::seconds(s), Time::seconds(d));
    // 1 s = 100 pt: [0, 100] and [101, 150] merge (gap under 6), a 2 pt span is dropped.
    let spans = [r(0, 1), TimeRange::new(Time::new(101, 100), Time::new(49, 100)), r(10, 0)];
    let bars = TimelinePanel::cache_bars(&spans, &g);
    assert_eq!(bars.len(), 1);
    assert!((bars[0].1 - bars[0].0 - 150.0).abs() < 1e-9);
}

#[test]
fn a_clip_name_is_black_on_a_light_fill_and_white_on_a_dark_one() {
    assert_eq!(TimelineSkin::text_on(Color::rgb(0.95, 0.95, 0.5)), Color::BLACK);
    assert_eq!(TimelineSkin::text_on(Color::rgb(0.1, 0.2, 0.5)), Color::WHITE);
}

#[test]
fn the_playhead_head_outline_is_closed_and_inside_its_box() {
    let pts = TimelineSkin::head_outline_points();
    assert_eq!(pts.len(), 1 + 5 + 6 * 5 - 1); // start, five lines, five flattened corners, minus the closing point
    assert!(pts.iter().all(|p| p.x >= -0.01 && p.x <= 12.01 && p.y >= -0.01 && p.y <= 12.2));
}

#[test]
fn the_lane_cache_replays_an_unchanged_frame_and_misses_after_a_change() {
    let (mut p, _) = four_row_panel();
    let draw = |p: &mut TimelinePanel| {
        let mut cv = sq_draw::Canvas::with_size(1000.0, 400.0, None, 1.0);
        p.draw_timeline(&mut cv);
        cv.list.quads().len()
    };
    let first = draw(&mut p);
    let second = draw(&mut p);
    assert_eq!(first, second);
    assert_eq!((p.lane_cache.hits(), p.lane_cache.misses()), (1, 1));
    p.selection.insert(uid(1));
    draw(&mut p);
    assert_eq!(p.lane_cache.misses(), 2);
}

#[test]
fn a_page_turn_while_playing_jumps_without_asking_for_frames() {
    let (mut p, _) = four_row_panel();
    p.follow_playback(true); // play starts with the playhead on screen
    let mut s = 1;
    while p.geometry.x(Time::seconds(s)) <= p.size.width {
        s += 1; // the first second that lies past the right edge
    }
    p.playhead = Time::seconds(s);
    let before = p.geometry.scroll_x;
    p.follow_playback(true);
    assert!(!p.is_zooming(), "no glide");
    assert!(p.geometry.scroll_x > before && p.geometry.x(p.playhead) <= p.size.width, "the page turned at once");
}

#[test]
fn reduce_motion_lands_a_zoom_at_once() {
    sq_draw::motion::set_reduce_motion(true);
    let (mut p, _) = four_row_panel();
    let mut ui = UiCx::new();
    let s0 = p.geometry.points_per_second;
    p.key(InputKey::Plus, InputModifiers::NONE, &mut ui);
    assert!(!p.is_zooming() && p.geometry.points_per_second > s0, "no glide, no frames asked for");
    sq_draw::motion::set_reduce_motion(false);
}

/// Create Captions adds a caption track while the view is scrolled to the base: the new track scrolls fully into view.
#[test]
fn a_new_caption_track_is_scrolled_fully_into_view() {
    let mut tracks = vec![track(1, TrackKind::Video, vec![clip(1, 0, 750, TrackKind::Video)])];
    tracks.extend((0..9).map(|i| track(10 + i, TrackKind::Video, Vec::new())));
    let mut tl = timeline(tracks);
    let (mut p, _) = panel_over(&tl, 1000.0, 200.0);
    p.geometry.scroll_y = 120.0; // the base: the top rows are above the view
    let captions: sq_core_model::CaptionTrack =
        serde_json::from_value(serde_json::json!({"id": uid(77).to_string()})).expect("caption track");
    tl.caption_tracks.push(captions);
    p.sync(SessionView {
        timeline: &tl,
        selection: &BTreeSet::new(),
        captions: &BTreeSet::new(),
        playhead: Time::ZERO,
        selected_transition: None,
        labels: LabelResolver::default(),
        line_keys: BTreeSet::new(),
    });
    let row = &p.geometry.caption_rows(&tl)[0];
    assert!(
        row.y >= TimelineGeometry::RULER_HEIGHT,
        "the caption row starts under the ruler, not above it ({})",
        row.y
    );
}

#[test]
fn two_panels_over_one_timeline_at_revision_zero_mint_disjoint_ids() {
    use sq_core_time::IdSource;
    let t = timeline(vec![track(1, TrackKind::Video, vec![clip(1, 0, 750, TrackKind::Video)])]);
    let ((mut a, _), (mut b, _)) = (panel_over(&t, 400.0, 200.0), panel_over(&t, 400.0, 200.0));
    let mut ids_a: Vec<_> = (0..3).flat_map(|_| [a.fresh_ids().next_id(), a.fresh_ids().next_id()]).collect();
    let ids_b: Vec<_> = (0..3).flat_map(|_| [b.fresh_ids().next_id(), b.fresh_ids().next_id()]).collect();
    ids_a.extend(ids_b.iter().copied());
    let all: std::collections::BTreeSet<_> = ids_a.iter().collect();
    assert_eq!(all.len(), ids_a.len(), "no id twice: {ids_a:?}");
    // A fixed salt gives reproducible ids for tests that need them.
    let fixed = |salt| panel_over(&t, 400.0, 200.0).0.with_id_salt(salt).fresh_ids().next_id();
    assert_eq!(fixed(7), fixed(7));
    assert_ne!(fixed(7), fixed(8));
}
