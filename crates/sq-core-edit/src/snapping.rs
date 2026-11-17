//! Snap points of a timeline and snapping of times and clip moves to them.
// Swift: Snapping.swift

use std::collections::BTreeSet;

use sq_core_model::{Clip, Timeline};
use sq_core_time::{Id, Time};

/// Where a snap point comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SnapKind {
    ClipEdge,
    Playhead,
    Marker,
    Frame,
    InOut,
    Keyframe,
}

/// A time clips and the playhead jump to.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SnapPoint {
    pub time: Time,
    pub kind: SnapKind,
}

impl SnapPoint {
    /// A point of `kind` at `time`.
    pub fn new(time: Time, kind: SnapKind) -> SnapPoint {
        SnapPoint { time, kind }
    }

    /// Sorted by time, one point per time; non-frame kinds win over `.frame`, otherwise the first one stays.
    #[doc(hidden)]
    pub fn normalized(points: &[SnapPoint]) -> Vec<SnapPoint> {
        let mut sorted = points.to_vec();
        sorted.sort_by_key(|p| p.time);
        let mut out: Vec<SnapPoint> = Vec::new();
        for p in sorted {
            match out.last_mut() {
                Some(last) if last.time == p.time => {
                    if last.kind == SnapKind::Frame && p.kind != SnapKind::Frame {
                        *last = p;
                    }
                }
                _ => out.push(p),
            }
        }
        out
    }
}

/// Swift `Timeline.snapPoints`.
pub trait SnappingTimelineExt {
    /// Snap targets: start and end of every clip not in `excluding`, the playhead, markers, the In and Out marks and 0.
    /// With `include_keyframes` the keyframe times (transform, opacity, volume and effect parameters) of the clips not in
    /// `excluding` count too. Sorted and deduplicated by time.
    fn snap_points(
        &self,
        excluding: &BTreeSet<Id>,
        playhead: Option<Time>,
        markers: &[Time],
        include_keyframes: bool,
    ) -> Vec<SnapPoint>;
}

impl SnappingTimelineExt for Timeline {
    fn snap_points(
        &self,
        excluding: &BTreeSet<Id>,
        playhead: Option<Time>,
        markers: &[Time],
        include_keyframes: bool,
    ) -> Vec<SnapPoint> {
        let mut pts = vec![SnapPoint::new(Time::ZERO, SnapKind::ClipEdge)];
        if let Some(playhead) = playhead {
            pts.push(SnapPoint::new(playhead, SnapKind::Playhead));
        }
        pts.extend(markers.iter().map(|&m| SnapPoint::new(m, SnapKind::Marker)));
        if let Some(io) = &self.in_out {
            pts.push(SnapPoint::new(io.start, SnapKind::InOut));
            pts.push(SnapPoint::new(io.end(), SnapKind::InOut));
        }
        for track in &self.tracks {
            for c in track.clips().iter().filter(|c| !excluding.contains(&c.id)) {
                let timeline = c.timeline();
                pts.push(SnapPoint::new(timeline.start, SnapKind::ClipEdge));
                pts.push(SnapPoint::new(timeline.end(), SnapKind::ClipEdge));
                if include_keyframes {
                    for k in keyframe_times(c) {
                        if timeline.contains(c.start + k) {
                            pts.push(SnapPoint::new(c.start + k, SnapKind::Keyframe));
                        }
                    }
                }
            }
        }
        SnapPoint::normalized(&pts)
    }
}

/// Clip-local times of every key on the transform, opacity, volume and effect parameters (Swift `Clip.keyframeTimes`).
pub fn keyframe_times(clip: &Clip) -> Vec<Time> {
    let a = &clip.animation;
    let mut out: Vec<Time> = Vec::new();
    out.extend(a.position.track.keys.iter().map(|k| k.time));
    out.extend(a.scale.track.keys.iter().map(|k| k.time));
    out.extend(a.rotation.track.keys.iter().map(|k| k.time));
    out.extend(a.opacity.track.keys.iter().map(|k| k.time));
    out.extend(a.anchor.track.keys.iter().map(|k| k.time));
    out.extend(a.volume.track.keys.iter().map(|k| k.time));
    for e in &clip.effects {
        out.extend(e.key_times());
    }
    out
}

fn distance(a: Time, b: Time) -> Time {
    let d = a - b;
    if d.is_negative() { -d } else { d }
}

/// Nearest point to `t` within `threshold` (ties: earlier). `points` must be sorted by time.
fn nearest(t: Time, points: &[SnapPoint], threshold: Time) -> Option<SnapPoint> {
    // First index with time >= t.
    let (mut lo, mut hi) = (0, points.len());
    while lo < hi {
        let mid = (lo + hi) / 2;
        if points[mid].time < t {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    let mut best = if lo > 0 { Some(points[lo - 1]) } else { None };
    if let Some(&next) = points.get(lo) {
        match best {
            Some(b) => {
                if distance(next.time, t) < distance(b.time, t) {
                    best = Some(next);
                }
            }
            None => best = Some(next),
        }
    }
    best.filter(|b| distance(b.time, t) <= threshold)
}

/// Snaps `t` to the nearest point within `threshold`; otherwise to the frame grid when `frame_duration` is set.
pub fn snap(t: Time, points: &[SnapPoint], threshold: Time, frame_duration: Option<Time>) -> (Time, Option<SnapPoint>) {
    if let Some(p) = nearest(t, points, threshold) {
        return (p.time, Some(p));
    }
    if let Some(fd) = frame_duration {
        return (t.snapped(fd), None);
    }
    (t, None)
}

/// Snapping for dragging a clip: tries its start and its end. Returns the adjustment to add to the clip's
/// position; the closer hit wins (tie: start). Without a hit, falls back to the frame grid for the start.
pub fn snap_move(
    start: Time,
    duration: Time,
    points: &[SnapPoint],
    threshold: Time,
    frame_duration: Option<Time>,
) -> (Time, Option<SnapPoint>) {
    let end = start + duration;
    let s = nearest(start, points, threshold);
    let e = nearest(end, points, threshold);
    match (s, e) {
        (Some(s), Some(e)) => {
            if distance(e.time, end) < distance(s.time, start) {
                (e.time - end, Some(e))
            } else {
                (s.time - start, Some(s))
            }
        }
        (Some(s), None) => (s.time - start, Some(s)),
        (None, Some(e)) => (e.time - end, Some(e)),
        (None, None) => match frame_duration {
            Some(fd) => (start.snapped(fd) - start, None),
            None => (Time::ZERO, None),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn clip(ids: &mut SequentialIds, start: i64, dur: i64) -> Clip {
        use sq_core_time::IdSource;
        Clip::new(ids.next_id(), "c", Id::NIL, TrackKind::Video, TimeRange::new(s(0), s(dur)), s(start))
    }
    fn pts(xs: &[i64], k: SnapKind) -> Vec<SnapPoint> {
        xs.iter().map(|&x| SnapPoint::new(s(x), k)).collect()
    }
    fn edges(xs: &[i64]) -> Vec<SnapPoint> {
        pts(xs, SnapKind::ClipEdge)
    }
    fn fd() -> Time {
        Time::new(1, 30)
    }
    fn timeline(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::NIL, "t", SequenceFormat::new(fd()), tracks)
    }

    #[test]
    fn nearest_within_threshold() {
        let (t, hit) = snap(Time::new(49, 10), &edges(&[0, 5, 10]), s(1), None);
        assert_eq!(t, s(5));
        assert_eq!(hit.map(|h| h.time), Some(s(5)));
    }

    #[test]
    fn tie_picks_earlier() {
        assert_eq!(snap(s(7), &edges(&[5, 9]), s(3), None).0, s(5));
    }

    #[test]
    fn outside_threshold_keeps_time() {
        let (t, hit) = snap(s(7), &edges(&[0, 20]), s(2), None);
        assert_eq!(t, s(7));
        assert_eq!(hit, None);
    }

    #[test]
    fn frame_fallback() {
        let t = Time::new(1, 30) + Time::new(1, 100);
        let (r, hit) = snap(t, &edges(&[100]), s(1), Some(fd()));
        assert_eq!(r, Time::new(1, 30));
        assert_eq!(hit, None);
    }

    #[test]
    fn point_beats_frame_fallback() {
        let (_, hit) = snap(Time::new(101, 100), &edges(&[1]), Time::new(1, 2), Some(fd()));
        assert_eq!(hit.map(|h| h.time), Some(s(1)));
    }

    #[test]
    fn empty_points() {
        let (t, hit) = snap(s(3), &[], s(1), None);
        assert!(t == s(3) && hit.is_none());
        let (f, _) = snap(Time::new(1, 30) + Time::new(1, 100), &[], s(1), Some(fd()));
        assert_eq!(f, Time::new(1, 30));
    }

    #[test]
    fn exclusion_and_collection() {
        let mut ids = SequentialIds::default();
        let (a, b) = (clip(&mut ids, 2, 3), clip(&mut ids, 10, 2));
        let a_id = a.id;
        let mut t1 = Track::new(ids_next(&mut ids), TrackKind::Video);
        t1.overwrite(a, &mut ids).unwrap();
        t1.overwrite(b, &mut ids).unwrap();
        let mut t2 = Track::new(ids_next(&mut ids), TrackKind::Video);
        let c = clip(&mut ids, 3, 4);
        t2.overwrite(c, &mut ids).unwrap();
        let tl = timeline(vec![t1, t2]);
        let all = tl.snap_points(&BTreeSet::new(), Some(s(8)), &[s(9)], false);
        let times: Vec<Time> = all.iter().map(|p| p.time).collect();
        assert_eq!(times, [0, 2, 3, 5, 7, 8, 9, 10, 12].map(s));
        assert_eq!(all.iter().find(|p| p.time == s(8)).map(|p| p.kind), Some(SnapKind::Playhead));
        assert_eq!(all.iter().find(|p| p.time == s(9)).map(|p| p.kind), Some(SnapKind::Marker));
        let ex = tl.snap_points(&BTreeSet::from([a_id]), None, &[], false);
        assert_eq!(ex.iter().map(|p| p.time).collect::<Vec<_>>(), [0, 3, 7, 10, 12].map(s));
    }

    fn ids_next(ids: &mut SequentialIds) -> Id {
        use sq_core_time::IdSource;
        ids.next_id()
    }

    #[test]
    fn dedupe_prefers_non_frame() {
        let mut ids = SequentialIds::default();
        let mut t1 = Track::new(ids_next(&mut ids), TrackKind::Video);
        let c = clip(&mut ids, 0, 5);
        t1.overwrite(c, &mut ids).unwrap();
        let tl = timeline(vec![t1]);
        let p = tl.snap_points(&BTreeSet::new(), Some(s(5)), &[s(0)], false);
        assert_eq!(p.iter().map(|p| p.time).collect::<Vec<_>>(), [s(0), s(5)]);
        assert!(p.iter().all(|p| p.kind != SnapKind::Frame));
        let mixed =
            SnapPoint::normalized(&[SnapPoint::new(s(1), SnapKind::Frame), SnapPoint::new(s(1), SnapKind::Marker)]);
        assert!(mixed.len() == 1 && mixed[0].kind == SnapKind::Marker);
    }

    #[test]
    fn move_snaps_start() {
        let (delta, hit) = snap_move(Time::new(49, 10), s(2), &edges(&[5]), s(1), None);
        assert_eq!(delta, Time::new(1, 10));
        assert_eq!(hit.map(|h| h.time), Some(s(5)));
    }

    #[test]
    fn move_snaps_end() {
        let mut points = edges(&[3]);
        points.push(SnapPoint::new(Time::new(13, 4), SnapKind::Marker));
        let (delta, _) = snap_move(s(1), s(2), &points, s(1), None);
        assert_eq!(delta, Time::new(0, 1));
        let (d2, hit) = snap_move(Time::new(1, 1), Time::new(9, 4), &edges(&[4]), s(1), None);
        assert_eq!(d2, Time::new(3, 4));
        assert_eq!(hit.map(|h| h.time), Some(s(4)));
    }

    #[test]
    fn move_closer_hit_wins() {
        let points = [
            SnapPoint::new(Time::new(19, 2), SnapKind::ClipEdge),
            SnapPoint::new(Time::new(61, 5), SnapKind::ClipEdge),
        ];
        assert_eq!(snap_move(s(10), s(2), &points, s(1), None).0, Time::new(1, 5));
    }

    #[test]
    fn move_frame_fallback_and_no_hit() {
        let (delta, hit) = snap_move(Time::new(1, 30) + Time::new(1, 100), s(2), &[], s(1), Some(fd()));
        assert_eq!(delta, Time::new(-1, 100));
        assert_eq!(hit, None);
        assert_eq!(snap_move(Time::new(1, 100), s(2), &[], s(1), None).0, Time::ZERO);
    }
}
