//! Port of `Timeline+MagneticOps.swift`: the Fast Cut verbs that run through `magnetic_edit` and need nothing from the
//! other edit groups. Each verb works on a copy: an error changes nothing, and one call is one undo step for the caller.
//!
//! Fast Cut invariants every verb keeps: the main track (V1) never gets a hole except through the spacer verbs; attached
//! clips never overwrite or get overwritten (a collision sends one to the nearest free track); linked groups keep their
//! internal offsets (J/L cuts).

use crate::timeline_add_track::AddTrackExt;
use crate::timeline_magnetic::{MagneticExt, MagneticScope, MagneticStay};
use sq_core_model::{
    Clip, ClipAttachment, ClipEdge, EditError, Member, ThreePointMode, Timeline, TimelineEditMode, Track, TrackKind,
    clear_main_track_attachments, floored_to_frame,
};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::{BTreeMap, BTreeSet};

/// A clip and the track it goes on.
pub type Placement = (Clip, Id);

/// What a Fast Cut ripple does with the captions inside the span it closes.
#[doc(hidden)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptionsInSpan {
    /// Pulled in to the span start with their duration (a trim, speed change, replace or hole close deletes nothing).
    Keep,
    /// Cut out with the span (the user deleted exactly that range or clip).
    Cut,
}

/// `extension Timeline` of `Timeline+MagneticOps.swift`.
pub trait MagneticOpsExt {
    // MARK: Queries

    /// True in a Fast Cut sequence that has a main track (the first video track).
    fn is_fast_cut(&self) -> bool;
    /// True when `id` is on the main track.
    fn is_on_main_track(&self, id: Id) -> bool;
    /// True when `id` belongs to the main track: on it, or linked to a clip on it (camera audio).
    fn is_main_material(&self, id: Id) -> bool;
    /// The main-track clip of `id`: itself on the main track, its linked main clip for camera audio, `None` otherwise.
    fn main_clip_of(&self, id: Id) -> Option<Id>;
    /// The clips attached to `hosts` (attachments derived from the positions first), linked partners included.
    fn attached_clips_of(&self, hosts: &BTreeSet<Id>) -> Vec<Id>;
    /// Where a main-track clip dropped at `t` goes: the nearest edit of the main track (`moving`'s own edges left out),
    /// so a rearrange never cuts a clip in two. `t` itself when there is none.
    fn main_track_drop_point(&self, t: Time, moving: Option<Id>) -> Time;
    /// End of the main track (its last clip's end), zero when empty or missing.
    fn main_track_end(&self) -> Time;

    // MARK: Building blocks

    /// Opens a hole of `d` at `t` on the main track: the main clip under `t` (with its linked partners running through
    /// `t`) is cut, every main clip from `t` on moves right with its linked partners (`ripple_main`). Captions open too.
    /// Normal: V1 and every sync-locked track are cut at `t` and open from there.
    #[doc(hidden)]
    fn open_main_hole(&mut self, t: Time, d: Time, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Fast Cut placement of material that lands in a hole just opened on the main track: main-track clips overwrite
    /// (the hole is theirs), the others go on their track when free, else the nearest free track of their kind.
    #[doc(hidden)]
    fn place_in_main_hole(&mut self, placements: &[Placement], ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Fast Cut insert of `placements` at `t` (their relative offsets kept; the main-track ones start at `t`): V1 opens
    /// by the main-track material's length, the rest never cuts anything (`place_in_main_hole`).
    #[doc(hidden)]
    fn insert_on_main(&mut self, placements: &[Placement], t: Time, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Fast Cut rearrange: `id` (a main-track clip) and its linked partners leave V1 (it closes by the clip's length) and
    /// go in at `drop` (pre-edit time, a V1 edit), V1 opening by the same length; partners keep their offsets (J/L).
    #[doc(hidden)]
    fn rearrange_main(&mut self, id: Id, drop: Time, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Fast Cut ripple: the main-track clips starting at or after `pivot` move by `d`, each with its linked partners on
    /// the other tracks wherever those start (a J cut's early audio goes along), so V1 closes or opens by exactly `d`
    /// and no pair is pulled apart. Fails with `TrackLocked` when a clip to move is on a locked track, `Collision` when
    /// the result overlaps. Captions, markers and In/Out follow; a caption in a span that closes is kept (pulled in to its
    /// start, `Timeline::close_caption_span_keeping`), because V1 must close whatever lies on the captions. Returns the
    /// moved ids.
    #[doc(hidden)]
    fn ripple_main(&mut self, pivot: Time, d: Time) -> Result<BTreeSet<Id>, EditError> {
        self.ripple_main_with(pivot, d, CaptionsInSpan::Keep)
    }
    /// `ripple_main` with the choice what happens to the captions inside a span that closes.
    #[doc(hidden)]
    fn ripple_main_with(&mut self, pivot: Time, d: Time, captions: CaptionsInSpan) -> Result<BTreeSet<Id>, EditError>;
    /// Shifts the clips at or after `pivot` on the given tracks (off V1, not in `moved`) by `d`, each with its linked
    /// partners on the other tracks off V1, so no pair is pulled apart; a link whose V1 partner did not move stays.
    /// Fails with `TrackLocked` when a clip to move is on a locked track, `Collision` when the result overlaps.
    #[doc(hidden)]
    fn shift_off_main(&mut self, pivot: Time, d: Time, tracks: &[Id], moved: &BTreeSet<Id>) -> Result<(), EditError>;
    /// Fast Cut ripple delete of main-track clips: each goes with its linked partners and V1 closes by the main clip's
    /// own length (not the group's span: J/L cuts and trimmed audio never leave a hole), later clips taking their
    /// partners along (`ripple_main`). Right to left. Returns the time closed.
    #[doc(hidden)]
    fn ripple_delete_main(&mut self, ids: &BTreeSet<Id>) -> Result<Time, EditError>;
    /// Fast Cut ripple trim of a main-track clip (head + = shorter, tail + = longer; the clip's start stays). V1 ripples
    /// from the clip's end by the change (`ripple_main`: later main clips take their partners along, earlier pairs stay).
    /// A head trim trims every linked partner (content stays in sync, starts stay, so J/L offsets hold); a tail trim
    /// only the partners ending with the clip (a J/L tail stays). Clamped by the media and, when lengthening, by the
    /// next clip that does not move on a partner's track. Returns how far the edge moved.
    #[doc(hidden)]
    fn ripple_trim_main(&mut self, id: Id, edge: ClipEdge, delta: Time) -> Result<Time, EditError>;
    /// Cuts the main clip strictly under `t` and those of its linked partners that run through `t` (the right halves
    /// share a fresh link). Nothing when `t` is on an edit.
    #[doc(hidden)]
    fn split_main(&mut self, t: Time, ids: &mut dyn IdSource) -> Result<(), EditError>;
    /// Places a new clip off the main track without covering anything: the lowest free unlocked track of its kind (for
    /// audio not the first audio track, which carries the main track's sound), else a new track.
    #[doc(hidden)]
    fn place_new(&mut self, c: Clip, ids: &mut dyn IdSource) -> Result<(), EditError>;

    // MARK: Source edits

    /// Append to Main Track (E): after the last main-track clip. Audio-only sources attach at `playhead` instead.
    /// Normal: an insert at the end of V1. Returns the new clip ids.
    fn append_to_main_track(
        &mut self,
        clips: &[Clip],
        playhead: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;
    /// Insert (W): the clips go onto the main track at `t` (cut there, everything later ripples; attached clips stay
    /// with their content). Video on V1, audio on the first audio track, linked as given. Fast Cut: `t` past the end of
    /// V1 is its end (no hole); audio-only sources attach. Normal: `insert` on the targeted tracks. Returns the new ids.
    fn insert_on_main_track(&mut self, clips: &[Clip], t: Time, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError>;
    /// Overwrite (D): the clips cover the main track from `t`; nothing ripples, attached clips stay on their frame and
    /// re-attach to whatever is under them now. Fast Cut: `t` past the end of V1 is its end; audio-only sources attach.
    /// Normal: `overwrite` on the targeted tracks.
    fn overwrite_on_main_track(
        &mut self,
        clips: &[Clip],
        t: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;
    /// Attach (Q, "Place on Top"): the clips go above (video) / below (audio, never on the first audio track) the main
    /// track at `t`, on the lowest free track (a new one when none is free), attached at their first frame to the main
    /// clip under `t`. `backtimed` (Shift+Q): they end at `t` and attach at their last frame. Keeps the clips' links and
    /// relative offsets. Normal: the same placement without attachments. Returns the new clip ids.
    fn attach(
        &mut self,
        clips: &[Clip],
        t: Time,
        backtimed: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;
    /// A source edit in Fast Cut (three-point edit from the Source monitor or the Project panel, a placed sequence): with
    /// the main track among the targets the clips go onto it (`insert_on_main_track` / `overwrite_on_main_track`: V1
    /// never gets a hole, attached clips follow or stay); otherwise they attach on the targeted tracks
    /// (`attach_on_tracks`: Place on Top, a source patched above V1). Returns the end of the placed clips.
    #[doc(hidden)]
    fn fast_cut_source_edit(
        &mut self,
        placements: &[Placement],
        t: Time,
        mode: ThreePointMode,
        backtimed: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError>;
    /// Attach on chosen tracks: the clips land at `t` (keeping their offsets), each on its track when free there, else on
    /// the nearest free track of its kind (never the main track, a new track when none is free), attached at `t` to the
    /// main clip under it. Nothing is covered and nothing moves. Fast Cut only (callers check). `backtimed` (Attach
    /// Backtimed): `t` is where the run ENDS (as in `attach`), the head is cut when there is no room before 0, and it
    /// attaches at its last frame. Returns the clip ids.
    fn attach_on_tracks(
        &mut self,
        placements: &[Placement],
        t: Time,
        backtimed: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError>;
    /// Replace (drop onto a main clip): `id` (a main-track clip) plays the first video of `clips` instead and keeps its
    /// id, so its attached clips stay attached. `keep_length` (Replace from Start): the new clip is as long as the old
    /// one (shorter sources keep their own length); else (Replace) it has the source length and everything later
    /// ripples. The old clip's linked partners go; audio of `clips` goes on the first audio track, linked with the video.
    fn replace_on_main_track(
        &mut self,
        id: Id,
        clips: &[Clip],
        keep_length: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError>;

    /// Insert Spacer (Ctrl+W): a hole of `duration` at `t` on the main track; everything later ripples with its attached
    /// clips. Normal: the same hole on V1 and the sync-locked tracks.
    fn insert_spacer(&mut self, t: Time, duration: Time, ids: &mut dyn IdSource) -> Result<(), EditError>;

    // MARK: Slide

    /// Slides the main-track clips `ids` by `delta`: each run of adjacent ones moves as one block with its linked
    /// partners (`slide_block`), later runs first when moving right. Returns the delta applied to the last run.
    #[doc(hidden)]
    fn slide_main_runs(&mut self, ids: &BTreeSet<Id>, delta: Time) -> Result<Time, EditError>;
    /// Slide of several clips as one block: per track, the block's members (the clips and their linked partners) move
    /// by `delta` with their content; the clip ending at the block's start gets its tail moved, the clip starting at
    /// its end its head (a neighbor across a gap is not edited, the gap changes). Clamped like `slide` (neighbors keep
    /// a frame, media handles, gaps, time 0). `hold_main_head`: a block on the main track with no clip right before it
    /// cannot move right (no hole at the head of V1). Returns the applied delta.
    #[doc(hidden)]
    fn slide_block(&mut self, ids: &[Id], delta: Time, hold_main_head: bool) -> Result<Time, EditError>;

    // MARK: Attach point

    /// Set Attach Point (Cmd+Opt+click): the clip (with its linked partners off V1) attaches at `t` (clamped into the
    /// clip, its last frame at most) to the main clip under `t`. A main-track clip fails with `WrongTrackKind`.
    fn set_attach_point(&mut self, id: Id, t: Time) -> Result<(), EditError>;
}

/// Source clips as placements: video on the main track, audio on the first audio track (made when missing).
fn source_placements(tl: &mut Timeline, clips: &[Clip], ids: &mut dyn IdSource) -> Result<Vec<Placement>, EditError> {
    let main = tl.main_track_id().ok_or(EditError::WrongTrackKind)?;
    let mut out = Vec::new();
    for c in clips {
        let mut c = c.clone();
        c.attachment = None;
        let track = match c.kind {
            TrackKind::Video => main,
            TrackKind::Audio => match tl.tracks.iter().find(|t| t.kind == TrackKind::Audio) {
                Some(t) => t.id,
                None => tl.add_track(TrackKind::Audio, ids),
            },
        };
        out.push((c, track));
    }
    Ok(out)
}

/// Normal source edit placements: video on the lowest targeted video track, audio on the lowest targeted audio track
/// (the first track of the kind when none is targeted; made when missing), like a Normal insert / overwrite.
fn targeted_placements(tl: &mut Timeline, clips: &[Clip], ids: &mut dyn IdSource) -> Vec<Placement> {
    let mut out = Vec::new();
    for c in clips {
        let track = match tl.tracks.iter().find(|t| t.kind == c.kind && t.is_targeted).map(|t| t.id) {
            Some(t) => t,
            None => match tl.tracks.iter().find(|t| t.kind == c.kind).map(|t| t.id) {
                Some(t) => t,
                None => tl.add_track(c.kind, ids),
            },
        };
        out.push((c.clone(), track));
    }
    out
}

/// Positions a run of clips (offsets relative to `first`, `length` long). Forward: it starts at `t`. `backtimed`: `t`
/// is where it ENDS; with no room before the sequence start the head is cut so it starts at 0 and still ends at `t`
/// (the back-time rule of `Timeline.sourceEditPlan`). The returned time is the attach time: the first frame, backtimed
/// the last frame.
pub(crate) fn place_run<T: Clone>(
    items: &[(Clip, T)],
    first: Time,
    length: Time,
    t: Time,
    backtimed: bool,
    frame: Time,
) -> Result<(Vec<(Clip, T)>, Time), EditError> {
    if t < Time::ZERO {
        return Err(EditError::Collision);
    }
    if !backtimed {
        let moved = items
            .iter()
            .map(|(c, tag)| {
                let mut c = c.clone();
                c.start = t + (c.start - first);
                (c, tag.clone())
            })
            .collect();
        return Ok((moved, t));
    }
    if t <= Time::ZERO {
        return Err(EditError::EmptyClip);
    }
    let run_start = t - length;
    let mut out = Vec::new();
    for (c0, tag) in items {
        let mut c = c0.clone();
        c.start = run_start + (c0.start - first);
        if run_start < Time::ZERO {
            let Some(cut) = c.cropped(TimeRange::from_end(Time::ZERO, t)) else { continue };
            c = cut;
        }
        out.push((c, tag.clone()));
    }
    if out.is_empty() {
        return Err(EditError::EmptyClip);
    }
    Ok((out, (t - frame).max(run_start.max(Time::ZERO))))
}

impl MagneticOpsExt for Timeline {
    fn is_fast_cut(&self) -> bool {
        self.edit_mode() == TimelineEditMode::Magnetic && self.main_track_index().is_some()
    }

    fn is_on_main_track(&self, id: Id) -> bool {
        self.main_track_index().is_some_and(|mi| self.tracks[mi].clip(id).is_some())
    }

    fn is_main_material(&self, id: Id) -> bool {
        self.find(id).is_some() && self.main_track_index().is_some() && !self.is_attachable(id)
    }

    fn main_clip_of(&self, id: Id) -> Option<Id> {
        let mi = self.main_track_index()?;
        let c = self.find(id)?.clip;
        if self.tracks[mi].clip(id).is_some() {
            return Some(id);
        }
        let l = c.link?;
        self.tracks[mi].clips().iter().find(|x| x.link == Some(l)).map(|x| x.id)
    }

    fn attached_clips_of(&self, hosts: &BTreeSet<Id>) -> Vec<Id> {
        let mut d = self.clone();
        d.derive_attachments();
        d.tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|c| c.attachment.as_ref().is_some_and(|a| hosts.contains(&a.host)))
            .map(|c| c.id)
            .collect()
    }

    fn main_track_drop_point(&self, t: Time, moving: Option<Id>) -> Time {
        let Some(mi) = self.main_track_index() else { return t };
        let edges =
            self.tracks[mi].clips().iter().filter(|c| Some(c.id) != moving).flat_map(|c| [c.start, c.timeline().end()]);
        nearest_edge(edges, t).unwrap_or(t)
    }

    fn main_track_end(&self) -> Time {
        self.main_track_index().map_or(Time::ZERO, |mi| self.tracks[mi].end())
    }

    fn open_main_hole(&mut self, t: Time, d: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let Some(mi) = self.main_track_index() else { return Ok(()) };
        if d <= Time::ZERO {
            return Ok(());
        }
        if self.tracks[mi].is_locked {
            return Err(EditError::TrackLocked);
        }
        if !self.is_fast_cut() {
            let mut work = self.tracks.clone();
            let mut relinks = BTreeMap::new();
            for (i, track) in work.iter_mut().enumerate() {
                if i == mi || track.follows_ripple() {
                    track.split_relinking(t, &mut relinks, ids)?;
                    track.shift(t, d, &BTreeSet::new());
                }
            }
            if !work.iter().all(Track::is_consistent) {
                return Err(EditError::Collision);
            }
            self.tracks = work;
            self.open_caption_gap(t, d);
            return Ok(());
        }
        let mut work = self.clone();
        work.split_main(t, ids)?;
        work.ripple_main(t, d)?;
        *self = work;
        Ok(())
    }

    fn place_in_main_hole(&mut self, placements: &[Placement], ids: &mut dyn IdSource) -> Result<(), EditError> {
        let main = self.main_track_id().ok_or(EditError::WrongTrackKind)?;
        let mut sorted = placements.to_vec();
        sorted.sort_by_key(|p| p.0.start);
        for (clip, track) in sorted {
            if clip.start < Time::ZERO {
                return Err(EditError::Collision);
            }
            if track == main {
                let i = self.tracks.iter().position(|t| t.id == main).ok_or(EditError::ClipNotFound)?;
                self.tracks[i].overwrite(clip, ids)?;
            } else {
                self.place_attached(clip, track, ids)?;
            }
        }
        clear_main_track_attachments(&mut self.tracks);
        Ok(())
    }

    fn insert_on_main(&mut self, placements: &[Placement], t: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let main = self.main_track_id().ok_or(EditError::WrongTrackKind)?;
        let on_main: Vec<&Clip> = placements.iter().filter(|p| p.1 == main).map(|p| &p.0).collect();
        let (Some(lo), Some(hi)) =
            (on_main.iter().map(|c| c.start).min(), on_main.iter().map(|c| c.timeline().end()).max())
        else {
            return Err(EditError::WrongTrackKind);
        };
        self.open_main_hole(t, hi - lo, ids)?;
        let moved: Vec<Placement> = placements
            .iter()
            .map(|(c, track)| {
                let mut c = c.clone();
                c.start = t + (c.start - lo);
                (c, *track)
            })
            .collect();
        self.place_in_main_hole(&moved, ids)
    }

    fn rearrange_main(&mut self, id: Id, drop: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let mi = self.main_track_index().ok_or(EditError::ClipNotFound)?;
        let v = self.tracks[mi].clip(id).ok_or(EditError::ClipNotFound)?.clone();
        let group = self.linked_group(id)?;
        let homes: Vec<Id> = group.iter().map(|m| self.tracks[m.track].id).collect();
        let mut work = self.clone();
        work.ripple_delete_main(&[id].into())?;
        let at = if drop >= v.timeline().end() { drop - v.timeline().duration } else { drop.min(v.start) };
        work.open_main_hole(at, v.timeline().duration, ids)?;
        let placements: Vec<Placement> = group
            .iter()
            .zip(homes)
            .map(|(m, home)| {
                let mut c = m.clip.clone();
                c.start = at + (c.start - v.start);
                (c, home)
            })
            .collect();
        work.place_in_main_hole(&placements, ids)?;
        *self = work;
        Ok(())
    }

    // The Fast Cut main track stays gapless, so a closing `d` always closes. A caption inside the closed span is kept
    // (trims, speed changes, replace, hole closing) unless the caller deletes the span on purpose (`CaptionsInSpan::Cut`).
    // A spacer delete limits `d` first.
    fn ripple_main_with(&mut self, pivot: Time, d: Time, captions: CaptionsInSpan) -> Result<BTreeSet<Id>, EditError> {
        let Some(mi) = self.main_track_index().filter(|_| d != Time::ZERO) else { return Ok(BTreeSet::new()) };
        let main = self.tracks[mi].clips();
        let movers: Vec<&Clip> = main.iter().filter(|c| c.start >= pivot).collect();
        if movers.is_empty() {
            return Ok(BTreeSet::new());
        }
        let links: BTreeSet<Id> = movers.iter().filter_map(|c| c.link).collect();
        // A link with main clips on both sides of the pivot (rare): only its partners from the pivot on move.
        let before: BTreeSet<Id> = main.iter().filter(|c| c.start < pivot).filter_map(|c| c.link).collect();
        let split: BTreeSet<Id> = links.intersection(&before).copied().collect();
        let follows = |c: &Clip| match c.link {
            Some(l) if links.contains(&l) => !split.contains(&l) || c.start >= pivot,
            _ => false,
        };
        let mut moved: BTreeSet<Id> = movers.iter().map(|c| c.id).collect();
        let mut work = self.tracks.clone();
        for (i, track) in work.iter_mut().enumerate() {
            let mut changed = false;
            let mut clips = Vec::new();
            for c in track.clips() {
                let moves = if i == mi { c.start >= pivot } else { follows(c) };
                if !moves {
                    clips.push(c.clone());
                    continue;
                }
                changed = true;
                moved.insert(c.id);
                let mut n = c.clone();
                n.start += d;
                clips.push(n);
            }
            if changed {
                if track.is_locked {
                    return Err(EditError::TrackLocked);
                }
                if clips.iter().any(|c| c.start < Time::ZERO) {
                    return Err(EditError::Collision);
                }
                track.set_clips(clips);
            }
        }
        if !work.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        if d < Time::ZERO {
            let span = TimeRange::new(pivot + d, -d);
            match captions {
                CaptionsInSpan::Keep => self.close_caption_span_keeping(span),
                CaptionsInSpan::Cut => self.close_caption_span(span),
            }
        } else {
            self.open_caption_gap(pivot, d);
        }
        Ok(moved)
    }

    fn shift_off_main(&mut self, pivot: Time, d: Time, tracks: &[Id], moved: &BTreeSet<Id>) -> Result<(), EditError> {
        let Some(mi) = self.main_track_index().filter(|_| d != Time::ZERO) else { return Ok(()) };
        let staying_links: BTreeSet<Id> =
            self.tracks[mi].clips().iter().filter(|c| !moved.contains(&c.id)).filter_map(|c| c.link).collect();
        let mut links = BTreeSet::new();
        let mut single = BTreeSet::new();
        for t in self.tracks.iter().enumerate().filter(|(i, _)| *i != mi).map(|(_, t)| t) {
            if !tracks.contains(&t.id) {
                continue;
            }
            for c in t.clips().iter().filter(|c| c.start >= pivot && !moved.contains(&c.id)) {
                match c.link {
                    Some(l) => {
                        if !staying_links.contains(&l) {
                            links.insert(l);
                        }
                    }
                    None => {
                        single.insert(c.id);
                    }
                }
            }
        }
        if links.is_empty() && single.is_empty() {
            return Ok(());
        }
        let mut work = self.tracks.clone();
        for i in (0..work.len()).filter(|&i| i != mi) {
            let mut changed = false;
            let mut clips = Vec::new();
            for c in work[i].clips() {
                let shifts =
                    !moved.contains(&c.id) && (single.contains(&c.id) || c.link.is_some_and(|l| links.contains(&l)));
                if !shifts {
                    clips.push(c.clone());
                    continue;
                }
                changed = true;
                let mut n = c.clone();
                n.start += d;
                clips.push(n);
            }
            if changed {
                if work[i].is_locked {
                    return Err(EditError::TrackLocked);
                }
                if clips.iter().any(|c| c.start < Time::ZERO) {
                    return Err(EditError::Collision);
                }
                work[i].set_clips(clips);
            }
        }
        if !work.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        Ok(())
    }

    fn ripple_delete_main(&mut self, ids: &BTreeSet<Id>) -> Result<Time, EditError> {
        let mi = self.main_track_index().ok_or(EditError::WrongTrackKind)?;
        let mut work = self.clone();
        let mut closed = Time::ZERO;
        let mut doomed: Vec<Clip> = self.tracks[mi].clips().iter().filter(|c| ids.contains(&c.id)).cloned().collect();
        doomed.sort_by_key(|c| std::cmp::Reverse(c.start));
        for c in doomed {
            let group = work.linked_group(c.id)?;
            if group.iter().any(|m| work.tracks[m.track].is_locked) {
                return Err(EditError::TrackLocked);
            }
            for m in &group {
                work.tracks[m.track].remove(m.clip.id);
            }
            work.ripple_main_with(c.timeline().end(), -c.timeline().duration, CaptionsInSpan::Cut)?;
            closed += c.timeline().duration;
        }
        work.prune_transitions();
        *self = work;
        Ok(closed)
    }

    fn ripple_trim_main(&mut self, id: Id, edge: ClipEdge, delta: Time) -> Result<Time, EditError> {
        let mi = self.main_track_index().ok_or(EditError::ClipNotFound)?;
        let v = self.tracks[mi].clip(id).ok_or(EditError::ClipNotFound)?.clone();
        let group = self.linked_group(id)?;
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let trimmed: Vec<&Member> =
            group.iter().filter(|m| edge == ClipEdge::Head || m.clip.timeline().end() == v.timeline().end()).collect();
        let trimmed_ids: BTreeSet<Id> = trimmed.iter().map(|m| m.clip.id).collect();
        let fd = self.frame_duration();
        let mut g = if edge == ClipEdge::Tail { delta } else { -delta }; // change of duration
        for m in &trimmed {
            g = m.clip.clamping_shortening(g, fd);
            if g <= -m.clip.duration() {
                return Err(EditError::EmptyClip);
            }
            let room = if edge == ClipEdge::Tail { m.clip.tail_room() } else { m.clip.head_handle() }
                .map(|r| floored_to_frame(r, fd));
            if let Some(room) = room
                && g > room
            {
                g = room.max(Time::ZERO);
            }
        }
        let pivot = v.timeline().end();
        if g > Time::ZERO {
            let mut probe = self.clone();
            let movers = probe.ripple_main(pivot, g)?;
            for m in trimmed.iter().filter(|m| m.track != mi) {
                let end = m.clip.timeline().end();
                let next = self.tracks[m.track]
                    .clips()
                    .iter()
                    .filter(|c| !trimmed_ids.contains(&c.id) && !movers.contains(&c.id) && c.start >= end)
                    .map(|c| c.start)
                    .min();
                if let Some(n) = next
                    && g > n - end
                {
                    g = n - end;
                }
            }
        }
        if g == Time::ZERO {
            return Ok(Time::ZERO);
        }
        let mut work = self.clone();
        if g > Time::ZERO {
            work.ripple_main(pivot, g)?;
        }
        for m in &trimmed {
            let mut c = m.clip.clone();
            if edge == ClipEdge::Head {
                c.extend_head(g);
            } else {
                c.extend_tail(g);
            }
            work.tracks[m.track].replace(c);
        }
        if g < Time::ZERO {
            work.ripple_main(pivot, g)?;
        }
        if !work.tracks.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        *self = work;
        Ok(if edge == ClipEdge::Tail { g } else { -g })
    }

    fn split_main(&mut self, t: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let Some(mi) = self.main_track_index() else { return Ok(()) };
        let Some(under) =
            self.tracks[mi].clips().iter().find(|c| c.start < t && c.timeline().contains(t)).map(|c| c.id)
        else {
            return Ok(());
        };
        let group = self.linked_group(under)?;
        if group.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let mut relinks = BTreeMap::new();
        let mut work = self.tracks.clone();
        for m in group.iter().filter(|m| m.clip.start < t && m.clip.timeline().contains(t)) {
            work[m.track].split_relinking(t, &mut relinks, ids)?;
        }
        self.tracks = work;
        Ok(())
    }

    fn place_new(&mut self, c: Clip, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let mi = self.main_track_index();
        let first_audio = self.tracks.iter().position(|t| t.kind == TrackKind::Audio);
        let range = c.timeline();
        let free = (0..self.tracks.len()).find(|&i| {
            let t = &self.tracks[i];
            t.kind == c.kind
                && Some(i) != mi
                && !t.is_locked
                && (c.kind == TrackKind::Video || Some(i) != first_audio)
                && !t.clips().iter().any(|x| x.timeline().overlaps(&range))
        });
        if let Some(i) = free {
            return self.tracks[i].overwrite(c, ids);
        }
        self.add_track(c.kind, ids);
        let last = self.tracks.len() - 1;
        self.tracks[last].overwrite(c, ids)
    }

    fn append_to_main_track(
        &mut self,
        clips: &[Clip],
        playhead: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        if self.is_fast_cut() && !clips.iter().any(|c| c.kind == TrackKind::Video) {
            return self.attach(clips, playhead, false, ids);
        }
        let end = self.main_track_end();
        self.insert_on_main_track(clips, end, ids)
    }

    fn insert_on_main_track(&mut self, clips: &[Clip], t: Time, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError> {
        if clips.is_empty() {
            return Err(EditError::EmptyClip);
        }
        if !self.is_fast_cut() {
            let mut work = self.clone();
            let p = targeted_placements(&mut work, clips, ids);
            work.insert(&p, t, ids)?;
            *self = work;
            return Ok(clips.iter().map(|c| c.id).collect());
        }
        if !clips.iter().any(|c| c.kind == TrackKind::Video) {
            return self.attach(clips, t, false, ids);
        }
        let mut work = self.clone();
        let at = t.max(Time::ZERO).min(self.main_track_end());
        let p = source_placements(&mut work, clips, ids)?;
        work.magnetic_edit(MagneticScope::default(), ids, |tl, ids| tl.insert_on_main(&p, at, ids))?;
        *self = work;
        Ok(p.iter().map(|x| x.0.id).collect())
    }

    fn overwrite_on_main_track(
        &mut self,
        clips: &[Clip],
        t: Time,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        if clips.is_empty() {
            return Err(EditError::EmptyClip);
        }
        if !self.is_fast_cut() {
            let mut work = self.clone();
            let p = targeted_placements(&mut work, clips, ids);
            work.overwrite(&p, t, ids)?;
            *self = work;
            return Ok(clips.iter().map(|c| c.id).collect());
        }
        if !clips.iter().any(|c| c.kind == TrackKind::Video) {
            return self.attach(clips, t, false, ids);
        }
        let mut work = self.clone();
        let at = t.max(Time::ZERO).min(self.main_track_end());
        let p = source_placements(&mut work, clips, ids)?;
        let scope = MagneticScope { stay: MagneticStay::All, ..Default::default() };
        work.magnetic_edit(scope, ids, |tl, ids| tl.overwrite(&p, at, ids))?;
        *self = work;
        Ok(p.iter().map(|x| x.0.id).collect())
    }

    fn attach(
        &mut self,
        clips: &[Clip],
        t: Time,
        backtimed: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        let first = clips.iter().map(|c| c.start).min().ok_or(EditError::EmptyClip)?;
        let length = clips.iter().map(|c| (c.start - first) + c.timeline().duration).max().unwrap_or(Time::ZERO);
        if length <= Time::ZERO {
            return Err(EditError::EmptyClip);
        }
        let mut work = self.clone();
        if work.is_fast_cut() {
            work.derive_attachments();
        }
        let items: Vec<(Clip, ())> = clips.iter().map(|c| (c.clone(), ())).collect();
        let (mut placed, point_time) = place_run(&items, first, length, t, backtimed, self.frame_duration())?;
        let host = if work.is_fast_cut() { work.attach_host(point_time) } else { None };
        let made: Vec<Id> = placed.iter().map(|p| p.0.id).collect();
        placed.sort_by_key(|p| p.0.start);
        for (mut c, ()) in placed {
            c.attachment = host.map(|h| ClipAttachment::new(h, point_time - c.start));
            work.place_new(c, ids)?;
        }
        if work.is_fast_cut() {
            work.derive_attachments();
        }
        *self = work;
        Ok(made)
    }

    fn fast_cut_source_edit(
        &mut self,
        placements: &[Placement],
        t: Time,
        mode: ThreePointMode,
        backtimed: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Time, EditError> {
        let clips: Vec<Clip> = placements.iter().map(|p| p.0.clone()).collect();
        let made = match self.main_track_id() {
            Some(main) if placements.iter().any(|p| p.1 == main) => match mode {
                ThreePointMode::Insert => self.insert_on_main_track(&clips, t, ids)?,
                ThreePointMode::Overwrite => self.overwrite_on_main_track(&clips, t, ids)?,
            },
            _ => self.attach_on_tracks(placements, t, backtimed, ids)?,
        };
        Ok(made.iter().filter_map(|i| self.find(*i).map(|m| m.clip.timeline().end())).max().unwrap_or(t))
    }

    fn attach_on_tracks(
        &mut self,
        placements: &[Placement],
        t: Time,
        backtimed: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Vec<Id>, EditError> {
        let first = placements.iter().map(|p| p.0.start).min().ok_or(EditError::EmptyClip)?;
        if t < Time::ZERO {
            return Err(EditError::Collision);
        }
        let mut work = self.clone();
        work.derive_attachments();
        if placements.iter().any(|p| work.track(p.1).is_some_and(|tr| tr.is_locked)) {
            return Err(EditError::TrackLocked);
        }
        let length =
            placements.iter().map(|p| (p.0.start - first) + p.0.timeline().duration).max().unwrap_or(Time::ZERO);
        let (mut run, point_time) = place_run(placements, first, length, t, backtimed, self.frame_duration())?;
        let host = work.attach_host(point_time);
        let made: Vec<Id> = run.iter().map(|p| p.0.id).collect();
        run.sort_by_key(|p| p.0.start);
        for (mut c, track) in run {
            c.attachment = host.map(|h| ClipAttachment::new(h, point_time - c.start));
            work.place_attached(c, track, ids)?;
        }
        work.derive_attachments();
        *self = work;
        Ok(made)
    }

    fn replace_on_main_track(
        &mut self,
        id: Id,
        clips: &[Clip],
        keep_length: bool,
        ids: &mut dyn IdSource,
    ) -> Result<(), EditError> {
        let old = match self.find(id) {
            Some(m) if m.clip.kind == TrackKind::Video => m.clip,
            _ => return Err(EditError::ClipNotFound),
        };
        let (Some(v), Some(first)) =
            (clips.iter().find(|c| c.kind == TrackKind::Video), clips.iter().map(|c| c.start).min())
        else {
            return Err(EditError::WrongTrackKind);
        };
        let length =
            if keep_length { old.timeline().duration.min(v.timeline().duration) } else { v.timeline().duration };
        let link = (clips.len() > 1).then(|| ids.next_id());
        let mut fresh: Vec<Clip> = Vec::new();
        for c in clips {
            let end = c.timeline().end().min(c.start + length);
            let Some(mut n) = c.cropped(TimeRange::from_end(c.start, end)) else { continue };
            n.id = if c.id == v.id { old.id } else { c.id };
            n.start = old.start + (c.start - first);
            n.link = link;
            n.attachment = None;
            fresh.push(n);
        }
        let delta = length - old.timeline().duration;
        let mut work = self.clone();
        work.magnetic_edit(MagneticScope::default(), ids, |tl, ids| {
            let group = tl.linked_group(id)?;
            if group.iter().any(|m| tl.tracks[m.track].is_locked) {
                return Err(EditError::TrackLocked);
            }
            // Swift builds a Dictionary keyed by kind (a group with two clips of one kind would trap); the first wins here.
            let mut old_tracks: Vec<(TrackKind, Id)> = Vec::new();
            for m in &group {
                if !old_tracks.iter().any(|o| o.0 == m.clip.kind) {
                    old_tracks.push((m.clip.kind, tl.tracks[m.track].id));
                }
            }
            let old_track = |k: TrackKind| old_tracks.iter().find(|o| o.0 == k).map(|o| o.1);
            for m in &group {
                tl.tracks[m.track].remove(m.clip.id);
            }
            if delta != Time::ZERO && tl.is_fast_cut() {
                tl.ripple_main(old.timeline().end(), delta)?;
            } else if delta != Time::ZERO {
                // Normal mode: a shorter replacement is not a delete, so a caption in the freed tail limits the close.
                let delta = tl.limit_close_by_captions(old.timeline().end(), delta);
                let video_track = old_track(TrackKind::Video);
                for t in &mut tl.tracks {
                    if Some(t.id) == video_track || t.follows_ripple() {
                        t.shift(old.timeline().end(), delta, &BTreeSet::new());
                    }
                }
                if delta > Time::ZERO {
                    tl.open_caption_gap(old.timeline().end(), delta);
                } else {
                    tl.close_caption_span(TimeRange::new(old.timeline().end() + delta, -delta));
                }
            }
            for c in &fresh {
                let track = match old_track(c.kind) {
                    Some(t) => t,
                    None => {
                        let fallback = if c.kind == TrackKind::Video {
                            tl.main_track_id()
                        } else {
                            tl.tracks.iter().find(|t| t.kind == TrackKind::Audio).map(|t| t.id)
                        };
                        match fallback {
                            Some(t) => t,
                            None => tl.add_track(c.kind, ids),
                        }
                    }
                };
                let i = tl.tracks.iter().position(|t| t.id == track).ok_or(EditError::ClipNotFound)?;
                if tl.tracks[i].is_locked {
                    return Err(EditError::TrackLocked);
                }
                tl.tracks[i].overwrite(c.clone(), ids)?;
            }
            tl.prune_transitions();
            if !tl.tracks.iter().all(Track::is_consistent) {
                return Err(EditError::Collision);
            }
            Ok(())
        })?;
        *self = work;
        Ok(())
    }

    fn insert_spacer(&mut self, t: Time, duration: Time, ids: &mut dyn IdSource) -> Result<(), EditError> {
        if duration <= Time::ZERO {
            return Err(EditError::EmptyClip);
        }
        let mut work = self.clone();
        let at = if self.is_fast_cut() { t.max(Time::ZERO).min(self.main_track_end()) } else { t };
        work.magnetic_edit(MagneticScope::default(), ids, |tl, ids| tl.open_main_hole(at, duration, ids))?;
        *self = work;
        Ok(())
    }

    fn slide_main_runs(&mut self, ids: &BTreeSet<Id>, delta: Time) -> Result<Time, EditError> {
        let mi = self.main_track_index().ok_or(EditError::WrongTrackKind)?;
        let mut runs: Vec<Vec<Id>> = Vec::new();
        let mut prev_end: Option<Time> = None; // end of the previous selected clip
        for c in self.tracks[mi].clips().iter().filter(|c| ids.contains(&c.id)) {
            match runs.last_mut() {
                Some(run) if prev_end == Some(c.start) => run.push(c.id),
                _ => runs.push(vec![c.id]),
            }
            prev_end = Some(c.timeline().end());
        }
        if delta > Time::ZERO {
            runs.reverse();
        }
        let mut d = Time::ZERO;
        for run in runs {
            d = self.slide_block(&run, delta, true)?;
        }
        Ok(d)
    }

    fn slide_block(&mut self, ids: &[Id], delta: Time, hold_main_head: bool) -> Result<Time, EditError> {
        let mut members: Vec<Member> = Vec::new();
        let mut seen = BTreeSet::new();
        for id in ids {
            for m in self.linked_group(*id)? {
                if seen.insert(m.clip.id) {
                    members.push(m);
                }
            }
        }
        if members.is_empty() {
            return Err(EditError::ClipNotFound);
        }
        if members.iter().any(|m| self.tracks[m.track].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let frame = self.frame_duration();
        let mi = self.main_track_index();
        let mut by_track: BTreeMap<usize, Vec<&Member>> = BTreeMap::new();
        for m in &members {
            by_track.entry(m.track).or_default().push(m);
        }
        struct Around {
            lo: Time,
            hi: Time,
            prev: Option<Clip>,
            next: Option<Clip>,
        }
        let around = |ti: usize, mine: &[&Member]| -> Option<Around> {
            let lo = mine.iter().map(|m| m.clip.start).min()?;
            let hi = mine.iter().map(|m| m.clip.timeline().end()).max()?;
            let others: Vec<&Clip> = self.tracks[ti].clips().iter().filter(|c| !seen.contains(&c.id)).collect();
            let prev = others.iter().rev().find(|c| c.timeline().end() <= lo).map(|c| (*c).clone());
            let next = others.iter().find(|c| c.start >= hi).map(|c| (*c).clone());
            Some(Around { lo, hi, prev, next })
        };
        let mut d = delta;
        for (ti, mine) in &by_track {
            let Some(Around { lo, hi, prev, next }) = around(*ti, mine) else { continue };
            if d < Time::ZERO {
                match &prev {
                    Some(p) if p.timeline().end() == lo => d = d.max(-(p.duration() - frame).max(Time::ZERO)),
                    _ => d = d.max(-(lo - prev.as_ref().map_or(Time::ZERO, |p| p.timeline().end()))),
                }
                if let Some(n) = &next
                    && n.start == hi
                    && let Some(h) = n.head_handle().map(|h| floored_to_frame(h, frame))
                {
                    d = d.max(-h);
                }
            } else if d > Time::ZERO {
                if hold_main_head && Some(*ti) == mi && !prev.as_ref().is_some_and(|p| p.timeline().end() == lo) {
                    d = Time::ZERO;
                }
                match &next {
                    Some(n) if n.start == hi => d = d.min((n.duration() - frame).max(Time::ZERO)),
                    Some(n) => d = d.min(n.start - hi),
                    None => {}
                }
                if let Some(p) = &prev
                    && p.timeline().end() == lo
                    && let Some(room) = p.tail_room().map(|r| floored_to_frame(r, frame))
                {
                    d = d.min(room);
                }
            }
        }
        if d == Time::ZERO {
            return Ok(Time::ZERO);
        }
        let mut work = self.tracks.clone();
        for (ti, mine) in &by_track {
            let Some(Around { lo, hi, prev, next }) = around(*ti, mine) else { continue };
            if let Some(mut p) = prev
                && p.timeline().end() == lo
            {
                p.extend_tail(d);
                work[*ti].replace(p);
            }
            if let Some(mut n) = next
                && n.start == hi
            {
                n.start += d;
                n.extend_head(-d);
                work[*ti].replace(n);
            }
            for m in mine {
                let mut c = m.clip.clone();
                c.start += d;
                work[*ti].replace(c);
            }
        }
        if !work.iter().all(Track::is_consistent) {
            return Err(EditError::Collision);
        }
        self.tracks = work;
        Ok(d)
    }

    fn set_attach_point(&mut self, id: Id, t: Time) -> Result<(), EditError> {
        let mut work = self.clone();
        work.derive_attachments();
        let (Some(mi), true, Some(c)) =
            (work.main_track_index(), work.is_attachable(id), work.find(id).map(|m| m.clip))
        else {
            return Err(EditError::WrongTrackKind);
        };
        let mut members: Vec<(usize, Clip)> = Vec::new();
        for (i, tr) in work.tracks.iter().enumerate().filter(|(i, _)| *i != mi) {
            members.extend(
                tr.clips()
                    .iter()
                    .filter(|x| x.id == id || (c.link.is_some() && x.link == c.link))
                    .map(|x| (i, x.clone())),
            );
        }
        if members.iter().any(|m| work.tracks[m.0].is_locked) {
            return Err(EditError::TrackLocked);
        }
        let lo = members.iter().map(|m| m.1.start).min().ok_or(EditError::ClipNotFound)?;
        let hi = members.iter().map(|m| m.1.timeline().end()).max().ok_or(EditError::ClipNotFound)?;
        let at = t.max(lo).min((hi - self.frame_duration()).max(lo));
        let host = work.attach_host(at).ok_or(EditError::ClipNotFound)?;
        for (i, m) in members {
            let mut n = m.clone();
            n.attachment = Some(ClipAttachment::new(host, at - m.start));
            work.tracks[i].replace(n);
        }
        *self = work;
        Ok(())
    }
}

/// The edge nearest to `t`; on a tie the earlier one.
pub(crate) fn nearest_edge(edges: impl Iterator<Item = Time>, t: Time) -> Option<Time> {
    edges.min_by_key(|&e| (if e < t { t - e } else { e - t }, e))
}

/// The Fast Cut fixture of the Swift edit-core tests, shared by the tests of the Fast Cut modules.
///
/// V1: c1 0-4 (linked with c1a) | c2 4-8 | c3 8-12; V2: title 4.5-6.5, attached to c2 at point 1 (attach time 5.5);
/// A1: c1a 0-4 (camera audio of c1: part of the main track); A2: music 1-7, attached to c1 at point 0 (attach time 1).
#[cfg(test)]
pub(crate) mod fixture {
    use super::*;
    use sq_core_model::SequenceFormat;
    use sq_core_time::SequentialIds;

    pub fn s(x: f64) -> Time {
        Time::new((x * 30.0).round() as i64, 30)
    }

    pub fn fd() -> Time {
        Time::new(1, 30)
    }

    /// One caption track with an item per `(start, end)` in whole seconds.
    pub fn captions(items: &[(i64, i64)]) -> sq_core_model::CaptionTrack {
        let list: Vec<_> = items
            .iter()
            .enumerate()
            .map(|(n, (a, b))| serde_json::json!({"id": Id::from_u128(900 + n as u128), "lines": ["c"], "range": {"start": {"value": a * 30, "timescale": 30}, "duration": {"value": (b - a) * 30, "timescale": 30}}}))
            .collect();
        serde_json::from_value(serde_json::json!({"id": Id::from_u128(899), "items": list}))
            .unwrap_or_else(|e| panic!("{e}"))
    }

    /// The caption item ranges of the first caption track, in seconds.
    pub fn caption_spans(tl: &Timeline) -> Vec<[i64; 2]> {
        let secs = |t: Time| t.frame_index(Time::new(1, 1));
        tl.caption_tracks[0].items().iter().map(|i| [secs(i.range.start), secs(i.range.end())]).collect()
    }

    pub fn d(t: Time) -> f64 {
        t.value() as f64 / t.timescale() as f64
    }

    pub struct F {
        pub tl: Timeline,
        pub ids: SequentialIds,
        pub c1: Id,
        pub c2: Id,
        pub c3: Id,
        pub c1a: Id,
        pub title: Id,
        pub music: Id,
    }

    pub fn clip(ids: &mut SequentialIds, kind: TrackKind, start: f64, len: f64, link: Option<Id>, media: Id) -> Clip {
        let mut c = Clip::new(ids.next_id(), "x", media, kind, TimeRange::new(s(10.0), s(len)), s(start));
        c.link = link;
        c.media_duration = Some(s(100.0));
        c
    }

    fn attached(mut c: Clip, host: Id, point: f64) -> Clip {
        c.attachment = Some(ClipAttachment::new(host, s(point)));
        c
    }

    impl F {
        pub fn new() -> F {
            let mut ids = SequentialIds::default();
            let (cam, cam_media, other) = (ids.next_id(), ids.next_id(), ids.next_id());
            let c1 = clip(&mut ids, TrackKind::Video, 0.0, 4.0, Some(cam), cam_media);
            let c2 = clip(&mut ids, TrackKind::Video, 4.0, 4.0, None, other);
            let c3 = clip(&mut ids, TrackKind::Video, 8.0, 4.0, None, other);
            let title = attached(clip(&mut ids, TrackKind::Video, 4.5, 2.0, None, other), c2.id, 1.0);
            let c1a = clip(&mut ids, TrackKind::Audio, 0.0, 4.0, Some(cam), cam_media);
            let music = attached(clip(&mut ids, TrackKind::Audio, 1.0, 6.0, None, other), c1.id, 0.0);
            let ids_of = (c1.id, c2.id, c3.id, c1a.id, title.id, music.id);
            let mut tracks = Vec::new();
            for (kind, clips) in [
                (TrackKind::Video, vec![c1, c2, c3]),
                (TrackKind::Video, vec![title]),
                (TrackKind::Audio, vec![c1a]),
                (TrackKind::Audio, vec![music]),
            ] {
                let mut t = Track::new(ids.next_id(), kind);
                t.set_clips(clips);
                tracks.push(t);
            }
            let mut tl = Timeline::new(ids.next_id(), "S", SequenceFormat::new(fd()), tracks);
            tl.set_edit_mode_stored(TimelineEditMode::Magnetic);
            F { tl, ids, c1: ids_of.0, c2: ids_of.1, c3: ids_of.2, c1a: ids_of.3, title: ids_of.4, music: ids_of.5 }
        }
    }

    pub fn span(tl: &Timeline, id: Id) -> Option<[f64; 2]> {
        tl.find(id).map(|m| [d(m.clip.start), d(m.clip.timeline().end())])
    }

    pub fn host(tl: &Timeline, id: Id) -> Option<Id> {
        tl.find(id).and_then(|m| m.clip.attachment).map(|a| a.host)
    }

    pub fn main_clips(tl: &Timeline) -> Vec<Clip> {
        tl.main_track_index().map(|mi| tl.tracks[mi].clips().to_vec()).unwrap_or_default()
    }

    pub fn main_spans(tl: &Timeline) -> Vec<[f64; 2]> {
        main_clips(tl).iter().map(|c| [d(c.start), d(c.timeline().end())]).collect()
    }

    /// Fast Cut invariants after every op: no hole on V1 (unless `holes`), every attachable clip attached and valid, no overlaps.
    pub fn check_invariants(tl: &Timeline, holes: bool) {
        let m = main_clips(tl);
        if !holes {
            assert!(m.windows(2).all(|w| w[0].timeline().end() == w[1].start), "hole on the main track");
        }
        assert!(tl.tracks.iter().all(Track::is_consistent));
        for t in &tl.tracks {
            for c in t.clips() {
                if tl.is_attachable(c.id) && !m.is_empty() {
                    assert!(tl.is_attachment_valid(c.id), "attachment of {:?} invalid", c.id);
                } else {
                    assert!(c.attachment.is_none());
                }
            }
        }
    }

    /// A source range as Fast Cut source edits get it: video and its linked audio, both starting at 0.
    pub fn package(ids: &mut SequentialIds, len: f64, audio: bool, video: bool) -> Vec<Clip> {
        let link = (audio && video).then(|| ids.next_id());
        let media = ids.next_id();
        let mut out = Vec::new();
        for (on, kind) in [(video, TrackKind::Video), (audio, TrackKind::Audio)] {
            if on {
                let mut c = clip(ids, kind, 0.0, len, link, media);
                c.source = TimeRange::new(Time::ZERO, s(len));
                out.push(c);
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::fixture::*;
    use super::*;

    #[test]
    fn fixture_is_valid() {
        let f = F::new();
        check_invariants(&f.tl, false);
        let t = f.tl.find(f.title).unwrap().clip;
        assert_eq!(d(t.start + t.attachment.unwrap().point), 5.5);
        assert!(!f.tl.is_attachable(f.c1a)); // camera audio is part of the main track
    }

    #[test]
    fn insert_splits_and_carries() {
        let mut f = F::new();
        let src = package(&mut f.ids, 2.0, true, true);
        let made = f.tl.insert_on_main_track(&src, s(5.0), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 5.], [5., 7.], [7., 10.], [10., 14.]]);
        assert_eq!(span(&f.tl, f.title), Some([6.5, 8.5]));
        assert_eq!(host(&f.tl, f.title), Some(main_clips(&f.tl)[3].id));
        assert_eq!(span(&f.tl, f.music), Some([1., 7.]));
        let audio = made.iter().filter_map(|i| f.tl.find(*i)).find(|m| m.clip.kind == TrackKind::Audio).unwrap();
        assert_eq!(audio.track, 2); // A1, linked with the new video
        assert_eq!([d(audio.clip.start), d(audio.clip.timeline().end())], [5., 7.]);
        check_invariants(&f.tl, false);

        let mut g = F::new();
        let src = package(&mut g.ids, 2.0, true, true);
        g.tl.insert_on_main_track(&src, s(6.0), &mut g.ids).unwrap();
        assert_eq!(span(&g.tl, g.title), Some([4.5, 6.5]));
        assert_eq!(host(&g.tl, g.title), Some(g.c2));
        check_invariants(&g.tl, false);
    }

    #[test]
    fn overwrite_keeps_attached_in_place() {
        let mut f = F::new();
        let src = package(&mut f.ids, 2.0, true, true);
        let made = f.tl.overwrite_on_main_track(&src, s(5.0), &mut f.ids).unwrap();
        let video = *made.iter().find(|i| f.tl.find(**i).is_some_and(|m| m.clip.kind == TrackKind::Video)).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 5.], [5., 7.], [7., 8.], [8., 12.]]);
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&f.tl, f.title), Some(video));
        assert_eq!(span(&f.tl, f.music), Some([1., 7.])); // A2 untouched by the A1 overwrite
        check_invariants(&f.tl, false);
    }

    #[test]
    fn source_edit_past_the_end_opens_no_hole() {
        let mut f = F::new();
        let src = package(&mut f.ids, 2.0, true, true);
        f.tl.overwrite_on_main_track(&src, s(20.0), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl).last(), Some(&[12., 14.]));
        let src = package(&mut f.ids, 1.0, true, true);
        f.tl.insert_on_main_track(&src, s(30.0), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl).last(), Some(&[14., 15.]));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn append_goes_after_the_last_main_clip() {
        let mut f = F::new();
        let src = package(&mut f.ids, 2.0, true, true);
        let made = f.tl.append_to_main_track(&src, s(3.0), &mut f.ids).unwrap();
        assert_eq!(made.len(), 2);
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.], [12., 14.]]);
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn audio_only_source_attaches_below() {
        let mut f = F::new();
        let src = package(&mut f.ids, 2.0, true, false);
        let made = f.tl.append_to_main_track(&src, s(3.0), &mut f.ids).unwrap();
        let a = f.tl.find(made[0]).unwrap();
        assert_eq!(a.clip.kind, TrackKind::Audio);
        assert_ne!(a.track, 2); // never on A1 (main-track sound)
        assert_eq!(host(&f.tl, a.clip.id), Some(f.c1));
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        check_invariants(&f.tl, false);
    }

    #[test]
    fn attach_places_on_top_at_its_first_frame() {
        let mut f = F::new();
        let src = package(&mut f.ids, 2.0, true, true);
        let made = f.tl.attach(&src, s(9.0), false, &mut f.ids).unwrap();
        assert_eq!(made.len(), 2);
        for id in &made {
            assert_eq!(span(&f.tl, *id), Some([9., 11.]));
            assert_eq!(host(&f.tl, *id), Some(f.c3));
            assert_eq!(f.tl.find(*id).unwrap().clip.attachment.unwrap().point, Time::ZERO);
        }
        let v = made.iter().filter_map(|i| f.tl.find(*i)).find(|m| m.clip.kind == TrackKind::Video).unwrap();
        assert_eq!(v.track, 1);
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        check_invariants(&f.tl, false);
    }

    #[test]
    fn attach_backtimed() {
        let mut f = F::new();
        let src = package(&mut f.ids, 2.0, true, true);
        let made = f.tl.attach(&src, s(9.0), true, &mut f.ids).unwrap();
        for id in made {
            assert_eq!(span(&f.tl, id), Some([7., 9.]));
            assert_eq!(f.tl.find(id).unwrap().clip.attachment.unwrap().point, s(2.0) - fd());
            assert_eq!(host(&f.tl, id), Some(f.c3));
        }
        check_invariants(&f.tl, false);
    }

    fn lone(f: &mut F, len: f64) -> Clip {
        let media = f.ids.next_id();
        clip(&mut f.ids, TrackKind::Video, 0.0, len, None, media)
    }

    #[test]
    fn attach_on_tracks_backtimed_ends_at_t() {
        let mut f = F::new();
        let c = lone(&mut f, 2.0);
        let v2 = f.tl.tracks[1].id;
        let plain = f.tl.attach_on_tracks(&[(c.clone(), v2)], s(7.0), false, &mut f.ids).unwrap();
        assert_eq!(span(&f.tl, plain[0]), Some([7., 9.]));
        assert_eq!(host(&f.tl, plain[0]), Some(f.c2));

        let mut g = F::new();
        let c = lone(&mut g, 2.0);
        let v2 = g.tl.tracks[1].id;
        let back = g.tl.attach_on_tracks(&[(c, v2)], s(9.0), true, &mut g.ids).unwrap();
        assert_eq!(span(&g.tl, back[0]), Some([7., 9.]));
        assert_eq!(host(&g.tl, back[0]), Some(g.c3));
        assert_eq!(g.tl.find(back[0]).unwrap().clip.attachment.unwrap().point, s(2.0) - fd());
        check_invariants(&g.tl, false);
    }

    #[test]
    fn attach_backtimed_cuts_the_head_when_there_is_no_room() {
        let mut f = F::new();
        let c = lone(&mut f, 3.0);
        let v2 = f.tl.tracks[1].id;
        let made = f.tl.attach_on_tracks(&[(c.clone(), v2)], s(1.0), true, &mut f.ids).unwrap();
        let m = f.tl.find(made[0]).unwrap().clip;
        assert_eq!(span(&f.tl, made[0]), Some([0., 1.]));
        assert_eq!(m.source, TimeRange::new(s(12.0), s(1.0))); // the last second of the source
        assert_eq!(m.attachment.unwrap().point, s(1.0) - fd());
        assert_eq!(host(&f.tl, made[0]), Some(f.c1));

        let mut g = F::new();
        let c = lone(&mut g, 3.0);
        let via = g.tl.attach(&[c], s(1.0), true, &mut g.ids).unwrap();
        let m = g.tl.find(via[0]).unwrap().clip;
        assert_eq!(span(&g.tl, via[0]), Some([0., 1.]));
        assert_eq!(m.source, TimeRange::new(s(12.0), s(1.0)));
        assert_eq!(m.attachment.unwrap().point, s(1.0) - fd());
        check_invariants(&g.tl, false);
    }

    #[test]
    fn attach_backtimed_cuts_linked_pairs_alike() {
        let mut f = F::new();
        let link = f.ids.next_id();
        let (m1, m2) = (f.ids.next_id(), f.ids.next_id());
        let v = clip(&mut f.ids, TrackKind::Video, 0.0, 3.0, Some(link), m1);
        let a = clip(&mut f.ids, TrackKind::Audio, 0.0, 3.0, Some(link), m2);
        let (vid, aid) = (v.id, a.id);
        let made = f.tl.attach(&[v, a], s(2.0), true, &mut f.ids).unwrap();
        for id in made {
            assert_eq!(span(&f.tl, id), Some([0., 2.]));
        }
        assert_eq!(f.tl.find(vid).unwrap().clip.source.start, s(11.0));
        assert_eq!(f.tl.find(aid).unwrap().clip.source.start, s(11.0));
    }

    #[test]
    fn attach_backtimed_at_zero_is_refused() {
        let mut f = F::new();
        let c = lone(&mut f, 3.0);
        let v2 = f.tl.tracks[1].id;
        assert_eq!(f.tl.attach_on_tracks(&[(c, v2)], Time::ZERO, true, &mut f.ids), Err(EditError::EmptyClip));
    }

    #[test]
    fn replace_with_source_length_ripples() {
        let mut f = F::new();
        let src = package(&mut f.ids, 6.0, true, true);
        f.tl.replace_on_main_track(f.c2, &src, false, &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 10.], [10., 14.]]);
        assert_eq!(main_clips(&f.tl)[1].id, f.c2);
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&f.tl, f.title), Some(f.c2));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn replace_from_start_keeps_the_length() {
        let mut f = F::new();
        let mut src = package(&mut f.ids, 6.0, true, true);
        let media = src[0].media;
        for c in &mut src {
            c.media = media;
        }
        f.tl.replace_on_main_track(f.c2, &src, true, &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 8.], [8., 12.]]);
        assert_eq!(main_clips(&f.tl)[1].media, media);
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
        assert_eq!(host(&f.tl, f.title), Some(f.c2));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn insert_spacer_opens_a_hole_and_moves_attached_clips() {
        let mut f = F::new();
        f.tl.insert_spacer(s(5.0), s(2.0), &mut f.ids).unwrap();
        assert_eq!(main_spans(&f.tl), [[0., 4.], [4., 5.], [7., 10.], [10., 14.]]);
        assert_eq!(span(&f.tl, f.title), Some([6.5, 8.5]));
        assert_eq!(host(&f.tl, f.title), Some(main_clips(&f.tl)[2].id));
        assert_eq!(span(&f.tl, f.music), Some([1., 7.]));
        check_invariants(&f.tl, true);
    }

    #[test]
    fn set_attach_point_picks_the_host_under_the_time() {
        let mut f = F::new();
        f.tl.set_attach_point(f.title, s(6.0)).unwrap();
        assert_eq!(host(&f.tl, f.title), Some(f.c2));
        assert_eq!(f.tl.find(f.title).unwrap().clip.attachment.unwrap().point, s(1.5));
        f.tl.set_attach_point(f.music, s(5.0)).unwrap();
        assert_eq!(host(&f.tl, f.music), Some(f.c2));
        assert_eq!(f.tl.find(f.music).unwrap().clip.attachment.unwrap().point, s(4.0));
        f.tl.set_attach_point(f.music, s(50.0)).unwrap(); // clamped into the clip
        let m = f.tl.find(f.music).unwrap().clip;
        assert_eq!(d(m.start + m.attachment.unwrap().point), d(s(7.0) - fd()));
        assert_eq!(f.tl.set_attach_point(f.c1, s(1.0)), Err(EditError::WrongTrackKind));
    }

    /// `magneticDelete` of main clips, spelled out: the engine with orphans deleted around `ripple_delete_main`.
    fn delete_main(f: &mut F, ids: &[Id]) {
        let hosts: BTreeSet<Id> = ids.iter().copied().collect();
        let scope = MagneticScope { orphans: crate::timeline_magnetic::MagneticOrphans::Delete, ..Default::default() };
        f.tl.magnetic_edit(scope, &mut f.ids, |tl, _| tl.ripple_delete_main(&hosts)).unwrap();
    }

    #[test]
    fn colliding_attached_clip_goes_to_the_nearest_free_track() {
        let mut f = F::new();
        let media = f.ids.next_id();
        let mut x = clip(&mut f.ids, TrackKind::Video, 2.5, 2.0, None, media);
        x.source = TimeRange::new(Time::ZERO, s(2.0));
        let xid = x.id;
        f.tl.tracks[1].overwrite(x, &mut f.ids).unwrap(); // V2: x 2.5-4.5 (on c1), title 4.5-6.5 (on c2)
        f.tl.derive_attachments();
        let c1 = f.c1;
        f.tl.magnetic_edit(MagneticScope::default(), &mut f.ids, |tl, _| {
            tl.ripple_trim_main(c1, ClipEdge::Tail, s(-1.0))
        })
        .unwrap();
        assert_eq!(span(&f.tl, xid), Some([2.5, 4.5])); // c1 keeps its start
        assert_eq!(f.tl.find(xid).unwrap().track, 1);
        assert_eq!(span(&f.tl, f.title), Some([3.5, 5.5]));
        let t = f.tl.find(f.title).unwrap().track;
        assert_ne!(t, 1);
        assert_eq!(f.tl.tracks[t].kind, TrackKind::Video);
        check_invariants(&f.tl, false);
    }

    #[test]
    fn linked_attached_group_keeps_its_offsets() {
        let mut f = F::new();
        let link = f.ids.next_id();
        let (m1, m2) = (f.ids.next_id(), f.ids.next_id());
        let mut broll = clip(&mut f.ids, TrackKind::Video, 9.0, 1.0, Some(link), m1);
        broll.source = TimeRange::new(Time::ZERO, s(1.0));
        let mut sound = clip(&mut f.ids, TrackKind::Audio, 8.5, 2.0, Some(link), m2);
        sound.source = TimeRange::new(Time::ZERO, s(2.0));
        let (bid, sid) = (broll.id, sound.id);
        for (kind, c) in [(TrackKind::Video, broll), (TrackKind::Audio, sound)] {
            let mut t = Track::new(f.ids.next_id(), kind);
            t.set_clips(vec![c]);
            f.tl.tracks.push(t);
        }
        f.tl.derive_attachments();
        assert_eq!(host(&f.tl, bid), Some(f.c3));
        let c2 = f.c2;
        delete_main(&mut f, &[c2]);
        assert_eq!(span(&f.tl, bid), Some([5., 6.]));
        assert_eq!(span(&f.tl, sid), Some([4.5, 6.5]));
        check_invariants(&f.tl, false);
    }

    #[test]
    fn sync_lock_off_does_not_stop_followers() {
        let mut f = F::new();
        for t in &mut f.tl.tracks {
            t.sync_lock = false;
        }
        let c1 = f.c1;
        delete_main(&mut f, &[c1]);
        assert_eq!(span(&f.tl, f.title), Some([0.5, 2.5]));
        assert!(f.tl.tracks.iter().all(|t| !t.sync_lock)); // the flags are kept for Normal mode
        check_invariants(&f.tl, false);
    }

    #[test]
    fn attached_clip_on_a_locked_track_stays() {
        let mut f = F::new();
        f.tl.tracks[1].is_locked = true;
        let c1 = f.c1;
        delete_main(&mut f, &[c1]);
        assert_eq!(span(&f.tl, f.title), Some([4.5, 6.5]));
    }

    #[test]
    fn nearest_edge_prefers_the_earlier_edge_on_a_tie() {
        let edges = [s(2.0), s(4.0)];
        assert_eq!(nearest_edge(edges.into_iter(), s(3.0)), Some(s(2.0)));
        assert_eq!(nearest_edge(std::iter::empty(), s(3.0)), None);
    }
}
