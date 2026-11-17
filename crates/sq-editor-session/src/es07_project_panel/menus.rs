//! Rows for the Project panel menus: empty area, bin, item, column header (Swift `ProjectPanelMenus`). Pure: no native
//! menu, the panel maps [`ProjectMenuAction`]s to calls. The shared project list builds the same rows on every system.

use std::rc::Rc;

use sq_core_model::{AudioChannelMap, LabelColor, PixelAspect};
use sq_core_time::Id;
use sq_os::Platform;
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::sqmenu_model::{SQMenuIcon, SQMenuItem};

use super::Column;

/// What a menu row asks the panel to do.
// Swift: ProjectPanelMenus.swift:9
#[derive(Clone, Debug, PartialEq)]
pub enum ProjectMenuAction {
    NewFolder,
    NewColorMatte,
    NewSequence,
    ImportMedia,
    Find,
    GoUp,
    ToggleHoverScrub,
    OpenInSource,
    OpenInTimeline,
    Insert,
    Overwrite,
    SequenceFromClip,
    MakeSubclip,
    EditOriginal,
    Rename,
    DeletePoster,
    Reveal,
    ReplaceMedia,
    LocateMedia,
    Delete,
    /// Source settings > Pixel Aspect: `None` = From File.
    SetPixelAspect(Option<PixelAspect>),
    CustomPixelAspect,
    /// Source settings > Deinterlace of the selected interlaced media items.
    SetDeinterlace(bool),
    /// `None`: back to the default label of the item's type.
    SetLabel(Option<LabelColor>),
    SelectLabelGroup(LabelColor),
    ToggleColumn(Column),
    ResetColumns,
    /// The file channels the media items play (`None` = the file's layout).
    SetAudioChannels(Option<AudioChannelMap>),
    /// The selected media items become one Angles clip.
    CreateAnglesClip,
    /// The selected media items fill the slots of the active sequence (Fill Reel…).
    FillReel,
    /// Like Delete, but media a sequence still uses goes offline and its clips stay.
    ClearUsedMedia,
    /// The sound of the single selected media item as its own M4A item.
    ExtractAudio,
    /// Variable-frame-rate media items become constant-rate copies the items take over (background job).
    ConformToConstantFrameRate,
}

/// What the menu needs to know about the clicked selection and the panel.
// Swift: ProjectPanelMenus.swift:36
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ProjectMenuContext {
    // Swift: ProjectPanelMenus.swift:38
    pub media: Vec<Id>,
    // Swift: ProjectPanelMenus.swift:39
    pub has_bin: bool,
    // Swift: ProjectPanelMenus.swift:40
    pub has_sequence: bool,
    // Swift: ProjectPanelMenus.swift:41
    pub target_count: usize,
    // Swift: ProjectPanelMenus.swift:42
    pub all_media_online: bool,
    // Swift: ProjectPanelMenus.swift:43
    pub single_media_offline: bool,
    // Swift: ProjectPanelMenus.swift:44
    pub single_media_has_poster: bool,
    /// The single media item has a Source In or Out (Make Subclip needs one).
    // Swift: ProjectPanelMenus.swift:46
    pub single_media_has_marks: bool,
    /// Label shared by all non-bin targets (`None` when mixed or none).
    // Swift: ProjectPanelMenus.swift:48
    pub shared_label: Option<LabelColor>,
    /// The label of the first non-bin target.
    // Swift: ProjectPanelMenus.swift:49
    pub first_label: Option<LabelColor>,
    // Swift: ProjectPanelMenus.swift:50
    pub has_non_bin_target: bool,
    // Swift: ProjectPanelMenus.swift:51
    pub is_icon_view: bool,
    // Swift: ProjectPanelMenus.swift:52
    pub can_go_up: bool,
    // Swift: ProjectPanelMenus.swift:53
    pub hover_scrub: bool,
    /// The rows of the Pixel Aspect submenu (`PixelAspectChoices.items`, built by the caller with its `run`); `None` = no
    /// Pixel Aspect row (no picture, offline mix...). Replaces Swift's `pixelAspect: PixelAspectChoices.State?`, which
    /// belongs to ES8.
    // Swift: ProjectPanelMenus.swift:55
    pub pixel_aspect_rows: Option<Vec<SQMenuItem>>,
    /// Channels of the selected media's sound (0 = none, or the items differ).
    // Swift: ProjectPanelMenus.swift:57
    pub audio_channels: i64,
    /// The rows of the Audio Channels submenu (`AudioChannelsMenu.items`, built by the caller); empty = no row. Replaces
    /// Swift's `audioChannelMap`, which only fed that builder.
    // Swift: ProjectPanelMenus.swift:58
    pub audio_channel_rows: Vec<SQMenuItem>,
    /// Deinterlace of the selected media items, all interlaced (true = on for all); `None` = no Deinterlace row.
    // Swift: ProjectPanelMenus.swift:60
    pub deinterlace: Option<bool>,
    /// A selected media item is still used by a sequence (Delete would be blocked: Clear Used Media is offered).
    // Swift: ProjectPanelMenus.swift:62
    pub any_media_used: bool,
    /// The active sequence has clips to use as slots (Fill Reel…).
    // Swift: ProjectPanelMenus.swift:64
    pub can_fill_reel: bool,
    /// A selected media item is variable-frame-rate video (Conform to Constant Frame Rate).
    // Swift: ProjectPanelMenus.swift:66
    pub can_conform_to_cfr: bool,
}

impl ProjectMenuContext {
    // Swift: ProjectPanelMenus.swift:67
    pub fn new() -> ProjectMenuContext {
        ProjectMenuContext::default()
    }
}

/// Handler of a picked row.
pub type MenuRun = Rc<dyn Fn(ProjectMenuAction)>;

/// Premiere-style Project menus in one place.
// Swift: ProjectPanelMenus.swift:7
pub enum ProjectPanelMenus {}

impl ProjectPanelMenus {
    /// Shortcut text of an editor command in the current key map ("" when unbound or not showable).
    // Swift: ProjectPanelMenus.swift:82
    pub fn shortcut(command: &EditorCommand, map: &CommandMap) -> String {
        map.shown_binding_here(command).map(|b| KeyBindingText::text(&b, Platform::current())).unwrap_or_default()
    }

    /// The three Project menus: empty area, bin, item. Entries for features we do not have are left out. `shortcut`
    /// gives the key text of a command (`ProjectPanelMenus::shortcut` with the current map).
    // Swift: ProjectPanelMenus.swift:91
    pub fn items(c: &ProjectMenuContext, shortcut: &dyn Fn(&EditorCommand) -> String, run: MenuRun) -> Vec<SQMenuItem> {
        let mut rows: Vec<SQMenuItem> = Vec::new();
        let add = |rows: &mut Vec<SQMenuItem>,
                   title: &str,
                   a: ProjectMenuAction,
                   enabled: bool,
                   key: Option<EditorCommand>| {
            let mut item = SQMenuItem::new(title);
            item.shortcut = key.map(|k| shortcut(&k)).unwrap_or_default();
            item.is_enabled = enabled;
            let run = Rc::clone(&run);
            item.action = Some(Rc::new(move || run(a.clone())));
            rows.push(item);
        };
        use ProjectMenuAction as A;
        if c.target_count == 0 {
            add(&mut rows, "New Folder", A::NewFolder, true, Some(EditorCommand::NewBin));
            add(&mut rows, "New Sequence…", A::NewSequence, true, Some(EditorCommand::NewSequence));
            add(&mut rows, "New Color Matte…", A::NewColorMatte, true, None);
            rows.push(SQMenuItem::separator());
            add(&mut rows, "Import…", A::ImportMedia, true, Some(EditorCommand::ImportMedia));
            rows.push(SQMenuItem::separator());
            add(&mut rows, "Find…", A::Find, true, Some(EditorCommand::Find));
            if c.is_icon_view {
                add(&mut rows, "Up One Level", A::GoUp, c.can_go_up, None);
                let mut hover = SQMenuItem::new("Hover Scrub");
                hover.is_checked = c.hover_scrub;
                let r = Rc::clone(&run);
                hover.action = Some(Rc::new(move || r(A::ToggleHoverScrub)));
                rows.push(hover);
            }
            return rows;
        }
        let single = c.media.len() == 1;
        if !c.media.is_empty() && !c.has_bin && !c.has_sequence {
            add(&mut rows, "Open in Source", A::OpenInSource, single && c.all_media_online, None);
            rows.push(SQMenuItem::separator());
            add(&mut rows, "Insert", A::Insert, c.all_media_online, Some(EditorCommand::Insert));
            add(&mut rows, "Overwrite", A::Overwrite, c.all_media_online, Some(EditorCommand::Overwrite));
            add(&mut rows, "New Sequence From Clip", A::SequenceFromClip, single && c.all_media_online, None);
            add(
                &mut rows,
                "Make Subclip",
                A::MakeSubclip,
                single && c.single_media_has_marks,
                Some(EditorCommand::MakeSubclip),
            );
            if c.media.len() >= 2 {
                add(&mut rows, "Create Angles Clip…", A::CreateAnglesClip, c.all_media_online, None);
            }
            if c.can_fill_reel {
                add(&mut rows, "Fill Reel…", A::FillReel, c.all_media_online, None);
            }
            rows.push(SQMenuItem::separator());
        } else if c.has_sequence && !c.has_bin && c.media.is_empty() {
            add(&mut rows, "Open in Timeline", A::OpenInTimeline, c.target_count == 1, None);
            rows.push(SQMenuItem::separator());
            add(&mut rows, "Insert", A::Insert, true, Some(EditorCommand::Insert));
            add(&mut rows, "Overwrite", A::Overwrite, true, Some(EditorCommand::Overwrite));
            rows.push(SQMenuItem::separator());
        }
        if c.has_bin && c.target_count == 1 {
            add(&mut rows, "New Folder", A::NewFolder, true, Some(EditorCommand::NewBin));
            rows.push(SQMenuItem::separator());
        }
        add(&mut rows, "Rename", A::Rename, c.target_count == 1, None);
        if single && !c.has_bin && !c.has_sequence && c.single_media_has_poster {
            add(&mut rows, "Delete Poster Frame", A::DeletePoster, true, None);
        }
        if c.has_non_bin_target {
            rows.push(SQMenuItem::separator());
            let mut label = SQMenuItem::new("Label");
            label.submenu = Some(Self::label_items(c, Rc::clone(&run)));
            rows.push(label);
            if let Some(first) = c.first_label {
                let mut group = SQMenuItem::new("Select Label Group");
                let r = Rc::clone(&run);
                group.action = Some(Rc::new(move || r(A::SelectLabelGroup(first))));
                rows.push(group);
            }
        }
        if !c.media.is_empty() {
            rows.push(SQMenuItem::separator());
            if let Some(pa) = &c.pixel_aspect_rows {
                let mut item = SQMenuItem::new("Pixel Aspect");
                item.submenu = Some(pa.clone());
                rows.push(item);
            }
            if let Some(on) = c.deinterlace {
                let mut item = SQMenuItem::new("Deinterlace");
                item.is_checked = on;
                let r = Rc::clone(&run);
                item.action = Some(Rc::new(move || r(A::SetDeinterlace(!on))));
                rows.push(item);
            }
            add(&mut rows, Platform::current().reveal_title(), A::Reveal, true, None);
            add(&mut rows, "Edit Original", A::EditOriginal, c.all_media_online, Some(EditorCommand::EditOriginal));
            if single && c.single_media_offline {
                add(&mut rows, "Locate…", A::LocateMedia, true, None);
            }
            if single {
                add(
                    &mut rows,
                    if c.single_media_offline { "Reconnect Media…" } else { "Replace Media…" },
                    A::ReplaceMedia,
                    true,
                    None,
                );
            }
            if !c.audio_channel_rows.is_empty() {
                let mut item = SQMenuItem::new("Audio Channels");
                item.submenu = Some(c.audio_channel_rows.clone());
                rows.push(item);
            }
            if single && c.audio_channels > 0 {
                add(&mut rows, "Extract Audio", A::ExtractAudio, c.all_media_online, None);
            }
            if c.can_conform_to_cfr {
                add(
                    &mut rows,
                    "Conform to Constant Frame Rate",
                    A::ConformToConstantFrameRate,
                    c.all_media_online,
                    None,
                );
            }
        }
        rows.push(SQMenuItem::separator()); // destructive entries last
        if c.any_media_used {
            add(&mut rows, "Clear Used Media", A::ClearUsedMedia, true, None);
        }
        add(&mut rows, "Delete", A::Delete, true, Some(EditorCommand::DeleteProjectItems));
        rows
    }

    // Swift: ProjectPanelMenus.swift:166
    pub fn label_items(c: &ProjectMenuContext, run: MenuRun) -> Vec<SQMenuItem> {
        let mut default = SQMenuItem::new("Default");
        let r = Rc::clone(&run);
        default.action = Some(Rc::new(move || r(ProjectMenuAction::SetLabel(None))));
        let mut rows = vec![default, SQMenuItem::separator()];
        for l in LabelColor::ALL {
            let mut item = SQMenuItem::new(l.display_name());
            item.icon = SQMenuIcon::Swatch(l.rgb());
            item.is_checked = c.shared_label == Some(l);
            let r = Rc::clone(&run);
            item.action = Some(Rc::new(move || r(ProjectMenuAction::SetLabel(Some(l)))));
            rows.push(item);
        }
        rows
    }

    /// Column header right-click: toggle each optional column (Name is fixed), then Reset Columns.
    // Swift: ProjectPanelMenus.swift:179
    pub fn header_items(is_visible: &dyn Fn(Column) -> bool, run: MenuRun) -> Vec<SQMenuItem> {
        let mut rows = Vec::new();
        for col in Column::ALL.into_iter().filter(|c| *c != Column::Name) {
            let mut item = SQMenuItem::new(col.title());
            item.is_checked = is_visible(col);
            let r = Rc::clone(&run);
            item.action = Some(Rc::new(move || r(ProjectMenuAction::ToggleColumn(col))));
            rows.push(item);
        }
        rows.push(SQMenuItem::separator());
        let mut reset = SQMenuItem::new("Reset Columns");
        reset.action = Some(Rc::new(move || run(ProjectMenuAction::ResetColumns)));
        rows.push(reset);
        rows
    }
}
