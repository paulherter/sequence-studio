// Swift: NamedLookPreset.swift
//! Puts the default Caption Look into the Create Captions dialog's preset list (first entry) and adds a "No Animation"
//! preset; the user's own pick stays selected.

use sq_core_effects::style_kit::{CAPTION_ANIMATION_REF, CAPTION_STYLE_REF};
use sq_core_model::StyleKit;
use sq_editor_session::CaptionLookLibrary;
use sq_library::library_folder_store::SettingsStore;
use sq_transcribe::caption_preset::CaptionPreset;

use crate::captions::generated_caption_presets;
use crate::captions::panel_model::{CaptionsPanelModel, NamedPreset};

pub const KIT_PRESET_NAME: &str = "Project Kit";

/// W8.3: a project whose kit has a caption style creates captions in that style by default (it wins over the global
/// default look: the kit belongs to this project). Returns whether a default (kit or look) was installed.
pub fn install(
    m: &mut CaptionsPanelModel,
    library: &CaptionLookLibrary,
    settings: &dyn SettingsStore,
    kit: Option<&StyleKit>,
) -> bool {
    let no_anim = "Standard, No Animation";
    let picked = m.presets.get(m.selected_preset_index).map(|p| p.name.clone());
    if !m.presets.iter().any(|p| p.name == no_anim) {
        let mut p = CaptionPreset::standard();
        p.animation_ref = "none".to_string();
        m.presets.push(NamedPreset::new(no_anim, p));
    }
    generated_caption_presets::add(m);
    m.presets.retain(|p| p.name != KIT_PRESET_NAME);
    let keeps = |picked: &Option<String>, own: &str| match picked {
        None => own.to_string(),
        Some(p) if p == "Standard" || p == own => own.to_string(),
        Some(p) => p.clone(),
    };
    if kit.is_some_and(|k| k.caption.is_some()) {
        let mut p = CaptionPreset::standard();
        p.style_ref = CAPTION_STYLE_REF.to_string();
        p.animation_ref = CAPTION_ANIMATION_REF.to_string();
        m.presets.insert(0, NamedPreset::new(KIT_PRESET_NAME, p));
        let keep = keeps(&picked, KIT_PRESET_NAME);
        m.selected_preset_index = m.presets.iter().position(|p| p.name == keep).unwrap_or(0);
        return true;
    }
    let Some(l) = library.default_look(settings) else { return false };
    m.presets.retain(|p| p.name != l.name);
    m.presets.insert(0, NamedPreset::new(&l.name, library.apply_default(settings, &l.segmentation)));
    // The user's pick stays; an untouched "Standard" (or the look itself) moves to the default look.
    let keep = keeps(&picked, &l.name);
    m.selected_preset_index = m.presets.iter().position(|p| p.name == keep).unwrap_or(0);
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_editor_session::{CaptionLookStore, StoredCaptionLook};
    use sq_library::library_folder_store::MemorySettings;
    use sq_text::style_kit_text::StyleKitTextExt;

    struct NoStore;
    impl CaptionLookStore for NoStore {
        fn user_looks(&self) -> Vec<StoredCaptionLook> {
            Vec::new()
        }
        fn add(
            &mut self,
            _: sq_core_time::Id,
            _: &str,
            _: &sq_text::caption_presets::CaptionLook,
            _: &CaptionPreset,
        ) -> bool {
            false
        }
        fn update(
            &mut self,
            _: sq_core_time::Id,
            _: &sq_text::caption_presets::CaptionLook,
            _: Option<&CaptionPreset>,
        ) -> bool {
            false
        }
        fn delete(&mut self, _: sq_core_time::Id) {}
    }

    #[test]
    fn kit_caption_style_becomes_the_default_preset() {
        let mut m = CaptionsPanelModel::new();
        let kit = StyleKit::starter();
        assert!(kit.caption.is_some());
        let lib = CaptionLookLibrary::new(&NoStore);
        assert!(install(&mut m, &lib, &MemorySettings::default(), Some(&kit)));
        assert_eq!(m.presets[m.selected_preset_index].name, KIT_PRESET_NAME);
        let p = &m.presets[m.selected_preset_index].preset;
        assert!(p.style_ref == CAPTION_STYLE_REF && p.animation_ref == CAPTION_ANIMATION_REF);
    }

    #[test]
    fn no_kit_caption_style_leaves_the_presets_alone() {
        let mut m = CaptionsPanelModel::new();
        let lib = CaptionLookLibrary::new(&NoStore);
        let s = MemorySettings::default();
        assert!(!install(&mut m, &lib, &s, Some(&StyleKit::default())));
        assert!(!install(&mut m, &lib, &s, None));
        assert!(!m.presets.iter().any(|p| p.name == KIT_PRESET_NAME));
        assert_eq!(m.presets[m.selected_preset_index].name, "Standard");
    }

    #[test]
    fn a_user_pick_stays_selected() {
        let mut m = CaptionsPanelModel::new();
        m.selected_preset_index = 1;
        let lib = CaptionLookLibrary::new(&NoStore);
        install(&mut m, &lib, &MemorySettings::default(), Some(&StyleKit::starter()));
        assert_eq!(m.presets[m.selected_preset_index].name, "Short Video");
    }
}
