//! Ported from `TimelineDropSourceTests` (SQDrawTimeline): the ghost items of a drag, a drop placing media where the
//! ghost showed, and Alt-release replacing a clip.

use crate::drop::{TimelineDropSource, drop_items, drop_replace};
use crate::panel_tests::{Rig, uid};
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_core_model::{Clip, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

use sq_editor_session::{EditorSession, SessionDeps};
use sq_timeline_ui::DropItem;
use std::path::PathBuf;

const FD: Time = Time::new(1, 25);

fn media() -> MediaRef {
    let mut m = MediaRef::new(uid(40), "a", "/nonexistent/a.mov", MediaFingerprint::new(1));
    m.duration = Some(FD * 50);
    m.info = serde_json::from_value(serde_json::json!({"duration": {"value": 50, "timescale": 25},
        "video": {"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                  "nominalFrameDuration": {"value": 1, "timescale": 25}, "isVariableFrameRate": false}}))
    .ok();
    m
}

fn clip(n: u128, kind: TrackKind, frames: i64) -> Clip {
    Clip::new(uid(n), "c", uid(40), kind, TimeRange::new(Time::ZERO, FD * frames), Time::ZERO)
}

/// V1 with one 100-frame clip and a second sequence `inner` (50 frames, with audio), plus one media item.
fn rig() -> (Rig, Id) {
    let mut v = Track::new(uid(1), TrackKind::Video);
    v.set_clips(vec![clip(10, TrackKind::Video, 100)]);
    let host = Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v, Track::new(uid(2), TrackKind::Audio)]);
    let mut iv = Track::new(uid(3), TrackKind::Video);
    iv.set_clips(vec![clip(11, TrackKind::Video, 50)]);
    let mut ia = Track::new(uid(4), TrackKind::Audio);
    ia.set_clips(vec![clip(12, TrackKind::Audio, 50)]);
    let inner = Timeline::new(uid(9001), "inner", SequenceFormat::new(FD), vec![iv, ia]);
    let project = Project::new(uid(7000), "P", vec![media()], vec![host, inner]);
    let mut s = EditorSession::new(project, SessionDeps::headless(std::env::temp_dir().join("sq-drop-tests")));
    s.set_active_timeline(uid(9000));
    (Rig::from_session(s, 1000.0, 400.0), uid(9001))
}

fn items(r: &Rig, src: &TimelineDropSource) -> Vec<DropItem> {
    drop_items(src, &r.s, SourceStreams::Both)
}

#[test]
fn ghost_items_for_media_sequences_and_files() {
    let (r, inner) = rig();
    let m = items(&r, &TimelineDropSource::Media(vec![uid(40)]));
    assert_eq!(m, vec![DropItem::with_streams("a", FD * 50, true, false)]);
    let seq = items(&r, &TimelineDropSource::Sequences(vec![inner]));
    assert!(seq[0].has_audio && seq[0].duration == FD * 50);
    let files = items(&r, &TimelineDropSource::Files(vec![PathBuf::from("/x/s.wav"), PathBuf::from("/x/p.png")]));
    assert_eq!(files.iter().map(|i| i.has_video).collect::<Vec<_>>(), [false, true]);
    assert_eq!(files.iter().map(|i| i.has_audio).collect::<Vec<_>>(), [true, false]);
}

#[test]
fn a_media_drop_places_at_the_ghost_as_one_undo_step() {
    let (mut r, _) = rig();
    let row = r.p.rows()[0].clone();
    let (x, y) = (r.p.geometry.x(FD * 150) as f32, (row.y + row.height / 2.0) as f32);
    let it = items(&r, &TimelineDropSource::Media(vec![uid(40)]));
    r.p.drop_hover(it, x, y, false, true, SourceStreams::Both);
    let a = r.p.drop_commit(vec![uid(40)], x, y, false);
    assert_eq!(a.len(), 1);
    r.run(a);
    assert_eq!(r.tl().tracks[0].clips().len(), 2);
    r.s.undo();
    assert_eq!(r.tl().tracks[0].clips().len(), 1);
}

#[test]
fn alt_release_over_a_clip_replaces_it_with_the_first_item() {
    let (mut r, inner) = rig();
    // A 50-frame clip of the media at frame 150, so the replacements are long enough (a 100-frame clip refuses them).
    let row = r.p.rows()[0].clone();
    let (x, y) = (r.p.geometry.x(FD * 150) as f32, (row.y + row.height / 2.0) as f32);
    let a = r.p.drop_commit(vec![uid(40)], x, y, false);
    r.run(a);
    let placed = r.tl().tracks[0].clips().iter().find(|c| c.start == FD * 150).expect("placed").id;
    let files = TimelineDropSource::Files(vec![PathBuf::from("/nonexistent/a.mov")]);
    assert!(!drop_replace(&files, placed, None, &mut r.s));
    assert!(!drop_replace(&TimelineDropSource::Media(vec![uid(40)]), uid(10), None, &mut r.s)); // 100 frames > 50
    assert!(drop_replace(&TimelineDropSource::Sequences(vec![inner]), placed, None, &mut r.s));
    assert!(r.tl().tracks[0].clips().iter().find(|c| c.start == FD * 150).is_some_and(|c| c.is_nested()));
    r.s.undo();
    assert!(!r.tl().tracks[0].clips().iter().any(|c| c.is_nested()));
}

#[test]
fn the_clip_under_a_point_is_found_and_past_the_clip_is_an_ordinary_drop() {
    let (r, _) = rig();
    let row = r.p.rows()[0].clone();
    let y = (row.y + row.height / 2.0) as f32;
    assert_eq!(r.p.clip_id(r.p.geometry.x(FD * 10) as f32, y), Some(uid(10)));
    assert_eq!(r.p.clip_id(r.p.geometry.x(FD * 150) as f32, y), None);
}
