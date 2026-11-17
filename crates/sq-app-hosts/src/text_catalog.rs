// Swift: SQInspectorUI/TextTemplateTiles.swift (TextTemplateCatalog, TextTemplateTile.tiles) read by the Library
//! The built-in text templates the Library's Presets section lists: the inspector crate's `TextTemplateCatalog`.

use sq_draw_library::library::text_templates::{TextTemplateEntry, TextTemplateTile as LibraryTile, TextTemplates};
use sq_inspector_ui::text::template_tiles::{TextTemplateCatalog, TextTemplateTile};
use sq_library::preset_store::PresetItem;

/// `TextTemplateCatalog.all`, read each time so the caption styles are current.
pub struct CatalogTemplates;

impl TextTemplates for CatalogTemplates {
    fn entries(&self) -> Vec<TextTemplateEntry> {
        TextTemplateCatalog::all()
            .into_iter()
            .map(|e| TextTemplateEntry {
                id: e.id,
                name: e.name,
                is_cta: e.is_cta,
                graphic_preset_id: e.graphic_preset_id,
            })
            .collect()
    }

    fn tiles(&self, presets: &[PresetItem]) -> Vec<LibraryTile> {
        TextTemplateTile::tiles(presets, &TextTemplateCatalog::all())
            .into_iter()
            .map(|t| LibraryTile { preset_key: t.preset_key(), sample_text: t.sample_text, style: t.style })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_captions_title_2_tier_cta_and_graphics_in_swift_order() {
        let e = CatalogTemplates.entries();
        let pos = |id: &str| e.iter().position(|x| x.id == id);
        let (t2, cta) = (pos("title-2-tier"), pos("cta-end-card"));
        assert!(t2.is_some() && cta == t2.map(|i| i + 1), "title 2-tier then the CTA card");
        assert!(e[..t2.unwrap_or(0)].iter().all(|x| !x.is_cta && x.graphic_preset_id.is_none()));
        assert!(e[cta.unwrap_or(0) + 1..].iter().all(|x| x.graphic_preset_id.is_some()));
        assert!(e.iter().any(|x| x.name == "Title 2-Tier"));
        assert!(!e.iter().any(|x| x.id.starts_with("gen-")), "generated looks stay in the Captions gallery");
    }

    #[test]
    fn tiles_follow_the_entries_when_the_library_is_empty() {
        let tiles = CatalogTemplates.tiles(&[]);
        assert_eq!(tiles.len(), CatalogTemplates.entries().len());
        let t2 = tiles.iter().find(|t| t.preset_key.contains("title-2-tier")).map(|t| t.sample_text.clone());
        assert_eq!(t2.as_deref(), Some("Pixel\n9 Pro"));
    }
}
