// Swift: EffectControlsModel+MaskPathKeys.swift, EffectControlsModel+Masks.swift (path keys, removal), +MaskTool.swift (cache keys)
//! Mask keys in the keyframe lanes: a path mask's Path keys (`EffectProperty::MaskPath`, drawn on its controls row) and
//! a Magic mask's tracked frames (read from the matte store, on the same row). Path keys move, ease, copy and delete like
//! any key; tracked frames are only selectable and deletable.

use std::collections::{BTreeMap, BTreeSet};

use sq_core_masks::magic_mask::MagicSelectionExt;
use sq_core_masks::mask_inputs::MaskInputsExt;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_model::keyframes_editing::{PropertyID, SummaryKey, SummaryMember};
use sq_core_model::{Clip, ClipMask, MaskSource};
use sq_core_time::{Id, Time};
use sq_editor_session::EffectSection;
use sq_uikit::keyframe_control_state::KeyframeControlState;

use super::core::{EffectControlsModel, MagicFrameStep};
use super::property::{EffectProperty, StopwatchOutcome};
use crate::ec::magic_tracked_frames::MagicFrameKey;
use crate::ec::prelude::*;

impl EffectProperty {
    /// The mask of a `MaskPath` property.
    pub fn mask_path_id(&self) -> Option<Id> {
        if let EffectProperty::MaskPath(id) = self { Some(*id) } else { None }
    }
}

impl EffectControlsModel {
    // MARK: Path stopwatch and key button

    /// The Path stopwatch: on keys the path at the playhead; off removes every Path key, so it asks first
    /// (`NeedsConfirmation`, then again with `confirm_removal`), like any other property.
    pub(crate) fn toggle_mask_path_stopwatch(&mut self, id: Id, confirm_removal: bool) -> StopwatchOutcome {
        let Some(m) = self.clip.as_ref().and_then(|c| c.mask(id)) else { return StopwatchOutcome::Unavailable };
        if m.source() != MaskSource::Path {
            return StopwatchOutcome::Unavailable;
        }
        if m.path.is_animated() {
            if !confirm_removal {
                return StopwatchOutcome::NeedsConfirmation;
            }
            let pid = EffectProperty::MaskPath(id).id();
            let kept: BTreeSet<SummaryMember> = self.selection.iter().filter(|s| s.property != pid).cloned().collect();
            self.set_selection(kept);
            self.set_mask_path_animated(id, false);
            return StopwatchOutcome::Removed;
        }
        if !self.playhead_in_clip() {
            return StopwatchOutcome::Unavailable;
        }
        self.set_mask_path_animated(id, true);
        StopwatchOutcome::Added
    }

    /// The Path's key button: adds or removes the key at the playhead; on a still path it is the stopwatch.
    pub(crate) fn toggle_mask_path_key(&mut self, id: Id) -> StopwatchOutcome {
        let Some(m) = self.clip.as_ref().and_then(|c| c.mask(id)) else { return StopwatchOutcome::Unavailable };
        if m.source() != MaskSource::Path {
            return StopwatchOutcome::Unavailable;
        }
        if !m.path.is_animated() {
            return self.toggle_mask_path_stopwatch(id, false);
        }
        if !self.playhead_in_clip() {
            return StopwatchOutcome::Unavailable;
        }
        let on = self.mask_path_key_times(id).contains(&self.local_playhead());
        self.toggle_mask_path_key_at_playhead(id);
        if on { StopwatchOutcome::Removed } else { StopwatchOutcome::Added }
    }

    /// Stopwatch of a mask's path at the playhead.
    pub fn set_mask_path_animated(&mut self, id: Id, on: bool) {
        let Some(mut c) = self.working_clip() else { return };
        let local = self.local_playhead();
        c.set_mask_path_animated(id, on, local, &mut *self.ids);
        self.commit(c, if on { "Animate Mask Path" } else { "Stop Animating Mask Path" }, None);
    }

    /// Clip-local key times of a mask's path, sorted.
    pub(crate) fn mask_path_key_times(&self, id: Id) -> Vec<Time> {
        let mut t: Vec<Time> = self
            .clip
            .as_ref()
            .and_then(|c| c.mask(id))
            .map(|m| m.path.track.keys.iter().map(|k| k.time).collect())
            .unwrap_or_default();
        t.sort();
        t
    }

    /// The Path row's `KeyframeControls` (ring on a key, prev / diamond / next).
    pub fn mask_path_keyframe_state(&self, id: Id) -> KeyframeControlState {
        let times = self.mask_path_key_times(id);
        let l = self.local_playhead();
        KeyframeControlState::resolve(
            !times.is_empty(),
            times.contains(&l),
            times.iter().any(|t| *t < l),
            times.iter().any(|t| *t > l),
            self.playhead_in_clip(),
        )
    }

    pub fn go_to_previous_mask_path_key(&mut self, id: Id) {
        let l = self.local_playhead();
        let Some(t) = self.mask_path_key_times(id).into_iter().rfind(|t| *t < l) else { return };
        let g = t + self.clip.as_ref().map_or(Time::ZERO, |c| c.start);
        self.reveal_playhead(g);
        self.seek(g);
    }

    pub fn go_to_next_mask_path_key(&mut self, id: Id) {
        let l = self.local_playhead();
        let Some(t) = self.mask_path_key_times(id).into_iter().find(|t| *t > l) else { return };
        let g = t + self.clip.as_ref().map_or(Time::ZERO, |c| c.start);
        self.reveal_playhead(g);
        self.seek(g);
    }

    /// Adds or removes the mask path key at the playhead.
    pub fn toggle_mask_path_key_at_playhead(&mut self, id: Id) {
        let Some(mut c) = self.working_clip() else { return };
        if !self.playhead_in_clip() || !c.mask(id).is_some_and(|m| m.path.is_animated()) {
            return;
        }
        let local = self.local_playhead();
        let on = self.mask_path_key_times(id).contains(&local);
        c.toggle_mask_path_key(id, local, &mut *self.ids);
        self.commit(c, if on { "Remove Mask Path Keyframe" } else { "Add Mask Path Keyframe" }, None);
    }

    pub fn remove_mask(&mut self, id: Id) {
        let Some(mut c) = self.working_clip() else { return };
        if c.mask(id).is_none() {
            return;
        }
        c.remove_mask(id); // also drops it from every effect's input
        self.forget_removed_masks(&[id]);
        self.commit(c, "Delete Mask", None);
    }

    // MARK: Magic mask tracked frames

    /// The tracked frames of a Magic mask inside the clip, as lane keys (clip-local, sorted). Empty for any other mask.
    pub fn magic_keys(&self, id: Id) -> Vec<MagicFrameKey> {
        let Some(c) = &self.clip else { return Vec::new() };
        let Some(m) = c.mask(id) else { return Vec::new() };
        let Some(key) = Self::magic_cache_key(m, c) else { return Vec::new() };
        self.magic_frames.keys(c, m, &key, self.frame_duration)
    }

    /// The first Magic mask with a tracked pick: its id and matte cache key (the steps' strip reads that one).
    pub fn first_magic_check_key(&self) -> Option<(Id, String)> {
        let c = self.clip.as_ref()?;
        c.masks().iter().find_map(|m| Self::magic_cache_key(m, c).map(|k| (m.id, k)))
    }

    /// The matte cache key of a picked Magic mask of `c`, nil otherwise.
    pub(crate) fn magic_cache_key(m: &ClipMask, c: &Clip) -> Option<String> {
        if m.source() != MaskSource::Magic || c.sequence.is_some() {
            return None;
        }
        let sel = m.magic.as_ref()?;
        if sel.points.is_empty() {
            return None;
        }
        Some(sel.cache_key(c.media))
    }

    /// Every key a lane row of `p` shows: the track's keys, and for a Magic mask's Path row its tracked frames.
    pub(crate) fn lane_keys(&self, p: &EffectProperty) -> Vec<(Id, Time)> {
        let own = self.track_of(p).map(|t| t.times()).unwrap_or_default();
        let Some(id) = p.mask_path_id() else { return own };
        if self.clip.as_ref().and_then(|c| c.mask(id)).map(|m| m.source()) != Some(MaskSource::Magic) {
            return own;
        }
        let mut out = own;
        out.extend(self.magic_keys(id).into_iter().map(|k| (k.id, k.time)));
        out
    }

    /// The members of `sel` that are tracked frames still shown (the selection keeps them across edits).
    pub(crate) fn live_magic_members(&self, sel: &BTreeSet<SummaryMember>) -> BTreeSet<SummaryMember> {
        let Some(c) = &self.clip else { return BTreeSet::new() };
        let mut out = BTreeSet::new();
        for m in c.masks().iter().filter(|m| m.source() == MaskSource::Magic) {
            let pid = EffectProperty::MaskPath(m.id).id();
            let wanted: Vec<&SummaryMember> = sel.iter().filter(|s| s.property == pid).collect();
            if wanted.is_empty() {
                continue;
            }
            let ids: BTreeSet<Id> = self.magic_keys(m.id).into_iter().map(|k| k.id).collect();
            out.extend(wanted.into_iter().filter(|s| ids.contains(&s.key_id)).cloned());
        }
        out
    }

    /// Collapsed Magic mask section: its tracked frames as summary keys.
    pub(crate) fn magic_summary_keys(&self, section: &EffectSection) -> Vec<SummaryKey> {
        let EffectSection::Mask(id) = section else { return Vec::new() };
        let pid: PropertyID = EffectProperty::MaskPath(*id).id();
        self.magic_keys(*id)
            .into_iter()
            .map(|k| SummaryKey { time: k.time, members: BTreeSet::from([SummaryMember::new(pid.clone(), k.id)]) })
            .collect()
    }

    /// Summary keys of the tracks merged with `extra` (same time = one key).
    pub(crate) fn merging_magic(groups: Vec<SummaryKey>, extra: Vec<SummaryKey>) -> Vec<SummaryKey> {
        if extra.is_empty() {
            return groups;
        }
        let mut by_time: BTreeMap<Time, BTreeSet<SummaryMember>> = BTreeMap::new();
        for g in groups.into_iter().chain(extra) {
            by_time.entry(g.time).or_default().extend(g.members);
        }
        by_time.into_iter().map(|(time, members)| SummaryKey { time, members }).collect()
    }

    /// Deleting selected tracked frames (part of `delete_selection`): their mattes leave the store; a frame that carries a
    /// correction point also loses that point (`c`, the same undo step as the rest of the delete). The pick's own points
    /// always stay, whichever frames go: without them the mask has nothing to track from.
    pub(crate) fn remove_selected_magic_frames(&mut self, c: &mut Clip) -> Vec<MagicFrameStep> {
        let mut gone: Vec<MagicFrameStep> = Vec::new();
        let masks: Vec<ClipMask> = c.masks().iter().filter(|m| m.source() == MaskSource::Magic).cloned().collect();
        for m in masks {
            let ids = self.selected_key_ids(&EffectProperty::MaskPath(m.id));
            let Some(key) = Self::magic_cache_key(&m, c) else { continue };
            if ids.is_empty() {
                continue;
            }
            let keys: Vec<MagicFrameKey> = self.magic_keys(m.id).into_iter().filter(|k| ids.contains(&k.id)).collect();
            if keys.is_empty() {
                continue;
            }
            let corrections: Vec<MagicFrameKey> = keys.iter().filter(|k| k.is_correction).copied().collect();
            let plain: Vec<f64> = keys.iter().filter(|k| !k.is_correction).map(|k| k.pts).collect();
            let snap = self.magic_frames.remove(&key, &plain);
            if !snap.is_empty() {
                gone.push(MagicFrameStep { snapshot: snap });
            }
            // A Face / Skin mask: the narrowed mattes of those frames go too (the mask then covers them by estimate).
            if let Some(part) = m.magic.as_ref().and_then(|s| s.part_key(c.media)) {
                let snap = self.magic_frames.remove(&part, &plain);
                if !snap.is_empty() {
                    gone.push(MagicFrameStep { snapshot: snap });
                }
            }
            if !corrections.is_empty() {
                let anchor = m.magic.as_ref().and_then(|s| s.anchor_time());
                c.update_mask(m.id, |mask| {
                    if let Some(sel) = mask.magic.as_mut() {
                        sel.points.retain(|p| !corrections.iter().any(|k| k.holds_correction(p, anchor)));
                    }
                });
            }
        }
        gone
    }

    // MARK: Previous / next key of a mask row

    /// Clip-local key times of a mask's row: its Path keys, or a Magic mask's tracked frames.
    pub(crate) fn mask_row_key_times(&self, id: Id) -> Vec<Time> {
        if self.clip.as_ref().and_then(|c| c.mask(id)).map(|m| m.source()) != Some(MaskSource::Magic) {
            return self.mask_path_key_times(id);
        }
        self.magic_keys(id).into_iter().map(|k| k.time).collect()
    }

    /// The mask row's `KeyframeControls`: the Path's, or for a Magic mask previous / next tracked frame.
    pub fn mask_row_keyframe_state(&self, id: Id) -> KeyframeControlState {
        if self.clip.as_ref().and_then(|c| c.mask(id)).map(|m| m.source()) != Some(MaskSource::Magic) {
            return self.mask_path_keyframe_state(id);
        }
        let times = self.mask_row_key_times(id);
        let l = self.local_playhead();
        KeyframeControlState::resolve(
            !times.is_empty(),
            times.contains(&l),
            times.iter().any(|t| *t < l),
            times.iter().any(|t| *t > l),
            self.playhead_in_clip(),
        )
    }

    pub fn go_to_previous_mask_row_key(&mut self, id: Id) {
        let l = self.local_playhead();
        let Some(t) = self.mask_row_key_times(id).into_iter().rfind(|t| *t < l) else { return };
        let g = t + self.clip.as_ref().map_or(Time::ZERO, |c| c.start);
        self.reveal_playhead(g);
        self.seek(g);
    }

    pub fn go_to_next_mask_row_key(&mut self, id: Id) {
        let l = self.local_playhead();
        let Some(t) = self.mask_row_key_times(id).into_iter().find(|t| *t > l) else { return };
        let g = t + self.clip.as_ref().map_or(Time::ZERO, |c| c.start);
        self.reveal_playhead(g);
        self.seek(g);
    }
}
