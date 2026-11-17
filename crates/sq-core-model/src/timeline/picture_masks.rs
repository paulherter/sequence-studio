// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PictureMask.swift (remapPictureMasks), TrackMaskEffect.swift (the track lookup parts)

use crate::{Clip, ClipEffect, MaskSource, Timeline, TrackKind};
use sq_core_time::Id;
use std::collections::{BTreeMap, BTreeSet};

impl ClipEffect {
    /// This is a Track Mask effect.
    pub fn is_track_mask(&self) -> bool {
        self.kind == Self::TRACK_MASK_KIND
    }
}

impl Clip {
    /// Every Track Mask effect's track runs through `f` (a `None` result clears it).
    fn mapping_track_masks(&self, f: &dyn Fn(Id) -> Option<Id>) -> Clip {
        let mut c = self.clone();
        for e in c.effects.iter_mut().filter(|e| e.is_track_mask()) {
            if let Some(t) = e.mask_track {
                e.mask_track = f(t);
            }
        }
        c
    }

    /// Some Picture mask or Track Mask effect of this clip names a track.
    fn links_a_track(&self) -> bool {
        let masks = self.mask_store.iter().flatten();
        masks.into_iter().any(|m| m.source() == MaskSource::Picture && m.picture_track.is_some())
            || self.effects.iter().any(|e| e.is_track_mask() && e.mask_track.is_some())
    }
}

impl Timeline {
    /// After tracks were copied with new ids (`map`: old to new): every Picture mask follows the map; a link to a track that
    /// is neither in the map nor a video track of this timeline (not copied along) is cleared.
    pub fn remap_picture_masks(&mut self, map: &BTreeMap<Id, Id>) {
        let video: BTreeSet<Id> = self.tracks.iter().filter(|t| t.kind == TrackKind::Video).map(|t| t.id).collect();
        let remapped = |id: Id| map.get(&id).copied().or_else(|| video.contains(&id).then_some(id));
        for t in self.tracks.iter_mut().filter(|t| t.clips().iter().any(Clip::links_a_track)) {
            t.map_clips_keeping_timing(|c| {
                if !c.links_a_track() {
                    return c.clone();
                }
                let mut n = c.mapping_track_masks(&remapped);
                for m in n.mask_store.iter_mut().flatten().filter(|m| m.source() == MaskSource::Picture) {
                    m.picture_track = m.picture_track.and_then(remapped);
                }
                n
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ClipMask, MaskPath, MaskShapeKind, SequenceFormat, Track};
    use sq_core_time::{Time, TimeRange};

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn clip_with_links(picture: u128, effect: u128) -> Clip {
        let mut c =
            Clip::new(id(1), "c", id(2), TrackKind::Video, TimeRange::new(Time::ZERO, Time::seconds(1)), Time::ZERO);
        let mut m = ClipMask::new(id(10), "m", MaskShapeKind::Bezier, MaskPath { vertices: vec![] });
        m.set_source(MaskSource::Picture);
        m.picture_track = Some(id(picture));
        c.mask_store = Some(vec![m]);
        let mut e = ClipEffect::new(id(11), ClipEffect::TRACK_MASK_KIND);
        e.mask_track = Some(id(effect));
        c.effects = vec![e];
        c
    }

    fn timeline(clip: Clip, video_tracks: &[u128]) -> Timeline {
        let mut tracks = vec![];
        for (i, n) in video_tracks.iter().enumerate() {
            let mut t = Track::new(id(*n), TrackKind::Video);
            if i == 0 {
                t.set_clips(vec![clip.clone()]);
            }
            tracks.push(t);
        }
        Timeline::new(id(500), "t", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    fn links(t: &Timeline) -> (Option<Id>, Option<Id>) {
        let c = &t.tracks[0].clips()[0];
        (c.mask_store.iter().flatten().next().and_then(|m| m.picture_track), c.effects[0].mask_track)
    }

    #[test]
    fn links_follow_the_map_stay_on_video_tracks_of_this_timeline_and_are_cleared_otherwise() {
        let mut t = timeline(clip_with_links(20, 30), &[40, 20, 30]);
        t.remap_picture_masks(&BTreeMap::from([(id(20), id(21))]));
        assert_eq!(links(&t), (Some(id(21)), Some(id(30))), "30 is a video track of this timeline and stays");
        let mut gone = timeline(clip_with_links(88, 99), &[40]);
        gone.remap_picture_masks(&BTreeMap::new());
        assert_eq!(links(&gone), (None, None), "tracks that were not copied along are cleared");
    }
}
