// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SubjectMaskEditing.swift (`ClipEffects.needsSubjectMatte` and `Timeline.addSubjectMask` wait on the effects and
// edit crates, see NOTES.md)
//! Subject mask wiring: Clip > Add Subject Mask and the ProjectFile v37 gate query.

use crate::masks::ClipMasksExt;
use sq_core_model::{Clip, MaskSource, Project, Timeline, TrackKind};
use sq_core_time::Id;

/// Logic Swift keeps on `Clip` in `SubjectMaskEditing.swift`.
pub trait SubjectMaskClipExt {
    /// Media video only: the person matte is computed on the decoded source frame (no generators, no nested sequences).
    fn accepts_subject_mask(&self) -> bool;
    /// True when any mask (enabled or not) takes its shape from the person matte.
    fn has_subject_mask(&self) -> bool;
}

impl SubjectMaskClipExt for Clip {
    fn accepts_subject_mask(&self) -> bool {
        self.kind == TrackKind::Video && !self.is_generator() && !self.is_nested()
    }

    fn has_subject_mask(&self) -> bool {
        self.masks().iter().any(|m| m.source() == MaskSource::Subject)
    }
}

/// Logic Swift keeps on `Timeline` in `SubjectMaskEditing.swift`.
pub trait SubjectMaskTimelineExt {
    /// The clips of `ids` that Add Subject Mask would change (unlocked track, takes one, has none yet), in `ids` order.
    fn subject_mask_targets(&self, ids: &[Id]) -> Vec<Id>;
}

impl SubjectMaskTimelineExt for Timeline {
    fn subject_mask_targets(&self, ids: &[Id]) -> Vec<Id> {
        ids.iter()
            .copied()
            .filter(|id| {
                let Some(m) = self.find(*id) else { return false };
                !self.tracks[m.track].is_locked && m.clip.accepts_subject_mask() && !m.clip.has_subject_mask()
            })
            .collect()
    }
}

/// Logic Swift keeps on `Project` in `SubjectMaskEditing.swift`.
pub trait SubjectMaskProjectExt {
    /// Any clip in any sequence holds a subject mask (ProjectFile v37 gate).
    fn contains_subject_mask(&self) -> bool;
}

impl SubjectMaskProjectExt for Project {
    fn contains_subject_mask(&self) -> bool {
        self.timelines.iter().any(|t| t.tracks.iter().any(|t| t.clips().iter().any(|c| c.has_subject_mask())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::IdSource;

    use sq_core_model::{ClipMask, SequenceFormat};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn clip(n: u128) -> Clip {
        Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(0x90),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(5, 1)),
            Time::new(n as i64 * 10, 1),
        )
    }

    #[test]
    fn targets_skip_locked_tracks_nests_and_clips_with_a_subject_mask() {
        let mut ids = SequentialIds::default();
        let (a, mut has, mut nest, locked) = (clip(1), clip(2), clip(3), clip(4));
        has.set_masks(vec![ClipMask::make_subject(ids.next_id(), "Subject")]);
        nest.sequence = Some(Id::from_u128(0x77));
        let mut t1 = sq_core_model::Track::new(Id::from_u128(0x71), TrackKind::Video);
        for c in [a.clone(), has.clone(), nest.clone()] {
            assert!(t1.overwrite(c, &mut ids).is_ok());
        }
        let mut t2 = sq_core_model::Track::new(Id::from_u128(0x72), TrackKind::Video);
        assert!(t2.overwrite(locked.clone(), &mut ids).is_ok());
        t2.is_locked = true;
        let tl = Timeline::new(Id::from_u128(1), "T", SequenceFormat::new(Time::new(1, 30)), vec![t1, t2]);
        assert_eq!(tl.subject_mask_targets(&[a.id, has.id, nest.id, locked.id, Id::from_u128(99)]), vec![a.id]);
        let p = Project::new(Id::from_u128(5), "P", vec![], vec![tl]);
        assert!(p.contains_subject_mask());
        assert!(has.has_subject_mask() && !a.has_subject_mask());
    }
}
