//! Port of `Timeline+TitleBlock.swift`: title blocks (saved titles) and where they land.

use crate::timeline_clipboard::TimelineClipboard;
use crate::timeline_title_tracks::TimelineTitleTracksExt as _;
use sq_core_model::{EditError, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// `extension Timeline` of `Timeline+TitleBlock.swift`.
pub trait TitleBlockExt {
    /// True when every clip of `ids` is a generator (text, shape, adjustment layer): no media, no nested sequence.
    /// A title block (Library) holds only such clips, so it can be placed in any project.
    fn is_media_free(&self, ids: &BTreeSet<Id>) -> bool;

    /// Places a copied block (a saved title: several generator clips with their element transitions) at `t` on free
    /// video tracks: the unlocked tracks above everything that plays over the block's span, new tracks on top when there
    /// are not enough. The block's lane order is kept (lowest lane = lowest new track). Nothing is overwritten. Copies get
    /// new ids. Returns the new clip ids in `block.entries` order. `EmptyClip` for an empty block, `WrongTrackKind` when it
    /// holds anything but video-track clips.
    fn place_block(&mut self, block: &TimelineClipboard, t: Time, ids: &mut dyn IdSource)
    -> Result<Vec<Id>, EditError>;
}

impl TitleBlockExt for Timeline {
    fn is_media_free(&self, ids: &BTreeSet<Id>) -> bool {
        let clips: Vec<_> = self.tracks.iter().flat_map(|t| t.clips()).filter(|c| ids.contains(&c.id)).collect();
        !clips.is_empty()
            && clips.len() == ids.len()
            && clips.iter().all(|c| c.generator.is_some() && c.sequence.is_none() && c.kind == TrackKind::Video)
    }

    fn place_block(
        &mut self,
        block: &TimelineClipboard,
        t: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        if block.is_empty() {
            return Err(EditError::EmptyClip);
        }
        if !block.entries.iter().all(|e| e.clip.kind == TrackKind::Video) {
            return Err(EditError::WrongTrackKind);
        }
        let fd = self.frame_duration();
        let t = t.ceiled(fd).max(Time::ZERO);
        let span = block.duration().max(fd);
        let lanes: Vec<usize> = block.entries.iter().map(|e| e.lane).collect::<BTreeSet<_>>().into_iter().collect();
        let mut work = self.clone();
        let targets = work.stacked_title_tracks(lanes.len(), TimeRange::new(t, span), ids);
        let known: BTreeSet<Id> = work.variants.iter().map(|v| v.id).collect();
        let mut new_id: BTreeMap<Id, Id> = BTreeMap::new();
        let mut made: Vec<Id> = Vec::new();
        for e in &block.entries {
            let target = lanes.iter().position(|l| *l == e.lane).and_then(|rank| targets.get(rank)).copied();
            let ti =
                target.and_then(|id| work.tracks.iter().position(|tr| tr.id == id)).ok_or(EditError::ClipNotFound)?;
            let mut c = e.clip.clone();
            c.id = ids.next_id();
            c.link = None;
            c.start = t + e.offset;
            if let Some(store) = &mut c.variant_store {
                store.items.retain(|k, _| known.contains(k));
                if store.items.is_empty() {
                    c.variant_store = None;
                }
            }
            if c.generator.is_some() {
                c.media = c.id;
            }
            new_id.insert(e.clip.id, c.id);
            made.push(c.id);
            work.tracks[ti].overwrite_relinking(c, &mut BTreeMap::new(), ids)?;
        }
        work.remap_attachments(&new_id, Some(&made.iter().copied().collect()), false);
        for old in &block.transitions {
            let mut tr = old.clone();
            tr.id = ids.next_id();
            tr.outgoing = old.outgoing.and_then(|c| new_id.get(&c).copied());
            tr.incoming = old.incoming.and_then(|c| new_id.get(&c).copied());
            if old.outgoing.is_some() != tr.outgoing.is_some() || old.incoming.is_some() != tr.incoming.is_some() {
                continue;
            }
            let anchor = tr.outgoing.or(tr.incoming);
            let Some(owner) = work.tracks.iter().position(|t| anchor.is_some_and(|a| t.clip(a).is_some())) else {
                continue;
            };
            work.tracks[owner].transitions.push(tr);
        }
        work.prune_transitions();
        *self = work;
        Ok(made)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, GeneratorRef, SequenceFormat, Track};
    use sq_core_time::{IdSource, SequentialIds, Time, TimeRange};

    #[test]
    fn is_media_free_only_for_generators() {
        let mut ids = SequentialIds::default();
        let d = TimeRange::new(Time::ZERO, Time::new(3, 1));
        let gid = ids.next_id();
        let mut text = Clip::new(gid, "t", gid, TrackKind::Video, d, Time::ZERO);
        text.generator = Some(GeneratorRef { kind: "text".into(), payload: vec![1], payload_version: 1 });
        let mid = ids.next_id();
        let mut media = Clip::new(ids.next_id(), "m", mid, TrackKind::Video, d, Time::new(5, 1));
        media.media = mid;
        let mut track = Track::new(ids.next_id(), TrackKind::Video);
        track.set_clips(vec![text.clone(), media.clone()]);
        let tl = Timeline::new(ids.next_id(), "t", SequenceFormat::new(Time::new(1, 30)), vec![track]);
        assert!(tl.is_media_free(&[text.id].into()));
        assert!(!tl.is_media_free(&[text.id, media.id].into()));
        assert!(!tl.is_media_free(&BTreeSet::new()));
        assert!(!tl.is_media_free(&[ids.next_id()].into()));
    }

    #[test]
    fn place_block_refuses_empty_and_non_video_blocks() {
        use crate::timeline_clipboard::ClipboardEntry;
        use crate::timeline_edits::fixtures as fx;
        let mut t = fx::timeline(vec![fx::track(TrackKind::Video, vec![])]);
        let mut ids = sq_core_time::SequentialIds::default();
        let empty = TimelineClipboard { entries: vec![], transitions: vec![], picture_track_lanes: None };
        assert_eq!(t.place_block(&empty, Time::ZERO, &mut ids), Err(EditError::EmptyClip));
        let audio = TimelineClipboard {
            entries: vec![ClipboardEntry { clip: fx::a(0, 1), offset: Time::ZERO, lane: 0 }],
            transitions: vec![],
            picture_track_lanes: None,
        };
        assert_eq!(t.place_block(&audio, Time::ZERO, &mut ids), Err(EditError::WrongTrackKind));
    }

    #[test]
    fn place_block_goes_above_the_talking_head_with_offsets_and_new_ids() {
        use crate::timeline_clipboard::ClipboardEntry;
        use crate::timeline_edits::fixtures as fx;
        let text = |n: u128, offset: i64| {
            let mut c = Clip::new(Id::from_u128(n), "t", Id::from_u128(n), TrackKind::Video, fx::r(0, 3), fx::s(0));
            c.generator = Some(GeneratorRef { kind: "text".into(), payload: vec![1], payload_version: 1 });
            ClipboardEntry { clip: c, offset: fx::s(offset), lane: (n % 10) as usize }
        };
        let cb = TimelineClipboard {
            entries: vec![text(9001, 0), text(9002, 1)],
            transitions: vec![],
            picture_track_lanes: None,
        };
        let mut t = fx::timeline(vec![
            fx::track(TrackKind::Video, vec![fx::v(0, 20)]),
            fx::track(TrackKind::Video, vec![]),
            fx::track(TrackKind::Video, vec![]),
        ]);
        let made = t.place_block(&cb, fx::s(5), &mut SequentialIds::default()).unwrap();
        assert_eq!(made.len(), 2);
        let first = t.tracks[1].clips().first().cloned().unwrap();
        let second = t.tracks[2].clips().first().cloned().unwrap();
        assert_eq!((first.id, second.id), (made[0], made[1]));
        assert_eq!((first.start, second.start), (fx::s(5), fx::s(6)));
        assert_eq!(first.media, first.id);
        assert_eq!(t.tracks[0].clips().len(), 1);
        assert!(!cb.entries.iter().any(|e| e.clip.id == first.id));
    }
}
