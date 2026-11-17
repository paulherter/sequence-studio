//! Fast Cut (magnetic main track): the mode switch, the Fast Cut-only commands and the replayable `FastCutEdit` verbs.
//! Every other edit command picks its Fast Cut verb itself, so a Fast Cut sequence never runs a plain Normal edit. Each
//! command is ONE undo step and returns the status line the app shows.

use std::collections::{BTreeMap, BTreeSet};

use sq_core_audio::TimelineCaptionEditsExt as _;
use sq_core_edit::timeline_edits::{CopySpec, SlipKeyframes, TimelineEditsExt};
use sq_core_edit::timeline_fast_cut_storylines::FastCutStorylinesExt;
use sq_core_edit::timeline_magnetic::{MagneticExt, MagneticScope, MagneticStay};
use sq_core_edit::timeline_magnetic_moves::{MagneticCopy, MagneticGesturesExt};
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_edit::timeline_magnetic_verbs::MagneticVerbsExt;
use sq_core_edit::timeline_solo::SoloExt;
use sq_core_edit::timeline_source_edit::{SourceStreams, TimelineSourceEditExt};
use sq_core_edit::timeline_speed::SpeedChange;
use sq_core_model::{AnimatedProperty, Clip, ClipEdge, EditError, Timeline, TimelineEditMode, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange, Vec2};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;

use crate::{EditorSession, TimelineEdit};

impl EditorSession {
    /// Default length of Insert Spacer (FCP's gap default).
    // Swift: EditorSession+FastCut.swift:45
    pub const DEFAULT_SPACER_LENGTH: Time = Time::new(3, 1);

    /// Switches the active sequence between Normal and Fast Cut: ONE undo step that moves no clip. False when the
    /// sequence already is in `mode` (no step) or there is no sequence.
    // Swift: EditorSession+FastCut.swift:13
    pub fn set_timeline_edit_mode(&mut self, mode: TimelineEditMode) -> bool {
        let Some(id) = self.active_timeline_id else { return false };
        if self.active_timeline().is_none_or(|t| t.edit_mode() == mode) {
            return false;
        }
        let name = if mode == TimelineEditMode::Magnetic { "Switch to Fast Cut" } else { "Switch to Normal" };
        match self.try_perform(name, None, |p| p.set_edit_mode(mode, id)) {
            Ok(()) => true,
            Err(e) => {
                self.set_error(e.to_string());
                false
            }
        }
    }

    /// Enabled state of a Fast Cut command: only in Fast Cut, and only with the right selection.
    // Swift: EditorSession+FastCut.swift:23
    pub fn fast_cut_command_enabled(&self, c: EditorCommand) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if t.edit_mode() != TimelineEditMode::Magnetic {
            return false;
        }
        let main = t.main_track_index();
        let sel = &self.selection;
        let rows: Vec<usize> = t
            .tracks
            .iter()
            .enumerate()
            .flat_map(|(i, tr)| tr.clips().iter().filter(|c| sel.contains(&c.id)).map(move |_| i))
            .collect();
        match c {
            EditorCommand::AppendToMainTrack | EditorCommand::InsertSpacer => main.is_some(),
            EditorCommand::LiftOffMainTrack => rows.iter().any(|r| Some(*r) == main),
            EditorCommand::PutOnMainTrack => rows.iter().any(|r| Some(*r) != main),
            EditorCommand::SetAttachPoint => sel.iter().any(|id| t.is_attachable(*id)),
            EditorCommand::CreateStoryline => {
                let picks: Vec<&Clip> = t
                    .tracks
                    .iter()
                    .flat_map(|tr| tr.clips())
                    .filter(|c| sel.contains(&c.id) && t.is_attachable(c.id))
                    .collect();
                picks.len() >= 2 && picks.iter().all(|c| c.kind == picks[0].kind)
            }
            EditorCommand::StorylineRippleDelete => sel.iter().any(|id| t.storyline_containing(*id).is_some()),
            EditorCommand::MoveClipLeft | EditorCommand::MoveClipRight => {
                sel.iter().any(|id| t.main_clip_of(*id).is_some())
            }
            EditorCommand::DeleteSelectionOnly => {
                main.is_some() && (!sel.is_empty() || !self.caption_selection.is_empty())
            }
            EditorCommand::PasteAttached => self.clipboard.as_ref().is_some_and(|c| !c.entries.is_empty()),
            EditorCommand::AttachBacktimed => main.is_some(), // the app adds the "has a source" check
            _ => false,
        }
    }

    /// Append to Main Track (Ctrl+E): `ids` (the Source clip, else the media selected in the Project panel) go to the
    /// end of V1 one item after another, video with its sound linked; audio-only items attach at the playhead. Source
    /// marks are honored. The playhead moves to the end of what was appended.
    // Swift: EditorSession+FastCut.swift:50
    pub fn append_to_main_track(&mut self, ids: &[Id], streams: SourceStreams) -> String {
        let Some(t) = self.active_timeline() else { return "Open a sequence first.".to_string() };
        let refs: Vec<_> = ids.iter().filter_map(|i| self.project().media(*i)).cloned().collect();
        if refs.is_empty() {
            return "Open a clip in the Source view or select media in the Project panel first.".to_string();
        }
        let adopts = !t.format_locked && t.tracks.iter().all(|tr| tr.clips().is_empty());
        let marks = self.project().source_marks.clone();
        let at = self.playhead;
        let mut end: Option<Time> = None;
        let done = self.attempt_keyed_ids("Append to Main Track", None, |tl, src| {
            if adopts && let Some(v) = refs[0].info.as_ref().and_then(|i| i.video.as_ref()) {
                let still = refs[0].info.as_ref().is_some_and(|i| i.is_still);
                let mut f = tl.format.clone();
                f.width = v.display_width();
                f.height = v.display_height();
                if !still {
                    f.frame_duration = v.nominal_frame_duration;
                }
                tl.format = f.sanitized(&tl.format);
            }
            for r in &refs {
                let still = r.info.as_ref().is_some_and(|i| i.is_still);
                let total =
                    if still { Some(Time::new(5, 1)) } else { r.info.as_ref().map(|i| i.duration).or(r.duration) };
                let Some(total) = total else { continue };
                let range = if still {
                    Some(TimeRange::new(Time::ZERO, total))
                } else {
                    Timeline::source_edit_range(&marks.get(&r.id).cloned().unwrap_or_default(), total)
                };
                let Some(range) = range else { continue };
                let source = TimeRange::new(range.start, range.duration.snapped(tl.frame_duration()));
                if source.is_empty() {
                    continue;
                }
                let video = (r.info.as_ref().is_none_or(|i| i.video.is_some())) && streams.includes_video();
                let audio = r.info.as_ref().is_some_and(|i| i.audio.is_some()) && streams.includes_audio();
                let link = (video && audio).then(|| src.next_id());
                let mut clips: Vec<Clip> = Vec::new();
                if video {
                    let mut c = Clip::new(src.next_id(), &r.name, r.id, TrackKind::Video, source, Time::ZERO);
                    c.link = link;
                    c.media_duration = if still { None } else { Some(total) };
                    c.is_still = still;
                    let fit = r
                        .info
                        .as_ref()
                        .and_then(|i| i.video.as_ref())
                        .map_or(1.0, |v| tl.format.fit_scale(v.display_width(), v.display_height()));
                    if (fit - 1.0).abs() > 1e-12 {
                        c.animation.scale = AnimatedProperty::new(Vec2 { x: fit, y: fit });
                    }
                    clips.push(c);
                }
                if audio {
                    let mut c = Clip::new(src.next_id(), &r.name, r.id, TrackKind::Audio, source, Time::ZERO);
                    c.link = link;
                    c.media_duration = Some(total);
                    clips.push(c);
                }
                if clips.is_empty() {
                    continue;
                }
                let made = tl.append_to_main_track(&clips, at, src)?;
                end = tl
                    .tracks
                    .iter()
                    .flat_map(|tr| tr.clips())
                    .filter(|c| made.contains(&c.id))
                    .map(|c| c.timeline().end())
                    .max();
            }
            if end.is_none() {
                return Err(EditError::EmptyClip);
            }
            Ok(())
        });
        if !done {
            return self.last_error.clone().unwrap_or_else(|| "Nothing to append.".to_string());
        }
        if let Some(end) = end {
            self.seek_sequence(end);
        }
        SQL10n::plural(refs.len() as i64, "Appended to the main track.", "Appended %@ clips to the main track.")
    }

    /// Insert Spacer (Ctrl+W): a hole of `DEFAULT_SPACER_LENGTH` at the playhead on V1 (at its end when the playhead is
    /// past it); everything later ripples with its attached clips.
    // Swift: EditorSession+FastCut.swift:101
    pub fn insert_spacer(&mut self) -> String {
        let Some(t) = self.active_timeline() else { return "Open a sequence first.".to_string() };
        let fd = t.frame_duration();
        let (at, d) = (self.playhead.snapped(fd), Self::DEFAULT_SPACER_LENGTH.snapped(fd));
        if self.attempt_keyed_ids("Insert Spacer", None, |t, src| t.insert_spacer(at, d, src)) {
            "Spacer inserted.".to_string()
        } else {
            self.last_error.clone().unwrap_or_else(|| "No spacer inserted.".to_string())
        }
    }

    /// Replace with Spacer (Shift+Delete in Fast Cut): the selected main-track clips leave a hole; attached clips stay
    /// on their frame. Selected attached clips are removed, selected captions deleted (same step).
    // Swift: EditorSession+FastCut.swift:110
    pub fn replace_selection_with_spacer(&mut self) -> String {
        if self.selection.is_empty() && self.caption_selection.is_empty() {
            return "Select clips first.".to_string();
        }
        let ids = self.selection.clone();
        let captions: Vec<Id> = self.caption_selection.iter().copied().collect(); // uuid-string order = id order
        let name = if ids.is_empty() { "Delete" } else { "Replace with Spacer" };
        let ok = self.attempt_keyed_ids(name, None, |t, src| {
            if !ids.is_empty() {
                t.replace_with_spacer(&ids, src)?;
            }
            for c in &captions {
                t.delete_caption(*c)?;
            }
            Ok(())
        });
        if !ok {
            return self.last_error.clone().unwrap_or_else(|| "Nothing replaced.".to_string());
        }
        self.select(BTreeSet::new(), BTreeSet::new()); // clears the caption selection too
        if ids.is_empty() { "Deleted." } else { "Replaced with a spacer." }.to_string()
    }

    /// Move Clip Left / Right (Ctrl+Cmd+Left/Right): each selected main-track clip (once per linked group) swaps with
    /// its neighbor on V1; linked partners and attached clips travel with their host. One undo step.
    // Swift: EditorSession+FastCut.swift:124
    pub fn move_selected_main_clips(&mut self, step: i32) -> String {
        let Some(t) = self.active_timeline() else { return "Open a sequence first.".to_string() };
        let mut picks: Vec<Id> = Vec::new();
        for id in &self.selection {
            if let Some(m) = t.main_clip_of(*id)
                && !picks.contains(&m)
            {
                picks.push(m);
            }
        }
        let order: Vec<Id> =
            t.main_track_index().map(|i| t.tracks[i].clips().iter().map(|c| c.id).collect()).unwrap_or_default();
        picks.sort_by_key(|p| order.iter().position(|o| o == p).unwrap_or(0));
        if step > 0 {
            picks.reverse(); // the one in front goes first, so a run keeps its order
        }
        if picks.is_empty() {
            return "Select a main-track clip first.".to_string();
        }
        let name = if step < 0 { "Move Clip Left" } else { "Move Clip Right" };
        let ok = self.attempt_keyed_ids(name, None, |tl, src| {
            for id in &picks {
                tl.magnetic_move(*id, step, src)?;
            }
            Ok(())
        });
        if !ok {
            return self
                .last_error
                .clone()
                .unwrap_or_else(|| if step < 0 { "Already first." } else { "Already last." }.to_string());
        }
        if step < 0 { "Moved left." } else { "Moved right." }.to_string()
    }

    /// Lift off Main Track (Opt+Cmd+Up): the selected V1 clips go to the lowest free track above at the same time and
    /// become attached; a spacer stays on V1, attached clips stay on their frame.
    // Swift: EditorSession+FastCut.swift:153
    pub fn lift_off_main_track(&mut self) -> String {
        let ids = self.selection.clone();
        if self.attempt_keyed_ids("Lift off Main Track", None, |t, src| t.lift_off_main_track(&ids, src)) {
            "Lifted off the main track.".to_string()
        } else {
            self.last_error.clone().unwrap_or_else(|| "Nothing lifted.".to_string())
        }
    }

    /// Put on Main Track (Opt+Cmd+Down): the selected attached video clips overwrite V1 at their own position.
    // Swift: EditorSession+FastCut.swift:160
    pub fn put_on_main_track(&mut self) -> String {
        let ids = self.selection.clone();
        if self.attempt_keyed_ids("Put on Main Track", None, |t, src| t.put_on_main_track(&ids, src)) {
            "Put on the main track.".to_string()
        } else {
            self.last_error.clone().unwrap_or_else(|| "Nothing moved.".to_string())
        }
    }

    /// Set Attach Point: every selected attached clip (once per linked group) attaches at the playhead (clamped into
    /// the clip) to the main clip under it.
    // Swift: EditorSession+FastCut.swift:168
    pub fn set_attach_point(&mut self) -> String {
        let Some(t) = self.active_timeline() else { return "Open a sequence first.".to_string() };
        let at = self.playhead;
        let mut seen: BTreeSet<Id> = BTreeSet::new();
        let picks: Vec<Id> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| self.selection.contains(&c.id) && t.is_attachable(c.id))
            .filter(|c| seen.insert(c.link.unwrap_or(c.id)))
            .map(|c| c.id)
            .collect();
        if picks.is_empty() {
            return "Select a clip above or below the main track first.".to_string();
        }
        let ok = self.attempt_keyed_ids("Set Attach Point", None, |tl, _| {
            for id in &picks {
                tl.set_attach_point(*id, at)?;
            }
            Ok(())
        });
        if ok {
            "Attach point set.".to_string()
        } else {
            self.last_error.clone().unwrap_or_else(|| "Attach point not set.".to_string())
        }
    }

    /// Create Storyline (Ctrl+G): the selected attached clips of one kind join the lane of the earliest one on their
    /// own frames and connect into one storyline.
    // Swift: EditorSession+FastCut.swift:182
    pub fn create_storyline(&mut self) -> String {
        let Some(t) = self.active_timeline() else { return "Open a sequence first.".to_string() };
        let ids: BTreeSet<Id> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| self.selection.contains(&c.id) && t.is_attachable(c.id))
            .map(|c| c.id)
            .collect();
        if ids.len() < 2 {
            return "Select two or more connected clips first.".to_string();
        }
        if self.attempt_keyed_ids("Create Storyline", None, |t, src| t.create_storyline(&ids, src)) {
            "Storyline created.".to_string()
        } else {
            self.last_error.clone().unwrap_or_else(|| "No storyline created.".to_string())
        }
    }

    /// Ripple Delete in Storyline (Ctrl+Shift+Delete): the selected storyline clips leave and the later clips of that
    /// storyline close up; the main track and everything outside the run stay. One undo step for all.
    // Swift: EditorSession+FastCut.swift:192
    pub fn storyline_ripple_delete(&mut self) -> String {
        let Some(t) = self.active_timeline() else { return "Open a sequence first.".to_string() };
        let mut picks: Vec<&Clip> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| self.selection.contains(&c.id) && t.storyline_containing(c.id).is_some())
            .collect();
        // latest first: earlier clips keep their frames while deleting
        picks.sort_by_key(|c| std::cmp::Reverse(c.start));
        let picks: Vec<Id> = picks.iter().map(|c| c.id).collect();
        if picks.is_empty() {
            return "Select clips inside a storyline first.".to_string();
        }
        let ok = self.attempt_keyed_ids("Ripple Delete in Storyline", None, |tl, src| {
            for id in &picks {
                tl.storyline_ripple_delete(*id, src)?;
            }
            Ok(())
        });
        if !ok {
            return self.last_error.clone().unwrap_or_else(|| "Nothing deleted.".to_string());
        }
        self.select(BTreeSet::new(), BTreeSet::new());
        "Deleted from the storyline.".to_string()
    }

    /// Cmd+Opt+click on an attached clip: its attach point moves to the clicked time.
    // Swift: EditorSession+FastCut.swift:206
    pub fn set_attach_point_at(&mut self, id: Id, time: Time) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if !t.is_fast_cut() || !t.is_attachable(id) {
            return false;
        }
        let at = time.snapped(t.frame_duration());
        self.attempt_keyed_ids("Set Attach Point", None, |t, _| t.set_attach_point(id, at))
    }

    /// Delete Selection Only (Cmd+Opt+Delete); returns the status message.
    // Swift: EditorSession+FastCut.swift:141
    pub fn delete_selection_only(&mut self) -> String {
        if self.selection.is_empty() && self.caption_selection.is_empty() {
            return "Select clips first.".to_string();
        }
        let was = self.keep_attached_held;
        self.keep_attached_held = true;
        self.delete_selection(true, Some("Delete Selection Only"));
        self.keep_attached_held = was;
        "Deleted, attached clips kept.".to_string()
    }
}

impl EditorSession {
    /// The Fast Cut commands; enabled only in a Fast Cut sequence (`fast_cut_command_enabled`).
    // Swift: EditorSession+FastCut.swift:216
    pub const FAST_CUT_COMMANDS: [EditorCommand; 12] = [
        EditorCommand::AppendToMainTrack,
        EditorCommand::InsertSpacer,
        EditorCommand::LiftOffMainTrack,
        EditorCommand::PutOnMainTrack,
        EditorCommand::SetAttachPoint,
        EditorCommand::PasteAttached,
        EditorCommand::AttachBacktimed,
        EditorCommand::CreateStoryline,
        EditorCommand::StorylineRippleDelete,
        EditorCommand::MoveClipLeft,
        EditorCommand::MoveClipRight,
        EditorCommand::DeleteSelectionOnly,
    ];
}

/// One Fast Cut verb, replayable like any timeline edit. Built by `TimelineEdit::fast_cut` from what a gesture or
/// command would do in Normal.
// Swift: TimelineEdit+FastCut.swift:1
#[derive(Clone, Debug, PartialEq)]
pub enum FastCutEdit {
    /// Delete: main-track clips close up with their attached clips (`keep_attached`: those stay on their frame).
    Delete {
        ids: Vec<Id>,
        keep_attached: bool,
    },
    /// Replace with Spacer: main-track clips leave a hole, attached clips stay.
    ReplaceWithSpacer(Vec<Id>),
    RippleTrim {
        id: Id,
        edge: ClipEdge,
        by: Time,
    },
    Roll {
        id: Id,
        by: Time,
    },
    Slip {
        id: Id,
        by: Time,
        keyframes: SlipKeyframes,
    },
    Slide {
        id: Id,
        by: Time,
    },
    /// A main-track clip dragged along V1 (`to`: pre-edit time; it lands on the nearest V1 edit).
    Rearrange {
        id: Id,
        to: Time,
        keep_attached: bool,
    },
    /// An attached clip dragged (any track but V1); nothing else moves.
    MoveAttached {
        id: Id,
        to: Time,
        track: Option<Id>,
    },
    /// A main-track clip dragged onto another track: V1 closes, the clip becomes attached.
    DragOff {
        id: Id,
        track: Id,
        to: Time,
        keep_attached: bool,
    },
    /// An attached clip dragged onto V1: inserted at the nearest edit (`overwrite`: covers from `at`).
    DragOnto {
        id: Id,
        at: Time,
        overwrite: bool,
    },
    /// Cut at `at`: the given clips, or (empty) the main clip under `at` with its own sound.
    AddEdit {
        at: Time,
        clips: Vec<Id>,
    },
    AddEditAll {
        at: Time,
    },
    Nudge {
        ids: Vec<Id>,
        by: Time,
    },
    /// Delete on a spacer (a hole of V1) under `at`.
    DeleteSpacer {
        at: Time,
        keep_attached: bool,
    },
    /// Several main-track clips dragged at once by `by`: along V1 (`track` none or V1) one run at the nearest edit,
    /// else off V1 onto `track`.
    MoveBlock {
        ids: Vec<Id>,
        by: Time,
        track: Option<Id>,
        keep_attached: bool,
    },
    /// Option-drag / Cmd+Option-drag copies by `by`: onto V1 inserted, elsewhere attached.
    Copy {
        items: Vec<MagneticCopy>,
        by: Time,
    },
    /// Close Gap on a track other than V1: only that lane (and linked partners off V1) moves.
    CloseLaneGap {
        track: Id,
        at: Time,
    },
    RateStretch {
        id: Id,
        edge: ClipEdge,
        by: Time,
    },
    /// Speed/Duration or Reverse: main-track clips ripple V1 whatever the Ripple setting.
    Speed {
        ids: Vec<Id>,
        change: SpeedChange,
    },
    /// Create Storyline: the clips join the lane of the earliest one.
    CreateStoryline(Vec<Id>),
    /// Ripple delete inside a storyline: the later connected clips of the run close up.
    StorylineRippleDelete(Id),
    /// A storyline clip dragged along its lane: the run reorders and closes up.
    StorylineRearrange {
        id: Id,
        to: Time,
    },
    /// Position tool: the clip (with partners, `partners` = their target tracks) lands at `to` overwriting, leaves a hole.
    PositionMove {
        id: Id,
        to: Time,
        track: Option<Id>,
        partners: BTreeMap<Id, Id>,
    },
    /// Any other edit run with the Fast Cut rules (`Timeline::magnetic_edit`): attached clips follow or `stay`.
    Run {
        edits: Vec<TimelineEdit>,
        involving: Vec<Id>,
        stay: MagneticStay,
    },
}

impl FastCutEdit {
    /// Runs the verb on `t`.
    // Swift: TimelineEdit+FastCut.swift:49
    pub fn apply_to(&self, t: &mut Timeline, ids: &mut dyn IdSource) -> Result<(), EditError> {
        let set = |v: &[Id]| v.iter().copied().collect::<BTreeSet<Id>>();
        match self {
            FastCutEdit::Delete { ids: list, keep_attached } => t.magnetic_delete(&set(list), *keep_attached, ids),
            FastCutEdit::ReplaceWithSpacer(list) => t.replace_with_spacer(&set(list), ids),
            FastCutEdit::RippleTrim { id, edge, by } => t.magnetic_ripple_trim(*id, *edge, *by, ids).map(|_| ()),
            FastCutEdit::Roll { id, by } => t.magnetic_roll(*id, *by, ids).map(|_| ()),
            FastCutEdit::Slip { id, by, keyframes } => t.magnetic_slip(*id, *by, *keyframes, ids).map(|_| ()),
            FastCutEdit::Slide { id, by } => t.magnetic_slide(*id, *by, ids).map(|_| ()),
            FastCutEdit::Rearrange { id, to, keep_attached } => t.magnetic_rearrange(*id, *to, *keep_attached, ids),
            FastCutEdit::MoveAttached { id, to, track } => t.move_attached(*id, *to, *track, ids),
            FastCutEdit::DragOff { id, track, to, keep_attached } => {
                t.drag_off_main_track(*id, *track, *to, *keep_attached, ids)
            }
            FastCutEdit::DragOnto { id, at, overwrite } => t.drag_onto_main_track(*id, *at, *overwrite, ids),
            FastCutEdit::AddEdit { at, clips } => t.magnetic_add_edit(*at, &set(clips), ids).map(|_| ()),
            FastCutEdit::AddEditAll { at } => t.magnetic_add_edit_all(*at, ids).map(|_| ()),
            FastCutEdit::Nudge { ids: list, by } => t.magnetic_nudge(&set(list), *by, ids),
            FastCutEdit::DeleteSpacer { at, keep_attached } => t.delete_spacer(*at, *keep_attached, ids).map(|_| ()),
            FastCutEdit::MoveBlock { ids: list, by, track, keep_attached } => match track {
                Some(track) if Some(*track) != t.main_track_id() => {
                    t.drag_off_main_tracks(&set(list), *track, *by, *keep_attached, ids)
                }
                _ => t.magnetic_rearrange_block(&set(list), *by, *keep_attached, ids),
            },
            FastCutEdit::Copy { items, by } => t.magnetic_copy(items, *by, ids).map(|_| ()),
            FastCutEdit::CloseLaneGap { track, at } => t.close_lane_gap(*track, *at, ids).map(|_| ()),
            FastCutEdit::RateStretch { id, edge, by } => t.magnetic_rate_stretch(*id, *edge, *by, ids).map(|_| ()),
            FastCutEdit::Speed { ids: list, change } => t.magnetic_apply(change, list, ids),
            FastCutEdit::CreateStoryline(list) => t.create_storyline(&set(list), ids),
            FastCutEdit::StorylineRippleDelete(id) => t.storyline_ripple_delete(*id, ids),
            FastCutEdit::StorylineRearrange { id, to } => t.storyline_rearrange(*id, *to, ids),
            FastCutEdit::Run { edits, involving, stay } => {
                let scope = MagneticScope { involving: set(involving), stay: stay.clone(), ..MagneticScope::default() };
                t.magnetic_edit(scope, ids, |w, src| edits.iter().try_for_each(|e| e.apply(w, src)))
            }
            FastCutEdit::PositionMove { id, to, track, partners } => {
                // With retargeted partners (a drag onto another lane) the main-track end clamp of `position_move` is
                // skipped, exactly as in Swift (`TimelineEdit+FastCut.swift:79`).
                if partners.is_empty() {
                    t.position_move(*id, *to, *track, ids)
                } else {
                    let scope = MagneticScope {
                        involving: BTreeSet::from([*id]),
                        stay: MagneticStay::All,
                        ..MagneticScope::default()
                    };
                    t.magnetic_edit(scope, ids, |w, src| {
                        w.move_clip(*id, *to, *track, partners, None::<&CopySpec>, src).map(|_| ())
                    })
                }
            }
        }
    }
}

impl TimelineEdit {
    /// The clip a move edit drags.
    // Swift: TimelineEdit+FastCut.swift:238
    fn moved_clip(&self) -> Option<Id> {
        match self {
            TimelineEdit::Move { clip, .. }
            | TimelineEdit::MoveGroup { clip, .. }
            | TimelineEdit::MoveInsert { clip, .. }
            | TimelineEdit::InsertMove { clip, .. } => Some(*clip),
            _ => None,
        }
    }

    /// Where a move edit puts the dragged clip.
    // Swift: TimelineEdit+FastCut.swift:229
    fn move_target(&self) -> Option<Time> {
        match self {
            TimelineEdit::Move { to, .. }
            | TimelineEdit::MoveGroup { to, .. }
            | TimelineEdit::MoveInsert { to, .. }
            | TimelineEdit::InsertMove { to, .. } => Some(*to),
            _ => None,
        }
    }

    /// `edits` as Fast Cut does them in `t` (unchanged when `t` is not in Fast Cut). `keep_attached` (hold `) keeps the
    /// attached clips of the deleted or dragged main-track clips on their frame; `position` is the Position tool.
    // Swift: TimelineEdit+FastCut.swift:106
    pub fn fast_cut(edits: &[TimelineEdit], t: &Timeline, keep_attached: bool, position: bool) -> Vec<TimelineEdit> {
        let Some(main) = t.main_track_id().filter(|_| t.is_fast_cut()) else { return edits.to_vec() };
        let fc = TimelineEdit::FastCut;
        if position {
            let (mut rest, mut moves) = (Vec::new(), Vec::new());
            for e in edits {
                match e {
                    TimelineEdit::Move { clip, to, track } => moves.push(fc(FastCutEdit::PositionMove {
                        id: *clip,
                        to: *to,
                        track: *track,
                        partners: BTreeMap::new(),
                    })),
                    TimelineEdit::MoveGroup { clip, to, track, partners } => {
                        moves.push(fc(FastCutEdit::PositionMove {
                            id: *clip,
                            to: *to,
                            track: *track,
                            partners: partners.clone(),
                        }))
                    }
                    other => rest.push(other.clone()),
                }
            }
            let mut out = Self::fast_cut(&rest, t, keep_attached, false);
            out.extend(moves);
            return out;
        }
        let clip = |id: Id| t.tracks.iter().find_map(|tr| tr.clips().iter().find(|c| c.id == id));
        let is_main_move = |e: &TimelineEdit| e.moved_clip().is_some_and(|id| t.main_clip_of(id).is_some());
        let main_moves: Vec<&TimelineEdit> = edits.iter().filter(|e| is_main_move(e)).collect();
        let mains: BTreeSet<Id> =
            main_moves.iter().filter_map(|e| e.moved_clip().and_then(|id| t.main_clip_of(id))).collect();
        // The rearranged / dragged-off main clips carry their attached clips: their own moves would double them.
        let carried: BTreeSet<Id> =
            if keep_attached { BTreeSet::new() } else { t.attached_clips_of(&mains).into_iter().collect() };
        let block: Option<TimelineEdit> = if mains.len() > 1 {
            main_moves.first().and_then(|e| {
                let id = e.moved_clip()?;
                let m = t.main_clip_of(id)?;
                let c = clip(id)?;
                let target = match e {
                    TimelineEdit::Move { track, .. }
                    | TimelineEdit::MoveInsert { track, .. }
                    | TimelineEdit::InsertMove { track, .. } => (id == m).then_some(*track).flatten(),
                    TimelineEdit::MoveGroup { track, partners, .. } => {
                        if id == m {
                            *track
                        } else {
                            partners.get(&m).copied()
                        }
                    }
                    _ => None,
                };
                let to = e.move_target()?;
                let mut ordered: Vec<Id> = mains.iter().copied().collect();
                ordered.sort_by_key(|i| clip(*i).map(|c| c.start));
                Some(fc(FastCutEdit::MoveBlock { ids: ordered, by: to - c.start, track: target, keep_attached }))
            })
        } else {
            None
        };
        let copies: Vec<MagneticCopy> = edits
            .iter()
            .filter_map(|e| match e {
                TimelineEdit::CopyGroup { clip, track, partners, spec, .. } => {
                    Some(MagneticCopy { clip: *clip, track: *track, partners: partners.clone(), spec: spec.clone() })
                }
                TimelineEdit::InsertCopy { clip, track, spec, .. } => {
                    Some(MagneticCopy { clip: *clip, track: *track, partners: BTreeMap::new(), spec: spec.clone() })
                }
                _ => None,
            })
            .collect();
        let copy_delta: Option<Time> = edits.iter().find_map(|e| match e {
            TimelineEdit::CopyGroup { clip: id, to, .. } | TimelineEdit::InsertCopy { clip: id, to, .. } => {
                clip(*id).map(|c| *to - c.start)
            }
            _ => None,
        });
        let (mut emitted_block, mut emitted_copy) = (false, false);
        let mut moved_mains: BTreeSet<Id> = BTreeSet::new();
        let mut line_handled: BTreeSet<Id> = BTreeSet::new();
        let mut out = Vec::new();
        for e in edits {
            match e {
                TimelineEdit::Lift(ids) | TimelineEdit::RippleDelete(ids) => {
                    out.push(fc(FastCutEdit::Delete { ids: ids.clone(), keep_attached }));
                }
                TimelineEdit::Trim { clip, edge, by } | TimelineEdit::RippleTrim { clip, edge, by } => {
                    out.push(fc(FastCutEdit::RippleTrim { id: *clip, edge: *edge, by: *by }));
                }
                TimelineEdit::Roll { clip, by } => out.push(fc(FastCutEdit::Roll { id: *clip, by: *by })),
                TimelineEdit::Slip { clip, by, keyframes } => {
                    out.push(fc(FastCutEdit::Slip { id: *clip, by: *by, keyframes: *keyframes }));
                }
                TimelineEdit::Slide { clip, by } => out.push(fc(FastCutEdit::Slide { id: *clip, by: *by })),
                TimelineEdit::Nudge { clips, by } => out.push(fc(FastCutEdit::Nudge { ids: clips.clone(), by: *by })),
                TimelineEdit::Move { clip: id, to, track }
                | TimelineEdit::MoveGroup { clip: id, to, track, .. }
                | TimelineEdit::MoveInsert { clip: id, to, track }
                | TimelineEdit::InsertMove { clip: id, to, track } => {
                    if let (Some(block), true) = (&block, t.main_clip_of(*id).is_some()) {
                        if !emitted_block {
                            emitted_block = true;
                            out.push(block.clone());
                        }
                        continue;
                    }
                    if let (Some(m), Some(c)) = (t.main_clip_of(*id), clip(*id)) {
                        let Some(mc) = clip(m) else { continue };
                        // The partner's move would rearrange the same clip again, against the already changed layout.
                        if !moved_mains.insert(m) {
                            continue;
                        }
                        let target = if *id == m { *track } else { None }; // camera audio dragged: its main clip moves along V1
                        match target {
                            Some(target) if target != main => {
                                out.push(fc(FastCutEdit::DragOff { id: m, track: target, to: *to, keep_attached }))
                            }
                            _ => out.push(fc(FastCutEdit::Rearrange {
                                id: m,
                                to: mc.start + (*to - c.start),
                                keep_attached,
                            })),
                        }
                        continue;
                    }
                    if carried.contains(id) || line_handled.contains(id) {
                        continue;
                    }
                    // A storyline clip dragged along its own lane reorders the run (Fast Cut storylines are gapless).
                    if let Some(line) =
                        t.storyline_containing(*id).filter(|l| track.is_none() || *track == Some(l.track))
                    {
                        let _ = line;
                        line_handled.insert(*id);
                        if let Some(l) = clip(*id).and_then(|c| c.link) {
                            // linked partners travel with it
                            line_handled.extend(
                                t.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| c.link == Some(l)).map(|c| c.id),
                            );
                        }
                        out.push(fc(FastCutEdit::StorylineRearrange { id: *id, to: *to }));
                        continue;
                    }
                    if *track == Some(main) {
                        out.push(fc(FastCutEdit::DragOnto { id: *id, at: *to, overwrite: false }));
                    } else {
                        out.push(fc(FastCutEdit::MoveAttached { id: *id, to: *to, track: *track }));
                    }
                }
                TimelineEdit::CopyGroup { .. } | TimelineEdit::InsertCopy { .. } => {
                    if let (false, Some(d)) = (emitted_copy, copy_delta) {
                        emitted_copy = true;
                        out.push(fc(FastCutEdit::Copy { items: copies.clone(), by: d }));
                    }
                }
                TimelineEdit::AddEdit { at, tracks } => match tracks {
                    None => out.push(fc(FastCutEdit::AddEditAll { at: *at })),
                    Some(ids) => {
                        let under: Vec<Id> = t
                            .tracks
                            .iter()
                            .filter(|tr| ids.contains(&tr.id))
                            .flat_map(|tr| tr.clips().iter())
                            .filter(|c| c.start < *at && c.timeline().contains(*at))
                            .map(|c| c.id)
                            .collect();
                        if !under.is_empty() {
                            out.push(fc(FastCutEdit::AddEdit { at: *at, clips: under }));
                        }
                    }
                },
                TimelineEdit::CloseGap { track, at } => out.push(if *track == main {
                    fc(FastCutEdit::DeleteSpacer { at: *at, keep_attached })
                } else {
                    fc(FastCutEdit::CloseLaneGap { track: *track, at: *at })
                }),
                TimelineEdit::Only { clips, edits: inner } => {
                    // The partners held back are detached while the edit runs, so the inner edits are mapped against that
                    // layout: a sound dragged alone is a lone clip (not a rearrange of its video), V1 stays gapless.
                    let mut detached = t.clone();
                    let mut probe = t.clone();
                    let set: BTreeSet<Id> = clips.iter().copied().collect();
                    let _ = probe.editing_only(&set, &mut sq_core_time::SequentialIds::default(), |w, _| {
                        detached = w.clone();
                        Ok(())
                    });
                    out.push(TimelineEdit::Only {
                        clips: clips.clone(),
                        edits: Self::fast_cut(inner, &detached, keep_attached, false),
                    });
                }
                TimelineEdit::RateStretch { clip, edge, by } => {
                    out.push(fc(FastCutEdit::RateStretch { id: *clip, edge: *edge, by: *by }));
                }
                TimelineEdit::Speed { clips, change } => {
                    out.push(fc(FastCutEdit::Speed { ids: clips.clone(), change: change.clone() }));
                }
                TimelineEdit::ExtendEdit { .. } | TimelineEdit::SplitEditAudio { .. } => {
                    out.push(fc(FastCutEdit::Run {
                        edits: vec![e.clone()],
                        involving: Vec::new(),
                        stay: MagneticStay::All,
                    }));
                }
                TimelineEdit::AddTrack(_)
                | TimelineEdit::Link(_)
                | TimelineEdit::Unlink(_)
                | TimelineEdit::MoveCaption { .. }
                | TimelineEdit::TrimCaption { .. }
                | TimelineEdit::DeleteCaption(_)
                | TimelineEdit::RetimeCaptionWord { .. }
                | TimelineEdit::FastCut(_) => out.push(e.clone()),
            }
        }
        out
    }
}
