//! Port of `UndoFocus.swift`: what an undo or redo touched in a sequence: the clips that exist afterwards and the time
//! range they or their removed predecessors covered. The editor moves the playhead, selection and view there so the
//! change is visible.

use sq_core_model::{Clip, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// The clips and the range an undo or redo touched.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UndoFocus {
    /// Clips that exist afterwards and differ from before.
    pub clips: BTreeSet<Id>,
    /// What they or their removed predecessors covered.
    pub range: TimeRange,
    /// A clip appeared, left or moved or changed length. A change that only edits what a clip holds (a grade, an effect
    /// value) leaves the playhead where it is.
    pub timing_changed: bool,
}

fn by_id(t: &Timeline) -> BTreeMap<Id, &Clip> {
    let mut m = BTreeMap::new();
    for c in t.tracks.iter().flat_map(|t| t.clips()) {
        m.entry(c.id).or_insert(c); // the first wins, like `uniquingKeysWith: { a, _ in a }`
    }
    m
}

impl UndoFocus {
    /// Compares two states of the same sequence by clip. `None` when no clip differs (or a state is missing).
    pub fn between(old: Option<&Timeline>, new: Option<&Timeline>) -> Option<UndoFocus> {
        let (old, new) = (old?, new?);
        let (before, after) = (by_id(old), by_id(new));
        let mut ids = BTreeSet::new();
        let mut span: Option<(Time, Time)> = None;
        let mut timing_changed = false;
        let mut cover = |r: TimeRange| {
            span = Some(match span {
                Some((lo, hi)) => (lo.min(r.start), hi.max(r.end())),
                None => (r.start, r.end()),
            });
        };
        for (id, c) in &after {
            let was = before.get(id);
            if was != Some(c) {
                ids.insert(*id);
                cover(c.timeline());
                match was {
                    Some(o) => {
                        cover(o.timeline());
                        timing_changed |= o.timeline() != c.timeline();
                    }
                    None => timing_changed = true,
                }
            }
        }
        for (id, c) in &before {
            if !after.contains_key(id) {
                timing_changed = true;
                cover(c.timeline());
            }
        }
        let (lo, hi) = span?;
        Some(UndoFocus { clips: ids, range: TimeRange::from_end(lo, hi), timing_changed })
    }

    /// Where the playhead should go: `None` when it already is inside the range or nothing moved in time, else the range
    /// start.
    pub fn playhead(&self, current: Time) -> Option<Time> {
        if !self.timing_changed {
            return None;
        }
        (current < self.range.start || current > self.range.end()).then_some(self.range.start)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track, TrackKind};
    use sq_core_time::{IdSource, SequentialIds};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn clip(ids: &mut SequentialIds, start: i64, dur: i64) -> Clip {
        let media = ids.next_id();
        Clip::new(ids.next_id(), "c", media, TrackKind::Video, TimeRange::new(s(0), s(dur)), s(start))
    }

    fn timeline(ids: &mut SequentialIds, clips: &[Clip]) -> Timeline {
        let mut t = Track::new(ids.next_id(), TrackKind::Video);
        t.set_clips(clips.to_vec());
        Timeline::new(ids.next_id(), "t", SequenceFormat::new(Time::new(1, 30)), vec![t])
    }

    #[test]
    fn identical_timelines_have_no_focus() {
        let mut ids = SequentialIds::default();
        let c = clip(&mut ids, 0, 5);
        let t = timeline(&mut ids, &[c]);
        assert_eq!(UndoFocus::between(Some(&t), Some(&t)), None);
        assert_eq!(UndoFocus::between(None, Some(&t)), None);
    }

    #[test]
    fn changed_clip_is_focused_with_its_range() {
        let mut ids = SequentialIds::default();
        let (a, b) = (clip(&mut ids, 0, 5), clip(&mut ids, 10, 5));
        let mut b2 = b.clone();
        b2.name = "renamed".into();
        let (t1, t2) = (timeline(&mut ids, &[a.clone(), b.clone()]), timeline(&mut ids, &[a, b2]));
        let f = UndoFocus::between(Some(&t1), Some(&t2)).unwrap();
        assert_eq!(f.clips, [b.id].into());
        assert_eq!(f.range, TimeRange::new(s(10), s(5)));
    }

    #[test]
    fn a_changed_clip_value_does_not_move_the_playhead() {
        let mut ids = SequentialIds::default();
        let (a, b) = (clip(&mut ids, 0, 5), clip(&mut ids, 10, 5));
        let mut b2 = b.clone();
        b2.name = "renamed".into();
        let (t1, t2) = (timeline(&mut ids, &[a.clone(), b]), timeline(&mut ids, &[a, b2]));
        let f = UndoFocus::between(Some(&t1), Some(&t2)).unwrap();
        assert!(!f.timing_changed);
        assert_eq!(f.playhead(s(0)), None, "the undo of a grade or effect edit stays where the playhead is");
    }

    #[test]
    fn moved_clip_covers_old_and_new_position() {
        let mut ids = SequentialIds::default();
        let a = clip(&mut ids, 0, 5);
        let mut moved = a.clone();
        moved.start = s(20);
        let (t1, t2) = (timeline(&mut ids, std::slice::from_ref(&a)), timeline(&mut ids, &[moved]));
        let f = UndoFocus::between(Some(&t1), Some(&t2)).unwrap();
        assert_eq!(f.clips, [a.id].into());
        assert_eq!(f.range, TimeRange::from_end(s(0), s(25)));
    }

    #[test]
    fn removed_clip_focuses_range_but_no_clips() {
        let mut ids = SequentialIds::default();
        let (a, b) = (clip(&mut ids, 0, 5), clip(&mut ids, 10, 5));
        let (t1, t2) = (timeline(&mut ids, &[a.clone(), b]), timeline(&mut ids, &[a]));
        let f = UndoFocus::between(Some(&t1), Some(&t2)).unwrap();
        assert!(f.clips.is_empty());
        assert_eq!(f.range, TimeRange::new(s(10), s(5)));
    }

    #[test]
    fn added_clip_is_focused() {
        let mut ids = SequentialIds::default();
        let (a, b) = (clip(&mut ids, 0, 5), clip(&mut ids, 10, 5));
        let (t1, t2) = (timeline(&mut ids, std::slice::from_ref(&a)), timeline(&mut ids, &[a.clone(), b.clone()]));
        assert_eq!(UndoFocus::between(Some(&t1), Some(&t2)).map(|f| f.clips), Some([b.id].into()));
    }

    #[test]
    fn playhead_stays_when_inside_range_and_moves_to_range_start_when_outside() {
        let f = UndoFocus { clips: BTreeSet::new(), range: TimeRange::new(s(10), s(5)), timing_changed: true };
        assert_eq!(f.playhead(s(12)), None);
        assert_eq!(f.playhead(s(15)), None);
        assert_eq!(f.playhead(s(2)), Some(s(10)));
        assert_eq!(f.playhead(s(40)), Some(s(10)));
    }
}
