//! Port of `Timeline+Solo.swift`: Premiere "selected unlinked" (Option-click, or Linked Selection off): an edit acts on
//! exactly the selected clips. A linked partner follows only when it is selected too.

use crate::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_model::{Clip, EditError, Timeline};
use sq_core_time::{Id, IdSource};
use std::collections::{BTreeMap, BTreeSet};

/// `extension Timeline` of `Timeline+Solo.swift`.
pub trait SoloExt {
    /// Linked partners of `ids` that are not in `ids` themselves (they stay put when only `ids` are edited).
    fn held_back_partners(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id>;

    /// Runs `body` (any linked edit) so that only `ids` and their selected partners change: held-back partners are
    /// detached for the edit and relinked afterwards. A link left with a single clip (its partner deleted alone, a
    /// lone copy) is cleared. Without held-back partners `body` runs unchanged. An error leaves `self` unchanged.
    fn editing_only(
        &mut self,
        ids: &BTreeSet<Id>,
        id_source: &mut dyn IdSource,
        body: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<(), EditError>,
    ) -> Result<(), EditError>;
}

/// Sets every clip's link to `f(clip)` (only clips whose link changes are replaced).
fn relink(tl: &mut Timeline, mut f: impl FnMut(&Clip) -> Option<Id>) {
    for t in &mut tl.tracks {
        for mut c in t.clips().to_vec() {
            let l = f(&c);
            if l == c.link {
                continue;
            }
            c.link = l;
            t.replace(c);
        }
    }
}

impl SoloExt for Timeline {
    fn held_back_partners(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id> {
        let all = || self.tracks.iter().flat_map(|t| t.clips());
        let links: BTreeSet<Id> = all().filter(|c| ids.contains(&c.id)).filter_map(|c| c.link).collect();
        if links.is_empty() {
            return BTreeSet::new();
        }
        all().filter(|c| c.link.is_some_and(|l| links.contains(&l)) && !ids.contains(&c.id)).map(|c| c.id).collect()
    }

    fn editing_only(
        &mut self,
        ids: &BTreeSet<Id>,
        id_source: &mut dyn IdSource,
        body: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<(), EditError>,
    ) -> Result<(), EditError> {
        let held = self.held_back_partners(ids);
        if held.is_empty() {
            return body(self, id_source);
        }
        let mut work = self.clone();
        let mut saved: BTreeMap<Id, Id> = BTreeMap::new();
        relink(&mut work, |c| {
            if !held.contains(&c.id) {
                return c.link;
            }
            match c.link {
                Some(l) => saved.insert(c.id, l),
                None => saved.remove(&c.id),
            };
            None
        });
        body(&mut work, id_source)?;
        relink(&mut work, |c| saved.get(&c.id).copied().or(c.link));
        let mut counts: BTreeMap<Id, usize> = BTreeMap::new();
        for c in work.tracks.iter().flat_map(|t| t.clips()) {
            if let Some(l) = c.link {
                *counts.entry(l).or_default() += 1;
            }
        }
        relink(&mut work, |c| c.link.filter(|l| counts.get(l).copied().unwrap_or(0) >= 2));
        // Fast Cut: a clip moved alone and linked again is no attachment of its own any more
        // (`deriveFastCutAttachments`, which Swift keeps in Timeline+Clipboard.swift).
        if work.is_fast_cut() {
            work.derive_attachments();
        }
        *self = work;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track, TrackKind};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    fn clip(ids: &mut SequentialIds, kind: TrackKind, start: i64, link: Id) -> Clip {
        let media = ids.next_id();
        let mut c = Clip::new(ids.next_id(), "c", media, kind, TimeRange::new(s(5), s(10)), s(start));
        c.link = Some(link);
        c
    }

    /// A linked video and audio clip at 10 s.
    fn pair() -> (Timeline, Clip, Clip, SequentialIds) {
        let mut ids = SequentialIds::default();
        let l = ids.next_id();
        let (v, a) = (clip(&mut ids, TrackKind::Video, 10, l), clip(&mut ids, TrackKind::Audio, 10, l));
        let mut vt = Track::new(ids.next_id(), TrackKind::Video);
        vt.overwrite(v.clone(), &mut ids).unwrap();
        let mut at = Track::new(ids.next_id(), TrackKind::Audio);
        at.overwrite(a.clone(), &mut ids).unwrap();
        (Timeline::new(ids.next_id(), "t", SequenceFormat::new(Time::new(1, 30)), vec![vt, at]), v, a, ids)
    }

    /// A linked edit: moves the clip and every partner it is still linked to.
    fn move_linked(tl: &mut Timeline, id: Id, by: Time) -> Result<(), EditError> {
        let group = tl.linked_group(id)?;
        for m in group {
            let mut c = m.clip;
            c.start += by;
            tl.tracks[m.track].replace(c);
        }
        Ok(())
    }

    #[test]
    fn held_back_partners_are_the_unselected_links() {
        let (tl, v, a, _) = pair();
        assert_eq!(tl.held_back_partners(&[v.id].into()), [a.id].into());
        assert!(tl.held_back_partners(&[v.id, a.id].into()).is_empty());
    }

    #[test]
    fn edit_alone_leaves_partner_and_keeps_link() {
        let (mut tl, v, _a, mut ids) = pair();
        tl.editing_only(&[v.id].into(), &mut ids, |tl, _| move_linked(tl, v.id, s(4))).unwrap();
        assert_eq!(tl.tracks[0].clips()[0].start, s(14));
        assert_eq!(tl.tracks[1].clips()[0].start, s(10));
        assert_eq!(tl.tracks[0].clips()[0].link, v.link);
        assert_eq!(tl.tracks[1].clips()[0].link, v.link);
    }

    #[test]
    fn removing_alone_clears_the_partners_single_link() {
        let (mut tl, v, _a, mut ids) = pair();
        tl.editing_only(&[v.id].into(), &mut ids, |tl, _| {
            tl.tracks[0].remove(v.id);
            Ok(())
        })
        .unwrap();
        assert!(tl.tracks[0].clips().is_empty());
        assert_eq!(tl.tracks[1].clips().len(), 1);
        assert_eq!(tl.tracks[1].clips()[0].link, None);
    }

    #[test]
    fn full_selection_behaves_linked() {
        let (mut tl, v, a, mut ids) = pair();
        tl.editing_only(&[v.id, a.id].into(), &mut ids, |tl, _| move_linked(tl, v.id, s(4))).unwrap();
        assert_eq!(tl.tracks[1].clips()[0].start, s(14));
    }

    #[test]
    fn failure_leaves_timeline_unchanged() {
        let (mut tl, v, _a, mut ids) = pair();
        let before = tl.clone();
        let r = tl.editing_only(&[v.id].into(), &mut ids, |tl, _| {
            move_linked(tl, v.id, s(4))?;
            Err(EditError::Collision)
        });
        assert_eq!(r, Err(EditError::Collision));
        assert_eq!(tl, before);
    }
}
