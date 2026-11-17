//! Markers and poster frame on a media item, Mark Clip, and the Source monitor's list of opened clips.
// Swift: SourceMarkers.swift

use std::collections::BTreeSet;

use sq_core_model::{Marker, MarkerColor, Project, SourceMarks};
use sq_core_time::{Id, IdSource, Time};

/// Sorted by time, then by id text (Swift compares `uuidString`).
fn sorted(mut list: Vec<Marker>) -> Vec<Marker> {
    list.sort_by(|a, b| a.time.cmp(&b.time).then_with(|| a.id.cmp(&b.id)));
    list
}

/// Markers on a media item (M in the Source monitor). Stored in `MediaRef.source_markers`, sorted by time, one per frame.
pub trait SourceMarkersExt {
    /// The markers of `media`.
    fn source_markers(&self, media: Id) -> Vec<Marker>;
    /// Adds a marker at `time` (snapped to `frame_duration`, never before 0). A marker already on that frame is
    /// returned instead (`is_new == false`, Premiere: a second M opens the marker's edit dialog). None for unknown media.
    fn add_source_marker(
        &mut self,
        time: Time,
        frame_duration: Time,
        media: Id,
        ids: &mut dyn IdSource,
    ) -> Option<(Id, bool)>;
    /// Removes a marker; false when media or marker is unknown.
    fn remove_source_marker(&mut self, id: Id, media: Id) -> bool;
    /// Edits a marker in place and re-sorts; false when media or marker is unknown.
    fn update_source_marker(&mut self, id: Id, media: Id, body: impl FnOnce(&mut Marker)) -> bool;
    /// Poster frame (Cmd+P): the thumbnail time of `media`. None clears it (Option+P).
    fn set_poster_time(&mut self, time: Option<Time>, media: Id) -> bool;
    /// Mark Clip in the Source monitor: the media's In/Out become the whole clip. False for an empty media.
    fn mark_source_clip(&mut self, media: Id, duration: Time) -> bool;
}

impl SourceMarkersExt for Project {
    fn source_markers(&self, media: Id) -> Vec<Marker> {
        self.media(media).and_then(|m| m.source_markers.clone()).unwrap_or_default()
    }

    fn add_source_marker(
        &mut self,
        time: Time,
        frame_duration: Time,
        media: Id,
        ids: &mut dyn IdSource,
    ) -> Option<(Id, bool)> {
        let item = self.media.iter_mut().find(|m| m.id == media)?;
        let frame = Time::ZERO.max(time.snapped(frame_duration));
        let mut list = item.source_markers.take().unwrap_or_default();
        if let Some(m) = list.iter().find(|m| m.time == frame) {
            let id = m.id;
            item.source_markers = Some(list);
            return Some((id, false));
        }
        let m = Marker {
            id: ids.next_id(),
            time: frame,
            name: String::new(),
            color: MarkerColor::default(),
            comment: String::new(),
            duration: Time::ZERO,
        };
        let id = m.id;
        list.push(m);
        item.source_markers = Some(sorted(list));
        Some((id, true))
    }

    fn remove_source_marker(&mut self, id: Id, media: Id) -> bool {
        let Some(item) = self.media.iter_mut().find(|m| m.id == media) else { return false };
        let Some(list) = item.source_markers.as_mut().filter(|l| l.iter().any(|m| m.id == id)) else { return false };
        list.retain(|m| m.id != id);
        if list.is_empty() {
            item.source_markers = None;
        }
        true
    }

    fn update_source_marker(&mut self, id: Id, media: Id, body: impl FnOnce(&mut Marker)) -> bool {
        let Some(item) = self.media.iter_mut().find(|m| m.id == media) else { return false };
        let Some(list) = item.source_markers.take() else { return false };
        let mut list = list;
        let Some(j) = list.iter().position(|m| m.id == id) else {
            item.source_markers = Some(list);
            return false;
        };
        body(&mut list[j]);
        item.source_markers = Some(sorted(list));
        true
    }

    fn set_poster_time(&mut self, time: Option<Time>, media: Id) -> bool {
        let Some(item) = self.media.iter_mut().find(|m| m.id == media) else { return false };
        item.poster_time = time.map(|t| Time::ZERO.max(t));
        true
    }

    fn mark_source_clip(&mut self, media: Id, duration: Time) -> bool {
        let Some(m) = SourceMarksWholeClipExt::whole_clip(duration) else { return false };
        self.source_marks.insert(media, m);
        true
    }
}

/// Swift `SourceMarks.wholeClip`.
pub trait SourceMarksWholeClipExt: Sized {
    /// Mark Clip (X) in the Source monitor: In at the start, Out at the end of the whole media (the stored Out is one
    /// frame past the last frame). None for an empty media.
    fn whole_clip(duration: Time) -> Option<Self>;
}

impl SourceMarksWholeClipExt for SourceMarks {
    fn whole_clip(duration: Time) -> Option<SourceMarks> {
        (duration > Time::ZERO).then(|| SourceMarks {
            mark_in: Some(Time::ZERO),
            mark_out: Some(duration),
            ..SourceMarks::default()
        })
    }
}

/// The Source monitor's list of clips opened earlier (title popup): at most `LIMIT` unique ids, most recent first.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct SourceHistory {
    ids: Vec<Id>,
}

impl SourceHistory {
    /// Longest list.
    pub const LIMIT: usize = 20;

    /// An empty list.
    pub fn new() -> Self {
        Self::default()
    }

    /// The ids, most recent first.
    pub fn ids(&self) -> &[Id] {
        &self.ids
    }

    /// Moves `id` to the front. When the list is full the oldest entry drops out.
    pub fn open(&mut self, id: Id) {
        self.ids.retain(|x| *x != id);
        self.ids.insert(0, id);
        self.ids.truncate(Self::LIMIT);
    }

    /// Several ids at once (a multi-selection): the first becomes the current one, the rest follow it in order.
    pub fn open_all(&mut self, list: &[Id]) {
        for id in list.iter().rev() {
            self.open(*id);
        }
    }

    /// Removes `id`.
    pub fn close(&mut self, id: Id) {
        self.ids.retain(|x| *x != id);
    }

    /// Empties the list.
    pub fn close_all(&mut self) {
        self.ids.clear();
    }

    /// Drops ids that are no longer in the project.
    pub fn prune(&mut self, existing: &BTreeSet<Id>) {
        self.ids.retain(|x| existing.contains(x));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{MediaFingerprint, MediaRef};
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn fd() -> Time {
        Time::new(1, 30)
    }
    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }
    fn project() -> (Project, Id) {
        let m = MediaRef::new(id(500), "a", "/x/a", MediaFingerprint::new(1));
        (Project::new(id(501), "P", vec![m], vec![]), id(500))
    }

    #[test]
    fn adds_snapped_sorted_and_finds_existing() {
        let mut ids = SequentialIds::default();
        let (mut p, m) = project();
        let late = p.add_source_marker(s(5), fd(), m, &mut ids).unwrap();
        let early = p.add_source_marker(s(1) + Time::new(1, 90), fd(), m, &mut ids).unwrap();
        assert!(late.1 && early.1);
        assert_eq!(p.source_markers(m).iter().map(|x| x.time).collect::<Vec<_>>(), [s(1), s(5)]);
        let again = p.add_source_marker(s(5), fd(), m, &mut ids).unwrap();
        assert!(!again.1 && again.0 == late.0);
        assert_eq!(p.source_markers(m).len(), 2);
        assert_eq!(p.add_source_marker(s(1), fd(), id(9999), &mut ids), None);
    }

    #[test]
    fn update_and_remove() {
        let mut ids = SequentialIds::default();
        let (mut p, m) = project();
        let marker = p.add_source_marker(s(2), fd(), m, &mut ids).unwrap().0;
        assert!(p.update_source_marker(marker, m, |x| {
            x.name = "Hook".into();
            x.color = MarkerColor::Red;
        }));
        assert_eq!(p.source_markers(m)[0].name, "Hook");
        assert!(p.remove_source_marker(marker, m));
        assert_eq!(p.media(m).and_then(|x| x.source_markers.clone()), None);
        assert!(!p.remove_source_marker(marker, m));
    }

    #[test]
    fn poster_clears_with_none_and_never_goes_below_zero() {
        let (mut p, m) = project();
        assert!(p.set_poster_time(Some(s(4)), m));
        assert_eq!(p.media(m).and_then(|x| x.poster_time), Some(s(4)));
        p.set_poster_time(Some(s(-1)), m);
        assert_eq!(p.media(m).and_then(|x| x.poster_time), Some(Time::ZERO));
        p.set_poster_time(None, m);
        assert_eq!(p.media(m).and_then(|x| x.poster_time), None);
        assert!(!p.set_poster_time(None, id(9999)));
    }

    #[test]
    fn mark_clip_sets_whole_clip() {
        let (mut p, m) = project();
        assert!(p.mark_source_clip(m, s(10)));
        assert_eq!(
            p.source_marks[&m],
            SourceMarks { mark_in: Some(Time::ZERO), mark_out: Some(s(10)), ..SourceMarks::default() }
        );
        assert!(p.timelines.is_empty());
        assert_eq!(SourceMarks::whole_clip(Time::ZERO), None);
        assert!(!p.mark_source_clip(m, Time::ZERO));
    }

    #[test]
    fn history_keeps_unique_most_recent_first() {
        let mut h = SourceHistory::new();
        let (a, b, c) = (id(1), id(2), id(3));
        h.open(a);
        h.open(b);
        h.open(c);
        h.open(a);
        assert_eq!(h.ids(), [a, c, b]);
    }

    #[test]
    fn history_limits_to_twenty_and_drops_the_oldest() {
        let mut h = SourceHistory::new();
        let ids: Vec<Id> = (0..25).map(id).collect();
        for i in &ids {
            h.open(*i);
        }
        assert_eq!(h.ids().len(), 20);
        assert_eq!(h.ids().first(), ids.last());
        assert!(!h.ids().contains(&ids[0]));
    }

    #[test]
    fn history_multi_selection_loads_first_and_prune_and_close() {
        let mut h = SourceHistory::new();
        let (a, b, c) = (id(1), id(2), id(3));
        h.open_all(&[a, b, c]);
        assert_eq!(h.ids(), [a, b, c]);
        h.prune(&BTreeSet::from([a, c]));
        assert_eq!(h.ids(), [a, c]);
        h.close(a);
        assert_eq!(h.ids(), [c]);
        h.close_all();
        assert!(h.ids().is_empty());
    }
}
