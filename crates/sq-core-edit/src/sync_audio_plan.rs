//! Port of `SyncAudioPlan.swift`: which selected clip is the reference of Sync Audio to Reference and which clips are
//! lined up to it.

use sq_core_model::{Clip, Timeline, TrackKind};
use sq_core_time::Id;
use std::cmp::Ordering;
use std::collections::BTreeSet;

/// The reference clip and the clips lined up to it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncAudioPlan {
    /// The clip the others are lined up to.
    pub reference: Id,
    /// The clips to move, in order.
    pub targets: Vec<Id>,
}

/// `extension Timeline` of `SyncAudioPlan.swift`.
pub trait SyncAudioPlanExt {
    /// The reference is the selected media clip that starts first on the timeline (ties: the audio clip, then the
    /// upper track); every other selected media clip is a target, in that order. A target linked to the reference or to
    /// an earlier target is left out (it moves with its partner). Generators, stills and nested sequences take no part.
    /// `None` without a reference and at least one target.
    fn sync_audio_plan(&self, selection: &BTreeSet<Id>) -> Option<SyncAudioPlan>;
}

impl SyncAudioPlanExt for Timeline {
    fn sync_audio_plan(&self, selection: &BTreeSet<Id>) -> Option<SyncAudioPlan> {
        let mut picked: Vec<(usize, &Clip)> = Vec::new();
        for (i, t) in self.tracks.iter().enumerate() {
            for c in t.clips() {
                if selection.contains(&c.id) && !c.is_generator() && !c.is_still && c.sequence.is_none() {
                    picked.push((i, c));
                }
            }
        }
        picked.sort_by(|a, b| {
            a.1.start
                .cmp(&b.1.start)
                .then_with(|| match (a.1.kind, b.1.kind) {
                    (x, y) if x == y => Ordering::Equal,
                    (TrackKind::Audio, _) => Ordering::Less,
                    _ => Ordering::Greater,
                })
                .then(a.0.cmp(&b.0))
        });
        let reference = picked.first()?.1;
        let mut seen_links: BTreeSet<Id> = reference.link.into_iter().collect();
        let mut targets = Vec::new();
        for (_, c) in picked.iter().skip(1) {
            if let Some(link) = c.link
                && !seen_links.insert(link)
            {
                continue;
            }
            targets.push(c.id);
        }
        (!targets.is_empty()).then_some(SyncAudioPlan { reference: reference.id, targets })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{SequenceFormat, Track};
    use sq_core_time::{IdSource, SequentialIds, Time, TimeRange};

    const FD: Time = Time::new(1, 30);

    fn clip(ids: &mut SequentialIds, kind: TrackKind, at: i64, link: Option<Id>) -> Clip {
        let media = ids.next_id();
        let mut c = Clip::new(ids.next_id(), "c", media, kind, TimeRange::new(Time::ZERO, FD * 100), FD * at);
        c.link = link;
        c.media_duration = Some(FD * 100);
        c
    }

    fn track(ids: &mut SequentialIds, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(ids.next_id(), kind);
        for c in clips {
            t.overwrite(c, ids).unwrap();
        }
        t
    }

    #[test]
    fn earliest_clip_is_the_reference_and_linked_partners_are_skipped() {
        let mut ids = SequentialIds::default();
        let link = ids.next_id();
        let reference = clip(&mut ids, TrackKind::Audio, 0, None);
        let a = clip(&mut ids, TrackKind::Audio, 300, Some(link));
        let v = clip(&mut ids, TrackKind::Video, 300, Some(link));
        let b = clip(&mut ids, TrackKind::Audio, 700, None);
        let (rid, aid, vid, bid) = (reference.id, a.id, v.id, b.id);
        let t1 = track(&mut ids, TrackKind::Audio, vec![reference, b]);
        let t2 = track(&mut ids, TrackKind::Audio, vec![a]);
        let t3 = track(&mut ids, TrackKind::Video, vec![v]);
        let tl = Timeline::new(ids.next_id(), "t", SequenceFormat::new(FD), vec![t3, t1, t2]);
        let plan = tl.sync_audio_plan(&[rid, aid, vid, bid].into()).unwrap();
        assert_eq!(plan.reference, rid);
        assert_eq!(plan.targets, [aid, bid]);
    }

    #[test]
    fn one_clip_has_no_plan() {
        let mut ids = SequentialIds::default();
        let reference = clip(&mut ids, TrackKind::Audio, 0, None);
        let rid = reference.id;
        let tr = track(&mut ids, TrackKind::Audio, vec![reference]);
        let tl = Timeline::new(ids.next_id(), "t", SequenceFormat::new(FD), vec![tr]);
        assert_eq!(tl.sync_audio_plan(&[rid].into()), None);
        assert_eq!(tl.sync_audio_plan(&BTreeSet::new()), None);
    }
}
