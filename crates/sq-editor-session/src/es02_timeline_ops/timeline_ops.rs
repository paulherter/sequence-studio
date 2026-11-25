//! Timeline operations on the selection: clipboard, link, nudge, edge trims, gaps, markers, tracks, marks, lane moves.

use std::collections::BTreeSet;

use sq_core_edit::timeline_edits::SlipKeyframes;
use sq_core_edit::timeline_trim_to_playhead::PlayheadTrimMode;
use sq_core_model::{Clip, ClipEdge, EditError, LabelColor, MarkerColor, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

use super::EdgeEdits;
use super::prelude::*;
use super::track_toggles::TrackToggleNames;
use crate::EditorSession;
use crate::{GapSelection, TimelineEdit};

/// Clip > Link menu state: enabled with two or more clips or any linked clip selected; `unlink` when the selection is
/// one linked group.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LinkMenuState {
    pub enabled: bool,
    pub unlink: bool,
}

/// What M did: the marker, and whether it already existed (the host then opens its dialog).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MarkAtPlayhead {
    pub id: Id,
    pub open_edit: bool,
}

impl EditorSession {
    fn selected_clips(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        t.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| self.selection.contains(&c.id)).cloned().collect()
    }

    // MARK: Clipboard

    /// Cmd+C. False when no clip is selected. Fast Cut: copied main-track clips take their attached clips along.
    // Swift: EditorSession+TimelineOps.swift:9
    pub fn copy_selection(&mut self) -> bool {
        let Some(cb) = self.active_timeline().and_then(|t| t.magnetic_clipboard(&self.selection)) else { return false };
        self.clipboard = Some(cb);
        self.built_in_clipboard = None;
        self.effect_clipboard = None; // the latest copy wins: Cmd-V pastes clips again
        true
    }

    /// True when an effect was copied (in Effect Controls) and a selected clip can take it.
    // Swift: EditorSession+TimelineOps.swift:19
    pub fn can_paste_effect_clipboard(&self) -> bool {
        let (Some(e), Some(t)) = (&self.effect_clipboard, self.active_timeline()) else { return false };
        let ids = self.effect_paste_targets(e);
        t.tracks.iter().flat_map(|tr| tr.clips()).any(|c| ids.contains(&c.id) && c.can_accept_pasted_effect(e))
    }

    /// Clips a pasted effect goes to: the selection; an audio effect goes to the selected audio clips and to the audio
    /// linked to a selected video clip.
    fn effect_paste_targets(&self, e: &sq_core_model::ClipEffect) -> BTreeSet<Id> {
        if e.is_audio() { self.audio_effect_targets(&self.selection) } else { self.selection.clone() }
    }

    /// Cmd-V with an effect copied: adds a copy behind the effects of every selected clip that can take it (one undo
    /// step), whether or not Effect Controls is open.
    // Swift: EditorSession+TimelineOps.swift:33
    pub fn paste_effect_clipboard(&mut self) -> bool {
        let Some(e) = self.effect_clipboard.clone().filter(|_| self.can_paste_effect_clipboard()) else { return false };
        let targets = self.effect_paste_targets(&e);
        self.with_ids(|s, ids| {
            s.attempt("Paste Effect", None, |t| {
                let mut n = 0;
                for id in &targets {
                    let Some(mut c) = t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == *id).cloned() else {
                        continue;
                    };
                    if !c.can_accept_pasted_effect(&e) {
                        continue;
                    }
                    if sq_core_model::EffectCatalog::is_generator_owned(&e.kind) {
                        let mut copy = e.clone();
                        copy.id = ids.next_id();
                        match c.effects.iter().position(|x| x.kind == e.kind) {
                            Some(i) => c.effects[i] = copy,
                            None => c.effects.insert(0, copy),
                        }
                    } else if !c.insert_pasted_effect(&e, ids) {
                        continue;
                    }
                    t.replace_clip(c)?;
                    n += 1;
                }
                if n == 0 { Err(EditError::EmptyClip) } else { Ok(()) }
            })
        })
    }

    /// Cmd+X: copy, then lift (Cmd+Shift+X is not bound).
    // Swift: EditorSession+TimelineOps.swift:53
    pub fn cut_selection(&mut self) {
        if self.copy_selection() {
            self.delete_selection(false, Some("Cut"));
        }
    }

    /// Cmd+V (overwrite at the playhead) or Cmd+Shift+V (insert), onto the tracks the clips were copied from;
    /// `to_targets` is Paste to Targeted Track. The pasted clips become the selection and the playhead moves to their
    /// end. `attached` (Fast Cut, Opt+V): everything lands off V1 at the playhead, attached, nothing rippling.
    // Swift: EditorSession+TimelineOps.swift:62
    pub fn paste_clipboard(&mut self, insert: bool, to_targets: bool, attached: bool) {
        let Some(cb) = self.clipboard.clone().filter(|c| !c.is_empty()) else { return };
        let Some(tl) = self.active_timeline() else { return };
        let at = self.playhead;
        let lanes = to_targets.then(|| tl.target_lanes(&cb));
        let fast = tl.is_fast_cut();
        let name = if attached {
            "Paste Attached"
        } else if insert {
            "Paste Insert"
        } else {
            "Paste"
        };
        let mut made: Vec<Id> = Vec::new();
        let mut end = None;
        let done = self.with_ids(|s, ids| {
            s.attempt(name, None, |t| {
                // Fast Cut: main-track copies insert on V1 (no hole, attached copies come along); the rest attaches.
                made = if fast {
                    t.magnetic_paste(&cb, at, attached, ids)?
                } else {
                    t.paste(&cb.stripping_attachments(), at, lanes.as_ref(), insert, ids)? // Normal: no attach links
                };
                end = t.end_of(&made);
                Ok(())
            })
        });
        if !done {
            return;
        }
        if let Some(end) = end {
            self.seek_sequence(end);
        }
        self.select(made.into_iter().collect(), BTreeSet::new());
    }

    // MARK: Link

    /// Clip > Link menu state.
    // Swift: EditorSession+TimelineOps.swift:83
    pub fn link_menu_state(&self) -> LinkMenuState {
        let clips = self.selected_clips();
        let links: BTreeSet<Option<Id>> = clips.iter().map(|c| c.link).collect();
        LinkMenuState {
            enabled: clips.len() >= 2 || clips.iter().any(|c| c.link.is_some()),
            unlink: links.len() == 1 && links.iter().next().is_some_and(Option::is_some),
        }
    }

    /// Cmd+L: unlinks when the selection is one linked group, otherwise links the selected clips.
    // Swift: EditorSession+TimelineOps.swift:91
    pub fn toggle_link_selection(&mut self) {
        if self.active_timeline().is_none() {
            return;
        }
        let clips = self.selected_clips();
        if !(clips.len() >= 2 || clips.iter().any(|c| c.link.is_some())) {
            return;
        }
        let ids = self.selection.clone();
        let links: BTreeSet<Option<Id>> = clips.iter().map(|c| c.link).collect();
        if links.len() == 1 && links.iter().next().is_some_and(Option::is_some) {
            self.attempt("Unlink", None, |t| t.unlink(&ids));
        } else if clips.len() >= 2 {
            self.with_ids(|s, src| s.attempt("Link", None, |t| t.link(&ids, src)));
        } else {
            self.attempt("Unlink", None, |t| t.unlink(&ids));
        }
    }

    /// Unlink (Final Cut's Detach Audio): the selected clips and their partners become independent. False when nothing is linked.
    // Swift: EditorSession+TimelineOps.swift:103
    pub fn unlink_selection(&mut self) -> bool {
        if self.active_timeline().is_none() || !self.selected_clips().iter().any(|c| c.link.is_some()) {
            return false;
        }
        let ids = self.selection.clone();
        self.attempt("Unlink", None, |t| t.unlink(&ids));
        true
    }

    /// Solo of the audio tracks of the selected clips (and their linked partners). `None`: no audio clip selected.
    // Swift: EditorSession+TimelineOps.swift:113
    pub fn solo_selected_tracks(&mut self) -> Option<bool> {
        if self.selection.is_empty() {
            return None;
        }
        let on = self.active_timeline()?.clone().toggle_solo(&self.selection)?;
        let ids = self.selection.clone();
        self.attempt(if on { "Solo" } else { "Unsolo" }, None, |t| {
            t.toggle_solo(&ids);
            Ok(())
        });
        Some(on)
    }

    /// Mute of the audio tracks of the selected clips (and their linked partners), toggled like Solo.
    // Swift: EditorSession+TimelineOps.swift:121
    pub fn mute_selected_tracks(&mut self) -> Option<bool> {
        if self.selection.is_empty() {
            return None;
        }
        let on = self.active_timeline()?.clone().toggle_mute(&self.selection)?;
        let ids = self.selection.clone();
        self.attempt(if on { "Mute" } else { "Unmute" }, None, |t| {
            t.toggle_mute(&ids);
            Ok(())
        });
        Some(on)
    }

    /// Detach Audio: the audio clips linked to the selected video clips become independent clips where they are, and the
    /// selection moves to them. False when nothing was detachable.
    // Swift: EditorSession+TimelineOps.swift:130
    pub fn detach_audio_selection(&mut self) -> bool {
        let Some(mut probe) = self.active_timeline().cloned() else { return false };
        let Ok(ids) = probe.detach_audio(&self.selection) else { return false };
        if ids.is_empty() {
            return false;
        }
        let sel = self.selection.clone();
        self.attempt("Detach Audio", None, |t| t.detach_audio(&sel).map(|_| ()));
        self.select(ids.into_iter().collect(), BTreeSet::new());
        true
    }

    /// Next / Previous Keyframe: the selected clips' keys, else the clips under the playhead. False when none lies that way.
    // Swift: EditorSession+TimelineOps.swift:139
    pub fn go_to_keyframe(&mut self, forward: bool) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let mut ids = self.selection.clone();
        if ids.is_empty() {
            let p = self.playhead;
            ids =
                t.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| c.timeline().contains(p)).map(|c| c.id).collect();
        }
        let time =
            if forward { t.next_keyframe(self.playhead, &ids) } else { t.previous_keyframe(self.playhead, &ids) };
        let Some(time) = time else { return false };
        self.seek_sequence(time);
        true
    }

    /// Trim to In/Out: the selected clips are cut back to the In-Out range. Returns the count.
    // Swift: EditorSession+TimelineOps.swift:154
    pub fn trim_selection_to_range(&mut self) -> usize {
        let Some(r) = self.active_timeline().and_then(|t| t.in_out).filter(|r| !r.is_empty()) else { return 0 };
        if self.selection.is_empty() {
            return 0;
        }
        let ids = self.selection.clone();
        let mut n = 0;
        self.with_ids(|s, src| {
            s.attempt("Trim to In/Out", None, |t| {
                n = t.trim_to_range(&ids, r, src)?;
                Ok(())
            })
        });
        n
    }

    // MARK: Nudge, edge trims, extend, gaps

    /// Cmd+Left / Cmd+Right (Shift: 10 frames): moves the selected clips by whole frames, or the selected opacity /
    /// volume line keys when keys are selected (`select_line_keys`).
    // Swift: EditorSession+TimelineOps.swift:167
    pub fn nudge_selection(&mut self, frames: i64) {
        if self.nudge_line_keys(frames) {
            return; // selected line keys move instead of the clips
        }
        let Some(t) = self.active_timeline() else { return };
        if self.selection.is_empty() {
            return;
        }
        let ids = self.selection.clone();
        let d = t.frame_duration() * frames;
        // Fast Cut: main-track clips slide between their neighbors with their attached clips; attached clips move.
        let fast = t.is_fast_cut();
        self.with_ids(|s, src| {
            if fast {
                s.attempt("Nudge Clips", None, |t| t.magnetic_nudge(&ids, d, src));
            } else {
                s.attempt("Nudge Clips", None, |t| {
                    t.editing_only(&ids, src, |t, src| t.nudge(&ids, d, src).map(|_| ()))
                });
            }
        });
    }

    /// Opt+Left / Opt+Right with clips selected and no edit: slips the selected clips by `n` frames.
    // Swift: EditorSession+TimelineOps.swift:177
    pub fn slip_selection(&mut self, frames: i64, keyframes: SlipKeyframes) {
        let Some(t) = self.active_timeline() else { return };
        if self.selection.is_empty() {
            return;
        }
        let ids = self.selection.clone();
        let d = t.frame_duration() * frames;
        self.with_ids(|s, src| {
            s.attempt("Slip", None, |tl| {
                // A linked pair slips together: once per link, not once per selected member.
                let mut seen: BTreeSet<Id> = BTreeSet::new();
                let clips: Vec<Clip> =
                    tl.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| ids.contains(&c.id)).cloned().collect();
                for c in clips {
                    if let Some(l) = c.link
                        && !seen.insert(l)
                    {
                        continue;
                    }
                    tl.magnetic_slip(c.id, d, keyframes, src)?; // Fast Cut: attached clips stay
                }
                Ok(())
            })
        });
    }

    /// Opt+Left / Opt+Right with an edit selected: moves the selected edge(s) by `n` frames.
    // Swift: EditorSession+TimelineOps.swift:190
    pub fn trim_edges(&mut self, sel: &crate::EdgeSelection, frames: i64) {
        let Some(t) = self.active_timeline() else { return };
        let delta = t.frame_duration() * frames;
        let edits = TimelineEdit::fast_cut(
            &TimelineEdit::scoped(EdgeEdits::trim(sel, delta, t), sel.scope().as_ref(), t),
            t,
            self.keep_attached_held,
            false,
        );
        let name = if EdgeEdits::is_roll(sel, t) {
            "Move Edit"
        } else if sel.ripple {
            "Ripple Trim"
        } else {
            "Trim Clip"
        };
        self.run_edits(edits, name);
    }

    /// E: moves the selected edit to the playhead.
    // Swift: EditorSession+TimelineOps.swift:198
    pub fn extend_edit(&mut self, sel: &crate::EdgeSelection) {
        let Some(t) = self.active_timeline() else { return };
        let edits = TimelineEdit::fast_cut(
            &TimelineEdit::scoped(EdgeEdits::extend(sel, self.playhead, t), sel.scope().as_ref(), t),
            t,
            self.keep_attached_held,
            false,
        );
        self.run_edits(edits, "Extend Edit");
    }

    // Swift: EditorSession+TimelineOps.swift:205
    fn run_edits(&mut self, edits: Vec<TimelineEdit>, name: &str) {
        if edits.is_empty() {
            return;
        }
        self.attempt_ripple_ids(name, |t, ids| edits.iter().try_for_each(|e| e.apply(t, ids)));
    }

    /// Status line when content on another track (a caption, a title, audio) keeps a deleted gap from closing fully.
    pub const GAP_BLOCKED_MESSAGE: &'static str = "Ripple Delete limited by content on another track.";

    /// Status line when a caption keeps a Normal-mode ripple trim or speed change from closing all of its span (the edit
    /// stops at the caption instead of deleting it). Fast Cut pulls the caption in instead and never says this.
    pub const CAPTION_BLOCKED_MESSAGE: &'static str = "Ripple limited by a caption.";

    /// Delete on a selected gap: ripple-deletes it. Fast Cut: a gap on V1 is a spacer; a gap between attached clips
    /// closes on its track only.
    // Swift: EditorSession+TimelineOps.swift:212
    pub fn close_gap(&mut self, gap: &GapSelection) {
        let Some(t) = self.active_timeline() else { return };
        let edits = TimelineEdit::fast_cut(
            &[TimelineEdit::CloseGap { track: gap.track, at: gap.range.start }],
            t,
            self.keep_attached_held,
            false,
        );
        let name =
            if t.is_fast_cut() && Some(gap.track) == t.main_track_id() { "Delete Spacer" } else { "Ripple Delete" };
        // Never limit silently: content on another track (a caption, a title, audio) keeps the gap open there.
        let limited = !t.is_fast_cut()
            && t.gap_closable(gap.track, gap.range.start).is_some_and(|closable| closable < gap.range.duration);
        self.attempt_ripple_ids(name, |t, ids| edits.iter().try_for_each(|e| e.apply(t, ids)));
        if limited {
            self.set_error(Self::GAP_BLOCKED_MESSAGE.to_string());
        }
    }

    // MARK: Markers

    /// M: adds a marker at the playhead. When one already sits on that frame nothing is added and its id comes back so
    /// the host can open the marker dialog (M twice).
    // Swift: EditorSession+TimelineOps.swift:224
    pub fn mark_at_playhead(&mut self) -> Option<MarkAtPlayhead> {
        let mut probe = self.active_timeline()?.clone();
        let at = self.playhead;
        let (id, open_edit) = self.with_ids(|_, src| probe.mark_at_playhead(at, src));
        if open_edit {
            return Some(MarkAtPlayhead { id, open_edit });
        }
        let mut made = None;
        self.with_ids(|s, src| {
            s.attempt("Add Marker", None, |t| {
                made = Some(t.mark_at_playhead(at, src).0);
                Ok(())
            })
        });
        made.map(|id| MarkAtPlayhead { id, open_edit: false })
    }

    /// Marker dialog OK: name, color, comment.
    // Swift: EditorSession+TimelineOps.swift:236
    pub fn edit_marker(&mut self, id: Id, name: &str, color: MarkerColor, comment: &str) {
        self.attempt("Edit Marker", None, |t| {
            t.update_marker(id, |m| {
                m.name = name.to_string();
                m.color = color;
                m.comment = comment.to_string();
            });
            Ok(())
        });
    }

    /// Marker dialog OK with a duration: name, color, comment and range length in one undo step.
    // Swift: EditorSession+TimelineOps.swift:241
    pub fn edit_marker_with_duration(&mut self, id: Id, name: &str, color: MarkerColor, comment: &str, duration: Time) {
        self.attempt("Edit Marker", None, |t| {
            t.update_marker(id, |m| {
                m.name = name.to_string();
                m.color = color;
                m.comment = comment.to_string();
            });
            if t.set_marker_duration(id, duration) { Ok(()) } else { Err(EditError::ClipNotFound) }
        });
    }

    /// Drag of a range marker's end: one undo step.
    // Swift: EditorSession+TimelineOps.swift:249
    pub fn set_marker_duration(&mut self, id: Id, duration: Time) {
        self.attempt("Set Marker Duration", None, |t| {
            if t.set_marker_duration(id, duration) { Ok(()) } else { Err(EditError::ClipNotFound) }
        });
    }

    // Swift: EditorSession+TimelineOps.swift:254
    pub fn delete_marker(&mut self, id: Id) {
        self.attempt("Delete Marker", None, |t| {
            t.remove_marker(id);
            Ok(())
        });
    }

    // MARK: Clip markers (flags on the clip itself; source time, so they follow trims and splits)

    /// Context menu Add Clip Marker: a marker on `clip` at sequence time `time`.
    // Swift: EditorSession+TimelineOps.swift:260
    pub fn add_clip_marker(&mut self, clip: Id, time: Time) -> Option<Id> {
        let mut made = None;
        self.with_ids(|s, src| {
            s.attempt("Add Clip Marker", None, |t| {
                made = t.add_clip_marker(clip, time, "", MarkerColor::default(), src);
                if made.is_none() { Err(EditError::ClipNotFound) } else { Ok(()) }
            })
        });
        made
    }

    /// Drag of a clip marker flag (one step per drag).
    // Swift: EditorSession+TimelineOps.swift:271
    pub fn move_clip_marker(&mut self, id: Id, clip: Id, time: Time) {
        self.attempt("Move Clip Marker", None, |t| {
            if t.move_clip_marker(id, clip, time) { Ok(()) } else { Err(EditError::ClipNotFound) }
        });
    }

    // Swift: EditorSession+TimelineOps.swift:276
    pub fn edit_clip_marker(&mut self, id: Id, clip: Id, name: &str, color: MarkerColor, comment: &str) {
        self.attempt("Edit Clip Marker", None, |t| {
            let ok = t.update_clip_marker(id, clip, |m| {
                m.name = name.to_string();
                m.color = color;
                m.comment = comment.to_string();
            });
            if ok { Ok(()) } else { Err(EditError::ClipNotFound) }
        });
    }

    // Swift: EditorSession+TimelineOps.swift:284
    pub fn delete_clip_marker(&mut self, id: Id, clip: Id) {
        self.attempt("Delete Clip Marker", None, |t| {
            if t.remove_clip_marker(id, clip) { Ok(()) } else { Err(EditError::ClipNotFound) }
        });
    }

    // MARK: Tracks

    /// New empty track of `kind` after the last one of that kind (a new top video track, a new bottom audio track).
    // Swift: EditorSession+TimelineOps.swift:294
    pub fn add_track(&mut self, kind: TrackKind) {
        self.with_ids(|s, src| {
            s.attempt(if kind == TrackKind::Video { "Add Video Track" } else { "Add Audio Track" }, None, |t| {
                sq_core_edit::timeline_add_track::AddTrackExt::insert_track_after_last(t, kind, src);
                Ok(())
            })
        });
    }

    /// Sequence > Remove Empty Tracks; the status line says what went.
    // Swift: EditorSession+TimelineOps.swift:302
    pub fn remove_empty_tracks(&mut self) {
        let Some(t) = self.active_timeline() else { return };
        let mut probe = t.clone();
        if probe.remove_empty_tracks().is_empty() {
            self.set_error("No empty tracks to remove.");
            return;
        }
        self.attempt("Remove Empty Tracks", None, |t| {
            t.remove_empty_tracks();
            Ok(())
        });
    }

    /// Sequence > Delete Track: removes the targeted tracks with their clips as one undo step.
    // Swift: EditorSession+TimelineOps.swift:311
    pub fn delete_targeted_tracks(&mut self) {
        self.attempt("Delete Track", None, |t| t.delete_targeted_tracks().map(|_| ()));
    }

    /// Snapping belongs to the sequence and each change is one undo step. Returns whether it changed anything.
    // Swift: EditorSession+TimelineOps.swift:317
    pub fn set_snapping(&mut self, on: bool) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if (t.snapping_off_store != Some(true)) == on {
            return false;
        }
        self.attempt(if on { "Snapping On" } else { "Snapping Off" }, None, |t| {
            t.snapping_off_store = (!on).then_some(true);
            Ok(())
        })
    }

    /// Linked Selection belongs to the sequence; `linked_selection` mirrors the new value for session-made selections.
    // Swift: EditorSession+TimelineOps.swift:322
    pub fn set_linked_selection(&mut self, on: bool) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if (t.linked_selection_off_store != Some(true)) == on {
            return false;
        }
        let ok = self.attempt(if on { "Linked Selection On" } else { "Linked Selection Off" }, None, |t| {
            t.linked_selection_off_store = (!on).then_some(true);
            Ok(())
        });
        if ok {
            self.linked_selection = on;
        }
        ok
    }

    /// Deletes a track with its clips (undoable). A locked track is refused.
    // Swift: EditorSession+TimelineOps.swift:333
    pub fn delete_track(&mut self, id: Id) {
        self.attempt("Delete Track", None, |t| t.remove_track(id));
    }

    /// Track header menu Move Up / Move Down: trades places with the next track of its kind.
    // Swift: EditorSession+TimelineOps.swift:338
    pub fn move_track(&mut self, id: Id, up: bool) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if t.track(id).is_none() {
            return false;
        }
        if t.move_track_neighbor(id, up).is_none() {
            let msg = if t.is_fast_cut() && t.main_track_id() == Some(id) {
                "The main track of a Fast Cut sequence stays at the bottom.".to_string()
            } else {
                format!("The track cannot go further {}.", if up { "up" } else { "down" })
            };
            self.set_error(msg);
            return false;
        }
        self.attempt(if up { "Move Track Up" } else { "Move Track Down" }, None, |t| {
            t.move_track(id, up);
            Ok(())
        })
    }

    // Swift: EditorSession+TimelineOps.swift:348
    pub fn rename_track(&mut self, id: Id, name: &str) {
        let n = name.trim().to_string();
        self.attempt("Rename Track", None, |t| {
            if let Some(tr) = t.tracks.iter_mut().find(|tr| tr.id == id) {
                tr.name = n;
            }
            Ok(())
        });
    }

    // MARK: Rename and label

    /// Context menu Rename: the one selected clip (the video clip of a selected linked pair). A blank name is ignored.
    // Swift: EditorSession+TimelineOps.swift:359
    pub fn rename_selected_clip(&mut self, name: &str) {
        let n = name.trim().to_string();
        let (true, Some(id)) = (!n.is_empty(), self.single_selected_clip().map(|c| c.id)) else { return };
        self.attempt("Rename Clip", None, |t| {
            let Some(mut c) = t.tracks.iter().flat_map(|tr| tr.clips()).find(|c| c.id == id).cloned() else {
                return Ok(());
            };
            c.name = n;
            t.replace_clip(c)
        });
    }

    /// Context menu Label: color of the selected clips (`None` = back to the default of its type).
    // Swift: EditorSession+TimelineOps.swift:370
    pub fn set_label(&mut self, label: Option<LabelColor>) {
        if self.selection.is_empty() {
            return;
        }
        let ids = self.selection.clone();
        self.attempt("Change Label", None, |t| {
            let clips: Vec<Clip> = t
                .tracks
                .iter()
                .flat_map(|tr| tr.clips())
                .filter(|c| ids.contains(&c.id) && c.label != label)
                .cloned()
                .collect();
            for mut c in clips {
                c.label = label;
                t.replace_clip(c)?;
            }
            Ok(())
        });
    }

    // MARK: Selection and marks

    /// Cmd+A: every clip of the active sequence.
    // Swift: EditorSession+TimelineOps.swift:384
    pub fn select_all_clips(&mut self) {
        let Some(t) = self.active_timeline() else { return };
        let all = t.tracks.iter().flat_map(|tr| tr.clips()).map(|c| c.id).collect();
        self.select(all, BTreeSet::new());
    }

    /// Track header menu "Select All Clips on Track": every clip of that track (none on a locked track).
    // Swift: EditorSession+TimelineOps.swift:391
    pub fn select_all_clips_on_track(&mut self, track: Id) {
        let Some(tr) = self.active_timeline().and_then(|t| t.track(track)).filter(|tr| !tr.is_locked) else { return };
        let all = tr.clips().iter().map(|c| c.id).collect();
        self.select(all, BTreeSet::new());
    }

    /// D: selects the clips under the playhead on the targeted tracks (all tracks when none is targeted).
    // Swift: EditorSession+TimelineOps.swift:397
    pub fn select_clip_at_playhead(&mut self) {
        let Some(t) = self.active_timeline() else { return };
        let any_targeted = t.tracks.iter().any(|tr| tr.is_targeted);
        let p = self.playhead;
        let hit = t
            .tracks
            .iter()
            .filter(|tr| !any_targeted || tr.is_targeted)
            .flat_map(|tr| tr.clips())
            .filter(|c| c.timeline().contains(p))
            .map(|c| c.id)
            .collect();
        let sel = self.expanding_links(&hit);
        self.select(sel, BTreeSet::new());
    }

    /// Shift+Up / Shift+Down: edit points of every track, ignoring targets.
    // Swift: EditorSession+TimelineOps.swift:405
    pub fn go_to_edit_point_on_any_track(&mut self, forward: bool) {
        let Some(pts) = self.active_timeline().map(sq_core_effects::evaluation::TimelineEvaluation::edit_points) else {
            return;
        };
        let p = self.playhead;
        let target = if forward { pts.iter().find(|t| **t > p) } else { pts.iter().rev().find(|t| **t < p) };
        if let Some(t) = target.copied() {
            self.seek_sequence(t);
        }
    }

    /// `/`: In/Out around the selected clips.
    // Swift: EditorSession+TimelineOps.swift:412
    pub fn mark_selection(&mut self) {
        let ranges: Vec<TimeRange> = self.selected_clips().iter().map(Clip::timeline).collect();
        let (Some(lo), Some(hi)) = (ranges.iter().map(|r| r.start).min(), ranges.iter().map(|r| r.end()).max()) else {
            return;
        };
        self.attempt("Mark Selection", None, |t| {
            t.set_marked_range(Some(TimeRange::from_end(lo, hi)));
            Ok(())
        });
    }

    /// Mark Overhang: In/Out around the lead or trail where linked clips (a J or L cut) do not line up.
    // Swift: EditorSession+TimelineOps.swift:420
    pub fn mark_overhang(&mut self) {
        let Some(r) = self.active_timeline().and_then(|t| t.mark_overhang_range(self.playhead, &self.selection)) else {
            return;
        };
        self.attempt("Mark Overhang", None, |t| {
            t.set_marked_range(Some(r));
            Ok(())
        });
    }

    // Swift: EditorSession+TimelineOps.swift:424
    pub fn can_mark_overhang(&self) -> bool {
        self.active_timeline().is_some_and(|t| t.mark_overhang_range(self.playhead, &self.selection).is_some())
    }

    // Swift: EditorSession+TimelineOps.swift:425
    pub fn go_to_next_split_point(&mut self) {
        if let Some(t) = self.active_timeline().and_then(|t| t.next_split_point(self.playhead)) {
            self.seek_sequence(t);
        }
    }

    // Swift: EditorSession+TimelineOps.swift:427
    pub fn go_to_previous_split_point(&mut self) {
        if let Some(t) = self.active_timeline().and_then(|t| t.previous_split_point(self.playhead)) {
            self.seek_sequence(t);
        }
    }

    /// Shift+M.
    // Swift: EditorSession+TimelineOps.swift:430
    pub fn go_to_next_marker(&mut self) {
        if let Some(t) = self.active_timeline().and_then(|t| t.next_marker(self.playhead)).map(|m| m.time) {
            self.seek_sequence(t);
        }
    }

    /// Cmd+Shift+M.
    // Swift: EditorSession+TimelineOps.swift:431
    pub fn go_to_previous_marker(&mut self) {
        if let Some(t) = self.active_timeline().and_then(|t| t.previous_marker(self.playhead)).map(|m| m.time) {
            self.seek_sequence(t);
        }
    }

    // MARK: Premiere parity (2026-10)

    /// Opt+, / Opt+. : slides the selected clips by `n` frames (neighbors give or take the time; linked pairs once).
    // Swift: EditorSession+TimelineOps.swift:436
    pub fn slide_selection(&mut self, frames: i64) {
        let Some(t) = self.active_timeline() else { return };
        if self.selection.is_empty() {
            return;
        }
        let ids = self.selection.clone();
        let d = t.frame_duration() * frames;
        self.with_ids(|s, src| {
            s.attempt("Slide", None, |tl| {
                let mut seen: BTreeSet<Id> = BTreeSet::new();
                let clips: Vec<Clip> =
                    tl.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| ids.contains(&c.id)).cloned().collect();
                for c in clips {
                    if let Some(l) = c.link
                        && !seen.insert(l)
                    {
                        continue;
                    }
                    tl.magnetic_slide(c.id, d, src)?; // Fast Cut: a main clip's attached clips slide with it
                }
                Ok(())
            })
        });
    }

    /// Cmd+Down / Cmd+Up: the next (previous) clip on the track of the last (first) selected clip becomes the selection.
    /// False when nothing is selected or the track has no further clip.
    // Swift: EditorSession+TimelineOps.swift:450
    pub fn select_adjacent_clip(&mut self, forward: bool) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let picked = self.selected_clips();
        let from = if forward {
            picked.iter().reduce(|a, b| if a.timeline().end() < b.timeline().end() { b } else { a })
        } else {
            picked.iter().reduce(|a, b| if b.start < a.start { b } else { a })
        };
        let Some(next) = from.and_then(|f| t.neighbour_clip(f.id, forward)) else { return false };
        let sel = self.expanding_links(&BTreeSet::from([next]));
        self.select(sel, BTreeSet::new());
        true
    }

    /// Go to Selected Clip Start / End: moves the playhead to the edge of the selection. False without a selection.
    // Swift: EditorSession+TimelineOps.swift:461
    pub fn go_to_selected_clip_edge(&mut self, end: bool) -> bool {
        let Some(r) = self.active_timeline().and_then(|t| t.extent(&self.selection)) else { return false };
        self.seek_sequence(if end { r.end() } else { r.start });
        true
    }

    /// Opt+M: removes the marker on the playhead frame. False when there is none.
    // Swift: EditorSession+TimelineOps.swift:469
    pub fn clear_marker_at_playhead(&mut self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let at = self.playhead;
        if !t.markers.iter().any(|m| m.time == at.snapped(t.frame_duration()).max(Time::ZERO)) {
            return false;
        }
        self.attempt("Clear Marker", None, |t| {
            t.clear_marker(at);
            Ok(())
        })
    }

    /// Clears every sequence marker. Returns how many were removed.
    // Swift: EditorSession+TimelineOps.swift:477
    pub fn clear_all_markers(&mut self) -> usize {
        let n = self.active_timeline().map_or(0, |t| t.markers.len());
        if n == 0 {
            return 0;
        }
        self.attempt("Clear All Markers", None, |t| {
            t.clear_all_markers();
            Ok(())
        });
        n
    }
}

// MARK: Round 2 timeline verbs (EditorSession+TimelineEdit2.swift)

impl EditorSession {
    /// Q / W with Shift (rolling) or Option (plain trim, gap stays). `Ripple` is the ripple trim to playhead. Fast Cut:
    /// V1 never keeps a gap.
    // Swift: EditorSession+TimelineEdit2.swift:9
    pub fn trim_to_playhead(&mut self, edge: ClipEdge, mode: PlayheadTrimMode) {
        let at = self.edit_point();
        let side = if edge == ClipEdge::Head { "Previous" } else { "Next" };
        if mode == PlayheadTrimMode::Ripple {
            // Q / W: all unlocked tracks; Fast Cut: the main track, attached clips follow (` held: they stay). A trim
            // the core had to limit says so, and the playhead follows the closed span (`attempt_ripple_ids`).
            let name = format!("Ripple Trim {side} Edit");
            let keep = self.keep_attached_held;
            let mut clamp: Option<String> = None;
            let mut caption_limited = false;
            let ok = self.attempt_ripple_ids(&name, |t, ids| {
                let tracks = Self::playhead_trim_tracks(t);
                let (outcome, limited) = Self::run_noting_caption_limit(t, |tl| {
                    tl.magnetic_ripple_trim_to_playhead(edge, at, tracks.as_deref(), keep, ids).map(|(_, o)| o)
                })?;
                clamp = Self::clamp_text(t, outcome);
                caption_limited = limited;
                Ok(())
            });
            if let Some(c) = clamp {
                self.set_error(format!("Trim {c}"));
            } else if ok && caption_limited {
                self.set_error(Self::CAPTION_BLOCKED_MESSAGE.to_string());
            }
            return;
        }
        let name = match mode {
            PlayheadTrimMode::Roll => format!("Roll Trim {side} Edit"),
            _ => format!("Trim {side} Edit"),
        };
        let keep = self.keep_attached_held;
        self.with_ids(|s, src| {
            let mut attempt = |s: &mut EditorSession| {
                s.attempt(&name, None, |tl| {
                    let ids = Self::playhead_trim_tracks(tl);
                    if tl.is_fast_cut() {
                        tl.magnetic_trim_to_playhead(edge, at, mode, keep, src).map(|_| ())
                    } else {
                        tl.trim_to_playhead(edge, at, ids.as_deref(), mode).map(|_| ())
                    }
                })
            };
            attempt(s)
        });
    }

    /// Tracks Q / W (and their Shift / Option variants) act on: unlocked and enabled (a hidden video track or a muted
    /// audio track is skipped). `None` when that is every unlocked track (the core default), or when nothing is enabled.
    // Swift: EditorSession+TimelineEdit2.swift:26
    pub(crate) fn playhead_trim_tracks(t: &sq_core_model::Timeline) -> Option<Vec<Id>> {
        let unlocked: Vec<_> = t.tracks.iter().filter(|tr| !tr.is_locked).collect();
        let enabled: Vec<_> = unlocked
            .iter()
            .filter(|tr| if tr.kind == TrackKind::Video { tr.is_visible } else { !tr.is_muted })
            .collect();
        if enabled.is_empty() || enabled.len() == unlocked.len() {
            return None;
        }
        Some(enabled.iter().map(|tr| tr.id).collect())
    }

    /// Shift+Cmd+/: copies the selected clips right after the selection; the copies become the selection.
    // Swift: EditorSession+TimelineEdit2.swift:34
    pub fn duplicate_selection(&mut self) {
        if self.selection.is_empty() {
            return;
        }
        let ids = self.selection.clone();
        let mut made: Vec<Id> = Vec::new();
        let ok = self.with_ids(|s, src| {
            s.attempt("Duplicate", None, |t| {
                made = t.magnetic_duplicate(&ids, src)?;
                Ok(())
            })
        });
        if ok {
            self.select(made.into_iter().collect(), BTreeSet::new());
        }
    }

    /// Shift+Cmd+E: disables the selected clips (and their linked partners), or enables them when one is disabled.
    // Swift: EditorSession+TimelineEdit2.swift:42
    pub fn toggle_enabled_selection(&mut self) {
        let Some(t) = self.active_timeline() else { return };
        if self.selection.is_empty() {
            return;
        }
        let ids = self.selection.clone();
        // The name follows what the toggle really does to the linked group.
        let enabling = t.clone().toggle_enabled(&ids).unwrap_or(false);
        self.attempt(if enabling { "Enable Clip" } else { "Disable Clip" }, None, |t| {
            t.toggle_enabled(&ids).map(|_| ())
        });
    }

    /// Selected clips when they are all Adjustment Layers; empty for any other selection.
    // Swift: EditorSession+TimelineEdit2.swift:52
    pub fn selected_adjustment_layers(&self) -> Vec<Clip> {
        let clips = self.selected_clips();
        if !clips.is_empty() && clips.iter().all(Clip::is_adjustment) { clips } else { Vec::new() }
    }

    /// Check state of Clip > Extend to Sequence End: every selected layer carries the flag.
    // Swift: EditorSession+TimelineEdit2.swift:59
    pub fn selection_extends_to_sequence_end(&self) -> bool {
        let l = self.selected_adjustment_layers();
        !l.is_empty() && l.iter().all(Clip::extends_to_sequence_end)
    }

    /// Clip > Extend to Sequence End: switches the flag for the selected Adjustment Layers (off when all were on).
    // Swift: EditorSession+TimelineEdit2.swift:66
    pub fn toggle_extend_to_sequence_end_selection(&mut self) {
        let layers = self.selected_adjustment_layers();
        if layers.is_empty() {
            return;
        }
        let on = !self.selection_extends_to_sequence_end();
        let ids: Vec<Id> = layers.iter().map(|c| c.id).collect();
        let name = if on { "Extend to Sequence End" } else { "Stop Extending to Sequence End" };
        self.perform(name, None, |p| {
            for id in ids {
                p.set_extend_to_sequence_end(on, id, &mut |tl, id, by| {
                    let _ = tl.trim(id, ClipEdge::Tail, by);
                });
            }
        });
    }

    /// Opt+Up / Opt+Down: moves the selected clips one track. Returns false when the outermost lane blocks it.
    // Swift: EditorSession+TimelineEdit2.swift:79
    pub fn move_selection_lane(&mut self, up: bool) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        if self.selection.is_empty() {
            return false;
        }
        let ids = self.selection.clone();
        let name = if !t.is_fast_cut() {
            if up { "Move Clip Up" } else { "Move Clip Down" }
        } else if ids.iter().any(|id| t.is_on_main_track(*id)) {
            "Lift off Main Track"
        } else if up {
            "Move Clip Up"
        } else {
            "Move Clip Down"
        };
        let mut moved = false;
        self.with_ids(|s, src| {
            s.attempt(name, None, |tl| {
                moved = tl.magnetic_move_to_lane(&ids, up, src)?;
                Ok(())
            })
        });
        moved
    }

    /// Ruler drag of a marker flag (one step per drag).
    // Swift: EditorSession+TimelineEdit2.swift:92
    pub fn move_marker(&mut self, id: Id, time: Time) {
        self.attempt("Move Marker", None, |t| {
            t.move_marker(id, time);
            Ok(())
        });
    }

    /// Click on a track target button with Shift / Option.
    // Swift: EditorSession+TimelineEdit2.swift:97
    pub fn toggle_target(&mut self, id: Id, shift: bool, option: bool) {
        self.attempt(TrackToggleNames::TARGET_ALL, None, |t| {
            t.toggle_target(id, shift, option);
            Ok(())
        });
    }
}
