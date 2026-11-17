//! Ported from `TimelineCursorTests` (SQDrawTimeline): which pointer shape the panel asks for.

use crate::panel_tests::{Rig, uid};
use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Time, TimeRange};
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{InputEvent, InputKey, InputModifiers};
use sq_timeline_ui::{TimelineGeometry, TrackSizing};

const FD: Time = Time::new(1, 25);

fn clip(n: u128, start: i64, frames: i64) -> Clip {
    Clip::new(uid(n), "c", uid(n + 500), TrackKind::Video, TimeRange::new(Time::new(0, 1), FD * frames), FD * start)
}

/// 1000 x 400 pt, V1 with clips at 0...50 and 100...150, V2, A1.
fn rig() -> Rig {
    let mut v1 = Track::new(uid(1), TrackKind::Video);
    v1.set_clips(vec![clip(10, 0, 50), clip(11, 100, 50)]);
    let tracks = vec![v1, Track::new(uid(2), TrackKind::Video), Track::new(uid(3), TrackKind::Audio)];
    Rig::new(Timeline::new(uid(9000), "t", SequenceFormat::new(FD), tracks), 1000.0, 400.0)
}

fn v1_y(r: &Rig) -> f32 {
    let id = r.tl().tracks[0].id;
    let row = r.p.rows().into_iter().find(|x| x.track == id).expect("row");
    (row.y + row.height * 0.7) as f32
}

#[test]
fn selection_tool_trims_at_clip_edges() {
    let r = rig();
    let y = v1_y(&r);
    let head = r.p.geometry.x(FD * 100) as f32 + 2.0;
    let tail = r.p.geometry.x(FD * 50) as f32 - 2.0;
    assert_eq!(r.p.cursor_at(head, y, InputModifiers::NONE), Some(DrawCursor::TrimIn));
    assert_eq!(r.p.cursor_at(tail, y, InputModifiers::NONE), Some(DrawCursor::TrimOut));
    assert_eq!(r.p.cursor_at(2000.0, y, InputModifiers::NONE), None); // outside the panel: the host's arrow
}

#[test]
fn razor_tool_shows_the_razor_over_the_tracks() {
    let mut r = rig();
    r.key(InputKey::Character('c'), InputModifiers::NONE);
    let row = r.p.rows().into_iter().find(|x| x.track == r.tl().tracks[0].id).expect("row");
    let x = r.p.geometry.x(FD * 25) as f32;
    assert_eq!(r.p.cursor_at(x, (row.y + row.height * 0.5) as f32, InputModifiers::NONE), Some(DrawCursor::Razor));
}

#[test]
fn row_edge_resizes() {
    let r = rig();
    let x = TimelineGeometry::CONTENT_ORIGIN_X + 300.0;
    let y = (TimelineGeometry::RULER_HEIGHT as i32..400)
        .find(|&y| {
            TrackSizing::zone(sq_uikit::controls_grid::CGPoint { x, y: f64::from(y) }, &r.p.rows(), 1000.0).is_some()
        })
        .expect("a row edge");
    assert_eq!(r.p.cursor_at(x as f32, y as f32, InputModifiers::NONE), Some(DrawCursor::ResizeUpDown));
}

#[test]
fn drag_keeps_the_press_cursor_and_publishes_it() {
    let mut r = rig();
    let y = v1_y(&r);
    let x = r.p.geometry.x(FD * 100) as f32 + 2.0;
    let moved = InputEvent::MouseMoved { x, y };
    r.ui.hover.begin_event(&moved);
    r.send(moved);
    assert_eq!(r.ui.hover.cursor, Some(DrawCursor::TrimIn));
    r.send(InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE });
    let far = InputEvent::dragged(x + 200.0, y);
    r.ui.hover.begin_event(&far);
    r.send(far); // far off the edge: the trim cursor stays
    assert_eq!(r.ui.hover.cursor, Some(DrawCursor::TrimIn));
    r.send(InputEvent::MouseUp { x: x + 200.0, y });
}
