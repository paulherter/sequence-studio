//! Effect and transition presets, built-in stack presets, Convert to Keyframes.

use std::collections::BTreeSet;

use sq_core_effects::effect_preset::{Anchor, ApplyMode, EffectPreset, TimelineEffectPresetExt};
use sq_core_effects::effect_stack_preset::EffectStackPresets;
use sq_core_effects::keystone::Keystone;
use sq_core_effects::transition::TimelineTransitions;
use sq_core_effects::transition::TransitionPresetExt;
use sq_core_effects::user_preset_bake::{BakeError, BakeFailure, ClipBakeExt as _, TimelineBakeExt as _};
use sq_core_model::effect_defaults::TransitionPreset;
use sq_core_model::{Clip, EditError, Timeline, TrackKind};
use sq_core_time::keyframes_model::Vec2;
use sq_core_time::{Id, IdSource, Timestamp};
use sq_library::library_folder_store::SettingsStore;
use sq_library::preset_store::{PresetItem, PresetKind};

use super::transition_targets::TransitionTargets;
use crate::{EdgeSelection, EditorSession};

/// The settings key and access of the preset apply mode (Swift `PresetApplyModeSetting`).
pub enum PresetApplyModeSetting {}

impl PresetApplyModeSetting {
    // Swift: EditorSession+Presets.swift:101
    pub const KEY: &'static str = "sq.presets.applyMode";
    // Swift: EditorSession+Presets.swift:102
    pub fn load(settings: &dyn SettingsStore) -> ApplyMode {
        let raw = settings.data(Self::KEY).and_then(|b| String::from_utf8(b).ok());
        match raw.as_deref() {
            Some("relative") => ApplyMode::Relative,
            _ => ApplyMode::Absolute,
        }
    }
    // Swift: EditorSession+Presets.swift:105
    pub fn save(mode: ApplyMode, settings: &mut dyn SettingsStore) {
        let raw = if mode == ApplyMode::Relative { "relative" } else { "absolute" };
        settings.set_data(Self::KEY, raw.as_bytes().to_vec());
    }
}

impl EditorSession {
    // Swift: EditorSession+Presets.swift:9
    pub fn effect_preset_item(
        name: &str,
        preset: &EffectPreset,
        id: Id,
        created_at: Timestamp,
    ) -> Result<PresetItem, String> {
        let payload = preset.payload().map_err(|e| e.to_string())?;
        Ok(PresetItem::new(id, PresetKind::Effect, name, created_at, payload, EffectPreset::PAYLOAD_VERSION))
    }
    // Swift: EditorSession+Presets.swift:15
    pub fn preset_from_selected_clip(&self, anchor: Anchor) -> Option<EffectPreset> {
        let c = self.single_selected_clip().cloned().filter(|c| c.kind == TrackKind::Video)?;
        // The sequence frame travels with the preset, so applying it to another size scales Position and points.
        let size = self.active_timeline().map(|t| Vec2::new(t.format.display_width() as f64, t.format.height as f64));
        let p = EffectPreset::capture(&c, anchor, None, None, size);
        if p.is_empty() { None } else { Some(p) }
    }
    // Swift: EditorSession+Presets.swift:26
    pub fn apply_preset(&mut self, item: &PresetItem, ids: Option<&BTreeSet<Id>>, mode: ApplyMode) -> bool {
        if item.kind == PresetKind::Transition {
            return self.apply_transition_preset(item, None);
        }
        if item.kind == PresetKind::Keystone {
            return self.apply_motion_preset(item, ids);
        }
        if item.kind != PresetKind::Effect {
            self.set_error(format!("\u{201c}{}\u{201d} is not an effect preset.", item.name));
            return false;
        }
        let preset = match EffectPreset::from_payload(&item.payload, item.payload_version, self.ids.as_mut()) {
            Ok(p) => p,
            Err(_) => {
                self.set_error(format!(
                    "\u{201c}{}\u{201d} was made by a newer version of Sequence Studio or is damaged.",
                    item.name
                ));
                return false;
            }
        };
        // An audio-only preset (an imported voice chain) goes onto audio clips.
        let kind = preset.track_kind();
        let targets: BTreeSet<Id> = match ids {
            Some(ids) => ids.clone(),
            None => self.command_clips(Some(kind)).iter().map(|c| c.id).collect(),
        };
        if targets.is_empty() {
            let what = if kind == TrackKind::Audio { "an audio" } else { "a video" };
            self.set_error(format!("Select {what} clip to apply \u{201c}{}\u{201d}.", item.name));
            return false;
        }
        self.apply_effect_preset_to(&format!("Apply Preset \u{201c}{}\u{201d}", item.name), &preset, &targets, mode)
    }
    /// A motion preset (a keystone of the Library's Motion entry): lands on the whole selected video clip with the
    /// keystone's own placement, one undo step; a refusal sets the error line.
    fn apply_motion_preset(&mut self, item: &PresetItem, ids: Option<&BTreeSet<Id>>) -> bool {
        let Ok(keystone) = Keystone::from_payload(&item.payload, item.payload_version) else {
            self.set_error(format!(
                "\u{201c}{}\u{201d} was made by a newer version of Sequence Studio or is damaged.",
                item.name
            ));
            return false;
        };
        let targets: Vec<Id> = match ids {
            Some(ids) => ids.iter().copied().collect(),
            None => {
                self.single_selected_clip().filter(|c| c.kind == TrackKind::Video).map(|c| c.id).into_iter().collect()
            }
        };
        if targets.is_empty() {
            self.set_error(format!("Select a video clip to apply \u{201c}{}\u{201d}.", item.name));
            return false;
        }
        targets.into_iter().all(|clip| self.apply_keystone(&keystone, clip, None).is_some())
    }

    /// Row-id prefix of the built-in effect-stack presets.
    // Swift: EditorSession+Presets.swift:49
    pub const BUILT_IN_PRESET_PREFIX: &'static str = EffectStackPresets::ROW_PREFIX;

    /// Applies `preset` to `targets` in one undo step (Swift `performTimeline`: re-applying an identical preset is no
    /// failure); a refusal sets the error line.
    fn apply_effect_preset_to(
        &mut self,
        name: &str,
        preset: &EffectPreset,
        targets: &BTreeSet<Id>,
        mode: ApplyMode,
    ) -> bool {
        match self.perform_timeline_ids(name, None, |t, ids| t.apply_preset(preset, targets, mode, ids).map(|_| ())) {
            Ok(()) => true,
            Err(e) => {
                self.set_error(e.to_string());
                false
            }
        }
    }
    // Swift: EditorSession+Presets.swift:55
    pub fn apply_stack_preset(&mut self, id: &str, ids: Option<&BTreeSet<Id>>) -> bool {
        let Some(p) = EffectStackPresets::preset(id).or_else(|| EffectStackPresets::preset_by_row_id(id)) else {
            self.set_error("Unknown preset.");
            return false;
        };
        let audio = p.track_kind() == TrackKind::Audio;
        let picked: BTreeSet<Id> = match ids {
            Some(ids) => ids.clone(),
            None => {
                self.command_clips(if audio { None } else { Some(TrackKind::Video) }).iter().map(|c| c.id).collect()
            }
        };
        let targets = if audio { self.audio_effect_targets(&picked) } else { picked };
        if targets.is_empty() {
            let what = if audio { "an audio" } else { "a video" };
            self.set_error(format!("Select {what} clip to apply \u{201c}{}\u{201d}.", p.name));
            return false;
        }
        self.apply_effect_preset_to(
            &format!("Apply Preset \u{201c}{}\u{201d}", p.name),
            &p.preset(),
            &targets,
            ApplyMode::Absolute,
        )
    }
    /// The clip `id` in the active timeline.
    fn bake_clip(&self, id: Id) -> Option<&Clip> {
        self.active_timeline()?.tracks.iter().find_map(|t| t.clip(id))
    }
    /// Whether Convert to Keyframes is offered for `effect` of clip `clip` in the active timeline.
    // Swift: EditorSession+Presets.swift:73
    pub fn can_convert_to_keyframes(&self, effect: Id, clip: Id) -> bool {
        self.active_timeline().is_some_and(|t| t.can_convert_to_keyframes(effect, clip))
    }
    /// Whether the newest baked record of `clip` can be re-opened (false when the clip has none).
    // Swift: EditorSession+Presets.swift:78
    pub fn can_reopen_as_effect(&self, clip: Id) -> bool {
        let Some(c) = self.bake_clip(clip) else { return false };
        c.baked_effects().last().is_some_and(|last| c.can_reopen_as_effect(last.id))
    }
    /// Bakes `effect` into Motion keys: one undo step. False (with `last_error`) when refused.
    // Swift: EditorSession+Presets.swift:84
    pub fn convert_to_keyframes(&mut self, effect: Id, clip: Id) -> bool {
        self.attempt_bake("Convert to Keyframes", |t, ids| t.convert_to_keyframes(effect, clip, ids))
    }
    /// Puts the newest baked effect of `clip` back: one undo step. False (with `last_error`) when refused.
    // Swift: EditorSession+Presets.swift:90
    pub fn reopen_as_effect(&mut self, clip: Id) -> bool {
        let Some(record) = self.bake_clip(clip).and_then(|c| c.baked_effects().last().map(|b| b.id)) else {
            self.set_error(BakeError::RecordNotFound.message());
            return false;
        };
        self.attempt_bake("Re-open as Effect", |t, ids| t.reopen_as_effect(record, clip, ids))
    }
    /// `attempt_ids` for a bake edit; a refusal by the clip shows its own message.
    fn attempt_bake(
        &mut self,
        name: &str,
        body: impl FnOnce(&mut Timeline, &mut dyn IdSource) -> Result<(), BakeFailure>,
    ) -> bool {
        let mut refused = None;
        let ok = self.attempt_ids(name, |t, ids| match body(t, ids) {
            Ok(()) => Ok(()),
            Err(BakeFailure::Edit(e)) => Err(e),
            Err(BakeFailure::Bake(e)) => {
                refused = Some(e);
                Err(EditError::EmptyClip)
            }
        });
        if let Some(e) = refused {
            self.set_error(e.message());
        }
        ok
    }
    // Swift: EditorSession+TransitionPresets.swift:9
    pub fn transition_preset_item(
        name: &str,
        preset: &TransitionPreset,
        id: Id,
        created_at: Timestamp,
    ) -> Result<PresetItem, String> {
        let payload = preset.payload().map_err(|e| e.to_string())?;
        Ok(PresetItem::new(id, PresetKind::Transition, name, created_at, payload, TransitionPreset::PAYLOAD_VERSION))
    }
    // Swift: EditorSession+TransitionPresets.swift:14
    pub fn preset_from_selected_transition(&self) -> Option<TransitionPreset> {
        let info = self.transition_info(self.selected_transition?)?;
        Some(TransitionPreset::capture(&info.transition))
    }
    // Swift: EditorSession+TransitionPresets.swift:22
    pub fn apply_transition_preset(&mut self, item: &PresetItem, edges: Option<&EdgeSelection>) -> bool {
        if item.kind != PresetKind::Transition {
            self.set_error(format!("\u{201c}{}\u{201d} is not a transition preset.", item.name));
            return false;
        }
        let Ok(preset) = TransitionPreset::from_payload(&item.payload, item.payload_version) else {
            self.set_error(format!(
                "\u{201c}{}\u{201d} was made by a newer version of Sequence Studio or is damaged.",
                item.name
            ));
            return false;
        };
        let name = format!("Apply Transition Preset \u{201c}{}\u{201d}", item.name);
        if let Some(id) =
            self.selected_transition.filter(|id| self.active_timeline().and_then(|t| t.transition(*id)).is_some())
        {
            // Re-applying an identical preset changes nothing: not a failure, no message (as for effect presets).
            return match self.perform_timeline_ids(&name, None, |t, _| t.apply_transition_preset(&preset, id)) {
                Ok(()) => true,
                Err(e) => {
                    self.set_error(e.to_string());
                    false
                }
            };
        }
        let Some(t) = self.active_timeline() else { return false };
        let element = preset.kind.is_element();
        let targets =
            TransitionTargets::resolve(t, &[preset.track_kind()], edges, &self.selection, self.playhead, element);
        let both_ends = if element { Self::clips_with_both_ends(&targets) } else { BTreeSet::new() };
        if targets.is_empty() {
            let what = if preset.track_kind() == TrackKind::Audio { "an audio track" } else { "a track" };
            self.set_error(format!("Target {what}, or select an edit, to apply \u{201c}{}\u{201d}.", item.name));
            return false;
        }
        let mut made = None;
        let count = targets.len();
        let ok = self.attempt_keyed_ids(&name, None, |tl, ids| {
            let mut applied = 0;
            for target in &targets {
                let mut p = preset.clone();
                if let Some(c) = super::transitions::element_clip(target.point).filter(|c| both_ends.contains(c))
                    && let Some(clip) = tl.track(target.track).and_then(|tr| tr.clip(c))
                {
                    p.duration = <sq_core_model::Timeline as TimelineTransitions>::element_duration(
                        p.duration,
                        clip.duration(),
                        true,
                        tl.format.frame_duration,
                    );
                }
                if let Ok(id) = tl.add_transition_from_preset(&p, target.point, target.track, ids) {
                    made = Some(id);
                    applied += 1;
                }
            }
            if applied == 0 { Err(sq_core_model::EditError::InsufficientMedia) } else { Ok(()) }
        });
        if ok
            && count == 1
            && let Some(id) = made
        {
            self.select_transition(Some(id), false);
        }
        ok
    }
}
