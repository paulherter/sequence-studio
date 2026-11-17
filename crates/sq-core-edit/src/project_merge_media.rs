// Swift: Project+MergeMedia.swift
//! One file is one asset: items that point at the same file are folded into one and the clips follow.

use sq_core_model::{LUTRef, MediaRef, Project};
use sq_core_time::Id;
use std::collections::BTreeSet;

/// `extension LUTRef` of Project+MergeMedia.swift.
pub trait LutRefRepointExt {
    /// `Embedded(drop)` as `Embedded(keep)`; everything else unchanged.
    fn repointing(&self, drop: Id, keep: Id) -> LUTRef;
}

impl LutRefRepointExt for LUTRef {
    fn repointing(&self, drop: Id, keep: Id) -> LUTRef {
        match self {
            LUTRef::Embedded { media } if *media == drop => LUTRef::Embedded { media: keep },
            other => other.clone(),
        }
    }
}

/// `extension Project` of Project+MergeMedia.swift.
pub trait ProjectMergeMediaExt {
    /// Folds `drop` into `keep`: every clip (and stinger) of `drop` points at `keep`, the item goes, `keep` inherits the
    /// Source marks it lacks. One file is one asset. No-op (false) for unknown or equal ids.
    fn merge_media(&mut self, drop: Id, keep: Id) -> bool;
    /// After a relink: items of `moved` that now share a path with another item are folded into it (the item that was
    /// there first, or the earlier one of two relinked items).
    fn merge_shared_paths(&mut self, moved: &BTreeSet<Id>);
    /// Repair for projects that hold a linked original AND its imported copy (`folder` is the Imported folder with a
    /// trailing slash): the original is folded into the copy when `is_same_file(original, copy)` says so (the caller
    /// compares contents). Only items outside `folder` with a size match are offered. Returns how many were merged.
    fn merge_linked_originals(&mut self, folder: &str, is_same_file: impl Fn(&MediaRef, &MediaRef) -> bool) -> usize;
}

impl ProjectMergeMediaExt for Project {
    fn merge_media(&mut self, drop: Id, keep: Id) -> bool {
        if drop == keep || !self.media.iter().any(|m| m.id == drop) || !self.media.iter().any(|m| m.id == keep) {
            return false;
        }
        for tl in &mut self.timelines {
            for track in &mut tl.tracks {
                for c in track.clips().to_vec() {
                    let mut n = c.clone();
                    if n.media == drop {
                        n.media = keep;
                    }
                    // LUTs embedded in the dropped item (any clip may carry one, e.g. pasted grades) now name `keep`.
                    for e in &mut n.effects {
                        if let Some(d) = &mut e.grade {
                            d.input_lut = d.input_lut.as_ref().map(|l| l.repointing(drop, keep));
                            d.look = d.look.as_ref().map(|l| l.repointing(drop, keep));
                        }
                        if let Some(g) = &mut e.color_graph {
                            g.input_lut = g.input_lut.as_ref().map(|l| l.repointing(drop, keep));
                            g.output_lut = g.output_lut.as_ref().map(|l| l.repointing(drop, keep));
                            g.edit_steps(drop, |steps| {
                                for s in steps {
                                    s.lut = s.lut.as_ref().map(|l| l.repointing(drop, keep));
                                }
                            });
                        }
                    }
                    if n != c {
                        track.replace(n);
                    }
                }
                for t in &mut track.transitions {
                    if let Some(st) = t.stinger.as_mut().filter(|s| s.media == drop) {
                        st.media = keep;
                    }
                }
            }
        }
        if !self.source_marks.contains_key(&keep)
            && let Some(m) = self.source_marks.get(&drop).cloned()
        {
            self.source_marks.insert(keep, m);
        }
        let Some(gone) = self.media.iter().find(|m| m.id == drop).cloned() else { return false };
        for m in &mut self.media {
            if m.id == keep {
                if m.source_markers.is_none() {
                    m.source_markers = gone.source_markers.clone();
                }
                if m.label.is_none() {
                    m.label = gone.label;
                }
                if m.poster_time.is_none() {
                    m.poster_time = gone.poster_time;
                }
            }
            if let Some(s) = m.subclip.as_mut().filter(|s| s.parent == drop) {
                s.parent = keep; // subclips of the dropped item follow
            }
        }
        self.source_marks.remove(&drop);
        self.media.retain(|m| m.id != drop);
        self.normalize_bins();
        true
    }

    fn merge_shared_paths(&mut self, moved: &BTreeSet<Id>) {
        let all: Vec<Id> = self.media.iter().map(|m| m.id).collect();
        for id in all.into_iter().filter(|id| moved.contains(id)) {
            let Some(mi) = self.media.iter().position(|m| m.id == id) else { continue };
            // Subclips share their parent's path by design: only items with the same subclip value (both none) are one file.
            let target = (0..self.media.len()).find(|&j| {
                j != mi
                    && self.media[j].path == self.media[mi].path
                    && self.media[j].subclip == self.media[mi].subclip
                    && (!moved.contains(&self.media[j].id) || j < mi)
            });
            if let Some(ti) = target {
                let keep = self.media[ti].id;
                self.merge_media(id, keep);
            }
        }
    }

    fn merge_linked_originals(&mut self, folder: &str, is_same_file: impl Fn(&MediaRef, &MediaRef) -> bool) -> usize {
        let mut merged = 0;
        let copies: Vec<MediaRef> =
            self.media.iter().filter(|m| m.path.starts_with(folder) && m.subclip.is_none()).cloned().collect();
        let originals: Vec<MediaRef> = self.media.to_vec();
        for original in
            originals.iter().filter(|m| !m.path.starts_with(folder) && m.fingerprint.size > 0 && m.subclip.is_none())
        {
            let Some(copy) =
                copies.iter().find(|c| c.fingerprint.size == original.fingerprint.size && is_same_file(original, c))
            else {
                continue;
            };
            if self.merge_media(original.id, copy.id) {
                merged += 1;
            }
        }
        merged
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{
        Clip, ClipEffect, ColorGradeData, ColorGraph, MediaFingerprint, SequenceFormat, SourceMarks, Subclip, Timeline,
        Track, TrackKind,
    };
    use sq_core_time::{Time, TimeRange};

    fn media(n: u128, path: &str, size: i64) -> MediaRef {
        MediaRef::new(Id::from_u128(n), "a.mov", path, MediaFingerprint::new(size))
    }
    fn clip(n: u128, m: &MediaRef) -> Clip {
        Clip::new(
            Id::from_u128(n),
            &m.name,
            m.id,
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(2, 1)),
            Time::ZERO,
        )
    }
    fn project(media: Vec<MediaRef>, clips: Vec<Clip>) -> Project {
        let mut track = Track::new(Id::from_u128(50), TrackKind::Video);
        track.set_clips(clips);
        let tl = Timeline::new(Id::from_u128(60), "T", SequenceFormat::new(Time::new(1, 30)), vec![track]);
        let mut p = Project::new(Id::from_u128(70), "t", media, vec![tl]);
        p.normalize_bins();
        p
    }
    fn clip_media(p: &Project) -> Vec<Id> {
        p.timelines.iter().flat_map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.media))).collect()
    }

    #[test]
    fn merging_a_held_path_moves_clips_to_the_keeper() {
        let (copy, linked) = (media(1, "/P/Files/Imported/a.mov", 100), media(2, "/Users/x/a.mov", 100));
        let mut p = project(vec![copy.clone(), linked.clone()], vec![clip(11, &copy), clip(12, &linked)]);
        p.merge_shared_paths(&BTreeSet::new());
        assert_eq!(p.media.len(), 2);
        assert!(p.merge_media(linked.id, copy.id));
        assert_eq!(p.media.iter().map(|m| m.id).collect::<Vec<_>>(), vec![copy.id]);
        assert_eq!(clip_media(&p), vec![copy.id, copy.id]);
        assert!(!p.merge_media(linked.id, copy.id));
    }

    #[test]
    fn two_items_moved_to_one_path_make_one_item() {
        let (a, b) = (media(1, "/P/Imported/a.mov", 100), media(2, "/P/Imported/a.mov", 100));
        let mut p = project(vec![a.clone(), b.clone()], vec![clip(11, &a), clip(12, &b)]);
        p.merge_shared_paths(&[a.id, b.id].into_iter().collect());
        assert_eq!(p.media.len(), 1);
        assert!(clip_media(&p).iter().all(|m| *m == p.media[0].id));
    }

    #[test]
    fn merge_carries_source_marks_when_keeper_has_none() {
        let (copy, linked) = (media(1, "/P/Imported/a.mov", 100), media(2, "/o/a.mov", 100));
        let mut p = project(vec![copy.clone(), linked.clone()], vec![clip(11, &linked)]);
        p.source_marks.insert(linked.id, SourceMarks { mark_in: Some(Time::new(1, 1)), ..SourceMarks::default() });
        p.merge_media(linked.id, copy.id);
        assert!(p.source_marks.contains_key(&copy.id) && !p.source_marks.contains_key(&linked.id));
    }

    #[test]
    fn repair_folds_linked_original_into_imported_copy() {
        let copy = media(1, "/P/Files/Imported/a.mov", 100);
        let (linked, other) = (media(2, "/Users/x/a.mov", 100), media(3, "/Users/x/b.mov", 7));
        let mut p =
            project(vec![linked.clone(), copy.clone(), other.clone()], vec![clip(11, &linked), clip(12, &other)]);
        let n = p.merge_linked_originals("/P/Files/Imported/", |o, i| o.id == linked.id && i.id == copy.id);
        assert_eq!(n, 1);
        assert_eq!(p.media.iter().map(|m| m.id).collect::<BTreeSet<_>>(), [copy.id, other.id].into_iter().collect());
        assert_eq!(clip_media(&p), vec![copy.id, other.id]);
    }

    #[test]
    fn repair_leaves_different_files_alone() {
        let (copy, linked) = (media(1, "/P/Files/Imported/a.mov", 100), media(2, "/Users/x/a.mov", 100));
        let mut p = project(vec![linked.clone(), copy], vec![clip(11, &linked)]);
        assert_eq!(p.merge_linked_originals("/P/Files/Imported/", |_, _| false), 0);
        assert_eq!(p.media.len(), 2);
    }

    #[test]
    fn subclips_sharing_the_parent_path_are_not_folded() {
        let parent = media(1, "/P/Imported/a.mov", 100);
        let mut sub = media(2, "/P/Imported/a.mov", 100);
        sub.subclip = Some(Subclip { parent: parent.id, range: TimeRange::new(Time::ZERO, Time::new(1, 1)) });
        let mut p = project(vec![parent.clone(), sub.clone()], vec![clip(11, &sub)]);
        p.merge_shared_paths(&[parent.id, sub.id].into_iter().collect());
        assert_eq!(p.media.len(), 2);
        assert_eq!(clip_media(&p), vec![sub.id]);
    }

    #[test]
    fn merge_repoints_subclip_parents_and_carries_metadata() {
        let copy = media(1, "/P/Imported/a.mov", 100);
        let mut linked = media(2, "/o/a.mov", 100);
        let mut sub = media(3, "/o/a.mov", 100);
        sub.subclip = Some(Subclip { parent: linked.id, range: TimeRange::new(Time::ZERO, Time::new(1, 1)) });
        linked.poster_time = Some(Time::new(2, 1));
        let mut p = project(vec![copy.clone(), linked.clone(), sub.clone()], vec![clip(11, &linked)]);
        p.merge_media(linked.id, copy.id);
        assert_eq!(p.media.len(), 2);
        assert_eq!(
            p.media.iter().find(|m| m.id == sub.id).and_then(|m| m.subclip.as_ref()).map(|s| s.parent),
            Some(copy.id)
        );
        assert_eq!(p.media.iter().find(|m| m.id == copy.id).and_then(|m| m.poster_time), Some(Time::new(2, 1)));
    }

    #[test]
    fn repair_skips_subclips() {
        let copy = media(1, "/P/Files/Imported/a.mov", 100);
        let mut sub = media(2, "/o/a.mov", 100);
        sub.subclip = Some(Subclip { parent: Id::from_u128(99), range: TimeRange::new(Time::ZERO, Time::new(1, 1)) });
        let mut p = project(vec![sub.clone(), copy], vec![clip(11, &sub)]);
        assert_eq!(p.merge_linked_originals("/P/Files/Imported/", |_, _| true), 0);
    }

    #[test]
    fn merge_repoints_embedded_luts() {
        let (copy, linked) = (media(1, "/P/Imported/a.mov", 100), media(2, "/o/a.mov", 100));
        let mut c = clip(11, &copy);
        let mut fx = ClipEffect::new(Id::from_u128(20), "color");
        let emb = LUTRef::Embedded { media: linked.id };
        fx.grade =
            Some(ColorGradeData { input_lut: Some(emb.clone()), look: Some(emb.clone()), ..ColorGradeData::default() });
        let mut graph = ClipEffect::new(Id::from_u128(21), "colorGraph");
        let mut g = ColorGraph::new(vec![], Some(emb.clone()), None, Id::from_u128(22));
        g.edit_steps(Id::from_u128(22), |steps| steps[0].lut = Some(emb.clone()));
        graph.color_graph = Some(g);
        c.effects = vec![fx, graph];
        let mut p = project(vec![copy.clone(), linked.clone()], vec![c]);
        p.merge_media(linked.id, copy.id);
        let e = p.timelines[0].tracks[0].clips()[0].effects.clone();
        let kept = Some(LUTRef::Embedded { media: copy.id });
        let grade = e[0].grade.clone().unwrap_or_default();
        assert!(grade.input_lut == kept && grade.look == kept);
        let graph = e[1].color_graph.clone();
        assert!(graph.as_ref().is_some_and(|g| g.input_lut == kept && g.steps()[0].lut == kept));
    }
}
