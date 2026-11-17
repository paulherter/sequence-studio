// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextLookGenerator.swift

use crate::text_presets::{TextLook, TextPresetCatalog, TextPresetCategory};
use crate::text_style::{
    BoxPadding, FontWeight, RGBAColor, StrokePosition, TextAlignment, TextBackground, TextShadow, TextStroke, TextStyle,
};
use std::collections::{BTreeMap, HashMap};
use std::sync::OnceLock;

/// WCAG relative luminance and contrast ratio (sRGB). Used by the look generator and its tests.
pub enum ColorContrast {}

impl ColorContrast {
    /// Relative luminance.
    pub fn luminance(c: &RGBAColor) -> f64 {
        fn lin(v: f64) -> f64 {
            if v <= 0.03928 { v / 12.92 } else { ((v + 0.055) / 1.055).powf(2.4) }
        }
        0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }

    /// 1...21; opaque colors.
    pub fn ratio(a: &RGBAColor, b: &RGBAColor) -> f64 {
        let (x, y) = (Self::luminance(a), Self::luminance(b));
        (x.max(y) + 0.05) / (x.min(y) + 0.05)
    }

    /// `c` laid over an opaque gray `level` (0 black ... 1 white).
    pub fn composite(c: &RGBAColor, over_grey: f64) -> RGBAColor {
        let level = over_grey;
        RGBAColor::rgb(
            c.red * c.alpha + level * (1.0 - c.alpha),
            c.green * c.alpha + level * (1.0 - c.alpha),
            c.blue * c.alpha + level * (1.0 - c.alpha),
        )
    }
}

/// Four related colors: a bright main color, a second bright accent, a very dark tinted ink and a tinted off-white.
/// Every look is built from one palette, so the dark ink against any of the three light colors always reads.
#[derive(Clone, Debug, PartialEq)]
pub struct LookPalette {
    /// Stable id.
    pub id: String,
    /// Shown name.
    pub name: String,
    /// Main bright color.
    pub fill: RGBAColor,
    /// Second bright color.
    pub accent: RGBAColor,
    /// Very dark tinted color.
    pub ink: RGBAColor,
    /// Tinted off-white.
    pub paper: RGBAColor,
}

type Rgb = (f64, f64, f64);

impl LookPalette {
    fn new(id: &str, name: &str, fill: Rgb, accent: Rgb, ink: Rgb, paper: Rgb) -> Self {
        let c = |t: Rgb| RGBAColor::rgb(t.0, t.1, t.2);
        LookPalette {
            id: id.to_string(),
            name: name.to_string(),
            fill: c(fill),
            accent: c(accent),
            ink: c(ink),
            paper: c(paper),
        }
    }
}

/// A generated look with its origin.
#[derive(Clone, Debug, PartialEq)]
pub struct GeneratedTextLook {
    /// The look's id (Swift computes it from `look`).
    pub id: String,
    /// The look.
    pub look: TextLook,
    /// Family noun.
    pub family: String,
    /// Palette name.
    pub palette: String,
}

/// A look family: a noun, a category, a pool of fonts and a style builder.
pub(crate) struct Family {
    pub(crate) id: &'static str,
    pub(crate) noun: &'static str,
    pub(crate) category: TextPresetCategory,
    pub(crate) fonts: &'static [&'static str],
    pub(crate) build: fn(&LookPalette, &str) -> TextStyle,
}

/// Parametric title/caption look generator: 15 families x 12 palettes, each family rotating through its own pool of
/// bundled OFL fonts, each look paired with a motion of its category (`TextLook.suggested_motion_id`). Pure and
/// deterministic (no randomness, no clock): the same table on every run, so tests can pin it. Names are our own:
/// palette word + family noun.
pub enum TextLookGenerator {}

/// Faces that exist in one weight only (static families); everything else is a variable font that takes any weight.
const STATIC_FONTS: [&str; 15] = [
    "Bebas Neue",
    "Anton",
    "Archivo Black",
    "Passion One",
    "Russo One",
    "Lilita One",
    "Righteous",
    "DM Serif Display",
    "Pacifico",
    "Lobster",
    "Knewave",
    "Bangers",
    "Bungee",
    "Bowlby One",
    "Sigmar One",
];

// Every pool holds at least as many faces as there are palettes, so no two looks of a family share a font.
const HEAVY_FONTS: &[&str] = &[
    "Anton",
    "Bebas Neue",
    "Passion One",
    "Russo One",
    "Archivo Black",
    "League Spartan",
    "Lilita One",
    "Bangers",
    "Bungee",
    "Bowlby One",
    "Sigmar One",
    "Oswald",
    "Righteous",
    "Knewave",
];
const BOLD_FONTS: &[&str] = &[
    "Montserrat",
    "Rubik",
    "Poppins",
    "Archivo Black",
    "League Spartan",
    "Outfit",
    "Anton",
    "Lilita One",
    "Space Grotesk",
    "Fredoka",
    "Oswald",
    "Russo One",
    "Righteous",
];
const CLEAN_FONTS: &[&str] = &[
    "Montserrat",
    "Poppins",
    "Rubik",
    "Space Grotesk",
    "Outfit",
    "Inter",
    "Fredoka",
    "League Spartan",
    "Oswald",
    "Righteous",
    "Playfair Display",
    "DM Serif Display",
];
const SERIF_FONTS: &[&str] = &[
    "Playfair Display",
    "DM Serif Display",
    "Caveat",
    "Lobster",
    "Pacifico",
    "Montserrat",
    "Poppins",
    "Outfit",
    "Space Grotesk",
    "Rubik",
    "Inter",
    "Fredoka",
];
const DISPLAY_FONTS: &[&str] = &[
    "DM Serif Display",
    "Playfair Display",
    "Bowlby One",
    "Archivo Black",
    "Righteous",
    "Sigmar One",
    "Bungee",
    "Anton",
    "Passion One",
    "Lobster",
    "Pacifico",
    "Bebas Neue",
    "Oswald",
];

fn shadow(c: &RGBAColor, a: f64, dist: f64, blur: f64, angle: f64) -> TextShadow {
    TextShadow::from_angle(RGBAColor::new(c.red, c.green, c.blue, a), angle, dist, blur)
}

fn dim(c: &RGBAColor, a: f64) -> RGBAColor {
    RGBAColor::new(c.red, c.green, c.blue, a)
}

fn stroke(color: RGBAColor, width: f64) -> Option<TextStroke> {
    Some(TextStroke::new(color, width, StrokePosition::Outside))
}

fn boxed(color: RGBAColor, h: f64, v: f64, radius: f64) -> Option<TextBackground> {
    Some(TextBackground::new(color, BoxPadding::new(h, v), radius))
}

impl TextLookGenerator {
    /// The 12 palettes.
    pub fn palettes() -> &'static [LookPalette] {
        static PALETTES: OnceLock<Vec<LookPalette>> = OnceLock::new();
        PALETTES.get_or_init(|| {
            let p = LookPalette::new;
            vec![
                p("saffron", "Saffron", (1.0, 0.80, 0.10), (1.0, 0.55, 0.15), (0.12, 0.08, 0.02), (1.0, 0.97, 0.88)),
                p("coral", "Coral", (1.0, 0.42, 0.38), (1.0, 0.75, 0.30), (0.16, 0.04, 0.05), (1.0, 0.94, 0.92)),
                p("lagoon", "Lagoon", (0.10, 0.85, 0.85), (0.30, 0.60, 1.0), (0.02, 0.10, 0.14), (0.90, 1.0, 1.0)),
                p("moss", "Moss", (0.60, 0.85, 0.20), (0.20, 0.75, 0.40), (0.05, 0.10, 0.03), (0.95, 1.0, 0.90)),
                p("orchid", "Orchid", (0.85, 0.45, 1.0), (1.0, 0.40, 0.75), (0.10, 0.03, 0.15), (0.97, 0.92, 1.0)),
                p("cobalt", "Cobalt", (0.30, 0.55, 1.0), (0.50, 0.90, 1.0), (0.02, 0.04, 0.16), (0.92, 0.95, 1.0)),
                p("ember", "Ember", (1.0, 0.35, 0.10), (1.0, 0.78, 0.20), (0.15, 0.03, 0.0), (1.0, 0.93, 0.86)),
                p("slate", "Slate", (0.62, 0.70, 0.80), (0.85, 0.90, 0.95), (0.07, 0.09, 0.12), (0.94, 0.96, 0.98)),
                p("ivory", "Ivory", (0.96, 0.93, 0.82), (0.85, 0.70, 0.40), (0.10, 0.08, 0.05), (1.0, 0.99, 0.96)),
                p("mint", "Mint", (0.55, 1.0, 0.80), (0.30, 0.90, 0.60), (0.02, 0.12, 0.08), (0.93, 1.0, 0.97)),
                p("plum", "Plum", (0.90, 0.35, 0.60), (0.70, 0.40, 1.0), (0.12, 0.02, 0.08), (1.0, 0.92, 0.96)),
                p("sand", "Sand", (0.90, 0.70, 0.45), (0.75, 0.50, 0.30), (0.12, 0.07, 0.03), (0.99, 0.95, 0.90)),
            ]
        })
    }

    /// The weight `font` can actually draw closest to `wanted`.
    pub fn weight(font: &str, wanted: FontWeight) -> FontWeight {
        if STATIC_FONTS.contains(&font) {
            return FontWeight::Regular;
        }
        if font == "Poppins" {
            return if wanted >= FontWeight::Heavy {
                FontWeight::Heavy
            } else if wanted >= FontWeight::Bold {
                FontWeight::Bold
            } else {
                FontWeight::Medium
            };
        }
        wanted
    }

    fn style(f: &str, size: f64, weight: FontWeight, color: RGBAColor) -> TextStyle {
        TextStyle { font_name: f.to_string(), size, weight: Self::weight(f, weight), color, ..TextStyle::default() }
    }

    pub(crate) fn families() -> &'static [Family] {
        static FAMILIES: OnceLock<Vec<Family>> = OnceLock::new();
        use FontWeight::*;
        use TextPresetCategory::{Professional, Tiktok, Titles, Youtube};
        FAMILIES.get_or_init(|| {
            vec![
                // TikTok
                Family {
                    id: "outline-stack",
                    noun: "Outliner",
                    category: Tiktok,
                    fonts: BOLD_FONTS,
                    build: |p, f| TextStyle {
                        stroke: stroke(p.ink, 11.0),
                        shadow: Some(shadow(&p.ink, 0.55, 3.0, 8.0, 135.0)),
                        line_spacing: 2.0,
                        ..Self::style(f, 76.0, Black, p.paper)
                    },
                },
                Family {
                    id: "burst",
                    noun: "Burst",
                    category: Tiktok,
                    fonts: HEAVY_FONTS,
                    build: |p, f| TextStyle {
                        stroke: stroke(p.ink, 10.0),
                        shadow: Some(shadow(&p.ink, 0.65, 4.0, 0.0, 135.0)),
                        tracking: 1.0,
                        all_caps: true,
                        ..Self::style(f, 84.0, Bold, p.fill)
                    },
                },
                Family {
                    id: "marker",
                    noun: "Marker",
                    category: Tiktok,
                    fonts: HEAVY_FONTS,
                    build: |p, f| TextStyle {
                        background: boxed(p.fill, 22.0, 10.0, 14.0),
                        all_caps: true,
                        ..Self::style(f, 64.0, Black, p.ink)
                    },
                },
                Family {
                    id: "sticker",
                    noun: "Sticker",
                    category: Tiktok,
                    fonts: HEAVY_FONTS,
                    build: |p, f| TextStyle {
                        background: boxed(p.paper, 20.0, 9.0, 22.0),
                        shadow: Some(shadow(&p.accent, 1.0, 7.0, 0.0, 315.0)),
                        ..Self::style(f, 58.0, Heavy, p.ink)
                    },
                },
                Family {
                    id: "glow",
                    noun: "Glow",
                    category: Tiktok,
                    fonts: HEAVY_FONTS,
                    build: |p, f| TextStyle {
                        stroke: stroke(p.ink, 5.0),
                        shadow: Some(shadow(&p.accent, 0.85, 0.0, 18.0, 90.0)),
                        tracking: 2.0,
                        ..Self::style(f, 62.0, Heavy, p.paper)
                    },
                },
                Family {
                    id: "splash",
                    noun: "Splash",
                    category: Tiktok,
                    fonts: HEAVY_FONTS,
                    build: |p, f| TextStyle {
                        stroke: Some(TextStroke::new(p.ink, 8.0, StrokePosition::Centre)),
                        shadow: Some(shadow(&p.accent, 1.0, 7.0, 0.0, 135.0)),
                        tracking: 2.0,
                        ..Self::style(f, 88.0, Regular, p.paper)
                    },
                },
                // YouTube
                Family {
                    id: "shout",
                    noun: "Shout",
                    category: Youtube,
                    fonts: HEAVY_FONTS,
                    build: |p, f| TextStyle {
                        stroke: stroke(p.ink, 9.0),
                        shadow: Some(shadow(&p.ink, 0.8, 6.0, 0.0, 135.0)),
                        ..Self::style(f, 86.0, Black, p.fill)
                    },
                },
                Family {
                    id: "banner",
                    noun: "Banner",
                    category: Youtube,
                    fonts: HEAVY_FONTS,
                    build: |p, f| TextStyle {
                        background: boxed(p.accent, 26.0, 8.0, 4.0),
                        tracking: 3.0,
                        all_caps: true,
                        ..Self::style(f, 76.0, Bold, p.ink)
                    },
                },
                Family {
                    id: "ribbon",
                    noun: "Ribbon",
                    category: Youtube,
                    fonts: CLEAN_FONTS,
                    build: |p, f| TextStyle {
                        background: boxed(dim(&p.ink, 0.82), 20.0, 10.0, 12.0),
                        line_spacing: 2.0,
                        ..Self::style(f, 56.0, Bold, p.paper)
                    },
                },
                Family {
                    id: "whisper",
                    noun: "Whisper",
                    category: Youtube,
                    fonts: CLEAN_FONTS,
                    build: |p, f| TextStyle {
                        stroke: stroke(p.ink, 3.0),
                        shadow: Some(shadow(&p.ink, 0.7, 4.0, 11.0, 135.0)),
                        ..Self::style(f, 64.0, Bold, p.paper)
                    },
                },
                // Professional
                Family {
                    id: "lower-third",
                    noun: "Lower",
                    category: Professional,
                    fonts: CLEAN_FONTS,
                    build: |p, f| TextStyle {
                        background: boxed(dim(&p.ink, 0.9), 30.0, 14.0, 2.0),
                        alignment: TextAlignment::Left,
                        tracking: 1.0,
                        ..Self::style(f, 44.0, Semibold, p.paper)
                    },
                },
                Family {
                    id: "hairline",
                    noun: "Hairline",
                    category: Professional,
                    fonts: CLEAN_FONTS,
                    build: |p, f| TextStyle {
                        stroke: stroke(p.ink, 2.0),
                        shadow: Some(shadow(&p.ink, 0.6, 2.0, 7.0, 135.0)),
                        tracking: 8.0,
                        all_caps: true,
                        ..Self::style(f, 42.0, Light, p.paper)
                    },
                },
                Family {
                    id: "editorial",
                    noun: "Editorial",
                    category: Professional,
                    fonts: SERIF_FONTS,
                    build: |p, f| TextStyle {
                        shadow: Some(shadow(&p.ink, 0.75, 3.0, 9.0, 135.0)),
                        tracking: 1.0,
                        italic: true,
                        ..Self::style(f, 66.0, Regular, p.paper)
                    },
                },
                // Titles
                Family {
                    id: "poster",
                    noun: "Poster",
                    category: Titles,
                    fonts: HEAVY_FONTS,
                    build: |p, f| TextStyle {
                        stroke: stroke(p.ink, 7.0),
                        shadow: Some(shadow(&p.ink, 0.7, 6.0, 0.0, 135.0)),
                        tracking: 6.0,
                        all_caps: true,
                        ..Self::style(f, 128.0, Bold, p.fill)
                    },
                },
                Family {
                    id: "monument",
                    noun: "Monument",
                    category: Titles,
                    fonts: DISPLAY_FONTS,
                    build: |p, f| TextStyle {
                        stroke: stroke(p.ink, 6.0),
                        shadow: Some(shadow(&p.accent, 1.0, 8.0, 0.0, 135.0)),
                        ..Self::style(f, 112.0, Black, p.paper)
                    },
                },
            ]
        })
    }

    /// Every look, in family order then palette order. Fonts rotate per family (`pool[(palette_index + family_index) % pool.len()]`),
    /// so neighboring palettes of one family differ in font as well as color.
    pub fn all() -> &'static [GeneratedTextLook] {
        static ALL: OnceLock<Vec<GeneratedTextLook>> = OnceLock::new();
        ALL.get_or_init(|| {
            let mut out = Vec::new();
            let mut motion_cursor: HashMap<TextPresetCategory, usize> = HashMap::new();
            for (fi, fam) in Self::families().iter().enumerate() {
                let motions: Vec<_> = TextPresetCatalog::motions_in(fam.category)
                    .into_iter()
                    .filter(|m| m.animation_in.is_some())
                    .collect();
                for (pi, pal) in Self::palettes().iter().enumerate() {
                    let font = fam.fonts[(pi + fi) % fam.fonts.len()];
                    let n = *motion_cursor.get(&fam.category).unwrap_or(&0);
                    motion_cursor.insert(fam.category, n + 1);
                    let look = TextLook {
                        id: format!("gen-{}-{}", fam.id, pal.id),
                        name: format!("{} {}", pal.name, fam.noun),
                        category: fam.category,
                        style: (fam.build)(pal, font),
                        suggested_motion_id: if motions.is_empty() {
                            None
                        } else {
                            Some(motions[n % motions.len()].id.clone())
                        },
                    };
                    out.push(GeneratedTextLook {
                        id: look.id.clone(),
                        look,
                        family: fam.noun.to_string(),
                        palette: pal.name.clone(),
                    });
                }
            }
            out
        })
    }

    /// Every generated look.
    pub fn looks() -> Vec<TextLook> {
        Self::all().iter().map(|g| g.look.clone()).collect()
    }

    /// The family noun of a generated look id (`None` for hand-made looks): the Effects panel keeps one sub-folder per family.
    pub fn family_of_look_id(id: &str) -> Option<&'static str> {
        static BY_ID: OnceLock<BTreeMap<String, String>> = OnceLock::new();
        BY_ID
            .get_or_init(|| TextLookGenerator::all().iter().map(|g| (g.id.clone(), g.family.clone())).collect())
            .get(id)
            .map(String::as_str)
    }

    /// The contrast of the text against what carries it: its box, else its stroke, else a dense shadow (1 when none).
    /// Boxes with alpha are judged over black and white alike (the worse of the two).
    pub fn readability(s: &TextStyle) -> f64 {
        if let Some(b) = &s.background {
            return ColorContrast::ratio(&s.color, &ColorContrast::composite(&b.color, 0.0))
                .min(ColorContrast::ratio(&s.color, &ColorContrast::composite(&b.color, 1.0)));
        }
        if let Some(st) = &s.stroke {
            return ColorContrast::ratio(&s.color, &st.color);
        }
        if let Some(sh) = &s.shadow
            && sh.color.alpha >= 0.5
        {
            return ColorContrast::ratio(&s.color, &sh.color);
        }
        1.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bundled_fonts;
    use std::collections::BTreeSet;

    fn all() -> &'static [GeneratedTextLook] {
        TextLookGenerator::all()
    }

    #[test]
    fn contrast_maths() {
        assert!((ColorContrast::ratio(&RGBAColor::BLACK, &RGBAColor::WHITE) - 21.0).abs() < 0.01);
        assert!((ColorContrast::ratio(&RGBAColor::WHITE, &RGBAColor::WHITE) - 1.0).abs() < 0.001);
    }

    #[test]
    fn size_ids_and_names() {
        assert!((150..=300).contains(&all().len()));
        assert_eq!(all().iter().map(|g| g.id.as_str()).collect::<BTreeSet<_>>().len(), all().len());
        assert_eq!(all().iter().map(|g| g.look.name.as_str()).collect::<BTreeSet<_>>().len(), all().len());
        // The whole catalog stays unique with the hand-made looks and the motions.
        let mut ids: Vec<String> = TextPresetCatalog::looks().iter().map(|l| l.id.clone()).collect();
        ids.extend(TextPresetCatalog::motions().iter().map(|m| m.id.clone()));
        assert_eq!(ids.iter().collect::<BTreeSet<_>>().len(), ids.len());
    }

    #[test]
    fn own_vocabulary_names() {
        let banned =
            ["premiere", "capcut", "adobe", "tiktok", "youtube", "mogrt", "final cut", "resolve", "canva", "alight"];
        for g in all() {
            let n = g.look.name.to_lowercase();
            for b in banned {
                assert!(!n.contains(b), "{}", g.look.name);
            }
        }
    }

    #[test]
    fn every_category_has_looks() {
        for c in TextPresetCategory::ALL {
            assert!(all().iter().filter(|g| g.look.category == c).count() >= 20, "{c:?}");
        }
    }

    #[test]
    fn deterministic() {
        let looks: Vec<TextLook> = all().iter().map(|g| g.look.clone()).collect();
        assert_eq!(TextLookGenerator::looks(), looks);
        // The table is rebuilt from the same inputs: the first and last entries are pinned.
        assert_eq!(all().first().map(|g| g.id.as_str()), Some("gen-outline-stack-saffron"));
        assert_eq!(all().last().map(|g| g.id.as_str()), Some("gen-monument-sand"));
    }

    #[test]
    fn all_bundled_fonts_are_used() {
        let used: BTreeSet<&str> = all().iter().map(|g| g.look.style.font_name.as_str()).collect();
        for f in &bundled_fonts::FAMILIES {
            assert!(used.contains(f.name), "{} unused", f.name);
        }
        for u in used {
            assert!(bundled_fonts::is_bundled(u), "{u}");
        }
    }

    #[test]
    fn fonts_never_repeat_within_a_family() {
        for fam in TextLookGenerator::families() {
            assert!(fam.fonts.len() >= TextLookGenerator::palettes().len(), "{}", fam.id);
            let prefix = format!("gen-{}-", fam.id);
            let fonts: Vec<&str> = all()
                .iter()
                .filter(|g| g.look.id.starts_with(&prefix))
                .map(|g| g.look.style.font_name.as_str())
                .collect();
            assert_eq!(fonts.iter().collect::<BTreeSet<_>>().len(), fonts.len(), "{}", fam.id);
        }
    }

    #[test]
    fn static_fonts_keep_regular_weight() {
        for g in all()
            .iter()
            .filter(|g| ["Anton", "Bebas Neue", "Bangers", "Pacifico"].contains(&g.look.style.font_name.as_str()))
        {
            assert_eq!(g.look.style.weight, FontWeight::Regular, "{}", g.id);
        }
    }

    #[test]
    fn palette_invariants() {
        for p in TextLookGenerator::palettes() {
            assert!(ColorContrast::ratio(&p.fill, &p.ink) >= 4.5, "{} fill", p.name);
            assert!(ColorContrast::ratio(&p.accent, &p.ink) >= 4.5, "{} accent", p.name);
            assert!(ColorContrast::ratio(&p.paper, &p.ink) >= 10.0, "{} paper", p.name);
        }
        let names: BTreeSet<&str> = TextLookGenerator::palettes().iter().map(|p| p.name.as_str()).collect();
        assert_eq!(names.len(), TextLookGenerator::palettes().len());
    }

    /// WCAG-ish: text against what carries it (box, stroke or dense shadow) is at least 4.5:1 for every look; every palette
    /// and every font appears, so this covers every palette/font pair that ships.
    #[test]
    fn every_look_is_readable() {
        for g in all() {
            let r = TextLookGenerator::readability(&g.look.style);
            assert!(r >= 4.5, "{} {}: {r}", g.id, g.look.style.font_name);
            assert!(g.look.style.size >= 40.0);
        }
    }

    #[test]
    fn glow_and_shadow_accents_do_not_carry_the_text() {
        // A look whose only backing is a shadow must have a dense one (alpha >= 0.5); none of ours rely on the accent alone.
        for g in all().iter().filter(|g| g.look.style.stroke.is_none() && g.look.style.background.is_none()) {
            assert!(g.look.style.shadow.map(|s| s.color.alpha).unwrap_or(0.0) >= 0.5, "{}", g.id);
        }
    }

    /// Curation: no two looks are near-identical.
    #[test]
    fn no_near_duplicates() {
        fn d(a: &RGBAColor, b: &RGBAColor) -> f64 {
            ((a.red - b.red).powi(2) + (a.green - b.green).powi(2) + (a.blue - b.blue).powi(2)).sqrt()
        }
        fn distance(x: &TextStyle, y: &TextStyle) -> f64 {
            let clear = RGBAColor::CLEAR;
            let mut s = d(&x.color, &y.color);
            s += d(&x.stroke.map(|s| s.color).unwrap_or(clear), &y.stroke.map(|s| s.color).unwrap_or(clear));
            s += d(&x.background.map(|s| s.color).unwrap_or(clear), &y.background.map(|s| s.color).unwrap_or(clear));
            s += d(&x.shadow.map(|s| s.color).unwrap_or(clear), &y.shadow.map(|s| s.color).unwrap_or(clear)) * 0.5;
            if x.font_name != y.font_name {
                s += 0.6;
            }
            if x.stroke.is_none() != y.stroke.is_none() {
                s += 0.6;
            }
            if x.background.is_none() != y.background.is_none() {
                s += 0.6;
            }
            if x.all_caps != y.all_caps {
                s += 0.3;
            }
            if x.italic != y.italic {
                s += 0.3;
            }
            if x.alignment != y.alignment {
                s += 0.3;
            }
            s += (x.size - y.size).abs() / 40.0 + (x.tracking - y.tracking).abs() / 10.0;
            s += (x.stroke.map(|s| s.width).unwrap_or(0.0) - y.stroke.map(|s| s.width).unwrap_or(0.0)).abs() / 8.0;
            s += (x.background.map(|b| b.corner_radius).unwrap_or(0.0)
                - y.background.map(|b| b.corner_radius).unwrap_or(0.0))
            .abs()
                / 20.0;
            s
        }
        let mut styles: Vec<(String, TextStyle)> = all().iter().map(|g| (g.id.clone(), g.look.style.clone())).collect();
        styles.extend(TextPresetCatalog::handmade().iter().map(|l| (l.id.clone(), l.style.clone())));
        let mut close: Vec<String> = Vec::new();
        for i in 0..styles.len() {
            for j in (i + 1)..styles.len() {
                let v = distance(&styles[i].1, &styles[j].1);
                if v < 0.45 {
                    close.push(format!("{} ~ {}: {v}", styles[i].0, styles[j].0));
                }
            }
        }
        assert!(close.is_empty(), "{} near-duplicates, e.g. {:?}", close.len(), &close[..close.len().min(12)]);
    }

    #[test]
    fn suggested_motions_exist_and_fit_the_category() {
        for g in all() {
            let id = g.look.suggested_motion_id.clone();
            assert!(id.is_some(), "{}", g.id);
            let id = id.unwrap_or_default();
            let m = TextPresetCatalog::motions().iter().find(|m| m.id == id);
            assert!(m.is_some(), "{id}");
            if let Some(m) = m {
                assert!(m.category == g.look.category && m.animation_in.is_some());
            }
        }
        // Every in-motion of a category is suggested somewhere (the animation presets are all reachable).
        for c in TextPresetCategory::ALL {
            let ins: BTreeSet<String> = TextPresetCatalog::motions_in(c)
                .into_iter()
                .filter(|m| m.animation_in.is_some())
                .map(|m| m.id)
                .collect();
            let used: BTreeSet<String> = all()
                .iter()
                .filter(|g| g.look.category == c)
                .filter_map(|g| g.look.suggested_motion_id.clone())
                .collect();
            assert_eq!(used, ins, "{c:?}");
        }
    }

    #[test]
    fn look_is_found_by_pasteboard_id() {
        let g = &all()[40];
        assert_eq!(TextPresetCatalog::look(&TextPresetCatalog::look_id(&g.look)), Some(g.look.clone()));
    }
}
