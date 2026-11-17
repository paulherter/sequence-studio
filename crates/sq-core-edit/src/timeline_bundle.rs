// Swift: Timeline+Bundle.swift
//! Bundles: Clip > Group. A bundle keeps every clip on its own track and only ties them together for editing:
//! - a click on one member selects the whole bundle (and the members' linked partners); Option-click picks one clip;
//! - moving, nudging and deleting act on the selection, so the bundle goes as one;
//! - dragging an edge also drags the same edge of every member whose edge sits at the same time; an edge no other
//!   member shares trims alone (`bundle_edge_peers`);
//! - a split keeps both halves in the bundle, copies (paste, duplicate, Option-drag) never join the original bundle;
//! - bundles are flat: bundling members of other bundles merges them into one.
//!
//! Links stay untouched: a bundle is a second tag next to `Clip::link`.

use crate::timeline_solo::SoloExt;
use sq_core_model::{ClipEdge, EditError, Timeline};
use sq_core_time::{Id, IdSource, Time};
use std::collections::{BTreeMap, BTreeSet};

/// `extension Timeline` of Timeline+Bundle.swift.
pub trait TimelineBundleExt {
    /// True when any clip carries a bundle.
    fn contains_bundles(&self) -> bool;
    /// `ids` plus every member of their bundles and the linked partners of those members (the selection a click on a
    /// bundled clip makes when Linked Selection is on).
    fn expanding_bundles(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id>;
    /// Bundles the clips (and their linked partners) into one new bundle and returns its id. Members of other bundles
    /// bring their whole bundle along. Needs at least two clips that are not one linked group: `ClipNotFound` otherwise.
    /// A clip on a locked track refuses with `TrackLocked`.
    fn bundle(&mut self, ids: &BTreeSet<Id>, new_id: &mut dyn IdSource) -> Result<Id, EditError>;
    /// Breaks up every bundle a clip in `ids` belongs to. Returns false (and changes nothing) when none is bundled.
    /// A clip on a locked track refuses with `TrackLocked`.
    fn unbundle(&mut self, ids: &BTreeSet<Id>) -> Result<bool, EditError>;
    /// Clears `bundle` on clips whose bundle has fewer than two members left (the rest was deleted).
    fn drop_orphan_bundles(&mut self);
    /// The other members of `id`'s bundle whose `edge` sits at the same time as `id`'s (track order). Dragging that edge
    /// trims them along; empty when the clip is not bundled or no member shares the edge.
    fn bundle_edge_peers(&self, id: Id, edge: ClipEdge) -> Vec<Id>;
}

/// Sets the bundle of every clip whose current bundle satisfies `pick` to `to`.
fn retag(
    tl: &mut Timeline,
    pick: impl Fn(&sq_core_model::Clip) -> bool,
    to: impl Fn(&sq_core_model::Clip) -> Option<Id>,
) {
    for t in &mut tl.tracks {
        for c in t.clips().to_vec().into_iter().filter(|c| pick(c)) {
            let mut n = c.clone();
            n.bundle = to(&c);
            t.replace(n);
        }
    }
}

impl TimelineBundleExt for Timeline {
    fn contains_bundles(&self) -> bool {
        self.tracks.iter().any(|t| t.clips().iter().any(|c| c.bundle.is_some()))
    }

    fn expanding_bundles(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id> {
        let clips = || self.tracks.iter().flat_map(|t| t.clips());
        let bundles: BTreeSet<Id> = clips().filter(|c| ids.contains(&c.id)).filter_map(|c| c.bundle).collect();
        if bundles.is_empty() {
            return ids.clone();
        }
        let in_bundle = |c: &sq_core_model::Clip| c.bundle.is_some_and(|b| bundles.contains(&b));
        let links: BTreeSet<Id> = clips().filter(|c| in_bundle(c)).filter_map(|c| c.link).collect();
        let mut out = ids.clone();
        for c in clips().filter(|c| in_bundle(c) || c.link.is_some_and(|l| links.contains(&l))) {
            out.insert(c.id);
        }
        out
    }

    fn bundle(&mut self, ids: &BTreeSet<Id>, new_id: &mut dyn IdSource) -> Result<Id, EditError> {
        let found: BTreeSet<Id> = ids.iter().copied().filter(|id| self.find(*id).is_some()).collect();
        let mut members = self.expanding_bundles(&found);
        members.extend(self.held_back_partners(&members));
        // Units: each link group counts once, each unlinked clip counts once.
        let units: BTreeSet<Id> = self
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|c| members.contains(&c.id))
            .map(|c| c.link.unwrap_or(c.id))
            .collect();
        if units.len() < 2 {
            return Err(EditError::ClipNotFound);
        }
        if self.tracks.iter().any(|t| t.is_locked && t.clips().iter().any(|c| members.contains(&c.id))) {
            return Err(EditError::TrackLocked);
        }
        let b = new_id.next_id();
        retag(self, |c| members.contains(&c.id), |_| Some(b));
        Ok(b)
    }

    fn unbundle(&mut self, ids: &BTreeSet<Id>) -> Result<bool, EditError> {
        let bundles: BTreeSet<Id> = self
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|c| ids.contains(&c.id))
            .filter_map(|c| c.bundle)
            .collect();
        if bundles.is_empty() {
            return Ok(false);
        }
        let in_bundle = |c: &sq_core_model::Clip| c.bundle.is_some_and(|b| bundles.contains(&b));
        if self.tracks.iter().any(|t| t.is_locked && t.clips().iter().any(in_bundle)) {
            return Err(EditError::TrackLocked);
        }
        retag(self, in_bundle, |_| None);
        Ok(true)
    }

    fn drop_orphan_bundles(&mut self) {
        let mut counts: BTreeMap<Id, usize> = BTreeMap::new();
        for c in self.tracks.iter().flat_map(|t| t.clips()) {
            if let Some(b) = c.bundle {
                *counts.entry(b).or_default() += 1;
            }
        }
        if !counts.values().any(|n| *n < 2) {
            return;
        }
        retag(self, |c| c.bundle.is_some_and(|b| counts.get(&b).copied().unwrap_or(0) < 2), |_| None);
    }

    fn bundle_edge_peers(&self, id: Id, edge: ClipEdge) -> Vec<Id> {
        let Some(c) = self.find(id).map(|m| m.clip) else { return Vec::new() };
        let Some(b) = c.bundle else { return Vec::new() };
        let time =
            |x: &sq_core_model::Clip| -> Time { if edge == ClipEdge::Head { x.start } else { x.timeline().end() } };
        let at = time(&c);
        self.tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|x| x.id != id && x.bundle == Some(b) && time(x) == at)
            .map(|x| x.id)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn clip(n: u128, start: i64, dur: i64, kind: TrackKind, link: Option<u128>) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(1000 + n),
            "c",
            Id::from_u128(n + 5000),
            kind,
            TimeRange::new(s(0), s(dur)),
            s(start),
        );
        c.link = link.map(Id::from_u128);
        c.media_duration = Some(s(100));
        c
    }
    fn track(n: u128, kind: TrackKind, clips: Vec<Clip>, locked: bool) -> Track {
        let mut t = Track::new(Id::from_u128(n), kind);
        t.set_clips(clips);
        t.is_locked = locked;
        t
    }
    fn video(n: u128, clips: Vec<Clip>) -> Track {
        track(n, TrackKind::Video, clips, false)
    }
    fn tl(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }
    fn set(ids: &[Id]) -> BTreeSet<Id> {
        ids.iter().copied().collect()
    }
    fn bundle_of(t: &Timeline, id: Id) -> Option<Id> {
        t.find(id).and_then(|m| m.clip.bundle)
    }
    fn vc(n: u128, start: i64, dur: i64) -> Clip {
        clip(n, start, dur, TrackKind::Video, None)
    }

    #[test]
    fn bundles_clips_on_several_tracks() {
        let (a, b) = (vc(1, 0, 10), vc(2, 2, 5));
        let mut t = tl(vec![video(10, vec![a.clone()]), video(11, vec![b.clone()])]);
        let id = t.bundle(&set(&[a.id, b.id]), &mut SequentialIds::default());
        assert!(id.is_ok());
        assert_eq!(bundle_of(&t, a.id), id.ok());
        assert_eq!(bundle_of(&t, b.id), id.ok());
        assert!(t.contains_bundles());
    }

    #[test]
    fn linked_partners_join_the_bundle() {
        let v = clip(1, 0, 10, TrackKind::Video, Some(90));
        let a = clip(2, 0, 10, TrackKind::Audio, Some(90));
        let title = vc(3, 0, 4);
        let mut t = tl(vec![
            video(10, vec![v.clone()]),
            video(11, vec![title.clone()]),
            track(12, TrackKind::Audio, vec![a.clone()], false),
        ]);
        let id = t.bundle(&set(&[v.id, title.id]), &mut SequentialIds::default()).ok();
        assert_eq!(bundle_of(&t, a.id), id);
        assert_eq!(t.find(a.id).and_then(|m| m.clip.link), a.link); // the link stays as it was
        assert_eq!(t.expanding_bundles(&set(&[title.id])), set(&[v.id, a.id, title.id]));
    }

    #[test]
    fn one_linked_pair_alone_is_not_a_bundle() {
        let v = clip(1, 0, 10, TrackKind::Video, Some(90));
        let a = clip(2, 0, 10, TrackKind::Audio, Some(90));
        let mut t = tl(vec![video(10, vec![v.clone()]), track(11, TrackKind::Audio, vec![a.clone()], false)]);
        let mut ids = SequentialIds::default();
        assert_eq!(t.bundle(&set(&[v.id]), &mut ids), Err(EditError::ClipNotFound));
        assert_eq!(t.bundle(&set(&[v.id, a.id]), &mut ids), Err(EditError::ClipNotFound));
        assert!(!t.contains_bundles());
    }

    #[test]
    fn bundling_members_of_bundles_merges_them() {
        let cs: Vec<Clip> = (0..4).map(|i| vc(1 + i, 10 * i as i64, 5)).collect();
        let mut t = tl(vec![video(10, cs.clone())]);
        let mut ids = SequentialIds::default();
        let first = t.bundle(&set(&[cs[0].id, cs[1].id]), &mut ids);
        assert!(t.bundle(&set(&[cs[2].id, cs[3].id]), &mut ids).is_ok());
        let merged = t.bundle(&set(&[cs[1].id, cs[2].id]), &mut ids);
        assert!(merged.is_ok() && merged != first);
        assert!(cs.iter().all(|c| bundle_of(&t, c.id) == merged.ok()));
    }

    #[test]
    fn locked_track_refuses() {
        let (a, b) = (vc(1, 0, 5), vc(2, 0, 5));
        let mut t = tl(vec![video(10, vec![a.clone()]), track(11, TrackKind::Video, vec![b.clone()], true)]);
        assert_eq!(t.bundle(&set(&[a.id, b.id]), &mut SequentialIds::default()), Err(EditError::TrackLocked));
        assert!(!t.contains_bundles());
    }

    #[test]
    fn unbundle_clears_every_touched_bundle() {
        let cs: Vec<Clip> = (0..4).map(|i| vc(1 + i, 10 * i as i64, 5)).collect();
        let mut t = tl(vec![video(10, cs.clone())]);
        let mut ids = SequentialIds::default();
        assert!(t.bundle(&set(&[cs[0].id, cs[1].id]), &mut ids).is_ok());
        let keep = t.bundle(&set(&[cs[2].id, cs[3].id]), &mut ids).ok();
        assert_eq!(t.unbundle(&set(&[cs[0].id])), Ok(true));
        assert!(bundle_of(&t, cs[0].id).is_none() && bundle_of(&t, cs[1].id).is_none());
        assert_eq!(bundle_of(&t, cs[2].id), keep);
        assert_eq!(t.unbundle(&set(&[cs[0].id])), Ok(false)); // nothing bundled any more: no change
    }

    #[test]
    fn orphan_bundles_are_dropped() {
        let (a, b) = (vc(1, 0, 5), vc(2, 10, 5));
        let mut t = tl(vec![video(10, vec![a.clone(), b.clone()])]);
        assert!(t.bundle(&set(&[a.id, b.id]), &mut SequentialIds::default()).is_ok());
        t.tracks[0].remove(b.id);
        t.drop_orphan_bundles();
        assert!(bundle_of(&t, a.id).is_none());
    }

    #[test]
    fn expanding_bundles_without_bundles_is_identity() {
        let a = vc(1, 0, 5);
        let t = tl(vec![video(10, vec![a.clone()])]);
        assert_eq!(t.expanding_bundles(&set(&[a.id])), set(&[a.id]));
    }

    #[test]
    fn edge_peers_share_the_edge_time() {
        let (base, top, short, late) = (vc(1, 0, 10), vc(2, 0, 10), vc(3, 2, 6), vc(4, 4, 6));
        let mut t = tl(vec![
            video(10, vec![base.clone()]),
            video(11, vec![top.clone()]),
            video(12, vec![short.clone()]),
            video(13, vec![late.clone()]),
        ]);
        assert!(t.bundle(&set(&[base.id, top.id, short.id, late.id]), &mut SequentialIds::default()).is_ok());
        assert_eq!(t.bundle_edge_peers(base.id, ClipEdge::Head), vec![top.id]);
        assert_eq!(t.bundle_edge_peers(base.id, ClipEdge::Tail), vec![top.id, late.id]);
        assert!(t.bundle_edge_peers(short.id, ClipEdge::Head).is_empty());
        let lone = vc(5, 30, 5);
        assert!(tl(vec![video(10, vec![lone.clone()])]).bundle_edge_peers(lone.id, ClipEdge::Head).is_empty());
    }

    #[test]
    fn split_keeps_both_halves_in_the_bundle() {
        let (a, b) = (vc(1, 0, 10), vc(2, 0, 10));
        let mut t = tl(vec![video(10, vec![a.clone()]), video(11, vec![b.clone()])]);
        let id = t.bundle(&set(&[a.id, b.id]), &mut SequentialIds::default()).ok();
        assert!(t.tracks[0].split(s(5), &mut SequentialIds::default()).is_ok());
        assert_eq!(t.tracks[0].clips().len(), 2);
        assert!(t.tracks[0].clips().iter().all(|c| c.bundle == id));
    }
}
