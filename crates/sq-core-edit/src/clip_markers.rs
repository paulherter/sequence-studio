//! Port of `ClipMarkers.swift`: clip markers (v60), markers that belong to a clip's content, like Premiere's clip
//! markers. Stored in source time (`Clip::markers`): a marker names the source frame that starts at its `time`. A trim,
//! slip or split of a clip that plays its source range therefore never moves a marker off its frame; both halves of a
//! split keep the list and each shows the markers inside its own range.
//!
//! Where source time does not describe what plays:
//! - an applied title template (it plays its content through the zones whatever its source range) shows none: a trim
//!   does move the content under the markers;
//! - a hold frame shows one frame: none;
//! - a clip relinked to a still loses its source offset (`Project.adoptProbes`): its markers shift with `source.start`,
//!   so they keep their place on the clip.

use sq_core_model::{Clip, Marker, floored_to_frame};
use sq_core_time::Time;

/// `extension Clip` of `ClipMarkers.swift`.
pub trait ClipMarkersExt {
    /// The markers the clip shows, at clip-local time on the sequence frame grid, sorted by time. Each is placed on the
    /// timeline frame that shows the marker's source frame, by the frame convention of `source_time` /
    /// `timeline_time_for_source`: a reversed clip shows the frame starting at source `s` one frame before the instant it
    /// passes `s`. When the clip skips the marker's frame (fast speed) the marker sits on the frame playing across it.
    ///
    /// Range: a marker at the played range's start counts, one at its end does not (that frame is not shown). On a speed
    /// track a marker on the hull's end counts when the track passes that instant inside the clip (a turning point).
    /// A speed track that passes a source time more than once shows the marker at every visit: one entry per visit, all
    /// with the marker's `id`.
    ///
    /// `duration` is the marker's length on the clip (source length through a constant speed, snapped to frames); on a
    /// speed track it is kept as the source length.
    fn visible_markers(&self, fd: Time) -> Vec<Marker>;
}

impl ClipMarkersExt for Clip {
    fn visible_markers(&self, fd: Time) -> Vec<Marker> {
        let Some(all) = self.markers.as_ref().filter(|m| !m.is_empty()) else { return Vec::new() };
        if self.hold_frame.is_some() || self.plays_through_zones() || self.duration() <= Time::ZERO {
            return Vec::new();
        }
        let last_frame = Time::ZERO.max(floored_to_frame(self.duration() - fd, fd));
        let on_grid = |local: Time| floored_to_frame(local, fd).max(Time::ZERO).min(last_frame);
        let nudge = Time::new(1, 1 << 19);
        let mut out = Vec::new();
        for m in all {
            if let Some(k) = &self.speed_keys {
                let hull = k.hull();
                if m.time < hull.start || m.time > hull.end() {
                    continue;
                }
                let mut seen: Vec<Time> = Vec::new();
                for v in k.local_times_for_source(m.time) {
                    if m.time == hull.end() && !(v > Time::ZERO && v < self.duration()) {
                        continue;
                    }
                    if v >= self.duration() && !k.is_reversed((v - fd).max(Time::ZERO)) {
                        continue; // the out point itself is not shown
                    }
                    // Ramp visits are solved in Double and rounded to 1/2^20 s: nudge so a frame boundary does not fall back.
                    let exact = v + nudge;
                    let early = v - fd;
                    let local = on_grid(if fd > Time::ZERO && early >= Time::ZERO && k.is_reversed(early) {
                        early + nudge
                    } else {
                        exact
                    });
                    if seen.contains(&local) {
                        continue;
                    }
                    seen.push(local);
                    let mut x = m.clone();
                    x.time = local;
                    x.duration = m.duration.snapped(fd);
                    out.push(x);
                }
                continue;
            }
            if !(m.time >= self.source.start && m.time < self.source.end()) {
                continue;
            }
            let mut x = m.clone();
            x.time = on_grid(if self.reversed {
                self.speed.unscale(self.source.end() - m.time) - fd
            } else {
                self.speed.unscale(m.time - self.source.start)
            });
            x.duration = self.speed.unscale(m.duration).snapped(fd);
            out.push(x);
        }
        out.sort_by_key(|m| m.time);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{AnimationZones, ClipSpeed, MarkerColor, SpeedKeys, SpeedSegment, TrackKind, ZoneMiddle};
    use sq_core_time::{IdSource, SequentialIds, TimeRange};

    const FD: Time = Time::new(1, 30);

    fn t(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn marker(ids: &mut SequentialIds, time: Time, name: &str) -> Marker {
        Marker {
            id: ids.next_id(),
            time,
            name: name.to_string(),
            color: MarkerColor::default(),
            comment: String::new(),
            duration: Time::ZERO,
        }
    }

    fn clip(ids: &mut SequentialIds, markers: Option<Vec<Marker>>) -> Clip {
        let (id, media) = (ids.next_id(), ids.next_id());
        let mut c = Clip::new(id, "c", media, TrackKind::Video, TimeRange::new(t(2), t(4)), Time::ZERO);
        c.media_duration = Some(t(20));
        c.markers = markers;
        c
    }

    fn names(v: &[Marker]) -> Vec<&str> {
        v.iter().map(|m| m.name.as_str()).collect()
    }

    fn times(v: &[Marker]) -> Vec<Time> {
        v.iter().map(|m| m.time).collect()
    }

    #[test]
    fn template_clip_playing_through_zones_shows_none() {
        let mut ids = SequentialIds::default();
        let ms = vec![marker(&mut ids, t(3), "")];
        let mut c = clip(&mut ids, Some(ms));
        assert_eq!(c.visible_markers(FD).len(), 1);
        c.sequence = Some(ids.next_id());
        c.zones = Some(AnimationZones::new(t(1), t(1), ZoneMiddle::Hold, Some(t(4))));
        assert!(c.visible_markers(FD).is_empty());
    }

    #[test]
    fn visible_markers_are_clip_local() {
        let mut ids = SequentialIds::default();
        let inside = marker(&mut ids, t(3), "in");
        let ms = vec![
            marker(&mut ids, t(1), ""),
            inside.clone(),
            marker(&mut ids, t(6), ""),
            marker(&mut ids, t(2), "head"),
        ];
        let c = clip(&mut ids, Some(ms));
        let v = c.visible_markers(FD);
        assert_eq!(names(&v), ["head", "in"]);
        assert_eq!(times(&v), [Time::ZERO, t(1)]);
        assert_eq!(v[1].id, inside.id);
    }

    #[test]
    fn visible_markers_follow_speed_and_direction() {
        let mut ids = SequentialIds::default();
        let ms = vec![marker(&mut ids, t(3), "")];
        let mut c = clip(&mut ids, Some(ms));
        c.speed = ClipSpeed::from_percent(200.0);
        c.source = TimeRange::new(t(2), t(4));
        assert_eq!(times(&c.visible_markers(FD)), [Time::new(1, 2)]);
        // A frame the 200 % clip skips sits on the frame playing across it, on the grid.
        c.markers = Some(vec![marker(&mut ids, t(2) + FD, "")]);
        assert_eq!(times(&c.visible_markers(FD)), [Time::ZERO]);
    }

    /// Reversed: the frame starting at source `s` is shown one frame before the clip passes `s`, so every visible marker
    /// lies inside the clip and on the frame showing it.
    #[test]
    fn reversed_clip_puts_markers_on_the_frame_showing_them() {
        let mut ids = SequentialIds::default();
        let ms = vec![
            marker(&mut ids, t(3), "mid"),
            marker(&mut ids, t(2), "sourceStart"),
            marker(&mut ids, t(6) - FD, "lastSourceFrame"),
            marker(&mut ids, t(6), "end"),
        ];
        let mut c = clip(&mut ids, Some(ms.clone()));
        c.reversed = true;
        let v = c.visible_markers(FD);
        assert_eq!(names(&v), ["lastSourceFrame", "mid", "sourceStart"]);
        assert_eq!(times(&v), [Time::ZERO, t(3) - FD, t(4) - FD]);
        for m in &v {
            assert!(m.time < c.duration());
            let source = c.source_time(c.start + m.time, FD);
            assert_eq!(Some(source), ms.iter().find(|x| x.id == m.id).map(|x| x.time));
            assert_eq!(c.timeline_time_for_source(source, FD), c.start + m.time);
        }
    }

    /// A speed track that plays forwards then backwards passes a source time twice: the marker shows at every visit, on the
    /// grid, by the reversed frame convention on the way back. The hull's end counts at the turning point.
    #[test]
    fn speed_track_shows_every_visit_on_the_frame_grid() {
        let mut ids = SequentialIds::default();
        let ms = vec![
            marker(&mut ids, Time::new(5, 2), "twice"),
            marker(&mut ids, t(3), "peak"),
            marker(&mut ids, t(2), "ends"),
        ];
        let mut c = clip(&mut ids, Some(ms));
        c.set_speed_keys(Some(SpeedKeys::new(
            vec![
                SpeedSegment::new(t(1), ClipSpeed::NORMAL, None, false, None),
                SpeedSegment::new(t(1), ClipSpeed::NORMAL, None, true, None),
            ],
            t(2),
        )));
        let v = c.visible_markers(FD);
        assert_eq!(names(&v), ["ends", "twice", "peak", "twice", "ends"]);
        assert_eq!(times(&v), [Time::ZERO, Time::new(1, 2), t(1), Time::new(3, 2) - FD, t(2) - FD]);
        let twice: Vec<_> = v.iter().filter(|m| m.name == "twice").map(|m| m.id).collect();
        assert_eq!(twice[0], twice[1]);
    }

    /// A ramp's inverse is solved numerically (1/2^20 s): the visible time is still a whole frame.
    #[test]
    fn ramped_clip_snaps_markers_to_frames() {
        let mut ids = SequentialIds::default();
        let ms = vec![marker(&mut ids, Time::new(23, 10), ""), marker(&mut ids, Time::new(7, 2), "outPoint")];
        let mut c = clip(&mut ids, Some(ms));
        // 100 % -> 200 % over 1 s from source 2 s: position = 2 + t + t^2 / 2, ends at 3.5 s. Source 2.3 s is at t = 0.2649 s.
        c.set_speed_keys(Some(SpeedKeys::new(
            vec![SpeedSegment::new(t(1), ClipSpeed::NORMAL, Some(ClipSpeed::from_percent(200.0)), false, None)],
            t(2),
        )));
        // The out point (hull end, reached only at the clip's end) is not shown.
        assert_eq!(times(&c.visible_markers(FD)), [FD * 7]);
    }

    #[test]
    fn hold_frame_shows_none() {
        let mut ids = SequentialIds::default();
        let ms = vec![marker(&mut ids, t(3), "")];
        let mut c = clip(&mut ids, Some(ms));
        c.hold_frame = Some(t(3));
        assert!(c.visible_markers(FD).is_empty());
    }

    #[test]
    fn split_halves_keep_markers_on_their_frames() {
        let mut ids = SequentialIds::default();
        let ms = vec![marker(&mut ids, t(3), "a"), marker(&mut ids, t(5), "b")];
        let c = clip(&mut ids, Some(ms));
        let mut tr = sq_core_model::Track::new(ids.next_id(), TrackKind::Video);
        tr.overwrite(c, &mut ids).unwrap();
        tr.split(t(2), &mut ids).unwrap();
        let clips = tr.clips();
        assert_eq!(clips.len(), 2);
        assert_eq!(names(&clips[0].visible_markers(FD)), ["a"]);
        assert_eq!(times(&clips[0].visible_markers(FD)), [t(1)]);
        assert_eq!(names(&clips[1].visible_markers(FD)), ["b"]);
        // Second half starts at timeline 2 s = source 4 s: marker b (source 5 s) is 1 s in.
        assert_eq!(times(&clips[1].visible_markers(FD)), [t(1)]);
    }

    #[test]
    fn no_markers_means_none_visible() {
        let mut ids = SequentialIds::default();
        assert!(clip(&mut ids, None).visible_markers(FD).is_empty());
    }
}
