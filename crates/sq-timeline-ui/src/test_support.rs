//! Shared fixtures of the unit tests: ids, clips, tracks and the pointer helpers of the gesture suites.

use crate::timeline_geometry::TimelineGeometry;
use crate::timeline_interaction::TimelineInteraction;
use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use sq_editor_session::{GestureModifiers, TimelineCommit};
use sq_uikit::keyframe_graph_geometry::Point;
use std::cell::Cell;

pub(crate) const FD: Time = Time::new(1, 24);

/// Seed of the ids a test interaction makes; far from every id `uid` hands out.
pub(crate) const ID_SEED: u128 = 1 << 100;

thread_local! {
    static NEXT: Cell<u128> = const { Cell::new(1 << 80) };
}

/// A fresh id (the Swift `UUID()`), unique within the test thread.
pub(crate) fn uid() -> Id {
    NEXT.with(|n| {
        n.set(n.get() + 1);
        Id::from_u128(n.get())
    })
}

/// A clip of `frames` frames at frame `start`, source from frame 50 (the fixture of the gesture suites).
pub(crate) fn mk(start: i64, frames: i64, kind: TrackKind, link: Option<Id>) -> Clip {
    let mut c = Clip::new(uid(), "c", uid(), kind, TimeRange::new(FD * 50, FD * frames), FD * start);
    c.link = link;
    c.media_duration = Some(FD * 200);
    c
}

/// A video clip without a link.
pub(crate) fn mkv(start: i64, frames: i64) -> Clip {
    mk(start, frames, TrackKind::Video, None)
}

/// A track of `kind` holding `clips`.
pub(crate) fn track(kind: TrackKind, clips: Vec<Clip>) -> Track {
    let mut t = Track::new(uid(), kind);
    t.set_clips(clips);
    t
}

/// A 24 fps timeline of `tracks`.
pub(crate) fn timeline(tracks: Vec<Track>) -> Timeline {
    Timeline::new(uid(), "t", SequenceFormat::new(FD), tracks)
}

/// 4 pt per frame: frame f is at x = CONTENT_ORIGIN_X + 4 f.
pub(crate) fn x(f: f64) -> f64 {
    TimelineGeometry::CONTENT_ORIGIN_X + f * 4.0
}

/// Geometry of the gesture suites (4 pt per frame).
pub(crate) fn geo4() -> TimelineGeometry {
    TimelineGeometry::with_points_per_frame(FD, 4.0)
}

/// An interaction over `t` at 4 pt per frame.
pub(crate) fn interaction_of(t: Timeline) -> TimelineInteraction {
    TimelineInteraction::new(t, geo4(), ID_SEED)
}

/// The clip `id` of `t`.
pub(crate) fn clip_of(t: &Timeline, id: Id) -> Option<&Clip> {
    t.tracks.iter().find_map(|tr| tr.clips().iter().find(|c| c.id == id))
}

pub(crate) fn pt(x: f64, y: f64) -> Point {
    Point::new(x, y)
}

pub(crate) fn none() -> GestureModifiers {
    GestureModifiers::default()
}

/// Press, two drag steps, release.
pub(crate) fn drag(i: &mut TimelineInteraction, a: Point, b: Point, m: GestureModifiers) -> Option<TimelineCommit> {
    i.mouse_down(a, m);
    i.mouse_dragged(pt((a.x + b.x) / 2.0, (a.y + b.y) / 2.0), m);
    i.mouse_dragged(b, m);
    i.mouse_up(b, m)
}

/// Press and release at `p`.
pub(crate) fn click(i: &mut TimelineInteraction, p: Point, m: GestureModifiers) -> Option<TimelineCommit> {
    i.mouse_down(p, m);
    i.mouse_up(p, m)
}
