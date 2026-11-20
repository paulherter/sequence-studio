// Swift: EffectsDrawPanel.swift
//! The Effects panel on the shared draw-list toolkit.

use crate::effects::effect_folder_model::{EffectFolderOutline, EffectFolderStore, Navigation, OutlineKey};
use crate::effects::effects_catalog::{EffectsCatalog, EffectsEntry, EffectsRow};
use crate::effects::effects_grid_model::{EffectsGridLayout, EffectsViewMode};
use crate::effects::effects_tile_atlas::{EffectsTileAtlas, EffectsTilePicture};
use crate::empty_state::{EmptyPane, draw_empty_pane};
use crate::geom::{dist, offset_by, trim_ws};
use crate::menu_queue::MenuQueue;
use sq_app_shell::HostCx;
use sq_core_time::{Id, IdSource};
use sq_draw::scroll::{ScrollBody, ScrollGesture};
use sq_draw::theme::{radius, spacing};
use sq_draw::{
    Alignment, Canvas, Color, DrawTheme, InputEvent, InputKey, InputModifiers, TextAlign, TextFieldControl, UiCx,
};
use sq_editor_session::EditorSession;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

/// Where a drag out of the panel is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DragPhase {
    /// The pointer moved.
    Moved,
    /// Released.
    Ended,
    /// Dropped back or escaped.
    Canceled,
}

/// What the panel asks of its host (the Swift hooks `onApply`, `onMenu`, `askName`, `onDrag`).
#[derive(Clone, Debug)]
pub enum EffectsEvent {
    /// Double-click or Return on an item: the effect, transition or preset id (`EffectsRow.itemID`).
    Apply(String),
    /// A menu at a panel-local point.
    Menu(Vec<SQMenuItem>, CGPoint),
    /// Asks for a folder name; the answer goes to `answer_name` with the same `purpose`.
    AskName {
        /// Dialog title.
        title: String,
        /// Initial text.
        initial: String,
        /// What the name is for.
        purpose: NamePurpose,
    },
    /// A drag of effect ids out of the panel; the point is panel-local (the host turns it into window pixels).
    Drag(Vec<String>, DragPhase, CGPoint),
}

/// What an asked folder name is for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NamePurpose {
    /// A new folder, with an item to put in it.
    NewFolder(Option<String>),
    /// A rename.
    Rename(Id),
}

#[derive(Clone)]
enum MenuCmd {
    AskNewFolder(Option<String>),
    AskRename(Id),
    DeleteFolder(Id),
    AddItem(String, Id),
    RemoveItem(String, Id),
    SetViewMode(EffectsViewMode),
}

/// The Effects panel on the shared draw-list toolkit: the same catalog (`EffectsCatalog`), folder outline
/// (`EffectFolderOutline`, the user's folders from `EffectFolderStore`, the saved open state), search with the effects'
/// other names, list or grid (`EffectsViewMode`, the Mac key), the "fx" badge, the right-click folder menu, a drop of an
/// item onto a user folder, user folder reordering, and a drag of an effect or transition out of the panel (the host
/// routes it onto the timeline). Coordinates are panel-local points.
/// Grid tiles show the host's still (`EffectsTileAtlas`), the icon until it is made.
pub struct EffectsDrawPanel {
    /// The panel's size in points.
    pub size: CGSize,
    defaults: Box<dyn UiDefaults>,
    ids: Box<dyn IdSource>,
    preset_entries: Vec<EffectsEntry>,
    folder_store: EffectFolderStore,
    expanded: std::collections::BTreeSet<String>,
    query: String,
    /// While searching every matching folder is open; these are the ones the user closed again.
    collapsed_in_search: std::collections::BTreeSet<String>,
    rows: Vec<EffectsRow>,
    view_mode: EffectsViewMode,
    selected_id: Option<String>,
    scroll_body: ScrollBody,
    search: TextFieldControl,
    events: Vec<EffectsEvent>,
    menu: MenuQueue<MenuCmd>,
    press: Option<(CGPoint, Option<EffectsRow>)>,
    /// A drag runs.
    pub is_dragging: bool,
    last_click: Option<(String, f64)>,
    /// The row under the pointer while an item or folder is dragged inside the panel (drop target highlight).
    pub drop_row: Option<usize>,
    /// The pointer over the panel (panel coordinates), for the row hover pill.
    pub hover: Option<CGPoint>,
    /// The seconds on the steady clock of the last event (the double-click test, the scroll body).
    pub now: f64,
}

impl EffectsDrawPanel {
    /// Height of the search row.
    pub const SEARCH_ROW_HEIGHT: f64 = 38.0;
    /// The hint under the list (two lines of 11 pt).
    pub const FOOTER_HEIGHT: f64 = 40.0;
    /// What the footer says.
    pub const FOOTER_HINT: &'static str = "Drag an effect onto a clip, or select a clip and double-click the effect.";
    /// Height of a list row.
    pub const ROW_HEIGHT: f64 = 28.0;
    /// Indent per folder level.
    pub const INDENT: f64 = 14.0;
    /// Width of a grid tile.
    pub const TILE_WIDTH: f64 = 104.0;
    const DRAG_SLOP: f64 = 4.0;
    const DOUBLE_CLICK: f64 = 0.4;

    /// A panel over `defaults` (the saved folders, open state and view mode); `ids` names new folders.
    pub fn new(defaults: Box<dyn UiDefaults>, ids: Box<dyn IdSource>) -> EffectsDrawPanel {
        let folder_store = EffectFolderStore::load(defaults.as_ref());
        let open = EffectFolderOutline::load_expanded(defaults.as_ref());
        let view_mode = EffectsViewMode::load(defaults.as_ref());
        let mut search = TextFieldControl::new("");
        search.alignment = Alignment::Left;
        let mut p = EffectsDrawPanel {
            size: CGSize::default(),
            defaults,
            ids,
            preset_entries: Vec::new(),
            folder_store,
            expanded: open,
            query: String::new(),
            collapsed_in_search: Default::default(),
            rows: Vec::new(),
            view_mode,
            selected_id: None,
            scroll_body: ScrollBody::new(0.0),
            search,
            events: Vec::new(),
            menu: MenuQueue::default(),
            press: None,
            is_dragging: false,
            last_click: None,
            drop_row: None,
            hover: None,
            now: 0.0,
        };
        p.rebuild();
        p
    }

    /// The hooks that fired since the last call, in order.
    pub fn take_events(&mut self) -> Vec<EffectsEvent> {
        std::mem::take(&mut self.events)
    }

    /// Saved presets of the Library listed under "Presets" (`EffectsCatalog::preset_entries`).
    pub fn set_preset_entries(&mut self, entries: Vec<EffectsEntry>) {
        self.preset_entries = entries;
        self.rebuild();
    }

    /// The user's folders.
    pub fn folder_store(&self) -> &EffectFolderStore {
        &self.folder_store
    }
    /// The open folders.
    pub fn expanded(&self) -> &std::collections::BTreeSet<String> {
        &self.expanded
    }
    /// The search text applied to the rows.
    pub fn query(&self) -> &str {
        &self.query
    }
    /// The rows of the outline.
    pub fn rows(&self) -> &[EffectsRow] {
        &self.rows
    }
    /// List or grid.
    pub fn view_mode(&self) -> EffectsViewMode {
        self.view_mode
    }
    /// The selected row id.
    pub fn selected_id(&self) -> Option<&str> {
        self.selected_id.as_deref()
    }
    /// The scroll offset; the body adds momentum and the rubber band.
    pub fn scroll(&mut self) -> f64 {
        self.scroll_body.position()
    }
    fn set_scroll(&mut self, v: f64) {
        self.scroll_body.assign(v);
    }

    /// Every entry the panel can list.
    pub fn all_entries(&self) -> Vec<EffectsEntry> {
        let mut all = EffectsCatalog::catalog();
        all.extend(EffectsCatalog::built_in_preset_entries());
        all.extend(self.preset_entries.iter().cloned());
        all
    }

    fn rebuild(&mut self) {
        self.rows = EffectFolderOutline::rows(
            &self.all_entries(),
            &self.folder_store,
            &self.expanded,
            &self.query,
            &self.collapsed_in_search,
        );
    }

    fn save_folders(&mut self) {
        self.folder_store.save(self.defaults.as_mut());
        self.rebuild();
    }

    // MARK: Model actions (the Mac panel's closures)

    /// Applies a search text; a new search opens all matches again and scrolls to the top.
    pub fn set_query(&mut self, q: &str) {
        if q == self.query {
            return;
        }
        self.query = q.to_string();
        self.collapsed_in_search.clear();
        self.set_scroll(0.0);
        self.rebuild();
    }

    /// Opens or closes a folder row.
    pub fn toggle_folder(&mut self, id: &str) {
        if !trim_ws(&self.query).is_empty() {
            // Search results are forced open; the arrow closes one for this search only (not saved).
            if !self.collapsed_in_search.remove(id) {
                self.collapsed_in_search.insert(id.to_string());
            }
        } else {
            if !self.expanded.remove(id) {
                self.expanded.insert(id.to_string());
            }
            EffectFolderOutline::save_expanded(&self.expanded, self.defaults.as_mut());
        }
        self.rebuild();
    }

    /// Switches list and grid (saved).
    pub fn set_view_mode(&mut self, mode: EffectsViewMode) {
        if mode == self.view_mode {
            return;
        }
        self.view_mode = mode;
        mode.save(self.defaults.as_mut());
        self.set_scroll(0.0);
    }

    /// Makes a user folder (optionally holding `item`) and opens it.
    pub fn new_folder(&mut self, name: &str, adding: Option<&str>) {
        let id = self.folder_store.create_folder(name, self.ids.as_mut());
        if let Some(item) = adding {
            self.folder_store.add(item, id);
        }
        self.expanded.insert(EffectFolderOutline::user_id(id));
        EffectFolderOutline::save_expanded(&self.expanded, self.defaults.as_mut());
        self.save_folders();
    }

    /// Renames a user folder.
    pub fn rename_folder(&mut self, id: Id, name: &str) {
        self.folder_store.rename(id, name);
        self.save_folders();
    }
    /// Deletes a user folder.
    pub fn delete_folder(&mut self, id: Id) {
        self.folder_store.delete(id);
        self.save_folders();
    }
    /// Takes an item out of a user folder.
    pub fn remove_item(&mut self, item: &str, folder: Id) {
        self.folder_store.remove(item, folder);
        self.save_folders();
    }

    /// Puts an item in a user folder and opens the folder.
    pub fn add_item(&mut self, item: &str, folder: Id) {
        self.folder_store.add(item, folder);
        self.expanded.insert(EffectFolderOutline::user_id(folder));
        EffectFolderOutline::save_expanded(&self.expanded, self.defaults.as_mut());
        self.save_folders();
    }

    /// Moves a user folder in front of `target` (none = last).
    pub fn move_folder(&mut self, id: Id, target: Option<Id>) {
        self.folder_store.move_folder(id, target);
        self.save_folders();
    }

    /// The host's answer to an `AskName` event (none = canceled).
    pub fn answer_name(&mut self, purpose: &NamePurpose, name: Option<&str>) {
        let Some(name) = name else { return };
        match purpose {
            NamePurpose::NewFolder(adding) => self.new_folder(name, adding.as_deref()),
            NamePurpose::Rename(id) => self.rename_folder(*id, name),
        }
    }

    fn ask_new_folder(&mut self, adding: Option<String>) {
        self.events.push(EffectsEvent::AskName {
            title: "New Folder".into(),
            initial: "New Folder".into(),
            purpose: NamePurpose::NewFolder(adding),
        });
    }

    /// Applies the menu rows picked since the last call (after the menu closed).
    pub fn pump(&mut self) {
        for cmd in self.menu.drain() {
            match cmd {
                MenuCmd::AskNewFolder(adding) => self.ask_new_folder(adding),
                MenuCmd::AskRename(f) => {
                    let initial = self.folder_store.folder(f).map(|x| x.name.clone()).unwrap_or_default();
                    self.events.push(EffectsEvent::AskName {
                        title: "Rename Folder".into(),
                        initial,
                        purpose: NamePurpose::Rename(f),
                    });
                }
                MenuCmd::DeleteFolder(f) => self.delete_folder(f),
                MenuCmd::AddItem(item, f) => self.add_item(&item, f),
                MenuCmd::RemoveItem(item, f) => self.remove_item(&item, f),
                MenuCmd::SetViewMode(m) => self.set_view_mode(m),
            }
        }
    }

    /// The right-click menu of a row (none = empty space): the Mac `menuItems(forRow:)`.
    pub fn menu_for(&self, row: Option<&EffectsRow>) -> Vec<SQMenuItem> {
        let q = &self.menu;
        let mut out = vec![q.row("New Folder\u{2026}", MenuCmd::AskNewFolder(None))];
        let Some(r) = row else { return out };
        if r.is_folder {
            if let Some(f) = r.user_folder {
                out.push(q.row("Rename Folder\u{2026}", MenuCmd::AskRename(f)));
                out.push(SQMenuItem::separator());
                out.push(q.row("Delete Folder", MenuCmd::DeleteFolder(f)));
            }
        } else if !r.is_header {
            let mut sub: Vec<SQMenuItem> = Vec::new();
            for f in self.folder_store.folders() {
                sub.push(q.row(&f.name, MenuCmd::AddItem(r.item_id().to_string(), f.id)));
            }
            if !self.folder_store.folders().is_empty() {
                sub.push(SQMenuItem::separator());
            }
            sub.push(q.row("New Folder\u{2026}", MenuCmd::AskNewFolder(Some(r.item_id().to_string()))));
            let mut add = SQMenuItem::new("Add to Folder");
            add.submenu = Some(sub);
            out.insert(0, add);
            if let Some(f) = r.user_folder {
                out.push(SQMenuItem::separator());
                out.push(q.row("Remove from Folder", MenuCmd::RemoveItem(r.item_id().to_string(), f)));
            }
        }
        out
    }

    /// The panel header's "..." menu: as List / as Grid.
    pub fn options_menu(&self) -> Vec<SQMenuItem> {
        let mut list = self.menu.row("as List", MenuCmd::SetViewMode(EffectsViewMode::List));
        list.is_checked = self.view_mode == EffectsViewMode::List;
        let mut grid = self.menu.row("as Grid", MenuCmd::SetViewMode(EffectsViewMode::Grid));
        grid.is_checked = self.view_mode == EffectsViewMode::Grid;
        vec![list, grid]
    }

    // MARK: Geometry

    fn search_field_rect(&self) -> CGRect {
        CGRect::new(
            spacing::SM as f64,
            7.0,
            (self.size.width - 2.0 * spacing::SM as f64).max(0.0),
            Self::SEARCH_ROW_HEIGHT - 14.0,
        )
    }
    fn search_clear_rect(&self) -> CGRect {
        let f = self.search_field_rect();
        CGRect::new(f.max_x() - 20.0, f.mid_y() - 8.0, 16.0, 16.0)
    }
    fn list_rect(&self) -> CGRect {
        CGRect::new(
            0.0,
            Self::SEARCH_ROW_HEIGHT,
            self.size.width,
            (self.size.height - Self::SEARCH_ROW_HEIGHT - Self::FOOTER_HEIGHT).max(0.0),
        )
    }

    /// The rect of row `i` (scrolled).
    pub fn row_rect(&mut self, i: usize) -> CGRect {
        let scroll = self.scroll();
        CGRect::new(
            0.0,
            self.list_rect().min_y() + i as f64 * Self::ROW_HEIGHT - scroll,
            self.size.width,
            Self::ROW_HEIGHT,
        )
    }

    /// Grid rows: an open folder becomes a heading over its tiles (closed folders stay as a heading too).
    fn grid_rows(&self) -> Vec<EffectsRow> {
        self.rows
            .iter()
            .map(|r| {
                let mut h = r.clone();
                if r.is_folder {
                    h.is_header = true;
                }
                h
            })
            .collect()
    }

    /// The tile layout of the grid.
    pub fn grid(&self) -> EffectsGridLayout {
        EffectsGridLayout::new(&self.grid_rows(), self.size.width.max(1.0), Self::TILE_WIDTH)
    }

    fn content_height(&self) -> f64 {
        if self.view_mode == EffectsViewMode::List {
            self.rows.len() as f64 * Self::ROW_HEIGHT
        } else {
            self.grid().content_height
        }
    }

    /// The row index under a panel-local point.
    pub fn row_index(&mut self, p: CGPoint) -> Option<usize> {
        let lr = self.list_rect();
        if !lr.contains(p) {
            return None;
        }
        let scroll = self.scroll();
        match self.view_mode {
            EffectsViewMode::List => {
                let i = ((p.y - lr.min_y() + scroll) / Self::ROW_HEIGHT).floor();
                (i >= 0.0 && (i as usize) < self.rows.len()).then_some(i as usize)
            }
            EffectsViewMode::Grid => {
                let q = CGPoint::new(p.x, p.y - lr.min_y() + scroll);
                let grid = self.grid();
                let item = grid.items.iter().find(|it| it.frame.contains(q))?;
                self.rows.iter().position(|r| r.id == item.id)
            }
        }
    }

    /// The grid tile (not a header) under a panel-local point; none in list mode or off a tile.
    pub fn tile_id(&mut self, p: CGPoint) -> Option<String> {
        let lr = self.list_rect();
        if self.view_mode != EffectsViewMode::Grid || !lr.contains(p) {
            return None;
        }
        let q = CGPoint::new(p.x, p.y - lr.min_y() + self.scroll());
        self.grid().items.iter().find(|it| !it.is_header && it.frame.contains(q)).map(|it| it.id.clone())
    }

    /// The ids of the grid tiles in view (empty in list mode), for the host's `EffectsTileAtlas::prepare`.
    pub fn visible_tile_ids(&mut self) -> Vec<String> {
        if self.view_mode != EffectsViewMode::Grid {
            return Vec::new();
        }
        let lr = self.list_rect();
        let top = lr.min_y() - self.scroll();
        self.grid()
            .items
            .iter()
            .filter(|it| {
                let f = offset_by(&it.frame, 0.0, top);
                !it.is_header && f.max_y() >= lr.min_y() && f.min_y() <= lr.max_y()
            })
            .map(|it| it.id.clone())
            .collect()
    }

    fn lead(depth: i64) -> f64 {
        (spacing::XS + spacing::SM) as f64 + depth.clamp(0, 2) as f64 * Self::INDENT
    }

    /// What dragging a row carries out of the panel: an effect, transition or saved preset id (`preset.<uuid>`, which
    /// `LibraryDropRoute` applies with the saved mode); folders and the built-in stack presets (they apply to the selection,
    /// by double-click) do not drag out.
    fn drag_ids(r: &EffectsRow) -> Vec<String> {
        if r.is_header || r.is_folder || r.item_id().starts_with(EditorSession::BUILT_IN_PRESET_PREFIX) {
            return Vec::new();
        }
        vec![r.item_id().to_string()]
    }

    // MARK: Events (panel-local points)

    /// A press.
    pub fn mouse_down(&mut self, p: CGPoint, m: InputModifiers, now: f64) {
        self.now = now;
        if p.y < Self::SEARCH_ROW_HEIGHT {
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
        let i = self.row_index(p);
        let row = i.map(|i| self.rows[i].clone());
        if m.contains(InputModifiers::SECONDARY) {
            if let Some(r) = &row
                && !r.is_folder
                && !r.is_header
            {
                self.selected_id = Some(r.id.clone());
            }
            let menu = self.menu_for(row.as_ref());
            self.events.push(EffectsEvent::Menu(menu, p));
            self.press = None;
            return;
        }
        self.press = Some((p, row.clone()));
        let Some(row) = row else {
            self.selected_id = None;
            return;
        };
        if row.is_folder || row.is_header {
            // A folder row only opens or closes (a user folder can still be dragged to reorder).
            if row.user_folder.is_none() || !row.is_folder {
                self.toggle_folder(&row.id);
                self.press = None;
            }
            return;
        }
        self.selected_id = Some(row.id.clone());
        let t = now;
        let double = self.last_click.as_ref().is_some_and(|l| l.0 == row.id && t - l.1 < Self::DOUBLE_CLICK);
        if double {
            self.last_click = None;
            self.press = None;
            self.events.push(EffectsEvent::Apply(row.item_id().to_string()));
        } else {
            self.last_click = Some((row.id.clone(), t));
        }
    }

    /// Activates the row `id` like assistive tech does: a folder or heading opens or closes, an item is selected and
    /// applied (there is no double click). False when no row has that id.
    pub fn a11y_activate(&mut self, id: &str) -> bool {
        let Some(row) = self.rows.iter().find(|r| r.id == id).cloned() else { return false };
        if row.is_folder || row.is_header {
            self.toggle_folder(&row.id);
        } else {
            self.selected_id = Some(row.id.clone());
            self.events.push(EffectsEvent::Apply(row.item_id().to_string()));
        }
        true
    }

    /// The pointer moved with the button down.
    pub fn mouse_dragged(&mut self, p: CGPoint) {
        let Some(start) = self.press.clone() else { return };
        if !self.is_dragging {
            if dist(p, start.0) < Self::DRAG_SLOP || start.1.is_none() {
                return;
            }
            self.is_dragging = true;
            self.last_click = None;
        }
        self.drop_row = self.internal_drop_target(p);
        if let Some(r) = &start.1
            && !r.is_folder
        {
            self.events.push(EffectsEvent::Drag(Self::drag_ids(r), DragPhase::Moved, p));
        }
    }

    /// The button went up.
    pub fn mouse_up(&mut self, p: CGPoint) {
        let start = self.press.take();
        let dragging = self.is_dragging;
        self.is_dragging = false;
        self.drop_row = None;
        let Some((_, Some(r))) = start else { return };
        if !dragging {
            // A click (no drag) on a user folder row opens or closes it.
            if r.is_folder {
                self.toggle_folder(&r.id);
            }
            return;
        }
        if r.is_folder {
            if let Some(moving) = r.user_folder
                && self.list_rect().contains(p)
            {
                let target = self.folder_move_target(p);
                self.move_folder(moving, target);
            }
            return;
        }
        if self.list_rect().contains(p)
            && let Some(t) = self.internal_drop_target(p)
            && let Some(folder) = self.rows[t].user_folder
        {
            self.add_item(r.item_id(), folder);
            self.events.push(EffectsEvent::Drag(Self::drag_ids(&r), DragPhase::Canceled, p));
            return;
        }
        self.events.push(EffectsEvent::Drag(Self::drag_ids(&r), DragPhase::Ended, p));
    }

    /// A user folder row under the pointer while an item is dragged inside the panel (built-in folders are read-only).
    fn internal_drop_target(&mut self, p: CGPoint) -> Option<usize> {
        let i = self.row_index(p)?;
        self.rows[i].user_folder.is_some().then_some(i)
    }

    /// Where a dragged user folder lands: in front of the folder under the pointer, else after the last user folder.
    fn folder_move_target(&mut self, p: CGPoint) -> Option<Id> {
        let i = self.row_index(p)?;
        self.rows[i].user_folder
    }

    /// The wheel.
    pub fn scroll_by(&mut self, gesture: Option<ScrollGesture>, dy: f64, now: f64) {
        self.sync_scroll_range();
        let (max_scroll, extent) = (self.scroll_body.max_offset, self.scroll_body.extent);
        self.scroll_body.feed(gesture, dy, max_scroll, extent, now);
    }

    /// Tells the scroll body how long the list is now (every frame and before a wheel): an offset past the end of shorter
    /// content is pulled back, never kept.
    pub fn sync_scroll_range(&mut self) {
        let lr = self.list_rect();
        self.scroll_body.set_range((self.content_height() - lr.height).max(0.0), lr.height);
    }

    /// Keys while the panel has focus: typing in the search field, up / down selection, left / right open and close
    /// folders (`EffectFolderOutline::key_navigation`), Return applies, Escape cancels a drag.
    pub fn key(&mut self, k: InputKey, m: InputModifiers, ui: &mut UiCx) -> bool {
        if k == InputKey::Escape
            && self.is_dragging
            && let Some((_, Some(r))) = self.press.take()
        {
            self.events.push(EffectsEvent::Drag(Self::drag_ids(&r), DragPhase::Canceled, CGPoint::ZERO));
            self.is_dragging = false;
            self.drop_row = None;
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
        let sel = self
            .selected_id
            .as_ref()
            .and_then(|id| self.rows.iter().position(|r| &r.id == id))
            .map_or(-1, |i| i as i64);
        match k {
            InputKey::Up => {
                self.move_selection(-1);
                true
            }
            InputKey::Down => {
                self.move_selection(1);
                true
            }
            InputKey::Left | InputKey::Right => {
                let key = if k == InputKey::Left { OutlineKey::Left } else { OutlineKey::Right };
                match EffectFolderOutline::key_navigation(&self.rows, sel, key) {
                    Navigation::None => return false,
                    Navigation::Select(i) => self.selected_id = Some(self.rows[i].id.clone()),
                    Navigation::Toggle(id) => {
                        self.toggle_folder(&id);
                        self.selected_id = Some(id);
                    }
                }
                true
            }
            InputKey::Enter => {
                let Some(r) = usize::try_from(sel).ok().and_then(|i| self.rows.get(i)).cloned() else { return false };
                if r.is_folder {
                    self.toggle_folder(&r.id);
                } else if !r.is_header {
                    self.events.push(EffectsEvent::Apply(r.item_id().to_string()));
                }
                true
            }
            _ => false,
        }
    }

    fn move_selection(&mut self, d: i64) {
        if self.rows.is_empty() {
            return;
        }
        let cur = self
            .selected_id
            .as_ref()
            .and_then(|id| self.rows.iter().position(|r| &r.id == id))
            .map_or(if d > 0 { -1 } else { self.rows.len() as i64 }, |i| i as i64);
        let mut i = cur + d;
        while usize::try_from(i).ok().and_then(|u| self.rows.get(u)).is_some_and(|r| r.is_header) {
            i += d;
        }
        let Some(idx) = usize::try_from(i).ok().filter(|u| *u < self.rows.len()) else { return };
        self.selected_id = Some(self.rows[idx].id.clone());
        let r = self.row_rect(idx);
        let lr = self.list_rect();
        let scroll = self.scroll();
        if r.min_y() < lr.min_y() {
            self.set_scroll(scroll - (lr.min_y() - r.min_y()));
        }
        let scroll = self.scroll();
        if r.max_y() > lr.max_y() {
            self.set_scroll(scroll + (r.max_y() - lr.max_y()));
        }
    }

    /// The text in the search field (the open editor's, else the field's).
    pub fn search_text(&self) -> String {
        self.search.editor().map_or_else(|| self.search.text.clone(), |e| e.string())
    }
    /// The search field has the keyboard.
    pub fn is_editing_search(&self) -> bool {
        self.search.is_editing()
    }

    fn set_search_text(&mut self, s: &str) {
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

    /// The hover tip under a point: a row's subtitle or the full title when it is cut.
    pub fn help(&mut self, p: CGPoint) -> Option<String> {
        let i = self.row_index(p)?;
        let r = &self.rows[i];
        if r.subtitle.is_empty() { None } else { Some(r.subtitle.clone()) }
    }

    // MARK: Drawing

    /// Draws the panel; `picture` answers a grid tile's still (`EffectsTileAtlas::picture`).
    pub fn draw(
        &mut self,
        c: &mut Canvas,
        t: &DrawTheme,
        ui: &mut UiCx,
        picture: &dyn Fn(&str) -> Option<EffectsTilePicture>,
    ) {
        c.fill(CGRect::new(0.0, 0.0, self.size.width, self.size.height), t.panel());
        let f = self.search_field_rect();
        self.search.font_size = 11.0;
        // `SQSearchField`: the magnifier at 9, the text from 28 (as the Library field).
        self.search.text_inset = 28.0;
        self.search.quiet = true;
        let editing = self.search.is_editing();
        self.search.draw(c, f, t, editing, ui);
        c.draw_icon(SQIcon::Search, CGPoint::new(f.min_x() + 9.0, f.mid_y() - 6.0), 12.0, t.label3(), None);
        if self.search_text().is_empty() && !editing {
            c.draw_text_in("Search effects, also Premiere names", f, 11.0, t.label3(), TextAlign::Left, 28.0, 0);
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
        c.save_gstate();
        c.clip_to(self.list_rect());
        if self.rows.is_empty() {
            self.draw_empty(c, t);
        } else if self.view_mode == EffectsViewMode::List {
            self.draw_list(c, t);
        } else {
            self.draw_grid(c, t, picture);
        }
        c.restore_gstate();
        let lr = self.list_rect();
        let foot = CGRect::new(
            spacing::MD as f64,
            lr.max_y() + 6.0,
            (self.size.width - 2.0 * spacing::MD as f64).max(0.0),
            Self::FOOTER_HEIGHT - 6.0,
        );
        // Never past the panel edge: a narrow panel wraps to more lines than the footer holds, so the last line that fits
        // ends in an ellipsis.
        let room = ((foot.height / 16.0).floor() as usize).max(1);
        let mut lines = c.wrap(Self::FOOTER_HINT, foot.width, 11.0);
        if lines.len() > room {
            let rest = lines.split_off(room - 1).join(" ");
            lines.push(c.ellipsized(&rest, 11.0, 0, foot.width));
        }
        for (i, line) in lines.iter().enumerate() {
            c.draw_text(line, CGPoint { x: foot.x, y: foot.y + i as f64 * 16.0 }, 11.0, t.label3(), f64::INFINITY, 0);
        }
    }

    fn draw_empty(&self, c: &mut Canvas, t: &DrawTheme) {
        let q = trim_ws(&self.query).to_string();
        // r8: the shared empty state (icon, title, hint) centered in the list column, top-aligned when it is short.
        let hint = if q.is_empty() {
            String::new()
        } else {
            format!("Nothing here matches \u{201C}{q}\u{201D}.")
        };
        let empty = EmptyPane {
            icon: if q.is_empty() { SQIcon::Folder } else { SQIcon::Search },
            title: if q.is_empty() { "Nothing here yet" } else { "No results" },
            hint: &hint,
            button: None,
        };
        draw_empty_pane(c, t, self.list_rect(), &empty, |_| false);
    }

    fn draw_list(&mut self, c: &mut Canvas, t: &DrawTheme) {
        let lr = self.list_rect();
        let gap = (spacing::XS + spacing::XXS) as f64;
        for i in 0..self.rows.len() {
            let rr = self.row_rect(i);
            if rr.max_y() < lr.min_y() || rr.min_y() > lr.max_y() {
                continue;
            }
            let r = self.rows[i].clone();
            let pill = rr.inset_by(spacing::XS as f64, 1.0);
            if self.drop_row == Some(i) {
                c.fill_rounded(pill, radius::SMALL as f64, t.accent_fill());
                c.stroke_rounded(pill, radius::SMALL as f64, 2.0, t.accent());
            } else {
                let hot = self.hover.is_some_and(|h| rr.contains(h)) && !self.is_dragging;
                c.stone_row_pill(rr, self.selected_id.as_deref() == Some(r.id.as_str()), hot, t);
            }
            let mut x = Self::lead(r.depth);
            if r.is_header {
                c.draw_text_in(
                    &r.title,
                    CGRect::new(x, rr.min_y(), rr.width - x, rr.height),
                    11.0,
                    t.label2(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
                continue;
            }
            if r.is_folder {
                let mid = CGPoint::new(x + 6.0, rr.mid_y());
                let pts = if r.is_expanded {
                    [
                        CGPoint::new(mid.x - 3.0, mid.y - 1.5),
                        CGPoint::new(mid.x, mid.y + 1.5),
                        CGPoint::new(mid.x + 3.0, mid.y - 1.5),
                    ]
                } else {
                    [
                        CGPoint::new(mid.x - 1.5, mid.y - 3.0),
                        CGPoint::new(mid.x + 1.5, mid.y),
                        CGPoint::new(mid.x - 1.5, mid.y + 3.0),
                    ]
                };
                c.stroke_polyline(&pts, 1.2, t.label2());
                x += 12.0 + gap;
            }
            let mut right = rr.max_x() - Self::lead(0);
            if let (true, Some(n), true) = (r.is_folder, r.count, true) {
                let s = n.to_string();
                let w = c.size_of(&s, 10.0, 0).width;
                c.draw_text(&s, CGPoint::new(right - w, rr.mid_y() - 6.0), 10.0, t.label3(), f64::INFINITY, 0);
                right -= w + gap;
            }
            // NSTableCellView turns its text field white, whatever textColor says
            c.draw_text_in(
                &r.title,
                CGRect::new(x, rr.min_y(), (right - x).max(0.0), rr.height),
                12.0,
                t.label(),
                TextAlign::Left,
                0.0,
                0,
            );
            // Stabilize (the app's own, not Gyroflow) wears the experimental pill behind its name.
            if !r.is_folder
                && sq_draw::experimental::Feature::for_effect_kind(&r.id)
                    == Some(sq_draw::experimental::Feature::Stabilize)
            {
                let tw = c.size_of(&r.title, 12.0, 0).width.ceil();
                let origin = CGPoint::new(x + tw + 8.0, rr.mid_y() - sq_draw::experimental::PILL_HEIGHT / 2.0);
                if origin.x + 90.0 < right {
                    c.experimental_mark(
                        sq_draw::experimental::Feature::Stabilize,
                        origin,
                        sq_draw::experimental::ExperimentalMark::Pill,
                        t,
                    );
                    // Kit: the choice behind the pill, muted at the right (two short lines when the dock is narrow).
                    let room = right - (origin.x + 100.0);
                    if room >= 60.0 {
                        let lines = c.wrap("Method: Standard or Gyroflow", room, 10.0);
                        let top = rr.mid_y() - lines.len().min(2) as f64 * 6.0;
                        for (i, line) in lines.iter().take(2).enumerate() {
                            c.draw_text_in(
                                line,
                                CGRect::new(right - room, top + i as f64 * 12.0, room, 12.0),
                                10.0,
                                t.label3(),
                                TextAlign::Right,
                                0.0,
                                0,
                            );
                        }
                    }
                }
            }
        }
    }

    fn draw_grid(&mut self, c: &mut Canvas, t: &DrawTheme, picture: &dyn Fn(&str) -> Option<EffectsTilePicture>) {
        let lr = self.list_rect();
        let top = lr.min_y() - self.scroll();
        for item in self.grid().items {
            let f = offset_by(&item.frame, 0.0, top);
            if f.max_y() < lr.min_y() || f.min_y() > lr.max_y() {
                continue;
            }
            if item.is_header {
                c.draw_text_in(
                    &item.title,
                    f.inset_by(EffectsGridLayout::PAD, 0.0),
                    11.0,
                    t.label2(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
                continue;
            }
            let thumb = offset_by(&item.thumb, 0.0, top);
            c.fill_rounded(thumb, radius::SMALL as f64, t.content());
            if let Some(pic) = picture(&item.id) {
                // The stills are 16:9 like the tile (`EffectsGridLayout`); the square-cornered picture gets the rounding back.
                c.draw_image_slot(pic.slot, thumb, pic.source(), Color::WHITE);
                c.round_picture_corners(thumb, radius::SMALL as f64, t.panel());
            } else {
                let s = 22.0;
                c.draw_icon(
                    item.symbol,
                    CGPoint::new(thumb.mid_x() - s / 2.0, thumb.mid_y() - s / 2.0),
                    s,
                    t.label2(),
                    None,
                );
            }
            if self.selected_id.as_deref() == Some(item.id.as_str()) {
                c.stroke_rounded(thumb, radius::SMALL as f64, 2.0, t.accent());
            }
            c.draw_text_in(
                &item.title,
                CGRect::new(f.min_x(), thumb.max_y(), f.width, EffectsGridLayout::CAPTION_HEIGHT),
                10.0,
                t.label2(),
                TextAlign::Center,
                0.0,
                0,
            );
        }
    }
}

/// The Effects panel as an app host: it owns the tile atlas and hands the panel's hooks to the app as
/// [`EffectsEvent`]s ([`EffectsPanelHost::take_events`]).
pub struct EffectsPanelHost {
    /// The panel.
    pub panel: EffectsDrawPanel,
    /// The grid's stills.
    pub atlas: EffectsTileAtlas,
    frame: CGRect,
    scale: f32,
}

impl EffectsPanelHost {
    /// A host around `panel`.
    pub fn new(panel: EffectsDrawPanel) -> EffectsPanelHost {
        EffectsPanelHost { panel, atlas: EffectsTileAtlas::new(), frame: CGRect::default(), scale: 1.0 }
    }

    /// The panel's hooks that fired, in order.
    pub fn take_events(&mut self) -> Vec<EffectsEvent> {
        self.panel.take_events()
    }

    fn local(&self, x: f32, y: f32) -> CGPoint {
        let k = self.scale as f64;
        CGPoint::new(x as f64 / k - self.frame.x, y as f64 / k - self.frame.y)
    }
}

impl sq_app_shell::AppHost for EffectsPanelHost {
    fn sync(&mut self, _session: &EditorSession) {
        let ids = self.panel.visible_tile_ids();
        self.atlas.prepare(&ids, EffectsTileAtlas::BUDGET);
        self.atlas.advance(self.panel.now);
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.frame = frame;
        // Events are pixels: a display scale change must reach the hit tests before the next draw.
        self.scale = cx.scale;
        self.panel.size = CGSize::new(frame.width, frame.height);
        self.panel.sync_scroll_range();
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.scale = c.scale;
        c.save_gstate();
        c.translate_by(self.frame.x, self.frame.y);
        let atlas = &self.atlas;
        self.panel.draw(c, t, cx.ui, &|id| atlas.picture(id));
        c.restore_gstate();
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        self.scale = cx.scale;
        let now = cx.ui.now;
        self.panel.now = now;
        let inside = |s: &Self, p: CGPoint| CGRect::new(0.0, 0.0, s.frame.width, s.frame.height).contains(p);
        let taken = match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = self.local(x, y);
                if !inside(self, p) {
                    return false;
                }
                self.panel.mouse_down(p, modifiers, now);
                true
            }
            InputEvent::MouseDragged { x, y, .. } => {
                let p = self.local(x, y);
                self.panel.mouse_dragged(p);
                self.panel.press.is_some()
            }
            InputEvent::MouseUp { x, y } => {
                let p = self.local(x, y);
                let was = self.panel.press.is_some();
                self.panel.mouse_up(p);
                was
            }
            InputEvent::MouseMoved { x, y } => {
                let p = self.local(x, y);
                self.panel.hover = Some(p);
                let tile = self.panel.tile_id(p);
                self.atlas.set_hover(tile.as_deref(), now);
                false
            }
            InputEvent::Scroll { x, y, dy, .. } => {
                let p = self.local(x, y);
                if !inside(self, p) {
                    return false;
                }
                self.panel.scroll_by(cx.ui.gesture, f64::from(dy) / f64::from(self.scale), now);
                true
            }
            InputEvent::KeyDown { key, modifiers } => self.panel.key(key, modifiers, cx.ui),
        };
        self.panel.pump();
        taken
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effects::effects_catalog::EffectsEntry;
    use crate::test_support::MemoryDefaults;
    use sq_core_time::{IdSource, SequentialIds};
    use sq_draw::motion;

    fn panel() -> EffectsDrawPanel {
        let mut p = EffectsDrawPanel::new(Box::new(MemoryDefaults::default()), Box::new(SequentialIds::default()));
        p.size = CGSize::new(260.0, 600.0);
        p
    }

    fn last_drag(p: &mut EffectsDrawPanel) -> Option<(Vec<String>, DragPhase)> {
        p.take_events().into_iter().rev().find_map(|e| match e {
            EffectsEvent::Drag(ids, phase, _) => Some((ids, phase)),
            _ => None,
        })
    }

    fn pad(phase: sq_draw::scroll::ScrollPhase) -> Option<ScrollGesture> {
        Some(ScrollGesture { precise: true, phase, ..Default::default() })
    }

    /// Bug 39 (2026-11-14): the Effects list stayed stretched after a rubber-band pull at the top because nothing ran the
    /// bounce between two scroll events. The panel reads its offset each frame; frames alone must bring it back.
    #[test]
    fn an_overscroll_springs_back_by_frames_alone_and_a_reopened_panel_starts_in_bounds() {
        use sq_draw::scroll::ScrollPhase::{Began, Changed, Ended};
        let mut p = panel();
        p.size = CGSize::new(260.0, 200.0);
        p.sync_scroll_range();
        let max = p.scroll_body.max_offset;
        assert!(max > 0.0, "the catalog is taller than 200 pt");
        for (k, (pull, edge)) in [(300.0, 0.0), (-(max + 400.0), max)].into_iter().enumerate() {
            let b = 200.0 * k as f64; // each round on its own stretch of the clock
            p.scroll_body.assign(edge);
            p.scroll_by(pad(Began), 0.0, b + 1.0);
            p.scroll_by(pad(Changed), pull, b + 1.01);
            motion::begin_frame(b + 1.02);
            let stretched = p.scroll();
            assert!(stretched < 0.0 || stretched > max, "pulled past an end: {stretched}");
            p.scroll_by(pad(Ended), 0.0, b + 1.5);
            // Only frames from here on, no more scroll messages.
            let mut t = b + 1.5;
            while t < b + 3.0 {
                t += 1.0 / 60.0;
                motion::begin_frame(t);
                p.scroll();
            }
            assert_eq!(p.scroll(), edge, "back at the edge after the bounce");
            assert!(!motion::needs_frame(), "no frame is asked for once it settled");
            // The same pull, the panel closed before the end came, reopened much later: it starts in bounds.
            p.scroll_by(pad(Began), 0.0, b + 10.0);
            p.scroll_by(pad(Changed), pull, b + 10.01);
            motion::begin_frame(b + 60.0);
            assert_eq!(p.scroll(), edge, "an out-of-range offset is not restored");
        }
    }

    #[test]
    fn drag_from_an_effect_row_reports_moves_and_the_release() {
        let mut p = panel();
        p.set_query("blur");
        let i = p.rows().iter().position(|r| !r.is_folder && !r.is_header).expect("row");
        let y = p.row_rect(i).mid_y();
        let pt = CGPoint::new(60.0, y);
        p.mouse_down(pt, InputModifiers::NONE, 0.0);
        p.mouse_dragged(CGPoint::new(pt.x + 40.0, pt.y - 20.0));
        assert!(p.is_dragging);
        let want = vec![p.rows()[i].item_id().to_string()];
        assert_eq!(last_drag(&mut p), Some((want, DragPhase::Moved)));
        p.mouse_up(CGPoint::new(pt.x + 300.0, pt.y - 20.0));
        assert_eq!(last_drag(&mut p).map(|d| d.1), Some(DragPhase::Ended));
    }

    #[test]
    fn drag_from_a_grid_tile_reports_moves_and_the_release() {
        let mut p = panel();
        p.set_view_mode(EffectsViewMode::Grid);
        p.set_query("blur");
        let grid = p.grid();
        let tile = grid.items.iter().find(|i| !i.is_header).expect("tile");
        let pt = CGPoint::new(tile.frame.mid_x(), tile.frame.mid_y() + EffectsDrawPanel::SEARCH_ROW_HEIGHT);
        p.mouse_down(pt, InputModifiers::NONE, 0.0);
        p.mouse_dragged(CGPoint::new(pt.x + 40.0, pt.y - 20.0));
        assert!(p.is_dragging);
        assert_eq!(last_drag(&mut p).map(|d| d.1), Some(DragPhase::Moved));
        p.mouse_up(CGPoint::new(pt.x + 300.0, pt.y - 20.0));
        assert_eq!(last_drag(&mut p).map(|d| d.1), Some(DragPhase::Ended));
    }

    #[test]
    fn a_saved_preset_row_drags_out_like_an_effect() {
        let mut p = panel();
        let id = SequentialIds::default().next_id();
        p.set_preset_entries(vec![EffectsEntry::new(
            &format!("preset.{id}"),
            "Mine",
            EffectFolderOutline::PRESETS_FOLDER,
            SQIcon::ToolMask,
        )]);
        p.set_query("Mine");
        let i = p.rows().iter().position(|r| !r.is_folder && !r.is_header).expect("row");
        let y = p.row_rect(i).mid_y();
        let pt = CGPoint::new(60.0, y);
        p.mouse_down(pt, InputModifiers::NONE, 0.0);
        p.mouse_dragged(CGPoint::new(pt.x + 40.0, pt.y - 20.0));
        assert_eq!(last_drag(&mut p).map(|d| d.0), Some(vec![format!("preset.{id}")]));
    }

    #[test]
    fn effects_search_keeps_undo_and_paste() {
        let mut p = panel();
        let mut ui = UiCx::new();
        p.focus_search();
        for ch in "ab".chars() {
            assert!(p.key(InputKey::Character(ch), InputModifiers::NONE, &mut ui));
        }
        assert!(p.key(InputKey::Character('z'), InputModifiers::COMMAND, &mut ui));
        assert_eq!(p.search_text(), "");
        ui.clipboard.write("blur");
        assert!(p.key(InputKey::Character('v'), InputModifiers::COMMAND, &mut ui));
        assert_eq!(p.search_text(), "blur");
    }
}
