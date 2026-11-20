// Swift: LibraryPanelLogic.swift
//! Names and icons of the Library panel, the sidebar rows, the preset cells and the tile geometry.

use crate::library::library_panel_model::{LibraryFolderRow, LibrarySection};
use crate::library::text_templates::TextTemplateEntry;
use sq_core_time::Id;
use sq_library::favorites::LibraryStoreError;
use sq_library::library_index::FolderState;
use sq_library::library_item_kind::LibraryItemKind;
use sq_library::preset_organizer::PresetKey;
use sq_library::preset_store::{PresetFileError, PresetItem, PresetKind};
use sq_library::sqpack::SQPackError;
use sq_library::sqpack_store::SQPackImportError;
use sq_uikit::controls_grid::CGSize;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use std::path::{Path, PathBuf};

/// Presets that are placed on the timeline as titles (double-click, drag, "Insert at Playhead"): title blocks and title
/// templates.
pub trait PresetKindTitleExt {
    /// Whether the kind is a title block or title template.
    fn is_title_insert(&self) -> bool;
}

impl PresetKindTitleExt for PresetKind {
    fn is_title_insert(&self) -> bool {
        matches!(self, PresetKind::TitleBlock | PresetKind::TitleTemplate)
    }
}

/// Why a preset or pack action failed (the Swift `any Error` the Library flows catch).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LibraryError {
    /// The preset store or a Library file.
    Store(LibraryStoreError),
    /// A `.sqpreset` file.
    Preset(PresetFileError),
    /// A `.sqpack` file.
    Pack(SQPackError),
    /// A pack import.
    Import(SQPackImportError),
}

impl From<LibraryStoreError> for LibraryError {
    fn from(e: LibraryStoreError) -> Self {
        LibraryError::Store(e)
    }
}
impl From<PresetFileError> for LibraryError {
    fn from(e: PresetFileError) -> Self {
        LibraryError::Preset(e)
    }
}
impl From<SQPackError> for LibraryError {
    fn from(e: SQPackError) -> Self {
        LibraryError::Pack(e)
    }
}
impl From<SQPackImportError> for LibraryError {
    fn from(e: SQPackImportError) -> Self {
        LibraryError::Import(e)
    }
}

/// Names and icons of the Library panel.
pub enum LibraryLabels {}

impl LibraryLabels {
    /// The icon of an item kind.
    pub fn symbol(kind: LibraryItemKind) -> SQIcon {
        match kind {
            LibraryItemKind::Video => SQIcon::Film,
            LibraryItemKind::Audio => SQIcon::Waveform,
            LibraryItemKind::Image => SQIcon::Image,
            LibraryItemKind::Overlay => SQIcon::Group,
            LibraryItemKind::Lut => SQIcon::Palette,
            LibraryItemKind::Font => SQIcon::Text,
            LibraryItemKind::Other => SQIcon::File,
        }
    }

    /// The shown name of an item kind.
    pub fn title(kind: LibraryItemKind) -> String {
        SQL10n::string(match kind {
            LibraryItemKind::Video => "Video",
            LibraryItemKind::Audio => "Audio",
            LibraryItemKind::Image => "Image",
            LibraryItemKind::Overlay => "Overlay",
            LibraryItemKind::Lut => "LUT",
            LibraryItemKind::Font => "Font",
            LibraryItemKind::Other => "Other",
        })
    }

    /// Sidebar icons of the Presets group (board `side()`).
    pub fn preset_symbol(kind: Option<PresetKind>) -> SQIcon {
        match kind {
            None | Some(PresetKind::Effect) => SQIcon::SlidersHorizontal,
            Some(PresetKind::TextTemplate)
            | Some(PresetKind::AnimatedTextTemplate)
            | Some(PresetKind::TitleBlock)
            | Some(PresetKind::TitleTemplate) => SQIcon::Text,
            Some(PresetKind::Easing) | Some(PresetKind::Keystone) => SQIcon::MoveHorizontal,
            Some(PresetKind::Caption) => SQIcon::Captions,
            Some(PresetKind::Transition) => SQIcon::Columns2,
        }
    }

    /// The shown name of a preset kind (none = all kinds).
    pub fn preset_title(kind: Option<PresetKind>) -> String {
        SQL10n::string(match kind {
            None => "All Presets",
            Some(PresetKind::TextTemplate) => "Text Templates",
            Some(PresetKind::AnimatedTextTemplate) => "Animated Text",
            Some(PresetKind::Easing) => "Easing",
            Some(PresetKind::Caption) => "Captions",
            Some(PresetKind::Effect) => "Effects",
            Some(PresetKind::Transition) => "Transitions",
            Some(PresetKind::Keystone) => "Motion",
            Some(PresetKind::TitleBlock) => "Title Blocks",
            Some(PresetKind::TitleTemplate) => "Title Templates",
        })
    }

    /// What the empty list says and how to fill it (INTERACTION-AUDIT section 10): (title, hint).
    pub fn empty_text(
        offline: bool,
        preset_mode: bool,
        favorites: bool,
        has_folders: bool,
        query: &str,
    ) -> (String, String) {
        let q = crate::geom::trim_ws(query);
        let pair = |a: &str, b: &str| (SQL10n::string(a), SQL10n::string(b));
        if !q.is_empty() {
            return (
                SQL10n::string("No results"),
                SQL10n::format("Nothing in the library matches \u{201C}%@\u{201D}.", &[q]),
            );
        }
        if offline {
            return pair(
                "Folder is offline",
                "The drive with this folder is not connected. Reconnect it, then right-click the folder and choose Rescan.",
            );
        }
        if preset_mode {
            return pair(
                "No presets",
                "Save an effect, a look or a keystone as a preset and it appears here. Right-click to import presets.",
            );
        }
        if favorites {
            return pair("No favorites yet", "Right-click an item and choose Toggle Favorite to find it here.");
        }
        if !has_folders {
            return pair("No Media Yet", "Import video, audio and images to use them in this project.");
        }
        pair("Nothing in this folder", "Files you add to the folder appear here.")
    }

    /// The text of a failed preset import or save (the Mac `showError`): (title, detail).
    pub fn preset_error(error: &LibraryError, file: Option<&Path>) -> (String, String) {
        let title = match file.and_then(|f| f.file_name()) {
            Some(n) => format!("\u{201C}{}\u{201D} could not be imported.", n.to_string_lossy()),
            None => "The preset could not be saved.".to_string(),
        };
        let detail = match error {
            LibraryError::Store(LibraryStoreError::NewerFormat { .. })
            | LibraryError::Preset(PresetFileError::Store(LibraryStoreError::NewerFormat { .. })) => {
                "It was made by a newer version of Sequence Studio.".to_string()
            }
            LibraryError::Preset(PresetFileError::NotAPreset) => "It is not a Sequence Studio preset.".to_string(),
            LibraryError::Preset(PresetFileError::DamagedPayload) => {
                "The preset inside the file is damaged.".to_string()
            }
            LibraryError::Store(e) | LibraryError::Preset(PresetFileError::Store(e)) => SQL10n::error_text(e),
            LibraryError::Preset(PresetFileError::UnknownKind(_)) => {
                "It is a kind of preset this version does not know.".to_string()
            }
            LibraryError::Pack(e) | LibraryError::Import(SQPackImportError::Pack(e)) => {
                Self::pack_error(&LibraryError::Pack(e.clone()))
            }
            LibraryError::Import(SQPackImportError::Store(e)) => SQL10n::error_text(e),
        };
        (title, detail)
    }

    /// The text of a failed pack import or export (the Mac `LibraryPackFlow.message`).
    pub fn pack_error(error: &LibraryError) -> String {
        match error {
            LibraryError::Pack(e) | LibraryError::Import(SQPackImportError::Pack(e)) => match e {
                SQPackError::NotAPack => SQL10n::string("It is not a Sequence Studio pack."),
                SQPackError::NewerFormat { .. } => SQL10n::string("It was made by a newer version of Sequence Studio."),
                SQPackError::TooLarge(_) => SQL10n::string("It is larger than a pack may be."),
                SQPackError::EmptyPack => SQL10n::string("The pack holds nothing this version can read."),
                SQPackError::MissingLicense(_) => SQL10n::string("A font in it has no recorded open font license."),
                SQPackError::ChecksumMismatch(_) | SQPackError::InvalidAsset(_) => {
                    SQL10n::string("A file inside it is damaged or not allowed.")
                }
                SQPackError::DamagedEntry(n) => {
                    SQL10n::format("The preset \u{201C}%@\u{201D} inside it is damaged.", &[n])
                }
                SQPackError::InvalidManifest(_) | SQPackError::Malformed(_) => {
                    SQL10n::string("Its description is damaged.")
                }
                SQPackError::Io(text) => text.clone(),
            },
            LibraryError::Store(e)
            | LibraryError::Import(SQPackImportError::Store(e))
            | LibraryError::Preset(PresetFileError::Store(e)) => SQL10n::error_text(e),
            LibraryError::Preset(_) => SQL10n::string("The preset could not be read."),
        }
    }
}

/// One row of the Library sidebar tree (v9): "Library" (every folder) > Favorites + the watched folders; "Presets" >
/// the preset kinds; "Packs" > the imported packs.
#[derive(Clone, Debug, PartialEq)]
pub struct LibrarySidebarRow {
    /// Shown name.
    pub title: String,
    /// Leading icon.
    pub symbol: SQIcon,
    /// What a click selects (none: a plain group heading).
    pub section: Option<LibrarySection>,
    /// A group heading row.
    pub is_group: bool,
    /// The folder's drive is not connected.
    pub is_offline: bool,
}

impl LibrarySidebarRow {
    fn row(title: &str, symbol: SQIcon, section: Option<LibrarySection>, is_group: bool) -> LibrarySidebarRow {
        LibrarySidebarRow { title: title.to_string(), symbol, section, is_group, is_offline: false }
    }

    /// The sidebar of the current mode: Media shows Library, Favorites and the folders; Presets shows "All Presets" and
    /// the imported packs (the kinds are the chips above the list).
    pub fn rows(folders: &[LibraryFolderRow], pack_names: &[String], presets_mode: bool) -> Vec<LibrarySidebarRow> {
        let mut out = Vec::new();
        if presets_mode {
            out.push(Self::row("All Presets", SQIcon::SlidersHorizontal, Some(LibrarySection::Presets(None)), true));
        } else {
            out.push(Self::row("Library", SQIcon::Folder, Some(LibrarySection::All), true));
            out.push(Self::row("Favorites", SQIcon::Star, Some(LibrarySection::Favorites), false));
            out.extend(folders.iter().map(|f| {
                let off = f.state == FolderState::Offline;
                let mut r = Self::row(
                    &f.folder.display_name,
                    if off { SQIcon::DriveOffline } else { SQIcon::Folder },
                    Some(LibrarySection::Folder(f.folder.id)),
                    false,
                );
                r.is_offline = off;
                r
            }));
        }
        if presets_mode && !pack_names.is_empty() {
            out.push(Self::row("Packs", SQIcon::Folder, None, true));
            out.extend(
                pack_names.iter().map(|n| Self::row(n, SQIcon::Package, Some(LibrarySection::Pack(n.clone())), false)),
            );
        }
        out
    }
}

/// A row or tile of the presets section: a built-in text template or a preset the user saved.
#[derive(Clone, Debug, PartialEq)]
pub enum LibraryPresetCell {
    /// A built-in template.
    Template(TextTemplateEntry),
    /// A saved preset.
    User(PresetItem),
    /// A built-in audio stack: its id (`AudioPresets`) and name.
    AudioStack(String, String),
    /// A LUT file of the LUT library: path and shown name.
    Lut(String, String),
}

impl LibraryPresetCell {
    /// Shown name.
    pub fn name(&self) -> &str {
        match self {
            LibraryPresetCell::Template(t) => &t.name,
            LibraryPresetCell::User(p) => &p.name,
            LibraryPresetCell::AudioStack(_, n) | LibraryPresetCell::Lut(_, n) => n,
        }
    }

    /// The cell's icon.
    pub fn symbol(&self) -> SQIcon {
        match self {
            LibraryPresetCell::Template(t) => {
                if t.graphic_preset_id.is_none() {
                    SQIcon::Text
                } else {
                    SQIcon::Sparkles
                }
            }
            LibraryPresetCell::User(p) => LibraryLabels::preset_symbol(Some(p.kind)),
            LibraryPresetCell::AudioStack(..) => SQIcon::Waveform,
            LibraryPresetCell::Lut(..) => SQIcon::Palette,
        }
    }

    /// The use-counter key (`PresetKey`).
    pub fn preset_key(&self) -> String {
        match self {
            LibraryPresetCell::Template(t) => PresetKey::built_in(&t.id),
            LibraryPresetCell::User(p) => PresetKey::user(p.id),
            LibraryPresetCell::AudioStack(id, _) => PresetKey::built_in(id),
            LibraryPresetCell::Lut(path, _) => format!("lut:{path}"),
        }
    }

    /// What dragging the cell carries (the Mac pasteboard writer); none = not draggable.
    pub fn drag_payload(&self) -> Option<LibraryDragPayload> {
        match self {
            LibraryPresetCell::Template(t) => Some(LibraryDragPayload::TextTemplate(t.id.clone())),
            LibraryPresetCell::User(p) if p.kind.is_title_insert() => Some(LibraryDragPayload::TitleBlock(p.id)),
            LibraryPresetCell::User(p) if matches!(p.kind, PresetKind::Effect | PresetKind::Keystone) => {
                Some(LibraryDragPayload::EffectPreset(p.id))
            }
            LibraryPresetCell::User(_) => None,
            LibraryPresetCell::AudioStack(id, _) => Some(LibraryDragPayload::AudioStack(id.clone())),
            // shortcut: a LUT cannot be dropped on a clip yet (the look slot lives in the Color page model); double-click applies.
            LibraryPresetCell::Lut(..) => None,
        }
    }
}

/// What a drag out of the Library carries (the Mac pasteboard types): files (onto the timeline: import and place), a
/// built-in text template or a saved title (placed where it lands), an effect preset (applied to the clip under it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LibraryDragPayload {
    /// Files.
    Files(Vec<PathBuf>),
    /// A built-in template id.
    TextTemplate(String),
    /// A saved title.
    TitleBlock(Id),
    /// A saved effect preset.
    EffectPreset(Id),
    /// A built-in audio stack (applied to the audio clip under it).
    AudioStack(String),
}

/// Grid geometry of the Library tiles (v9 `.tiles`: the slider sets the smallest tile, the columns share the width).
pub enum LibraryTileGeometry {}

impl LibraryTileGeometry {
    /// The settings key of the slider.
    pub const TILE_SIZE_KEY: &'static str = "sq.library.tileSize";
    /// The slider's start.
    pub const DEFAULT_FRACTION: f64 = 0.4;
    /// Thumbnail height over width.
    pub const ASPECT: f64 = 10.0 / 16.0;
    /// Space between thumbnail and name.
    pub const NAME_GAP: f64 = 4.0;
    /// Height of the name line.
    pub const NAME_HEIGHT: f64 = 14.0;
    /// The pack label's line under a preset tile's name.
    pub const PACK_LINE: f64 = 12.0;
    /// Space between tiles.
    pub const GAP: f64 = 8.0;

    /// Space between a preset tile's preview and its name.
    pub const PRESET_NAME_GAP: f64 = 7.0;
    /// Height of a preset tile's caption band: name line, kind and pack line, padding.
    pub const PRESET_CAPTION: f64 = 42.0;

    /// A preset tile's preview height for its width (the kit's wide, flat preview).
    pub fn preset_thumb_height(width: f64) -> f64 {
        (width * 0.42).round()
    }

    /// Presets: two flat columns (one when the panel is very narrow), whatever the tile slider says.
    pub fn preset_layout(avail: f64) -> (i64, CGSize) {
        let columns = if avail >= 2.0 * 96.0 + Self::GAP { 2 } else { 1 };
        let w = ((avail - (columns - 1) as f64 * Self::GAP) / columns as f64).floor().max(1.0);
        (columns, CGSize::new(w, Self::preset_thumb_height(w) + Self::PRESET_CAPTION))
    }

    /// Slider fraction (0...1) -> thumbnail width; 0.4 is the board's 96 (`LibraryTile.thumbWidth`).
    pub fn thumb_width(fraction: f64) -> f64 {
        (64.0 + 80.0 * fraction.clamp(0.0, 1.0)).round()
    }

    /// Columns and the stretched tile size for the available width.
    pub fn layout(avail: f64, fraction: f64) -> (i64, CGSize) {
        let tw = Self::thumb_width(fraction);
        let columns = (((avail + Self::GAP) / (tw + Self::GAP)).floor() as i64).max(1);
        let w = ((avail - (columns - 1) as f64 * Self::GAP) / columns as f64).floor().max(tw);
        (columns, CGSize::new(w, (w * Self::ASPECT).round() + Self::NAME_GAP + Self::NAME_HEIGHT))
    }
}
