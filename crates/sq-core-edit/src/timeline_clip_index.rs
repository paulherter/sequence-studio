//! Clip id lookup for one timeline value.
// Swift: TimelineClipIndex.swift

use std::collections::HashMap;

use sq_core_model::{Clip, Timeline};
use sq_core_time::Id;

/// Where a clip sits.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Location {
    /// Index into `Timeline.tracks`.
    pub track: usize,
    /// Index into that track's clips.
    pub clip: usize,
    pub track_id: Id,
}

/// Clip ID -> (track, position) lookup for one timeline value, plus link groups. Built once per timeline value
/// (O(clips)); every lookup is then O(1) instead of a scan over all tracks. A value type: the owner rebuilds it whenever
/// it assigns a new timeline (an index of an older value is simply stale, never shared).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TimelineClipIndex {
    locations: HashMap<Id, Location>,
    links: HashMap<Id, Vec<Id>>,
    bundles: HashMap<Id, Vec<Id>>,
}

impl TimelineClipIndex {
    /// An empty index.
    pub fn new() -> Self {
        Self::default()
    }

    /// The index of `timeline`.
    pub fn of(timeline: &Timeline) -> Self {
        let mut ix = Self::new();
        for (ti, t) in timeline.tracks.iter().enumerate() {
            for (ci, c) in t.clips().iter().enumerate() {
                ix.locations.insert(c.id, Location { track: ti, clip: ci, track_id: t.id });
                if let Some(l) = c.link {
                    ix.links.entry(l).or_default().push(c.id);
                }
                if let Some(b) = c.bundle {
                    ix.bundles.entry(b).or_default().push(c.id);
                }
            }
        }
        ix
    }

    /// Number of clips.
    pub fn count(&self) -> usize {
        self.locations.len()
    }

    /// Where clip `id` sits.
    pub fn location(&self, id: Id) -> Option<Location> {
        self.locations.get(&id).copied()
    }

    /// The track holding clip `id`.
    pub fn track_id(&self, id: Id) -> Option<Id> {
        self.locations.get(&id).map(|l| l.track_id)
    }

    /// Whether clip `id` is in the timeline.
    pub fn contains(&self, id: Id) -> bool {
        self.locations.contains_key(&id)
    }

    /// The clip in `timeline`, which must be the value this index was built from.
    pub fn clip<'a>(&self, id: Id, timeline: &'a Timeline) -> Option<&'a Clip> {
        let l = self.locations.get(&id)?;
        timeline.tracks.get(l.track)?.clips().get(l.clip)
    }

    /// Every clip carrying `link`, in track then position order.
    pub fn clips_linked_by(&self, link: Id) -> &[Id] {
        self.links.get(&link).map_or(&[], Vec::as_slice)
    }

    /// Every clip carrying `bundle` (v57), in track then position order.
    pub fn clips_bundled_by(&self, bundle: Id) -> &[Id] {
        self.bundles.get(&bundle).map_or(&[], Vec::as_slice)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track, TrackKind};
    use sq_core_time::{IdSource, SequentialIds, Time, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// V1 and A1 with `n` linked pairs, 2 s each, back to back; plus an empty V2.
    fn make(ids: &mut SequentialIds, n: i64) -> Timeline {
        let mut v = Track::new(ids.next_id(), TrackKind::Video);
        let mut a = Track::new(ids.next_id(), TrackKind::Audio);
        let v2 = Track::new(ids.next_id(), TrackKind::Video);
        for i in 0..n {
            let link = ids.next_id();
            let range = TimeRange::new(s(0), s(2));
            let mut cv = Clip::new(ids.next_id(), &format!("v{i}"), ids.next_id(), TrackKind::Video, range, s(i * 2));
            let mut ca = Clip::new(ids.next_id(), &format!("a{i}"), ids.next_id(), TrackKind::Audio, range, s(i * 2));
            cv.link = Some(link);
            ca.link = Some(link);
            v.overwrite(cv, ids).unwrap();
            a.overwrite(ca, ids).unwrap();
        }
        Timeline::new(ids.next_id(), "T", SequenceFormat::new(Time::new(1, 30)), vec![v2, v, a])
    }

    /// The index must agree with a full scan for every clip, and know nothing else.
    fn expect_matches(t: &Timeline, ix: &TimelineClipIndex) {
        let mut total = 0;
        let mut links: HashMap<Id, Vec<Id>> = HashMap::new();
        for (ti, track) in t.tracks.iter().enumerate() {
            for (ci, c) in track.clips().iter().enumerate() {
                total += 1;
                assert_eq!(ix.location(c.id), Some(Location { track: ti, clip: ci, track_id: track.id }));
                assert_eq!(ix.track_id(c.id), Some(track.id));
                assert_eq!(ix.clip(c.id, t), Some(c));
                if let Some(l) = c.link {
                    links.entry(l).or_default().push(c.id);
                }
            }
        }
        assert_eq!(ix.count(), total);
        for (l, ids) in links {
            assert_eq!(ix.clips_linked_by(l), ids);
        }
        let unknown = Id::from_u128(u128::MAX);
        assert_eq!(ix.location(unknown), None);
        assert_eq!(ix.clip(unknown, t), None);
        assert!(ix.clips_linked_by(unknown).is_empty());
    }

    #[test]
    fn fresh_timeline_matches_scan() {
        let mut ids = SequentialIds::default();
        let t = make(&mut ids, 4);
        expect_matches(&t, &TimelineClipIndex::of(&t));
        let empty = Timeline::new(Id::NIL, "E", t.format.clone(), vec![]);
        assert_eq!(TimelineClipIndex::of(&empty).count(), 0);
    }

    #[test]
    fn after_track_insert_and_delete() {
        let mut ids = SequentialIds::default();
        let mut t = make(&mut ids, 4);
        let before = TimelineClipIndex::of(&t);
        t.tracks.insert(0, Track::new(ids.next_id(), TrackKind::Video));
        let inserted = TimelineClipIndex::of(&t);
        expect_matches(&t, &inserted);
        assert_ne!(inserted, before);
        let id = t.tracks[2].clips()[0].id;
        assert_eq!(inserted.location(id).map(|l| l.track), Some(2));

        let removed = t.tracks.remove(2);
        let ix = TimelineClipIndex::of(&t);
        expect_matches(&t, &ix);
        for c in removed.clips() {
            assert!(!ix.contains(c.id));
        }
        assert_eq!(ix.count(), 4);
    }
}
