//! Tests of the Source monitor host: open, marks, Insert/Overwrite at the playhead, the picture slot, and the root's
//! double click path.

use super::*;
use crate::test_rig::Rig;
use sq_core_model::{MediaFingerprint, MediaInfo, MediaRef, SourceMarks};
use sq_core_time::{SequentialIds, Time, TimeRange};
use sq_draw::Color;
use sq_draw::RgbaImage;
use sq_draw::draw_list::QuadKind;
use sq_draw::monitor::monitor_modes::MonitorAction;
use sq_editor_session::{SessionDeps, StubProgramEngine};

fn s(n: i64) -> Time {
    Time::new(n, 1)
}

fn clip_media(n: u128, secs: i64) -> MediaRef {
    let mut m = MediaRef::new(Id::from_u128(n), "A.mov", "/nonexistent/A.mov", MediaFingerprint::new(1));
    m.duration = Some(s(secs));
    let info: MediaInfo = serde_json::from_value(serde_json::json!({
        "duration": {"value": secs, "timescale": 1},
        "video": {"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                  "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false, "rotation": 0},
        "audio": {"sampleRate": 48000, "channels": 2, "codec": "lpcm"}
    }))
    .unwrap_or_else(|e| panic!("media info: {e}"));
    m.info = Some(info);
    m
}

fn rig_with_media() -> Rig {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-source"));
    deps.ids = Box::new(ids);
    let mut rig = Rig::new(EditorSession::new(project, deps));
    rig.session.perform("Import", None, |p| p.add(clip_media(1, 10)));
    rig
}

fn host(picture: MonitorPicture) -> SourceMonitorHost {
    SourceMonitorHost::new(Box::new(StubProgramEngine::new()), picture, Box::new(SequentialIds::default()))
}

fn track_clips(rig: &Rig) -> usize {
    rig.session.active_timeline().map_or(0, |t| t.tracks.iter().map(|k| k.clips().len()).sum())
}

#[test]
fn opening_media_loads_it_and_unknown_media_says_so() {
    let mut rig = rig_with_media();
    let mut h = host(MonitorPicture::default());
    assert!(h.open(&mut rig.cx(), Id::from_u128(1)));
    assert_eq!(h.core().media_id(), Some(Id::from_u128(1)));
    assert_eq!(h.core().duration(), s(10));
    assert!(!h.open(&mut rig.cx(), Id::from_u128(99)));
    assert_eq!(h.core().media_id(), Some(Id::from_u128(1)));
}

#[test]
fn marks_and_play_run_through_the_panel_buttons() {
    let mut rig = rig_with_media();
    let mut h = host(MonitorPicture::default());
    h.open(&mut rig.cx(), Id::from_u128(1));
    h.core.seek(s(2));
    h.core.perform(&mut rig.session, MonitorAction::MarkIn);
    h.core.seek(s(5));
    h.core.perform(&mut rig.session, MonitorAction::MarkOut);
    let marks = rig.session.project().source_marks_for(Id::from_u128(1));
    assert_eq!(marks.mark_in, Some(s(2)));
    assert_eq!(marks.mark_out, Some(s(5) + Time::new(1, 30)));
    h.core.perform(&mut rig.session, MonitorAction::PlayPause);
    assert!(h.core().is_playing());
    // The shared panel wiring: a model action raised by the card reaches the core on the next pump.
    h.panel.model.emit(sq_draw_monitor::monitor_panel_model::MonitorEvent::Action(MonitorAction::PlayPause));
    h.with_panel(|core, _| core.pump(&mut rig.session));
    assert!(!h.core().is_playing());
}

#[test]
fn insert_and_overwrite_place_the_marked_range_at_the_playhead() {
    let mut rig = rig_with_media();
    let mut h = host(MonitorPicture::default());
    h.open(&mut rig.cx(), Id::from_u128(1));
    rig.session.set_source_marks(
        Some(SourceMarks { mark_in: Some(s(2)), mark_out: Some(s(5)), ..SourceMarks::default() }),
        Id::from_u128(1),
    );
    rig.session.seek(s(1));
    h.with_panel(|core, _| core.perform(&mut rig.session, MonitorAction::Overwrite));
    assert_eq!(track_clips(&rig), 2); // video and audio
    let start = rig
        .session
        .active_timeline()
        .and_then(|t| t.tracks.iter().flat_map(|k| k.clips().to_vec()).map(|c| (c.start, c.source)).next());
    assert_eq!(start, Some((s(1), TimeRange::from_end(s(2), s(5)))));
    h.with_panel(|core, _| core.perform(&mut rig.session, MonitorAction::Insert));
    assert_eq!(track_clips(&rig), 4);
}

#[test]
fn the_picture_draws_in_its_own_image_slot() {
    let mut rig = rig_with_media();
    let picture = MonitorPicture::default();
    let mut h = host(picture.clone());
    h.open(&mut rig.cx(), Id::from_u128(1));
    h.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 600.0, 400.0), &mut rig.cx());
    let draw = |h: &mut SourceMonitorHost, rig: &mut Rig| {
        let mut c = Canvas::with_size(600.0, 400.0, None, 1.0);
        h.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
        c.list.quads().iter().filter(|q| q.kind == QuadKind::Image && q.slot == SOURCE_PICTURE_SLOT as f32).count()
    };
    assert_eq!(draw(&mut h, &mut rig), 0);
    picture.set(Some(RgbaImage::filled(4, 4, Color::WHITE)));
    assert_eq!(draw(&mut h, &mut rig), 1);
}

#[test]
fn the_program_playing_pauses_the_source() {
    let mut rig = rig_with_media();
    let mut h = host(MonitorPicture::default());
    h.open(&mut rig.cx(), Id::from_u128(1));
    // The Program only plays a sequence that has something on it.
    h.with_panel(|core, _| core.perform(&mut rig.session, MonitorAction::Insert));
    h.core.play_pause();
    assert!(h.core().is_playing());
    rig.session.play_pause();
    assert!(rig.session.is_playing());
    h.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 600.0, 400.0), &mut rig.cx());
    assert!(!h.core().is_playing());
}

fn key(c: sq_draw::InputKey) -> InputEvent {
    InputEvent::KeyDown { key: c, modifiers: sq_draw::InputModifiers::NONE }
}

#[test]
fn keys_drive_the_source_transport_and_marks() {
    let mut rig = rig_with_media();
    let mut h = host(MonitorPicture::default());
    assert!(h.open(&mut rig.cx(), Id::from_u128(1)));
    assert!(h.handle(&key(sq_draw::InputKey::Right), &mut rig.cx()));
    assert_eq!(h.core().current_time(), Time::new(1, 30));
    assert!(h.handle(&key(sq_draw::InputKey::Character('i')), &mut rig.cx()));
    assert_eq!(h.core().marks(&rig.session).mark_in, Some(Time::new(1, 30)));
    assert!(h.handle(&key(sq_draw::InputKey::Space), &mut rig.cx()));
    assert!(h.core().is_playing());
    assert!(h.handle(&key(sq_draw::InputKey::Character('k')), &mut rig.cx()));
    assert!(!h.core().is_playing());
}

#[test]
fn closing_the_clip_clears_the_picture() {
    let mut rig = rig_with_media();
    let picture = MonitorPicture::default();
    let mut h = host(picture.clone());
    assert!(h.open(&mut rig.cx(), Id::from_u128(1)));
    picture.set(Some(RgbaImage::filled(2, 2, Color::WHITE)));
    h.core.close_all(&mut rig.session);
    h.pump(&mut rig.cx());
    assert!(picture.get().is_none());
}

#[test]
fn the_source_monitors_full_screen_command_reaches_the_root() {
    let mut rig = rig_with_media();
    let mut h = host(MonitorPicture::default());
    assert!(h.open(&mut rig.cx(), Id::from_u128(1)));
    assert!(h.take_deferred().is_empty());
    h.core.model.emit(sq_draw_monitor::monitor_panel_model::MonitorEvent::FullScreen);
    h.pump(&mut rig.cx());
    assert!(matches!(
        h.take_deferred().as_slice(),
        [MonitorDeferred::Model(sq_draw_monitor::monitor_panel_model::MonitorEvent::FullScreen)]
    ));
}

#[test]
fn the_source_monitor_offers_full_screen_in_its_menu() {
    let h = host(MonitorPicture::default());
    let titles: Vec<String> = h.core.model.option_items(Vec::new()).into_iter().map(|i| i.title).collect();
    assert!(titles.contains(&"Full Screen".to_string()));
}

#[test]
fn the_waveform_meter_solo_reaches_the_source_engine() {
    use sq_draw::{InputEvent, InputModifiers};
    let mut rig = rig_with_media();
    let mut h = host(MonitorPicture::default());
    h.open(&mut rig.cx(), Id::from_u128(1));
    h.with_panel(|_, p| p.model.viewer_mode = sq_draw_monitor::monitor_drop_indicator::SourceViewerMode::Waveform);
    h.panel.has_wave_meter = true;
    h.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 600.0, 400.0), &mut rig.cx());
    let r = h.with_panel(|_, p| p.wave_meter_rect());
    let (x, y) = ((r.min_x() + 10.0) as f32, (r.max_y() - 8.0) as f32); // the "L" label row
    assert!(h.core.engine.channel_monitor().is_none());
    h.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
    let monitor = h.core.engine.channel_monitor().expect("the Solo reached the engine");
    assert!(monitor.is_soloed(0));
    assert!(h.take_deferred().is_empty(), "nothing is left for the root");
}
