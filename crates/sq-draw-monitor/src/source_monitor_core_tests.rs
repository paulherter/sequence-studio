//! SourceMonitorCoreTests and SourceTimelineBuilderTests of the Swift package.

use crate::monitor_panel::{HeaderControl, MonitorPanel};
use crate::source_monitor_core::{FourPointFitChoice, SourceCoreEvent, SourceMonitorCore};
use crate::source_timeline_builder::SourceTimelineBuilder;
use crate::test_support::{Rig, draw};
use serde_json::json;
use sq_core_edit::playback::PlaybackRate;
use sq_core_model::{MediaFingerprint, MediaInfo, MediaRef, SourceMarks, Timeline};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use sq_draw::InputModifiers;
use sq_draw::monitor::monitor_modes::MonitorAction;
use sq_editor_session::{PreviewSurface, ProgramEngine, StubProgramEngine};
use sq_media::video_decoding::DecodeScale;
use sq_uikit::editor_command::EditorCommand;
use std::any::Any;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

fn s(n: i64) -> Time {
    Time::new(n, 1)
}

fn info(v: serde_json::Value) -> MediaInfo {
    serde_json::from_value(v).unwrap_or_else(|e| panic!("media info: {e}"))
}

fn video(width: i64, fd: (i64, i64)) -> serde_json::Value {
    json!({"width": width, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
           "nominalFrameDuration": {"value": fd.0, "timescale": fd.1}, "isVariableFrameRate": false, "rotation": 0})
}

fn audio() -> serde_json::Value {
    json!({"sampleRate": 48000, "channels": 2, "codec": "lpcm"})
}

fn media(n: u128, name: &str, size: i64, secs: i64, v: Option<serde_json::Value>, a: bool) -> MediaRef {
    let mut m = MediaRef::new(Id::from_u128(n), name, &format!("/nonexistent/{name}"), MediaFingerprint::new(size));
    m.duration = Some(s(secs));
    let mut j = json!({"duration": {"value": secs, "timescale": 1}});
    if let Some(v) = v {
        j["video"] = v;
    }
    if a {
        j["audio"] = audio();
    }
    m.info = Some(info(j));
    m
}

/// The stub engine behind a handle, so a test can drive it while the core owns the `Box<dyn ProgramEngine>`.
#[derive(Clone)]
struct SharedStub(Rc<RefCell<StubProgramEngine>>);

impl ProgramEngine for SharedStub {
    fn set_timeline(&mut self, timeline: &Timeline, sequences: &BTreeMap<Id, Timeline>) {
        self.0.borrow_mut().set_timeline(timeline, sequences);
    }
    fn attach(&mut self, surface: Option<PreviewSurface>) {
        self.0.borrow_mut().attach(surface);
    }
    fn position(&self) -> Time {
        self.0.borrow().position()
    }
    fn rate(&self) -> PlaybackRate {
        self.0.borrow().rate()
    }
    fn play(&mut self, rate: PlaybackRate) {
        self.0.borrow_mut().play(rate);
    }
    fn pause(&mut self) {
        self.0.borrow_mut().pause();
    }
    fn seek(&mut self, t: Time) {
        self.0.borrow_mut().seek(t);
    }
    fn step(&mut self, frames: i64) {
        self.0.borrow_mut().step(frames);
    }
    fn begin_scrub(&mut self) {
        self.0.borrow_mut().begin_scrub();
    }
    fn scrub(&mut self, t: Time) {
        self.0.borrow_mut().scrub(t);
    }
    fn end_scrub(&mut self) {
        self.0.borrow_mut().end_scrub();
    }
    fn quality(&self) -> DecodeScale {
        self.0.borrow().quality()
    }
    fn set_quality(&mut self, quality: DecodeScale) {
        self.0.borrow_mut().set_quality(quality);
    }
    fn take_position_change(&mut self) -> Option<Time> {
        self.0.borrow_mut().take_position_change()
    }
    fn as_any(&self) -> &dyn Any {
        self
    }
}

struct Fixture {
    src: SourceMonitorCore,
    engine: Rc<RefCell<StubProgramEngine>>,
    rig: Rig,
    m: MediaRef,
    b: MediaRef,
}

fn make_source() -> Fixture {
    let m = media(1, "A.mov", 1, 10, Some(video(1920, (1, 30))), true);
    let b = media(2, "B.wav", 2, 4, None, true);
    let mut rig = Rig::new();
    let (m2, b2) = (m.clone(), b.clone());
    rig.session.perform("Import", None, |p| {
        p.add(m2);
        p.add(b2);
    });
    let engine = Rc::new(RefCell::new(StubProgramEngine::new()));
    let src =
        SourceMonitorCore::new(Box::new(SharedStub(Rc::clone(&engine))), None, Box::new(SequentialIds::default()));
    Fixture { src, engine, rig, m, b }
}

#[test]
fn open_builds_the_clip_timeline_and_fills_the_model() {
    let mut f = make_source();
    assert!(f.src.open(&mut f.rig.session, f.m.id, Some(s(3))));
    assert_eq!(f.src.media_id(), Some(f.m.id));
    assert_eq!(f.src.model.duration, s(10));
    assert_eq!(f.src.model.current_time, s(3));
    assert_eq!(f.src.model.viewer_mode, crate::monitor_drop_indicator::SourceViewerMode::Picture);
    assert_eq!(f.src.picture_shape(), [1920, 1080]);
    assert!(f.src.open(&mut f.rig.session, f.b.id, None));
    assert_eq!(f.src.model.viewer_mode, crate::monitor_drop_indicator::SourceViewerMode::Waveform);
    assert_eq!(f.src.model.source_items.iter().map(|i| i.id).collect::<Vec<_>>(), [f.b.id, f.m.id]); // most recent first
    f.src.close_current(&mut f.rig.session);
    assert_eq!(f.src.media_id(), Some(f.m.id));
    f.src.close_all(&mut f.rig.session);
    assert!(f.src.media_id().is_none() && f.src.model.source_items.is_empty());
}

#[test]
fn marks_go_to_the_project_with_out_exclusive() {
    let mut f = make_source();
    f.src.open(&mut f.rig.session, f.m.id, None);
    f.src.seek(s(2));
    f.src.mark_in(&mut f.rig.session);
    f.src.seek(s(5));
    f.src.mark_out(&mut f.rig.session);
    let marks = f.rig.session.project().source_marks_for(f.m.id);
    assert_eq!(marks.mark_in, Some(s(2)));
    assert_eq!(marks.mark_out, Some(s(5) + Time::new(1, 30)));
    assert_eq!(f.src.model.mark_in, Some(s(2)));
    f.src.go_to_out(&f.rig.session);
    assert_eq!(f.src.current_time(), s(5));
    f.src.clear_marks(&mut f.rig.session);
    assert!(f.rig.session.project().source_marks_for(f.m.id).is_empty());
}

#[test]
fn insert_and_overwrite_place_the_marked_range() {
    let mut f = make_source();
    f.src.open(&mut f.rig.session, f.m.id, None);
    f.rig.session.set_source_marks(
        Some(SourceMarks { mark_in: Some(s(2)), mark_out: Some(s(5)), ..SourceMarks::default() }),
        f.m.id,
    );
    f.src.perform(&mut f.rig.session, MonitorAction::Overwrite);
    let clips = |r: &Rig| {
        r.session
            .active_timeline()
            .map(|t| t.tracks.iter().flat_map(|k| k.clips().to_vec()).collect::<Vec<_>>())
            .unwrap_or_default()
    };
    let c = clips(&f.rig);
    assert_eq!(c.len(), 2);
    assert!(c.iter().all(|c| c.source == TimeRange::from_end(s(2), s(5))));
    f.src.perform(&mut f.rig.session, MonitorAction::Insert);
    assert_eq!(clips(&f.rig).len(), 4);
}

/// Every clip of every non-empty track as (start, duration, source in).
fn lanes(r: &Rig) -> Vec<Vec<(Time, Time, Time)>> {
    r.session.active_timeline().map_or_else(Vec::new, |t| {
        let all = t.tracks.iter().map(|k| k.clips().iter().map(|c| (c.start, c.duration(), c.source.start)).collect());
        all.filter(|v: &Vec<_>| !v.is_empty()).collect()
    })
}

/// End parks on the sequence end, so Overwrite and Insert there append on V1 and A1 and the last clip keeps every frame;
/// the same Insert one frame earlier (the last frame) splits that clip exactly: its 1-frame right part follows the new
/// clip. One undo restores each state.
#[test]
fn source_edits_at_the_sequence_end_append_and_at_the_last_frame_split_exactly() {
    let fd = Time::new(1, 30);
    let mut f = make_source();
    f.src.open(&mut f.rig.session, f.m.id, None);
    f.rig.session.set_source_marks(
        Some(SourceMarks { mark_in: Some(s(2)), mark_out: Some(s(5)), ..SourceMarks::default() }),
        f.m.id,
    );
    f.src.perform(&mut f.rig.session, MonitorAction::Overwrite);
    let first = vec![(s(0), s(3), s(2))];
    assert_eq!(lanes(&f.rig), vec![first.clone(), first.clone()]);
    f.rig.session.go_to_end();
    assert_eq!(f.rig.session.playhead(), s(3), "End = the sequence end");
    f.src.perform(&mut f.rig.session, MonitorAction::Overwrite);
    let two = vec![(s(0), s(3), s(2)), (s(3), s(3), s(2))];
    assert_eq!(lanes(&f.rig), vec![two.clone(), two.clone()], "Overwrite at the end appends");
    f.rig.session.go_to_end();
    f.src.perform(&mut f.rig.session, MonitorAction::Insert);
    let three = vec![(s(0), s(3), s(2)), (s(3), s(3), s(2)), (s(6), s(3), s(2))];
    assert_eq!(lanes(&f.rig), vec![three.clone(), three.clone()], "Insert at the end appends");
    f.rig.session.undo();
    assert_eq!(lanes(&f.rig), vec![two.clone(), two.clone()], "undo restores exactly");
    f.rig.session.seek(s(6) - fd);
    f.src.perform(&mut f.rig.session, MonitorAction::Insert);
    let split = vec![(s(0), s(3), s(2)), (s(3), s(3) - fd, s(2)), (s(6) - fd, s(3), s(2)), (s(9) - fd, fd, s(5) - fd)];
    assert_eq!(lanes(&f.rig), vec![split.clone(), split], "Insert on the last frame splits it exactly");
    f.rig.session.undo();
    assert_eq!(lanes(&f.rig), vec![two.clone(), two]);
}

#[test]
fn replace_needs_one_selected_clip() {
    let mut f = make_source();
    f.src.perform(&mut f.rig.session, MonitorAction::Replace);
    let last = |src: &mut SourceMonitorCore| {
        src.take_events()
            .into_iter()
            .rev()
            .find_map(|e| if let SourceCoreEvent::Status(t) = e { Some(t) } else { None })
    };
    assert!(last(&mut f.src).is_some_and(|t| t.contains("Open a clip")));
    f.src.open(&mut f.rig.session, f.m.id, None);
    f.src.perform(&mut f.rig.session, MonitorAction::Replace);
    assert!(last(&mut f.src).is_some_and(|t| t.contains("Select one clip")));
    f.src.perform(&mut f.rig.session, MonitorAction::Overwrite);
    let clip = f
        .rig
        .session
        .active_timeline()
        .and_then(|t| {
            t.tracks
                .iter()
                .find(|k| k.kind == sq_core_model::TrackKind::Video)
                .and_then(|k| k.clips().first().map(|c| c.id))
        })
        .unwrap_or_else(|| panic!("a video clip"));
    let c = media(3, "C.mov", 3, 10, Some(video(1920, (1, 30))), true);
    let cid = c.id;
    f.rig.session.perform("Import", None, |p| p.add(c));
    f.src.open(&mut f.rig.session, cid, None);
    f.rig.session.seek(Time::ZERO);
    // the video clip alone (a click selects its linked audio too)
    f.rig.session.set_selection([clip].into_iter().collect(), Default::default());
    f.src.perform(&mut f.rig.session, MonitorAction::Replace);
    assert!(f.rig.session.undo_name().is_some_and(|n| n.contains("Replace")));
}

#[test]
fn four_point_edit_asks_and_cancel_places_nothing() {
    let mut f = make_source();
    f.src.asks_four_point_fit = true;
    f.src.open(&mut f.rig.session, f.m.id, None);
    f.rig.session.set_source_marks(
        Some(SourceMarks { mark_in: Some(s(1)), mark_out: Some(s(2)), ..SourceMarks::default() }),
        f.m.id,
    );
    f.rig.session.set_in_point(s(0));
    f.rig.session.set_out_point(s(4));
    let empty = |r: &Rig| r.session.active_timeline().is_some_and(|t| t.tracks.iter().all(|k| k.clips().is_empty()));
    f.src.perform(&mut f.rig.session, MonitorAction::Overwrite);
    assert_eq!(f.src.take_events().iter().filter(|e| **e == SourceCoreEvent::ChooseFourPointFit).count(), 1);
    f.src.resolve_four_point_fit(&mut f.rig.session, None);
    assert!(empty(&f.rig));
    f.src.perform(&mut f.rig.session, MonitorAction::Overwrite);
    f.src.resolve_four_point_fit(&mut f.rig.session, Some(FourPointFitChoice::ChangeSpeed));
    assert!(!empty(&f.rig));
}

#[test]
fn play_in_to_out_stops_at_out_and_loop_wraps_without_engine_loop() {
    let mut f = make_source();
    f.src.open(&mut f.rig.session, f.m.id, None);
    f.rig.session.set_source_marks(
        Some(SourceMarks { mark_in: Some(s(2)), mark_out: Some(s(3)), ..SourceMarks::default() }),
        f.m.id,
    );
    f.src.play_in_to_out(&f.rig.session, false);
    assert!(f.src.is_playing());
    assert_eq!(f.src.bounds().range(), Some(TimeRange::from_end(s(2), s(3))));
    simulate(&mut f, s(2));
    assert!(!f.src.is_playing());
    assert_eq!(f.src.current_time(), s(3) - Time::new(1, 30));
    f.src.perform(&mut f.rig.session, MonitorAction::Loop);
    f.src.play_in_to_out(&f.rig.session, false);
    simulate(&mut f, s(2));
    assert!(f.src.is_playing() && f.src.current_time() == s(2)); // wrapped back to In by the core
}

/// Advances the stub engine like the app's frame loop does, then lets the core read the new position.
fn simulate(f: &mut Fixture, dt: Time) {
    f.engine.borrow_mut().simulate_playback(dt);
    f.src.tick(&mut f.rig.session);
}

#[test]
fn source_commands_route_while_focused() {
    let mut f = make_source();
    f.src.open(&mut f.rig.session, f.m.id, None);
    assert!(f.src.handle(&mut f.rig.session, EditorCommand::StepForward));
    assert_eq!(f.src.current_time(), Time::new(1, 30));
    assert!(f.src.handle(&mut f.rig.session, EditorCommand::GoToEnd));
    assert_eq!(f.src.current_time(), s(10) - Time::new(1, 30));
    assert!(!f.src.handle(&mut f.rig.session, EditorCommand::Undo));
}

#[test]
fn audio_only_clip_shows_the_waveform_and_a_press_scrubs() {
    let mut f = make_source();
    let asked: std::rc::Rc<std::cell::RefCell<Vec<Id>>> = Default::default();
    let sink = std::rc::Rc::clone(&asked);
    f.src.waveform_provider = Some(Box::new(move |id| {
        sink.borrow_mut().push(id);
        None
    }));
    f.src.open(&mut f.rig.session, f.b.id, None);
    assert_eq!(*asked.borrow(), [f.b.id]);
    let model = std::mem::replace(
        &mut f.src.model,
        crate::monitor_panel_model::MonitorPanelModel::new(
            Time::new(1, 30),
            sq_draw::monitor::monitor_modes::MonitorMode::Source,
        ),
    );
    let mut panel = MonitorPanel::new(model, None);
    panel.layout_px(sq_draw::Rect::new(0.0, 0.0, 800.0, 500.0), 1.0);
    draw(&mut panel);
    assert!(panel.shows_waveform());
    assert!(!panel.header_controls().iter().any(|c| c.0 == HeaderControl::Zoom)); // no picture tools for sound
    let r = panel.slot();
    assert!(f.rig.down(&mut panel, r.mid_x(), r.mid_y(), InputModifiers::NONE));
    std::mem::swap(&mut f.src.model, &mut panel.model);
    f.src.pump(&mut f.rig.session);
    std::mem::swap(&mut f.src.model, &mut panel.model);
    assert!(f.src.current_time() > s(1) && f.src.current_time() < s(3)); // the middle of a 4 s file
    f.rig.drag(&mut panel, r.max_x(), r.mid_y());
    f.rig.up(&mut panel, r.max_x(), r.mid_y());
    std::mem::swap(&mut f.src.model, &mut panel.model);
    f.src.pump(&mut f.rig.session);
    std::mem::swap(&mut f.src.model, &mut panel.model);
    assert_eq!(f.src.current_time(), f.src.duration() - f.src.frame_duration());
    assert!(!panel.is_dragging());
}

#[test]
fn menu_lists_the_edit_rows() {
    let mut f = make_source();
    f.src.open(&mut f.rig.session, f.m.id, None);
    let titles: Vec<String> = f.src.context_menu_items(&f.rig.session).iter().map(|i| i.title.clone()).collect();
    for t in ["Mark In", "Insert", "Overwrite", "Fit to Fill", "Replace Clip from Source", "Export Frame…"] {
        assert!(titles.contains(&t.to_string()), "{t}");
    }
}

// SourceTimelineBuilderTests

fn ref_with(v: Option<serde_json::Value>) -> MediaRef {
    let mut m = MediaRef::new(Id::from_u128(9), "a.mov", "/a.mov", MediaFingerprint::new(1));
    m.duration = None;
    let mut j = json!({"duration": {"value": 10, "timescale": 1}});
    if let Some(v) = v {
        j["video"] = v;
    }
    m.info = Some(info(j));
    m
}

fn set_aspect_override(r: &mut MediaRef, num: i64, den: i64) {
    let mut v = serde_json::to_value(r.info.as_ref().and_then(|i| i.video.clone())).unwrap_or_default();
    v["pixelAspectOverride"] = json!({"num": num, "den": den});
    if let Some(i) = r.info.as_mut() {
        i.video = serde_json::from_value(v).ok();
    }
}

fn video_aspect() -> serde_json::Value {
    video(1440, (1, 25))
}

#[test]
fn shape_follows_the_pixel_aspect() {
    let mut r = ref_with(Some(video_aspect()));
    assert_eq!(SourceTimelineBuilder::shape(&r), [1440, 1080]);
    set_aspect_override(&mut r, 4, 3);
    assert_eq!(SourceTimelineBuilder::shape(&r), [1920, 1080]);
    let mut ids = SequentialIds::default();
    assert_eq!(SourceTimelineBuilder::build(&r, &mut ids).map(|b| b.format.width), Some(1920));
}

#[test]
fn rebuild_only_when_the_shape_moved() {
    let mut r = ref_with(Some(video_aspect()));
    let loaded = SourceTimelineBuilder::shape(&r);
    assert!(!SourceTimelineBuilder::needs_reshape(&r, &loaded));
    set_aspect_override(&mut r, 2, 1);
    assert!(SourceTimelineBuilder::needs_reshape(&r, &loaded));
    assert!(!SourceTimelineBuilder::needs_reshape(&r, &SourceTimelineBuilder::shape(&r)));
    assert!(!SourceTimelineBuilder::needs_reshape(&ref_with(None), &[])); // audio only: no picture, no shape
}

#[test]
fn unprobed_media_builds_nothing_and_has_no_shape() {
    let r = MediaRef::new(Id::from_u128(9), "a.mov", "/a.mov", MediaFingerprint::new(1));
    let mut ids = SequentialIds::default();
    assert!(SourceTimelineBuilder::build(&r, &mut ids).is_none());
    assert!(SourceTimelineBuilder::shape(&r).is_empty());
    assert!(!SourceTimelineBuilder::needs_reshape(&r, &[]));
}

#[test]
fn late_info_changes_frame_rate_and_length() {
    let mut unprobed = MediaRef::new(Id::from_u128(9), "a.mov", "/a.mov", MediaFingerprint::new(1));
    unprobed.duration = Some(s(10));
    let mut ids = SequentialIds::default();
    let before = SourceTimelineBuilder::build(&unprobed, &mut ids);
    assert_eq!(before.map(|b| b.format.frame_duration), Some(Time::new(1, 30)));
    let mut probed = unprobed.clone();
    probed.info = Some(info(json!({"duration": {"value": 4, "timescale": 1}, "video": video_aspect()})));
    let after = SourceTimelineBuilder::build(&probed, &mut ids);
    assert_eq!(after.as_ref().map(|b| b.format.frame_duration), Some(Time::new(1, 25)));
    assert_eq!(after.map(|b| b.total), Some(s(4)));
    assert!(SourceTimelineBuilder::needs_reshape(&probed, &SourceTimelineBuilder::shape(&unprobed)));
}

#[test]
fn position_and_range_are_clamped_to_the_new_end() {
    let fd = Time::new(1, 25);
    let total = s(4);
    assert_eq!(SourceTimelineBuilder::clamped_position(s(9), total, fd), s(4) - fd);
    assert_eq!(SourceTimelineBuilder::clamped_position(s(2), total, fd), s(2));
    let cut = SourceTimelineBuilder::clamped_range(Some(TimeRange::from_end(s(2), s(9))), total);
    assert_eq!(cut, Some(TimeRange::from_end(s(2), total)));
    assert_eq!(SourceTimelineBuilder::clamped_range(Some(TimeRange::from_end(s(5), s(9))), total), None);
    assert_eq!(SourceTimelineBuilder::clamped_range(None, total), None);
}

/// Shift+L / Shift+J change the playing speed by 1/4 (Swift `PlaybackRate.nudged`; the first press from a stop plays at
/// 1.25x, not in slow motion): the rate the engine really plays at, not only the rate maths.
#[test]
fn shift_l_and_shift_j_nudge_the_playing_speed_by_a_quarter() {
    let mut f = make_source();
    f.src.open(&mut f.rig.session, f.m.id, Some(s(3)));
    let rate = |f: &Fixture| f.engine.borrow().rate();
    let r = |n, d| PlaybackRate::new(n, d);
    assert!(f.src.handle(&mut f.rig.session, EditorCommand::ShuttleSlowForward));
    assert_eq!(rate(&f), r(5, 4));
    f.src.handle(&mut f.rig.session, EditorCommand::ShuttleSlowForward);
    assert_eq!(rate(&f), r(3, 2));
    f.src.handle(&mut f.rig.session, EditorCommand::ShuttleSlowReverse);
    assert_eq!(rate(&f), r(5, 4), "against the direction it slows down");
    for _ in 0..5 {
        f.src.handle(&mut f.rig.session, EditorCommand::ShuttleSlowReverse); // 1, 3/4, 1/2, 1/4, then zero
    }
    assert_eq!(rate(&f), PlaybackRate::ZERO, "at zero it stops");
    f.src.handle(&mut f.rig.session, EditorCommand::ShuttleSlowReverse);
    assert_eq!(rate(&f), r(-5, 4), "from a stop it starts backward at 1.25x");
}
