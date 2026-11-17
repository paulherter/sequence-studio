//! The built-in text templates the Presets section lists (Swift `TextTemplateCatalog`, `TextTemplateTile` of SQInspectorUI).
//!
//! The catalog and the tiles live behind this seam; the app hands in the real ones
//! (`LibraryPanelModel::set_templates`, `sq-app-hosts` `CatalogTemplates`), the Library lists none until then.

use sq_library::preset_store::PresetItem;
use sq_text::text_style::TextStyle;

/// One built-in template (the fields of `TextTemplateCatalog.Entry` the Library uses).
#[derive(Clone, Debug, PartialEq)]
pub struct TextTemplateEntry {
    /// Stable id (a caption style id, `title-2-tier`, the CTA end card or a graphic preset).
    pub id: String,
    /// Shown name.
    pub name: String,
    /// The CTA end card: placed as a Graphics clip.
    pub is_cta: bool,
    /// A built-in sticker or lower third (`GraphicPresetCatalog` id), placed as a Graphics clip.
    pub graphic_preset_id: Option<String>,
}

/// One tile of the Text panel's template list, as the Library grid draws it.
#[derive(Clone, Debug, PartialEq)]
pub struct TextTemplateTile {
    /// The use-counter key of the tile (`PresetKey`).
    pub preset_key: String,
    /// The text the tile shows.
    pub sample_text: String,
    /// Drawn with the real text renderer when there is no saved picture.
    pub style: Option<TextStyle>,
}

/// The built-in templates and the tiles of all text-like items.
pub trait TextTemplates {
    /// `TextTemplateCatalog.all`, read each time so the caption styles are current.
    fn entries(&self) -> Vec<TextTemplateEntry>;
    /// `TextTemplateTile.tiles(presets:builtIns:)`: the user's own first, then the built-ins.
    fn tiles(&self, presets: &[PresetItem]) -> Vec<TextTemplateTile>;
}

/// No built-in templates.
pub struct NoTextTemplates;

impl TextTemplates for NoTextTemplates {
    fn entries(&self) -> Vec<TextTemplateEntry> {
        Vec::new()
    }
    fn tiles(&self, _presets: &[PresetItem]) -> Vec<TextTemplateTile> {
        Vec::new()
    }
}
