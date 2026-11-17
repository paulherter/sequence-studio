//! Editor audit A1-A4 (ship audit): padlock glyph per lock state, a tall track list opening at V1/A1 with a scroll
//! hint. The ruler label rule lives beside `TimelinePanel::label_x`.

use crate::panel::TimelinePanel;
use crate::panel_tests::{Rig, uid};
use sq_core_model::{SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::Time;
use sq_timeline_ui::TimelineGeometry;
use sq_uikit::sqicon::SQIcon;

fn forty_tracks() -> Timeline {
    let mut tracks = Vec::new();
    for i in 0..20u128 {
        tracks.push(Track::new(uid(100 + i), TrackKind::Video));
    }
    for i in 0..20u128 {
        tracks.push(Track::new(uid(200 + i), TrackKind::Audio));
    }
    Timeline::new(uid(9100), "T40", SequenceFormat::new(Time::new(1, 25)), tracks)
}

#[test]
fn padlock_glyph_follows_the_lock_state() {
    assert_eq!(TimelinePanel::lock_icon(true), SQIcon::TrackLock);
    assert_eq!(TimelinePanel::lock_icon(false), SQIcon::TrackUnlock);
}

#[test]
fn forty_tracks_open_at_v1_and_a1_with_a_scroll_hint() {
    let r = Rig::new(forty_tracks(), 1440.0, 700.0);
    let rows = r.p.rows();
    let first_audio = rows.iter().position(|x| x.kind == TrackKind::Audio).expect("audio rows");
    let area = r.p.track_area_height();
    for i in [first_audio - 1, first_audio] {
        let row = &rows[i];
        assert!(
            row.y >= TimelineGeometry::RULER_HEIGHT && row.max_y() <= area,
            "row {i} ({:?}) is out of view: {}..{} of {area}",
            row.kind,
            row.y,
            row.max_y()
        );
    }
    assert!(r.p.geometry.scroll_y > 0.0, "opens scrolled to the base, not the top");
    let thumb = TimelinePanel::vertical_thumb(
        1440.0,
        TimelineGeometry::RULER_HEIGHT,
        area - TimelineGeometry::RULER_HEIGHT,
        r.p.geometry.scroll_y,
        r.p.max_scroll_y(),
    )
    .expect("a scroll hint while tracks overflow");
    assert!(thumb.min_y() >= TimelineGeometry::RULER_HEIGHT && thumb.max_y() <= area);
}

#[test]
fn few_tracks_need_no_scroll_hint() {
    assert!(TimelinePanel::vertical_thumb(1440.0, 28.0, 400.0, 0.0, 0.0).is_none());
    let t = TimelinePanel::vertical_thumb(1440.0, 28.0, 400.0, 100.0, 200.0).unwrap();
    assert!(t.min_y() > 28.0 && t.max_y() < 428.0);
}

#[test]
fn a_word_wider_than_the_lane_keeps_its_text_on_screen() {
    use sq_uikit::controls_grid::CGRect;
    let lane = CGRect::new(100.0, 0.0, 600.0, 26.0);
    // Box from far left to far right: centered in the lane, not in the box.
    let x = TimelinePanel::word_text_x(-50_000.0, 50_000.0, lane, 40.0, 4.0);
    assert!((x - (400.0 - 20.0)).abs() < 1e-9, "{x}");
    // A box inside the lane stays centered on itself.
    assert_eq!(TimelinePanel::word_text_x(200.0, 300.0, lane, 40.0, 4.0), 230.0);
    // Text wider than the visible part starts at the inset of that part.
    assert_eq!(TimelinePanel::word_text_x(80.0, 130.0, lane, 40.0, 4.0), 104.0);
}
