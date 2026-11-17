// Swift: GeneratedCaptionPresets.swift
//! Caption presets from the look generator: the segmentation that suits the look's family plus its style and entrance
//! animation refs. TikTok families cut one short word at a time, YouTube families two lines of about 32 characters,
//! Professional ones the standard cut.

use std::collections::BTreeSet;

use sq_text::caption_style_looks::CaptionStyleLook;
use sq_text::generated_caption_looks::GeneratedCaptionLooks;
use sq_text::text_presets::{BuiltInTextLooks, TextPresetCategory};
use sq_transcribe::caption_preset::{CaptionEmphasis, CaptionPreset};

use crate::captions::panel_model::{CaptionsPanelModel, NamedPreset};

/// `CaptionPreset.generated(for:)`.
pub fn generated(look: &CaptionStyleLook) -> CaptionPreset {
    let mut p;
    match look.category {
        Some(TextPresetCategory::Tiktok) => {
            p = CaptionPreset::short_video();
            // The look carries its own box or outline.
            p.emphasis = CaptionEmphasis::None;
        }
        Some(TextPresetCategory::Youtube) => {
            p = CaptionPreset::standard();
            p.max_chars_per_line = 32;
        }
        _ => p = CaptionPreset::standard(),
    }
    p.style_ref = look.style_ref.clone();
    p.animation_ref = look.animation_ref.clone();
    p
}

pub(crate) const NAME_PREFIX: &str = "Look - ";

/// One named preset per generated caption look, in gallery order.
pub(crate) fn named() -> Vec<NamedPreset> {
    if !BuiltInTextLooks::IS_ENABLED {
        return Vec::new();
    }
    GeneratedCaptionLooks::all()
        .iter()
        .map(|l| NamedPreset::new(&format!("{NAME_PREFIX}{}", l.title), generated(l)))
        .collect()
}

/// Adds the presets the model does not list yet; the selection and the other presets stay.
pub(crate) fn add(m: &mut CaptionsPanelModel) {
    let have: BTreeSet<String> = m.presets.iter().map(|p| p.name.clone()).collect();
    m.presets.extend(named().into_iter().filter(|p| !have.contains(&p.name)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_text::caption_presets::CaptionPresetLibrary;

    #[test]
    fn presets_follow_the_family() {
        let lib = CaptionPresetLibrary::built_in();
        let mut seen = BTreeSet::new();
        for l in GeneratedCaptionLooks::all() {
            let p = generated(l);
            assert!(p.style_ref == l.style_ref && p.animation_ref == l.animation_ref);
            assert!(lib.has_style(&p.style_ref) && lib.has_animation(&p.animation_ref));
            let Some(c) = l.category else { panic!("generated look without a family") };
            seen.insert(format!("{c:?}"));
            match c {
                TextPresetCategory::Tiktok => {
                    assert!(p.max_words_per_caption == Some(1) && p.emphasis == CaptionEmphasis::None)
                }
                TextPresetCategory::Youtube => assert!(p.max_chars_per_line == 32 && p.max_lines == 2),
                _ => assert_eq!(p.max_chars_per_line, CaptionPreset::standard().max_chars_per_line),
            }
        }
        let want: BTreeSet<String> = ["Tiktok", "Youtube", "Professional"].iter().map(|s| s.to_string()).collect();
        assert_eq!(seen, want);
    }

    #[test]
    fn adding_keeps_the_selection_and_is_idempotent() {
        let mut m = CaptionsPanelModel::new();
        let before = m.presets.len();
        m.selected_preset_index = 1;
        add(&mut m);
        add(&mut m);
        assert_eq!(m.presets.len(), before + named().len());
        assert!(m.selected_preset_index == 1 && m.presets[1].name == "Short Video");
        let names: BTreeSet<&String> = m.presets.iter().map(|p| &p.name).collect();
        assert_eq!(names.len(), m.presets.len());
    }
}
