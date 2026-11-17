//! Port of the Fast Cut verbs of `Timeline+MagneticOps.swift` that route to a Normal-mode verb of the other edit
//! modules (delete, trim, roll, slip, slide, nudge, cut, join, move, clipboard, ranges, nest). The building blocks they
//! use are in `timeline_magnetic_ops`; every verb works on a copy, so an error changes nothing.

use crate::timeline_clipboard::{TimelineClipboard, TimelineClipboardExt as _};
use crate::timeline_duplicate::TimelineDuplicateExt as _;
use crate::timeline_edit_targets::{EditOutcome, TimelineEditTargetsExt as _};
use crate::timeline_edits::{SlipKeyframes, TimelineEditsExt as _};
use crate::timeline_join_cuts::TimelineJoinCutsExt as _;
use crate::timeline_magnetic::{MagneticExt, MagneticOrphans, MagneticScope, MagneticStay};
use crate::timeline_magnetic_moves::MagneticGesturesExt as _;
use crate::timeline_magnetic_ops::{CaptionsInSpan, MagneticOpsExt};
use crate::timeline_range_edits::TimelineRangeEditsExt as _;
use crate::timeline_three_point::TimelineThreePointExt as _;
use sq_core_model::{Clip, ClipEdge, EditError, Project, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

fn scope(involving: BTreeSet<Id>, local: bool, stay: MagneticStay) -> MagneticScope {
    MagneticScope { involving, local, stay, orphans: MagneticOrphans::Follow }
}

/// Removes the attachment of the clips `ids` (the right halves of a cut attach at their own first frame).
fn drop_attachments(tl: &mut Timeline, ids: &[Id]) {
    for id in ids {
        let Some(m) = tl.find(*id).filter(|m| m.clip.attachment.is_some()) else { continue };
        tl.tracks[m.track].replace(Clip { attachment: None, ..m.clip });
    }
}

/// The clipboard with its main-track copies (V1, lane 0) closed up into one contiguous run (FCP: a paste never opens a
/// hole on the main track). Every other copy moves with the main copy it belongs to: its linked main clip, else its
/// attachment host, else the main copy before it; so attached copies keep their point.
fn packed_main_entries(cb: &TimelineClipboard) -> TimelineClipboard {
    let mut mains: Vec<usize> = (0..cb.entries.len())
        .filter(|i| cb.entries[*i].clip.kind == TrackKind::Video && cb.entries[*i].lane == 0)
        .collect();
    mains.sort_by_key(|i| cb.entries[*i].offset);
    let Some(&first) = mains.first() else { return cb.clone() };
    let mut shift: BTreeMap<Id, Time> = BTreeMap::new();
    let mut by_link: BTreeMap<Id, Time> = BTreeMap::new();
    let mut cursor = cb.entries[first].offset;
    let mut starts: Vec<(Time, Time)> = Vec::new();
    for i in mains {
        let e = &cb.entries[i];
        let s = cursor - e.offset;
        shift.insert(e.clip.id, s);
        if let Some(l) = e.clip.link {
            by_link.insert(l, s);
        }
        starts.push((e.offset, s));
        cursor += e.clip.timeline().duration;
    }
    if shift.values().all(|s| *s == Time::ZERO) {
        return cb.clone();
    }
    let mut out = cb.clone();
    for e in &mut out.entries {
        let s = shift
            .get(&e.clip.id)
            .copied()
            .or_else(|| e.clip.link.and_then(|l| by_link.get(&l).copied()))
            .or_else(|| e.clip.attachment.as_ref().and_then(|a| shift.get(&a.host).copied()))
            .or_else(|| starts.iter().rev().find(|(o, _)| *o <= e.offset).map(|x| x.1))
            .unwrap_or(Time::ZERO);
        e.offset += s;
    }
    out
}

/// `extension Timeline` of `Timeline+MagneticOps.swift` (the verbs that call Normal-mode verbs).
pub trait MagneticVerbsExt {
    /// Delete: a main-track clip ripple-deletes (V1 closes) and its attached clips go with it, unless `keep_attached`
    /// (hold `): then they stay on their frame and re-attach to the clip now under it. An attached clip is removed and
    /// nothing moves. Normal: lift (leaves gaps).
    fn magnetic_delete(
        &mut self,
        clips: &BTreeSet<Id>,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;
    /// Replace with Spacer (Shift+Delete): main-track clips leave a hole; attached clips stay on their frame.
    fn replace_with_spacer(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Delete on a spacer / Close Gap at the playhead: closes the hole of the main track under `t` (nothing when `t` is on
    /// a clip or after the last one). Clips attached in the hole are deleted unless `keep_attached`. Returns the time closed.
    fn delete_spacer(&mut self, t: Time, keep_attached: bool, ids: &mut dyn IdSource) -> Result<Time, EditError>;
    /// Ripple trim: a main-track clip ripples V1 and everything attached later; an attached clip is trimmed alone.
    fn magnetic_ripple_trim(
        &mut self,
        id: Id,
        edge: ClipEdge,
        delta: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
    /// Q / E style ripple trim to the playhead. Fast Cut: the main track only; `keep_attached` keeps the trimmed clip's
    /// attached clips on their frame. Normal: `tracks`.
    fn magnetic_ripple_trim_to_playhead(
        &mut self,
        edge: ClipEdge,
        t: Time,
        tracks: Option<&[Id]>,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(Time, EditOutcome), EditError>;
    /// Roll: the cut moves, nothing ripples; attached clips stay on their frame.
    fn magnetic_roll(&mut self, id: Id, delta: Time, ids: &mut dyn IdSource) -> Result<Time, EditError>;
    /// Slip: the content moves inside the clip; attached clips stay where they are.
    fn magnetic_slip(
        &mut self,
        id: Id,
        delta: Time,
        keyframes: SlipKeyframes,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
    /// Slide: a main-track clip moves between its neighbors with its attached clips; an attached clip slides on its track.
    fn magnetic_slide(&mut self, id: Id, delta: Time, ids: &mut dyn IdSource) -> Result<Time, EditError>;
    /// Nudge: main-track clips slide by `delta`, each run of adjacent selected clips as one block; other clips nudge alone.
    fn magnetic_nudge(&mut self, clips: &BTreeSet<Id>, delta: Time, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Cmd+K. Fast Cut, nothing selected: the main clip under `t` and its linked audio only. With a selection: the
    /// selected clips. The right half of a cut attached clip attaches at its own first frame. Returns the new right halves.
    fn magnetic_add_edit(
        &mut self,
        t: Time,
        selection: &BTreeSet<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;
    /// Cmd+Shift+K: every unlocked track, attached clips included.
    fn magnetic_add_edit_all(&mut self, t: Time, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError>;
    /// Join Through Edits: the joined clip keeps the left id; clips attached to the right half re-attach to it.
    fn magnetic_join(&mut self, selection: Option<&BTreeSet<Id>>, ids: &mut dyn IdSource) -> Result<usize, EditError>;
    /// Drag a main-track clip along V1 to the nearest V1 edit to `t`; its attached clips travel with it unless
    /// `keep_attached`. An attached clip is moved (`move_attached`). Normal: the plain move.
    fn magnetic_rearrange(
        &mut self,
        id: Id,
        t: Time,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;
    /// Move Left / Move Right: the main-track clip of `id` swaps places with its neighbor on V1 (`step` > 0 right).
    fn magnetic_move(&mut self, id: Id, step: i32, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Drag an attached clip (with its linked partners) to `start`, onto `target` when given, never covering anything.
    fn move_attached(
        &mut self,
        id: Id,
        start: Time,
        target: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;
    /// Lift off Main Track: the main-track clips among `clips` go to the lowest free video track above, attached.
    fn lift_off_main_track(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Drag a main-track clip onto another track: V1 closes, the clip and its partners land at `start` and become attached.
    fn drag_off_main_track(
        &mut self,
        id: Id,
        target: Id,
        start: Time,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;
    /// Drag a video clip from another track onto the main track: inserted at the nearest V1 edit to `t`; `overwrite`
    /// covers V1 from `t` instead.
    fn drag_onto_main_track(
        &mut self,
        id: Id,
        t: Time,
        overwrite: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;
    /// Put on Main Track: each attached video clip among `clips` overwrites V1 at its own position.
    fn put_on_main_track(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Copy: in Fast Cut, copied main-track clips take their linked partners and attached clips along.
    fn magnetic_clipboard(&self, clips: &BTreeSet<Id>) -> Option<TimelineClipboard>;
    /// Paste. Fast Cut: copied main-track clips are inserted on V1 at `t`; a clipboard without main clips, or `attached`,
    /// lands off the main track. Normal: overwrite without the copied attachments.
    fn magnetic_paste(
        &mut self,
        cb: &TimelineClipboard,
        t: Time,
        attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;
    /// Duplicate: main-track clips are pasted right after the selection's last main clip; attached clips land after the
    /// selection, attached. Normal: `duplicate`.
    fn magnetic_duplicate(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError>;
    /// Delete Range / Cut Out with the main track targeted: V1 closes and clips on the other targeted tracks close too;
    /// without the main track: a lift. Returns the time closed and the clamp.
    fn magnetic_extract(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        ids: &mut dyn IdSource,
    ) -> Result<(Time, EditOutcome), EditError>;
    /// Clear Range with the main track targeted: a spacer for that range on V1; attached clips stay on their frame.
    fn magnetic_clear_range(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;
}

impl MagneticVerbsExt for Timeline {
    fn magnetic_delete(
        &mut self,
        clips: &BTreeSet<Id>,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            return self.lift_clips(&clips.iter().copied().collect::<Vec<_>>());
        }
        let main: BTreeSet<Id> = clips.iter().copied().filter(|c| self.is_main_material(*c)).collect();
        let attached: Vec<Id> = clips.difference(&main).copied().collect();
        let hosts: BTreeSet<Id> = main.iter().filter_map(|c| self.main_clip_of(*c)).collect();
        let stay = if keep_attached { MagneticStay::Hosts(hosts.clone()) } else { MagneticStay::None };
        let sc = MagneticScope {
            orphans: MagneticOrphans::Delete,
            ..scope(attached.iter().copied().collect(), false, stay)
        };
        let mut work = self.clone();
        work.magnetic_edit(sc, ids, |tl, _| {
            if !attached.is_empty() {
                tl.lift_clips(&attached)?;
            }
            if !hosts.is_empty() {
                tl.ripple_delete_main(&hosts)?;
            }
            Ok(())
        })?;
        *self = work;
        Ok(())
    }

    fn replace_with_spacer(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let mut work = self.clone();
        let list: Vec<Id> = clips.iter().copied().collect();
        work.magnetic_edit(scope(clips.clone(), false, MagneticStay::All), ids, |tl, _| tl.lift_clips(&list))?;
        *self = work;
        Ok(())
    }

    fn delete_spacer(&mut self, t: Time, keep_attached: bool, ids: &mut dyn IdSource) -> Result<Time, EditError> {
        let Some(main) = self.main_track_id() else { return Ok(Time::ZERO) };
        let Some(r) = self.gap(main, t) else { return Ok(Time::ZERO) };
        if !self.is_fast_cut() {
            return self.close_gap(main, t, ids);
        }
        // Nothing is deleted here, so a caption inside the spacer limits the close (as `close_gap` does) instead of going.
        let closable = Time::ZERO - self.limit_close_by_captions(r.end(), Time::ZERO - r.duration);
        if closable <= Time::ZERO {
            return Ok(Time::ZERO);
        }
        let mut work = self.clone();
        work.derive_attachments();
        let mut doomed: Vec<Id> = Vec::new();
        if !keep_attached {
            for tr in work.tracks.iter().filter(|t| !t.is_locked) {
                doomed.extend(
                    tr.clips()
                        .iter()
                        .filter(|c| c.attachment.as_ref().is_some_and(|a| r.contains(c.start + a.point)))
                        .map(|c| c.id),
                );
            }
        }
        let stay = if keep_attached { MagneticStay::Range(r) } else { MagneticStay::None };
        let sc = scope(doomed.iter().copied().collect(), false, stay);
        let closed = work.magnetic_edit(sc, ids, |tl, _| {
            if !doomed.is_empty() {
                tl.lift_clips(&doomed)?;
            }
            // Every main clip after the hole moves with its linked partners, so a J cut reaching into the hole stays.
            tl.ripple_main(r.end(), Time::ZERO - closable)?;
            Ok(closable)
        })?;
        *self = work;
        Ok(closed)
    }

    fn magnetic_ripple_trim(
        &mut self,
        id: Id,
        edge: ClipEdge,
        delta: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let mut work = self.clone();
        let fast = self.is_fast_cut();
        let moved = if fast && self.is_on_main_track(id) {
            work.magnetic_edit(MagneticScope::default(), ids, |tl, _| tl.ripple_trim_main(id, edge, delta))?
        } else if !fast || self.is_main_material(id) {
            work.magnetic_edit(MagneticScope::default(), ids, |tl, _| tl.ripple_trim(id, edge, delta))?
        } else {
            let sc = scope([id].into(), true, MagneticStay::None);
            work.magnetic_edit(sc, ids, |tl, _| tl.trim(id, edge, delta))?
        };
        *self = work;
        Ok(moved)
    }

    fn magnetic_ripple_trim_to_playhead(
        &mut self,
        edge: ClipEdge,
        t: Time,
        tracks: Option<&[Id]>,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(Time, EditOutcome), EditError> {
        let (true, Some(main), Some(mi)) = (self.is_fast_cut(), self.main_track_id(), self.main_track_index()) else {
            return self.ripple_trim_to_playhead_outcome(edge, t, tracks);
        };
        let under = self.tracks[mi].clips().iter().find(|c| c.timeline().contains(t)).map(|c| c.id);
        let stay = if keep_attached { MagneticStay::Hosts(under.into_iter().collect()) } else { MagneticStay::None };
        let mut work = self.clone();
        let r = work.magnetic_edit(scope(BTreeSet::new(), false, stay), ids, |tl, _| {
            tl.ripple_trim_to_playhead_outcome(edge, t, Some(&[main]))
        })?;
        *self = work;
        Ok(r)
    }

    fn magnetic_roll(&mut self, id: Id, delta: Time, ids: &mut dyn IdSource) -> Result<Time, EditError> {
        let mut work = self.clone();
        let local = !self.is_main_material(id);
        let involving = if local { [id].into() } else { BTreeSet::new() };
        let d = work.magnetic_edit(scope(involving, local, MagneticStay::All), ids, |tl, _| tl.roll(id, delta))?;
        *self = work;
        Ok(d)
    }

    fn magnetic_slip(
        &mut self,
        id: Id,
        delta: Time,
        keyframes: SlipKeyframes,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let mut work = self.clone();
        let local = !self.is_main_material(id);
        let involving = if local { [id].into() } else { BTreeSet::new() };
        let d =
            work.magnetic_edit(scope(involving, local, MagneticStay::All), ids, |tl, _| tl.slip(id, delta, keyframes))?;
        *self = work;
        Ok(d)
    }

    fn magnetic_slide(&mut self, id: Id, delta: Time, ids: &mut dyn IdSource) -> Result<Time, EditError> {
        if !self.is_fast_cut() {
            return self.slide(id, delta);
        }
        let mut work = self.clone();
        let d = match self.main_clip_of(id).filter(|_| self.is_main_material(id)) {
            Some(main) => {
                work.magnetic_edit(MagneticScope::default(), ids, |tl, _| tl.slide_main_runs(&[main].into(), delta))?
            }
            None => {
                work.magnetic_edit(scope([id].into(), true, MagneticStay::None), ids, |tl, _| tl.slide(id, delta))?
            }
        };
        *self = work;
        Ok(d)
    }

    fn magnetic_nudge(&mut self, clips: &BTreeSet<Id>, delta: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            self.nudge(clips, delta, ids)?;
            return Ok(());
        }
        let mains: BTreeSet<Id> =
            clips.iter().copied().filter(|c| self.is_main_material(*c)).filter_map(|c| self.main_clip_of(c)).collect();
        let carried: BTreeSet<Id> = self.attached_clips_of(&mains).into_iter().collect();
        let alone: BTreeSet<Id> =
            clips.iter().copied().filter(|c| !self.is_main_material(*c) && !carried.contains(c)).collect();
        let mut work = self.clone();
        if !mains.is_empty() {
            work.magnetic_edit(MagneticScope::default(), ids, |tl, _| tl.slide_main_runs(&mains, delta))?;
        }
        if !alone.is_empty() {
            work.magnetic_edit(scope(alone.clone(), true, MagneticStay::None), ids, |tl, ids| {
                tl.nudge(&alone, delta, ids)
            })?;
        }
        *self = work;
        Ok(())
    }

    fn magnetic_add_edit(
        &mut self,
        t: Time,
        selection: &BTreeSet<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        let (true, Some(mi)) = (self.is_fast_cut(), self.main_track_index()) else {
            return self.add_edit_for_selection(t, selection, ids);
        };
        let mut work = self.clone();
        let made = if selection.is_empty() {
            let Some(under) = self.tracks[mi].clips().iter().find(|c| c.start < t && c.timeline().contains(t)) else {
                return Ok(Vec::new());
            };
            let mut tracks = vec![self.tracks[mi].id];
            if let Some(l) = under.link {
                tracks.extend(
                    self.tracks
                        .iter()
                        .enumerate()
                        .filter(|(i, tr)| *i != mi && tr.clips().iter().any(|c| c.link == Some(l)))
                        .map(|(_, tr)| tr.id),
                );
            }
            work.magnetic_edit(MagneticScope::default(), ids, |tl, ids| tl.add_edit(t, Some(&tracks), ids))?
        } else {
            work.magnetic_edit(scope(selection.clone(), false, MagneticStay::None), ids, |tl, ids| {
                let made = tl.add_edit_for_selection(t, selection, ids)?;
                drop_attachments(tl, &made);
                Ok(made)
            })?
        };
        *self = work;
        Ok(made)
    }

    fn magnetic_add_edit_all(&mut self, t: Time, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError> {
        if !self.is_fast_cut() {
            return self.add_edit(t, None, ids);
        }
        let under: BTreeSet<Id> = self
            .tracks
            .iter()
            .filter(|tr| !tr.is_locked)
            .flat_map(|tr| tr.clips().iter().filter(|c| c.start < t && c.timeline().contains(t)).map(|c| c.id))
            .collect();
        let mut work = self.clone();
        let made = work.magnetic_edit(scope(under, false, MagneticStay::None), ids, |tl, ids| {
            let made = tl.add_edit(t, None, ids)?;
            drop_attachments(tl, &made);
            Ok(made)
        })?;
        *self = work;
        Ok(made)
    }

    fn magnetic_join(&mut self, selection: Option<&BTreeSet<Id>>, ids: &mut dyn IdSource) -> Result<usize, EditError> {
        let mut work = self.clone();
        // A join moves nothing, so every clip it may touch is worked on directly (nothing is lifted out).
        let all: BTreeSet<Id> = match selection {
            Some(s) => s.clone(),
            None => self.tracks.iter().flat_map(|t| t.clips().iter().map(|c| c.id)).collect(),
        };
        let n =
            work.magnetic_edit(scope(all, false, MagneticStay::None), ids, |tl, _| tl.join_through_edits(selection))?;
        *self = work;
        Ok(n)
    }

    fn magnetic_rearrange(
        &mut self,
        id: Id,
        t: Time,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            self.move_clip(id, t, None, &BTreeMap::new(), None, ids)?;
            return Ok(());
        }
        let Some(main) = self.main_clip_of(id) else { return self.move_attached(id, t, None, ids) };
        let drop = self.main_track_drop_point(t, Some(main));
        let stay = if keep_attached { MagneticStay::Hosts([main].into()) } else { MagneticStay::None };
        let mut work = self.clone();
        work.magnetic_edit(scope(BTreeSet::new(), false, stay), ids, |tl, ids| tl.rearrange_main(main, drop, ids))?;
        *self = work;
        Ok(())
    }

    fn magnetic_move(&mut self, id: Id, step: i32, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let (true, true, Some(mi), Some(main)) =
            (self.is_fast_cut(), step != 0, self.main_track_index(), self.main_clip_of(id))
        else {
            return Ok(());
        };
        let clips = self.tracks[mi].clips();
        let i = clips.iter().position(|c| c.id == main).ok_or(EditError::ClipNotFound)?;
        let j = if step > 0 { i.checked_add(1) } else { i.checked_sub(1) };
        let Some(other) = j.and_then(|j| clips.get(j)) else { return Ok(()) };
        let to = if step > 0 { other.timeline().end() } else { other.start };
        self.magnetic_rearrange(main, to, false, ids)
    }

    fn move_attached(
        &mut self,
        id: Id,
        start: Time,
        target: Option<Id>,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            self.move_clip(id, start, target, &BTreeMap::new(), None, ids)?;
            return Ok(());
        }
        // Onto the main track is its own verb (drag_onto_main_track / put_on_main_track): refused here.
        if target.is_some() && target == self.main_track_id() {
            return Err(EditError::WrongTrackKind);
        }
        let mut work = self.clone();
        work.derive_attachments();
        if !work.is_attachable(id) {
            return Err(EditError::WrongTrackKind);
        }
        let group = work.linked_group(id)?;
        if group.iter().any(|m| work.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        if let Some(t) = target.and_then(|t| work.track(t)) {
            if t.kind != group[0].clip.kind {
                return Err(EditError::WrongTrackKind);
            }
            if t.is_locked {
                return Err(EditError::TrackLocked);
            }
        }
        let mut d = start - group[0].clip.start;
        for m in &group {
            d = d.max(Time::ZERO - m.clip.start);
        }
        let homes: Vec<Id> = group.iter().map(|m| work.tracks[m.track].id).collect();
        let stash = work.lift_out(&group.iter().map(|m| m.clip.id).collect());
        for (m, home) in group.iter().zip(homes) {
            let mut c = m.clip.clone();
            c.start += d;
            work.place_attached(c, if m.clip.id == id { target.unwrap_or(home) } else { home }, ids)?;
        }
        work.restore_magnetic(&stash);
        work.derive_attachments();
        *self = work;
        Ok(())
    }

    fn lift_off_main_track(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let (true, Some(mi)) = (self.is_fast_cut(), self.main_track_index()) else {
            self.move_to_lane(clips, true, ids)?;
            return Ok(());
        };
        let mains: BTreeSet<Id> = clips.iter().copied().filter(|c| self.tracks[mi].clip(*c).is_some()).collect();
        if mains.is_empty() {
            return Ok(());
        }
        if self.tracks[mi].is_locked {
            return Err(EditError::TrackLocked);
        }
        let mut work = self.clone();
        let (mut taken, mut stash) = (Vec::new(), Vec::new());
        work.magnetic_edit(scope(BTreeSet::new(), false, MagneticStay::All), ids, |tl, _| {
            taken = tl.tracks[mi].clips().iter().filter(|c| mains.contains(&c.id)).cloned().collect::<Vec<_>>();
            stash = tl.lift_out(&mains);
            Ok(())
        })?;
        for c in taken {
            work.place_new(Clip { attachment: None, ..c }, ids)?;
        }
        work.restore_magnetic(&stash);
        work.prune_transitions();
        work.derive_attachments();
        *self = work;
        Ok(())
    }

    fn drag_off_main_track(
        &mut self,
        id: Id,
        target: Id,
        start: Time,
        keep_attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        if !self.is_fast_cut() {
            self.move_clip(id, start, Some(target), &BTreeMap::new(), None, ids)?;
            return Ok(());
        }
        let clip =
            self.find(id).map(|m| m.clip).filter(|_| self.is_on_main_track(id)).ok_or(EditError::WrongTrackKind)?;
        self.drag_off_main_tracks(&[id].into(), target, start - clip.start, keep_attached, ids)
    }

    fn drag_onto_main_track(
        &mut self,
        id: Id,
        t: Time,
        overwrite: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let main = self.main_track_id().ok_or(EditError::WrongTrackKind)?;
        if !self.is_fast_cut() {
            self.move_clip(id, t, Some(main), &BTreeMap::new(), None, ids)?;
            return Ok(());
        }
        let clip = self.find(id).map(|m| m.clip).filter(|c| c.kind == TrackKind::Video && !self.is_on_main_track(id));
        let clip = clip.ok_or(EditError::WrongTrackKind)?;
        let group = self.linked_group(id)?;
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let group_ids: BTreeSet<Id> = group.iter().map(|m| m.clip.id).collect();
        let first = group.iter().map(|m| m.clip.start).min().ok_or(EditError::ClipNotFound)?;
        let lead = clip.start - first;
        let placements: Vec<(Clip, Id)> = group
            .iter()
            .map(|m| {
                let track = if m.clip.id == id { main } else { self.tracks[m.track].id };
                (Clip { attachment: None, ..m.clip.clone() }, track)
            })
            .collect();
        let mut work = self.clone();
        if overwrite {
            work.magnetic_edit(scope(group_ids.clone(), false, MagneticStay::All), ids, |tl, ids| {
                tl.lift_out(&group_ids);
                // Past V1's end the clip appends exactly at the end (never a hole before it). Its partners keep their
                // offsets, so a partner that would start before 0 refuses the edit (`Collision`) instead of shifting the clip.
                let end = tl.main_track_end();
                let from = if t > end { end - lead } else { (t - lead).max(Time::ZERO) };
                tl.overwrite(&placements, from, ids)
            })?;
        } else {
            let drop = self.main_track_drop_point(t, None);
            work.magnetic_edit(scope(group_ids.clone(), false, MagneticStay::None), ids, |tl, ids| {
                tl.lift_out(&group_ids);
                tl.insert_on_main(&placements, drop, ids) // V1 opens by the clip's own length (no J/L hole)
            })?;
        }
        *self = work;
        Ok(())
    }

    fn put_on_main_track(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let mut work = self.clone();
        let mut picks: Vec<Clip> = clips
            .iter()
            .filter_map(|c| work.find(*c).map(|m| m.clip))
            .filter(|c| c.kind == TrackKind::Video && !work.is_on_main_track(c.id))
            .collect();
        picks.sort_by_key(|c| c.start);
        for c in picks {
            work.drag_onto_main_track(c.id, c.start, true, ids)?;
        }
        *self = work;
        Ok(())
    }

    fn magnetic_clipboard(&self, clips: &BTreeSet<Id>) -> Option<TimelineClipboard> {
        if !self.is_fast_cut() {
            return self.clipboard(clips);
        }
        let mut d = self.clone();
        d.derive_attachments();
        let mut all = clips.clone();
        for id in clips {
            if let Ok(g) = d.linked_group(*id) {
                all.extend(g.iter().map(|m| m.clip.id));
            }
        }
        let hosts: BTreeSet<Id> = all.iter().copied().filter(|c| d.is_on_main_track(*c)).collect();
        all.extend(d.attached_clips_of(&hosts));
        d.clipboard(&all)
    }

    fn magnetic_paste(
        &mut self,
        cb: &TimelineClipboard,
        t: Time,
        attached: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        if !self.is_fast_cut() {
            return self.paste(&cb.stripping_attachments(), t, None, false, ids);
        }
        let cb = if attached { cb.clone() } else { packed_main_entries(cb) };
        let mains: Vec<_> = cb.entries.iter().filter(|e| e.clip.kind == TrackKind::Video && e.lane == 0).collect();
        let span =
            mains.iter().map(|e| e.offset).min().zip(mains.iter().map(|e| e.offset + e.clip.timeline().duration).max());
        let (false, Some((m0, m1))) = (attached, span) else { return paste_attached(self, &cb, t, ids) };
        let at = t.ceiled(self.frame_duration()).max(Time::ZERO).min(self.main_track_end());
        if at - m0 < Time::ZERO {
            return Err(EditError::Collision);
        }
        let mut work = self.clone();
        let made = work.magnetic_edit(MagneticScope::default(), ids, |tl, ids| {
            tl.open_main_hole(at, m1 - m0, ids)?;
            tl.paste(&cb, at - m0, None, false, ids)
        })?;
        *self = work;
        Ok(made)
    }

    fn magnetic_duplicate(&mut self, clips: &BTreeSet<Id>, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError> {
        if !self.is_fast_cut() {
            return self.duplicate(clips, ids);
        }
        let cb = self.magnetic_clipboard(clips).ok_or(EditError::ClipNotFound)?;
        let mains: Vec<Id> = clips.iter().filter_map(|c| self.main_clip_of(*c)).collect();
        let end_of = |list: &mut dyn Iterator<Item = Id>| {
            list.filter_map(|c| self.find(c).map(|m| m.clip.timeline().end())).max().unwrap_or(Time::ZERO)
        };
        if mains.is_empty() {
            let end = end_of(&mut clips.iter().copied());
            return paste_attached(self, &cb, end, ids);
        }
        let end = end_of(&mut mains.iter().copied());
        self.magnetic_paste(&cb, end, false, ids)
    }

    fn magnetic_extract(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        ids: &mut dyn IdSource,
    ) -> Result<(Time, EditOutcome), EditError> {
        let (true, Some(main)) = (self.is_fast_cut(), self.main_track_id()) else {
            return self.extract_outcome(range, tracks, ids);
        };
        if !tracks.contains(&main) {
            let mut work = self.clone();
            // The untargeted main track never gets a hole: the partner rule leaves it alone.
            work.lift_sparing(range, tracks, &[main].into(), true, ids)?;
            work.derive_attachments();
            *self = work;
            return Ok((Time::ZERO, EditOutcome::Applied));
        }
        let targets = self.with_main_partner_tracks(tracks, range);
        let direct = self.clips_off_main(&targets, main);
        let mut work = self.clone();
        // The range is cut out of the targeted tracks, then V1 closes by its whole length (main clips take their linked
        // partners along, `ripple_main`) and the other targeted tracks close by the same amount.
        let r = work.magnetic_edit(scope(direct, false, MagneticStay::None), ids, |tl, ids| {
            tl.lift_sparing(range, &targets, &BTreeSet::new(), false, ids)?;
            let back = Time::ZERO - range.duration;
            let moved = tl.ripple_main_with(range.end(), back, CaptionsInSpan::Cut)?;
            tl.shift_off_main(range.end(), back, &targets, &moved)?;
            if moved.is_empty() {
                // Deliberate delete of the range (as `extract`): captions inside it go.
                tl.close_caption_span(range);
            }
            Ok((range.duration, EditOutcome::Applied))
        })?;
        *self = work;
        Ok(r)
    }

    fn magnetic_clear_range(
        &mut self,
        range: TimeRange,
        tracks: &[Id],
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let (true, Some(main)) = (self.is_fast_cut(), self.main_track_id()) else {
            return self.lift(range, tracks, ids);
        };
        if !tracks.contains(&main) {
            let mut work = self.clone();
            work.lift_sparing(range, tracks, &[main].into(), true, ids)?;
            work.derive_attachments();
            *self = work;
            return Ok(());
        }
        let targets = self.with_main_partner_tracks(tracks, range);
        let direct = self.clips_off_main(&targets, main);
        let mut work = self.clone();
        work.magnetic_edit(scope(direct, false, MagneticStay::All), ids, |tl, ids| tl.lift(range, &targets, ids))?;
        *self = work;
        Ok(())
    }
}

/// Private helpers of the range verbs.
trait RangeHelpers {
    /// `ids` plus the unlocked tracks holding linked audio of main clips under `range`, so V1 and its sound stay in sync.
    fn with_main_partner_tracks(&self, ids: &[Id], range: TimeRange) -> Vec<Id>;
    /// Every clip on the tracks `targets` except the main track.
    fn clips_off_main(&self, targets: &[Id], main: Id) -> BTreeSet<Id>;
}

impl RangeHelpers for Timeline {
    fn with_main_partner_tracks(&self, ids: &[Id], range: TimeRange) -> Vec<Id> {
        let Some(mi) = self.main_track_index() else { return ids.to_vec() };
        let links: BTreeSet<Id> =
            self.tracks[mi].clips().iter().filter(|c| c.timeline().overlaps(&range)).filter_map(|c| c.link).collect();
        let mut out = ids.to_vec();
        for (i, tr) in self.tracks.iter().enumerate() {
            if i != mi
                && !tr.is_locked
                && !out.contains(&tr.id)
                && tr
                    .clips()
                    .iter()
                    .any(|c| c.link.is_some_and(|l| links.contains(&l)) && c.timeline().overlaps(&range))
            {
                out.push(tr.id);
            }
        }
        out
    }

    fn clips_off_main(&self, targets: &[Id], main: Id) -> BTreeSet<Id> {
        self.tracks
            .iter()
            .filter(|t| targets.contains(&t.id) && t.id != main)
            .flat_map(|t| t.clips().iter().map(|c| c.id))
            .collect()
    }
}

/// Pastes `cb` at `t` with every copy placed like an attached clip: its lane when free, else the nearest free track of
/// its kind, never the main track; then attached to the main clip under it.
fn paste_attached(
    tl: &mut Timeline,
    cb: &TimelineClipboard,
    t: Time,
    ids: &mut dyn IdSource,
) -> Result<Vec<Id>, EditError> {
    let mut scratch = tl.clone();
    scratch.set_edit_mode_stored(sq_core_model::TimelineEditMode::Normal);
    for tr in &mut scratch.tracks {
        tr.set_clips(Vec::new());
        tr.transitions = Vec::new();
        tr.is_locked = false;
    }
    let made = scratch.paste(cb, t, None, false, ids)?;
    let mut work = tl.clone();
    work.derive_attachments();
    let set: BTreeSet<Id> = made.iter().copied().collect();
    let stash: Vec<_> = scratch
        .tracks
        .iter()
        .flat_map(|tr| tr.transitions.iter())
        .filter(|tr| [tr.outgoing, tr.incoming].into_iter().flatten().all(|c| set.contains(&c)))
        .cloned()
        .collect();
    let mut copies: Vec<_> = made.iter().filter_map(|c| scratch.find(*c)).collect();
    copies.sort_by_key(|m| m.clip.start);
    for m in copies {
        work.place_attached(m.clip, scratch.tracks[m.track].id, ids)?;
    }
    work.restore_magnetic(&stash);
    work.derive_attachments();
    *tl = work;
    Ok(made)
}

/// `extension Project` of `Timeline+MagneticOps.swift`.
pub trait MagneticNestExt {
    /// Nest (Combine) in Fast Cut: selected main-track clips take their linked partners and the attached clips that lie
    /// entirely inside the selection's span into the nest; the nested clip sits on V1 and keeps the other clips attached.
    /// Normal: `nest`.
    fn magnetic_nest(
        &mut self,
        clips: &[Id],
        timeline: Id,
        name: Option<&str>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError>;
}

impl MagneticNestExt for Project {
    fn magnetic_nest(
        &mut self,
        clips: &[Id],
        timeline: Id,
        name: Option<&str>,
        ids: &mut dyn IdSource,
    ) -> Result<Id, EditError> {
        let ti = self.timelines.iter().position(|t| t.id == timeline).ok_or(EditError::TimelineNotFound)?;
        if !self.timelines[ti].is_fast_cut() {
            return self.nest(clips, timeline, name, ids);
        }
        let mut p = self.clone();
        let mut tl = p.timelines[ti].clone();
        tl.derive_attachments();
        let mut sel: BTreeSet<Id> = clips.iter().copied().collect();
        for id in clips {
            if let Ok(g) = tl.linked_group(*id) {
                sel.extend(g.iter().map(|m| m.clip.id));
            }
        }
        let mains: BTreeSet<Id> = sel.iter().copied().filter(|c| tl.is_on_main_track(*c)).collect();
        let main_clips: Vec<Clip> = mains.iter().filter_map(|c| tl.find(*c).map(|m| m.clip)).collect();
        if let Some((s, e)) =
            main_clips.iter().map(|c| c.start).min().zip(main_clips.iter().map(|c| c.timeline().end()).max())
        {
            let mut by_group: BTreeMap<Id, Vec<Clip>> = BTreeMap::new();
            for id in tl.attached_clips_of(&mains) {
                if let Some(c) = tl.find(id).map(|m| m.clip) {
                    by_group.entry(c.link.unwrap_or(c.id)).or_default().push(c);
                }
            }
            for g in by_group.values().filter(|g| g.iter().all(|c| c.start >= s && c.timeline().end() <= e)) {
                sel.extend(g.iter().map(|c| c.id));
            }
        }
        p.timelines[ti] = tl;
        let seq = p.nest(&sel.into_iter().collect::<Vec<_>>(), timeline, name, ids)?;
        p.timelines[ti].derive_attachments();
        *self = p;
        Ok(seq)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::SlipKeyframes;
    use crate::timeline_magnetic_ops::fixture::*;
    use sq_core_model::Timeline;

    fn attach_time(tl: &Timeline, id: Id) -> Option<f64> {
        tl.find(id).and_then(|m| m.clip.attachment.map(|a| d(m.clip.start + a.point)))
    }

    fn track_of(tl: &Timeline, id: Id) -> Option<usize> {
        tl.find(id).map(|m| m.track)
    }

    // MARK: Delete

    #[test]
    fn delete_main_clip_deletes_its_attached_clips() {
        let mut f = F::new();
        f.tl.magnetic_delete(&[f.c2].into(), false, &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.]]);
        assert!(f.tl.find(f.title).is_none());
        assert_eq!(span(&f.tl, f.music), Some([1., 7.]));
        assert_eq!(host(&f.tl, f.music), Some(f.c1));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn delete_main_clip_keeping_attached_clips() {
        let mut f = F::new();
        f.tl.magnetic_delete(&[f.c2].into(), true, &mut f.ids).unwrap();
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&f.tl, f.title), Some(f.c3));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn delete_first_main_clip_carries_later_attached_clips() {
        let mut f = F::new();
        f.tl.magnetic_delete(&[f.c1].into(), false, &mut f.ids).unwrap();
        assert!(f.tl.find(f.c1a).is_none() && f.tl.find(f.music).is_none());
        assert_eq!(span(&f.tl, f.c2), Some([0., 4.]));
        assert_eq!(span(&f.tl, f.title), Some([0.5, 2.5]));
        assert_eq!(host(&f.tl, f.title), Some(f.c2));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn delete_attached_clip_moves_nothing() {
        let mut f = F::new();
        let before = main_spans(&f.tl);
        f.tl.magnetic_delete(&[f.title].into(), false, &mut f.ids).unwrap();
        assert!(f.tl.find(f.title).is_none());
        assert_eq!(main_spans(&f.tl), before);
        assert_eq!(span(&f.tl, f.music), Some([1., 7.]));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn replace_with_spacer_keeps_attached_clips() {
        let mut f = F::new();
        f.tl.replace_with_spacer(&[f.c2].into(), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [8., 12.]]);
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&f.tl, f.title), Some(f.c1));
        check_invariants(&f.tl, true);
    }

    #[test]
    fn delete_spacer_follows_the_delete_rule() {
        let mut f = F::new();
        f.tl.replace_with_spacer(&[f.c2].into(), &mut f.ids).unwrap();
        let mut keep = f.tl.clone();
        assert_eq!(f.tl.delete_spacer(s(5.0), false, &mut f.ids), Ok(s(4.0)));
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.]]);
        assert!(f.tl.find(f.title).is_none());
        check_invariants(&f.tl, false);
        keep.delete_spacer(s(5.0), true, &mut f.ids).unwrap();
        assert_eq!(span(&keep, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&keep, f.title), Some(f.c3));
        check_invariants(&keep, false);
    }

    #[test]
    fn delete_spacer_keeps_a_caption_inside_the_spacer_and_undo_restores_it() {
        use crate::timeline_magnetic_ops::fixture::{caption_spans, captions};
        let mut f = F::new();
        f.tl.replace_with_spacer(&[f.c2].into(), &mut f.ids).unwrap(); // spacer 4-8
        f.tl.caption_tracks.push(captions(&[(5, 6), (9, 10)]));
        let before = f.tl.clone();
        assert_eq!(f.tl.delete_spacer(s(5.0), false, &mut f.ids), Ok(s(2.0)), "only the 2 s after the caption close");
        assert_eq!(main_spans(&f.tl), [[0., 4.], [6., 10.]]);
        assert_eq!(caption_spans(&f.tl), [[5, 6], [7, 8]], "the caption in the spacer stays, the later one rides");
        assert_ne!(f.tl, before);
        f.tl = before.clone(); // undo = the snapshot taken before the edit
        assert_eq!(caption_spans(&f.tl), [[5, 6], [9, 10]]);
        let mut blocked = before;
        blocked.caption_tracks[0] = captions(&[(5, 8)]);
        assert_eq!(
            blocked.delete_spacer(s(5.0), false, &mut f.ids),
            Ok(Time::ZERO),
            "a caption to the spacer end blocks"
        );
        assert_eq!(main_spans(&blocked), [[0., 4.], [8., 12.]]);
    }

    #[test]
    fn close_gap_at_playhead_deletes_the_spacer() {
        let mut f = F::new();
        f.tl.replace_with_spacer(&[f.c3].into(), &mut f.ids).unwrap(); // trailing: not a hole
        assert_eq!(f.tl.delete_spacer(s(9.0), false, &mut f.ids), Ok(Time::ZERO));
        f.tl.replace_with_spacer(&[f.c1].into(), &mut f.ids).unwrap(); // leading hole 0-4; music attached in it
        f.tl.delete_spacer(s(1.0), false, &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.]]);
        assert!(f.tl.find(f.music).is_none());
        assert_eq!(span(&f.tl, f.title), Some([0.5, 2.5]));
        check_invariants(&f.tl, false);
    }

    // MARK: Trim, roll, slip, slide, nudge

    #[test]
    fn ripple_trim_tail() {
        let mut f = F::new();
        f.tl.magnetic_ripple_trim(f.c1, ClipEdge::Tail, s(-1.0), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 3.], [3., 7.], [7., 11.]]);
        assert_eq!(span(&f.tl, f.c1a), Some([0., 3.]));
        assert_eq!(span(&f.tl, f.title), Some([3.5, 5.5]));
        assert_eq!(span(&f.tl, f.music), Some([1., 7.]));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn ripple_trim_head_keeps_the_content_frame() {
        let mut f = F::new();
        f.tl.magnetic_ripple_trim(f.c2, ClipEdge::Head, s(1.0), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 7.], [7., 11.]]);
        assert_eq!(attach_time(&f.tl, f.title), Some(4.5));
        assert_eq!(span(&f.tl, f.title), Some([3.5, 5.5]));
        assert_eq!(host(&f.tl, f.title), Some(f.c2));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn ripple_trim_head_past_the_point_sticks_to_the_edge() {
        let mut f = F::new();
        f.tl.magnetic_ripple_trim(f.c2, ClipEdge::Head, s(2.0), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 6.], [6., 10.]]);
        assert_eq!(attach_time(&f.tl, f.title), Some(4.0));
        assert_eq!(host(&f.tl, f.title), Some(f.c2));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn ripple_trim_to_playhead() {
        let mut f = F::new();
        f.tl.magnetic_ripple_trim_to_playhead(ClipEdge::Head, s(5.0), None, false, &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 7.], [7., 11.]]);
        assert_eq!(attach_time(&f.tl, f.title), Some(4.5));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn roll_keeps_attached_on_their_frame() {
        let mut f = F::new();
        f.tl.magnetic_roll(f.c1, s(2.0), &mut f.ids).unwrap();
        assert_eq!(span(&f.tl, f.c1), Some([0., 6.]));
        assert_eq!(span(&f.tl, f.c2), Some([6., 8.]));
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&f.tl, f.title), Some(f.c1));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn slip_leaves_attached_in_place() {
        let mut f = F::new();
        f.tl.magnetic_slip(f.c2, s(1.0), SlipKeyframes::FollowContent, &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&f.tl, f.title), Some(f.c2));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn slide_carries_attached_clips() {
        let mut f = F::new();
        f.tl.magnetic_slide(f.c2, s(1.0), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 5.], [5., 9.], [9., 12.]]);
        assert_eq!(span(&f.tl, f.title), Some([5.5, 7.5]));
        assert_eq!(span(&f.tl, f.music), Some([1., 7.]));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn nudge_main_clip_slides_and_attached_clip_moves() {
        let mut f = F::new();
        f.tl.magnetic_nudge(&[f.c2].into(), fd(), &mut f.ids).unwrap();
        let start = |tl: &Timeline, id| tl.find(id).map(|m| m.clip.start);
        assert_eq!(start(&f.tl, f.c2), Some(s(4.0) + fd()));
        assert_eq!(start(&f.tl, f.title), Some(s(4.5) + fd()));
        assert_eq!(start(&f.tl, f.c3), Some(s(8.0) + fd())); // the neighbor trims, its end stays
        assert_eq!(f.tl.find(f.c3).map(|m| m.clip.timeline().end()), Some(s(12.0)));
        check_invariants(&f.tl, false);

        let mut g = F::new();
        g.tl.magnetic_nudge(&[g.title].into(), fd(), &mut g.ids).unwrap();
        assert_eq!(g.tl.find(g.title).map(|m| m.clip.start), Some(s(4.5) + fd()));
        assert_eq!(main_spans(&g.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        check_invariants(&g.tl, false);
    }

    // MARK: Cut and join

    #[test]
    fn add_edit_cuts_the_main_track_only() {
        let mut f = F::new();
        let made = f.tl.magnetic_add_edit(s(5.0), &BTreeSet::new(), &mut f.ids).unwrap();
        assert_eq!(made.len(), 1);
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 5.], [5., 8.], [8., 12.]]);
        assert_eq!(host(&f.tl, f.title), Some(made[0]));
        assert_eq!(f.tl.tracks[3].clips().len(), 1); // music not cut
        check_invariants(&f.tl, false);
    }

    #[test]
    fn add_edit_all_tracks_cuts_attached_clips_too_and_join_rehosts() {
        let mut f = F::new();
        f.tl.magnetic_add_edit_all(s(5.0), &mut f.ids).unwrap();
        assert_eq!(f.tl.tracks[3].clips().len(), 2);
        let right = f.tl.tracks[3].clips()[1].clone();
        assert_eq!(right.attachment.map(|a| a.point), Some(Time::ZERO));
        assert_eq!(host(&f.tl, right.id), Some(main_clips(&f.tl)[2].id)); // c2's right half
        assert_eq!(host(&f.tl, f.music), Some(f.c1));
        check_invariants(&f.tl, false);

        let mut g = F::new();
        g.tl.magnetic_add_edit(s(5.0), &BTreeSet::new(), &mut g.ids).unwrap();
        assert_eq!(g.tl.magnetic_join(None, &mut g.ids), Ok(1));
        assert_eq!(main_spans(&g.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        assert_eq!(host(&g.tl, g.title), Some(g.c2));
        check_invariants(&g.tl, false);
    }

    // MARK: Moving

    #[test]
    fn rearrange_carries_attached_clips() {
        let mut f = F::new();
        let mut keep = f.tl.clone();
        f.tl.magnetic_rearrange(f.c2, s(11.5), false, &mut f.ids).unwrap();
        assert_eq!(span(&f.tl, f.c3), Some([4., 8.]));
        assert_eq!(span(&f.tl, f.c2), Some([8., 12.]));
        assert_eq!(span(&f.tl, f.title), Some([8.5, 10.5]));
        assert_eq!(host(&f.tl, f.title), Some(f.c2));
        assert_eq!(span(&f.tl, f.music), Some([1., 7.]));
        check_invariants(&f.tl, false);
        keep.magnetic_rearrange(f.c2, s(11.5), true, &mut f.ids).unwrap();
        assert_eq!(span(&keep, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&keep, f.title), Some(f.c3));
        check_invariants(&keep, false);
    }

    #[test]
    fn magnetic_move_swaps_with_the_neighbor() {
        let mut f = F::new();
        f.tl.magnetic_move(f.c2, 1, &mut f.ids).unwrap();
        assert_eq!(span(&f.tl, f.c3), Some([4., 8.]));
        assert_eq!(span(&f.tl, f.c2), Some([8., 12.]));
        let before = f.tl.clone();
        f.tl.magnetic_move(f.c2, 1, &mut f.ids).unwrap(); // at the end: nothing happens
        assert_eq!(f.tl, before);
    }

    #[test]
    fn drag_off_main_track() {
        let mut f = F::new();
        let v2 = f.tl.tracks[1].id;
        f.tl.drag_off_main_track(f.c2, v2, s(9.0), false, &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.]]);
        assert_eq!(span(&f.tl, f.c2), Some([9., 13.]));
        assert_eq!(track_of(&f.tl, f.c2), Some(1));
        assert_eq!(span(&f.tl, f.title), Some([9.5, 11.5]));
        assert_ne!(track_of(&f.tl, f.title), Some(1)); // collided with c2: next free track
        assert_eq!(host(&f.tl, f.c2), Some(f.c3));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn drag_onto_main_track_inserts_or_overwrites() {
        let mut f = F::new();
        f.tl.drag_onto_main_track(f.title, s(7.5), false, &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 10.], [10., 14.]]);
        assert_eq!(main_clips(&f.tl)[2].id, f.title);
        assert!(f.tl.find(f.title).is_some_and(|m| m.clip.attachment.is_none()));
        assert_eq!(span(&f.tl, f.music), Some([1., 7.]));
        check_invariants(&f.tl, false);

        let mut g = F::new();
        g.tl.drag_onto_main_track(g.title, s(9.0), true, &mut g.ids).unwrap();
        assert_eq!(main_spans(&g.tl), [[0., 4.], [4., 8.], [8., 9.], [9., 11.], [11., 12.]]);
        check_invariants(&g.tl, false);
    }

    #[test]
    fn move_attached_rehosts() {
        let mut f = F::new();
        f.tl.move_attached(f.title, s(9.0), None, &mut f.ids).unwrap();
        assert_eq!(span(&f.tl, f.title), Some([9., 11.]));
        assert_eq!(host(&f.tl, f.title), Some(f.c3));
        assert_eq!(attach_time(&f.tl, f.title), Some(10.));
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        check_invariants(&f.tl, false);
    }

    #[test]
    fn lift_off_main_track_leaves_a_spacer_and_put_on_main_track_overwrites_in_place() {
        let mut f = F::new();
        f.tl.lift_off_main_track(&[f.c2].into(), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [8., 12.]]);
        assert_eq!(span(&f.tl, f.c2), Some([4., 8.]));
        let t = track_of(&f.tl, f.c2).unwrap();
        assert!(f.tl.tracks[t].kind == TrackKind::Video && t != 0 && t != 1); // V2 is busy with the title
        assert_eq!(host(&f.tl, f.c2), Some(f.c1));
        assert_eq!(host(&f.tl, f.title), Some(f.c1));
        check_invariants(&f.tl, true);

        let mut g = F::new();
        g.tl.put_on_main_track(&[g.title].into(), &mut g.ids).unwrap();
        assert_eq!(main_spans(&g.tl), [[0., 4.], [4., 4.5], [4.5, 6.5], [6.5, 8.], [8., 12.]]);
        assert_eq!(track_of(&g.tl, g.title), Some(0));
        assert!(g.tl.find(g.title).is_some_and(|m| m.clip.attachment.is_none()));
        check_invariants(&g.tl, false);
    }

    #[test]
    fn insert_spacer_and_set_attach_point() {
        let mut f = F::new();
        f.tl.insert_spacer(s(5.0), s(2.0), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 5.], [7., 10.], [10., 14.]]);
        assert_eq!(span(&f.tl, f.title), Some([6.5, 8.5]));
        assert_eq!(host(&f.tl, f.title), Some(main_clips(&f.tl)[2].id));
        assert_eq!(span(&f.tl, f.music), Some([1., 7.]));
        check_invariants(&f.tl, true);

        let mut g = F::new();
        g.tl.set_attach_point(g.title, s(6.0)).unwrap();
        assert_eq!(host(&g.tl, g.title), Some(g.c2));
        assert_eq!(g.tl.find(g.title).and_then(|m| m.clip.attachment).map(|a| a.point), Some(s(1.5)));
        g.tl.set_attach_point(g.music, s(50.0)).unwrap(); // clamped into the clip
        assert_eq!(attach_time(&g.tl, g.music), Some(d(s(7.0) - fd())));
        assert!(g.tl.set_attach_point(g.c1, s(1.0)).is_err());
        g.tl.magnetic_delete(&[g.c3].into(), false, &mut g.ids).unwrap();
        assert!(g.tl.find(g.music).is_some());
        check_invariants(&g.tl, false);
    }

    // MARK: Clipboard, nest, ranges

    #[test]
    fn paste_carries_attached_clips() {
        let mut f = F::new();
        let cb = f.tl.magnetic_clipboard(&[f.c2].into()).unwrap();
        assert_eq!(cb.entries.len(), 2); // the title travels with its host
        let made = f.tl.magnetic_paste(&cb, s(8.0), false, &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.], [12., 16.]]);
        let copies: Vec<Clip> = made.iter().filter_map(|i| f.tl.find(*i).map(|m| m.clip)).collect();
        let host_copy = copies.iter().find(|c| c.attachment.is_none()).unwrap();
        let title_copy = copies.iter().find(|c| c.attachment.is_some()).unwrap();
        assert_eq!([d(title_copy.start), d(title_copy.timeline().end())], [8.5, 10.5]);
        assert_eq!(title_copy.attachment.as_ref().map(|a| a.host), Some(host_copy.id));
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn paste_attached_clips_alone_and_as_attached() {
        let mut f = F::new();
        let cb = f.tl.magnetic_clipboard(&[f.title].into()).unwrap();
        let made = f.tl.magnetic_paste(&cb, s(5.0), false, &mut f.ids).unwrap();
        let c = f.tl.find(made[0]).unwrap();
        assert_eq!([d(c.clip.start), d(c.clip.timeline().end())], [5., 7.]);
        assert_ne!(c.track, 1); // the title is there
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&f.tl, made[0]), Some(f.c2));
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        check_invariants(&f.tl, false);

        let mut g = F::new();
        let cb = g.tl.magnetic_clipboard(&[g.c2].into()).unwrap();
        let made = g.tl.magnetic_paste(&cb, s(9.0), true, &mut g.ids).unwrap();
        assert_eq!(main_spans(&g.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        assert!(made.iter().all(|i| track_of(&g.tl, *i) != Some(0)));
        check_invariants(&g.tl, false);
    }

    #[test]
    fn duplicate_inserts_after_the_selection() {
        let mut f = F::new();
        f.tl.magnetic_duplicate(&[f.c2].into(), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.], [12., 16.]]);
        let third = main_clips(&f.tl)[2].id;
        let hanging =
            f.tl.tracks.iter().flat_map(|t| t.clips()).filter(|c| c.attachment.as_ref().map(|a| a.host) == Some(third));
        assert_eq!(hanging.count(), 1);
        check_invariants(&f.tl, false);
    }

    #[test]
    fn nest_takes_attached_clips_along() {
        let mut f = F::new();
        let tl_id = f.tl.id;
        let mut p = Project::new(f.ids.next_id(), "P", vec![], vec![f.tl.clone()]);
        let seq = p.magnetic_nest(&[f.c2], tl_id, None, &mut f.ids).unwrap();
        let outer = p.timeline(tl_id).unwrap().clone();
        let inner = p.timeline(seq).unwrap().clone();
        assert_eq!(main_spans(&outer), [[0., 4.], [4., 8.], [8., 12.]]);
        assert_eq!(main_clips(&outer)[1].sequence, Some(seq));
        assert!(outer.find(f.title).is_none());
        assert!(inner.find(f.title).is_some());
        assert_eq!(host(&outer, f.music), Some(f.c1));
        check_invariants(&outer, false);
    }

    #[test]
    fn delete_range_slides_attached_to_the_cut_and_clear_range_leaves_a_spacer() {
        let mut f = F::new();
        let v1 = f.tl.tracks[0].id;
        f.tl.magnetic_extract(TimeRange::from_end(s(5.0), s(6.0)), &[v1], &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 5.], [5., 7.], [7., 11.]]);
        assert_eq!(attach_time(&f.tl, f.title), Some(d(s(5.0) - fd()))); // on its host's last frame before the cut
        assert!(f.tl.find(f.title).is_some());
        check_invariants(&f.tl, false);

        let mut g = F::new();
        let v1 = g.tl.tracks[0].id;
        g.tl.magnetic_clear_range(TimeRange::from_end(s(5.0), s(6.0)), &[v1], &mut g.ids).unwrap();
        assert_eq!(main_spans(&g.tl), [[0., 4.], [4., 5.], [6., 8.], [8., 12.]]);
        assert_eq!(span(&g.tl, g.title), Some([4.5, 6.5]));
        assert_eq!(host(&g.tl, g.title), Some(g.c2));
        check_invariants(&g.tl, true);
    }

    #[test]
    fn replace_modes_keep_the_clip_length_and_report_short_media() {
        use crate::timeline_replace_modes::{ReplaceMode, TimelineReplaceModesExt as _};
        let go = |len: f64, mode, playhead: f64, anchor: f64| {
            let mut f = F::new();
            let src = package(&mut f.ids, len, true, true);
            let out = f.tl.replace_on_main_track_mode(f.c2, &src, mode, s(playhead), s(anchor), &mut f.ids).unwrap();
            (f, out)
        };
        let (f, out) = go(6.0, ReplaceMode::FromEnd, 0.0, 0.0);
        assert!(!out.is_short());
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        let c = &main_clips(&f.tl)[1];
        assert_eq!((c.source.start, c.source.end()), (s(2.0), s(6.0)));
        check_invariants(&f.tl, false);

        let (f, out) = go(20.0, ReplaceMode::AtPlayhead, 5.0, 10.0);
        assert!(!out.is_short());
        let c = &main_clips(&f.tl)[1];
        assert_eq!((c.source.start, c.source.end()), (s(9.0), s(13.0)));
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.]]);

        let (f, _) = go(8.0, ReplaceMode::WithRetime, 0.0, 0.0);
        let c = &main_clips(&f.tl)[1];
        assert_eq!((c.source.duration, c.speed), (s(8.0), sq_core_model::ClipSpeed::new(2, 1)));
        assert_eq!(host(&f.tl, f.title), Some(f.c2));
        check_invariants(&f.tl, false);

        let (_, out) = go(3.0, ReplaceMode::FromStart, 0.0, 0.0);
        assert!(out.is_short() && out.short_by == s(1.0) && out.warning().is_some());
        let (_, late) = go(10.0, ReplaceMode::AtPlayhead, 5.0, 0.0);
        assert!(late.is_short());
    }

    // MARK: Captions in the freed span (Fast Cut keeps V1 gapless, so the span closes; a caption in it is kept, not dropped)

    /// c2 (4..8) is trimmed, sped up, stretched or replaced so it ends at `new_end`; the captions lie in the freed tail.
    fn freed_tail_edit(name: &str, new_end: i64, items: &[(i64, i64)]) -> (F, Timeline) {
        use crate::timeline_magnetic_moves::MagneticGesturesExt as _;
        use crate::timeline_speed::SpeedChange;
        use sq_core_model::ClipSpeed;
        let mut f = F::new();
        f.tl.caption_tracks.push(captions(items));
        let before = f.tl.clone();
        let (c2, shorter) = (f.c2, Time::new(new_end - 8, 1));
        match name {
            "trim" => {
                f.tl.magnetic_ripple_trim(c2, ClipEdge::Tail, shorter, &mut f.ids).unwrap();
            }
            "stretch" => {
                f.tl.magnetic_rate_stretch(c2, ClipEdge::Tail, shorter, &mut f.ids).unwrap();
            }
            "speed" => {
                let change = SpeedChange { speed: Some(ClipSpeed::new(4, new_end - 4)), ..Default::default() };
                f.tl.magnetic_apply(&change, &[c2], &mut f.ids).unwrap();
            }
            _ => {
                let src = package(&mut f.ids, (new_end - 4) as f64, true, true);
                f.tl.replace_on_main_track(c2, &src, false, &mut f.ids).unwrap();
            }
        }
        (f, before)
    }

    #[test]
    fn a_caption_in_the_freed_tail_is_kept_and_pulled_in_by_every_fast_cut_edit() {
        // c2 shrinks to 4..6: the 2 s tail 6..8 closes; the caption at 7..8 lies in it, 9..10 rides along.
        for name in ["trim", "stretch", "speed", "replace"] {
            let (f, before) = freed_tail_edit(name, 6, &[(7, 8), (9, 10)]);
            assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 6.], [6., 10.]], "{name}");
            assert_eq!(caption_spans(&f.tl), [[6, 7], [7, 8]], "{name}: kept at the new end, the later one rides");
            check_invariants(&f.tl, false);
            assert_eq!(caption_spans(&before), [[7, 8], [9, 10]], "{name}: undo (the snapshot) has them back");
        }
    }

    #[test]
    fn captions_pulled_into_one_point_stack_and_the_earlier_one_yields() {
        // Trim c2 to 4..5: the tail 5..8 closes. 5..7 and 6..8 both lie in it, 9..10 rides to 6..7.
        let (f, _) = freed_tail_edit("trim", 5, &[(5, 7), (6, 8), (9, 10)]);
        assert_eq!(caption_spans(&f.tl), [[5, 7], [7, 9], [9, 10]], "stacked in order, none dropped");
        let (g, _) = freed_tail_edit("trim", 5, &[(6, 8), (9, 10)]);
        assert_eq!(caption_spans(&g.tl), [[5, 6], [6, 7]], "pulled to 5..7, the rider at 6 makes it yield");
    }

    #[test]
    fn closing_a_main_hole_keeps_the_captions_in_it() {
        use crate::timeline_magnetic_moves::MagneticGesturesExt as _;
        let mut f = F::new();
        f.tl.caption_tracks.push(captions(&[(5, 6), (9, 10)]));
        f.tl.tracks[0].remove(f.c2); // hole 4..8 on V1
        f.tl.close_main_holes().unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.]]);
        assert_eq!(caption_spans(&f.tl), [[4, 5], [5, 6]]);
    }

    #[test]
    fn deleting_the_clip_still_cuts_its_captions_out() {
        let mut f = F::new();
        f.tl.caption_tracks.push(captions(&[(5, 6), (9, 10)]));
        let hosts: BTreeSet<Id> = [f.c2].into();
        f.tl.magnetic_edit(MagneticScope::default(), &mut f.ids, |tl, _| tl.ripple_delete_main(&hosts)).unwrap();
        assert_eq!(caption_spans(&f.tl), [[5, 6]], "the caption of the deleted range goes, the later one rides");
    }
}
