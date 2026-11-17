// Swift: EffectDropRules.swift
//! Whether a clip lights up for an effect drag: the drop must be one `addEffect` can carry out, so the ghost never
//! promises something the drop then refuses (locked track, a picture effect over an audio clip).

use crate::preset_drop::PresetDrop;
use sq_core_effects::effect_stack_preset::EffectStackPresets;
use sq_core_model::{Clip, ClipEffect, TrackKind};
use sq_text::text_presets::TextPresetCatalog;

/// The effect drop rules.
pub struct EffectDropRules;

impl EffectDropRules {
    /// `effect_ids`: the dragged ids (a dragged folder carries several). Accepts when at least one of them can land.
    pub fn accepts(effect_ids: &[String], clip: &Clip, track_locked: bool) -> bool {
        if track_locked {
            return false;
        }
        effect_ids.iter().any(|id| Self::accepts_one(id, clip))
    }

    pub(crate) fn accepts_one(id: &str, clip: &Clip) -> bool {
        if PresetDrop::preset_id_from_effect_id(id).is_some() {
            return true; // Library presets decide on apply
        }
        if TextPresetCatalog::is_text_preset_id(id) || EffectStackPresets::preset_by_row_id(id).is_some() {
            return true;
        }
        if ClipEffect::is_audio_kind(id) {
            return clip.kind == TrackKind::Audio || clip.link.is_some(); // a video clip's linked sound
        }
        clip.kind == TrackKind::Video || clip.link.is_some() // or a selection that holds its picture
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;

    fn clip(kind: TrackKind, linked: bool) -> Clip {
        mk(0, 24, kind, linked.then(uid))
    }

    fn blur() -> Vec<String> {
        vec![ClipEffect::GAUSSIAN_BLUR_KIND.to_string()]
    }

    fn audio_fx() -> String {
        format!("{}gain", ClipEffect::AUDIO_KIND_PREFIX)
    }

    #[test]
    fn locked_track_never_lights_up() {
        assert!(!EffectDropRules::accepts(&blur(), &clip(TrackKind::Video, false), true));
        assert!(EffectDropRules::accepts(&blur(), &clip(TrackKind::Video, false), false));
    }

    #[test]
    fn picture_effect_needs_picture_and_sound_effect_needs_sound() {
        let fx = [audio_fx()];
        assert!(!EffectDropRules::accepts(&blur(), &clip(TrackKind::Audio, false), false));
        assert!(!EffectDropRules::accepts(&fx, &clip(TrackKind::Video, false), false));
        assert!(EffectDropRules::accepts(&fx, &clip(TrackKind::Audio, false), false));
        assert!(EffectDropRules::accepts(&fx, &clip(TrackKind::Video, true), false)); // its linked sound
        assert!(EffectDropRules::accepts(&blur(), &clip(TrackKind::Audio, true), false));
    }

    #[test]
    fn a_folder_lights_up_when_any_of_its_effects_fits() {
        let both = [ClipEffect::GAUSSIAN_BLUR_KIND.to_string(), audio_fx()];
        assert!(EffectDropRules::accepts(&both, &clip(TrackKind::Audio, false), false));
    }

    #[test]
    fn library_presets_are_left_to_the_apply_path() {
        let id = [PresetDrop::effect_id(uid())];
        assert!(EffectDropRules::accepts(&id, &clip(TrackKind::Audio, false), false));
        assert!(PresetDrop::preset_id_from_effect_id(&id[0]).is_some());
        assert!(PresetDrop::preset_id_from_effect_id("gaussianBlur").is_none());
    }
}
