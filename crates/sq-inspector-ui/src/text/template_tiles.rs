// Swift: TextTemplateTiles.swift
//! One pickable text or graphic template of the Text panel's Templates tab, and placing a picked one.

use sq_core_time::{Id, Time};
use sq_editor_session::EditorSession;
use sq_editor_session::{CTAEndCard, GraphicPresetCatalog};
use sq_library::preset_organizer::PresetKey;
use sq_library::preset_store::{PresetItem, PresetKind};
use sq_library::title_block::TitleBlock;
use sq_library::title_template_preset::TitleTemplatePreset;
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::generated_caption_looks::GeneratedCaptionLooks;
use sq_text::text_style::{FontWeight, RGBAColor, TextAlignment, TextLineStyle, TextShadow, TextStyle};
use sq_text::text_template::TextTemplate;
use sq_uikit::localization::SQL10n;

/// One entry of `TextTemplateCatalog` (the Library's built-in text templates), as far as the tiles read it.
#[derive(Clone, Debug, PartialEq)]
pub struct TextTemplateCatalogEntry {
    pub id: String,
    pub name: String,
    pub template: TextTemplate,
    /// The CTA end card: placed as a Graphics clip, `template` is only a placeholder.
    pub is_cta: bool,
    /// A built-in sticker or lower third, placed as a Graphics clip.
    pub graphic_preset_id: Option<String>,
    /// Shown in the Library's Kind column.
    pub kind_label: String,
}

/// Text layer templates offered in the Library (Text Templates): the built-in caption styles as ready-made titles, plus
/// "Title 2-Tier" (small line over a big line in one text clip) and the CTA end card (a graphic).
// Swift: ClipSectionLogic.swift (TextTemplateCatalog)
pub enum TextTemplateCatalog {}

impl TextTemplateCatalog {
    pub const PLACEHOLDER_TEXT: &'static str = "Your text";
    pub const TITLE_2_TIER_ID: &'static str = "title-2-tier";

    /// "TOP LINE" small, tracked caps over a big heavy second line in the same text clip (`TextStyle.second_line`): the
    /// paragraph break is the line split.
    pub fn title_2_tier() -> TextTemplate {
        let shadow =
            TextShadow::from_angle(RGBAColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 0.6 }, 135.0, 4.0, 10.0);
        let font = TextStyle::default_font_name();
        let big = TextLineStyle::new(font, 150.0, FontWeight::Black, RGBAColor::WHITE, false);
        let mut style = TextStyle::new(font, 52.0, FontWeight::Bold, RGBAColor::WHITE);
        style.shadow = Some(shadow);
        style.alignment = TextAlignment::Center;
        style.line_spacing = 0.0;
        style.tracking = 8.0;
        style.all_caps = true;
        style.second_line = Some(big);
        TextTemplate::new("Title 2-Tier", "Pixel\n9 Pro", style)
    }

    /// Read from the live caption library each time, so the kit caption style and token values are current.
    pub fn all() -> Vec<TextTemplateCatalogEntry> {
        let lib = CaptionPresetLibrary::built_in();
        // The generated caption looks live in the Captions look gallery, not in this Library list.
        let mut out: Vec<TextTemplateCatalogEntry> = lib
            .style_ids()
            .into_iter()
            .filter(|id| !id.starts_with(GeneratedCaptionLooks::STYLE_PREFIX))
            .map(|id| {
                let name = id
                    .split('-')
                    .filter(|w| !w.is_empty())
                    .map(|w| {
                        let mut c = w.chars();
                        c.next().map(|f| f.to_uppercase().chain(c).collect::<String>()).unwrap_or_default()
                    })
                    .collect::<Vec<_>>()
                    .join(" ");
                let template = TextTemplate::new(&name, Self::PLACEHOLDER_TEXT, lib.style(Some(&id)));
                TextTemplateCatalogEntry {
                    id,
                    name,
                    template,
                    is_cta: false,
                    graphic_preset_id: None,
                    kind_label: "Text Template".to_string(),
                }
            })
            .collect();
        out.push(TextTemplateCatalogEntry {
            id: Self::TITLE_2_TIER_ID.to_string(),
            name: "Title 2-Tier".to_string(),
            template: Self::title_2_tier(),
            is_cta: false,
            graphic_preset_id: None,
            kind_label: "Text Template".to_string(),
        });
        out.push(TextTemplateCatalogEntry {
            id: CTAEndCard::ID.to_string(),
            name: CTAEndCard::NAME.to_string(),
            template: TextTemplate::new(CTAEndCard::NAME, CTAEndCard::LABEL, TextStyle::default()),
            is_cta: true,
            graphic_preset_id: None,
            kind_label: "Text Template".to_string(),
        });
        for g in GraphicPresetCatalog::all() {
            let label = g.category.label();
            let name = format!("{} {label}", g.name);
            out.push(TextTemplateCatalogEntry {
                id: g.id.clone(),
                template: TextTemplate::new(&name, label, TextStyle::default()),
                name,
                is_cta: false,
                graphic_preset_id: Some(g.id),
                kind_label: label.to_string(),
            });
        }
        out
    }

    pub fn entry(id: &str) -> Option<TextTemplateCatalogEntry> {
        Self::all().into_iter().find(|e| e.id == id)
    }
}

/// Where a tile comes from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TileSource {
    BuiltIn(String),
    User(Id, PresetKind),
}

#[derive(Clone, Debug, PartialEq)]
pub struct TextTemplateTile {
    pub source: TileSource,
    pub name: String,
    /// Drawn with the real text renderer when there is no saved picture.
    pub style: Option<TextStyle>,
    pub sample_text: String,
    /// PNG of a saved multi-layer template.
    pub thumbnail: Option<Vec<u8>>,
}

impl TextTemplateTile {
    /// The text a tile shows when the template has none.
    pub const SAMPLE_TEXT: &'static str = "Text";

    pub fn id(&self) -> String {
        match &self.source {
            TileSource::BuiltIn(id) => format!("builtin:{id}"),
            TileSource::User(id, _) => format!("user:{id}"),
        }
    }

    /// The Library's text-like items in the order the tab shows them: the user's own first (they made them for reuse),
    /// then the built-ins.
    pub fn tiles(presets: &[PresetItem], built_ins: &[TextTemplateCatalogEntry]) -> Vec<TextTemplateTile> {
        let own = presets.iter().filter_map(|p| match p.kind {
            PresetKind::TextTemplate | PresetKind::AnimatedTextTemplate => {
                let t = TextTemplate::decode_from(&p.payload).ok();
                let text = match &t {
                    Some(t) if !t.text.is_empty() => t.text.clone(),
                    _ => Self::SAMPLE_TEXT.to_string(),
                };
                Some(TextTemplateTile {
                    source: TileSource::User(p.id, p.kind),
                    name: p.name.clone(),
                    style: t.map(|t| t.style),
                    sample_text: text,
                    thumbnail: None,
                })
            }
            PresetKind::TitleTemplate => {
                let png = TitleTemplatePreset::from_preset(p).ok().and_then(|t| t.thumbnail);
                Some(TextTemplateTile {
                    source: TileSource::User(p.id, p.kind),
                    name: p.name.clone(),
                    style: None,
                    sample_text: p.name.clone(),
                    thumbnail: png,
                })
            }
            PresetKind::TitleBlock => Some(TextTemplateTile {
                source: TileSource::User(p.id, p.kind),
                name: p.name.clone(),
                style: None,
                sample_text: p.name.clone(),
                thumbnail: None,
            }),
            _ => None,
        });
        let built = built_ins.iter().map(|e| TextTemplateTile {
            source: TileSource::BuiltIn(e.id.clone()),
            name: e.name.clone(),
            style: (e.graphic_preset_id.is_none() && !e.is_cta).then(|| e.template.style.clone()),
            sample_text: if e.template.text.is_empty() {
                Self::SAMPLE_TEXT.to_string()
            } else {
                e.template.text.clone()
            },
            thumbnail: None,
        });
        own.chain(built).collect()
    }

    /// The tiles whose name contains `query` (case-insensitive); all of them for an empty query.
    pub fn filter(tiles: Vec<TextTemplateTile>, query: &str) -> Vec<TextTemplateTile> {
        let q = query.trim_matches(' ');
        if q.is_empty() {
            return tiles;
        }
        let q = q.to_lowercase();
        tiles.into_iter().filter(|t| t.name.to_lowercase().contains(&q)).collect()
    }

    /// The Library's use counter key of the tile (`PresetKey`).
    pub fn preset_key(&self) -> String {
        match &self.source {
            TileSource::BuiltIn(id) => PresetKey::built_in(id),
            TileSource::User(id, _) => PresetKey::user(*id),
        }
    }
}

/// Placing a picked template at the playhead (`insertTitleBlock`, `insertTitleTemplate`, `placeTextTemplate`).
pub enum TextTemplatePlacement {}

impl TextTemplatePlacement {
    /// Places `tile` (`presets` = the Library's items, for a saved one; `built_ins` = the catalog for a built-in one).
    /// Returns the status line, `None` when there is none.
    pub fn place(
        tile: &TextTemplateTile,
        presets: &[PresetItem],
        built_ins: &[TextTemplateCatalogEntry],
        session: &mut EditorSession,
    ) -> Option<String> {
        match &tile.source {
            TileSource::BuiltIn(id) => {
                let entry = built_ins.iter().find(|e| e.id == *id)?;
                if entry.is_cta {
                    session.add_cta_end_card(None, None);
                    return None;
                }
                if let Some(g) = &entry.graphic_preset_id {
                    session.add_graphic_preset(g, None, None);
                    return None;
                }
                session.add_text_clip(&entry.template, None, None, Time::new(5, 1), None, false);
                None
            }
            TileSource::User(id, kind) => {
                let item = presets.iter().find(|p| p.id == *id)?;
                if *kind == PresetKind::TitleBlock || *kind == PresetKind::TitleTemplate {
                    return Some(Self::insert_title(item, None, None, session));
                }
                let Ok(template) = TextTemplate::decode_from(&item.payload) else {
                    return Some(SQL10n::string("The template could not be read."));
                };
                session.add_text_clip(&template, None, None, Time::new(5, 1), None, false);
                None
            }
        }
    }

    /// A saved title block or multi-layer title template at `time` (`None` = the playhead); returns the status line.
    pub fn insert_title(
        item: &PresetItem,
        time: Option<Time>,
        track: Option<Id>,
        session: &mut EditorSession,
    ) -> String {
        if item.kind == PresetKind::TitleTemplate {
            let Ok(preset) = TitleTemplatePreset::from_preset(item) else {
                return SQL10n::string("The template could not be read.");
            };
            let template = preset.template;
            session.stop_playback();
            if session.insert_title_template(&template, time, track).is_none() {
                return session
                    .last_error()
                    .map_or_else(|| SQL10n::string("The template could not be placed."), str::to_string);
            }
            let at = time.unwrap_or_else(|| session.playhead());
            session.seek(at);
            return SQL10n::string("Template placed. Edit its text in Controls.");
        }
        let Ok(block) = TitleBlock::from_preset(item) else {
            return SQL10n::string("The title block could not be read.");
        };
        session.stop_playback();
        if session.insert_title_block(&block, time).is_empty() {
            return session
                .last_error()
                .map_or_else(|| SQL10n::string("The title block could not be placed."), str::to_string);
        }
        let at = time.unwrap_or_else(|| session.playhead());
        session.seek(at);
        SQL10n::string("Title block placed. Double-click a line to type.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Timestamp;
    use sq_text::text_style::TextStyle;

    fn entry(id: &str, name: &str, text: &str) -> TextTemplateCatalogEntry {
        TextTemplateCatalogEntry {
            id: id.into(),
            name: name.into(),
            template: TextTemplate::new(name, text, TextStyle::default()),
            is_cta: false,
            graphic_preset_id: None,
            kind_label: "Text Template".into(),
        }
    }

    #[test]
    fn catalog_has_the_h1_entries_and_the_swift_title_2_tier() {
        let all = TextTemplateCatalog::all();
        assert!(all.iter().any(|e| e.kind_label == "Text Template"));
        let t = TextTemplateCatalog::entry(TextTemplateCatalog::TITLE_2_TIER_ID).map(|e| e.template);
        let t = t.unwrap_or_else(|| panic!("title 2-tier"));
        assert_eq!(t.text, "Pixel\n9 Pro");
        assert_eq!((t.style.size, t.style.tracking, t.style.all_caps), (52.0, 8.0, true));
        assert_eq!(t.style.second_line.as_ref().map(|l| l.size), Some(150.0));
        let cta = TextTemplateCatalog::entry(CTAEndCard::ID).unwrap_or_else(|| panic!("cta"));
        assert!(cta.is_cta && cta.template.text == CTAEndCard::LABEL);
        let g = all.iter().find(|e| e.graphic_preset_id.is_some()).unwrap_or_else(|| panic!("graphic"));
        assert_eq!(g.template.text, g.kind_label);
        assert!(g.name.ends_with(&g.kind_label));
    }

    #[test]
    fn user_templates_come_before_built_ins() {
        let t = TextTemplate::new("Mine", "Hello", TextStyle::default());
        let payload = t.encoded().unwrap_or_else(|e| panic!("{e}"));
        let item = PresetItem::new(
            Id::fixed(1),
            PresetKind::TextTemplate,
            "Mine",
            Timestamp::from_reference_seconds(0.0),
            payload,
            1,
        );
        let tiles = TextTemplateTile::tiles(&[item], &[entry("b", "Bold", "")]);
        assert_eq!(tiles.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["Mine", "Bold"]);
        assert_eq!(tiles[0].sample_text, "Hello");
        assert_eq!(tiles[1].sample_text, "Text");
        assert_eq!(tiles[1].id(), "builtin:b");
    }

    #[test]
    fn filter_is_case_insensitive_and_empty_keeps_all() {
        let tiles = TextTemplateTile::tiles(&[], &[entry("a", "Big Title", ""), entry("b", "Lower Third", "")]);
        assert_eq!(TextTemplateTile::filter(tiles.clone(), "  ").len(), 2);
        let f = TextTemplateTile::filter(tiles, "third");
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].name, "Lower Third");
    }

    #[test]
    fn cta_and_graphic_entries_have_no_style() {
        let mut cta = entry("cta", "CTA", "Subscribe");
        cta.is_cta = true;
        let tiles = TextTemplateTile::tiles(&[], &[cta]);
        assert!(tiles[0].style.is_none());
    }
}
