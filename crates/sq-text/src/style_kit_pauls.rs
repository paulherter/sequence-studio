// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: StyleKit+Pauls.swift

use crate::style_kit_text::{BRAND_FONT_TOKEN, TEXT_COLOR_TOKEN};
use sq_core_model::{
    CaptionHorizontal, CaptionPosition, CaptionStyleSpec, CaptionVertical, EffectColor, StyleKit, StyleValue,
};
use std::collections::BTreeMap;

/// `static var pauls` of StyleKit+Pauls.swift.
pub trait StyleKitPaulsExt {
    /// "the maintainer's Kit" (W8.6): the caption look of his Premiere projects (docs/research/E2-paul-videos.md 2.4): Inter Bold, white,
    /// soft dark shadow (the "classic" base style), the caption pop, caption y 0.707 (C1-own-style). Only values the research documents are set; unknown ones
    /// stay `None` (caption size, emphasis pill color, motion defaults, "Folgen" overlay slot, audio chain, punch-in preset,
    /// see the roadmap "W8.6 SeedKit follow-ups").
    fn pauls() -> StyleKit;
}

impl StyleKitPaulsExt for StyleKit {
    fn pauls() -> StyleKit {
        StyleKit {
            fonts: BTreeMap::from([(BRAND_FONT_TOKEN.to_string(), "Inter-Bold".to_string())]),
            colors: BTreeMap::from([(TEXT_COLOR_TOKEN.to_string(), EffectColor::WHITE)]),
            caption: Some(CaptionStyleSpec {
                base_style: "classic".to_string(),
                animation: None,
                font: Some(StyleValue::Token(BRAND_FONT_TOKEN.to_string())),
                size: None,
                text_color: Some(StyleValue::Token(TEXT_COLOR_TOKEN.to_string())),
                stroke_color: None,
                uses_pill: false,
                all_caps: None,
                hides_background: None,
                tweaks: None,
            }),
            caption_position: Some(CaptionPosition {
                vertical: CaptionVertical::Middle,
                horizontal: CaptionHorizontal::Center,
                offset_x: 0.0,
                offset_y: 0.707 - 0.5,
            }),
            ..StyleKit::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::caption_presets::{CaptionPresetLibrary, KeyframeTemplateCaptionExt};
    use crate::text_style::RGBAColor;
    use sq_core_effects::style_kit::{CAPTION_ANIMATION_REF, CAPTION_STYLE_REF, StyleKitExt};
    use sq_core_model::anchored_animation::KeyframeTemplate;

    #[test]
    fn carries_only_researched_values() {
        let kit = StyleKit::pauls();
        assert_eq!(kit.fonts.get(BRAND_FONT_TOKEN).map(String::as_str), Some("Inter-Bold")); // E2 2.4: Inter Bold
        assert_eq!(kit.colors.get(TEXT_COLOR_TOKEN), Some(&EffectColor::WHITE)); // white captions
        assert_eq!(
            kit.caption.as_ref().and_then(|c| c.font.clone()),
            Some(StyleValue::Token(BRAND_FONT_TOKEN.to_string()))
        );
        assert_eq!(kit.caption.as_ref().map(|c| c.uses_pill), Some(false)); // soft shadow, no pill
        assert_eq!(kit.caption.as_ref().and_then(|c| c.size), None); // unknown: left unset
        assert!(kit.motion.is_none()); // unknown: left unset
        assert!(kit.pill.is_none());
        // Caption y 0.707 of the canvas height (C1 brand kit): middle plus 0.207 down.
        assert_eq!(
            kit.caption_position,
            Some(CaptionPosition {
                vertical: CaptionVertical::Middle,
                horizontal: CaptionHorizontal::Center,
                offset_x: 0.0,
                offset_y: 0.707 - 0.5
            })
        );
    }

    #[test]
    fn caption_style_resolves_to_inter_bold_with_shadow() {
        let lib = CaptionPresetLibrary::base().applying(Some(&StyleKit::pauls()));
        let s = lib.style(Some(CAPTION_STYLE_REF));
        assert_eq!(s.font_name, "Inter-Bold");
        assert_eq!(s.color, RGBAColor::WHITE);
        assert!(s.shadow.is_some());
        assert!(s.background.is_none());
        assert_eq!(
            lib.animation(Some(CAPTION_ANIMATION_REF)),
            <KeyframeTemplate as KeyframeTemplateCaptionExt>::caption_pop()
        );
    }

    #[test]
    fn import_keeps_the_importers_brand() {
        let mut mine = StyleKit::default();
        mine.fonts.insert(BRAND_FONT_TOKEN.to_string(), "Avenir-Black".to_string());
        let (mine, _) = mine.merging(&StyleKit::pauls());
        assert_eq!(mine.fonts.get(BRAND_FONT_TOKEN).map(String::as_str), Some("Avenir-Black"));
        assert!(mine.caption.is_some());
        assert_eq!(mine.font(BRAND_FONT_TOKEN), Some("Avenir-Black"));
    }
}
