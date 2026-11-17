// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Subclip.swift (saved type, moved down; Make Subclip: task M-4)
//
// Make Subclip (v57): a range of a media item becomes its own Project item, filed right after its parent. It is an
// ordinary `MediaRef` over the same file (so playback, thumbnails, drag to the timeline and relink treat it like any media)
// with `subclip` set. Its bounds are soft, like Premiere with "Restrict trims to subclip boundaries" off: the range seeds the
// item's In/Out and poster frame, and clips cut from it can still be trimmed into the rest of the file.

use crate::project::trim_spaces;
use crate::{BinItem, BinItemRef, EditError, MediaRef, Project, SourceMarks};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, IdSource, Time, TimeRange};

/// Where a subclip comes from.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Subclip {
    /// The media item over the whole file (a subclip of a subclip points at the file's item).
    pub parent: Id,
    /// The part of the media it covers (media time).
    pub range: TimeRange,
}

impl MediaRef {
    /// True for an item made with Make Subclip.
    pub fn is_subclip(&self) -> bool {
        self.subclip.is_some()
    }
}

impl Project {
    /// Make Subclip: a new media item over `range` of media `id` (clamped to the media's length when known), named `name`
    /// or "<parent> Subclip" (" 2", " 3"... when taken), filed right after `id` in its bin. Its In/Out marks are `range`
    /// and its poster frame the range start. Returns the new item's id (taken from `ids`). Unknown media:
    /// `ClipNotFound`; a range with nothing left after clamping: `EmptyClip`.
    pub fn make_subclip(
        &mut self,
        id: Id,
        range: TimeRange,
        name: Option<&str>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let source = self.media(id).ok_or(EditError::ClipNotFound)?;
        let parent_id = source.subclip.as_ref().map_or(id, |s| s.parent);
        let parent = self.media(parent_id).unwrap_or(source);
        let (mut start, mut end) = (range.start.max(Time::ZERO), range.end());
        if let Some(d) = parent.duration {
            end = end.min(d);
            start = start.min(d);
        }
        if end <= start {
            return Err(EditError::EmptyClip);
        }
        let r = TimeRange::from_end(start, end);

        let base = format!("{} Subclip", parent.name);
        let mut label = base.clone();
        let mut n = 2;
        while self.media.iter().any(|m| m.name == label) {
            label = format!("{base} {n}");
            n += 1;
        }
        let given = trim_spaces(name.unwrap_or(""), false);

        let mut item = MediaRef::new(
            ids.next_id(),
            if given.is_empty() { &label } else { given },
            &parent.path,
            parent.fingerprint.clone(),
        );
        item.bookmark = parent.bookmark.clone();
        item.duration = parent.duration;
        item.info = parent.info.clone();
        item.label = source.label;
        item.poster_time = Some(r.start);
        item.subclip = Some(Subclip { parent: parent_id, range: r });
        let new_id = item.id;
        self.media.push(item);
        let at = BinItemRef::Media(id);
        match self.root_bin.parent_of(at).and_then(|bin| self.root_bin.bin_mut(bin)) {
            Some(b) => {
                let i = b.children.iter().position(|c| c.item_ref() == at).map_or(b.children.len(), |i| i + 1);
                b.children.insert(i, BinItem::Media(new_id));
            }
            None => self.root_bin.children.push(BinItem::Media(new_id)),
        }
        self.source_marks
            .insert(new_id, SourceMarks { mark_in: Some(r.start), mark_out: Some(r.end()), ..SourceMarks::default() });
        Ok(new_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    #[test]
    fn round_trips() {
        assert_round_trip::<Subclip>(json!({
            "parent": "00000000-0000-0000-0000-000000000007",
            "range": {"start": {"value": 1, "timescale": 1}, "duration": {"value": 2, "timescale": 1}}}));
    }

    use crate::nesting::test_util::*;
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn range(a: i64, b: i64) -> TimeRange {
        TimeRange::from_end(s(a), s(b))
    }

    /// Interview.mov (60 s, label iris) and Other.mov in a bin "Footage"; returns the project, Interview and the bin.
    fn project(ids: &mut SequentialIds) -> (Project, Id, Id) {
        let media = |n: u32, name: &str, size: i64, secs: i64, label: Option<&str>| {
            let mut m = json!({"id": id(n), "name": name, "path": format!("/v/{name}"), "fingerprint": {"size": size},
                "duration": time(secs, 1)});
            if let Some(l) = label {
                m["label"] = json!(l);
            }
            m
        };
        let mut p = project_json(
            vec![media(101, "Interview.mov", 42, 60, Some("iris")), media(102, "Other.mov", 7, 10, None)],
            vec![timeline_json(10, vec![])],
        );
        let bin = p.new_bin("Footage", None, ids).unwrap_or(Id::NIL);
        assert!(p.move_items(&[BinItemRef::Media(id(101)), BinItemRef::Media(id(102))], bin, None));
        (p, id(101), bin)
    }

    #[test]
    fn makes_a_media_item_over_the_range() {
        let mut ids = SequentialIds::default();
        let (mut p, m, bin) = project(&mut ids);
        let sub_id = p.make_subclip(m, range(10, 20), None, &mut ids).unwrap_or(Id::NIL);
        let (sub, parent) = (
            p.media(sub_id).cloned().unwrap_or_else(|| panic!("sub")),
            p.media(m).cloned().unwrap_or_else(|| panic!("parent")),
        );
        assert_ne!(sub.id, m);
        assert_eq!((&sub.path, &sub.fingerprint, sub.duration), (&parent.path, &parent.fingerprint, parent.duration));
        assert_eq!(sub.label, parent.label);
        assert_eq!(sub.subclip, Some(Subclip { parent: m, range: range(10, 20) }));
        assert_eq!((sub.name.as_str(), sub.poster_time), ("Interview.mov Subclip", Some(s(10))));
        assert_eq!(
            p.source_marks.get(&sub_id),
            Some(&SourceMarks { mark_in: Some(s(10)), mark_out: Some(s(20)), ..SourceMarks::default() })
        );
        // Filed right after its parent, in the parent's bin.
        let kids: Vec<_> =
            p.root_bin.bin(bin).map(|b| b.children.iter().map(BinItem::item_ref).collect()).unwrap_or_default();
        let pos = |r: BinItemRef| kids.iter().position(|k| *k == r);
        assert_eq!(pos(BinItemRef::Media(sub_id)), pos(BinItemRef::Media(m)).map(|i| i + 1));
        // Comes after the parent in `media`, so a path lookup still finds the parent first.
        assert_eq!(p.media.iter().find(|x| x.path == parent.path).map(|x| x.id), Some(m));
    }

    #[test]
    fn names_count_up() {
        let mut ids = SequentialIds::default();
        let (mut p, m, _) = project(&mut ids);
        assert!(p.make_subclip(m, range(1, 2), None, &mut ids).is_ok());
        let second = p.make_subclip(m, range(3, 4), None, &mut ids).unwrap_or(Id::NIL);
        assert_eq!(p.media(second).map(|x| x.name.as_str()), Some("Interview.mov Subclip 2"));
        let named = p.make_subclip(m, range(3, 4), Some(" Answer 1 "), &mut ids).unwrap_or(Id::NIL);
        assert_eq!(p.media(named).map(|x| x.name.as_str()), Some("Answer 1"));
    }

    #[test]
    fn subclip_of_a_subclip_points_at_the_file() {
        let mut ids = SequentialIds::default();
        let (mut p, m, _) = project(&mut ids);
        let a = p.make_subclip(m, range(10, 30), None, &mut ids).unwrap_or(Id::NIL);
        let b = p.make_subclip(a, range(12, 15), None, &mut ids).unwrap_or(Id::NIL);
        assert_eq!(p.media(b).and_then(|x| x.subclip.as_ref()).map(|x| x.parent), Some(m));
        assert_eq!(p.media(b).map(MediaRef::is_subclip), Some(true));
        assert_eq!(p.media(m).map(MediaRef::is_subclip), Some(false));
    }

    #[test]
    fn range_is_clamped_to_the_media() {
        let mut ids = SequentialIds::default();
        let (mut p, m, _) = project(&mut ids);
        let id = p.make_subclip(m, range(0, 90), None, &mut ids).unwrap_or(Id::NIL);
        assert_eq!(p.media(id).and_then(|x| x.subclip.as_ref()).map(|x| x.range), Some(range(0, 60)));
        let negative = TimeRange::from_end(s(-5), s(90));
        let id = p.make_subclip(m, negative, None, &mut ids).unwrap_or(Id::NIL);
        assert_eq!(p.media(id).and_then(|x| x.subclip.as_ref()).map(|x| x.range), Some(range(0, 60)));
    }

    #[test]
    fn refuses_unknown_media_and_empty_ranges() {
        let mut ids = SequentialIds::default();
        let (mut p, m, _) = project(&mut ids);
        let before = p.clone();
        assert_eq!(p.make_subclip(id(77), range(0, 1), None, &mut ids), Err(EditError::ClipNotFound));
        assert_eq!(p.make_subclip(m, range(70, 80), None, &mut ids), Err(EditError::EmptyClip));
        assert_eq!(p.make_subclip(m, range(5, 5), None, &mut ids), Err(EditError::EmptyClip));
        assert_eq!(p, before);
    }
}
