// Swift: LibraryMenus.swift
//! SQ rows for the Library panel menus (sidebar folder, file item, preset). Pure: the panel maps `Action`s to calls.

use sq_library::preset_organizer::{PresetCategory, PresetMetaTable};
use sq_os::Platform;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::rc::Rc;

/// What a menu row asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Action {
    /// Rescan the folder.
    Rescan,
    /// Remove the folder from the Library.
    RemoveFolder,
    /// Toggle the favorite mark of the selected files.
    ToggleFavorite,
    /// Whoosh at the selected cuts.
    Whoosh,
    /// Copy the audio files into the SFX bin.
    AddToSFX,
    /// Reveal the files.
    Reveal,
    /// Insert the saved title at the playhead.
    InsertTitleBlock,
    /// Apply the effect preset with the remembered mode.
    ApplyPreset,
    /// Apply it absolute.
    ApplyAbsolute,
    /// Apply it relative.
    ApplyRelative,
    /// Switch the remembered mode.
    ToggleDefaultApply,
    /// Export the preset.
    ExportPreset,
    /// Import presets.
    ImportPresets,
    /// Delete the preset.
    DeletePreset,
    /// Export a pack.
    ExportPack,
    /// Import a pack.
    ImportPack,
    /// Organizing a preset or built-in template: favorite.
    ToggleFavoritePreset,
    /// Shelf (none = back to the default shelf).
    SetCategory(Option<PresetCategory>),
    /// Tag on/off.
    ToggleTag(String),
}

/// Current organizing state of the clicked preset or template (none in the context = no organize rows).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Organize {
    /// Marked favorite.
    pub is_favorite: bool,
    /// The shelf now.
    pub category: PresetCategory,
    /// The shelf without the user's choice.
    pub default_category: PresetCategory,
    /// The tags now.
    pub tags: Vec<String>,
}

/// What the menu depends on.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Context {
    /// The presets section is shown.
    pub shows_presets: bool,
    /// An audio file is selected.
    pub has_audio: bool,
    /// The host places sounds on cuts.
    pub can_whoosh: bool,
    /// The preset is a saved title.
    pub preset_is_title_block: bool,
    /// The preset is an effect preset.
    pub preset_is_effect: bool,
    /// A motion preset (a keystone): applied to the selected clip, no absolute / relative mode.
    pub preset_is_motion: bool,
    /// A saved preset was clicked.
    pub has_preset: bool,
    /// The remembered apply mode is relative.
    pub relative_default: bool,
    /// Organizing state.
    pub organize: Option<Organize>,
}

/// The rows of the Library menus.
pub enum LibraryMenus {}

/// Runs an action when its row is picked.
pub type Run = Rc<dyn Fn(Action)>;

fn row(run: &Run, title: &str, a: Action, enabled: bool) -> SQMenuItem {
    let mut item = SQMenuItem::new(title);
    item.is_enabled = enabled;
    let run = Rc::clone(run);
    item.action = Some(Rc::new(move || run(a.clone())));
    item
}

impl LibraryMenus {
    /// The sidebar menu of a watched folder.
    pub fn folder_items(run: &Run) -> Vec<SQMenuItem> {
        vec![
            row(run, "Rescan", Action::Rescan, true),
            SQMenuItem::separator(),
            row(run, "Remove Folder", Action::RemoveFolder, true),
        ]
    }

    /// Sidebar menu of a pack folder.
    pub fn pack_items(run: &Run) -> Vec<SQMenuItem> {
        vec![
            row(run, "Export as Pack\u{2026}", Action::ExportPack, true),
            row(run, "Import Pack\u{2026}", Action::ImportPack, true),
        ]
    }

    /// File items, or the preset items of the Presets section.
    pub fn item_items(c: &Context, run: &Run) -> Vec<SQMenuItem> {
        if !c.shows_presets {
            return vec![
                row(run, "Toggle Favorite", Action::ToggleFavorite, true),
                row(run, "Whoosh at Selected Cuts", Action::Whoosh, c.has_audio && c.can_whoosh),
                row(run, "Add to SFX Folder", Action::AddToSFX, c.has_audio),
                row(run, Platform::current().reveal_title(), Action::Reveal, true),
            ];
        }
        let mut organise: Vec<SQMenuItem> = Vec::new();
        if let Some(o) = &c.organize {
            let mut tags: Vec<String> = PresetMetaTable::SUGGESTED_TAGS.iter().map(|t| t.to_string()).collect();
            tags.extend(o.tags.iter().filter(|t| !PresetMetaTable::SUGGESTED_TAGS.contains(&t.as_str())).cloned());
            organise.push(row(
                run,
                if o.is_favorite { "Remove from Favorites" } else { "Add to Favorites" },
                Action::ToggleFavoritePreset,
                true,
            ));
            let mut category = SQMenuItem::new("Category");
            category.submenu = Some(
                PresetCategory::ALL
                    .iter()
                    .map(|cat| {
                        let pick = if *cat == o.default_category { None } else { Some(*cat) };
                        let mut item = row(run, cat.title(), Action::SetCategory(pick), true);
                        item.is_checked = o.category == *cat;
                        item
                    })
                    .collect(),
            );
            organise.push(category);
            let mut tag_menu = SQMenuItem::new("Tags");
            tag_menu.submenu = Some(
                tags.iter()
                    .map(|tag| {
                        let mut item = row(run, tag, Action::ToggleTag(tag.clone()), true);
                        item.is_checked = o.tags.contains(tag);
                        item
                    })
                    .collect(),
            );
            organise.push(tag_menu);
            organise.push(SQMenuItem::separator());
        }
        organise.extend([
            row(run, "Insert at Playhead", Action::InsertTitleBlock, c.preset_is_title_block),
            row(run, "Apply to Selected Clips", Action::ApplyPreset, c.preset_is_effect || c.preset_is_motion),
            row(run, "Apply Absolute (Replace Values)", Action::ApplyAbsolute, c.preset_is_effect),
            row(run, "Apply Relative (Add to Clip)", Action::ApplyRelative, c.preset_is_effect),
            row(
                run,
                if c.relative_default {
                    "Default Apply: Relative (switch to Absolute)"
                } else {
                    "Default Apply: Absolute (switch to Relative)"
                },
                Action::ToggleDefaultApply,
                true,
            ),
            row(run, "Export\u{2026}", Action::ExportPreset, c.has_preset),
            row(run, "Import Presets\u{2026}", Action::ImportPresets, true),
            row(run, "Export as Pack\u{2026}", Action::ExportPack, c.has_preset),
            row(run, "Import Pack\u{2026}", Action::ImportPack, true),
            SQMenuItem::separator(), // destructive entry last
            row(run, "Delete", Action::DeletePreset, c.has_preset),
        ]);
        organise
    }
}
