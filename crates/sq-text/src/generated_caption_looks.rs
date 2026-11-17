// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: GeneratedCaptionLooks.swift
//! Caption styles from the same generator as the text Looks (`TextLookGenerator`): every third or fourth palette of each
//! caption-sized family (TikTok, YouTube, Professional), as gallery looks (style + entrance animation + word highlight).
//! Their styles are merged into `CaptionPresetLibrary.builtIn`, so the refs resolve in the monitor and the burn-in.
//! Deterministic like the table it comes from.

use crate::caption_style_looks::{CaptionStyleLook, LookGroup};
use crate::text_look_generator::{ColorContrast, GeneratedTextLook, LookPalette, TextLookGenerator};
use crate::text_presets::TextPresetCategory;
use crate::text_style::{RGBAColor, TextStyle};
use sq_core_model::KaraokeStyle;
use std::collections::BTreeMap;
use std::sync::LazyLock;

/// Namespace of the generated caption looks.
pub enum GeneratedCaptionLooks {}

impl GeneratedCaptionLooks {
    /// Style ids of generated looks start with this.
    pub const STYLE_PREFIX: &'static str = "gen-";

    /// The caption selection of the generator: `paletteIndex % 4 == familyIndex % 4`, no title families.
    fn source() -> &'static [GeneratedTextLook] {
        static SOURCE: LazyLock<Vec<GeneratedTextLook>> = LazyLock::new(|| {
            let fams = TextLookGenerator::families();
            let palettes = TextLookGenerator::palettes();
            TextLookGenerator::all()
                .iter()
                .filter(|g| {
                    if g.look.category == TextPresetCategory::Titles {
                        return false;
                    }
                    let (Some(fi), Some(pi)) = (
                        fams.iter().position(|f| f.noun == g.family),
                        palettes.iter().position(|p| p.name == g.palette),
                    ) else {
                        return false;
                    };
                    pi % 4 == fi % 4
                })
                .cloned()
                .collect()
        });
        &SOURCE
    }

    /// Style by ref (`CaptionStyleLook.styleRef`).
    pub fn styles() -> BTreeMap<String, TextStyle> {
        Self::source().iter().map(|g| (g.id.clone(), g.look.style.clone())).collect()
    }

    /// The look's lit-word color: the first of accent, fill, paper that stands apart from the text color and still reads
    /// against what carries the text. Dark text (on a light box) gets none: a lit word would vanish into the box.
    pub fn highlight(g: &GeneratedTextLook, p: &LookPalette) -> Option<KaraokeStyle> {
        let s = &g.look.style;
        if ColorContrast::luminance(&s.color) <= 0.35 {
            return None;
        }
        let backing = s
            .background
            .map(|b| ColorContrast::composite(&b.color, 0.5))
            .or_else(|| s.stroke.map(|k| k.color))
            .or_else(|| s.shadow.map(|k| k.color))
            .unwrap_or(RGBAColor::BLACK);
        let apart = |c: &RGBAColor| {
            (c.red - s.color.red).abs() + (c.green - s.color.green).abs() + (c.blue - s.color.blue).abs() >= 0.3
        };
        let c =
            [p.accent, p.fill, p.paper].into_iter().find(|c| apart(c) && ColorContrast::ratio(c, &backing) >= 4.5)?;
        Some(KaraokeStyle {
            red: c.red,
            green: c.green,
            blue: c.blue,
            keep_spoken: g.look.category != TextPresetCategory::Tiktok,
        })
    }

    /// Every generated caption look.
    pub fn all() -> &'static [CaptionStyleLook] {
        static ALL: LazyLock<Vec<CaptionStyleLook>> = LazyLock::new(|| {
            let palettes = TextLookGenerator::palettes();
            GeneratedCaptionLooks::source()
                .iter()
                .enumerate()
                .filter_map(|(i, g)| {
                    let p = palettes.iter().find(|p| p.name == g.palette)?;
                    let anims = entrances(g.look.category);
                    let mut l = CaptionStyleLook::new(
                        &g.id,
                        &g.look.name,
                        LookGroup::Collection,
                        &g.id,
                        anims[i % anims.len()],
                        GeneratedCaptionLooks::highlight(g, p),
                    );
                    l.category = Some(g.look.category);
                    Some(l)
                })
                .collect()
        });
        &ALL
    }
}

fn entrances(category: TextPresetCategory) -> &'static [&'static str] {
    match category {
        TextPresetCategory::Tiktok => &["pop", "bounce-in"],
        TextPresetCategory::Youtube => &["rise", "slide-side"],
        TextPresetCategory::Professional => &["fade", "rise"],
        TextPresetCategory::Titles => &["fade"],
    }
}
