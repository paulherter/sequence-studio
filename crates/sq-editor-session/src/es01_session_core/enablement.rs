//! Edit helpers (`perform_timeline`, `attempt`), error messages, and the selection-driven enablement predicates and
//! shortcut commands (targets, edge selection, marker at playhead, sequence settings).

use std::collections::BTreeSet;

use sq_core_edit::playhead_after_ripple::PlayheadAfterRippleExt;
use sq_core_edit::timeline_join_cuts::TimelineJoinCutsExt;
use sq_core_edit::timeline_keyframe_navigation::TimelineKeyframeNavigationExt;
use sq_core_edit::timeline_mute_detach::TimelineMuteDetachExt;
use sq_core_edit::timeline_navigation::TimelineNavigationExt;
use sq_core_edit::timeline_replace::TimelineReplaceExt as _;
use sq_core_model::sequence_settings::SequenceSettings;
use sq_core_model::{Clip, ClipEdge, EditError, Project, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, Time};

use super::{EdgeRef, EdgeSelection};
use crate::EditorSession;

impl EditorSession {
    /// Shown when a sequence would contain itself.
    // Swift: EditorSession.swift:1595
    pub const NESTING_CYCLE_MESSAGE: &'static str =
        "A sequence cannot contain itself, nor a sequence that contains it.";

    /// The message of an edit error (English; the UI localizes it, the English text is the key).
    // Swift: EditorSession.swift:964
    pub fn message_for(error: &EditError) -> String {
        match error {
            EditError::TrackLocked => "The track is locked.",
            EditError::Collision => "Another clip is in the way.",
            EditError::NestingCycle => Self::NESTING_CYCLE_MESSAGE,
            EditError::InvalidFormat => "That sequence format is not valid.",
            EditError::ClipNotFound | EditError::TimelineNotFound => "The clip no longer exists.",
            EditError::WrongTrackKind => "That clip does not belong on this track.",
            EditError::EmptyClip => "Nothing to edit.",
            EditError::SpeedUnsupported => "Speed cannot be changed on that clip (titles and stills).",
            EditError::NotACut => "Transitions go on a cut between two clips that touch, or on a clip edge.",
            EditError::InsufficientMedia => {
                "Not enough media beyond the cut for a transition. Trim the clips to leave handles."
            }
            EditError::NotAGroup => "Select a group to ungroup.",
            EditError::NotNested => "Select a nested sequence to unnest.",
            EditError::UngroupLosesLook => {
                "Ungrouping would change how this group looks or sounds (its effects, speed or transitions, blend \
                 modes, dips or opacity over overlapping clips inside, track settings or markers inside)."
            }
            EditError::NotConvertible => "This clip cannot become a graphic without changing how it looks.",
            EditError::NoTrackToDelete => "Target the track to delete first (the lowest track of each kind stays).",
        }
        .to_string()
    }

    /// Edits the active timeline through `Project::edit`: a nesting cycle is refused with `NestingCycle`.
    // Swift: EditorSession.swift:432
    pub fn perform_timeline(
        &mut self,
        name: &str,
        key: Option<&str>,
        body: impl FnOnce(&mut Timeline) -> Result<(), EditError>,
    ) -> Result<(), EditError> {
        let id = self.active_timeline_id.ok_or(EditError::TimelineNotFound)?;
        self.try_perform(name, key, |p| {
            p.edit(id, |t| {
                body(t)?;
                t.normalize_audio_key_marks();
                Ok(())
            })
        })
    }

    /// `perform_timeline` for edits that create objects: the body gets the session's id source.
    pub(crate) fn perform_timeline_ids(
        &mut self,
        name: &str,
        key: Option<&str>,
        body: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<(), EditError>,
    ) -> Result<(), EditError> {
        self.with_ids(|s, ids| s.perform_timeline(name, key, |t| body(t, ids)))
    }

    /// `attempt` with a merge key whose body gets the session's id source.
    pub(crate) fn attempt_keyed_ids(
        &mut self,
        name: &str,
        key: Option<&str>,
        body: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<(), EditError>,
    ) -> bool {
        self.with_ids(|s, ids| s.attempt(name, key, |t| body(t, ids)))
    }

    /// `try_perform` over the whole project whose body gets the session's id source.
    pub(crate) fn perform_ids(
        &mut self,
        name: &str,
        key: Option<&str>,
        body: impl FnOnce(&mut Project, &mut dyn IdSource) -> Result<(), EditError>,
    ) -> Result<(), EditError> {
        self.with_ids(|s, ids| s.try_perform(name, key, |p| body(p, ids)))
    }

    /// `perform` over the whole project whose body gets the session's id source.
    pub(crate) fn perform_with_ids(&mut self, name: &str, edit: impl FnOnce(&mut Project, &mut dyn IdSource)) {
        self.with_ids(|s, ids| s.perform(name, None, |p| edit(p, ids)))
    }

    /// Like `perform_timeline`, but a refused edit only sets the status message. Returns whether it was applied.
    // Swift: EditorSession.swift:439
    pub fn attempt(
        &mut self,
        name: &str,
        key: Option<&str>,
        body: impl FnOnce(&mut Timeline) -> Result<(), EditError>,
    ) -> bool {
        let before = self.history.current().clone();
        if let Err(e) = self.perform_timeline(name, key, body) {
            self.set_error(Self::message_for(&e));
            return false;
        }
        *self.history.current() != before
    }

    /// `attempt` for edits that can ripple. The playhead keeps the picture it was on: it moves left by what the edit
    /// closed before it; inside a closed span it lands on the edit point. The move is remembered with the undo step,
    /// so Undo puts the playhead back and Redo moves it again. `ids` feeds the playhead probe.
    pub(crate) fn attempt_ripple_with(
        &mut self,
        name: &str,
        ids: &mut dyn sq_core_time::IdSource,
        body: impl FnOnce(&mut Timeline) -> Result<(), EditError>,
    ) -> bool {
        let at = self.playhead;
        let mut landed = at;
        let ok = self.attempt(name, None, |t| {
            landed = t.following_ripple(at, ids, body)?;
            Ok(())
        });
        if !ok {
            return false;
        }
        let frame = self.active_timeline().map(Timeline::frame_duration);
        let target = frame.map_or(landed, |f| landed.snapped(f)).max(Time::ZERO);
        if target < at
            && let Some(id) = self.active_timeline_id
        {
            self.seek_sequence(target); // sequence time, also while the monitor shows a source file
            let depth = self.history.undo_depth();
            self.playhead_steps.insert(depth, crate::PlayheadStep { timeline: id, before: at, after: target });
        }
        true
    }

    /// Nudge and Slide: need at least one selected clip.
    // Swift: EditorSession+CommandEnablement.swift:8
    pub fn can_nudge_or_slide_selection(&self) -> bool {
        !self.selection.is_empty() && self.active_timeline().is_some()
    }

    /// Select Next / Previous Clip: the last (first) selected clip has a neighbour on its track.
    // Swift: EditorSession+CommandEnablement.swift:11
    pub fn can_select_adjacent_clip(&self, forward: bool) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let picked = t.tracks.iter().flat_map(|tr| tr.clips().iter()).filter(|c| self.selection.contains(&c.id));
        let from = if forward {
            picked.reduce(|a, b| if a.timeline().end() < b.timeline().end() { b } else { a })
        } else {
            picked.reduce(|a, b| if b.start < a.start { b } else { a })
        };
        from.is_some_and(|c| t.neighbour_clip(c.id, forward).is_some())
    }

    /// Go to Selected Clip Start / End: the selection has an extent.
    // Swift: EditorSession+CommandEnablement.swift:20
    pub fn can_go_to_selected_clip_edge(&self) -> bool {
        self.active_timeline().is_some_and(|t| t.extent(&self.selection).is_some())
    }

    /// Trim to Range: a non-empty In/Out range and a selection.
    // Swift: EditorSession+CommandEnablement.swift:23
    pub fn can_trim_selection_to_range(&self) -> bool {
        if self.selection.is_empty() {
            return false;
        }
        self.active_timeline().and_then(|t| t.in_out).is_some_and(|r| !r.is_empty())
    }

    /// Solo: a selected clip (or its linked partner) lies on an audio track.
    // Swift: EditorSession+CommandEnablement.swift:35
    pub fn can_solo_selected_tracks(&self) -> bool {
        if self.selection.is_empty() {
            return false;
        }
        let Some(mut t) = self.active_timeline().cloned() else { return false };
        t.toggle_solo(&self.selection).is_some()
    }

    /// Mute: same reach as Solo.
    // Swift: EditorSession+CommandEnablement.swift:41
    pub fn can_mute_selected_tracks(&self) -> bool {
        self.can_solo_selected_tracks()
    }

    /// Detach Audio: a selected video clip has linked audio on an unlocked track.
    // Swift: EditorSession+CommandEnablement.swift:44
    pub fn can_detach_audio_selection(&self) -> bool {
        if self.selection.is_empty() {
            return false;
        }
        let Some(mut t) = self.active_timeline().cloned() else { return false };
        t.detach_audio(&self.selection).is_ok_and(|ids| !ids.is_empty())
    }

    /// Join Cuts: a through edit exists in the selection (the whole sequence when nothing is selected).
    // Swift: EditorSession+CommandEnablement.swift:50
    pub fn can_join_cuts(&self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let scope = (!self.selection.is_empty()).then_some(&self.selection);
        !t.through_edits(scope).is_empty()
    }

    /// Toggle All Targets: every track of the sequence is targeted, or, when all already are, none (one undo step).
    // Swift: EditorSession+ShortcutRest.swift:20
    pub fn can_toggle_all_targets(&self) -> bool {
        self.active_timeline().is_some_and(|t| !t.tracks.is_empty())
    }

    /// The state the next Toggle All Targets sets: true = all on.
    // Swift: EditorSession+ShortcutRest.swift:23
    pub fn toggle_all_targets_turns_on(&self) -> bool {
        self.active_timeline().is_some_and(|t| t.tracks.iter().any(|tr| !tr.is_targeted))
    }

    // Swift: EditorSession+ShortcutRest.swift:24
    pub fn toggle_all_targets(&mut self) -> bool {
        if !self.can_toggle_all_targets() {
            return false;
        }
        let on = self.toggle_all_targets_turns_on();
        self.attempt(Self::TARGET_ALL_NAME, None, |t| {
            for tr in t.tracks.iter_mut() {
                tr.is_targeted = on;
            }
            Ok(())
        });
        true
    }

    /// Undo name of a change of several track targets (Swift `TrackToggleNames.targetAll`, ES2).
    const TARGET_ALL_NAME: &'static str = "Change Track Targets";

    /// Toggle Video / Audio Targets: the same for the tracks of one kind (one undo step). False when there is none.
    // Swift: EditorSession+ShortcutRest.swift:34
    pub fn can_toggle_targets(&self, kind: TrackKind) -> bool {
        self.active_timeline().is_some_and(|t| t.tracks.iter().any(|tr| tr.kind == kind))
    }

    // Swift: EditorSession+ShortcutRest.swift:35
    pub fn toggle_targets(&mut self, kind: TrackKind) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if !self.can_toggle_targets(kind) {
            return false;
        }
        let on = t.tracks.iter().any(|tr| tr.kind == kind && !tr.is_targeted);
        self.attempt(Self::TARGET_ALL_NAME, None, |t| {
            for tr in t.tracks.iter_mut().filter(|tr| tr.kind == kind) {
                tr.is_targeted = on;
            }
            Ok(())
        });
        true
    }

    /// Track N (1-based) of a kind.
    fn nth_track(&self, kind: TrackKind, n: i64) -> Option<&Track> {
        if n < 1 {
            return None;
        }
        self.active_timeline()?.tracks.iter().filter(|t| t.kind == kind).nth(n as usize - 1)
    }

    // Swift: EditorSession+ShortcutRest.swift:50
    pub fn can_toggle_track_target(&self, kind: TrackKind, n: i64) -> bool {
        self.nth_track(kind, n).is_some()
    }

    /// Target track N (1-based) of a kind by key: toggles that track's target. False when there is no such track.
    // Swift: EditorSession+ShortcutRest.swift:52
    pub fn toggle_track_target(&mut self, kind: TrackKind, n: i64) -> bool {
        let Some(id) = self.nth_track(kind, n).map(|t| t.id) else { return false };
        self.toggle_tracks(id, crate::TrackToggle::Target, false);
        true
    }

    /// Lock / unlock the targeted tracks: all become locked unless they already are, then all unlock (one undo step).
    // Swift: EditorSession+ShortcutRest.swift:61
    pub fn can_toggle_lock_of_targets(&self) -> bool {
        self.active_timeline().is_some_and(|t| t.tracks.iter().any(|tr| tr.is_targeted))
    }

    // Swift: EditorSession+ShortcutRest.swift:62
    pub fn toggle_lock_of_targets(&mut self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if !self.can_toggle_lock_of_targets() {
            return false;
        }
        let on = t.tracks.iter().any(|tr| tr.is_targeted && !tr.is_locked);
        self.attempt(if on { "Lock Tracks" } else { "Unlock Tracks" }, None, |t| {
            for tr in t.tracks.iter_mut().filter(|tr| tr.is_targeted) {
                tr.is_locked = on;
            }
            Ok(())
        });
        true
    }

    /// Select Left / Right Edge: the head (tail) edges of the selected clips as an edge selection for the trim keys.
    /// `None` when no clip is selected. Not rippling.
    // Swift: EditorSession+ShortcutRest.swift:77
    pub fn edge_selection_of_selection(&self, edge: ClipEdge) -> Option<EdgeSelection> {
        let t = self.active_timeline()?;
        if self.selection.is_empty() {
            return None;
        }
        let edges: Vec<EdgeRef> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c: &&Clip| self.selection.contains(&c.id))
            .map(|c| EdgeRef::new(c.id, edge))
            .collect();
        (!edges.is_empty()).then(|| EdgeSelection::new(edges, false, true))
    }

    // Swift: EditorSession+ShortcutRest.swift:83
    pub fn can_select_edge_of_selection(&self) -> bool {
        self.edge_selection_of_selection(ClipEdge::Head).is_some()
    }

    /// The marker the Edit Marker command opens: one on the playhead frame, else a range marker that covers it.
    // Swift: EditorSession+ShortcutRest.swift:89
    pub fn marker_at_playhead(&self) -> Option<Id> {
        let t = self.active_timeline()?;
        let p = self.playhead;
        if let Some(m) = t.markers.iter().find(|m| m.time == p) {
            return Some(m.id);
        }
        t.markers.iter().find(|m| m.duration > Time::ZERO && m.time <= p && p < m.time + m.duration).map(|m| m.id)
    }

    // Swift: EditorSession+ShortcutRest.swift:94
    pub fn can_edit_marker_at_playhead(&self) -> bool {
        self.marker_at_playhead().is_some()
    }

    /// Sequence Settings of the active sequence: one undo step ("Sequence Settings"). False when nothing changed.
    // Swift: EditorSession+SequenceSettings.swift:6
    pub fn apply_sequence_settings(&mut self, s: &SequenceSettings) -> bool {
        let Some(id) = self.active_timeline_id else { return false };
        let Some(current) = self.active_timeline().map(Timeline::settings) else { return false };
        let mut wanted = s.clone();
        if wanted.name.trim().is_empty() {
            wanted.name = current.name.clone();
        }
        if wanted == current {
            return false;
        }
        if let Err(e) = self.try_perform("Sequence Settings", None, |p| p.set_settings(&wanted, id)) {
            self.set_error(Self::message_for(&e));
            return false;
        }
        true
    }

    /// Ids of the selected clips on the active timeline (helper for the predicates above).
    #[allow(dead_code)] // shortcut: first caller comes with the selection methods
    pub(crate) fn selected_ids(&self) -> BTreeSet<Id> {
        self.selection.clone()
    }
}
