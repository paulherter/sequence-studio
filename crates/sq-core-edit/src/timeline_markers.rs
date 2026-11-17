// Swift: Timeline+Markers.swift
//! Sequence marker operations (Premiere behavior). Markers stay sorted by time.

use sq_core_model::{Marker, Timeline};
use sq_core_time::{Id, IdSource, Time, TimeRange};

/// Markers sorted by time, ties by id (the Swift `uuidString` order).
pub(crate) fn sort_markers(markers: &mut [Marker]) {
    markers.sort_by(|a, b| a.time.cmp(&b.time).then(a.id.cmp(&b.id)));
}

/// A marker with the Swift initializer's defaults.
pub(crate) fn new_marker(id: Id, time: Time, name: &str) -> Marker {
    Marker { id, time, name: name.to_string(), color: Default::default(), comment: String::new(), duration: Time::ZERO }
}

/// `extension Timeline` of Timeline+Markers.swift.
pub trait TimelineMarkersExt {
    /// Adds a marker at `time` (snapped to the frame grid, not before 0) and returns its id.
    fn add_marker(&mut self, time: Time, name: &str, ids: &mut dyn IdSource) -> Id;
    /// Mark All for search hits: one marker per distinct hit time, named after the search text. A marker with the same name
    /// on the same frame is not added twice. Returns how many were added.
    // Swift: TextSearch.swift:30
    fn add_search_hit_markers(&mut self, times: &[Time], name: &str, ids: &mut dyn IdSource) -> usize;
    /// Removes the marker.
    fn remove_marker(&mut self, id: Id);
    /// Moves the marker to `time` (frame grid, not before 0).
    fn move_marker(&mut self, id: Id, time: Time);
    /// Renames the marker.
    fn rename_marker(&mut self, id: Id, name: &str);
    /// Generic edit of one marker (comment, color, duration). False if the id is unknown.
    fn update_marker(&mut self, id: Id, body: impl FnOnce(&mut Marker)) -> bool;
    /// M: adds a marker at the playhead; if one already sits on that frame, returns it with `true` (second M opens
    /// the edit dialog) and adds nothing.
    fn mark_at_playhead(&mut self, playhead: Time, ids: &mut dyn IdSource) -> (Id, bool);
    /// The first marker after `t`.
    fn next_marker(&self, t: Time) -> Option<&Marker>;
    /// The last marker before `t`.
    fn previous_marker(&self, t: Time) -> Option<&Marker>;
    /// Markers with `range.start <= time < range.end`.
    fn markers_in(&self, range: TimeRange) -> Vec<&Marker>;
    /// `shift_markers` for many closed spans at once: `f` is their composed point map; a range marker maps both ends.
    fn shift_markers_through(&mut self, f: impl Fn(Time) -> Time);
}

fn clamped_frame(tl: &Timeline, t: Time) -> Time {
    t.snapped(tl.frame_duration()).max(Time::ZERO)
}

impl TimelineMarkersExt for Timeline {
    fn add_marker(&mut self, time: Time, name: &str, ids: &mut dyn IdSource) -> Id {
        let m = new_marker(ids.next_id(), clamped_frame(self, time), name);
        let id = m.id;
        self.markers.push(m);
        sort_markers(&mut self.markers);
        id
    }

    fn add_search_hit_markers(&mut self, times: &[Time], name: &str, ids: &mut dyn IdSource) -> usize {
        let mut added = 0;
        for t in times {
            let frame = clamped_frame(self, *t);
            if self.markers.iter().any(|m| m.time == frame && m.name == name) {
                continue;
            }
            self.add_marker(frame, name, ids);
            added += 1;
        }
        added
    }

    fn remove_marker(&mut self, id: Id) {
        self.markers.retain(|m| m.id != id);
    }

    fn move_marker(&mut self, id: Id, time: Time) {
        let t = clamped_frame(self, time);
        let Some(i) = self.markers.iter().position(|m| m.id == id) else { return };
        self.markers[i].time = t;
        sort_markers(&mut self.markers);
    }

    fn rename_marker(&mut self, id: Id, name: &str) {
        if let Some(m) = self.markers.iter_mut().find(|m| m.id == id) {
            m.name = name.to_string();
        }
    }

    fn update_marker(&mut self, id: Id, body: impl FnOnce(&mut Marker)) -> bool {
        let Some(i) = self.markers.iter().position(|m| m.id == id) else { return false };
        body(&mut self.markers[i]);
        sort_markers(&mut self.markers);
        true
    }

    fn mark_at_playhead(&mut self, playhead: Time, ids: &mut dyn IdSource) -> (Id, bool) {
        let frame = clamped_frame(self, playhead);
        if let Some(m) = self.markers.iter().find(|m| m.time == frame) {
            return (m.id, true);
        }
        (self.add_marker(frame, "", ids), false)
    }

    fn next_marker(&self, t: Time) -> Option<&Marker> {
        self.markers.iter().find(|m| m.time > t)
    }

    fn previous_marker(&self, t: Time) -> Option<&Marker> {
        self.markers.iter().rev().find(|m| m.time < t)
    }

    fn markers_in(&self, range: TimeRange) -> Vec<&Marker> {
        self.markers.iter().filter(|m| m.time >= range.start && m.time < range.end()).collect()
    }

    fn shift_markers_through(&mut self, f: impl Fn(Time) -> Time) {
        for m in &mut self.markers {
            if m.duration > Time::ZERO {
                let (s, e) = (f(m.time), f(m.time + m.duration));
                m.time = s;
                m.duration = (e - s).max(Time::ZERO);
            } else {
                m.time = f(m.time);
            }
        }
        sort_markers(&mut self.markers);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::SequenceFormat;
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn tl() -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), vec![])
    }
    fn names(t: &Timeline) -> Vec<&str> {
        t.markers.iter().map(|m| m.name.as_str()).collect()
    }
    fn times(t: &Timeline) -> Vec<Time> {
        t.markers.iter().map(|m| m.time).collect()
    }
    fn with_markers(at: &[i64]) -> Timeline {
        let (mut t, mut ids) = (tl(), SequentialIds::default());
        for n in at {
            t.add_marker(s(*n), "", &mut ids);
        }
        t
    }

    #[test]
    fn mark_all_adds_one_marker_per_hit_and_pressing_it_again_changes_nothing() {
        let (mut t, mut ids) = (tl(), SequentialIds::default());
        let hits = [s(2), s(2), s(5), Time::new(-1, 1)];
        assert_eq!(t.add_search_hit_markers(&hits, "fox", &mut ids), 3); // 2 s once, 5 s, the negative one at 0
        assert_eq!(times(&t), vec![s(0), s(2), s(5)]);
        assert!(names(&t).iter().all(|n| *n == "fox"));
        assert_eq!(t.add_search_hit_markers(&hits, "fox", &mut ids), 0);
        assert_eq!(t.add_search_hit_markers(&[s(2)], "dog", &mut ids), 1); // another name on the same frame is new
    }

    #[test]
    fn add_keeps_sorted_and_snaps_to_frame() {
        let (mut t, mut ids) = (tl(), SequentialIds::default());
        t.add_marker(s(5), "b", &mut ids);
        t.add_marker(Time::new(1, 61), "a", &mut ids);
        assert_eq!(names(&t), vec!["a", "b"]);
        assert_eq!(t.markers[0].time.snapped(Time::new(1, 30)), t.markers[0].time);
    }

    #[test]
    fn remove_move_rename() {
        let (mut t, mut ids) = (tl(), SequentialIds::default());
        let a = t.add_marker(s(1), "a", &mut ids);
        let b = t.add_marker(s(3), "b", &mut ids);
        t.move_marker(a, s(4));
        assert_eq!(names(&t), vec!["b", "a"]);
        t.move_marker(a, s(-2));
        assert_eq!(t.markers.first().map(|m| m.time), Some(Time::ZERO));
        t.rename_marker(b, "x");
        assert!(t.markers.iter().any(|m| m.name == "x"));
        t.remove_marker(a);
        assert_eq!(t.markers.len(), 1);
        t.remove_marker(Id::from_u128(99));
        assert_eq!(t.markers.len(), 1);
    }

    #[test]
    fn update_marker_closure() {
        let (mut t, mut ids) = (tl(), SequentialIds::default());
        let a = t.add_marker(s(1), "", &mut ids);
        assert!(t.update_marker(a, |m| m.name = "n".into()));
        assert_eq!(t.markers[0].name, "n");
        assert!(!t.update_marker(Id::from_u128(99), |_| {}));
    }

    #[test]
    fn marker_at_playhead_toggle() {
        let (mut t, mut ids) = (tl(), SequentialIds::default());
        let r1 = t.mark_at_playhead(s(2), &mut ids);
        assert!(!r1.1);
        let r2 = t.mark_at_playhead(s(2), &mut ids);
        assert!(r2.1 && r2.0 == r1.0);
        assert_eq!(t.markers.len(), 1);
        assert!(t.mark_at_playhead(s(2) + Time::new(1, 100), &mut ids).1);
        assert!(!t.mark_at_playhead(s(3), &mut ids).1);
        assert_eq!(t.markers.len(), 2);
    }

    #[test]
    fn next_previous() {
        let t = with_markers(&[2, 4, 6]);
        assert_eq!(t.next_marker(s(2)).map(|m| m.time), Some(s(4)));
        assert_eq!(t.next_marker(s(1)).map(|m| m.time), Some(s(2)));
        assert!(t.next_marker(s(6)).is_none());
        assert_eq!(t.previous_marker(s(4)).map(|m| m.time), Some(s(2)));
        assert!(t.previous_marker(s(2)).is_none());
        assert_eq!(t.previous_marker(s(10)).map(|m| m.time), Some(s(6)));
    }

    #[test]
    fn in_range() {
        let t = with_markers(&[2, 4, 6]);
        let hit = |r: TimeRange| t.markers_in(r).iter().map(|m| m.time).collect::<Vec<_>>();
        assert_eq!(hit(TimeRange::new(s(2), s(4))), vec![s(2), s(4)]);
        assert!(hit(TimeRange::new(s(7), s(1))).is_empty());
    }

    #[test]
    fn ripple_shift() {
        let mut t = with_markers(&[1, 4, 6, 9]);
        t.shift_markers(s(4), s(2));
        assert_eq!(times(&t), vec![s(1), s(6), s(8), s(11)]);
        t.shift_markers(s(8), s(-3));
        assert_eq!(times(&t), vec![s(1), s(5), s(5), s(8)]);
    }

    #[test]
    fn shift_through_maps_both_ends_of_a_range_marker() {
        let (mut t, mut ids) = (tl(), SequentialIds::default());
        t.add_marker(s(1), "", &mut ids);
        let r = t.add_marker(s(4), "r", &mut ids);
        t.update_marker(r, |m| m.duration = s(4));
        t.shift_markers_through(|x| if x >= s(6) { x - s(2) } else { x });
        assert_eq!(times(&t), vec![s(1), s(4)]);
        assert_eq!(t.markers[1].duration, s(2));
    }
}
