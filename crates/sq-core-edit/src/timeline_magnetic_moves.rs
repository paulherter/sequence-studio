//! Port of `Timeline+MagneticMoves.swift`: Fast Cut verbs for gestures that touch several clips at once. They keep the
//! Fast Cut invariants of `timeline_magnetic_ops`: V1 never gets a hole, attached clips never cover anything.
//!
//! Only the building blocks that need no Normal-mode verb of the other edit groups are here; the router verbs (they fall
//! back to `move`, `closeGap`, `trimToPlayhead`, `apply(SpeedChange)`, ...) are listed in `notes/g1.md`.

use crate::timeline_clipboard::TimelineClipboardExt as _;
use crate::timeline_duplicate::TimelineDuplicateExt as _;
use crate::timeline_edits::{CopySpec, TimelineEditsExt as _};
use crate::timeline_freeze_frame::TimelineFreezeFrameExt as _;
use crate::timeline_magnetic::{MagneticExt, MagneticOrphans, MagneticScope, MagneticStay};
use crate::timeline_magnetic_ops::{MagneticOpsExt, Placement, nearest_edge};
use crate::timeline_magnetic_verbs::MagneticVerbsExt as _;
use crate::timeline_speed::{SpeedChange, TimelineSpeedExt as _};
use crate::timeline_trim_to_playhead::{PlayheadTrimMode, TimelineTrimToPlayheadExt as _};
use sq_core_model::{Clip, ClipEdge, EditError, SpeedKeys, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time};
use std::collections::{BTreeMap, BTreeSet};

/// `extension Timeline` of `Timeline+MagneticMoves.swift`.
pub trait MagneticMovesExt {
    /// `main_track_drop_point` with every edge of `moving` left out; at most the end of V1 without them (no hole).
    /// Swift overload `mainTrackDropPoint(_:movingAll:)`.
    #[doc(hidden)]
    fn main_track_drop_point_all(&self, t: Time, moving: &BTreeSet<Id>) -> Time;

    /// The main-track clips `ids` (with their linked partners) leave V1 and go in at `drop` (pre-edit time, a V1 edit not
    /// of theirs) as one run in their order, V1 opening by their total length.
    #[doc(hidden)]
    fn rearrange_main_block(&mut self, ids: &[Id], drop: Time, id_source: &mut dyn IdSource) -> Result<(), EditError>;
}

impl MagneticMovesExt for Timeline {
    fn main_track_drop_point_all(&self, t: Time, moving: &BTreeSet<Id>) -> Time {
        let Some(mi) = self.main_track_index() else { return t };
        let edges = self.tracks[mi]
            .clips()
            .iter()
            .filter(|c| !moving.contains(&c.id))
            .flat_map(|c| [c.start, c.timeline().end()]);
        nearest_edge(edges, t).unwrap_or(Time::ZERO)
    }

    fn rearrange_main_block(&mut self, ids: &[Id], drop: Time, id_source: &mut dyn IdSource) -> Result<(), EditError> {
        let mi = self.main_track_index().ok_or(EditError::WrongTrackKind)?;
        let mains: Vec<Clip> = self.tracks[mi].clips().iter().filter(|c| ids.contains(&c.id)).cloned().collect();
        let mut seen = BTreeSet::new();
        let mut groups: Vec<(&Clip, Vec<Placement>)> = Vec::new();
        for v in &mains {
            let g = self.linked_group(v.id)?;
            let members =
                g.into_iter().filter(|m| seen.insert(m.clip.id)).map(|m| (m.clip, self.tracks[m.track].id)).collect();
            groups.push((v, members));
        }
        let mut work = self.clone();
        work.ripple_delete_main(&mains.iter().map(|c| c.id).collect())?;
        let before =
            mains.iter().filter(|c| c.timeline().end() <= drop).fold(Time::ZERO, |a, c| a + c.timeline().duration);
        let at = (drop - before).max(Time::ZERO).min(work.main_track_end());
        let total = mains.iter().fold(Time::ZERO, |a, c| a + c.timeline().duration);
        work.open_main_hole(at, total, id_source)?;
        let mut cursor = at;
        let mut placements: Vec<Placement> = Vec::new();
        for (main, members) in groups {
            let s = cursor - main.start;
            for (clip, track) in members {
                let mut c = clip;
                c.start += s;
                placements.push((c, track));
            }
            cursor += main.timeline().duration;
        }
        work.place_in_main_hole(&placements, id_source)?;
        *self = work;
        Ok(())
    }
}

/// One copied clip of an Option-drag (`magnetic_copy`): the dragged clip, where it goes, where its linked partners go
/// (missing = their own track) and the identities of the copies.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MagneticCopy {
    /// The dragged clip.
    pub clip: Id,
    /// Destination of `clip`; `None` = its own track.
    pub track: Option<Id>,
    /// Destination tracks of linked partners.
    pub partners: BTreeMap<Id, Id>,
    /// Ids of the copies and their shared link.
    pub spec: CopySpec,
}

fn scope(involving: BTreeSet<Id>, local: bool, stay: MagneticStay) -> MagneticScope {
    MagneticScope { involving, local, stay, orphans: MagneticOrphans::Follow }
}

/// End of the main-track clip `id` after an edit.
fn main_clip_end(tl: &Timeline, id: Id) -> Result<Time, EditError> {
    let mi = tl.main_track_index().ok_or(EditError::ClipNotFound)?;
    tl.tracks[mi].clip(id).map(|c| c.timeline().end()).ok_or(EditError::ClipNotFound)
}

/// Clips of `ids` in drag order: far end first when moving right.
fn drag_order(tl: &Timeline, ids: &BTreeSet<Id>, delta: Time) -> Vec<Clip> {
    let mut order: Vec<Clip> = ids.iter().filter_map(|c| tl.find(*c).map(|m| m.clip)).collect();
    order.sort_by_key(|c| c.start);
    if delta > Time::ZERO {
        order.reverse();
    }
    order
}

/// `extension Timeline` of `Timeline+MagneticMoves.swift` (the verbs that route to a Normal-mode verb).
pub trait MagneticGesturesExt {
    /// Close Gap on a track other than V1: the clips of that track after the gap move left by its length, each with its
    /// linked partners off V1; V1, its camera audio and every other track stay. On V1: `delete_spacer`. Returns the time closed.
    fn close_lane_gap(&mut self, track: Id, t: Time, ids: &mut dyn IdSource) -> Result<Time, EditError>;
    /// Option-drag / Cmd+Option-drag copy by `delta`. Copies whose video lands on V1 go in as one contiguous run at the
    /// V1 edit nearest to the first one; every other copy lands like an attached clip. The originals stay. Returns the
    /// ids of the copies.
    fn magnetic_copy(
        &mut self,
        items: &[MagneticCopy],
        delta: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;
    /// Drag of several main-track clips along V1: they leave V1 and go in as one contiguous run at the V1 edit nearest to
    /// where the first one was dragged. Attached clips travel with their hosts unless `keep_attached`.
    fn magnetic_rearrange_block(
        &mut self,
        clips: &BTreeSet<Id>,
        delta: Time,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;
    /// Drag of main-track clips onto another track: V1 closes, the clips and their linked partners move by `delta` and
    /// become attached. Normal: plain moves.
    fn drag_off_main_tracks(
        &mut self,
        clips: &BTreeSet<Id>,
        target: Id,
        delta: Time,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;
    /// Q / W with a mode. Fast Cut: `Ripple` is `magnetic_ripple_trim_to_playhead`; `Roll` keeps every attached clip on
    /// its frame; `Plain` trims the attached clips under `t` alone and ripple-trims V1. Normal: `trim_to_playhead`.
    fn magnetic_trim_to_playhead(
        &mut self,
        edge: ClipEdge,
        t: Time,
        mode: PlayheadTrimMode,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
    /// Speed/Duration and Reverse. Fast Cut: main-track clips always ripple V1; attached clips are retimed alone.
    fn magnetic_apply(&mut self, change: &SpeedChange, clips: &[Id], ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Rate Stretch tool. Fast Cut, a main-track clip: its start stays, V1 ripples from its end by the change. Returns how
    /// far the dragged edge moved.
    fn magnetic_rate_stretch(
        &mut self,
        id: Id,
        edge: ClipEdge,
        delta: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
    /// Closes every hole between main-track clips by rippling the later clips (and their partners) left.
    #[doc(hidden)]
    fn close_main_holes(&mut self) -> Result<(), EditError>;
    /// Speed ramp edit. Fast Cut, a main-track clip: V1 ripples from the clip's end by the length change. Returns the change
    /// of the clip's timeline duration.
    fn magnetic_edit_speed_keys(
        &mut self,
        id: Id,
        keeping_keys: bool,
        refuse_shortening: bool,
        edit: impl FnOnce(&SpeedKeys) -> Option<SpeedKeys>,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
    /// Insert Frame Hold Segment. Fast Cut: a main-track clip splits and the held copy goes in with V1 rippling by its
    /// length; an attached clip is refused (`WrongTrackKind`).
    fn magnetic_insert_frame_hold(
        &mut self,
        clip: Option<Id>,
        time: Time,
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    /// Add Frame Hold. Fast Cut: the clip's length and everything around it stay; attached clips keep their frame.
    fn magnetic_add_frame_hold(
        &mut self,
        clip: Option<Id>,
        time: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
    /// Opt+Up / Opt+Down. Fast Cut: main-track clips only go up (`lift_off_main_track`); attached video clips on the lane
    /// right above V1 going down are put on the main track; every other clip changes lane and re-attaches. False, changing
    /// nothing, when no clip can move that way.
    fn magnetic_move_to_lane(
        &mut self,
        clips: &BTreeSet<Id>,
        up: bool,
        ids: &mut dyn IdSource,
    ) -> Result<bool, EditError>;
}

impl MagneticGesturesExt for Timeline {
    fn close_lane_gap(&mut self, track: Id, t: Time, ids: &mut dyn IdSource) -> Result<Time, EditError> {
        let Some(main) = self.main_track_id().filter(|_| self.is_fast_cut()) else {
            return self.close_gap(track, t, ids);
        };
        if track == main {
            return self.delete_spacer(t, false, ids);
        }
        let Some(r) = self.gap(track, t) else { return Ok(Time::ZERO) };
        let mut work = self.clone();
        work.shift_off_main(r.end(), Time::ZERO - r.duration, &[track], &BTreeSet::new())?;
        work.derive_attachments();
        *self = work;
        Ok(r.duration)
    }

    fn magnetic_copy(
        &mut self,
        items: &[MagneticCopy],
        delta: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        let Some(main) = self.main_track_id().filter(|_| self.is_fast_cut()) else {
            let mut work = self.clone();
            let mut made = Vec::new();
            for it in items {
                let group = work.linked_group(it.clip)?;
                work.move_clip(it.clip, group[0].clip.start + delta, it.track, &it.partners, Some(&it.spec), ids)?;
                made.extend(group.iter().map(|m| it.spec.ids.get(&m.clip.id).copied().unwrap_or(m.clip.id)));
            }
            *self = work;
            return Ok(made);
        };
        let mut base = self.clone();
        base.derive_attachments();
        struct MainCopy {
            lead: Clip,
            original: Id,
            members: Vec<Placement>,
        }
        let mut mains: Vec<MainCopy> = Vec::new();
        let mut loose: Vec<(Option<Id>, Vec<Placement>)> = Vec::new();
        let mut made: Vec<Id> = Vec::new();
        for it in items {
            let group = base.linked_group(it.clip)?;
            let copies: Vec<Placement> = group
                .iter()
                .map(|m| {
                    let home = base.tracks[m.track].id;
                    let mut c = m.clip.clone();
                    c.id = it.spec.ids.get(&m.clip.id).copied().unwrap_or_else(|| ids.next_id());
                    if c.link.is_some() {
                        c.link = Some(it.spec.link);
                    }
                    c.bundle = None; // a copy never joins the original's bundle
                    let track = if m.clip.id == it.clip {
                        it.track.unwrap_or(home)
                    } else {
                        it.partners.get(&m.clip.id).copied().unwrap_or(home)
                    };
                    (c, track)
                })
                .collect();
            made.extend(copies.iter().map(|p| p.0.id));
            if let Some(i) = copies.iter().position(|p| p.0.kind == TrackKind::Video && p.1 == main) {
                let members: Vec<Placement> =
                    copies.into_iter().map(|(c, tr)| (Clip { attachment: None, ..c }, tr)).collect();
                mains.push(MainCopy { lead: members[i].0.clone(), original: group[i].clip.id, members });
            } else {
                loose.push((group[0].clip.attachment.as_ref().map(|a| a.host), copies));
            }
        }
        // The V1 copies as one run, in timeline order; attached copies of a copied main clip ride with its copy.
        mains.sort_by_key(|m| m.lead.start);
        let mut shift: BTreeMap<Id, Time> = BTreeMap::new(); // original main clip -> how far its copy moves
        let mut cursor = mains.first().map_or(Time::ZERO, |m| m.lead.start);
        for m in &mains {
            shift.insert(m.original, cursor - m.lead.start);
            cursor += m.lead.timeline().duration;
        }
        let moved = |members: &[Placement], by: Time| -> Vec<Placement> {
            members.iter().map(|(c, tr)| (Clip { start: c.start + by, ..c.clone() }, *tr)).collect()
        };
        let mut in_run: Vec<Placement> = mains
            .iter()
            .flat_map(|m| moved(&m.members, shift.get(&m.original).copied().unwrap_or(Time::ZERO)))
            .collect();
        let mut work = base.clone();
        let mut alone: Vec<Placement> = Vec::new();
        for (host, members) in &loose {
            if let Some(s) = host.and_then(|h| shift.get(&h).copied()) {
                in_run.extend(moved(members, s));
                continue;
            }
            let d = members.iter().fold(delta, |d, p| d.max(Time::ZERO - p.0.start));
            alone.extend(moved(members, d));
        }
        alone.sort_by_key(|p| p.0.start);
        for p in alone {
            work.place_attached(p.0, p.1, ids)?;
        }
        work.derive_attachments();
        if let Some(first) = mains.first() {
            let drop =
                base.main_track_drop_point_all(first.lead.start + delta, &BTreeSet::new()).min(work.main_track_end());
            work.magnetic_edit(MagneticScope::default(), ids, |tl, ids| tl.insert_on_main(&in_run, drop, ids))?;
        }
        work.derive_attachments();
        *self = work;
        Ok(made)
    }

    fn magnetic_rearrange_block(
        &mut self,
        clips: &BTreeSet<Id>,
        delta: Time,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let (true, Some(mi)) = (self.is_fast_cut(), self.main_track_index()) else {
            let mut work = self.clone();
            for c in drag_order(self, clips, delta) {
                work.move_clip(c.id, c.start + delta, None, &BTreeMap::new(), None, ids)?;
            }
            *self = work;
            return Ok(());
        };
        let mains: BTreeSet<Id> = clips.iter().filter_map(|c| self.main_clip_of(*c)).collect();
        let main_clips: Vec<Clip> = self.tracks[mi].clips().iter().filter(|c| mains.contains(&c.id)).cloned().collect();
        let first = main_clips.first().ok_or(EditError::ClipNotFound)?;
        if main_clips.len() == 1 {
            return self.magnetic_rearrange(first.id, first.start + delta, keep_attached, ids);
        }
        let drop = self.main_track_drop_point_all(first.start + delta, &mains);
        let order: Vec<Id> = main_clips.iter().map(|c| c.id).collect();
        let stay = if keep_attached { MagneticStay::Hosts(mains) } else { MagneticStay::None };
        let mut work = self.clone();
        work.magnetic_edit(scope(BTreeSet::new(), false, stay), ids, |tl, ids| {
            tl.rearrange_main_block(&order, drop, ids)
        })?;
        *self = work;
        Ok(())
    }

    fn drag_off_main_tracks(
        &mut self,
        clips: &BTreeSet<Id>,
        target: Id,
        delta: Time,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let (true, Some(mi)) = (self.is_fast_cut(), self.main_track_index()) else {
            let mut work = self.clone();
            for c in drag_order(self, clips, delta) {
                work.move_clip(c.id, c.start + delta, Some(target), &BTreeMap::new(), None, ids)?;
            }
            *self = work;
            return Ok(());
        };
        let mains: Vec<Id> = self.tracks[mi].clips().iter().filter(|c| clips.contains(&c.id)).map(|c| c.id).collect();
        let tr = self
            .track(target)
            .filter(|t| !mains.is_empty() && Some(t.id) != self.main_track_id() && t.kind == TrackKind::Video);
        let tr = tr.ok_or(EditError::WrongTrackKind)?;
        if tr.is_locked {
            return Err(EditError::TrackLocked);
        }
        let mut base = self.clone();
        base.derive_attachments();
        let mut seen: BTreeSet<Id> = BTreeSet::new();
        let mut group: Vec<sq_core_model::Member> = Vec::new();
        for id in &mains {
            group.extend(base.linked_group(*id)?.into_iter().filter(|m| seen.insert(m.clip.id)));
        }
        let main_set: BTreeSet<Id> = mains.iter().copied().collect();
        let followers: BTreeSet<Id> = if keep_attached {
            BTreeSet::new()
        } else {
            base.attached_clips_of(&main_set).into_iter().filter(|f| !seen.contains(f)).collect()
        };
        let mut carried: Vec<Clip> = group.iter().map(|m| m.clip.clone()).collect();
        carried.extend(followers.iter().filter_map(|f| base.find(*f).map(|m| m.clip)));
        let d = carried.iter().fold(delta, |d, c| d.max(Time::ZERO - c.start));
        let mut homes: BTreeMap<Id, Id> = group.iter().map(|m| (m.clip.id, base.tracks[m.track].id)).collect();
        homes.extend(followers.iter().filter_map(|f| base.find(*f).map(|m| (*f, base.tracks[m.track].id))));
        let mut stash = Vec::new();
        let mut work = base;
        let stay = if keep_attached { MagneticStay::Hosts(main_set.clone()) } else { MagneticStay::None };
        work.magnetic_edit(scope(followers.clone(), false, stay), ids, |tl, _| {
            stash = tl.lift_out(&followers);
            tl.ripple_delete_main(&main_set)?;
            Ok(())
        })?;
        for mut c in carried {
            c.start += d;
            c.attachment = None;
            let preferring =
                if main_set.contains(&c.id) { target } else { homes.get(&c.id).copied().unwrap_or(target) };
            work.place_attached(c, preferring, ids)?;
        }
        work.restore_magnetic(&stash);
        work.prune_transitions();
        work.derive_attachments();
        *self = work;
        Ok(())
    }

    fn magnetic_trim_to_playhead(
        &mut self,
        edge: ClipEdge,
        t: Time,
        mode: PlayheadTrimMode,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let (true, Some(mi)) = (self.is_fast_cut(), self.main_track_index()) else {
            return self.trim_to_playhead(edge, t, None, mode);
        };
        let mut work = self.clone();
        let moved = match mode {
            PlayheadTrimMode::Ripple => work.magnetic_ripple_trim_to_playhead(edge, t, None, keep_attached, ids)?.0,
            PlayheadTrimMode::Roll => {
                work.magnetic_edit(scope(BTreeSet::new(), false, MagneticStay::All), ids, |tl, _| {
                    tl.trim_to_playhead(edge, t, None, PlayheadTrimMode::Roll)
                })?
            }
            PlayheadTrimMode::Plain => {
                let strictly_under = |c: &Clip| c.start < t && t < c.timeline().end();
                let under: Vec<(usize, Id)> = (0..self.tracks.len())
                    .filter(|i| *i != mi && !self.tracks[*i].is_locked)
                    .flat_map(|i| {
                        self.tracks[i]
                            .clips()
                            .iter()
                            .filter(|c| strictly_under(c) && self.is_attachable(c.id))
                            .map(move |c| (i, c.id))
                            .collect::<Vec<_>>()
                    })
                    .collect();
                let on_main = self.tracks[mi].clips().iter().any(strictly_under);
                if under.is_empty() && !on_main {
                    return self.trim_to_playhead(edge, t, None, PlayheadTrimMode::Plain);
                }
                let mut m = Time::ZERO;
                if !under.is_empty() {
                    let involved: BTreeSet<Id> = under.iter().map(|u| u.1).collect();
                    let lanes: Vec<Id> = under
                        .iter()
                        .map(|u| u.0)
                        .collect::<BTreeSet<_>>()
                        .into_iter()
                        .map(|i| self.tracks[i].id)
                        .collect();
                    m = work.magnetic_edit(scope(involved, true, MagneticStay::None), ids, |tl, _| {
                        tl.trim_to_playhead(edge, t, Some(&lanes), PlayheadTrimMode::Plain)
                    })?;
                }
                if on_main {
                    m = work.magnetic_ripple_trim_to_playhead(edge, t, None, keep_attached, ids)?.0;
                }
                m
            }
        };
        *self = work;
        Ok(moved)
    }

    fn magnetic_apply(&mut self, change: &SpeedChange, clips: &[Id], ids: &mut dyn IdSource) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            return self.apply_speed_change_to_all(change, clips);
        }
        let mains: Vec<Id> = clips.iter().copied().filter(|c| self.is_main_material(*c)).collect();
        let others: Vec<Id> = clips.iter().copied().filter(|c| !self.is_main_material(*c)).collect();
        let mut work = self.clone();
        if !mains.is_empty() {
            let c = SpeedChange { ripple: true, ..change.clone() };
            work.magnetic_edit(MagneticScope::default(), ids, |tl, _| {
                tl.apply_speed_change_to_all(&c, &mains)?;
                // A linked partner that rounds to another length makes `apply` close by the smaller change only.
                tl.close_main_holes()
            })?;
        }
        if !others.is_empty() {
            let c = SpeedChange { ripple: false, ..change.clone() };
            let sc = scope(others.iter().copied().collect(), true, MagneticStay::None);
            work.magnetic_edit(sc, ids, |tl, _| tl.apply_speed_change_to_all(&c, &others))?;
        }
        *self = work;
        Ok(())
    }

    fn magnetic_rate_stretch(
        &mut self,
        id: Id,
        edge: ClipEdge,
        delta: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let (true, Some(mi)) = (self.is_fast_cut(), self.main_track_index()) else {
            return self.rate_stretch(id, edge, delta);
        };
        let mut work = self.clone();
        let main_clip = self.main_clip_of(id).and_then(|m| self.tracks[mi].clip(m).cloned());
        let moved = if let Some(v) = main_clip {
            let change = if edge == ClipEdge::Tail { delta } else { Time::ZERO - delta };
            work.magnetic_edit(MagneticScope::default(), ids, |tl, _| {
                let old_end = v.timeline().end();
                let room = change.max(Time::ZERO);
                if room > Time::ZERO {
                    tl.ripple_main(old_end, room)?;
                }
                tl.rate_stretch(id, ClipEdge::Tail, change)?;
                let new_end = main_clip_end(tl, v.id)?;
                let fix = new_end - (old_end + room);
                if fix != Time::ZERO {
                    tl.ripple_main(old_end + room, fix)?;
                }
                let applied = new_end - old_end;
                Ok(if edge == ClipEdge::Tail { applied } else { Time::ZERO - applied })
            })?
        } else {
            work.magnetic_edit(scope([id].into(), true, MagneticStay::None), ids, |tl, _| {
                tl.rate_stretch(id, edge, delta)
            })?
        };
        *self = work;
        Ok(moved)
    }

    fn close_main_holes(&mut self) -> Result<(), EditError> {
        let Some(mi) = self.main_track_index() else { return Ok(()) };
        for _ in 0..=self.tracks[mi].clips().len() {
            let mut sorted: Vec<Clip> = self.tracks[mi].clips().to_vec();
            sorted.sort_by_key(|c| c.start);
            let Some(i) =
                (0..sorted.len().saturating_sub(1)).find(|i| sorted[*i].timeline().end() < sorted[*i + 1].start)
            else {
                return Ok(());
            };
            let gap = sorted[i + 1].start - sorted[i].timeline().end();
            self.ripple_main(sorted[i + 1].start, Time::ZERO - gap)?;
        }
        Ok(())
    }

    fn magnetic_edit_speed_keys(
        &mut self,
        id: Id,
        keeping_keys: bool,
        refuse_shortening: bool,
        edit: impl FnOnce(&SpeedKeys) -> Option<SpeedKeys>,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let (true, Some(mi)) = (self.is_fast_cut(), self.main_track_index()) else {
            return self.edit_speed_keys(id, keeping_keys, refuse_shortening, edit);
        };
        let main_clip = self.main_clip_of(id).and_then(|m| self.tracks[mi].clip(m).cloned());
        let mut work = self.clone();
        let change = if let Some(v) = main_clip {
            work.magnetic_edit(MagneticScope::default(), ids, |tl, _| {
                let old_end = v.timeline().end();
                // Room first (the edit may grow the clip), then close what is left over.
                let room = Time::new(3600, 1);
                tl.ripple_main(old_end, room)?;
                let result = tl.edit_speed_keys(id, keeping_keys, refuse_shortening, edit)?;
                let fix = main_clip_end(tl, v.id)? - (old_end + room);
                if fix != Time::ZERO {
                    tl.ripple_main(old_end + room, fix)?;
                }
                Ok(result)
            })?
        } else {
            work.magnetic_edit(scope([id].into(), true, MagneticStay::None), ids, |tl, _| {
                tl.edit_speed_keys(id, keeping_keys, refuse_shortening, edit)
            })?
        };
        *self = work;
        Ok(change)
    }

    fn magnetic_insert_frame_hold(
        &mut self,
        clip: Option<Id>,
        time: Time,
        duration: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        if !self.is_fast_cut() {
            return self.insert_frame_hold(clip, time, duration, ids);
        }
        if clip.is_some_and(|c| !self.is_main_material(c)) {
            return Err(EditError::WrongTrackKind);
        }
        self.magnetic_edit(MagneticScope::default(), ids, |tl, ids| tl.insert_frame_hold(clip, time, duration, ids))
    }

    fn magnetic_add_frame_hold(
        &mut self,
        clip: Option<Id>,
        time: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        if !self.is_fast_cut() {
            return self.add_frame_hold(clip, time, ids);
        }
        if let Some(c) = clip.filter(|c| !self.is_main_material(*c)) {
            return self.magnetic_edit(scope([c].into(), true, MagneticStay::None), ids, |tl, ids| {
                tl.add_frame_hold(clip, time, ids)
            });
        }
        self.magnetic_edit(MagneticScope::default(), ids, |tl, ids| tl.add_frame_hold(clip, time, ids))
    }

    fn magnetic_move_to_lane(
        &mut self,
        clips: &BTreeSet<Id>,
        up: bool,
        ids: &mut dyn IdSource,
    ) -> Result<bool, EditError> {
        let (true, Some(mi)) = (self.is_fast_cut(), self.main_track_index()) else {
            return self.move_to_lane(clips, up, ids);
        };
        if clips.iter().any(|c| self.is_on_main_track(*c)) {
            if !up {
                return Ok(false);
            }
            self.lift_off_main_track(clips, ids)?;
            return Ok(true);
        }
        let video_lanes: Vec<usize> =
            (0..self.tracks.len()).filter(|i| self.tracks[*i].kind == TrackKind::Video).collect();
        let above = video_lanes.iter().position(|i| *i == mi).and_then(|p| video_lanes.get(p + 1)).copied();
        let down: Vec<Clip> = if up {
            Vec::new()
        } else {
            clips
                .iter()
                .filter_map(|c| self.find(*c))
                .filter(|m| Some(m.track) == above && m.clip.kind == TrackKind::Video)
                .map(|m| m.clip)
                .collect()
        };
        if down.is_empty() {
            return self.magnetic_edit(scope(clips.clone(), false, MagneticStay::All), ids, |tl, ids| {
                tl.move_to_lane(clips, up, ids)
            });
        }
        let links: BTreeSet<Id> = down.iter().filter_map(|c| c.link).collect();
        let rest: BTreeSet<Id> = clips
            .iter()
            .copied()
            .filter(|id| {
                self.find(*id).is_some_and(|m| {
                    !down.iter().any(|d| d.id == *id) && !m.clip.link.is_some_and(|l| links.contains(&l))
                })
            })
            .collect();
        let mut work = self.clone();
        work.put_on_main_track(&down.iter().map(|c| c.id).collect(), ids)?;
        if !rest.is_empty() {
            let moved = work.magnetic_edit(scope(rest.clone(), false, MagneticStay::All), ids, |tl, ids| {
                tl.move_to_lane(&rest, up, ids)
            })?;
            if !moved {
                return Ok(false);
            }
        }
        *self = work;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_magnetic::{MagneticExt, MagneticScope};
    use crate::timeline_magnetic_ops::fixture::{F, check_invariants, host, main_spans, s, span};

    #[test]
    fn drop_point_leaves_the_moving_edges_out() {
        let f = F::new();
        // Edges of V1 are 0, 4, 8, 12; without c2 the 4 and 8 edges stay (c1 and c3 have them), 12 is the end.
        assert_eq!(f.tl.main_track_drop_point_all(s(9.0), &[f.c2].into()), s(8.0));
        // Without c1 and c2 only c3's edges (8, 12) are left: V1 would never be cut at 4.
        assert_eq!(f.tl.main_track_drop_point_all(s(3.0), &[f.c1, f.c2].into()), s(8.0));
        assert_eq!(f.tl.main_track_drop_point_all(s(3.0), &[f.c1, f.c2, f.c3].into()), Time::ZERO);
    }

    #[test]
    fn rearrange_block_moves_two_clips_as_one_run_with_their_attached_clips() {
        let mut f = F::new();
        // c1 and c2 (with camera audio and title) go behind c3.
        let (c1, c2, c3) = (f.c1, f.c2, f.c3);
        let drop = f.tl.main_track_drop_point_all(s(12.0), &[c1, c2].into());
        assert_eq!(drop, s(12.0));
        f.tl.magnetic_edit(MagneticScope::default(), &mut f.ids, |tl, ids| {
            tl.rearrange_main_block(&[c1, c2], drop, ids)
        })
        .unwrap();
        let order: Vec<Id> = f.tl.tracks[0].clips().iter().map(|c| c.id).collect();
        assert_eq!(order, vec![c3, c1, c2]);
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        assert_eq!(span(&f.tl, f.c1a), Some([4., 8.])); // camera audio travels with c1
        assert_eq!(host(&f.tl, f.title), Some(c2));
        check_invariants(&f.tl, false);
    }

    // Swift MagneticMovesTests: closeLaneGapInNormalIsCloseGap / plainTrimToPlayheadInNormalLeavesTheGap.
    #[test]
    fn close_lane_gap_in_normal_is_close_gap() {
        use sq_core_model::TimelineEditMode;
        let mut f = F::new();
        f.tl.set_edit_mode_stored(TimelineEditMode::Normal);
        let mut late = crate::timeline_magnetic_ops::fixture::clip(
            &mut f.ids,
            sq_core_model::TrackKind::Video,
            9.0,
            1.0,
            None,
            Id::from_u128(77),
        );
        late.id = Id::from_u128(78);
        let mut clips = f.tl.tracks[1].clips().to_vec();
        clips.push(late);
        f.tl.tracks[1].set_clips(clips);
        let (mut a, mut b) = (f.tl.clone(), f.tl.clone());
        let track = f.tl.tracks[1].id;
        let ra = a.close_lane_gap(track, s(7.5), &mut sq_core_time::SequentialIds::default());
        let rb = b.close_gap(track, s(7.5), &mut sq_core_time::SequentialIds::default());
        assert_eq!(ra, rb);
        assert!(ra.is_ok_and(|d| d > Time::ZERO), "the gap exists, so the test moves something");
        assert_eq!(a, b);
    }

    #[test]
    fn plain_trim_to_playhead_in_normal_leaves_the_gap() {
        use sq_core_model::TimelineEditMode;
        let mut f = F::new();
        f.tl.set_edit_mode_stored(TimelineEditMode::Normal);
        let (mut a, mut b) = (f.tl.clone(), f.tl.clone());
        let ra = a.magnetic_trim_to_playhead(
            ClipEdge::Tail,
            s(6.0),
            PlayheadTrimMode::Plain,
            false,
            &mut sq_core_time::SequentialIds::default(),
        );
        let rb = b.trim_to_playhead(ClipEdge::Tail, s(6.0), None, PlayheadTrimMode::Plain);
        assert_eq!(ra, rb);
        assert_eq!(a, b);
    }
}
