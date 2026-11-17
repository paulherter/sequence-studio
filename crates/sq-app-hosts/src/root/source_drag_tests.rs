//! A drag from the Source monitor onto the timeline (Swift `MonitorCardHost.sourceDragged`): the picture drags both streams,
//! a footer handle one; the timeline shows its drop preview and the release places the Source clip with those streams.

use super::tests::root;
use super::*;
use crate::{MonitorPicture, SourceMonitorHost};
use sq_core_time::{Id, SequentialIds, Time};
use sq_draw_monitor::monitor_panel_source_drag::MonitorDragPhase;
use sq_editor_session::SessionDeps;

fn with_open_source() -> (AppRoot, crate::test_rig::Rig, (f32, f32)) {
    let source = SourceMonitorHost::new(
        Box::new(sq_editor_session::StubProgramEngine::new()),
        MonitorPicture::default(),
        Box::new(SequentialIds::default()),
    );
    let mut r = root().with_source(source);
    let id = Id::from_u128(77);
    let mut media = sq_core_model::MediaRef::new(id, "i", "/tmp/i.mp4", sq_core_model::MediaFingerprint::new(1));
    media.duration = Some(Time::seconds(4));
    media.info = serde_json::from_value(serde_json::json!({
        "duration": {"value": 4, "timescale": 1},
        "video": {"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                  "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false, "rotation": 0},
        "audio": {"sampleRate": 48000, "channels": 2, "codec": "lpcm"}
    }))
    .ok();
    let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![media], Vec::new());
    let mut rig = crate::test_rig::Rig::new(EditorSession::new(
        project,
        SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests-source-drag")),
    ));
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1000.0, 800.0), &mut rig.cx());
    r.sync(&rig.session);
    assert!(r.source.as_mut().expect("source").open(&mut rig.cx(), id));
    let tl = r.dock.content_frame(PanelID::Timeline).expect("timeline docked");
    (r, rig, ((tl.min_x() + 400.0) as f32, (tl.min_y() + 60.0) as f32))
}

fn clips(rig: &crate::test_rig::Rig) -> usize {
    rig.session.active_timeline().map_or(0, |t| t.tracks.iter().map(|k| k.clips().len()).sum())
}

#[test]
fn the_picture_drags_both_streams_onto_the_timeline() {
    let (mut r, mut rig, (x, y)) = with_open_source();
    r.source_dragged(&mut rig.cx(), SourceStreams::Both, MonitorDragPhase::Moved, x, y);
    assert!(r.timeline.inner().panel.drop_hover_active(), "the drop preview follows the pointer");
    assert!(r.source_drag_tile.is_some(), "the tile follows the pointer");
    r.source_dragged(&mut rig.cx(), SourceStreams::Both, MonitorDragPhase::Ended, x, y);
    assert!(!r.timeline.inner().panel.drop_hover_active());
    assert!(r.source_drag_tile.is_none());
    assert_eq!(clips(&rig), 2, "video and audio");
}

#[test]
fn a_footer_handle_drags_one_stream() {
    let (mut r, mut rig, (x, y)) = with_open_source();
    r.source_dragged(&mut rig.cx(), SourceStreams::VideoOnly, MonitorDragPhase::Moved, x, y);
    r.source_dragged(&mut rig.cx(), SourceStreams::VideoOnly, MonitorDragPhase::Ended, x, y);
    assert_eq!(clips(&rig), 1, "the video clip alone");
}

#[test]
fn a_canceled_drag_or_one_released_off_the_timeline_places_nothing() {
    let (mut r, mut rig, (x, y)) = with_open_source();
    r.source_dragged(&mut rig.cx(), SourceStreams::Both, MonitorDragPhase::Moved, x, y);
    r.source_dragged(&mut rig.cx(), SourceStreams::Both, MonitorDragPhase::Canceled, x, y);
    assert!(!r.timeline.inner().panel.drop_hover_active());
    r.source_dragged(&mut rig.cx(), SourceStreams::Both, MonitorDragPhase::Ended, 5.0, 5.0);
    assert_eq!(clips(&rig), 0);
}
