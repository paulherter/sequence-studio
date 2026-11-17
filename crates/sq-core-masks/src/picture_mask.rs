// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: PictureMask.swift (Delete Track, Remove Empty Tracks, the clipboard lanes and the LayerRequest evaluation
// helpers wait on the edit and effects crates, see NOTES.md)
//! Picture mask: another video track's picture (same timeline, same sequence time) as a mask source
//! (`MaskSource::Picture`). Linked by track id. Rules and the editing helpers (paste remap) live here.

use crate::magic_matte_needs::AngleView;
use sq_core_model::{Clip, MaskSource, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time};
use std::collections::{BTreeMap, BTreeSet};

/// Kind of the Track Mask effect, which stands for a Picture mask (the effects crate owns the catalog constant).
// shortcut: copied string, use the effects crate's constant when that crate exists.
const TRACK_MASK_KIND: &str = "trackMask";

/// Nesting deeper than this is not followed (guards against a cycle).
const MAX_DEPTH: usize = 8;

fn is_track_mask(e: &sq_core_model::ClipEffect) -> bool {
    e.kind == TRACK_MASK_KIND
}

/// Logic Swift keeps on `Timeline` in `PictureMask.swift`.
pub trait PictureMaskTimelineExt {
    /// Tracks a Picture mask of a clip on `track` may read: the other video tracks of this timeline, bottom first.
    fn picture_mask_tracks(&self, track: Id) -> Vec<&Track>;
    /// The same tracks for a menu: those above `track` nearest first, then those below nearest first.
    fn picture_mask_tracks_nearest_first(&self, track: Id) -> Vec<&Track>;
    /// The track a new Picture mask reads: the nearest video track above with a clip at `t`, else the nearest above,
    /// else the nearest below, else `None`.
    fn default_picture_mask_track(&self, track: Id, t: Time) -> Option<Id>;
    /// Tracks the enabled Picture masks of the clips `ids` read (the timeline marks them while those clips are
    /// selected).
    fn picture_matte_tracks_of_clips(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id>;
    /// Enabled Picture masks of enabled clips on visible video tracks that read no track ("No track": they cover
    /// nothing), nested sequences (`sequences`) included. For the export warning.
    fn unlinked_picture_mask_count(&self, sequences: &BTreeMap<Id, Timeline>, angle_view: AngleView) -> usize;
    /// `id` is a video track of this timeline other than `track`.
    fn accepts_picture_track(&self, id: Id, track: Id) -> bool;
    /// Clears `picture_track` on every mask that reads `id` (the masks stay, covering nothing).
    fn clear_picture_masks_reading_track(&mut self, id: Id);
    /// After tracks were copied with new ids (`map`: old -> new): every Picture mask follows the map; a link to a track
    /// that is neither in the map nor a video track of this timeline (not copied along) is cleared.
    fn remap_picture_masks(&mut self, map: &BTreeMap<Id, Id>);
    /// `c` (a clip of this timeline) with its Picture masks' tracks remapped for its place here
    /// (`PictureMaskClipExt::remapping_picture_tracks`).
    fn remapping_picture_tracks(
        &self,
        c: &Clip,
        source_lane: Option<usize>,
        picture_lanes: &BTreeMap<Id, usize>,
    ) -> Clip;
    /// Video lane (index among the video tracks) of every track the Picture masks of `clips` read; `None` when none
    /// does. Stored with a copy so a paste elsewhere can keep the matte at the same lane offset. `copied`: only these
    /// tracks' lanes are recorded; `None` = every video track.
    #[doc(hidden)]
    fn picture_track_lanes(&self, clips: &[Clip], copied: Option<&BTreeSet<Id>>) -> Option<BTreeMap<String, usize>>;
}

fn unlinked_count(tl: &Timeline, sequences: &BTreeMap<Id, Timeline>, depth: usize, angle_view: AngleView) -> usize {
    let mut n = 0;
    for tr in tl.tracks.iter().filter(|t| t.kind == TrackKind::Video && t.is_visible) {
        for c in tr.clips().iter().filter(|c| c.is_enabled) {
            n += c
                .mask_store
                .iter()
                .flatten()
                .filter(|m| m.enabled && m.source() == MaskSource::Picture && m.picture_track.is_none())
                .count();
            if let Some(id) = c.sequence
                && depth < MAX_DEPTH
                && let Some(inner) = sequences.get(&id).map(|s| angle_view(c, s))
            {
                n += unlinked_count(&inner, sequences, depth + 1, angle_view);
            }
        }
    }
    n
}

/// Whether any mask or Track Mask effect of `c` is linked to a track (the clip needs a remap).
fn linked(c: &Clip) -> bool {
    c.mask_store.iter().flatten().any(|m| m.source() == MaskSource::Picture && m.picture_track.is_some())
        || c.effects.iter().any(|e| is_track_mask(e) && e.mask_track.is_some())
}

/// `f` over every Track Mask effect's track (a `None` result clears it).
fn mapping_track_masks(c: &Clip, f: &dyn Fn(Id) -> Option<Id>) -> Clip {
    if !c.effects.iter().any(|e| is_track_mask(e) && e.mask_track.is_some()) {
        return c.clone();
    }
    let mut n = c.clone();
    for e in n.effects.iter_mut().filter(|e| is_track_mask(e)) {
        if let Some(t) = e.mask_track {
            e.mask_track = f(t);
        }
    }
    n
}

/// Any mask of `c` is a Picture mask reading `track`.
fn reads_picture(c: &Clip, track: Id) -> bool {
    c.mask_store.iter().flatten().any(|m| m.source() == MaskSource::Picture && m.picture_track == Some(track))
        || c.effects.iter().any(|e| is_track_mask(e) && e.mask_track == Some(track))
}

impl PictureMaskTimelineExt for Timeline {
    fn picture_mask_tracks(&self, track: Id) -> Vec<&Track> {
        self.tracks.iter().filter(|t| t.kind == TrackKind::Video && t.id != track).collect()
    }

    fn picture_mask_tracks_nearest_first(&self, track: Id) -> Vec<&Track> {
        let Some(i) = self.tracks.iter().position(|t| t.id == track) else {
            return self.picture_mask_tracks(track);
        };
        let above = self.tracks[i + 1..].iter().filter(|t| t.kind == TrackKind::Video);
        let below = self.tracks[..i].iter().filter(|t| t.kind == TrackKind::Video).rev();
        above.chain(below).collect()
    }

    fn default_picture_mask_track(&self, track: Id, t: Time) -> Option<Id> {
        let list = self.picture_mask_tracks_nearest_first(track);
        let Some(i) = self.tracks.iter().position(|x| x.id == track) else {
            return list.first().map(|x| x.id);
        };
        let above: BTreeSet<Id> = self.tracks[i + 1..].iter().map(|x| x.id).collect();
        let up: Vec<&&Track> = list.iter().filter(|x| above.contains(&x.id)).collect();
        up.iter()
            .find(|x| x.clips().iter().any(|c| c.timeline().contains(t)))
            .map(|x| x.id)
            .or_else(|| list.first().map(|x| x.id))
    }

    fn picture_matte_tracks_of_clips(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id> {
        let mut out = BTreeSet::new();
        if ids.is_empty() {
            return out;
        }
        for tr in &self.tracks {
            for c in tr.clips().iter().filter(|c| ids.contains(&c.id)) {
                for m in c.mask_store.iter().flatten().filter(|m| m.enabled && m.source() == MaskSource::Picture) {
                    out.extend(m.picture_track);
                }
                for e in c.effects.iter().filter(|e| e.enabled && is_track_mask(e)) {
                    out.extend(e.mask_track);
                }
            }
        }
        out
    }

    fn unlinked_picture_mask_count(&self, sequences: &BTreeMap<Id, Timeline>, angle_view: AngleView) -> usize {
        unlinked_count(self, sequences, 0, angle_view)
    }

    fn accepts_picture_track(&self, id: Id, track: Id) -> bool {
        id != track && self.tracks.iter().any(|t| t.id == id && t.kind == TrackKind::Video)
    }

    fn clear_picture_masks_reading_track(&mut self, id: Id) {
        for track in &mut self.tracks {
            if !track.clips().iter().any(|c| reads_picture(c, id)) {
                continue;
            }
            track.map_clips_keeping_timing(|c| {
                if !reads_picture(c, id) {
                    return c.clone();
                }
                let mut n = mapping_track_masks(c, &|t| if t == id { None } else { Some(t) });
                n.mask_store = c.mask_store.as_ref().map(|list| {
                    list.iter()
                        .map(|m| {
                            let mut m = m.clone();
                            if m.picture_track == Some(id) {
                                m.picture_track = None;
                            }
                            m
                        })
                        .collect()
                });
                n
            });
        }
    }

    fn remap_picture_masks(&mut self, map: &BTreeMap<Id, Id>) {
        let video: BTreeSet<Id> = self.tracks.iter().filter(|t| t.kind == TrackKind::Video).map(|t| t.id).collect();
        let remapped = |id: Option<Id>| -> Option<Id> {
            let id = id?;
            if let Some(n) = map.get(&id) {
                return Some(*n);
            }
            video.contains(&id).then_some(id)
        };
        for track in &mut self.tracks {
            if !track.clips().iter().any(linked) {
                continue;
            }
            track.map_clips_keeping_timing(|c| {
                if !linked(c) {
                    return c.clone();
                }
                let mut n = mapping_track_masks(c, &|t| remapped(Some(t)));
                n.mask_store = c.mask_store.as_ref().map(|list| {
                    list.iter()
                        .map(|m| {
                            if m.source() != MaskSource::Picture {
                                return m.clone();
                            }
                            let mut m = m.clone();
                            m.picture_track = remapped(m.picture_track);
                            m
                        })
                        .collect()
                });
                n
            });
        }
    }

    fn remapping_picture_tracks(
        &self,
        c: &Clip,
        source_lane: Option<usize>,
        picture_lanes: &BTreeMap<Id, usize>,
    ) -> Clip {
        let has_picture = c.mask_store.iter().flatten().any(|m| m.source() == MaskSource::Picture)
            || c.effects.iter().any(is_track_mask);
        if c.kind != TrackKind::Video || !has_picture {
            return c.clone();
        }
        let video: Vec<&Track> = self.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
        let Some(lane) = video.iter().position(|t| t.clip(c.id).is_some()) else { return c.clone() };
        let ids: Vec<Id> = video.iter().map(|t| t.id).collect();
        c.remapping_picture_tracks(source_lane, picture_lanes, lane, &ids)
    }

    fn picture_track_lanes(&self, clips: &[Clip], copied: Option<&BTreeSet<Id>>) -> Option<BTreeMap<String, usize>> {
        let video: Vec<Id> = self.tracks.iter().filter(|t| t.kind == TrackKind::Video).map(|t| t.id).collect();
        let mut out = BTreeMap::new();
        for c in clips {
            for m in c.mask_store.iter().flatten().filter(|m| m.source() == MaskSource::Picture) {
                if let Some(id) = m.picture_track
                    && copied.is_none_or(|set| set.contains(&id))
                    && let Some(lane) = video.iter().position(|v| *v == id)
                {
                    out.insert(id.to_string(), lane);
                }
            }
        }
        if out.is_empty() { None } else { Some(out) }
    }
}

/// Logic Swift keeps on `Clip` in `PictureMask.swift`.
pub trait PictureMaskClipExt {
    /// Where a pasted Picture mask's track lands: kept when that track is a video track of the target
    /// (`target_video_tracks`, bottom first) and not the clip's own (`target_lane`); else the same lane offset from the
    /// clip as in the source (`source_lane`, `source_lanes`); else `None`.
    fn remap_picture_track(
        id: Option<Id>,
        source_lane: Option<usize>,
        source_lanes: &BTreeMap<Id, usize>,
        target_lane: usize,
        target_video_tracks: &[Id],
    ) -> Option<Id>;
    /// This clip with every Picture mask's track remapped (`remap_picture_track`).
    fn remapping_picture_tracks(
        &self,
        source_lane: Option<usize>,
        source_lanes: &BTreeMap<Id, usize>,
        target_lane: usize,
        target_video_tracks: &[Id],
    ) -> Clip;
}

impl PictureMaskClipExt for Clip {
    fn remap_picture_track(
        id: Option<Id>,
        source_lane: Option<usize>,
        source_lanes: &BTreeMap<Id, usize>,
        target_lane: usize,
        target_video_tracks: &[Id],
    ) -> Option<Id> {
        let id = id?;
        let own = target_video_tracks.get(target_lane).copied();
        if Some(id) != own && target_video_tracks.contains(&id) {
            return Some(id);
        }
        let (source_lane, matte_lane) = (source_lane?, *source_lanes.get(&id)?);
        // The lane offset may be negative: work in i64.
        let lane = target_lane as i64 + (matte_lane as i64 - source_lane as i64);
        if lane == target_lane as i64 || lane < 0 {
            return None;
        }
        target_video_tracks.get(lane as usize).copied()
    }

    fn remapping_picture_tracks(
        &self,
        source_lane: Option<usize>,
        source_lanes: &BTreeMap<Id, usize>,
        target_lane: usize,
        target_video_tracks: &[Id],
    ) -> Clip {
        if !self.mask_store.iter().flatten().any(|m| m.source() == MaskSource::Picture && m.picture_track.is_some()) {
            return self.clone();
        }
        let mut c = self.clone();
        c.mask_store = self.mask_store.as_ref().map(|list| {
            list.iter()
                .map(|m| {
                    if m.source() != MaskSource::Picture {
                        return m.clone();
                    }
                    let mut m = m.clone();
                    m.picture_track = Self::remap_picture_track(
                        m.picture_track,
                        source_lane,
                        source_lanes,
                        target_lane,
                        target_video_tracks,
                    );
                    m
                })
                .collect()
        });
        c
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::masks::ClipMasksExt;
    use sq_core_model::{ClipMask, SequenceFormat};
    use sq_core_time::IdSource;
    use sq_core_time::{SequentialIds, TimeRange};

    fn fmt() -> SequenceFormat {
        SequenceFormat::new(Time::new(1, 30))
    }

    fn clip(n: u128, start: i64, seconds: i64) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(0x500 + n),
            "c",
            Id::from_u128(0x600 + n),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(seconds, 1)),
            Time::new(start, 1),
        );
        c.media_duration = Some(Time::new(100, 1));
        c
    }

    fn track(n: u128, clips: Vec<Clip>, kind: TrackKind) -> Track {
        let mut ids = SequentialIds::default();
        let mut t = Track::new(Id::from_u128(0x700 + n), kind);
        for c in clips {
            assert!(t.overwrite(c, &mut ids).is_ok());
        }
        t
    }

    fn plain_view(_: &Clip, inner: &Timeline) -> Timeline {
        inner.clone()
    }

    /// V1 V2 V3 V4 (bottom first) plus an audio track; the consumer is on V2.
    fn rig(v3: Vec<Clip>, v4: Vec<Clip>) -> (Timeline, Vec<Id>) {
        let ts = vec![
            track(1, vec![clip(1, 0, 5)], TrackKind::Video),
            track(2, vec![clip(2, 0, 5)], TrackKind::Video),
            track(3, v3, TrackKind::Video),
            track(4, v4, TrackKind::Video),
            track(5, vec![], TrackKind::Audio),
        ];
        let ids = ts.iter().map(|t| t.id).collect();
        (Timeline::new(Id::from_u128(1), "S", fmt(), ts), ids)
    }

    fn ids_of(list: Vec<&Track>) -> Vec<Id> {
        list.iter().map(|t| t.id).collect()
    }

    #[test]
    fn nearest_first_lists_above_then_below_and_skips_audio_and_own() {
        let (t, ids) = rig(vec![], vec![]);
        assert_eq!(ids_of(t.picture_mask_tracks_nearest_first(ids[1])), vec![ids[2], ids[3], ids[0]]);
        assert_eq!(ids_of(t.picture_mask_tracks(ids[1])), vec![ids[0], ids[2], ids[3]]);
    }

    #[test]
    fn default_is_nearest_above_with_a_clip_at_the_playhead() {
        let (t, ids) = rig(vec![clip(3, 10, 5)], vec![clip(4, 0, 5)]);
        assert_eq!(t.default_picture_mask_track(ids[1], Time::new(2, 1)), Some(ids[3]));
        let (u, uids) = rig(vec![clip(3, 0, 5)], vec![clip(4, 0, 5)]);
        assert_eq!(u.default_picture_mask_track(uids[1], Time::new(2, 1)), Some(uids[2]));
    }

    #[test]
    fn default_falls_back_to_nearest_above_then_below_then_none() {
        let (t, ids) = rig(vec![], vec![]);
        assert_eq!(t.default_picture_mask_track(ids[1], Time::new(2, 1)), Some(ids[2]));
        assert_eq!(t.default_picture_mask_track(ids[3], Time::new(2, 1)), Some(ids[2]));
        let single = Timeline::new(Id::from_u128(2), "S", fmt(), vec![track(1, vec![clip(1, 0, 5)], TrackKind::Video)]);
        assert_eq!(single.default_picture_mask_track(single.tracks[0].id, Time::ZERO), None);
    }

    #[test]
    fn unlinked_counts_enabled_picture_masks_without_track() {
        let mut ids = SequentialIds::default();
        let mut c = clip(1, 0, 5);
        let mut off = ClipMask::make_picture(ids.next_id(), "Picture", None);
        off.enabled = false;
        c.set_masks(vec![
            ClipMask::make_picture(ids.next_id(), "Picture", None),
            ClipMask::make_picture(ids.next_id(), "Picture", Some(Id::from_u128(9))),
            off,
        ]);
        let t = Timeline::new(Id::from_u128(1), "S", fmt(), vec![track(1, vec![c], TrackKind::Video)]);
        assert_eq!(t.unlinked_picture_mask_count(&BTreeMap::new(), &plain_view), 1);
        assert_eq!(
            Timeline::new(Id::from_u128(2), "E", fmt(), vec![])
                .unlinked_picture_mask_count(&BTreeMap::new(), &plain_view),
            0
        );
    }

    #[test]
    fn matte_tracks_of_selected_clips() {
        let mut ids = SequentialIds::default();
        let matte = track(2, vec![clip(2, 0, 5)], TrackKind::Video);
        let mut c = clip(1, 0, 5);
        c.set_masks(vec![ClipMask::make_picture(ids.next_id(), "Picture", Some(matte.id))]);
        let mut other = clip(3, 0, 5);
        other.set_masks(vec![ClipMask::make_picture(ids.next_id(), "Picture", Some(Id::from_u128(9)))]);
        let cid = c.id;
        let t = Timeline::new(
            Id::from_u128(1),
            "S",
            fmt(),
            vec![track(1, vec![c], TrackKind::Video), matte.clone(), track(3, vec![other], TrackKind::Video)],
        );
        assert_eq!(t.picture_matte_tracks_of_clips(&BTreeSet::from([cid])), BTreeSet::from([matte.id]));
        assert!(t.picture_matte_tracks_of_clips(&BTreeSet::new()).is_empty());
    }

    #[test]
    fn unlinked_skips_hidden_tracks_and_follows_nested_sequences() {
        let mut ids = SequentialIds::default();
        let mut c = clip(1, 0, 5);
        c.set_masks(vec![ClipMask::make_picture(ids.next_id(), "Picture", None)]);
        let mut hidden = track(1, vec![c], TrackKind::Video);
        hidden.is_visible = false;
        let mut inner = clip(2, 0, 5);
        inner.set_masks(vec![ClipMask::make_picture(ids.next_id(), "Picture", None)]);
        let inner_tl = Timeline::new(Id::from_u128(7), "In", fmt(), vec![track(2, vec![inner], TrackKind::Video)]);
        let mut nest = clip(3, 0, 5);
        nest.sequence = Some(inner_tl.id);
        let outer = Timeline::new(Id::from_u128(8), "Out", fmt(), vec![hidden, track(3, vec![nest], TrackKind::Video)]);
        let mut seqs = BTreeMap::new();
        seqs.insert(inner_tl.id, inner_tl);
        assert_eq!(outer.unlinked_picture_mask_count(&seqs, &plain_view), 1);
        assert_eq!(outer.unlinked_picture_mask_count(&BTreeMap::new(), &plain_view), 0);
    }

    #[test]
    fn accepts_only_other_video_tracks() {
        let (t, ids) = rig(vec![], vec![]);
        assert!(t.accepts_picture_track(ids[2], ids[1]));
        assert!(!t.accepts_picture_track(ids[1], ids[1]));
        assert!(!t.accepts_picture_track(ids[4], ids[1]));
    }

    #[test]
    fn clearing_and_remapping_follow_the_track_ids() {
        let mut ids = SequentialIds::default();
        let matte = track(2, vec![clip(2, 0, 5)], TrackKind::Video);
        let mut c = clip(1, 0, 5);
        c.set_masks(vec![ClipMask::make_picture(ids.next_id(), "Picture", Some(matte.id))]);
        let mut t =
            Timeline::new(Id::from_u128(1), "S", fmt(), vec![track(1, vec![c], TrackKind::Video), matte.clone()]);
        let new_id = Id::from_u128(0x999);
        t.remap_picture_masks(&BTreeMap::from([(matte.id, new_id)]));
        assert_eq!(t.tracks[0].clips()[0].masks()[0].picture_track, Some(new_id));
        // A link to a track that is neither in the map nor a video track here is cleared.
        t.remap_picture_masks(&BTreeMap::new());
        assert_eq!(t.tracks[0].clips()[0].masks()[0].picture_track, None);
        let mut c2 = clip(4, 0, 5);
        c2.set_masks(vec![ClipMask::make_picture(ids.next_id(), "Picture", Some(matte.id))]);
        t.tracks[0].set_clips(vec![c2]);
        t.clear_picture_masks_reading_track(matte.id);
        assert_eq!(t.tracks[0].clips()[0].masks()[0].picture_track, None);
    }

    #[test]
    fn a_pasted_picture_mask_keeps_its_lane_offset() {
        let tracks: Vec<Id> = (1..=4).map(Id::from_u128).collect();
        let remap = Clip::remap_picture_track;
        let lanes = BTreeMap::from([(Id::from_u128(77), 2_usize)]);
        // A video track of the target that is not the clip's own is kept.
        assert_eq!(remap(Some(tracks[2]), None, &BTreeMap::new(), 0, &tracks), Some(tracks[2]));
        // The clip's own track is never its matte: same offset from the source lane instead.
        assert_eq!(remap(Some(Id::from_u128(77)), Some(1), &lanes, 1, &tracks), Some(tracks[2]));
        assert_eq!(remap(Some(Id::from_u128(77)), Some(2), &lanes, 2, &tracks), None);
        assert_eq!(remap(Some(Id::from_u128(77)), None, &lanes, 1, &tracks), None);
        assert_eq!(remap(None, Some(0), &lanes, 1, &tracks), None);
    }
}
