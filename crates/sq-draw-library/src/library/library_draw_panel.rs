// Swift: LibraryDrawPanel.swift
//! The Library panel on the shared draw toolkit.
//!
//! Translated from the Mac `LibraryPanelView` on the same `LibraryPanelModel`: the sidebar tree (Library > Favorites +
//! watched folders, Presets > kinds, Packs), the search row with the view switch and the tile size slider, the preset group chips,
//! the grid (sections per subfolder, thumbnails from the host's `picture`, template tiles in their own type) or the list
//! (Name, Kind, Size, Date), selection with Command / Shift, the item, preset, folder and pack menus (`LibraryMenus`),
//! the "..." options (view, sort, preset filters), the empty states, double-click to place or apply a preset, and drags
//! out (files, templates, titles, effect presets) that the host routes onto the timeline. Coordinates are panel-local
//! points, y down. The preview bar at the bottom (`library_draw_panel_preview`) is the AppKit `LibraryPreviewBar`.
//!
//! Mapping (docs/rust/session-ui-design.md section 2): the panel owns its model. The hooks (`onRequest`, `onMenu`,
//! `onDrag`) are [`LibraryPanelEvent`]s the owner drains with `take_events`; the host's `picture` and `previewFrame`
//! closures are a parameter of `draw` and a field the host fills. Menu rows queue their pick; `pump` runs the picks after
//! the menu closed. The model's observation tracking is `LibraryPanelModel::version`.
//! known limit: the viewer shows the host's live frame (`preview_frame`) or the item's poster, and LUT tiles show their icon, not the look on the test
//! picture; upgrade when the draw toolkit has a live picture slot per panel.

use crate::geom::{dist, trim_ws};
use crate::library::library_menus::{Action, Context, LibraryMenus, Organize, Run};
use crate::library::library_panel_logic::{
    LibraryDragPayload, LibraryLabels, LibraryPresetCell, LibrarySidebarRow, LibraryTileGeometry, PresetKindTitleExt,
};
use crate::library::library_panel_model::{LibraryItem, LibraryPanelModel, LibrarySection, LibraryViewMode};
use crate::library::text_templates::TextTemplateTile;
use crate::menu_queue::MenuQueue;
use sq_core_effects::effect_preset::ApplyMode;
use sq_core_time::{Id, Timestamp};
use sq_draw::scroll::{ScrollBody, ScrollGesture};
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{radius, spacing, type_size};
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Alignment, Canvas, Color, DrawTheme, InputKey, InputModifiers, TextAlign, TextFieldControl, UiCx};
use sq_editor_session::PresetApplyModeSetting;
use sq_library::library_folder_store::SettingsStore;
use sq_library::library_grouping::LibraryGroup;
use sq_library::library_item_kind::LibraryItemKind;
use sq_library::library_search::LibrarySortKey;
use sq_library::preset_organizer::{PresetCategory, PresetKey, PresetScope, PresetSortKey};
use sq_library::preset_store::{PresetItem, PresetKind};
use sq_library::watched_folder::LibraryEntryID;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqbyte_size::SQByteSize;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::collections::{BTreeSet, HashMap};
use std::path::PathBuf;
use std::rc::Rc;

/// What the Library panel asks of its host (file choosers, dialogs, the timeline): the Mac panel's NSOpenPanel /
/// NSSavePanel / SQDialog / NSWorkspace calls and its `onApplyTextTemplate` / `onWhoosh` closures.
#[derive(Clone, Debug, PartialEq)]
pub enum LibraryRequest {
    /// Choose a folder to watch.
    AddFolder,
    /// Show the files in the file manager.
    Reveal(Vec<PathBuf>),
    /// Whoosh at the selected cuts with this sound.
    Whoosh(PathBuf),
    /// Place the built-in template with this id.
    ApplyTextTemplate(String),
    /// Apply the built-in audio stack with this id to the selected audio clips.
    ApplyAudioStack(String),
    /// Set this LUT file as the look of the clip on the Color page (the Color LUT popup's pick).
    ApplyLut(String),
    /// Export the preset to a file.
    ExportPreset(PresetItem),
    /// Choose `.sqpreset` files to import.
    ImportPresets,
    /// Ask, then delete the preset.
    DeletePreset(PresetItem),
    /// Export a pack of these presets.
    ExportPack {
        /// The presets.
        ids: Vec<Id>,
        /// The pack name to suggest.
        suggested_name: String,
    },
    /// Choose a `.sqpack` to import.
    ImportPack,
}

/// Where a drag out of the panel is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DragPhase {
    /// The pointer moved.
    Moved,
    /// Released outside the panel.
    Ended,
    /// Dropped back on the panel or escaped.
    Canceled,
}

/// What the panel reports to its host (the Swift hooks `onRequest`, `onMenu`, `onDrag`).
#[derive(Clone, Debug)]
pub enum LibraryPanelEvent {
    /// A dialog, file chooser or timeline call.
    Request(LibraryRequest),
    /// A menu at a panel-local point.
    Menu(Vec<SQMenuItem>, CGPoint),
    /// A drag out of the panel; the point is panel-local (the host turns it into window pixels).
    Drag(LibraryDragPayload, DragPhase, CGPoint),
}

/// One entry of the content in display order.
#[derive(Clone, Debug, PartialEq)]
pub enum Cell {
    /// A section header.
    Header(LibraryGroup),
    /// A file.
    Item(LibraryItem),
    /// A built-in or saved preset.
    Preset(LibraryPresetCell),
}

impl Cell {
    /// The selection key. A file listed under All and under its subfolder is one key: selection marks both copies.
    pub fn key(&self) -> String {
        match self {
            Cell::Header(g) => format!("h:{}", g.id),
            Cell::Item(it) => format!("i:{}/{}", it.entry.folder_id, it.entry.relative_path),
            Cell::Preset(p) => p.preset_key(),
        }
    }

    pub fn is_header(&self) -> bool {
        matches!(self, Cell::Header(_))
    }
}

/// A cell and its frame in content coordinates (y from the list top, before scrolling).
#[derive(Clone, Copy, Debug)]
pub struct Placed {
    /// Index into the cells.
    pub index: usize,
    /// The cell's frame.
    pub frame: CGRect,
}

/// What a press on the bar or a divider is dragging.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BarDrag {
    /// The viewer's top edge.
    Viewer {
        /// Height at the press.
        start_height: f64,
        /// Pointer y at the press.
        start_y: f64,
    },
    /// The sidebar's edge.
    Sidebar {
        /// Width at the press.
        start_width: f64,
        /// Pointer x at the press.
        start_x: f64,
    },
    /// The scrub bar.
    Scrub,
    /// The volume slider.
    Volume,
    /// The viewer picture, dragged out as a file.
    FileOut {
        /// Where the press was.
        start: CGPoint,
    },
}

/// The rubber band of a drag that started on the grid's empty background.
#[derive(Clone, Debug)]
pub struct Marquee {
    /// Content coordinates (y from the list top, before scrolling), so scrolling keeps the band on its tiles.
    pub start: CGPoint,
    /// The pointer now.
    pub current: CGPoint,
    /// The selection a Cmd or Shift press keeps.
    pub base: BTreeSet<String>,
}

impl Marquee {
    /// The band.
    pub fn rect(&self) -> CGRect {
        CGRect::new(
            self.start.x.min(self.current.x),
            self.start.y.min(self.current.y),
            (self.start.x - self.current.x).abs(),
            (self.start.y - self.current.y).abs(),
        )
    }
}

/// A picture of a file or preset: the image slot, the normalized part of it that holds the picture and the picture's
/// size in pixels. The panel fits the picture into its rect by that size (bars around it), it never stretches it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LibraryPicture {
    /// The draw list's image slot.
    pub slot: usize,
    /// The source rect (x0, y0, x1, y1).
    pub source: [f32; 4],
    /// The picture's size in pixels.
    pub size: CGSize,
}

/// The item's thumbnail for a tile rect (the host's media atlas: poster frame of a video, the picture of an image).
pub type PictureFn<'a> = &'a dyn Fn(&LibraryItem, CGRect) -> Option<LibraryPicture>;

#[derive(Clone)]
enum MenuCmd {
    SetViewMode(LibraryViewMode),
    AddFolder,
    SortBy(LibrarySortKey),
    SortPresets(PresetSortKey),
    Scope(PresetScope),
    Category(Option<PresetCategory>),
    Tag(Option<String>),
    ClearFilters,
    Folder(Action, Id),
    Pack(Action, String),
    /// Shows or hides the presets of one pack in the lists.
    TogglePack(String),
    Item(Box<ItemPick>),
}

#[derive(Clone)]
struct ItemPick {
    action: Action,
    items: Vec<LibraryItem>,
    audio: Option<LibraryItem>,
    preset: Option<PresetItem>,
    selected_presets: Vec<PresetItem>,
    key: Option<String>,
}

/// One chip of the Library's preset chip row (the Media mode has no chips): a preset group.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LibraryChip {
    Preset(PresetKind),
    /// The built-in audio stacks.
    AudioStacks,
    /// The LUT files.
    Luts,
}

/// The Library panel on the shared draw toolkit.
pub struct LibraryDrawPanel {
    /// The model the panel shows.
    pub model: LibraryPanelModel,
    /// The panel has keyboard focus: the sidebar selection is accent, else the quiet gray of the AppKit sidebar.
    pub has_focus: bool,
    pub(crate) defaults: Box<dyn UiDefaults>,
    pub(crate) settings: Box<dyn SettingsStore>,
    /// The width the user dragged the sidebar to (none = default); see `sidebar_w` for the clamped value.
    pub(crate) stored_sidebar_width: Option<f64>,
    /// The viewer height while a divider drag runs, before it is stored.
    pub(crate) bar_drag: Option<BarDrag>,
    /// Where the last draw put the empty state's "Add Folder..." button (below the wrapped text); none before a draw.
    pub(crate) add_folder_rect: std::cell::Cell<Option<CGRect>>,
    /// The host's live picture of the playing video (its slot, the part of it and its pixel size); none = show the poster.
    pub preview_frame: Option<LibraryPicture>,
    /// The host's stills of saved presets by `LibraryPresetCell::preset_key`; a preset without one shows its kind icon.
    pub preset_pictures: HashMap<String, LibraryPicture>,
    /// The panel's size in points.
    pub size: CGSize,
    /// "Whoosh at Selected Cuts" is offered (the host places sounds on cuts).
    pub can_whoosh: bool,
    /// The seconds on the steady clock of the last event.
    pub now: f64,

    cells: Vec<Cell>,
    /// The selected cell keys.
    pub(crate) selected: BTreeSet<String>,
    pub(crate) scroll_body: ScrollBody,
    tile_fraction: f64,
    sidebar: Vec<LibrarySidebarRow>,
    template_tiles: HashMap<String, TextTemplateTile>,
    anchor: Option<usize>,
    dirty: bool,
    seen_version: u64,
    press: Option<(CGPoint, Option<usize>)>,
    /// The rubber band of a drag that started on the grid's empty background.
    pub(crate) marquee: Option<Marquee>,
    /// A drag out of the panel runs.
    pub is_dragging: bool,
    pub(crate) drag_payload: Option<LibraryDragPayload>,
    last_click: Option<(String, f64)>,
    dragging_slider: bool,
    /// The Import... button in the panel's tab strip (panel-local points, so above the panel); set by the host.
    // shortcut: a panel without a host strip has no Import button; every docked or floating Library has one.
    strip_import: Option<CGRect>,
    pub(crate) hover: Option<CGPoint>,
    pub(crate) search: TextFieldControl,
    /// Measured chip widths by title (filled while drawing; see `chip_frames`).
    chip_widths: HashMap<String, f64>,
    events: Vec<LibraryPanelEvent>,
    menu: MenuQueue<MenuCmd>,
}

impl LibraryDrawPanel {
    /// Width of the sidebar before the user drags it.
    pub const SIDEBAR_WIDTH: f64 = 132.0;
    /// Height of the search row.
    pub const SEARCH_ROW_HEIGHT: f64 = 38.0;
    /// Height of a chip row.
    pub const CHIP_ROW_HEIGHT: f64 = 24.0;
    /// The Media | Presets switch row (Media mode; the grid or list follows it).
    pub const MODE_ROW_HEIGHT: f64 = 30.0;
    /// Height of a list row.
    pub const ROW_HEIGHT: f64 = 24.0;
    /// Height of a section header.
    pub const SECTION_HEIGHT: f64 = 24.0;
    /// Padding.
    pub const PAD: f64 = spacing::SM as f64;
    pub(crate) const DRAG_SLOP: f64 = 4.0;
    const DOUBLE_CLICK: f64 = 0.4;
    const SLIDER_WIDTH: f64 = 64.0;
    /// Height of the playing item's position bar on a tile.
    const PROGRESS_HEIGHT: f64 = 3.0;
    /// `Theme.Typography.list`: sidebar rows and preset chips.
    const LIST_FONT: f64 = 11.0;
    /// Space between the search row and the first chip row (Presets mode).
    const CHIPS_INSET: f64 = 8.0;
    /// Space between the search row and the first sidebar row.
    const SIDEBAR_INSET: f64 = spacing::XS as f64;
    /// The settings key of the stored viewer height (same key as the AppKit bar).
    pub const VIEWER_HEIGHT_KEY: &'static str = "sq.library.previewHeight";
    /// The settings key of the stored sidebar width.
    pub const SIDEBAR_WIDTH_KEY: &'static str = "sq.library.sidebarWidth";
    /// The packs switched off in the lists.
    pub const HIDDEN_PACKS_KEY: &'static str = "sq.library.hiddenPacks";

    /// A panel over `model`; `defaults` keeps the tile size and the dividers, `settings` the preset apply mode.
    pub fn new(
        model: LibraryPanelModel,
        defaults: Box<dyn UiDefaults>,
        settings: Box<dyn SettingsStore>,
    ) -> LibraryDrawPanel {
        let mut model = model;
        for name in defaults.string_array(Self::HIDDEN_PACKS_KEY).unwrap_or_default() {
            model.set_pack_hidden(&name, true);
        }
        let tile_fraction = get_double(defaults.as_ref(), LibraryTileGeometry::TILE_SIZE_KEY)
            .unwrap_or(LibraryTileGeometry::DEFAULT_FRACTION);
        let stored_sidebar_width = get_double(defaults.as_ref(), Self::SIDEBAR_WIDTH_KEY);
        let mut search = TextFieldControl::new(model.query());
        search.alignment = Alignment::Left;
        search.font_size = type_size::BODY as f64;
        LibraryDrawPanel {
            model,
            has_focus: false,
            defaults,
            settings,
            stored_sidebar_width,
            bar_drag: None,
            add_folder_rect: std::cell::Cell::new(None),
            preview_frame: None,
            preset_pictures: HashMap::new(),
            size: CGSize::default(),
            can_whoosh: false,
            now: 0.0,
            cells: Vec::new(),
            selected: BTreeSet::new(),
            scroll_body: ScrollBody::new(0.0),
            tile_fraction,
            sidebar: Vec::new(),
            template_tiles: HashMap::new(),
            anchor: None,
            dirty: true,
            seen_version: u64::MAX,
            press: None,
            marquee: None,
            is_dragging: false,
            drag_payload: None,
            last_click: None,
            dragging_slider: false,
            strip_import: None,
            hover: None,
            search,
            chip_widths: HashMap::new(),
            events: Vec::new(),
            menu: MenuQueue::default(),
        }
    }

    /// A press is running (a cell, a divider, the slider or the rubber band): the host keeps the pointer for the panel.
    pub fn is_pressed(&self) -> bool {
        self.press.is_some() || self.bar_drag.is_some() || self.dragging_slider || self.marquee.is_some()
    }

    /// The hooks that fired since the last call, in order.
    pub fn take_events(&mut self) -> Vec<LibraryPanelEvent> {
        std::mem::take(&mut self.events)
    }

    /// The scroll offset; the body adds momentum and the rubber band.
    pub fn scroll(&mut self) -> f64 {
        self.scroll_body.position()
    }
    pub(crate) fn set_scroll(&mut self, v: f64) {
        self.scroll_body.assign(v);
    }
    /// The cells in display order.
    pub fn cells(&self) -> &[Cell] {
        &self.cells
    }
    /// The selected cell keys.
    pub fn selected(&self) -> &BTreeSet<String> {
        &self.selected
    }
    /// The tile slider's value (0...1).
    pub fn tile_fraction(&self) -> f64 {
        self.tile_fraction
    }
    /// The settings store of the dividers and the tile size.
    pub fn defaults(&self) -> &dyn UiDefaults {
        self.defaults.as_ref()
    }
    pub(crate) fn defaults_mut(&mut self) -> &mut dyn UiDefaults {
        self.defaults.as_mut()
    }
    pub(crate) fn push_event(&mut self, e: LibraryPanelEvent) {
        self.events.push(e);
    }

    // MARK: Model refresh

    /// Rebuilds the cells when the model changed (cheap when nothing did); the host calls it before drawing.
    pub fn refresh(&mut self) {
        let v = self.model.version();
        if !self.dirty && v == self.seen_version {
            return;
        }
        self.dirty = false;
        self.seen_version = v;
        self.rebuild();
        // `rebuild` can change the model's version through `item_did_appear` calls of the draw; the next frame re-checks.
    }

    pub(crate) fn rebuild(&mut self) {
        self.sidebar =
            LibrarySidebarRow::rows(self.model.folders(), &self.model.pack_names(), self.model.is_showing_presets());
        if self.model.is_showing_presets() {
            let mut cells: Vec<Cell> = self
                .model
                .visible_text_templates()
                .into_iter()
                .map(|t| Cell::Preset(LibraryPresetCell::Template(t)))
                .collect();
            cells.extend(self.model.visible_presets().into_iter().map(|p| Cell::Preset(LibraryPresetCell::User(p))));
            cells.extend(
                self.model
                    .visible_audio_stacks()
                    .into_iter()
                    .map(|(id, name)| Cell::Preset(LibraryPresetCell::AudioStack(id, name))),
            );
            cells.extend(
                self.model
                    .visible_luts()
                    .into_iter()
                    .map(|e| Cell::Preset(LibraryPresetCell::Lut(e.path.clone(), e.name().to_string()))),
            );
            self.cells = cells;
            self.template_tiles = self.model.template_tiles().into_iter().map(|t| (t.preset_key.clone(), t)).collect();
        } else {
            let sections = self.model.sections();
            if sections.is_empty() {
                self.cells = self.model.items().into_iter().map(Cell::Item).collect();
            } else {
                // An item listed under All and under its subfolder is one cell key: selection marks both copies.
                self.cells = sections
                    .into_iter()
                    .flat_map(|s| {
                        let mut v = vec![Cell::Header(s.group)];
                        v.extend(s.items.into_iter().map(Cell::Item));
                        v
                    })
                    .collect();
            }
        }
        let keys: BTreeSet<String> = self.cells.iter().map(Cell::key).collect();
        self.selected.retain(|k| keys.contains(k));
        let max = self.max_scroll();
        let s = self.scroll();
        self.set_scroll(s.min(max));
    }

    // MARK: Derived state

    /// Cells that are not section headers.
    pub fn content_count(&self) -> usize {
        self.cells.iter().filter(|c| !c.is_header()).count()
    }
    fn trimmed_query(&self) -> String {
        trim_ws(self.model.query()).to_string()
    }
    /// A search without hits fills the panel (board "Library - no hits"): no sidebar, no switch, no chips.
    pub fn is_no_hits(&self) -> bool {
        self.content_count() == 0 && !self.trimmed_query().is_empty()
    }
    pub(crate) fn shows_sidebar(&self) -> bool {
        !self.is_no_hits()
            && !self.model.is_showing_presets()
            && self.size.width - Self::CONTENT_MIN_WIDTH >= sq_library::library_preview_math::MIN_SIDEBAR_WIDTH
    }
    /// The Media | Presets switch and the chip row show (a search without hits fills the panel instead).
    pub(crate) fn shows_header(&self) -> bool {
        !self.is_no_hits()
    }
    /// The preset group chips: Presets mode only. The Media mode lists the files of the selected folder, no kind chips.
    pub(crate) fn shows_chips(&self) -> bool {
        self.shows_header() && self.model.is_showing_presets()
    }

    /// What the empty list says: (title, hint).
    pub fn empty_text(&self) -> (String, String) {
        let mut text = LibraryLabels::empty_text(
            self.model.is_selected_folder_offline(),
            self.model.is_showing_presets(),
            *self.model.selection() == LibrarySection::Favorites,
            !self.model.folders().is_empty(),
            self.model.query(),
        );
        if self.model.is_showing_presets() && self.model.preset_filter_active() && self.trimmed_query().is_empty() {
            text = (
                SQL10n::string("Nothing here"),
                SQL10n::string("No preset matches the current filter. Open the ... menu and choose Show: All."),
            );
        }
        text
    }

    /// v9 "No library folders": the button under the hint adds one.
    pub fn offers_add_folder(&self) -> bool {
        !self.model.is_showing_presets()
            && !self.is_no_hits()
            && !self.model.is_selected_folder_offline()
            && self.model.folders().is_empty()
            && *self.model.selection() != LibrarySection::Favorites
    }

    // MARK: Geometry

    pub(crate) fn content_x(&self) -> f64 {
        if self.shows_sidebar() { self.sidebar_w() } else { 0.0 }
    }
    /// The sidebar sits under the search row, which spans the whole panel (the AppKit panel: field, view switch, slider).
    pub fn sidebar_rect(&self) -> CGRect {
        CGRect::new(
            0.0,
            Self::SEARCH_ROW_HEIGHT,
            if self.shows_sidebar() { self.sidebar_w() } else { 0.0 },
            (self.size.height - Self::SEARCH_ROW_HEIGHT).max(0.0),
        )
    }
    /// The tile size slider (grid only).
    pub fn slider_rect(&self) -> Option<CGRect> {
        (self.model.view_mode() == LibraryViewMode::Grid && !self.model.is_showing_presets())
            .then(|| CGRect::new(self.size.width - Self::PAD - Self::SLIDER_WIDTH, 8.0, Self::SLIDER_WIDTH, 22.0))
    }
    /// The grid / list switch.
    pub fn view_button_rect(&self) -> CGRect {
        let right = self.slider_rect().map_or(self.size.width - Self::PAD, |s| s.min_x() - Self::PAD);
        CGRect::new(right - 22.0 - if self.slider_rect().is_none() { 0.0 } else { 5.0 }, 8.0, 22.0, 22.0)
    }
    /// The search field.
    pub fn search_field_rect(&self) -> CGRect {
        if self.model.is_showing_presets() {
            // Kit (Panel / Library / Presets): switch, star and the field share the first row.
            let x = self.star_rect().max_x() + 6.0;
            return CGRect::new(x, 8.0, (self.size.width - Self::PAD - x).max(0.0), 22.0);
        }
        // Measured against the AppKit panel (2x crop): the field starts 2 pt left of the pad and ends 11 pt before the view switch.
        CGRect::new(Self::PAD - 2.0, 8.0, (self.view_button_rect().min_x() - 11.0 - (Self::PAD - 2.0)).max(0.0), 22.0)
    }
    fn search_clear_rect(&self) -> CGRect {
        let f = self.search_field_rect();
        CGRect::new(f.max_x() - 20.0, f.mid_y() - 8.0, 16.0, 16.0)
    }
    /// The favorites star right of the switch (Presets mode).
    pub fn star_rect(&self) -> CGRect {
        let (_, p) = self.mode_rects();
        CGRect::new(p.max_x() + 6.0, 8.0, 22.0, 22.0)
    }
    /// The separate switch row of the Media mode; in Presets mode the switch sits in the search row.
    fn mode_row_height(&self) -> f64 {
        if self.model.is_showing_presets() { 0.0 } else { Self::MODE_ROW_HEIGHT }
    }
    fn chips_top(&self) -> f64 {
        Self::SEARCH_ROW_HEIGHT + self.mode_row_height()
    }

    /// The two segments of the Media | Presets switch.
    pub fn mode_rects(&self) -> (CGRect, CGRect) {
        let x = self.content_x() + Self::PAD;
        let y = if self.model.is_showing_presets() { 8.0 } else { Self::SEARCH_ROW_HEIGHT + 4.0 };
        // Presets mode shares the row with the star and the search field: the segments are slimmer there.
        let w = if self.model.is_showing_presets() { 56.0 } else { 64.0 };
        (CGRect::new(x, y, w, 22.0), CGRect::new(x + w, y, w, 22.0))
    }

    /// Width the "Import…" button takes in the tab strip.
    pub const IMPORT_WIDTH: f64 = 72.0;
    /// Whether the panel wants its "Import…" button in the tab strip (Presets mode).
    pub fn wants_import(&self) -> bool {
        self.model.is_showing_presets()
    }
    /// The host gives the strip button's frame in panel-local points (none = no strip).
    pub fn set_import_rect(&mut self, r: Option<CGRect>) {
        self.strip_import = r;
    }
    /// Media (false) or Presets (true) from the switch; the other mode's selection stays as it is.
    fn set_mode(&mut self, presets: bool) {
        if presets && !self.model.is_showing_presets() {
            self.model.set_selection(LibrarySection::Presets(None));
        } else if !presets && self.model.is_showing_presets() {
            self.model.set_selection(LibrarySection::All);
        }
    }
    /// The "Import…" button in the tab strip (Presets mode).
    pub fn import_rect(&self) -> Option<CGRect> {
        self.strip_import.filter(|_| self.wants_import())
    }

    /// The preset groups (Text, Captions, Effects, Transitions, Motion, Audio, LUTs); none outside Presets mode.
    fn chip_items(&self) -> Vec<(LibraryChip, String)> {
        if !self.model.is_showing_presets() {
            return Vec::new();
        }
        Self::PRESET_CHIPS
            .iter()
            .map(|(k, title)| (LibraryChip::Preset(*k), SQL10n::string(title)))
            .chain([(LibraryChip::AudioStacks, SQL10n::string("Audio")), (LibraryChip::Luts, SQL10n::string("LUTs"))])
            .collect()
    }

    const PRESET_CHIPS: [(PresetKind, &'static str); 5] = [
        (PresetKind::TextTemplate, "Text"),
        (PresetKind::Caption, "Captions"),
        (PresetKind::Effect, "Effects"),
        (PresetKind::Transition, "Transitions"),
        (PresetKind::Keystone, "Motion"),
    ];
    /// The list's column header (Name / Kind / Size, the AppKit table header); the grid and an empty list have none.
    pub fn list_header_height(&self) -> f64 {
        if self.model.view_mode() == LibraryViewMode::List && self.cells.iter().any(|c| !c.is_header()) {
            Self::ROW_HEIGHT
        } else {
            0.0
        }
    }
    /// The scrolling content.
    pub fn list_rect(&self) -> CGRect {
        let chips = if self.shows_chips() {
            Self::CHIPS_INSET - 3.0 + Self::CHIP_ROW_HEIGHT * self.chip_rows() as f64
        } else {
            0.0
        };
        let top = Self::SEARCH_ROW_HEIGHT
            + if self.shows_header() { self.mode_row_height() } else { 0.0 }
            + chips
            + self.list_header_height();
        CGRect::new(
            self.content_x(),
            top,
            (self.size.width - self.content_x()).max(0.0),
            (self.size.height - top - self.preview_bar_height()).max(0.0),
        )
    }

    /// Chip frames of the preset groups, wrapped onto as many rows as the panel width needs (the AppKit chip bar wraps
    /// the same way). Widths come from the last draw's measure
    /// (`chip_widths`), so layout and hit testing match the drawn chips.
    pub fn chip_frames(&self) -> Vec<(LibraryChip, String, CGRect)> {
        let left = self.content_x() + Self::PAD;
        let right = (self.size.width - Self::PAD).max(left);
        let gap = spacing::XS as f64;
        let (mut x, mut row) = (left, 0usize);
        let mut out = Vec::new();
        for (k, title) in self.chip_items() {
            let estimate = title.chars().count() as f64 * 6.5 + 12.0;
            let w = self.chip_widths.get(&title).copied().unwrap_or(estimate);
            if x > left && x + w > right {
                row += 1;
                x = left;
            }
            out.push((
                k,
                title,
                CGRect::new(x, self.chips_top() + Self::CHIPS_INSET + row as f64 * Self::CHIP_ROW_HEIGHT, w, 20.0),
            ));
            x += w + gap;
        }
        out
    }

    fn measure_chips(&mut self, c: &Canvas) {
        for (_, t) in self.chip_items() {
            let w = c.size_of(&t, Self::LIST_FONT, 0).width + 18.0; // kit chip padding 9 each side
            self.chip_widths.insert(t, w);
        }
    }

    /// Rows the chips take at the current width.
    pub fn chip_rows(&self) -> usize {
        let Some(last) = self.chip_frames().last().map(|f| f.2) else { return 1 };
        ((last.min_y() - self.chips_top() - Self::CHIPS_INSET) / Self::CHIP_ROW_HEIGHT).round() as usize + 1
    }

    /// Cell frames in content coordinates (y from the list top, before scrolling).
    pub fn placed(&self) -> Vec<Placed> {
        let w = self.list_rect().width;
        let mut out = Vec::with_capacity(self.cells.len());
        if self.model.view_mode() == LibraryViewMode::List {
            for i in 0..self.cells.len() {
                out.push(Placed {
                    index: i,
                    frame: CGRect::new(0.0, i as f64 * Self::ROW_HEIGHT, w, Self::ROW_HEIGHT),
                });
            }
            return out;
        }
        let inner = (w - 2.0 * Self::PAD).max(1.0);
        let (columns, tile) = if self.model.is_showing_presets() {
            LibraryTileGeometry::preset_layout(inner)
        } else {
            LibraryTileGeometry::layout(inner, self.tile_fraction)
        };
        let (mut y, mut col) = (Self::PAD, 0i64);
        for (i, cell) in self.cells.iter().enumerate() {
            if cell.is_header() {
                if col > 0 {
                    y += tile.height + LibraryTileGeometry::GAP;
                    col = 0;
                }
                out.push(Placed { index: i, frame: CGRect::new(0.0, y, w, Self::SECTION_HEIGHT) });
                y += Self::SECTION_HEIGHT + spacing::XS as f64;
                continue;
            }
            let x = Self::PAD + col as f64 * (tile.width + LibraryTileGeometry::GAP);
            out.push(Placed { index: i, frame: CGRect::new(x, y, tile.width, tile.height) });
            col += 1;
            if col == columns {
                col = 0;
                y += tile.height + LibraryTileGeometry::GAP;
            }
        }
        out
    }

    fn content_height(&self) -> f64 {
        let last = self
            .placed()
            .into_iter()
            .fold(None::<f64>, |m, p| Some(m.map_or(p.frame.max_y(), |v| v.max(p.frame.max_y()))));
        let hint = if self.shows_pack_hint() { Self::PACK_HINT_HEIGHT } else { 0.0 };
        last.map_or(0.0, |m| m + Self::PAD + hint)
    }
    /// Room under the preset tiles for the pack hint (up to three lines at the narrowest panel).
    const PACK_HINT_HEIGHT: f64 = 66.0;
    const PACK_HINT: &'static str = "Built-in presets come as the pack \u{201C}Sequence Studio\u{201D}. Packs can be switched off in the \u{2022}\u{2022}\u{2022} menu, never deleted by accident.";
    fn shows_pack_hint(&self) -> bool {
        self.model.is_showing_presets() && self.model.view_mode() == LibraryViewMode::Grid && self.content_count() > 0
    }
    pub(crate) fn max_scroll(&self) -> f64 {
        (self.content_height() - self.list_rect().height).max(0.0)
    }

    /// The cell index under a panel-local point.
    pub fn cell_index(&mut self, p: CGPoint) -> Option<usize> {
        let lr = self.list_rect();
        if !lr.contains(p) {
            return None;
        }
        let q = CGPoint::new(p.x - lr.min_x(), p.y - lr.min_y() + self.scroll());
        self.placed().into_iter().find(|pl| pl.frame.contains(q)).map(|pl| pl.index)
    }

    /// The frame of a placed cell in panel coordinates (scrolled).
    pub fn cell_rect(&mut self, placed: &Placed) -> CGRect {
        let lr = self.list_rect();
        let scroll = self.scroll();
        CGRect::new(
            placed.frame.x + lr.min_x(),
            placed.frame.y + lr.min_y() - scroll,
            placed.frame.width,
            placed.frame.height,
        )
    }

    fn sidebar_index(&self, p: CGPoint) -> Option<usize> {
        if !self.sidebar_rect().contains(p) {
            return None;
        }
        let i = ((p.y - self.sidebar_rect().min_y() - Self::SIDEBAR_INSET) / Self::ROW_HEIGHT).floor();
        (i >= 0.0 && (i as usize) < self.sidebar.len()).then_some(i as usize)
    }

    fn sidebar_row_rect(&self, i: usize) -> CGRect {
        CGRect::new(
            0.0,
            self.sidebar_rect().min_y() + Self::SIDEBAR_INSET + i as f64 * Self::ROW_HEIGHT,
            self.sidebar_w(),
            Self::ROW_HEIGHT,
        )
    }

    /// The "Add Folder..." button of the empty state.
    /// It sits under the text block, so it follows the last draw; before one, a guess under the middle.
    pub fn add_folder_button_rect(&self) -> CGRect {
        self.add_folder_rect.get().unwrap_or_else(|| {
            let r = self.list_rect();
            CGRect::new(r.mid_x() - 56.0, r.mid_y() + 26.0, 112.0, 24.0)
        })
    }

    // MARK: Selection helpers

    fn selectable_indices(&self) -> Vec<usize> {
        (0..self.cells.len()).filter(|i| !self.cells[*i].is_header()).collect()
    }

    /// The selected file items, each once.
    pub fn selected_items(&self) -> Vec<LibraryItem> {
        let mut ids: Vec<LibraryEntryID> = Vec::new();
        self.cells
            .iter()
            .filter_map(|c| match c {
                Cell::Item(it) if self.selected.contains(&c.key()) && !ids.contains(&it.id()) => {
                    ids.push(it.id());
                    Some(it.clone())
                }
                _ => None,
            })
            .collect()
    }

    /// The selected saved presets in display order.
    pub fn selected_presets(&self) -> Vec<PresetItem> {
        self.cells
            .iter()
            .filter_map(|c| match c {
                Cell::Preset(LibraryPresetCell::User(p)) if self.selected.contains(&c.key()) => Some(p.clone()),
                _ => None,
            })
            .collect()
    }

    fn select(&mut self, i: usize, m: InputModifiers) {
        let key = self.cells[i].key();
        if m.contains(InputModifiers::SHIFT) && self.anchor.is_some_and(|a| a < self.cells.len()) {
            let a = self.anchor.unwrap_or(i);
            let (lo, hi) = (a.min(i), a.max(i));
            self.selected = (lo..=hi).filter(|j| !self.cells[*j].is_header()).map(|j| self.cells[j].key()).collect();
        } else if m.contains(InputModifiers::COMMAND) {
            if !self.selected.remove(&key) {
                self.selected.insert(key);
            }
            self.anchor = Some(i);
        } else {
            self.selected = BTreeSet::from([key]);
            self.anchor = Some(i);
        }
        self.preview_selection();
    }

    /// Selecting one item previews it (audio and video play at once); several selected items keep the current preview.
    pub(crate) fn preview_selection(&mut self) {
        if self.model.is_showing_presets() {
            return;
        }
        let items = self.selected_items();
        if items.len() == 1 {
            self.model.select_item_for_preview(Some(&items[0]));
        } else if items.is_empty() {
            self.model.select_item_for_preview(None);
        }
    }

    /// A chip of its own section: a second click goes back to all presets.
    fn toggle_chip_section(&mut self, section: LibrarySection) {
        let on = *self.model.selection() == section;
        self.model.set_selection(if on { LibrarySection::Presets(None) } else { section });
    }

    fn choose(&mut self, section: LibrarySection) {
        if *self.model.selection() == section {
            return;
        }
        self.model.set_selection(section);
        self.selected.clear();
        self.anchor = None;
        self.set_scroll(0.0);
        self.model.select_item_for_preview(None);
        self.dirty = true;
    }

    // MARK: Actions

    /// Double-click on a preset row or tile: place the template, insert the title block, apply the effect preset.
    pub fn activate(&mut self, cell: &LibraryPresetCell) {
        match cell {
            LibraryPresetCell::Template(t) => {
                self.model.record_preset_use(&PresetKey::built_in(&t.id));
                self.events.push(LibraryPanelEvent::Request(LibraryRequest::ApplyTextTemplate(t.id.clone())));
            }
            LibraryPresetCell::AudioStack(id, _) => {
                self.model.record_preset_use(&cell.preset_key());
                self.events.push(LibraryPanelEvent::Request(LibraryRequest::ApplyAudioStack(id.clone())));
            }
            LibraryPresetCell::Lut(path, _) => {
                self.model.record_preset_use(&cell.preset_key());
                self.events.push(LibraryPanelEvent::Request(LibraryRequest::ApplyLut(path.clone())));
            }
            LibraryPresetCell::User(p) => {
                if p.kind.is_title_insert() {
                    self.model.record_preset_use(&PresetKey::user(p.id));
                    self.model.insert_title_block(p.clone(), None);
                } else if matches!(p.kind, PresetKind::Effect | PresetKind::Keystone) {
                    self.model.record_preset_use(&PresetKey::user(p.id));
                    self.model.apply_preset(p.clone(), None);
                }
            }
        }
    }

    /// Switches grid and list.
    pub fn set_view_mode(&mut self, mode: LibraryViewMode) {
        self.model.set_view_mode(mode);
        self.set_scroll(0.0);
    }

    /// Sets the tile size (saved).
    pub fn set_tile_fraction(&mut self, f: f64) {
        self.tile_fraction = f.clamp(0.0, 1.0);
        set_double(self.defaults.as_mut(), LibraryTileGeometry::TILE_SIZE_KEY, self.tile_fraction);
        let max = self.max_scroll();
        let s = self.scroll();
        self.set_scroll(s.min(max));
    }

    fn sort_by(&mut self, key: LibrarySortKey) {
        if self.model.sort_key() == key {
            let a = !self.model.ascending();
            self.model.set_ascending(a);
        } else {
            self.model.set_sort_key(key);
            self.model.set_ascending(true);
        }
    }

    // MARK: Menus

    /// Header "..." of the Library panel: as Grid / as List, Add Folder..., then Sort by Name / Date / Size (the current
    /// key flips the direction) or, for presets, sort, Show (scope), Category, Tag and Clear Filters.
    pub fn options_menu(&self) -> Vec<SQMenuItem> {
        let q = &self.menu;
        let checked = |mut i: SQMenuItem, on: bool| {
            i.is_checked = on;
            i
        };
        let mut rows = vec![
            checked(
                q.row("as Grid", MenuCmd::SetViewMode(LibraryViewMode::Grid)),
                self.model.view_mode() == LibraryViewMode::Grid,
            ),
            checked(
                q.row("as List", MenuCmd::SetViewMode(LibraryViewMode::List)),
                self.model.view_mode() == LibraryViewMode::List,
            ),
            SQMenuItem::separator(),
            q.row("Add Folder\u{2026}", MenuCmd::AddFolder),
            SQMenuItem::separator(),
        ];
        let m = &self.model;
        if !m.is_showing_presets() {
            for (key, title) in
                [(LibrarySortKey::Name, "Name"), (LibrarySortKey::Date, "Date"), (LibrarySortKey::Size, "Size")]
            {
                rows.push(checked(q.row(&format!("Sort by {title}"), MenuCmd::SortBy(key)), m.sort_key() == key));
            }
            return rows;
        }
        for key in PresetSortKey::ALL {
            rows.push(checked(
                q.row(&format!("Sort by {}", key.title()), MenuCmd::SortPresets(key)),
                m.preset_sort() == key,
            ));
        }
        rows.push(SQMenuItem::separator());
        let packs = m.pack_names();
        if !packs.is_empty() {
            // Packs are switched off here, never deleted from it.
            let mut sub = SQMenuItem::new("Packs");
            sub.submenu = Some(
                packs
                    .iter()
                    .map(|n| checked(q.row(n, MenuCmd::TogglePack(n.clone())), !m.hidden_packs().contains(n)))
                    .collect(),
            );
            rows.push(sub);
        }
        let mut show = SQMenuItem::new("Show");
        show.submenu = Some(
            PresetScope::ALL
                .iter()
                .map(|s| checked(q.row(s.title(), MenuCmd::Scope(*s)), m.preset_scope() == *s))
                .collect(),
        );
        rows.push(show);
        let counts = m.preset_category_counts();
        let mut cats = vec![checked(q.row("All Categories", MenuCmd::Category(None)), m.preset_category().is_none())];
        for cat in PresetCategory::ALL {
            let n = counts.get(&cat).copied().unwrap_or(0);
            let mut item = checked(
                q.row(&format!("{} ({})", cat.title(), n), MenuCmd::Category(Some(cat))),
                m.preset_category() == Some(cat),
            );
            item.is_enabled = n > 0 || m.preset_category() == Some(cat);
            cats.push(item);
        }
        let mut category = SQMenuItem::new("Category");
        category.submenu = Some(cats);
        rows.push(category);
        let tags = m.preset_tag_counts();
        if !tags.is_empty() {
            let mut items = vec![checked(q.row("All Tags", MenuCmd::Tag(None)), m.preset_tag().is_none())];
            for (tag, n) in tags {
                let on = m.preset_tag() == Some(tag.as_str());
                items.push(checked(q.row(&format!("{tag} ({n})"), MenuCmd::Tag(Some(tag))), on));
            }
            let mut tag_menu = SQMenuItem::new("Tag");
            tag_menu.submenu = Some(items);
            rows.push(tag_menu);
        }
        if m.preset_filter_active() {
            rows.push(SQMenuItem::separator());
            rows.push(q.row("Clear Filters", MenuCmd::ClearFilters));
        }
        rows
    }

    /// The sidebar row menu: Add Folder..., then Rescan / Remove Folder on a watched folder, Export / Import Pack on a pack.
    pub fn sidebar_menu(&self, row: Option<&LibrarySidebarRow>) -> Vec<SQMenuItem> {
        let q = self.menu.clone();
        if let Some(LibrarySection::Pack(name)) = row.and_then(|r| r.section.as_ref()) {
            let name = name.clone();
            let run: Run = Rc::new(move |a| match a {
                Action::ExportPack | Action::ImportPack => q.push(MenuCmd::Pack(a, name.clone())),
                _ => {}
            });
            return LibraryMenus::pack_items(&run);
        }
        let add = self.menu.row("Add Folder\u{2026}", MenuCmd::AddFolder);
        let Some(LibrarySection::Folder(id)) = row.and_then(|r| r.section.as_ref()) else { return vec![add] };
        let id = *id;
        let run: Run = Rc::new(move |a| match a {
            Action::Rescan | Action::RemoveFolder => q.push(MenuCmd::Folder(a, id)),
            _ => {}
        });
        let mut out = vec![add, SQMenuItem::separator()];
        out.extend(LibraryMenus::folder_items(&run));
        out
    }

    /// The menu of a cell (none = empty space): file items or the presets section's rows (`LibraryMenus::item_items`).
    /// Rows capture what was clicked: the actions run after the menu closed.
    pub fn item_menu(&self, index: Option<usize>) -> Vec<SQMenuItem> {
        let cell = index.map(|i| self.cells[i].clone());
        let p: Option<PresetItem> = match &cell {
            Some(Cell::Preset(LibraryPresetCell::User(u))) => Some(u.clone()),
            _ => None,
        };
        let template = match &cell {
            Some(Cell::Preset(LibraryPresetCell::Template(t))) => Some(t.clone()),
            _ => None,
        };
        let entry = p
            .as_ref()
            .map(|p| self.model.entry_for_preset(p))
            .or_else(|| template.as_ref().map(|t| self.model.entry_for_template(t)));
        let items = self.selected_items();
        let audio = items.iter().find(|i| i.entry.kind == LibraryItemKind::Audio).cloned();
        let ctx = Context {
            shows_presets: self.model.is_showing_presets(),
            has_audio: audio.is_some(),
            can_whoosh: self.can_whoosh,
            preset_is_title_block: p.as_ref().is_some_and(|p| p.kind.is_title_insert()),
            preset_is_effect: p.as_ref().is_some_and(|p| p.kind == PresetKind::Effect),
            preset_is_motion: p.as_ref().is_some_and(|p| p.kind == PresetKind::Keystone),
            has_preset: p.is_some(),
            relative_default: PresetApplyModeSetting::load(self.settings.as_ref()) == ApplyMode::Relative,
            organize: entry.as_ref().map(|e| {
                let def = p
                    .as_ref()
                    .map(|p| PresetCategory::default_for(p.kind))
                    .or_else(|| template.as_ref().map(LibraryPanelModel::default_category_of_template))
                    .unwrap_or(PresetCategory::Other);
                Organize {
                    is_favorite: e.meta.is_favorite,
                    category: e.category,
                    default_category: def,
                    tags: e.tags().to_vec(),
                }
            }),
        };
        // Presets in the selection when the click is inside it, else the clicked one.
        let selected_presets = if cell.as_ref().is_some_and(|c| self.selected.contains(&c.key())) {
            self.selected_presets()
        } else {
            p.iter().cloned().collect()
        };
        let key = entry.map(|e| e.key);
        let q = self.menu.clone();
        let run: Run = Rc::new(move |a| {
            q.push(MenuCmd::Item(Box::new(ItemPick {
                action: a,
                items: items.clone(),
                audio: audio.clone(),
                preset: p.clone(),
                selected_presets: selected_presets.clone(),
                key: key.clone(),
            })));
        });
        LibraryMenus::item_items(&ctx, &run)
    }

    /// Applies the menu rows picked since the last call (after the menu closed).
    pub fn pump(&mut self) {
        for cmd in self.menu.drain() {
            match cmd {
                MenuCmd::SetViewMode(m) => self.set_view_mode(m),
                MenuCmd::AddFolder => self.events.push(LibraryPanelEvent::Request(LibraryRequest::AddFolder)),
                MenuCmd::SortBy(k) => self.sort_by(k),
                MenuCmd::SortPresets(k) => self.model.sort_presets(k),
                MenuCmd::Scope(s) => self.model.set_preset_scope(s),
                MenuCmd::TogglePack(name) => {
                    let on = self.model.hidden_packs().contains(&name);
                    self.model.set_pack_hidden(&name, !on);
                    let hidden: Vec<String> = self.model.hidden_packs().iter().cloned().collect();
                    self.defaults.set_string_array(Self::HIDDEN_PACKS_KEY, &hidden);
                }
                MenuCmd::Category(c) => self.model.set_preset_category(c),
                MenuCmd::Tag(t) => self.model.set_preset_tag(t),
                MenuCmd::ClearFilters => self.model.clear_preset_filters(),
                MenuCmd::Folder(Action::Rescan, id) => self.model.rescan(id),
                MenuCmd::Folder(Action::RemoveFolder, id) => self.model.remove_folder(id),
                MenuCmd::Folder(..) => {}
                MenuCmd::Pack(Action::ExportPack, name) => {
                    let ids = self.model.preset_ids_in_pack(&name);
                    self.events
                        .push(LibraryPanelEvent::Request(LibraryRequest::ExportPack { ids, suggested_name: name }));
                }
                MenuCmd::Pack(Action::ImportPack, _) => {
                    self.events.push(LibraryPanelEvent::Request(LibraryRequest::ImportPack));
                }
                MenuCmd::Pack(..) => {}
                MenuCmd::Item(pick) => self.run(*pick),
            }
        }
    }

    fn run(&mut self, pick: ItemPick) {
        let ItemPick { action, items, audio, preset: p, selected_presets, key } = pick;
        match action {
            Action::Rescan | Action::RemoveFolder => {}
            Action::ToggleFavorite => {
                for item in &items {
                    self.model.toggle_favorite(&item.id());
                }
            }
            Action::Whoosh => {
                let Some(item) = audio else { return };
                if self.model.sfx_sounds().contains(&item.url) {
                    self.model.choose_whoosh(&item.url); // the Sequence menu command reuses it
                }
                self.events.push(LibraryPanelEvent::Request(LibraryRequest::Whoosh(item.url)));
            }
            Action::AddToSFX => {
                let urls: Vec<PathBuf> =
                    items.iter().filter(|i| i.entry.kind == LibraryItemKind::Audio).map(|i| i.url.clone()).collect();
                self.model.add_to_sfx_bin(&urls);
                if let Some(f) = self.model.sfx_folder() {
                    self.model.set_selection(LibrarySection::Folder(f.id));
                }
            }
            Action::Reveal => {
                self.events.push(LibraryPanelEvent::Request(LibraryRequest::Reveal(
                    items.iter().map(|i| i.url.clone()).collect(),
                )));
            }
            Action::InsertTitleBlock => {
                if let Some(p) = p.filter(|p| p.kind.is_title_insert()) {
                    self.model.record_preset_use(&PresetKey::user(p.id));
                    self.model.insert_title_block(p, None);
                }
            }
            Action::ApplyPreset | Action::ApplyAbsolute | Action::ApplyRelative => {
                if let Some(p) = p {
                    self.model.record_preset_use(&PresetKey::user(p.id));
                    let mode = match action {
                        Action::ApplyAbsolute => Some(ApplyMode::Absolute),
                        Action::ApplyRelative => Some(ApplyMode::Relative),
                        _ => None,
                    };
                    self.model.apply_preset(p, mode);
                }
            }
            Action::ToggleFavoritePreset => {
                if let Some(k) = key {
                    self.model.toggle_favorite_preset(&k);
                }
            }
            Action::SetCategory(c) => {
                if let Some(k) = key {
                    self.model.set_preset_category_of(&k, c);
                }
            }
            Action::ToggleTag(t) => {
                if let Some(k) = key {
                    self.model.toggle_preset_tag(&k, &t);
                }
            }
            Action::ToggleDefaultApply => {
                let now = PresetApplyModeSetting::load(self.settings.as_ref());
                let next = if now == ApplyMode::Relative { ApplyMode::Absolute } else { ApplyMode::Relative };
                PresetApplyModeSetting::save(next, self.settings.as_mut());
            }
            Action::ExportPack => {
                let packs: BTreeSet<&str> = selected_presets.iter().filter_map(|p| p.pack.as_deref()).collect();
                let name = if packs.len() == 1 {
                    selected_presets.first().and_then(|p| p.pack.clone()).unwrap_or_default()
                } else {
                    String::new()
                };
                self.events.push(LibraryPanelEvent::Request(LibraryRequest::ExportPack {
                    ids: selected_presets.iter().map(|p| p.id).collect(),
                    suggested_name: name,
                }));
            }
            Action::ImportPack => self.events.push(LibraryPanelEvent::Request(LibraryRequest::ImportPack)),
            Action::ExportPreset => {
                if let Some(p) = p {
                    self.events.push(LibraryPanelEvent::Request(LibraryRequest::ExportPreset(p)));
                }
            }
            Action::ImportPresets => self.events.push(LibraryPanelEvent::Request(LibraryRequest::ImportPresets)),
            Action::DeletePreset => {
                if let Some(p) = p {
                    self.events.push(LibraryPanelEvent::Request(LibraryRequest::DeletePreset(p)));
                }
            }
        }
    }

    // MARK: Events (panel-local points)

    /// A press.
    pub fn mouse_down(&mut self, p: CGPoint, m: InputModifiers, now: f64) {
        self.now = now;
        self.refresh();
        self.press = None;
        self.bar_drag = None;
        if self.mouse_down_preview(p, m) {
            return;
        }
        if self.import_rect().is_some_and(|r| r.contains(p)) {
            self.end_search_editing();
            self.events.push(LibraryPanelEvent::Request(LibraryRequest::ImportPack));
            return;
        }
        if let Some(i) = self.sidebar_index(p) {
            self.end_search_editing();
            let row = self.sidebar[i].clone();
            if let Some(s) = row.section.clone() {
                self.choose(s);
            }
            if m.contains(InputModifiers::SECONDARY) {
                let menu = self.sidebar_menu(Some(&row));
                self.events.push(LibraryPanelEvent::Menu(menu, p));
            }
            return;
        }
        if self.sidebar_rect().contains(p) {
            if m.contains(InputModifiers::SECONDARY) {
                let menu = self.sidebar_menu(None);
                self.events.push(LibraryPanelEvent::Menu(menu, p));
            }
            return;
        }
        if p.y < Self::SEARCH_ROW_HEIGHT {
            if self.model.is_showing_presets() {
                let (media, presets) = self.mode_rects();
                if media.contains(p) || presets.contains(p) {
                    self.end_search_editing();
                    self.set_mode(presets.contains(p));
                    return;
                }
                if self.star_rect().contains(p) {
                    self.end_search_editing();
                    let on = self.model.preset_scope() == PresetScope::Favorites;
                    self.model.set_preset_scope(if on { PresetScope::All } else { PresetScope::Favorites });
                    return;
                }
            } else if self.view_button_rect().contains(p) {
                self.end_search_editing();
                let next = if self.model.view_mode() == LibraryViewMode::Grid {
                    LibraryViewMode::List
                } else {
                    LibraryViewMode::Grid
                };
                self.set_view_mode(next);
                return;
            }
            if let Some(s) = self.slider_rect()
                && s.inset_by(-4.0, 0.0).contains(p)
            {
                self.end_search_editing();
                self.dragging_slider = true;
                self.set_slider(p.x);
                return;
            }
            if !self.search_text().is_empty() && self.search_clear_rect().contains(p) {
                self.set_search_text("");
                return;
            }
            if self.search_field_rect().contains(p) {
                self.search.mouse_down(None, 1);
            }
            return;
        }
        self.end_search_editing();
        if self.shows_header() && p.y < self.list_rect().min_y() {
            let (media, presets) = self.mode_rects();
            if media.contains(p) || presets.contains(p) {
                self.set_mode(presets.contains(p));
            }
            for (chip, _, frame) in self.chip_frames() {
                if frame.contains(p) {
                    match chip {
                        LibraryChip::Preset(k) => {
                            let on = *self.model.selection() == LibrarySection::Presets(Some(k));
                            self.model.set_selection(LibrarySection::Presets((!on).then_some(k)));
                        }
                        LibraryChip::AudioStacks => self.toggle_chip_section(LibrarySection::AudioStacks),
                        LibraryChip::Luts => self.toggle_chip_section(LibrarySection::Luts),
                    }
                    return;
                }
            }
            return;
        }
        if self.content_count() == 0 && self.offers_add_folder() && self.add_folder_button_rect().contains(p) {
            self.events.push(LibraryPanelEvent::Request(LibraryRequest::AddFolder));
            return;
        }
        let Some(i) = self.cell_index(p) else {
            if !m.contains(InputModifiers::COMMAND) && !m.contains(InputModifiers::SHIFT) {
                self.selected.clear();
                self.preview_selection();
            }
            self.begin_marquee(p, m);
            if m.contains(InputModifiers::SECONDARY) {
                let menu = if self.model.is_showing_presets() { self.item_menu(None) } else { self.sidebar_menu(None) };
                self.events.push(LibraryPanelEvent::Menu(menu, p));
            }
            return;
        };
        let cell = self.cells[i].clone();
        if let Cell::Header(g) = &cell {
            if m.contains(InputModifiers::SECONDARY) {
                return;
            }
            self.model.toggle_group(&g.id);
            self.dirty = true;
            return;
        }
        if m.contains(InputModifiers::SECONDARY) {
            if !self.selected.contains(&cell.key()) {
                self.select(i, InputModifiers::NONE);
            }
            let menu = self.item_menu(Some(i));
            self.events.push(LibraryPanelEvent::Menu(menu, p));
            return;
        }
        let was_selected = self.selected.contains(&cell.key());
        if !(was_selected && m == InputModifiers::NONE) {
            self.select(i, m);
        }
        self.press = Some((p, Some(i)));
        let t = now;
        let double = self.last_click.as_ref().is_some_and(|l| l.0 == cell.key() && t - l.1 < Self::DOUBLE_CLICK)
            && m == InputModifiers::NONE;
        if double {
            self.last_click = None;
            self.press = None;
            if let Cell::Preset(pc) = &cell {
                self.activate(pc);
            }
        } else {
            self.last_click = Some((cell.key(), t));
        }
    }

    /// The pointer moved with the button down.
    pub fn mouse_dragged(&mut self, p: CGPoint) {
        if self.bar_drag.is_some() {
            self.drag_preview(p);
            return;
        }
        if self.dragging_slider {
            self.set_slider(p.x);
            return;
        }
        if self.marquee.is_some() {
            self.drag_marquee(p);
            return;
        }
        let Some((start, Some(i))) = self.press else { return };
        if !self.is_dragging {
            if dist(p, start) < Self::DRAG_SLOP {
                return;
            }
            self.last_click = None;
            self.drag_payload = self.payload_for(i);
            if self.drag_payload.is_none() {
                self.press = None;
                return;
            }
            self.is_dragging = true;
        }
        if let Some(d) = self.drag_payload.clone() {
            self.events.push(LibraryPanelEvent::Drag(d, DragPhase::Moved, p));
        }
    }

    /// The button went up.
    pub fn mouse_up(&mut self, p: CGPoint) {
        let press = self.press.take();
        let dragging = self.is_dragging;
        let payload = self.drag_payload.take();
        let was_bar = self.bar_drag;
        let was_slider = self.dragging_slider;
        let was_marquee = self.marquee.is_some();
        self.is_dragging = false;
        self.dragging_slider = false;
        self.marquee = None;
        if was_bar.is_some() {
            self.is_dragging = dragging;
            self.drag_payload = payload;
            self.end_preview_drag(p);
            self.is_dragging = false;
            self.drag_payload = None;
            self.bar_drag = None;
            return;
        }
        self.bar_drag = None;
        if was_slider || was_marquee {
            return;
        }
        let Some((_, Some(i))) = press else { return };
        let Some(d) = payload.filter(|_| dragging) else {
            // A plain click inside a multiple selection narrows it to the clicked cell.
            if i < self.cells.len() && self.selected.len() > 1 {
                self.select(i, InputModifiers::NONE);
            }
            return;
        };
        if CGRect::new(0.0, 0.0, self.size.width, self.size.height).contains(p) {
            self.events.push(LibraryPanelEvent::Drag(d, DragPhase::Canceled, p));
            return;
        }
        if let Cell::Preset(pc) = &self.cells[i] {
            let key = pc.preset_key();
            self.model.record_preset_use(&key);
        }
        self.events.push(LibraryPanelEvent::Drag(d, DragPhase::Ended, p));
    }

    /// What dragging cell `i` carries: the selected files (the Mac `dragURLs`), or the template / title / effect preset.
    fn payload_for(&self, i: usize) -> Option<LibraryDragPayload> {
        match &self.cells[i] {
            Cell::Header(_) => None,
            Cell::Item(it) => {
                let ids: Vec<LibraryEntryID> = if self.selected.contains(&self.cells[i].key()) {
                    self.selected_items().iter().map(LibraryItem::id).collect()
                } else {
                    vec![it.id()]
                };
                let urls = self.model.drag_urls(&ids);
                if urls.is_empty() { None } else { Some(LibraryDragPayload::Files(urls)) }
            }
            Cell::Preset(pc) => pc.drag_payload(),
        }
    }

    /// The pointer moved without a button.
    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        self.hover = p;
    }

    fn set_slider(&mut self, x: f64) {
        let Some(r) = self.slider_rect() else { return };
        self.set_tile_fraction((x - r.min_x() - 5.0) / (r.width - 10.0).max(1.0));
    }

    /// The wheel over `p`; true when the list took it.
    pub fn scroll_at(&mut self, p: CGPoint, gesture: Option<ScrollGesture>, dy: f64) -> bool {
        let lr = self.list_rect();
        if !lr.contains(p) {
            return false;
        }
        self.sync_scroll_range();
        let (max, extent) = (self.scroll_body.max_offset, self.scroll_body.extent);
        let now = self.now;
        self.scroll_body.feed(gesture, dy, max, extent, now);
        true
    }

    /// Tells the scroll body how long the list is now (every frame and before a wheel): an offset past the end of shorter
    /// content is pulled back, never kept.
    pub fn sync_scroll_range(&mut self) {
        let (max, extent) = (self.max_scroll(), self.list_rect().height);
        self.scroll_body.set_range(max, extent);
    }

    /// Keys while the panel has focus: typing in the search field, arrows move the selection, Return places or applies
    /// the selected preset, Space plays or pauses the preview, Escape cancels a drag.
    pub fn key(&mut self, k: InputKey, m: InputModifiers, ui: &mut UiCx) -> bool {
        if k == InputKey::Escape
            && self.is_dragging
            && let Some(d) = self.drag_payload.take()
        {
            self.events.push(LibraryPanelEvent::Drag(d, DragPhase::Canceled, CGPoint::ZERO));
            self.press = None;
            self.is_dragging = false;
            return true;
        }
        if self.search.is_editing() {
            if k == InputKey::Escape {
                if self.search_text().is_empty() {
                    self.search.cancel();
                } else {
                    self.set_search_text("");
                    self.search.mouse_down(None, 1);
                }
                return true;
            }
            if k == InputKey::Down {
                self.end_search_editing();
                self.move_selection(1);
                return true;
            }
            let _ = self.search.key(k, m, ui);
            let t = self.search_text();
            self.set_query(&t);
            return true;
        }
        match k {
            InputKey::Up | InputKey::Left => {
                self.move_selection(-1);
                true
            }
            InputKey::Down | InputKey::Right => {
                self.move_selection(1);
                true
            }
            InputKey::Enter => {
                let Some(i) = (0..self.cells.len()).find(|i| self.selected.contains(&self.cells[*i].key())) else {
                    return false;
                };
                let Cell::Preset(pc) = self.cells[i].clone() else { return false };
                self.activate(&pc);
                true
            }
            InputKey::Space => self.handle_play_pause(),
            _ => false,
        }
    }

    fn move_selection(&mut self, d: i64) {
        let order = self.selectable_indices();
        if order.is_empty() {
            return;
        }
        let cur = (0..self.cells.len())
            .find(|i| self.selected.contains(&self.cells[*i].key()))
            .and_then(|i| order.iter().position(|o| *o == i));
        let next = match cur {
            Some(c) => (c as i64 + d).clamp(0, order.len() as i64 - 1) as usize,
            None => {
                if d > 0 {
                    0
                } else {
                    order.len() - 1
                }
            }
        };
        let i = order[next];
        self.select(i, InputModifiers::NONE);
        let Some(pl) = self.placed().into_iter().find(|pl| pl.index == i) else { return };
        let r = self.cell_rect(&pl);
        let lr = self.list_rect();
        if r.min_y() < lr.min_y() {
            let s = self.scroll();
            self.set_scroll(s - (lr.min_y() - r.min_y()));
        }
        if r.max_y() > lr.max_y() {
            let s = self.scroll();
            self.set_scroll(s + (r.max_y() - lr.max_y()));
        }
        let (max, s) = (self.max_scroll(), self.scroll());
        self.set_scroll(s.clamp(0.0, max));
    }

    /// The text in the search field (the open editor's, else the field's).
    pub fn search_text(&self) -> String {
        self.search.editor().map_or_else(|| self.search.text.clone(), |e| e.string())
    }
    /// The search field has the keyboard.
    pub fn is_editing_search(&self) -> bool {
        self.search.is_editing()
    }

    fn set_query(&mut self, q: &str) {
        if self.model.query() == q {
            return;
        }
        self.model.set_query(q);
        self.set_scroll(0.0);
        self.dirty = true;
    }

    /// Sets the search text and applies it.
    pub fn set_search_text(&mut self, s: &str) {
        self.search.cancel();
        self.search.text = s.to_string();
        self.set_query(s);
    }

    /// Commits the search text and closes the field (a menu chord, a press elsewhere).
    pub fn end_search_editing(&mut self) {
        if self.search.is_editing() {
            let _ = self.search.commit();
            self.search.text = self.search_text();
        }
    }

    /// Focus goes to the search field (Cmd+F in the panel).
    pub fn focus_search(&mut self) {
        self.search.mouse_down(None, 1);
    }

    /// The tooltip under the pointer: a sidebar folder's path, a cell's full name.
    pub fn help(&mut self, p: CGPoint) -> Option<String> {
        if let Some(i) = self.sidebar_index(p) {
            if let Some(LibrarySection::Folder(id)) = &self.sidebar[i].section {
                return self.model.folder(*id).map(|f| f.url.to_string_lossy().to_string());
            }
            return None;
        }
        if self.view_button_rect().contains(p) {
            return Some(
                if self.model.view_mode() == LibraryViewMode::Grid { "Show as List" } else { "Show as Grid" }
                    .to_string(),
            );
        }
        if self.slider_rect().is_some_and(|s| s.contains(p)) {
            return Some("Tile Size".to_string());
        }
        if let Some(h) = self.preview_help(p) {
            return Some(h);
        }
        let i = self.cell_index(p)?;
        match &self.cells[i] {
            Cell::Header(_) => None,
            Cell::Item(it) => Some(it.entry.relative_path.clone()),
            Cell::Preset(pc) => Some(pc.name().to_string()),
        }
    }

    /// The cursor over a divider; none elsewhere.
    pub fn cursor(&self, p: CGPoint) -> Option<DrawCursor> {
        self.cursor_at(p)
    }

    // MARK: Drawing

    /// Draws the panel; `picture` answers a file's thumbnail.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, ui: &mut UiCx, picture: PictureFn) {
        self.refresh();
        self.model.preview.tick();
        if self.model.preview.is_playing() {
            ui.request_animation(); // the bar and the time follow the sound
        }
        c.fill(CGRect::new(0.0, 0.0, self.size.width, self.size.height), t.panel());
        if self.shows_sidebar() {
            self.draw_sidebar(c, t);
        }
        if self.shows_chips() {
            self.measure_chips(c); // measure first: `list_rect` follows the chip rows
        }
        self.draw_search_row(c, t, ui);
        if self.shows_header() {
            self.draw_mode_switch(c, t);
        }
        if self.shows_chips() {
            self.draw_chips(c, t);
        }
        if self.list_header_height() > 0.0 {
            self.draw_list_header(c, t);
        }
        c.save_gstate();
        c.clip_to(self.list_rect());
        if self.content_count() == 0 {
            self.draw_empty(c, t);
        } else if self.model.view_mode() == LibraryViewMode::List {
            self.draw_list(c, t, picture);
        } else {
            self.draw_grid(c, t, picture);
        }
        self.draw_marquee(c, t);
        c.restore_gstate();
        self.draw_import(c, t); // in the tab strip, above the panel: outside the list clip
        self.draw_preview_bar(c, t, picture);
    }

    fn draw_sidebar(&self, c: &mut Canvas, t: &DrawTheme) {
        c.fill(
            CGRect::new(
                self.sidebar_w() - 1.0,
                Self::SEARCH_ROW_HEIGHT,
                1.0,
                (self.size.height - Self::SEARCH_ROW_HEIGHT).max(0.0),
            ),
            t.separator(),
        );
        c.save_gstate();
        c.clip_to(self.sidebar_rect());
        for (i, row) in self.sidebar.iter().enumerate() {
            let r = self.sidebar_row_rect(i);
            if r.min_y() >= self.size.height {
                break;
            }
            let is_sel = row.section.is_some() && row.section.as_ref() == Some(self.model.selection());
            let hot = row.section.is_some() && self.hover.is_some_and(|h| r.contains(h));
            c.stone_row_pill(r, is_sel, hot, t);
            // The AppKit sidebar: a folder icon on the group rows only; the items are plain text.
            // NSTableCellView turns its text field white, whatever textColor says
            let ink = if row.is_offline { t.label3() } else { t.label() };
            let text_x = if row.is_group { 32.0 } else { 26.0 };
            if row.is_group {
                c.draw_icon(SQIcon::Folder, CGPoint::new(14.0, r.mid_y() - 6.0), 12.0, t.label3(), None);
            }
            c.draw_text_in(
                &row.title,
                CGRect::new(text_x, r.min_y(), (r.max_x() - text_x - 4.0).max(0.0), r.height),
                Self::LIST_FONT,
                if row.is_group { t.label() } else { ink },
                TextAlign::Left,
                0.0,
                0,
            );
        }
        c.restore_gstate();
    }

    fn draw_search_row(&mut self, c: &mut Canvas, t: &DrawTheme, ui: &mut UiCx) {
        let f = self.search_field_rect();
        // `SQSearchField`: the magnifier at 9, the text from 28 (measured in the AppKit render, as the Marker List field).
        self.search.text_inset = 28.0;
        self.search.quiet = false; // field well (art.html `--well`)
        let editing = self.search.is_editing();
        self.search.draw(c, f, t, editing, ui);
        c.draw_icon(SQIcon::Search, CGPoint::new(f.min_x() + 9.0, f.mid_y() - 6.0), 12.0, t.label3(), None);
        if self.search_text().is_empty() && !editing {
            // The long hint, then "Search"; a field too narrow for either shows none (never `Se...`).
            let long =
                SQL10n::string(if self.model.is_showing_presets() { "Search presets" } else { "Search library" });
            let short = SQL10n::string("Search");
            if let Some(hint) = c.first_that_fits(&[&long, &short], type_size::BODY as f64, 0, f.width - 28.0 - 8.0) {
                // (`draw_text_in` takes the inset off both sides; the rect is 20 pt wider so the room is what was measured.)
                let rect = CGRect::new(f.min_x(), f.min_y(), f.width + 20.0, f.height);
                c.draw_text_in(&hint, rect, type_size::BODY as f64, t.label3(), TextAlign::Left, 28.0, 0);
            }
        } else if !self.search_text().is_empty() {
            let x = self.search_clear_rect();
            c.draw_icon(
                SQIcon::CloseCircleFilled,
                CGPoint::new(x.min_x() + 1.0, x.min_y() + 1.0),
                x.width - 2.0,
                t.label3(),
                None,
            );
        }
        if let Some(s) = self.slider_rect() {
            let track = CGRect::new(s.min_x(), s.mid_y() - 1.0, s.width, 2.0);
            let kx = track.min_x() + 5.0 + self.tile_fraction * (track.width - 10.0); // the knob travels 5 pt in from the ends
            c.stone_slider_track(track, Some((track.min_x(), kx)), Touch::default(), t);
            c.stone_slider_knob(kx, s.mid_y(), false, Touch::default(), t);
        }
        if self.model.is_showing_presets() {
            self.draw_star(c, t);
            return; // grid or list: the "..." menu; tile size: Media only
        }
        let v = self.view_button_rect();
        let hot = self.hover.is_some_and(|h| v.contains(h));
        c.stone_button(v, ButtonKind::Quiet, Touch { hovering: hot, ..Touch::default() }, t);
        let icon = if self.model.view_mode() == LibraryViewMode::Grid { SQIcon::Grid } else { SQIcon::List };
        c.draw_icon(icon, CGPoint::new(v.mid_x() - 6.0, v.mid_y() - 6.0), 12.0, t.label2(), None);
    }

    /// The favorites star: on = only favorite presets show (the same filter as "..." > Show > Favorites).
    fn draw_star(&self, c: &mut Canvas, t: &DrawTheme) {
        let r = self.star_rect();
        let on = self.model.preset_scope() == PresetScope::Favorites;
        let hot = self.hover.is_some_and(|h| r.contains(h));
        if on || hot {
            c.stone_button(r, ButtonKind::Quiet, Touch { hovering: hot, ..Touch::default() }, t);
        }
        let icon = if on { SQIcon::StarFilled } else { SQIcon::Star };
        c.draw_icon(
            icon,
            CGPoint::new(r.mid_x() - 6.0, r.mid_y() - 6.0),
            12.0,
            if on { t.accent() } else { t.label2() },
            None,
        );
    }

    fn draw_mode_switch(&self, c: &mut Canvas, t: &DrawTheme) {
        let (media, presets) = self.mode_rects();
        let track = CGRect::new(media.min_x(), media.min_y(), media.width + presets.width, media.height);
        c.stone_segment_track(track, Touch::default(), t);
        let in_presets = self.model.is_showing_presets();
        for (frame, title, on) in [(media, "Media", !in_presets), (presets, "Presets", in_presets)] {
            let hot = self.hover.is_some_and(|h| frame.contains(h));
            c.stone_segment(frame.inset_by(2.0, 2.0), on, Touch { hovering: hot, ..Touch::default() }, t);
            c.draw_text_in(
                &SQL10n::string(title),
                frame,
                Self::LIST_FONT,
                if on { t.label() } else { t.label3() },
                TextAlign::Center,
                0.0,
                0,
            );
        }
    }

    fn draw_import(&self, c: &mut Canvas, t: &DrawTheme) {
        let Some(b) = self.import_rect() else { return };
        let hot = self.hover.is_some_and(|h| b.contains(h));
        // Kit Panels/Button/Small: a raised 20 pt button.
        c.stone_button(b, ButtonKind::Raised, Touch { hovering: hot, ..Touch::default() }, t);
        c.draw_text_in(&SQL10n::string("Import\u{2026}"), b, Self::LIST_FONT, t.label(), TextAlign::Center, 0.0, 0);
    }

    fn draw_chips(&self, c: &mut Canvas, t: &DrawTheme) {
        for (chip, title, frame) in self.chip_frames() {
            let on = match chip {
                LibraryChip::Preset(k) => *self.model.selection() == LibrarySection::Presets(Some(k)),
                LibraryChip::AudioStacks => *self.model.selection() == LibrarySection::AudioStacks,
                LibraryChip::Luts => *self.model.selection() == LibrarySection::Luts,
            };
            // The active group is a filled chip in the current fill (artifact: level-2 pills).
            let hot = self.hover.is_some_and(|h| frame.contains(h));
            c.stone_filter_chip(frame, on, Touch { hovering: hot, ..Touch::default() }, t);
            c.draw_text_in(
                &title,
                frame,
                Self::LIST_FONT,
                if on { t.label() } else { t.label3() },
                TextAlign::Center,
                0.0,
                0,
            );
        }
    }

    fn draw_empty(&self, c: &mut Canvas, t: &DrawTheme) {
        let text = self.empty_text();
        // The AppKit empty state is centered in the pane under the search row (chips included), 20 pt in from the edges.
        let pane = CGRect::new(
            self.content_x(),
            Self::SEARCH_ROW_HEIGHT,
            (self.size.width - self.content_x()).max(0.0),
            (self.size.height - Self::SEARCH_ROW_HEIGHT).max(0.0),
        );
        let r = pane.inset_by(20.0, 0.0);
        // One quiet line, no art (art.html R7); the add-folder button stays below it when offered.
        // The text block and the button are centered as one group: the button's height and gap are kept free below the text.
        let (button_h, gap) = (24.0, 12.0);
        let reserve = if self.offers_add_folder() { button_h + gap } else { 0.0 };
        let text_bottom = c.draw_empty_state_art(&text.0, &text.1, r, reserve, true, t);
        if self.offers_add_folder() {
            let b = CGRect::new(r.mid_x() - 56.0, text_bottom + gap, 112.0, button_h);
            self.add_folder_rect.set(Some(b));
            let hot = self.hover.is_some_and(|h| b.contains(h));
            c.stone_button(b, ButtonKind::Raised, Touch { hovering: hot, ..Touch::default() }, t);
            c.draw_text_in(
                &SQL10n::string("Add Folder\u{2026}"),
                b,
                type_size::BODY as f64,
                t.label(),
                TextAlign::Center,
                0.0,
                0,
            );
        }
    }

    /// The list's text columns of a cell: Kind, Size, Date (items) or Kind, Date (presets).
    fn columns(&self, cell: &Cell) -> Vec<String> {
        match cell {
            Cell::Header(_) => Vec::new(),
            Cell::Item(it) => vec![
                LibraryLabels::title(it.entry.kind),
                SQByteSize::string(it.entry.size),
                medium_date(it.entry.modified),
            ],
            Cell::Preset(LibraryPresetCell::Template(tpl)) => {
                vec![self.model.entry_for_template(tpl).category.title().to_string(), SQL10n::string("Built-in")]
            }
            Cell::Preset(LibraryPresetCell::AudioStack(..)) => {
                vec![SQL10n::string("Audio"), SQL10n::string("Built-in")]
            }
            Cell::Preset(LibraryPresetCell::Lut(..)) => vec![SQL10n::string("LUT"), SQL10n::string("Library")],
            Cell::Preset(LibraryPresetCell::User(p)) => {
                vec![
                    self.model.entry_for_preset(p).category.title().to_string(),
                    p.pack.clone().unwrap_or_else(|| medium_date(p.created_at)),
                ]
            }
        }
    }

    fn list_col_widths(&self) -> Vec<f64> {
        if self.model.is_showing_presets() { vec![84.0, 92.0] } else { vec![64.0, 64.0, 92.0] }
    }

    /// The AppKit table header: Name, then the text columns, in label3 semibold over a separator.
    fn draw_list_header(&self, c: &mut Canvas, t: &DrawTheme) {
        let lr = self.list_rect();
        let h = self.list_header_height();
        let r = CGRect::new(lr.min_x(), lr.min_y() - h, lr.width, h);
        c.fill(CGRect::new(r.min_x(), r.max_y() - 1.0, r.width, 1.0), t.separator());
        let size = type_size::BODY as f64;
        let semibold = c.semibold();
        c.draw_text_in(
            "Name",
            CGRect::new(r.min_x() + Self::PAD + 4.0, r.min_y(), r.width / 2.0, r.height),
            size,
            t.label3(),
            TextAlign::Left,
            0.0,
            semibold,
        );
        if lr.width <= 300.0 {
            return;
        }
        let mut right = r.max_x() - Self::PAD;
        let titles: Vec<&str> =
            if self.model.is_showing_presets() { vec!["Kind", "Created"] } else { vec!["Kind", "Size", "Created"] };
        for (i, (w, s)) in
            self.list_col_widths().into_iter().zip(titles).enumerate().collect::<Vec<_>>().into_iter().rev()
        {
            c.draw_text_in(
                s,
                CGRect::new(right - w, r.min_y(), w, r.height),
                size,
                t.label3(),
                if i == 0 { TextAlign::Left } else { TextAlign::Right },
                0.0,
                semibold,
            );
            right -= w;
        }
    }

    fn draw_list(&mut self, c: &mut Canvas, t: &DrawTheme, picture: PictureFn) {
        let col_widths = self.list_col_widths();
        let lr = self.list_rect();
        let show_columns = lr.width > 300.0;
        for pl in self.placed() {
            let rr = self.cell_rect(&pl);
            if rr.max_y() < lr.min_y() || rr.min_y() > lr.max_y() {
                continue;
            }
            let cell = self.cells[pl.index].clone();
            if let Cell::Header(g) = &cell {
                self.draw_section_header(c, t, g, rr);
                continue;
            }
            let hot = self.hover.is_some_and(|h| rr.contains(h));
            let pill = c.stone_row_pill(rr, self.selected.contains(&cell.key()), hot, t);
            let x = rr.min_x() + Self::PAD + 4.0;
            let (symbol, name, fav) = self.label(&cell);
            let thumb = CGRect::new(x, rr.mid_y() - 5.0, 16.0, 10.0);
            if self.draw_cell_picture(c, t, &cell, thumb, picture).is_none() {
                c.draw_icon(symbol, CGPoint::new(x, rr.mid_y() - 6.0), 12.0, t.label3(), None);
            }
            let mut right = rr.max_x() - Self::PAD;
            if show_columns {
                let texts = self.columns(&cell);
                for (i, (w, s)) in col_widths.iter().zip(texts.iter()).enumerate().collect::<Vec<_>>().into_iter().rev()
                {
                    c.draw_text_in(
                        s,
                        CGRect::new(right - w, rr.min_y(), *w, rr.height),
                        Self::LIST_FONT,
                        t.label3(),
                        if i == 0 { TextAlign::Left } else { TextAlign::Right },
                        0.0,
                        0,
                    );
                    right -= w;
                }
            }
            if fav {
                c.draw_icon(SQIcon::Star, CGPoint::new(right - 14.0, rr.mid_y() - 5.0), 10.0, t.accent(), None);
                right -= 16.0;
            }
            c.draw_text_in(
                &name,
                CGRect::new(x + 18.0, rr.min_y(), (right - x - 22.0).max(0.0), rr.height),
                Self::LIST_FONT,
                t.label(),
                TextAlign::Left,
                0.0,
                0,
            );
            self.draw_progress(c, t, &cell, CGRect::new(pill.min_x(), pill.max_y() - 2.0, pill.width, 2.0));
        }
    }

    fn label(&self, cell: &Cell) -> (SQIcon, String, bool) {
        match cell {
            Cell::Header(g) => (SQIcon::Folder, g.title.clone(), false),
            Cell::Item(it) => (LibraryLabels::symbol(it.entry.kind), it.entry.name().to_string(), it.is_favorite),
            Cell::Preset(pc) => {
                let fav = match pc {
                    LibraryPresetCell::Template(tpl) => self.model.entry_for_template(tpl).meta.is_favorite,
                    LibraryPresetCell::User(p) => self.model.entry_for_preset(p).meta.is_favorite,
                    LibraryPresetCell::AudioStack(..) | LibraryPresetCell::Lut(..) => false,
                };
                (pc.symbol(), pc.name().to_string(), fav)
            }
        }
    }

    fn draw_section_header(&self, c: &mut Canvas, t: &DrawTheme, g: &LibraryGroup, rr: CGRect) {
        let x = rr.min_x() + Self::PAD + g.depth.min(3) as f64 * 14.0;
        let mid = CGPoint::new(x + 5.0, rr.mid_y());
        let pts = if g.is_collapsed {
            [
                CGPoint::new(mid.x - 1.5, mid.y - 3.0),
                CGPoint::new(mid.x + 1.5, mid.y),
                CGPoint::new(mid.x - 1.5, mid.y + 3.0),
            ]
        } else {
            [
                CGPoint::new(mid.x - 3.0, mid.y - 1.5),
                CGPoint::new(mid.x, mid.y + 1.5),
                CGPoint::new(mid.x + 3.0, mid.y - 1.5),
            ]
        };
        c.stroke_polyline(&pts, 1.2, t.label2());
        let count = g.total_count.to_string();
        let cw = c.size_of(&count, 10.0, 0).width;
        // The AppKit header: the title in label, the count right after it (Spacing.sm), not at the edge.
        let avail = (rr.max_x() - x - 22.0 - cw - spacing::SM as f64 - Self::PAD).max(0.0);
        let tw = c.size_of(&g.title, type_size::BODY as f64, 0).width.min(avail);
        c.draw_text_in(
            &g.title,
            CGRect::new(x + 14.0, rr.min_y(), avail, rr.height),
            type_size::BODY as f64,
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );
        c.draw_text(
            &count,
            CGPoint::new(x + 14.0 + tw + spacing::SM as f64, rr.mid_y() - 6.0),
            10.0,
            t.label3(),
            f64::INFINITY,
            0,
        );
    }

    /// The preview's position of the playing item, drawn flush on the bottom edge `r` of its picture (known limit: no
    /// transport drawn).
    /// True when it drew.
    fn draw_progress(&self, c: &mut Canvas, t: &DrawTheme, cell: &Cell, r: CGRect) -> bool {
        let Cell::Item(it) = cell else { return false };
        if self.model.preview_item().map(LibraryItem::id) != Some(it.id()) || self.model.preview.duration() <= 0.0 {
            return false;
        }
        c.fill(r, t.fill());
        c.fill(CGRect::new(r.min_x(), r.min_y(), r.width * self.model.preview.fraction(), r.height), t.accent());
        true
    }

    /// The picture of a file (the host's poster) or of a saved preset (its still) fitted into `rect` at its own aspect,
    /// with the viewer color in the bars around it. Returns the rect the picture got; none when there is no picture.
    fn draw_cell_picture(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        cell: &Cell,
        rect: CGRect,
        picture: PictureFn,
    ) -> Option<CGRect> {
        let p = match cell {
            Cell::Item(it) => picture(it, rect),
            Cell::Preset(pc) => self.preset_pictures.get(&pc.preset_key()).copied(),
            Cell::Header(_) => None,
        }?;
        c.fill(rect, t.viewer());
        Some(c.draw_image_fit(p.slot, rect, p.source, p.size, Color::WHITE, None))
    }

    fn draw_grid(&mut self, c: &mut Canvas, t: &DrawTheme, picture: PictureFn) {
        let r = radius::CONTROL as f64;
        let lr = self.list_rect();
        for pl in self.placed() {
            let f = self.cell_rect(&pl);
            if f.max_y() < lr.min_y() || f.min_y() > lr.max_y() {
                continue;
            }
            let cell = self.cells[pl.index].clone();
            if let Cell::Header(g) = &cell {
                self.draw_section_header(c, t, g, f);
                continue;
            }
            let preset_tile = self.model.is_showing_presets();
            let thumb_h = if preset_tile {
                LibraryTileGeometry::preset_thumb_height(f.width)
            } else {
                (f.width * LibraryTileGeometry::ASPECT).round()
            };
            let thumb = CGRect::new(f.min_x(), f.min_y(), f.width, thumb_h);
            if preset_tile {
                // Kit: a flat card, the preview on top, the caption on a slightly deeper band.
                c.fill_rounded(f, r, t.content());
                c.fill_rounded(CGRect::new(f.min_x(), thumb.max_y(), f.width, f.height - thumb_h), r, t.lane());
            } else {
                c.fill_rounded(thumb, r, t.content());
            }
            let (symbol, name, fav) = self.label(&cell);
            let shown = self.draw_cell_picture(c, t, &cell, thumb, picture);
            // The position of the playing item sits flush on the bottom edge of its picture (of the tile without one),
            // never in the bars or floating above the edge.
            let base = shown.unwrap_or(thumb);
            let bar = Self::PROGRESS_HEIGHT;
            let playing =
                self.draw_progress(c, t, &cell, CGRect::new(base.min_x(), base.max_y() - bar, base.width, bar));
            if shown.is_some() || playing {
                // Picture and bar are square-cornered: give the rounded tile its corners back. A preset card keeps
                // square corners where the thumbnail meets its caption band.
                c.save_gstate();
                c.clip_to(thumb);
                let below = if preset_tile { r } else { 0.0 };
                c.round_picture_corners(CGRect::new(thumb.x, thumb.y, thumb.width, thumb.height + below), r, t.panel());
                c.restore_gstate();
            }
            let mut drew_picture = shown.is_some();
            if !drew_picture
                && let Cell::Preset(pc) = &cell
                && let Some(tile) = self.template_tiles.get(&pc.preset_key())
            {
                self.draw_template_sample(c, t, tile, thumb);
                drew_picture = true;
            }
            if !drew_picture {
                let s = 22.0;
                c.draw_icon(
                    symbol,
                    CGPoint::new(thumb.mid_x() - s / 2.0, thumb.mid_y() - s / 2.0),
                    s,
                    t.label3(),
                    None,
                );
            }
            if fav {
                c.draw_icon(
                    SQIcon::Star,
                    CGPoint::new(thumb.max_x() - 16.0, thumb.min_y() + 4.0),
                    12.0,
                    t.accent(),
                    None,
                );
            }
            if self.selected.contains(&cell.key()) {
                c.stroke_rounded(if preset_tile { f } else { thumb }.inset_by(1.0, 1.0), r, 2.0, t.accent());
            }
            // Kit: name, then the kind at the left and the pack in small capitals at the right (APP-AENDERUNGEN P12).
            if let Cell::Preset(pc) = &cell {
                let x = f.min_x() + 8.0;
                let w = (f.width - 16.0).max(0.0);
                let kind = self.columns(&cell).into_iter().next().unwrap_or_default();
                let pack = Self::pack_label(pc).to_uppercase();
                let pack_w = c.size_of(&pack, 9.0, 0).width.ceil().min(w * 0.7);
                let y = thumb.max_y() + LibraryTileGeometry::PRESET_NAME_GAP;
                c.draw_text_in(
                    &c.ellipsized(&name, type_size::BODY as f64, 0, w),
                    CGRect::new(x, y, w, LibraryTileGeometry::NAME_HEIGHT),
                    type_size::BODY as f64,
                    t.label(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
                let meta_y = y + LibraryTileGeometry::NAME_HEIGHT + 1.0;
                c.draw_text_in(
                    &c.ellipsized(&kind, 11.0, 0, (w - pack_w - 6.0).max(0.0)),
                    CGRect::new(x, meta_y, w, LibraryTileGeometry::PACK_LINE),
                    11.0,
                    t.label3(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
                c.draw_text_in(
                    &c.ellipsized(&pack, 9.0, 0, pack_w),
                    CGRect::new(x + w - pack_w, meta_y, pack_w, LibraryTileGeometry::PACK_LINE),
                    9.0,
                    t.label3(),
                    TextAlign::Right,
                    0.0,
                    0,
                );
                continue;
            }
            c.draw_text_in(
                &name,
                CGRect::new(
                    f.min_x(),
                    thumb.max_y() + LibraryTileGeometry::NAME_GAP,
                    f.width,
                    LibraryTileGeometry::NAME_HEIGHT,
                ),
                type_size::BODY as f64,
                t.label2(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
        if self.shows_pack_hint() {
            self.draw_pack_hint(c, t);
        }
    }

    fn draw_pack_hint(&mut self, c: &mut Canvas, t: &DrawTheme) {
        let Some(last) = self.placed().into_iter().last() else { return };
        let f = self.cell_rect(&last);
        let r = CGRect::new(
            Self::PAD + 4.0,
            f.max_y() + 12.0,
            (self.list_rect().width - 2.0 * Self::PAD - 8.0).max(0.0),
            50.0,
        );
        c.draw_wrapped(&SQL10n::string(Self::PACK_HINT), r, 11.0, 16.0, t.label3());
    }

    /// The pack a preset belongs to: the built-in ones come as "Sequence Studio", a saved one as its pack or "Mine".
    fn pack_label(pc: &LibraryPresetCell) -> String {
        match pc {
            LibraryPresetCell::User(p) => p.pack.clone().unwrap_or_else(|| "Mine".to_string()),
            _ => "Sequence Studio".to_string(),
        }
    }

    /// A template tile's sample in its own font and color (`TextTemplatesTabDraw.drawTile`).
    fn draw_template_sample(&self, c: &mut Canvas, t: &DrawTheme, tile: &TextTemplateTile, well: CGRect) {
        let text = if tile.sample_text.chars().count() <= 12
            && !tile.sample_text.contains('\n')
            && !tile.sample_text.is_empty()
        {
            tile.sample_text.as_str()
        } else {
            "Text"
        };
        c.save_gstate();
        c.clip_to(well);
        if let Some(st) = &tile.style {
            let face = c.face_family(&st.font_name, st.weight, st.italic);
            let col = st.color;
            let ink = if col.alpha > 0.05 {
                Color::new(col.red as f32, col.green as f32, col.blue as f32, col.alpha as f32)
            } else {
                t.label2()
            };
            c.draw_text_in(text, well.inset_by(4.0, 0.0), type_size::TITLE as f64, ink, TextAlign::Center, 0.0, face);
        } else {
            c.draw_text_in(
                text,
                well.inset_by(4.0, 0.0),
                type_size::TITLE as f64,
                t.label2(),
                TextAlign::Center,
                0.0,
                0,
            );
        }
        c.restore_gstate();
    }
}

/// A stored number (the settings store keeps text).
pub(crate) fn get_double(d: &dyn UiDefaults, key: &str) -> Option<f64> {
    d.string(key).and_then(|s| s.parse().ok())
}

/// Stores a number as text.
pub(crate) fn set_double(d: &mut dyn UiDefaults, key: &str, v: f64) {
    d.set_string(key, &v.to_string());
}

/// `DateFormatter` medium date in the user's zone and the interface language's order.
fn medium_date(t: Timestamp) -> String {
    sq_uikit::local_format::medium_date(t)
}
