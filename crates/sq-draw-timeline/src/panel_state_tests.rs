//! Ported from `TimelineFastCutTests` (weak stretch click, heights per sequence) of SQDrawTimeline.

use crate::action::TimelineAction;
use crate::panel_tests::{Rig, uid};
use sq_core_masks::HealthSpan;
use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Time, TimeRange};
use sq_library::library_folder_store::{MemorySettings, SettingsStore};
use sq_timeline_ui::{TimelineGeometry, TrackConfidenceStrip, TrackHeightStore};
use sq_uikit::keyframe_graph_geometry::Rect;
use std::cell::RefCell;
use std::rc::Rc;

const FD: Time = Time::new(1, 25);

fn rig() -> Rig {
    let c = Clip::new(uid(10), "c", uid(510), TrackKind::Video, TimeRange::new(Time::ZERO, FD * 100), Time::ZERO);
    let mut v = Track::new(uid(1), TrackKind::Video);
    v.set_clips(vec![c]);
    Rig::new(
        Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v, Track::new(uid(2), TrackKind::Video)]),
        1000.0,
        400.0,
    )
}

#[test]
fn a_weak_stretch_click_seeks_to_its_start() {
    let mut r = rig();
    r.p.track_weak_spans = Some(Box::new(|_| Some(vec![HealthSpan { start: 1.0, end: 2.0 }])));
    let row = r.p.rows().into_iter().find(|x| x.track == uid(1)).expect("row");
    let x0 = r.p.geometry.x(Time::ZERO);
    let band = TrackConfidenceStrip::hit_band(&Rect::new(x0, row.y, r.p.geometry.x(FD * 100) - x0, row.height));
    let pt = crate::tests::at(r.p.geometry.x(FD * 37), band.min_y() + band.height / 2.0);
    assert_eq!(r.p.weak_stretch_jump(pt), Some(FD * 25), "band {band:?} row {row:?}");
    let a = r.down(pt.x, pt.y);
    assert_eq!(a.last(), Some(&TimelineAction::Seek(FD * 25)), "{a:?}");
}

#[test]
fn track_heights_are_kept_per_sequence() {
    let store = Rc::new(RefCell::new(MemorySettings::default()));
    let mut r = rig();
    r.p.connect_host_defaults(Rc::clone(&store) as Rc<RefCell<dyn SettingsStore>>);
    let row = r.p.rows()[0].clone();
    let y = row.y + row.height / 2.0;
    // A spot of the header that is not a button (the Mac header's background).
    let x = (1..)
        .map(|i| f64::from(i) * 2.0)
        .take_while(|x| *x < TimelineGeometry::CONTENT_ORIGIN_X)
        .find(|x| {
            r.p.header_hit(crate::tests::at(*x, y)).is_none()
                && r.p.geometry.hit_test(crate::tests::at(*x, y), &r.p.timeline)
                    == sq_timeline_ui::TimelineHit::Header(row.track)
        })
        .expect("a header background spot");
    for _ in 0..2 {
        r.down(x, y);
        r.up(x, y);
    }
    let mut guard = store.borrow_mut();
    let kept = TrackHeightStore::new(&mut *guard).load(uid(9000));
    assert!(kept.contains_key(&uid(1)));
    drop(guard);
    // A fresh panel on the same sequence starts with the kept heights.
    let mut q = crate::panel::TimelinePanel::new(sq_draw::DrawTheme::default());
    q.connect_host_defaults(Rc::clone(&store) as Rc<RefCell<dyn SettingsStore>>);
    q.layout_px(sq_draw::Rect::new(0.0, 0.0, 1000.0, 400.0), 1.0);
    q.sync(crate::panel::SessionView {
        timeline: r.tl(),
        selection: &Default::default(),
        captions: &Default::default(),
        playhead: Time::ZERO,
        selected_transition: None,
        labels: Default::default(),
        line_keys: Default::default(),
    });
    assert_eq!(q.geometry.height_overrides, kept);
    let _ = store.borrow().data("x");
}

/// Video above audio: the split grab (3 pt either side of the last video row's bottom) comes first, as in Swift
/// (`TimelinePanel+Input.swift`: `TrackSizing.zone` before `weakStretchJump`), so the lower half of the strip resizes the split
/// and only its upper half seeks.
#[test]
fn over_an_audio_row_the_split_grab_takes_the_lower_half_of_the_weak_strip() {
    let c = Clip::new(uid(10), "c", uid(510), TrackKind::Video, TimeRange::new(Time::ZERO, FD * 100), Time::ZERO);
    let mut v = Track::new(uid(1), TrackKind::Video);
    v.set_clips(vec![c]);
    let tl = Timeline::new(uid(9000), "t", SequenceFormat::new(FD), vec![v, Track::new(uid(2), TrackKind::Audio)]);
    let mut r = Rig::new(tl, 1000.0, 400.0);
    r.p.track_weak_spans = Some(Box::new(|_| Some(vec![HealthSpan { start: 1.0, end: 2.0 }])));
    let row = r.p.rows().into_iter().find(|x| x.track == uid(1)).expect("row");
    let x = r.p.geometry.x(FD * 37);
    let upper = r.down(x, row.max_y() - 5.0);
    assert_eq!(upper.last(), Some(&TimelineAction::Seek(FD * 25)), "{upper:?}");
    r.up(x, row.max_y() - 5.0);
    let lower = r.down(x, row.max_y() - 2.0);
    assert!(!lower.iter().any(|a| matches!(a, TimelineAction::Seek(_))), "{lower:?}");
}
