//! Fast Cut Delete through the whole root, with the events a real window sends (FINAL-LIN-2 row 11): a caption row was
//! selected in the Captions panel earlier, then a click on a clip and the Delete key must ripple-delete that clip, and the
//! captions behind it shift and survive ("Edits never delete captions as a side effect").

use super::dead_commands_tests::{Scenario, demo_session};
use super::*;
use sq_core_model::{CaptionItem, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_draw::{InputKey, InputModifiers};
use sq_runtime::FakeClock;
use std::collections::BTreeSet;
use std::sync::Arc;

const CAPTION_A: u128 = 7001;
const CAPTION_B: u128 = 7002;

fn caption(id: u128, start: i64) -> CaptionItem {
    CaptionItem {
        id: Id::from_u128(id),
        lines: vec![format!("caption {id}")],
        range: TimeRange::new(Time::seconds(start), Time::seconds(start + 2)),
        style_ref: String::new(),
        animation_ref: String::new(),
        style_overridden: false,
        words: Vec::new(),
        position: None,
    }
}

/// A Fast Cut sequence with two 10 s clips on V1 (A at 0, B at 10 s) and one caption on each, the root laid out.
fn fast_cut_with_captions() -> (AppRoot, crate::test_rig::Rig) {
    let dir = crate::test_rig::unique_dir("sq-fast-cut-delete");
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
    let mut rig = crate::test_rig::Rig::new(demo_session(Scenario::FastCut));
    assert!(rig.session.add_caption_track().is_some(), "a caption track");
    assert!(rig.session.add_captions(vec![caption(CAPTION_A, 1), caption(CAPTION_B, 12)]), "two captions");
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    root.sync(&rig.session);
    (root, rig)
}

fn video_clips(rig: &crate::test_rig::Rig) -> Vec<(Time, Time)> {
    let t = rig.session.active_timeline().expect("sequence");
    let mut all: Vec<_> = t
        .tracks
        .iter()
        .filter(|k| k.kind == TrackKind::Video)
        .flat_map(|k| k.clips().iter().map(|c| (c.start, c.timeline().duration)))
        .collect();
    all.sort();
    all
}

fn caption_starts(rig: &crate::test_rig::Rig) -> Vec<Time> {
    let mut all: Vec<Time> = rig.session.caption_items().iter().map(|c| c.range.start).collect();
    all.sort();
    all
}

/// A press and release on the first video clip, with a hover before it (the window's order).
fn click_first_clip(r: &mut AppRoot, rig: &mut crate::test_rig::Rig) {
    let (x, y) = {
        let p = &r.timeline.inner().panel;
        let t = rig.session.active_timeline().expect("sequence");
        let v = t.tracks.iter().find(|k| k.kind == TrackKind::Video).expect("video track");
        (p.pixel_x(Time::seconds(5)), p.pixel_y_body_of(v.id).expect("row"))
    };
    r.handle(&InputEvent::MouseMoved { x, y }, &mut rig.cx());
    r.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
}

fn press_delete(r: &mut AppRoot, rig: &mut crate::test_rig::Rig) {
    let key = |k| InputEvent::KeyDown { key: k, modifiers: InputModifiers::NONE };
    r.handle(&key(InputKey::Delete), &mut rig.cx());
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
}

/// The reported bug: a caption row selected in the Captions panel, then a click on clip A and Delete.
#[test]
fn delete_after_a_clip_click_ripples_the_clip_and_keeps_every_caption() {
    let (mut r, mut rig) = fast_cut_with_captions();
    // The caption row was picked in the Captions panel, which has the keyboard focus.
    rig.session.select(BTreeSet::new(), BTreeSet::from([Id::from_u128(CAPTION_B)]));
    r.dock.set_focused(Some(PanelID::Text));
    r.sync(&rig.session);
    click_first_clip(&mut r, &mut rig);
    assert_eq!(r.dock.focused(), Some(PanelID::Timeline), "a press on the timeline moves the key focus there");
    assert!(rig.session.caption_selection().is_empty(), "a clip click replaces the caption selection");
    assert_eq!(rig.session.selection().len().min(1), 1, "clip A is selected");
    press_delete(&mut r, &mut rig);
    let clips = video_clips(&rig);
    assert_eq!(clips.len(), 1, "clip A is gone ({clips:?}, error {:?})", rig.session.last_error());
    assert_eq!(clips[0].0, Time::seconds(0), "clip B rippled to the start");
    // Clip A's own caption leaves with its clip (a deliberate delete of that range, `deleting_the_clip_still_cuts_its_
    // captions_out` in sq-core-edit); the caption behind it rides along and survives.
    let shifted = Time::seconds(12) - clips[0].1;
    assert_eq!(caption_starts(&rig), [shifted], "caption B shifted by A's length");
}
