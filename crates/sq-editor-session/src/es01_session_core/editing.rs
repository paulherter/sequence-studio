//! Edit commands of the session core: the replayable `TimelineEdit` list of a gesture and its commit, delete, add edit,
//! cut out, range edits, marks, sequences (add, format, place), frame scale.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

use sq_core_audio::TimelineCaptionEditsExt as _;
use sq_core_audio::tone_generator::ToneSpec;
use sq_core_audio::tone_generator::{ProjectToneExt, ToneClipExt};
use sq_core_edit::nesting_place::{NestingPlaceExt, SequencePlacement};
use sq_core_edit::nesting_place_clips::NestingPlaceClipsExt;
use sq_core_edit::source_edit_placement::SourceEditPlacementExt;
use sq_core_edit::timeline_bleep::{BLEEP_TRACK_NAME, TimelineBleepExt};
use sq_core_edit::timeline_clipboard::TimelineClipboardExt;
use sq_core_edit::timeline_cut_keys::{CutOutStep, JLCut, TimelineCutKeysExt, cut_out_step};
use sq_core_edit::timeline_duplicate::TimelineDuplicateExt;
use sq_core_edit::timeline_edit_targets::{EditOutcome, TimelineEditTargetsExt};
use sq_core_edit::timeline_edits::{CopySpec, SlipKeyframes, TimelineEditsExt};
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_edit::timeline_magnetic_verbs::MagneticVerbsExt;
use sq_core_edit::timeline_markers::TimelineMarkersExt;
use sq_core_edit::timeline_range_edits::TimelineRangeEditsExt;
use sq_core_edit::timeline_solo::SoloExt;
use sq_core_edit::timeline_speed::{SpeedChange, TimelineSpeedExt};
use sq_core_edit::timeline_split_edit::{SplitEditSide, TimelineSplitEditExt};
use sq_core_edit::timeline_three_point::TimelineThreePointExt;
use sq_core_model::{
    Clip, ClipEdge, DeliveryTarget, EditError, SequenceFormat, ThreePointMode, Timeline, Track, TrackKind,
};
use sq_core_project::project_template::ProjectTemplate;
use sq_core_time::{Id, IdSource, Time, TimeRange};

use crate::{Change, EditorSession};

/// One replayable timeline edit. A gesture yields an ordered list that is applied to the timeline as a single undo step.
// Swift: ToolState.swift:210
#[derive(Clone, Debug, PartialEq)]
pub enum TimelineEdit {
    AddTrack(Track),
    Move {
        clip: Id,
        to: Time,
        track: Option<Id>,
    },
    /// Move with linked partners retargeted to their own tracks (mirrored track change).
    MoveGroup {
        clip: Id,
        to: Time,
        track: Option<Id>,
        partners: BTreeMap<Id, Id>,
    },
    /// Cmd+Option-drag "rearrange": lifts the clip, closes its old gap, inserts it at the drop.
    MoveInsert {
        clip: Id,
        to: Time,
        track: Option<Id>,
    },
    /// Cmd-drag: insert at the drop, the old place stays as a gap.
    InsertMove {
        clip: Id,
        to: Time,
        track: Option<Id>,
    },
    Lift(Vec<Id>),
    RippleDelete(Vec<Id>),
    Trim {
        clip: Id,
        edge: ClipEdge,
        by: Time,
    },
    RippleTrim {
        clip: Id,
        edge: ClipEdge,
        by: Time,
    },
    /// Rate Stretch: the edge moves by `by`, the speed changes to fill the new length.
    RateStretch {
        clip: Id,
        edge: ClipEdge,
        by: Time,
    },
    /// Speed/Duration dialog result for these clips (linked partners follow).
    Speed {
        clips: Vec<Id>,
        change: SpeedChange,
    },
    Roll {
        clip: Id,
        by: Time,
    },
    /// Opt-drag on a cut between linked A/V clips: only the audio edit moves to `to` (split edit, a roll).
    SplitEditAudio {
        cut: Time,
        to: Time,
    },
    /// Extend Edit (E) on a selected edit.
    ExtendEdit {
        clip: Id,
        edge: ClipEdge,
        to: Time,
    },
    Slip {
        clip: Id,
        by: Time,
        keyframes: SlipKeyframes,
    },
    Slide {
        clip: Id,
        by: Time,
    },
    AddEdit {
        at: Time,
        tracks: Option<Vec<Id>>,
    },
    /// Option-drag: like `MoveGroup`, but the originals stay and the copies get the identities in `spec`.
    CopyGroup {
        clip: Id,
        to: Time,
        track: Option<Id>,
        partners: BTreeMap<Id, Id>,
        spec: CopySpec,
    },
    /// Cmd+Option-drag: insert a copy at the drop time, the original stays.
    InsertCopy {
        clip: Id,
        to: Time,
        track: Option<Id>,
        spec: CopySpec,
    },
    Nudge {
        clips: Vec<Id>,
        by: Time,
    },
    CloseGap {
        track: Id,
        at: Time,
    },
    Link(Vec<Id>),
    Unlink(Vec<Id>),
    MoveCaption {
        caption: Id,
        to: Time,
    },
    TrimCaption {
        caption: Id,
        edge: ClipEdge,
        to: Time,
    },
    DeleteCaption(Id),
    /// Drag of a word edge on the caption track. `rolling`: a neighbor touching that edge moves with it.
    RetimeCaptionWord {
        caption: Id,
        index: usize,
        edge: ClipEdge,
        to: Time,
        rolling: bool,
    },
    /// Runs `edits` on exactly these clips: linked partners outside the set stay put.
    Only {
        clips: Vec<Id>,
        edits: Vec<TimelineEdit>,
    },
    /// A Fast Cut verb (see `TimelineEdit::fast_cut`).
    FastCut(crate::FastCutEdit),
}

impl TimelineEdit {
    /// `edits` limited to `ids` when some linked partner of `ids` is not in `ids` (wrapped in `Only`); otherwise
    /// unchanged. `ids` `None` or no held-back partner: the edits follow links as usual.
    // Swift: ToolState.swift:256
    pub fn scoped(edits: Vec<TimelineEdit>, ids: Option<&BTreeSet<Id>>, t: &Timeline) -> Vec<TimelineEdit> {
        let Some(ids) = ids else { return edits };
        if edits.is_empty() || t.held_back_partners(ids).is_empty() {
            return edits;
        }
        let mut sorted: Vec<Id> = ids.iter().copied().collect();
        sorted.sort_by_key(|i| i.to_string());
        vec![TimelineEdit::Only { clips: sorted, edits }]
    }

    /// Applies the edit to the timeline; an error leaves the caller to discard the working copy.
    // Swift: ToolState.swift:260
    pub fn apply(&self, t: &mut Timeline, ids: &mut dyn IdSource) -> Result<(), EditError> {
        match self {
            TimelineEdit::AddTrack(track) => t.tracks.push(track.clone()),
            TimelineEdit::Move { clip, to, track } => {
                t.move_clip(*clip, *to, *track, &BTreeMap::new(), None, ids)?;
            }
            TimelineEdit::MoveGroup { clip, to, track, partners } => {
                t.move_clip(*clip, *to, *track, partners, None, ids)?;
            }
            TimelineEdit::MoveInsert { clip, to, track } => t.move_insert(*clip, *to, *track, ids)?,
            TimelineEdit::InsertMove { clip, to, track } => t.insert_move(*clip, *to, *track, ids)?,
            TimelineEdit::Lift(clips) => t.lift_clips(clips)?,
            TimelineEdit::RippleDelete(clips) => {
                t.ripple_delete(clips)?;
            }
            TimelineEdit::Trim { clip, edge, by } => {
                t.trim(*clip, *edge, *by)?;
            }
            TimelineEdit::RippleTrim { clip, edge, by } => {
                t.ripple_trim(*clip, *edge, *by)?;
            }
            TimelineEdit::RateStretch { clip, edge, by } => {
                t.rate_stretch(*clip, *edge, *by)?;
            }
            TimelineEdit::Speed { clips, change } => t.apply_speed_change_to_all(change, clips)?,
            TimelineEdit::Roll { clip, by } => {
                t.roll(*clip, *by)?;
            }
            TimelineEdit::SplitEditAudio { cut, to } => {
                t.split_edit(*cut, SplitEditSide::Audio, *to, None)?;
            }
            TimelineEdit::ExtendEdit { clip, edge, to } => {
                t.extend_edit(*clip, *edge, *to)?;
            }
            TimelineEdit::Slip { clip, by, keyframes } => {
                t.slip(*clip, *by, *keyframes)?;
            }
            TimelineEdit::Slide { clip, by } => {
                t.slide(*clip, *by)?;
            }
            TimelineEdit::AddEdit { at, tracks } => {
                t.add_edit(*at, tracks.as_deref(), ids)?;
            }
            TimelineEdit::CopyGroup { clip, to, track, partners, spec } => {
                t.move_clip(*clip, *to, *track, partners, Some(spec), ids)?;
            }
            TimelineEdit::InsertCopy { clip, to, track, spec } => t.insert_copy(*clip, *to, *track, spec, ids)?,
            TimelineEdit::Nudge { clips, by } => {
                t.nudge(&clips.iter().copied().collect(), *by, ids)?;
            }
            TimelineEdit::CloseGap { track, at } => {
                t.close_gap(*track, *at, ids)?;
            }
            TimelineEdit::Link(clips) => t.link(&clips.iter().copied().collect(), ids)?,
            TimelineEdit::Unlink(clips) => t.unlink(&clips.iter().copied().collect())?,
            TimelineEdit::DeleteCaption(id) => t.delete_caption(*id)?,
            TimelineEdit::MoveCaption { caption, to } => {
                t.move_caption(*caption, *to)?;
            }
            TimelineEdit::TrimCaption { caption, edge, to } => {
                t.trim_caption(*caption, *edge, *to)?;
            }
            TimelineEdit::RetimeCaptionWord { caption, index, edge, to, rolling } => {
                use sq_core_edit::captions_words::TimelineCaptionWordsExt;
                t.retime_caption_word(*caption, *index, *edge, *to, *rolling)?;
            }
            TimelineEdit::FastCut(f) => f.apply_to(t, ids)?,
            TimelineEdit::Only { clips, edits } => {
                let set: BTreeSet<Id> = clips.iter().copied().collect();
                t.editing_only(&set, ids, |w, ids| {
                    for e in edits {
                        e.apply(w, ids)?;
                    }
                    Ok(())
                })?;
            }
        }
        Ok(())
    }

    /// Applies all edits to a copy (the input is never changed; fails when one edit fails).
    // Swift: ToolState.swift:297
    pub fn apply_all(edits: &[TimelineEdit], t: &Timeline, ids: &mut dyn IdSource) -> Result<Timeline, EditError> {
        let mut out = t.clone();
        for e in edits {
            e.apply(&mut out, ids)?;
        }
        Ok(out)
    }
}

/// A finished gesture: the edit list, the resulting timeline and ONE undo step name.
// Swift: ToolState.swift:305
#[derive(Clone, Debug, PartialEq)]
pub struct TimelineCommit {
    // Swift: ToolState.swift:306
    pub timeline: Timeline,
    // Swift: ToolState.swift:307
    pub edits: Vec<TimelineEdit>,
    // Swift: ToolState.swift:308
    pub undo_name: String,
    // Swift: ToolState.swift:309
    pub selection: BTreeSet<Id>,
    /// Selected caption items after the gesture.
    // Swift: ToolState.swift:311
    pub caption_selection: BTreeSet<Id>,
}

impl TimelineCommit {
    // Swift: ToolState.swift:312
    pub fn new(
        timeline: Timeline,
        edits: Vec<TimelineEdit>,
        undo_name: &str,
        selection: BTreeSet<Id>,
        caption_selection: BTreeSet<Id>,
    ) -> TimelineCommit {
        TimelineCommit { timeline, edits, undo_name: undo_name.to_string(), selection, caption_selection }
    }
}

/// Lets one id stream serve several borrowers in one edit (the ripple wrapper, the edit body, the session itself).
#[derive(Clone)]
pub(crate) struct SharedIds(Rc<RefCell<Box<dyn IdSource>>>);

/// The session's id stream, lent out for one edit: the body draws from `source()` and the session's own `ids` (used by
/// `perform_steps` for grade links and Adjustment Layers) draws from the same stream, so no id repeats.
pub(crate) struct IdLease(Rc<RefCell<Box<dyn IdSource>>>);

impl IdLease {
    /// A handle on the lent stream.
    pub(crate) fn source(&self) -> SharedIds {
        SharedIds(Rc::clone(&self.0))
    }
}

impl IdSource for SharedIds {
    fn next_id(&mut self) -> Id {
        self.0.borrow_mut().next_id()
    }
}

impl EditorSession {
    /// Lends the id stream to an edit body: `self.ids` keeps drawing from the same stream while the lease is out.
    /// Give it back with `return_ids`.
    pub(crate) fn lend_ids(&mut self) -> IdLease {
        let real = std::mem::replace(&mut self.ids, Box::new(sq_core_time::SequentialIds::default()));
        let shared = Rc::new(RefCell::new(real));
        self.ids = Box::new(SharedIds(Rc::clone(&shared)));
        IdLease(shared)
    }

    /// Puts the lent stream back as the session's id source. Handles still alive after this draw from an empty stream.
    pub(crate) fn return_ids(&mut self, lease: IdLease) {
        let real = std::mem::replace(&mut *lease.0.borrow_mut(), Box::new(sq_core_time::SequentialIds::default()));
        self.ids = real;
    }

    /// Runs `f` with the session's id source lent out (so `f` may borrow `self` mutably as well).
    pub(crate) fn with_ids<R>(&mut self, f: impl FnOnce(&mut Self, &mut dyn IdSource) -> R) -> R {
        let lease = self.lend_ids();
        let mut ids = lease.source();
        let out = f(self, &mut ids);
        self.return_ids(lease);
        out
    }

    /// `attempt` with fresh ids for the edit body.
    pub(crate) fn attempt_ids(
        &mut self,
        name: &str,
        body: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<(), EditError>,
    ) -> bool {
        self.with_ids(|s, ids| s.attempt(name, None, |t| body(t, ids)))
    }

    /// `attempt_ripple` with fresh ids for the edit body.
    pub(crate) fn attempt_ripple_ids(
        &mut self,
        name: &str,
        body: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<(), EditError>,
    ) -> bool {
        let lease = self.lend_ids();
        let mut body_ids = lease.source();
        let ok = self.attempt_ripple_with(name, &mut lease.source(), |t| body(t, &mut body_ids));
        self.return_ids(lease);
        ok
    }

    /// Runs `edit` on `t`; the flag says a caption limited it. In Normal mode a ripple that closes a span stops at a caption
    /// in that span instead of deleting it, so the same edit on a copy without captions comes out differently. Fast Cut
    /// pulls such a caption in, never limits, and runs the edit once. Only for edits that make no new ids.
    pub(crate) fn run_noting_caption_limit<R>(
        t: &mut Timeline,
        mut edit: impl FnMut(&mut Timeline) -> Result<R, EditError>,
    ) -> Result<(R, bool), EditError> {
        let has_captions =
            !t.is_fast_cut() && t.caption_tracks.iter().any(|c| c.follows_ripple() && !c.items().is_empty());
        let mut probe = has_captions.then(|| {
            let mut p = t.clone();
            p.caption_tracks.clear();
            p
        });
        let result = edit(t)?;
        let limited = probe.as_mut().is_some_and(|p| edit(p).is_ok() && p.tracks != t.tracks);
        Ok((result, limited))
    }

    pub(crate) fn clamp_text(t: &Timeline, outcome: EditOutcome) -> Option<String> {
        outcome.clamp_reason().map(|r| t.describe(&r))
    }

    /// Tracks a range command acts on: the targeted unlocked ones, else all unlocked.
    fn range_track_ids(t: &Timeline) -> Vec<Id> {
        let targeted: Vec<Id> = t.tracks.iter().filter(|tr| tr.is_targeted && !tr.is_locked).map(|tr| tr.id).collect();
        if targeted.is_empty() {
            t.tracks.iter().filter(|tr| !tr.is_locked).map(|tr| tr.id).collect()
        } else {
            targeted
        }
    }

    /// Applies a finished timeline gesture as ONE undo step by replaying its edits.
    // Swift: EditorSession.swift:506
    pub fn commit(&mut self, c: &TimelineCommit) {
        let clamp: Rc<RefCell<Option<String>>> = Rc::default();
        let out = Rc::clone(&clamp);
        let mut caption_limited = false;
        let ok = self.attempt_ripple_ids(&c.undo_name, |t, ids| {
            *out.borrow_mut() = None;
            caption_limited = false;
            if c.edits.is_empty() {
                *t = c.timeline.clone();
                return Ok(());
            }
            for e in &c.edits {
                // Same as `delete_selection`: a ripple delete the tracks cut short says so in the status line.
                if let TimelineEdit::RippleDelete(clips) = e {
                    let (_, o) = t.ripple_delete_outcome(clips)?;
                    *out.borrow_mut() = Self::clamp_text(t, o);
                } else if matches!(e, TimelineEdit::RippleTrim { .. } | TimelineEdit::Speed { .. }) {
                    let ((), limited) = Self::run_noting_caption_limit(t, |tl| e.apply(tl, ids))?;
                    caption_limited |= limited;
                } else {
                    e.apply(t, ids)?;
                }
            }
            Ok(())
        });
        if !ok {
            return;
        }
        if let Some(clamp) = clamp.borrow().as_ref() {
            self.set_error(format!("Ripple Delete {clamp}"));
        } else if caption_limited {
            self.set_error(Self::CAPTION_BLOCKED_MESSAGE.to_string());
        }
        self.set_selection(c.selection.clone(), c.caption_selection.clone());
    }

    /// Property edit of one clip (Effect Controls). Edits of one gesture (`continues_gesture`) merge into one step.
    // Swift: EditorSession.swift:524
    pub fn replace_clip(&mut self, clip: &Clip, name: &str, continues_gesture: bool) {
        use sq_core_edit::timeline_replace::TimelineReplaceExt;
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let key = format!("clip:{}:{}", clip.id, self.gesture_counter);
        self.attempt(name, Some(&key), |t| t.replace_clip(clip.clone()));
    }

    /// `replace_clip` of an edit a panel computed from `base`, the clip it believed the session held: only the fields
    /// where `clip` differs from `base` land on the live clip, so an edit another panel made since is kept.
    pub fn replace_clip_rebased(&mut self, base: &Clip, clip: &Clip, name: &str, continues_gesture: bool) {
        let rebased = match self.clip_in_active(clip.id) {
            Some(live) => Clip::rebased(base, clip, &live),
            None => clip.clone(),
        };
        self.replace_clip(&rebased, name, continues_gesture);
    }

    /// Delete / Ripple Delete of the selected clips and captions.
    // Swift: EditorSession.swift:1279
    pub fn delete_selection(&mut self, ripple: bool, undo_name: Option<&str>) {
        if self.selection.is_empty() && self.caption_selection.is_empty() {
            return;
        }
        let selection = self.selection.clone();
        let captions: Vec<Id> = {
            let mut c: Vec<Id> = self.caption_selection.iter().copied().collect();
            c.sort_by_key(|i| i.to_string());
            c
        };
        let fast_cut = self.active_timeline().is_some_and(|t| t.is_fast_cut());
        let keep = self.keep_attached_held;
        let mut edits: Vec<TimelineEdit> = Vec::new();
        if !selection.is_empty() {
            let ids: Vec<Id> = selection.iter().copied().collect();
            if let Some(t) = self.active_timeline() {
                let one = if ripple { TimelineEdit::RippleDelete(ids) } else { TimelineEdit::Lift(ids) };
                edits = TimelineEdit::scoped(vec![one], Some(&selection), t);
            }
        }
        edits.extend(captions.into_iter().map(TimelineEdit::DeleteCaption));
        let name = undo_name.unwrap_or(if ripple && !selection.is_empty() { "Ripple Delete" } else { "Delete" });
        let clamp: Rc<RefCell<Option<String>>> = Rc::default();
        let out = Rc::clone(&clamp);
        let ok = self.attempt_ripple_ids(name, |t, ids| {
            // Fast Cut: Delete closes the main track (attached clips go along unless ` is held); the Shift+Delete
            // spacer is `replace_selection_with_spacer`.
            if fast_cut && !selection.is_empty() {
                t.magnetic_delete(&selection, keep, ids)?;
                edits.retain(|e| {
                    !matches!(e, TimelineEdit::RippleDelete(_) | TimelineEdit::Lift(_) | TimelineEdit::Only { .. })
                });
            }
            for e in &edits {
                if let TimelineEdit::RippleDelete(clips) = e {
                    let (_, o) = t.ripple_delete_outcome(clips)?;
                    *out.borrow_mut() = Self::clamp_text(t, o);
                } else {
                    e.apply(t, ids)?;
                }
            }
            Ok(())
        });
        if ok {
            self.set_selection_raw(BTreeSet::new());
            self.caption_selection.clear();
            self.notify(Change::SELECTION);
            if let Some(clamp) = clamp.borrow().as_ref() {
                self.set_error(format!("Ripple Delete {clamp}"));
            }
        }
    }

    /// Cut at the edit point (all tracks with `all_tracks`). A second cut selects the piece between the two.
    // Swift: EditorSession.swift:1308
    pub fn add_edit_at_playhead(&mut self, all_tracks: bool) {
        if self.active_timeline().is_none() {
            return;
        }
        let at = self.edit_point();
        let sel = self.selection.clone();
        let mut cut: Vec<Id> = Vec::new();
        let done = self.attempt_ids(if all_tracks { "Add Edit to All Tracks" } else { "Add Edit" }, |t, ids| {
            // Fast Cut without a selection: the main clip under the playhead and its sound; Normal: the edit target rule.
            cut = if all_tracks { t.magnetic_add_edit_all(at, ids)? } else { t.magnetic_add_edit(at, &sel, ids)? };
            Ok(())
        });
        if !done || cut.is_empty() {
            return;
        }
        // Only right after the previous cut in this sequence: an undo, another edit or a sequence switch ends it.
        if let Some(previous) = self.last_cut_point
            && Some(previous.timeline) == self.active_timeline_id
            && previous.depth + 1 == self.history.undo_depth()
            && previous.time != at
        {
            let piece = self.active_timeline().map(|t| t.clips_between(previous.time, at)).unwrap_or_default();
            if !piece.is_empty() {
                self.select(piece.into_iter().collect(), BTreeSet::new());
            }
        }
        self.last_cut_point = self.active_timeline_id.map(|timeline| crate::CutPoint {
            timeline,
            time: at,
            depth: self.history.undo_depth(),
        });
    }

    /// Cut Out: the first press marks the start, the second extracts the range.
    // Swift: EditorSession.swift:1330
    pub fn cut_out(&mut self) {
        let Some(t) = self.active_timeline() else { return };
        let at = self.playhead;
        // The pending start only counts while its In mark is still there (cleared marks cancel a half-done cut).
        let pending = self.cut_out_start.filter(|s| t.in_out.is_some_and(|r| r.start == *s));
        match cut_out_step(pending, at) {
            CutOutStep::MarkStart(s) => {
                if !self.attempt("Cut Out Start", None, |t| {
                    t.mark_in_at(s);
                    Ok(())
                }) {
                    return;
                }
                self.cut_out_start = Some(s);
            }
            CutOutStep::Extract(range) => {
                let tracks = Self::range_track_ids(t);
                let clamp: Rc<RefCell<Option<String>>> = Rc::default();
                let out = Rc::clone(&clamp);
                // attempt_ripple puts the playhead on the join and remembers it with the undo step.
                self.attempt_ripple_ids("Cut Out", |t, ids| {
                    let (_, o) = t.magnetic_extract(range, &tracks, ids)?;
                    *out.borrow_mut() = Self::clamp_text(t, o);
                    t.set_marked_range(None);
                    Ok(())
                });
                self.cut_out_start = None;
                if let Some(clamp) = clamp.borrow().as_ref() {
                    self.set_error(format!("Cut Out {clamp}"));
                }
            }
        }
    }

    /// Closes the gap (Fast Cut: the spacer) under the playhead.
    // Swift: EditorSession.swift:1354
    pub fn close_gap_at_playhead(&mut self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let at = self.playhead;
        // Fast Cut: only the main track has gaps that close (spacers); attached clips never ripple.
        if t.is_fast_cut() {
            let has_gap = t.main_track_id().is_some_and(|m| t.gap(m, at).is_some());
            if !has_gap {
                self.set_error("No spacer at the playhead.");
                return false;
            }
            let keep = self.keep_attached_held;
            return self.attempt_ripple_ids("Delete Spacer", |t, ids| t.delete_spacer(at, keep, ids).map(|_| ()));
        }
        if !t.tracks.iter().any(|tr| !tr.is_locked && t.gap(tr.id, at).is_some()) {
            self.set_error("No gap at the playhead.");
            return false;
        }
        self.attempt_ripple_ids("Close Gap", |t, ids| t.close_gaps_at_playhead(at, ids).map(|_| ()))
    }

    /// J / L cut: the audio cut moves to the playhead.
    // Swift: EditorSession.swift:1372
    pub fn jl_cut_to_playhead(&mut self, kind: JLCut) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let at = self.playhead;
        let mut probe = t.clone();
        if let Err(EditError::ClipNotFound) = probe.split_edit_jl(kind, at) {
            self.set_error(if kind == JLCut::JCut {
                "No audio cut ahead of the playhead."
            } else {
                "No audio cut behind the playhead."
            });
            return false;
        }
        // Clips that use their whole media have no handle to roll into: the cut would not move. Swift stays silent here;
        // this says why, like the Nudge / offset variants do ("No room to move the audio edit.").
        if probe.split_edit_jl(kind, at) == Ok(Time::ZERO) {
            self.set_error("No room to move the audio edit.");
            return false;
        }
        // Locked or colliding: the real attempt reports it.
        self.attempt(if kind == JLCut::JCut { "J Cut" } else { "L Cut" }, None, |t| {
            t.split_edit_jl(kind, at).map(|_| ())
        })
    }

    /// Q / W: ripple trim of the previous / next edit to the playhead.
    // Swift: EditorSession.swift:1385
    pub fn ripple_trim_to_playhead(&mut self, edge: ClipEdge) {
        let at = self.edit_point();
        let keep = self.keep_attached_held;
        let clamp: Rc<RefCell<Option<String>>> = Rc::default();
        let out = Rc::clone(&clamp);
        let mut caption_limited = false;
        // Head trim: the picture under the playhead slid back by the cut, so the playhead goes with it.
        let ok = self.attempt_ripple_ids(
            if edge == ClipEdge::Head { "Ripple Trim Previous Edit" } else { "Ripple Trim Next Edit" },
            |t, ids| {
                // Q/W: all unlocked tracks; Fast Cut: the main track, attached clips follow (` held: they stay).
                let tracks = Self::playhead_trim_track_ids(t);
                let (o, limited) = Self::run_noting_caption_limit(t, |tl| {
                    tl.magnetic_ripple_trim_to_playhead(edge, at, tracks.as_deref(), keep, ids).map(|(_, o)| o)
                })?;
                *out.borrow_mut() = Self::clamp_text(t, o);
                caption_limited = limited;
                Ok(())
            },
        );
        if let Some(clamp) = clamp.borrow().as_ref() {
            self.set_error(format!("Trim {clamp}"));
        } else if ok && caption_limited {
            self.set_error(Self::CAPTION_BLOCKED_MESSAGE.to_string());
        }
    }

    /// The tracks Q/W act on: the enabled unlocked ones when some are switched off, else all (`None`).
    fn playhead_trim_track_ids(t: &Timeline) -> Option<Vec<Id>> {
        let unlocked: Vec<&Track> = t.tracks.iter().filter(|tr| !tr.is_locked).collect();
        let enabled: Vec<Id> = unlocked
            .iter()
            .filter(|tr| if tr.kind == TrackKind::Video { tr.is_visible } else { !tr.is_muted })
            .map(|tr| tr.id)
            .collect();
        (!enabled.is_empty() && enabled.len() != unlocked.len()).then_some(enabled)
    }

    /// Clears the In/Out range (leaving a gap).
    // Swift: EditorSession.swift:1405
    pub fn lift_range(&mut self) {
        let Some(t) = self.active_timeline() else { return };
        let Some(io) = t.export_range().filter(|r| !r.is_empty()) else {
            self.set_error("Set In and Out first.");
            return;
        };
        let tracks = Self::range_track_ids(t);
        // Fast Cut with the main track targeted: a spacer on V1, attached clips stay.
        self.attempt_ripple_ids("Clear Range", |t, ids| t.magnetic_clear_range(io, &tracks, ids));
    }

    /// Replaces the sound of the In/Out range (or the selected clips) with a bleep tone.
    // Swift: EditorSession.swift:1415
    pub fn bleep_range(&mut self) {
        let Some(t) = self.active_timeline() else { return };
        let mut range = t.export_range();
        if range.is_none_or(|r| r.is_empty()) {
            let picked: Vec<_> =
                t.tracks.iter().flat_map(|tr| tr.clips().iter()).filter(|c| self.selection.contains(&c.id)).collect();
            let lo = picked.iter().map(|c| c.start).min();
            let hi = picked.iter().map(|c| c.timeline().end()).max();
            if let (Some(lo), Some(hi)) = (lo, hi) {
                range = Some(TimeRange::from_end(lo, hi));
            }
        }
        let Some(range) = range.filter(|r| !r.is_empty()) else {
            self.set_error("Set In and Out, or select a clip, to bleep.");
            return;
        };
        let ids: Vec<Id> = Self::range_track_ids(t)
            .into_iter()
            .filter(|i| t.track(*i).is_some_and(|tr| tr.kind == TrackKind::Audio && tr.name != BLEEP_TRACK_NAME))
            .collect();
        if ids.is_empty() {
            self.set_error("There is no audio track to bleep.");
            return;
        }
        // Nothing sounds there any more (a repeated Bleep): a short status line, not the generic refusal.
        let mut probe = t.clone();
        if probe.bleep(range, &ids, &ToneSpec::DEFAULT, &mut sq_core_time::SequentialIds::default())
            == Err(EditError::EmptyClip)
        {
            self.set_error("Nothing left to bleep there.");
            return;
        }
        self.attempt_ids("Bleep", |t, ids_src| t.bleep(range, &ids, &ToneSpec::DEFAULT, ids_src).map(|_| ()));
    }

    /// Settings of a tone clip.
    // Swift: EditorSession.swift:1436
    pub fn set_tone(&mut self, id: Id, spec: &ToneSpec) {
        if let Err(e) = self.try_perform("Tone Settings", None, |p| p.set_tone(id, spec)) {
            self.set_error(Self::message_for(&e));
        }
    }

    /// The selected tone clip and its settings.
    // Swift: EditorSession.swift:1441
    pub fn selected_tone(&self) -> Option<(Id, ToneSpec)> {
        if self.selection.len() != 1 {
            return None;
        }
        let id = *self.selection.iter().next()?;
        let t = self.active_timeline()?;
        let clip = t.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == id)?;
        clip.tone().map(|spec| (id, spec))
    }

    /// Deletes the In/Out range and closes the gap.
    // Swift: EditorSession.swift:1448
    pub fn extract_range(&mut self) {
        let Some(t) = self.active_timeline() else { return };
        let Some(io) = t.export_range().filter(|r| !r.is_empty()) else {
            self.set_error("Set In and Out first.");
            return;
        };
        let tracks = Self::range_track_ids(t);
        let clamp: Rc<RefCell<Option<String>>> = Rc::default();
        let out = Rc::clone(&clamp);
        self.attempt_ripple_ids("Delete Range", |t, ids| {
            let (_, o) = t.magnetic_extract(io, &tracks, ids)?;
            *out.borrow_mut() = Self::clamp_text(t, o);
            Ok(())
        });
        if let Some(clamp) = clamp.borrow().as_ref() {
            self.set_error(format!("Delete Range {clamp}"));
        }
    }

    /// Why `ids` cannot be nested in the active sequence (it is one of them, or one of them contains it).
    // Swift: EditorSession.swift:1591
    pub fn sequence_nesting_refusal(&self, ids: &[Id]) -> Option<String> {
        let host = self.active_timeline_id?;
        ids.iter().any(|i| self.project().would_create_cycle(*i, host)).then(|| Self::NESTING_CYCLE_MESSAGE.to_string())
    }

    /// Drops / Insert / Overwrite of whole sequences as nested clips, one undo step. Refusals set the status message.
    // Swift: EditorSession.swift:1600
    pub fn place_sequences(
        &mut self,
        ids: &[Id],
        at: Option<Time>,
        video_track: Option<Id>,
        mode: ThreePointMode,
        new_track: Option<TrackKind>,
    ) -> bool {
        let Some(host) = self.active_timeline_id else { return false };
        if ids.is_empty() {
            return false;
        }
        let at = at.unwrap_or(self.playhead);
        let before = self.history.current().clone();
        // An Angles sequence is always placed as one clip: its angles are never laid out as single clips.
        let as_clips = self.place_sequences_as_clips
            && !ids.iter().any(|i| self.project().timeline(*i).is_some_and(|t| t.angles.is_some()));
        let result = self.with_ids(|s, id_src| {
            s.try_perform(if mode == ThreePointMode::Insert { "Insert" } else { "Overwrite" }, None, |p| {
                let at = SequencePlacement { host, time: at, video_track, new_track, mode };
                if as_clips {
                    p.place_sequence_clips(ids, &at, id_src).map(|_| ())
                } else {
                    p.place_sequences(ids, &at, id_src).map(|_| ())
                }
            })
        });
        if let Err(e) = result {
            self.set_error(if e == EditError::EmptyClip {
                "That sequence is empty.".to_string()
            } else {
                Self::message_for(&e)
            });
            return false;
        }
        *self.history.current() != before
    }

    /// The default name of the next new sequence ("Sequence 03").
    // Swift: EditorSession.swift:1637
    pub fn suggested_sequence_name(&self) -> String {
        let names: BTreeSet<&str> = self.project().timelines.iter().map(|t| t.name.as_str()).collect();
        let mut n = self.project().timelines.len() + 1;
        while names.contains(format!("Sequence {n:02}").as_str()) {
            n += 1;
        }
        format!("Sequence {n:02}")
    }

    fn new_sequence_name(&self, name: Option<&str>) -> String {
        match name.map(str::trim).filter(|n| !n.is_empty()) {
            Some(n) => n.to_string(),
            None => self.suggested_sequence_name(),
        }
    }

    /// Adds an empty sequence (format of the active one by default) and opens it.
    // Swift: EditorSession.swift:1645
    pub fn add_sequence(
        &mut self,
        name: Option<&str>,
        format: Option<SequenceFormat>,
        delivery_target: Option<DeliveryTarget>,
    ) -> Id {
        let format = format
            .or_else(|| self.active_timeline().map(|t| t.format.clone()))
            .unwrap_or_else(|| SequenceFormat::new(Time::new(1001, 30000)));
        let title = self.new_sequence_name(name);
        let mode = self.new_sequence_edit_mode;
        let mut t = self.with_ids(|_, ids| {
            let tracks = Timeline::default_tracks(4, 4, ids);
            Timeline::new(ids.next_id(), &title, format, tracks)
        });
        t.delivery_target = delivery_target;
        t.set_edit_mode(mode);
        let id = t.id;
        self.perform("New Sequence", None, |p| {
            p.timelines.push(t);
            p.normalize_bins();
        });
        self.set_active_timeline(id);
        id
    }

    /// Adds a sequence made from a template and opens it.
    // Swift: EditorSession.swift:1665
    pub fn add_sequence_from_template(&mut self, template: &ProjectTemplate, name: Option<&str>) -> Id {
        let title = self.new_sequence_name(name);
        let mode = self.new_sequence_edit_mode;
        let mut t = self.with_ids(|_, ids| template.make_sequence(&title, ids));
        t.set_edit_mode(mode);
        let id = t.id;
        self.perform("New Sequence", None, |p| {
            p.timelines.push(t);
            p.normalize_bins();
        });
        self.set_active_timeline(id);
        id
    }

    /// Changes the format (and delivery target) of the active sequence: one undo step.
    // Swift: EditorSession.swift:1682
    pub fn set_sequence_format(&mut self, format: &SequenceFormat, delivery_target: Option<DeliveryTarget>) -> bool {
        let Some(id) = self.active_timeline_id else { return false };
        let same = self.active_timeline().is_some_and(|t| t.format == *format && t.delivery_target == delivery_target);
        if same {
            return false;
        }
        let result = self.try_perform("Sequence Settings", None, |p| {
            let mut s = p.timeline(id).ok_or(EditError::TimelineNotFound)?.settings();
            s.format = format.clone();
            s.delivery_target = delivery_target.clone();
            p.set_settings(&s, id)
        });
        if let Err(e) = result {
            self.set_error(Self::message_for(&e));
            return false;
        }
        true
    }

    /// Set to Frame Size on these clips (the selection by default).
    // Swift: EditorSession.swift:1694
    pub fn set_to_frame_size(&mut self, ids: Option<&BTreeSet<Id>>) -> bool {
        self.write_frame_scale(ids, false)
    }

    /// Scale to Fill Frame on these clips (the selection by default).
    // Swift: EditorSession.swift:1698
    pub fn set_to_fill_frame(&mut self, ids: Option<&BTreeSet<Id>>) -> bool {
        self.write_frame_scale(ids, true)
    }

    fn write_frame_scale(&mut self, ids: Option<&BTreeSet<Id>>, fill: bool) -> bool {
        let Some(tid) = self.active_timeline_id else { return false };
        let targets = ids.cloned().unwrap_or_else(|| self.selection.clone());
        if targets.is_empty() {
            return false;
        }
        let mut trial = self.project().clone();
        let n = if fill { trial.set_to_fill_frame(&targets, tid) } else { trial.set_to_frame_size(&targets, tid) };
        match n {
            Ok(0) => false, // already at the value
            Ok(_) => {
                self.perform(if fill { "Fill Frame" } else { "Fit to Frame" }, None, |p| *p = trial);
                true
            }
            Err(e) => {
                self.set_error(Self::message_for(&e));
                false
            }
        }
    }

    // Swift: EditorSession.swift:1718
    pub fn mark_in(&mut self) {
        if self.active_timeline().is_none() {
            return;
        }
        let at = self.playhead;
        self.attempt("Mark In", None, |t| {
            t.mark_in_at(at);
            Ok(())
        });
    }

    // Swift: EditorSession.swift:1726
    pub fn mark_out(&mut self) {
        if self.active_timeline().is_none() {
            return;
        }
        let at = self.playhead;
        self.attempt("Mark Out", None, |t| {
            t.mark_out_at(at);
            Ok(())
        });
    }

    /// Marks the clip under the playhead (or the selection) as the In/Out range.
    // Swift: EditorSession.swift:1733
    pub fn mark_clip(&mut self) {
        let Some(t) = self.active_timeline() else { return };
        let Some(range) = t.mark_clip_range_for_selection(self.playhead, &self.selection) else { return };
        self.attempt("Mark Clip", None, |t| {
            t.set_marked_range(Some(range));
            Ok(())
        });
    }

    // Swift: EditorSession.swift:1738
    pub fn clear_in_out(&mut self) {
        if self.active_timeline().and_then(|t| t.in_out).is_none() {
            return;
        }
        self.attempt("Clear In and Out", None, |t| {
            t.set_marked_range(None);
            Ok(())
        });
    }

    /// Mark All of the transcript search: a marker on every match, one undo step. Returns how many were added.
    // Swift: TextPanelDraw.swift:88
    pub fn mark_search_hits(&mut self, times: &[Time], name: &str) -> usize {
        let mut added = 0;
        self.attempt_ids("Mark Search Hits", |t, ids| {
            added = t.add_search_hit_markers(times, name, ids);
            Ok(())
        });
        added
    }

    // Swift: EditorSession.swift:1743
    pub fn add_marker_at_playhead(&mut self) {
        let at = self.playhead;
        self.attempt_ids("Add Marker", |t, ids| {
            t.add_marker(at, "", ids);
            Ok(())
        });
    }

    /// Selects the clips that appeared since `existing` (after a place or drop).
    #[allow(dead_code)] // shortcut: first caller is `place_media`, still pending
    pub(crate) fn select_new_clips(&mut self, existing: &BTreeSet<Id>) {
        let Some(t) = self.active_timeline() else { return };
        let all: BTreeSet<Id> = t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect();
        let added: BTreeSet<Id> = all.difference(existing).copied().collect();
        if !added.is_empty() {
            self.select(added, BTreeSet::new());
        }
    }
}
