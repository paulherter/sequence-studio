// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Timeline+Clipboard.swift (clipboard, paste, gaps, link / unlink, nudge)

use serde::{Deserialize, Serialize};
use sq_core_masks::{PictureMaskClipExt as _, PictureMaskTimelineExt as _};
use sq_core_model::{
    Clip, EditError, Member, Timeline, TimelineEditMode, Track, TrackKind, Transition, clear_main_track_attachments,
};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::timeline_range_edits::TimelineRangeEditsExt as _;

const KINDS: [TrackKind; 2] = [TrackKind::Video, TrackKind::Audio];

/// One copied clip.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ClipboardEntry {
    /// The clip as copied.
    pub clip: Clip,
    /// Start relative to the earliest copied clip.
    pub offset: Time,
    /// Index among the tracks of the clip's kind (0 = V1 / A1).
    pub lane: usize,
}

/// Clips copied from a timeline (Cmd+C / Cmd+X). Positions are relative to the earliest copied clip and tracks are stored
/// as a lane (index among the tracks of the same kind, 0 = V1 / A1), so a paste can land on other tracks.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelineClipboard {
    /// The copied clips.
    pub entries: Vec<ClipboardEntry>,
    /// Transitions whose clips are all part of the copy (a cut between two copied clips, the fades of a copied clip).
    pub transitions: Vec<Transition>,
    /// Source video lane of each track a copied Picture mask reads (keyed by the track id's string), so a paste into a
    /// sequence without that track keeps the matte at the same lane offset. `None` = none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub picture_track_lanes: Option<BTreeMap<String, usize>>,
}

impl TimelineClipboard {
    /// The clipboard without Fast Cut attachments (a paste into a Normal sequence: Normal never stores them).
    pub fn stripping_attachments(&self) -> TimelineClipboard {
        let mut out = self.clone();
        for e in &mut out.entries {
            e.clip.attachment = None;
        }
        out
    }

    /// Nothing copied.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Length from the earliest start to the latest end.
    pub fn duration(&self) -> Time {
        self.entries.iter().map(|e| e.offset + e.clip.timeline().duration).max().unwrap_or(Time::ZERO)
    }

    /// Lowest lane per kind (the lane a paste target is aligned to).
    pub fn lowest_lane(&self, kind: TrackKind) -> Option<usize> {
        self.entries.iter().filter(|e| e.clip.kind == kind).map(|e| e.lane).min()
    }

    /// The source lanes of the tracks the copied Picture masks read.
    pub fn picture_lanes(&self) -> BTreeMap<Id, usize> {
        let stored = self.picture_track_lanes.iter().flatten();
        stored.filter_map(|(k, v)| Id::parse(k).map(|id| (id, *v))).collect()
    }
}

/// Clipboard, paste, gaps, link / unlink and nudge.
pub trait TimelineClipboardExt {
    /// Copy of `ids` for the clipboard; `None` when none exists.
    fn clipboard(&self, ids: &BTreeSet<Id>) -> Option<TimelineClipboard>;

    /// Lane a paste of `kind` lands on by default: the lane the clips were copied from (Cmd+V pastes onto the source
    /// tracks, whatever is targeted).
    fn paste_lane(&self, kind: TrackKind, cb: &TimelineClipboard) -> Option<usize>;

    /// "Paste to Targeted Track": per kind in the clipboard, the lowest targeted track of that kind, else the lane the
    /// clips came from. The copy keeps its lane offsets above that track.
    fn target_lanes(&self, cb: &TimelineClipboard) -> HashMap<TrackKind, usize>;

    /// Paste to Targeted Track: `paste` onto `target_lanes` (overwrite or insert).
    fn paste_to_targets(
        &mut self,
        cb: &TimelineClipboard,
        t: Time,
        insert: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;

    /// Latest timeline end of `ids` (where the playhead goes after a paste); `None` when none exists.
    fn end_of(&self, ids: &[Id]) -> Option<Time>;

    /// Pastes at `t`: overwrite (default) or insert (Cmd+Shift+V, ripples all ripple tracks). `lanes` overrides the target
    /// lane per kind (the lane the lowest copied clip of that kind lands on); `None` uses `paste_lane`. Copies get new ids;
    /// a link survives only between copies. Returns the new clip ids.
    fn paste(
        &mut self,
        cb: &TimelineClipboard,
        t: Time,
        lanes: Option<&HashMap<TrackKind, usize>>,
        insert: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;

    /// The empty stretch of `track` under `t`: from the previous clip's end (or 0) to the next clip's start. `None` when a
    /// clip is there, or when no clip follows (empty space after the last clip is not a gap).
    fn gap(&self, track: Id, t: Time) -> Option<TimeRange>;

    /// How much of the gap under `t` on `track` `close_gap` can close: the stretch before the gap's end that is empty on
    /// every unlocked sync-locked track (clips and captions alike). `None` when there is no gap.
    fn gap_closable(&self, track: Id, t: Time) -> Option<Time>;

    /// Ripple-deletes the gap under `t` on `track`. Shifts the track and every sync-locked track left, as far as nothing
    /// collides. Content on another track never goes: the gap closes only through the stretch that is empty everywhere
    /// (see `gap_closable`), so a caption or clip inside the gap keeps its place. Returns the time closed.
    fn close_gap(&mut self, track: Id, t: Time, ids: &mut dyn IdSource) -> Result<Time, EditError>;

    /// Links the clips into one group (Cmd+L). Needs two or more clips; locked tracks refuse.
    fn link(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<(), EditError>;

    /// Fast Cut: a changed link changes who is attached to whom, so the stored attachments are re-derived.
    #[doc(hidden)]
    fn derive_fast_cut_attachments(&mut self);

    /// Clears `link` on clips whose link group has fewer than two members.
    fn drop_orphan_links(&mut self);

    /// Unlinks the selected clips from their partners. A partner left alone loses its link too.
    fn unlink(&mut self, clips: &BTreeSet<Id>) -> Result<(), EditError>;

    /// Moves the clips (and their linked partners) by `delta` on their tracks. The whole group moves as one: it never
    /// collides with itself, covered neighbors are cut (overwrite). Clamped so nothing starts before 0. Returns the applied
    /// delta.
    fn nudge(&mut self, clips: &BTreeSet<Id>, delta: Time, ids: &mut dyn IdSource) -> Result<Time, EditError>;
}

fn lane_tracks(tl: &Timeline, kind: TrackKind) -> Vec<&Track> {
    tl.tracks.iter().filter(|t| t.kind == kind).collect()
}

fn signed(n: usize) -> i64 {
    i64::try_from(n).unwrap_or(i64::MAX)
}

impl TimelineClipboardExt for Timeline {
    fn clipboard(&self, ids: &BTreeSet<Id>) -> Option<TimelineClipboard> {
        let mut entries: Vec<ClipboardEntry> = Vec::new();
        for k in KINDS {
            for (lane, t) in lane_tracks(self, k).into_iter().enumerate() {
                for c in t.clips().iter().filter(|c| ids.contains(&c.id)) {
                    entries.push(ClipboardEntry { clip: c.clone(), offset: c.start, lane });
                }
            }
        }
        let first = entries.iter().map(|e| e.offset).min()?;
        for e in &mut entries {
            e.offset -= first;
        }
        let copied: BTreeSet<Id> = entries.iter().map(|e| e.clip.id).collect();
        let kept: Vec<Transition> = self
            .tracks
            .iter()
            .flat_map(|t| t.transitions.iter())
            .filter(|tr| [tr.outgoing, tr.incoming].into_iter().flatten().all(|i| copied.contains(&i)))
            .cloned()
            .collect();
        let clips: Vec<Clip> = entries.iter().map(|e| e.clip.clone()).collect();
        Some(TimelineClipboard {
            entries,
            transitions: kept,
            picture_track_lanes: self.picture_track_lanes(&clips, None),
        })
    }

    fn paste_lane(&self, kind: TrackKind, cb: &TimelineClipboard) -> Option<usize> {
        cb.lowest_lane(kind)
    }

    fn target_lanes(&self, cb: &TimelineClipboard) -> HashMap<TrackKind, usize> {
        let mut out = HashMap::new();
        for k in KINDS {
            let Some(low) = cb.lowest_lane(k) else { continue };
            out.insert(k, lane_tracks(self, k).iter().position(|t| t.is_targeted).unwrap_or(low));
        }
        out
    }

    fn paste_to_targets(
        &mut self,
        cb: &TimelineClipboard,
        t: Time,
        insert: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        let lanes = self.target_lanes(cb);
        self.paste(cb, t, Some(&lanes), insert, ids)
    }

    fn end_of(&self, ids: &[Id]) -> Option<Time> {
        self.tracks.iter().flat_map(|t| t.clips()).filter(|c| ids.contains(&c.id)).map(|c| c.timeline().end()).max()
    }

    fn paste(
        &mut self,
        cb: &TimelineClipboard,
        t: Time,
        lanes: Option<&HashMap<TrackKind, usize>>,
        insert: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        if cb.is_empty() {
            return Err(EditError::EmptyClip);
        }
        // Up to the next frame, never back: a paste right after an off-frame clip end (Duplicate) must not cut into it.
        let t = t.ceiled(self.frame_duration()).max(Time::ZERO);
        let mut shift: HashMap<TrackKind, i64> = HashMap::new();
        for k in KINDS {
            let Some(low) = cb.lowest_lane(k) else { continue };
            let Some(to) = lanes.and_then(|l| l.get(&k).copied()).or_else(|| self.paste_lane(k, cb)) else { continue };
            shift.insert(k, signed(to) - signed(low));
        }
        let shift_of = |k: TrackKind| shift.get(&k).copied().unwrap_or(0);
        let mut link_map: BTreeMap<Id, Id> = BTreeMap::new();
        let mut bundle_map: BTreeMap<Id, Id> = BTreeMap::new();
        let mut counts: BTreeMap<Id, usize> = BTreeMap::new();
        let mut bundle_counts: BTreeMap<Id, usize> = BTreeMap::new();
        for e in &cb.entries {
            if let Some(l) = e.clip.link {
                *counts.entry(l).or_default() += 1;
            }
        }
        for e in &cb.entries {
            if let Some(b) = e.clip.bundle {
                *bundle_counts.entry(b).or_default() += 1;
            }
        }
        let mut placements: Vec<(Clip, Id)> = Vec::new();
        let picture_lanes = cb.picture_lanes();
        let mut new_id: BTreeMap<Id, Id> = BTreeMap::new();
        // Lanes that do not exist are created (Premiere adds tracks), so clips never stack on one track.
        let mut work = self.clone();
        for k in KINDS {
            let top =
                cb.entries.iter().filter(|e| e.clip.kind == k).map(|e| (signed(e.lane) + shift_of(k)).max(0)).max();
            let top = top.unwrap_or(-1);
            while signed(lane_tracks(&work, k).len()) <= top {
                let at = work.tracks.iter().rposition(|t| t.kind == k).map_or(work.tracks.len(), |i| i + 1);
                work.tracks.insert(at, Track::new(ids.next_id(), k));
            }
        }
        for e in &cb.entries {
            let list = lane_tracks(&work, e.clip.kind);
            if list.is_empty() {
                return Err(EditError::WrongTrackKind);
            }
            let top = signed(list.len()) - 1;
            let lane = usize::try_from((signed(e.lane) + shift_of(e.clip.kind)).clamp(0, top)).unwrap_or(0);
            let mut c = e.clip.clone();
            let fresh = ids.next_id();
            new_id.insert(e.clip.id, fresh);
            c.id = fresh;
            c.start = e.offset; // relative; placed below
            // Overrides only make sense for this sequence's variants (pasting from another sequence drops the rest).
            if let Some(vo) = c.variant_store.as_mut() {
                let known: BTreeSet<Id> = self.variants.iter().map(|v| v.id).collect();
                vo.items.retain(|k, v| known.contains(k) && !v.is_empty());
                if vo.items.is_empty() {
                    c.variant_store = None;
                }
            }
            if let Some(l) = c.link {
                if counts.get(&l).copied().unwrap_or(0) > 1 {
                    let n = match link_map.get(&l) {
                        Some(n) => *n,
                        None => ids.next_id(),
                    };
                    link_map.insert(l, n);
                    c.link = Some(n);
                } else {
                    c.link = None;
                }
            }
            // A bundle survives only between copies, under a new id (copies never join the original bundle).
            if let Some(b) = c.bundle {
                if bundle_counts.get(&b).copied().unwrap_or(0) > 1 {
                    let n = match bundle_map.get(&b) {
                        Some(n) => *n,
                        None => ids.next_id(),
                    };
                    bundle_map.insert(b, n);
                    c.bundle = Some(n);
                } else {
                    c.bundle = None;
                }
            }
            if c.kind == TrackKind::Video {
                let video_ids: Vec<Id> = list.iter().map(|t| t.id).collect();
                c = c.remapping_picture_tracks(Some(e.lane), &picture_lanes, lane, &video_ids);
            }
            placements.push((c, list[lane].id));
        }
        // Fast Cut attachments follow their host's copy; one whose host was not copied is dropped (re-derived later).
        for p in &mut placements {
            if p.0.attachment.is_some() {
                p.0.remap_attachment(&new_id);
            }
        }
        if insert {
            let mut edited = work;
            edited.insert(&placements, t, ids)?; // `insert` keeps the relative offsets
            *self = edited;
        } else {
            let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
            for p in &placements {
                let i = work.tracks.iter().position(|x| x.id == p.1).ok_or(EditError::ClipNotFound)?;
                if work.tracks[i].is_locked {
                    return Err(EditError::TrackLocked);
                }
                let mut c = p.0.clone();
                c.start = t + p.0.start;
                work.tracks[i].overwrite_relinking(c, &mut relinks, ids)?;
            }
            clear_main_track_attachments(&mut work.tracks);
            self.tracks = work.tracks;
        }
        // The copied transitions follow their clips (new ids); anything an overwrite cut apart is pruned again.
        for old in &cb.transitions {
            let mut tr = old.clone();
            tr.id = ids.next_id();
            tr.outgoing = old.outgoing.and_then(|o| new_id.get(&o).copied());
            tr.incoming = old.incoming.and_then(|i| new_id.get(&i).copied());
            if old.outgoing.is_none() != tr.outgoing.is_none() || old.incoming.is_none() != tr.incoming.is_none() {
                continue;
            }
            let Some(key) = tr.outgoing.or(tr.incoming) else { continue };
            let Some(owner) = self.tracks.iter().position(|t| t.clip(key).is_some()) else { continue };
            self.tracks[owner].transitions.push(tr);
        }
        self.prune_transitions();
        Ok(placements.into_iter().map(|p| p.0.id).collect())
    }

    fn gap(&self, track: Id, t: Time) -> Option<TimeRange> {
        let tr = self.track(track)?;
        if tr.clips().iter().any(|c| c.timeline().contains(t)) {
            return None;
        }
        let next = tr.clips().iter().find(|c| c.start > t)?;
        let prev_end = tr.clips().iter().filter(|c| c.timeline().end() <= t).map(|c| c.timeline().end()).max();
        let r = TimeRange::from_end(prev_end.unwrap_or(Time::ZERO), next.start);
        if r.is_empty() { None } else { Some(r) }
    }

    fn gap_closable(&self, track: Id, t: Time) -> Option<Time> {
        let r = self.gap(track, t)?;
        // Clips that straddle the gap's end move with their pair (`extract`), so only clips that end inside block;
        // a caption has no pair, so one that reaches past the end blocks too (`caption_room_before`).
        let clips = self
            .tracks
            .iter()
            .filter(|k| k.id != track && k.follows_ripple())
            .flat_map(|k| k.clips().iter())
            .filter(|c| c.start < r.end() && c.timeline().end() <= r.end())
            .map(|c| c.timeline().end());
        let free_from = clips.max().map_or(r.start, |e| e.max(r.start));
        let closable = (r.end() - free_from).max(Time::ZERO);
        Some(self.caption_room_before(r.end()).map_or(closable, |room| closable.min(room)))
    }

    fn close_gap(&mut self, track: Id, t: Time, ids: &mut dyn IdSource) -> Result<Time, EditError> {
        let Some(r) = self.gap(track, t) else { return Ok(Time::ZERO) };
        if self.track(track).is_some_and(|k| k.is_locked) {
            return Err(EditError::TrackLocked);
        }
        let closable = self.gap_closable(track, t).unwrap_or(Time::ZERO).min(r.duration);
        if closable <= Time::ZERO {
            return Ok(Time::ZERO);
        }
        self.extract(TimeRange::from_end(r.end() - closable, r.end()), &[track], ids)
    }

    fn link(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let members: Vec<Member> = clips.iter().filter_map(|i| self.find(*i)).collect();
        if members.len() < 2 {
            return Err(EditError::ClipNotFound);
        }
        if members.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let l = ids.next_id();
        for m in members {
            let mut c = m.clip;
            c.link = Some(l);
            self.tracks[m.track].replace(c);
        }
        self.drop_orphan_links();
        self.derive_fast_cut_attachments();
        Ok(())
    }

    fn derive_fast_cut_attachments(&mut self) {
        if self.edit_mode() == TimelineEditMode::Magnetic && self.main_track_index().is_some() {
            self.derive_attachments();
        }
    }

    fn drop_orphan_links(&mut self) {
        let mut counts: BTreeMap<Id, usize> = BTreeMap::new();
        for t in &self.tracks {
            for l in t.clips().iter().filter_map(|c| c.link) {
                *counts.entry(l).or_default() += 1;
            }
        }
        for t in &mut self.tracks {
            let orphans: Vec<Clip> = t
                .clips()
                .iter()
                .filter(|c| c.link.is_some_and(|l| counts.get(&l).copied().unwrap_or(0) < 2))
                .cloned()
                .collect();
            for mut n in orphans {
                n.link = None;
                t.replace(n);
            }
        }
    }

    fn unlink(&mut self, clips: &BTreeSet<Id>) -> Result<(), EditError> {
        let members: Vec<Member> = clips.iter().filter_map(|i| self.find(*i)).collect();
        if members.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let affected: BTreeSet<Id> = members.iter().filter_map(|m| m.clip.link).collect();
        for m in members {
            let mut c = m.clip;
            c.link = None;
            self.tracks[m.track].replace(c);
        }
        for l in affected {
            let rest: Vec<Id> =
                self.tracks.iter().flat_map(|t| t.clips()).filter(|c| c.link == Some(l)).map(|c| c.id).collect();
            let [only] = rest.as_slice() else { continue };
            let Some(m) = self.find(*only) else { continue };
            let mut c = m.clip;
            c.link = None;
            self.tracks[m.track].replace(c);
        }
        self.derive_fast_cut_attachments();
        Ok(())
    }

    fn nudge(&mut self, clips: &BTreeSet<Id>, delta: Time, ids: &mut dyn IdSource) -> Result<Time, EditError> {
        let mut group: Vec<Member> = Vec::new();
        let mut seen: BTreeSet<Id> = BTreeSet::new();
        for id in clips {
            for m in self.linked_group(*id)? {
                if seen.insert(m.clip.id) {
                    group.push(m);
                }
            }
        }
        if group.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let mut d = delta;
        for m in &group {
            d = d.max(Time::ZERO - m.clip.start);
        }
        if d == Time::ZERO {
            return Ok(Time::ZERO);
        }
        let mut work = self.tracks.clone();
        for m in &group {
            work[m.track].remove(m.clip.id);
        }
        let mut relinks: BTreeMap<Id, Id> = BTreeMap::new();
        group.sort_by_key(|m| m.clip.start);
        for m in &group {
            let mut c = m.clip.clone();
            c.start += d;
            work[m.track].overwrite_relinking(c, &mut relinks, ids)?;
        }
        self.tracks = work;
        Ok(d)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::*;
    use sq_core_model::TrackKind::{Audio, Video};
    use sq_core_time::SequentialIds;

    #[test]
    fn copy_keeps_offsets_and_lanes_and_paste_places_fresh_copies() {
        let (x, y) = (v(2, 3), v(8, 2));
        let mut tl = timeline(vec![track(Video, vec![x.clone(), y.clone()])]);
        let cb = tl.clipboard(&BTreeSet::from([x.id, y.id]));
        let cb = cb.unwrap_or_else(|| unreachable!());
        assert_eq!((cb.entries[1].offset, cb.duration()), (s(6), s(8)));
        let mut ids = SequentialIds::default();
        let new = tl.paste(&cb, s(20), None, false, &mut ids).unwrap_or_default();
        assert_eq!(new.len(), 2);
        assert!(!new.contains(&x.id));
        assert_eq!(spans(&tl.tracks[0]), [[2, 5], [8, 10], [20, 23], [26, 28]]);
        assert_eq!(tl.end_of(&new), Some(s(28)));
    }

    #[test]
    fn a_link_survives_only_between_copies_and_missing_lanes_are_created() {
        let l = link();
        let (vc, au) = (clip(0, 4, 0, Video, Some(l), None), clip(0, 4, 0, Audio, Some(l), None));
        let mut src =
            timeline(vec![track(Video, vec![vc.clone()]), track(Audio, vec![]), track(Audio, vec![au.clone()])]);
        let both = src.clipboard(&BTreeSet::from([vc.id, au.id])).unwrap_or_else(|| unreachable!());
        assert_eq!(both.entries.iter().map(|e| e.lane).collect::<Vec<_>>(), [0, 1]);
        let mut dst = timeline(vec![track(Video, vec![]), track(Audio, vec![])]);
        let mut ids = SequentialIds::default();
        assert!(dst.paste(&both, s(1), None, false, &mut ids).is_ok());
        assert_eq!(dst.tracks.len(), 3); // the second audio lane was added
        let links: Vec<Option<Id>> = dst.tracks.iter().flat_map(|t| t.clips()).map(|c| c.link).collect();
        assert!(links[0].is_some() && links[0] == links[1] && links[0] != Some(l));
        // one clip alone drops its link
        let one = src.clipboard(&BTreeSet::from([vc.id])).unwrap_or_else(|| unreachable!());
        assert!(dst.paste(&one, s(10), None, false, &mut ids).is_ok());
        assert_eq!(dst.tracks[0].clips().last().map(|c| c.link), Some(None));
        let _ = &mut src;
    }

    #[test]
    fn insert_paste_ripples_and_an_empty_clipboard_is_refused() {
        let (x, y) = (v(0, 4), v(4, 4));
        let mut tl = timeline(vec![track(Video, vec![x.clone(), y])]);
        let cb = tl.clipboard(&BTreeSet::from([x.id])).unwrap_or_else(|| unreachable!());
        let mut ids = SequentialIds::default();
        assert!(tl.paste(&cb, s(4), None, true, &mut ids).is_ok());
        assert_eq!(spans(&tl.tracks[0]), [[0, 4], [4, 8], [8, 12]]);
        assert_eq!(tl.clipboard(&BTreeSet::new()), None);
        let empty = TimelineClipboard { entries: vec![], transitions: vec![], picture_track_lanes: None };
        assert_eq!(tl.paste(&empty, s(0), None, false, &mut ids), Err(EditError::EmptyClip));
    }

    #[test]
    fn targeted_tracks_decide_the_paste_lane() {
        let x = v(0, 2);
        let mut tl = timeline(vec![track(Video, vec![x.clone()]), track(Video, vec![])]);
        tl.tracks[1].is_targeted = true;
        let cb = tl.clipboard(&BTreeSet::from([x.id])).unwrap_or_else(|| unreachable!());
        assert_eq!(tl.paste_lane(Video, &cb), Some(0));
        assert_eq!(tl.target_lanes(&cb).get(&Video), Some(&1));
        assert!(tl.paste_to_targets(&cb, s(5), false, &mut SequentialIds::default()).is_ok());
        assert_eq!(spans(&tl.tracks[1]), [[5, 7]]);
    }

    #[test]
    fn gap_and_close_gap() {
        let mut tl = timeline(vec![track(Video, vec![v(0, 2), v(5, 2), v(9, 1)])]);
        let t0 = tl.tracks[0].id;
        assert_eq!(tl.gap(t0, s(3)), Some(r(2, 5)));
        assert_eq!(tl.gap(t0, s(1)), None);
        assert_eq!(tl.gap(t0, s(20)), None); // nothing follows
        assert_eq!(tl.close_gap(t0, s(3), &mut SequentialIds::default()), Ok(s(3)));
        assert_eq!(spans(&tl.tracks[0]), [[0, 2], [2, 4], [6, 7]]);
    }

    fn captions(items: &[(i64, i64)]) -> sq_core_model::CaptionTrack {
        let items: Vec<serde_json::Value> = items
            .iter()
            .zip(70u128..)
            .map(|((a, b), n)| {
                serde_json::json!({"id": Id::from_u128(n), "lines": ["Hello caption"],
                    "range": {"start": {"value": a, "timescale": 1}, "duration": {"value": b - a, "timescale": 1}}})
            })
            .collect();
        let ct = serde_json::from_value(serde_json::json!({"id": Id::from_u128(60), "items": items}));
        ct.unwrap_or_else(|_| unreachable!())
    }

    fn caption_spans(tl: &Timeline) -> Vec<[i64; 2]> {
        let secs = |t: Time| t.value() / t.timescale();
        tl.caption_tracks
            .iter()
            .flat_map(|k| k.items().iter())
            .map(|i| [secs(i.range.start), secs(i.range.end())])
            .collect()
    }

    /// V1: a 27 s gap, then a clip at 27-37 s.
    fn gap_before_a_clip() -> Timeline {
        timeline(vec![track(Video, vec![v(27, 10)])])
    }

    #[test]
    fn a_caption_inside_the_gap_is_never_deleted() {
        let mut tl = gap_before_a_clip();
        tl.caption_tracks.push(captions(&[(10, 25), (28, 30)]));
        assert!(tl.caption_tracks[0].follows_ripple());
        let t0 = tl.tracks[0].id;
        // the caption ends at 25, so only the 2 s between it and the clip are empty everywhere
        assert_eq!(tl.gap_closable(t0, s(5)), Some(s(2)));
        assert_eq!(tl.close_gap(t0, s(5), &mut SequentialIds::default()), Ok(s(2)));
        assert_eq!(spans(&tl.tracks[0]), [[25, 35]]);
        assert_eq!(caption_spans(&tl), [[10, 25], [26, 28]]);
    }

    #[test]
    fn a_caption_straddling_the_gap_end_blocks_the_close() {
        let mut tl = gap_before_a_clip();
        tl.caption_tracks.push(captions(&[(20, 30)]));
        let t0 = tl.tracks[0].id;
        assert_eq!(tl.close_gap(t0, s(5), &mut SequentialIds::default()), Ok(s(0)));
        assert_eq!((spans(&tl.tracks[0]), caption_spans(&tl)), (vec![[27, 37]], vec![[20, 30]]));
    }

    #[test]
    fn a_clip_inside_the_gap_on_another_track_stays_and_limits_the_close() {
        for kind in [Video, Audio] {
            let mut tl = gap_before_a_clip();
            tl.tracks.push(track(kind, vec![if kind == Video { v(10, 15) } else { a(10, 15) }]));
            let t0 = tl.tracks[0].id;
            assert_eq!(tl.gap_closable(t0, s(5)), Some(s(2)));
            assert_eq!(tl.close_gap(t0, s(5), &mut SequentialIds::default()), Ok(s(2)));
            assert_eq!(spans(&tl.tracks[0]), [[25, 35]]);
            assert_eq!(spans(&tl.tracks[1]), [[10, 25]], "the clip on the other track is untouched");
        }
    }

    #[test]
    fn a_gap_that_is_empty_everywhere_closes_completely() {
        let mut tl = gap_before_a_clip();
        tl.tracks.push(track(Audio, vec![a(30, 5)]));
        tl.caption_tracks.push(captions(&[(40, 45)]));
        let t0 = tl.tracks[0].id;
        assert_eq!(tl.gap_closable(t0, s(5)), Some(s(27)));
        assert_eq!(tl.close_gap(t0, s(5), &mut SequentialIds::default()), Ok(s(27)));
        assert_eq!(spans(&tl.tracks[0]), [[0, 10]]);
        assert_eq!(spans(&tl.tracks[1]), [[3, 8]]);
        assert_eq!(caption_spans(&tl), [[13, 18]]);
    }

    #[test]
    fn locked_tracks_neither_block_nor_move_and_a_locked_target_refuses() {
        let mut tl = gap_before_a_clip();
        tl.tracks.push(locked(track(Audio, vec![a(10, 15)])));
        let mut ct = captions(&[(10, 25)]);
        ct.is_locked = true;
        tl.caption_tracks.push(ct);
        let t0 = tl.tracks[0].id;
        assert_eq!(tl.close_gap(t0, s(5), &mut SequentialIds::default()), Ok(s(27)));
        assert_eq!(spans(&tl.tracks[1]), [[10, 25]]);
        assert_eq!(caption_spans(&tl), [[10, 25]]);
        let mut shut = gap_before_a_clip();
        shut.tracks[0].is_locked = true;
        let t = shut.tracks[0].id;
        assert_eq!(shut.close_gap(t, s(5), &mut SequentialIds::default()), Err(EditError::TrackLocked));
    }

    #[test]
    fn link_unlink_and_orphans() {
        let (x, a1, b) = (v(0, 2), a(0, 2), v(5, 1));
        let mut tl = timeline(vec![track(Video, vec![x.clone(), b.clone()]), track(Audio, vec![a1.clone()])]);
        let mut ids = SequentialIds::default();
        assert!(tl.link(&BTreeSet::from([x.id, a1.id]), &mut ids).is_ok());
        assert!(tl.tracks[0].clips()[0].link.is_some() && tl.tracks[0].clips()[0].link == tl.tracks[1].clips()[0].link);
        assert_eq!(tl.link(&BTreeSet::from([b.id]), &mut ids), Err(EditError::ClipNotFound));
        // unlinking one of two frees the partner too
        assert!(tl.unlink(&BTreeSet::from([x.id])).is_ok());
        assert!(tl.tracks.iter().flat_map(|t| t.clips()).all(|c| c.link.is_none()));
    }

    #[test]
    fn nudge_moves_the_group_and_clamps_at_zero() {
        let l = link();
        let (vc, au) = (clip(1, 2, 0, Video, Some(l), None), clip(3, 2, 0, Audio, Some(l), None));
        let mut tl = timeline(vec![track(Video, vec![vc.clone()]), track(Audio, vec![au])]);
        let mut ids = SequentialIds::default();
        assert_eq!(tl.nudge(&BTreeSet::from([vc.id]), s(-5), &mut ids), Ok(s(-1)));
        assert_eq!((tl.tracks[0].clips()[0].start, tl.tracks[1].clips()[0].start), (s(0), s(2)));
        assert_eq!(tl.nudge(&BTreeSet::from([vc.id]), s(-5), &mut ids), Ok(Time::ZERO));
    }
}
