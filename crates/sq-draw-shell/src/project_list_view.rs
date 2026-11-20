// Swift: ProjectListView.swift, ProjectListView+Chrome.swift, +Columns, +Grid, +Health, +HoverScrub, +Move, +Reveal
//! The Project panel translated from the Mac `ProjectPanelView`: the same `ProjectPanelModel` (rows, cell texts, kind
//! icons, labels, search, sort, delete/rename/new folder) as a list (folders open in place, a kind chip per row, the
//! columns of `ProjectColumnLayout` with the header's column picker) or an icon grid (posters from the host, folders
//! entered by double-click, a path row back). The header's "..." menu switches the view and shows the search row. Drawing
//! and events are new; the menus are the Mac `ProjectPanelMenus` rows the shared toolkit has.
//! No smart-folder drag or filter chips, as in Swift `ProjectListView`.
//!
//! Mapping (docs/rust/session-ui-design.md section 2): the list holds no host, model or session. Every call that needs
//! them takes a [`ProjectListCx`]. The Swift hooks (`onOpenSequence`, `onDrag`, `onCollect`, ...) are
//! [`ProjectListEvent`]s ([`ProjectListView::take_events`]); the rows of a menu queue their action and
//! [`ProjectListView::run_queued`] performs them after the menu closed. What the shell has to do (dialogs, imports, the
//! Find sheet, placing clips) leaves as [`ProjectListEvent::Host`]. `UserDefaults` is [`ProjectListSettings`]: the list
//! keeps the values and raises [`ProjectListEvent::SettingsChanged`]; the app persists them. The dock's tab strip is a
//! [`StripTools`] the app copies from `ShellDock` (`set_strip`). `weak host.projectSelection` is
//! [`ProjectListView::selection`].

use sq_core_model::{Bin, BinItem, BinItemRef, LabelColor, MediaKind};
use sq_core_time::{Id, IdSource, Time};
use sq_draw::scroll::ScrollBody;
use sq_draw::theme::{radius, spacing, type_size};
use sq_draw::{
    Canvas, Color, DrawTheme, InputEvent, InputKey, InputModifiers, InspectorDraw, TextAlign, TextFieldControl,
    TextMeasure, UiCx,
};
use sq_editor_session::{
    Column, EditorSession, HoverScrub, MediaFilter, PixelAspectChoices, ProjectColumnLayout, ProjectColumnSizing,
    ProjectDrop, ProjectItemIcon, ProjectMenuAction, ProjectMenuContext, ProjectPanelMenus, ProjectPanelModel,
};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;

/// One visible row of the list.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ListRow {
    /// The item.
    pub item_ref: BinItemRef,
    /// Indent level.
    pub depth: usize,
    /// Set on a format variant row: `item_ref` is its sequence, the row is drawn one level in.
    pub variant: Option<Id>,
}

/// List or icon grid (the Mac `ProjectPanelView.ViewMode`, saved under the same key).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ViewMode {
    /// Rows with columns.
    List,
    /// Tiles.
    Icons,
}

impl ViewMode {
    /// The saved name.
    pub fn raw_value(self) -> &'static str {
        match self {
            ViewMode::List => "list",
            ViewMode::Icons => "icons",
        }
    }
    /// From the saved name.
    pub fn from_raw(s: &str) -> Option<ViewMode> {
        match s {
            "list" => Some(ViewMode::List),
            "icons" => Some(ViewMode::Icons),
            _ => None,
        }
    }
}

/// The values the Mac panel keeps per user (`UserDefaults` keys `ProjectPanel.viewMode`, `sq.project.searchVisible`,
/// `sq.project.thumbSize`, the column layout and `AppSettings.hoverScrub`).
#[derive(Clone, Debug, PartialEq)]
pub struct ProjectListSettings {
    /// List or icons.
    pub view_mode: ViewMode,
    /// The search row shows.
    pub search_visible: bool,
    /// Icon thumbnail width.
    pub thumb_size: f64,
    /// Visible columns and their widths.
    pub columns: ProjectColumnLayout,
    /// View > Hover Scrub.
    pub hover_scrub: bool,
}

impl Default for ProjectListSettings {
    fn default() -> Self {
        ProjectListSettings {
            view_mode: ViewMode::List,
            search_visible: false,
            thumb_size: 96.0,
            columns: ProjectColumnLayout::defaults(),
            hover_scrub: false,
        }
    }
}

/// A poster frame in one of the renderer's image slots (the Windows timeline thumbnail atlas): the part `u0...v1` of the
/// slot, `pixel_size` big.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ProjectPoster {
    /// Renderer slot.
    pub slot: usize,
    /// Left edge of the part.
    pub u0: f32,
    /// Top edge.
    pub v0: f32,
    /// Right edge.
    pub u1: f32,
    /// Bottom edge.
    pub v1: f32,
    /// Size of the picture in the slot.
    pub pixel_size: CGSize,
}

impl ProjectPoster {
    /// The whole slot.
    pub fn new(slot: usize, pixel_size: CGSize) -> ProjectPoster {
        ProjectPoster { slot, u0: 0.0, v0: 0.0, u1: 1.0, v1: 1.0, pixel_size }
    }

    /// Draws the poster whole into `bounds` at its own aspect (never stretched, never cropped): `bars` fills the rest
    /// of `bounds` (`None` leaves what is there). Returns the rect the picture got. Every panel that shows a poster in a
    /// tile of its own shape (Project icons, the card browser, the start screen) draws it through here, the same
    /// `sq_draw::Canvas::draw_image_fit` the Library uses.
    pub fn draw_fit(&self, c: &mut Canvas, bounds: CGRect, bars: Option<Color>) -> CGRect {
        c.draw_image_fit(self.slot, bounds, [self.u0, self.v0, self.u1, self.v1], self.pixel_size, Color::WHITE, bars)
    }
}

/// One column of the list on screen.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ColumnFrame {
    /// The column.
    pub column: Column,
    /// Left edge.
    pub min_x: f64,
    /// Right edge.
    pub max_x: f64,
}

/// A part of the health line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HealthPart {
    /// "N in folder".
    InFolder,
    /// "N outside".
    Outside,
    /// "N missing".
    Missing,
    /// The Fix… button.
    Fix,
}

/// A drag of the selected media and sequences out of the list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DragPhase {
    /// The pointer moved.
    Moved,
    /// Dropped.
    Ended,
    /// Taken back (dropped inside the panel, or Esc).
    Canceled,
}

/// Where a drag inside the panel would drop the items.
#[derive(Clone, Debug, PartialEq)]
pub struct MoveTarget {
    /// The folder.
    pub bin: Id,
    /// The index among the folder's children before the moved items are removed; `None` appends.
    pub index: Option<usize>,
    /// Where the cue is drawn: a folder row or tile outlined, or an insertion line.
    pub cue: CGRect,
    /// The cue is a line.
    pub is_line: bool,
}

/// The tile under the pointer while hover scrubbing.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HoverScrubState {
    /// Index into the grid items.
    pub item: usize,
    /// The media.
    pub media: Id,
    /// The frame time.
    pub time: Time,
    /// Where the scrub line sits.
    pub x: f64,
}

/// A press on the list's column header (resize, move or sort).
#[derive(Clone, Copy, Debug, PartialEq)]
struct ColumnPress {
    column: Column,
    kind: ColumnPressKind,
    start_x: f64,
    dragged: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum ColumnPressKind {
    Resize { start_width: f64 },
    Move,
}

/// The strip tools of the Project tab in the dock (`ShellDock` group): the app copies the group's strip each frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StripTools {
    /// The Project group's strip.
    pub strip: CGRect,
}

/// What the list tells its owner.
#[derive(Clone, Debug)]
pub enum ProjectListEvent {
    /// Double-click on a sequence.
    OpenSequence(Id),
    /// Double-click on a format variant row.
    OpenVariant(Id, Id),
    /// Double-click on a media item.
    OpenMedia(Id),
    /// Extract Audio.
    ExtractAudio(Id),
    /// Conform to Constant Frame Rate of the eligible items.
    ConformToConstantFrameRate(Vec<Id>),
    /// Fix > Collect (copy outside media into the project folder).
    Collect,
    /// Fix > Reconnect (File > Reconnect Media…).
    Reconnect,
    /// A drag of the selected items out of the list: the host shows it over the timeline (window pixels).
    Drag {
        /// The dragged items.
        refs: Vec<BinItemRef>,
        /// Phase.
        phase: DragPhase,
        /// Pointer x in pixels.
        x: f32,
        /// Pointer y in pixels.
        y: f32,
    },
    /// A menu to show at a window point (`anchor` = the control it drops from).
    PresentMenu {
        /// The rows.
        items: Vec<SQMenuItem>,
        /// Top-left corner.
        at: CGPoint,
        /// The control the menu belongs to.
        anchor: Option<CGRect>,
    },
    /// The options button's menu: the root adds the shared panel rows under it.
    PresentOptionsMenu {
        /// The rows.
        items: Vec<SQMenuItem>,
        /// Top-left corner.
        at: CGPoint,
    },
    /// A line for the status bar.
    Flash(String),
    /// A message dialog (title, detail).
    Message(String, String),
    /// Rename in a small form dialog; the answer goes to [`ProjectListView::rename_to`].
    Rename(BinItemRef),
    /// A menu action the shell performs (Import, Find, Reveal, Replace Media, placing clips...).
    Host(ProjectMenuAction, Vec<BinItemRef>),
    /// The settings changed: persist [`ProjectListView::settings`].
    SettingsChanged,
}

/// What a call into the list may touch.
pub struct ProjectListCx<'a, 'm> {
    /// The panel model.
    pub model: &'a mut ProjectPanelModel,
    /// The session (undo steps).
    pub session: &'a mut EditorSession,
    /// Text measure at the window's scale.
    pub measure: TextMeasure<'m>,
    /// Hover, drag preview, clipboard.
    pub ui: &'a mut UiCx,
    /// Seconds on a steady clock (double-click test, scrolling).
    pub now: f64,
    /// Ids for new smart folders.
    pub ids: &'a mut dyn IdSource,
    /// Whether the app can collect files (Fix > Collect).
    pub can_collect: bool,
    /// The keys held now: Shift scrubs while Hover Scrub is off.
    pub modifiers: InputModifiers,
}

/// A menu row picked, performed by [`ProjectListView::run_queued`] once the menu closed.
#[derive(Clone, Debug)]
enum ListAction {
    Menu(ProjectMenuAction, Vec<BinItemRef>),
    SetViewMode(ViewMode),
    ToggleSearch,
    SetFilter(MediaFilter),
    ToggleSpoken,
    SaveFilter,
    ToggleSmart(Id),
    DeleteSmart(Id),
    ShowMissing,
    Reconnect,
    Collect,
}

type MenuQueue = Rc<RefCell<Vec<ListAction>>>;

/// The Project panel as a list or icon grid.
pub struct ProjectListView {
    /// The panel in window points.
    pub frame: CGRect,
    /// Draws "Project" in its header row; off when a dock tab strip above already names the panel.
    pub shows_title: bool,
    strip: Option<StripTools>,
    expanded: BTreeSet<Id>,
    selection: Vec<BinItemRef>,
    scroll_body: ScrollBody,
    has_focus: bool,
    health_hover: Option<HealthPart>,
    hover_row: Option<usize>,
    press: Option<CGPoint>,
    is_dragging: bool,
    move_target: Option<MoveTarget>,
    last_click: Option<(BinItemRef, Option<Id>, f64)>,
    variant_selection: Option<Id>,
    settings: ProjectListSettings,
    search: TextFieldControl,
    size_slider_dragging: bool,
    column_press: Option<ColumnPress>,
    scrub: Option<HoverScrubState>,
    /// Tips of the last drawn rows (offline triangle, cut names), in window points.
    row_tips: Vec<(CGRect, String)>,
    events: Vec<ProjectListEvent>,
    queue: MenuQueue,
    /// Posters of media items for the icon grid (the host fills it from its thumbnails); `None` while one loads.
    pub posters: std::collections::BTreeMap<Id, ProjectPoster>,
    /// The scrubbed frame of the tile being scrubbed.
    pub scrub_poster: Option<(Id, Time, ProjectPoster)>,
}

impl ProjectListView {
    /// `Theme.Row.panelList`.
    pub const ROW_HEIGHT: f64 = 24.0;
    /// Height of the header row.
    pub const HEADER_HEIGHT: f64 = 30.0;
    /// `ProjectPanelView.searchRowHeight`.
    pub const SEARCH_ROW_HEIGHT: f64 = 38.0;
    /// `ProjectPanelView.crumbHeight`.
    pub const CRUMB_HEIGHT: f64 = 28.0;
    /// `PanelListHeader.height` = `Theme.Row.panelList`.
    pub const COLUMN_HEADER_HEIGHT: f64 = 24.0;
    const NAME_LEAD: f64 = 12.0;
    const LEVEL_INDENT: f64 = 14.0;
    /// Levels past this one indent by the smaller `DEEP_INDENT`, so names keep room; every level stays visible.
    const FULL_INDENT_LEVELS: usize = 3;
    const DEEP_INDENT: f64 = 4.0;
    const CHIP: f64 = 16.0;
    const DOUBLE_CLICK: f64 = 0.4;
    /// Icon grid thumbnail width range (the Mac slider's 64...160 range).
    pub const THUMB_RANGE: (f64, f64) = (64.0, 160.0);
    const DRAG_SLOP: f64 = 4.0;
    /// The red triangle after an offline name (14 pt).
    const OFFLINE_ICON: f64 = 14.0;
    const OFFLINE_RED: Color = Color::rgb(0.898, 0.282, 0.302);
    const CELL_PAD: f64 = spacing::XS as f64;
    const CELL_INSET: f64 = spacing::SM as f64;
    const LIST_FONT: f64 = 11.0;
    const OPTIONS_SIZE: f64 = 22.0;
    const STRIP_BUTTON: f64 = 28.0;
    const SIZE_SLIDER_WIDTH: f64 = 64.0;
    const RESIZE_GRAB: f64 = 4.0;
    const COLUMN_SLOP: f64 = 3.0;
    const MAX_COLUMN_WIDTH: f64 = 600.0;
    const INSERT_BAND: f64 = 0.25;
    const SCRUB_LINE_WIDTH: f64 = 1.5;
    const HEALTH_HEIGHT: f64 = 24.0;
    const TILE_NAME_GAP: f64 = spacing::XS as f64;
    const TILE_NAME_HEIGHT: f64 = 14.0;
    const TILE_PAD: f64 = 6.0;
    const RING_WIDTH: f64 = 2.0;

    /// The x offset of nesting `level` from the name lead: 14 pt per level up to 3 levels, then 4 pt per level.
    pub(crate) fn indent(level: usize) -> f64 {
        let full = level.min(Self::FULL_INDENT_LEVELS);
        full as f64 * Self::LEVEL_INDENT + (level - full) as f64 * Self::DEEP_INDENT
    }

    /// A list with the user's saved `settings`.
    pub fn new(settings: ProjectListSettings) -> ProjectListView {
        let mut search = TextFieldControl::new("");
        search.alignment = sq_draw::Alignment::Left;
        let mut s = settings;
        s.thumb_size = s.thumb_size.clamp(Self::THUMB_RANGE.0, Self::THUMB_RANGE.1);
        ProjectListView {
            frame: CGRect::default(),
            shows_title: true,
            strip: None,
            expanded: BTreeSet::new(),
            selection: Vec::new(),
            scroll_body: ScrollBody::new(0.0),
            has_focus: false,
            health_hover: None,
            hover_row: None,
            press: None,
            is_dragging: false,
            move_target: None,
            last_click: None,
            variant_selection: None,
            settings: s,
            search,
            size_slider_dragging: false,
            column_press: None,
            scrub: None,
            row_tips: Vec::new(),
            events: Vec::new(),
            queue: Rc::new(RefCell::new(Vec::new())),
            posters: Default::default(),
            scrub_poster: None,
        }
    }

    /// What the owner persists after [`ProjectListEvent::SettingsChanged`].
    pub fn settings(&self) -> &ProjectListSettings {
        &self.settings
    }
    /// The selected items (the shell's `projectSelection`).
    pub fn selection(&self) -> &[BinItemRef] {
        &self.selection
    }
    /// Replaces the selection.
    pub fn select(&mut self, refs: Vec<BinItemRef>) {
        self.selection = refs;
    }
    /// Keys go to the list only after a click inside it, until a click elsewhere.
    pub fn has_focus(&self) -> bool {
        self.has_focus
    }
    /// The open folders.
    pub fn expanded(&self) -> &BTreeSet<Id> {
        &self.expanded
    }
    /// List or icons.
    pub fn view_mode(&self) -> ViewMode {
        self.settings.view_mode
    }
    /// The search row shows.
    pub fn is_search_visible(&self) -> bool {
        self.settings.search_visible
    }
    /// View > Hover Scrub is on.
    pub fn hover_scrub_on(&self) -> bool {
        self.settings.hover_scrub
    }
    /// A drag of the selection is running.
    pub fn is_dragging(&self) -> bool {
        self.is_dragging
    }
    /// Where a drag inside the panel would drop the items.
    pub fn move_target(&self) -> Option<&MoveTarget> {
        self.move_target.as_ref()
    }
    /// The scroll offset.
    pub fn scroll(&mut self) -> f64 {
        self.scroll_body.position()
    }
    fn set_scroll(&mut self, v: f64) {
        self.scroll_body.assign(v);
    }
    /// The Project group's tab strip carries the item count, New Folder and "..." (the Mac `TabStrip`); `None` keeps the
    /// header row. The app passes it each frame from `ShellDock`.
    pub fn set_strip(&mut self, tools: Option<StripTools>) {
        self.strip = tools;
    }
    /// The width the dock keeps at the right end of the Project strip for the tools (`ShellDock::strip_tools`).
    pub fn strip_tools_width(&self, m: &TextMeasure, item_count: &str) -> f64 {
        let w = m.width(item_count, 11.0, 0);
        let slider =
            if self.settings.view_mode == ViewMode::Icons { Self::SIZE_SLIDER_WIDTH + spacing::MD as f64 } else { 0.0 };
        2.0 * Self::STRIP_BUTTON + 2.0 + w.ceil() + 6.0 + 2.0 + slider
    }
    /// What happened since the last call.
    pub fn take_events(&mut self) -> Vec<ProjectListEvent> {
        std::mem::take(&mut self.events)
    }

    // MARK: Rows

    /// Visible rows: the root's sequences first, then folders and loose items (the Mac `rootItems`), open folders inline.
    pub fn rows(&self, model: &ProjectPanelModel) -> Vec<ListRow> {
        let mut out = Vec::new();
        let project = model.project();
        let all = model.children(&project.root_bin);
        let is_sequence = |i: &BinItem| matches!(i, BinItem::Sequence(_));
        let mut ordered: Vec<BinItem> = all.iter().filter(|i| is_sequence(i)).cloned().collect();
        ordered.extend(all.iter().filter(|i| !is_sequence(i)).cloned());
        self.add_rows(model, &ordered, 0, &mut out);
        out
    }

    fn add_rows(&self, model: &ProjectPanelModel, items: &[BinItem], depth: usize, out: &mut Vec<ListRow>) {
        for i in items {
            out.push(ListRow { item_ref: i.item_ref(), depth, variant: None });
            // A sequence's format variants sit right under it, indented (one click away from the Program popup).
            if let BinItem::Sequence(id) = i
                && let Some(t) = model.project().timeline(*id)
            {
                for v in &t.variants {
                    out.push(ListRow { item_ref: i.item_ref(), depth: depth + 1, variant: Some(v.id) });
                }
            }
            if let BinItem::Bin(b) = i
                && self.expanded.contains(&b.id)
            {
                self.add_rows(model, &model.children(b), depth + 1, out);
            }
        }
    }

    /// The clickable items in display order: the list rows, or the grid's tiles.
    fn items(&self, model: &ProjectPanelModel) -> Vec<BinItemRef> {
        if self.settings.view_mode == ViewMode::List {
            self.rows(model).iter().map(|r| r.item_ref).collect()
        } else {
            self.grid_items(model)
        }
    }

    /// The scrolling content under the header, the search row and the column header or path row.
    fn list_rect(&self, model: &ProjectPanelModel) -> CGRect {
        let top = self.chrome_height(model);
        let bottom = self.health_rect(model).map_or(0.0, |r| r.height);
        CGRect::new(
            self.frame.min_x(),
            self.frame.min_y() + top,
            self.frame.width,
            (self.frame.height - top - bottom).max(0.0),
        )
    }

    fn row_rect(&mut self, model: &ProjectPanelModel, i: usize) -> CGRect {
        let scroll = self.scroll();
        CGRect::new(
            self.frame.min_x(),
            self.list_rect(model).min_y() + i as f64 * Self::ROW_HEIGHT - scroll,
            self.frame.width,
            Self::ROW_HEIGHT,
        )
    }

    /// The row under `p`.
    pub fn row_at(&mut self, model: &ProjectPanelModel, p: CGPoint) -> Option<usize> {
        let lr = self.list_rect(model);
        if self.settings.view_mode != ViewMode::List || !lr.contains(p) {
            return None;
        }
        let i = ((p.y - lr.min_y() + self.scroll()) / Self::ROW_HEIGHT).floor() as i64;
        usize::try_from(i).ok().filter(|i| *i < self.rows(model).len())
    }

    /// Index into the items under `p`.
    fn item_at(&mut self, model: &ProjectPanelModel, p: CGPoint) -> Option<usize> {
        if self.settings.view_mode == ViewMode::List { self.row_at(model, p) } else { self.tile_at(model, p) }
    }

    fn content_height(&self, model: &ProjectPanelModel) -> f64 {
        if self.settings.view_mode == ViewMode::List {
            self.rows(model).len() as f64 * Self::ROW_HEIGHT
        } else {
            self.grid_height(model)
        }
    }

    /// Opens or closes a folder.
    pub fn toggle(&mut self, id: Id) {
        if !self.expanded.remove(&id) {
            self.expanded.insert(id);
        }
    }

    /// Find: opens the bins that hold `refs` (parents first) and selects them.
    pub fn reveal_items(&mut self, refs: Vec<BinItemRef>, root: &Bin) {
        for r in &refs {
            let mut up = root.parent_of(*r);
            while let Some(b) = up.filter(|b| *b != root.id) {
                self.expanded.insert(b);
                up = root.parent_of(BinItemRef::Bin(b));
            }
        }
        self.selection = refs;
    }

    // MARK: Events

    /// Clicks, wheel, Delete, Return (rename), typing into the search row. `scale` turns pixels into points.
    pub fn handle(&mut self, cx: &mut ProjectListCx, e: &InputEvent, scale: f32) -> bool {
        let k = f64::from(scale.max(0.01));
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x) / k, f64::from(y) / k);
        let lr = self.list_rect(cx.model);
        let content = self.content_height(cx.model);
        if self.scroll_body.scroller_event(e, scale, lr, content, cx.now) {
            return true;
        }
        match *e {
            InputEvent::MouseDown { x, y, modifiers: m } => {
                let p = pt(x, y);
                let secondary = m.contains(InputModifiers::SECONDARY);
                if !secondary && self.strip_click(cx, p) {
                    self.end_search_editing();
                    self.press = None;
                    return true;
                }
                self.has_focus = self.frame.contains(p);
                if !self.has_focus || !self.search_rect(cx.model).contains(p) {
                    self.end_search_editing();
                }
                if !self.has_focus {
                    return false;
                }
                if self.health_click(cx, p) || self.chrome_click(cx, p, m) {
                    self.press = None;
                    return true;
                }
                crate::shell_log::info(&format!(
                    "project list press at {:.0},{:.0} pt: item {:?}",
                    p.x,
                    p.y,
                    self.item_at(cx.model, p)
                ));
                self.click(cx, p, m);
                self.press = if secondary || self.item_at(cx.model, p).is_none() { None } else { Some(p) };
                true
            }
            InputEvent::MouseDragged { x, y, .. } => {
                if self.size_slider_dragging {
                    self.set_thumb_size_at(cx, f64::from(x) / k);
                    return true;
                }
                if self.column_press.is_some() {
                    self.drag_column(cx, f64::from(x) / k);
                    return true;
                }
                let Some(start) = self.press else { return false };
                let p = pt(x, y);
                if !self.is_dragging {
                    if (p.x - start.x).hypot(p.y - start.y) < Self::DRAG_SLOP || self.selection.is_empty() {
                        return true;
                    }
                    self.is_dragging = true;
                    self.last_click = None;
                }
                self.move_target = self.compute_move_target(cx, p, &self.selection.clone());
                let drag = self.drag_refs();
                if !drag.is_empty() {
                    // The chip stays over a folder too, so a drop there can settle it onto the row.
                    self.show_drag_preview(cx, p);
                    if self.move_target.is_none() {
                        self.events.push(ProjectListEvent::Drag { refs: drag, phase: DragPhase::Moved, x, y });
                    }
                } else {
                    cx.ui.clear_drag();
                }
                true
            }
            InputEvent::MouseUp { x, y } => {
                if self.size_slider_dragging {
                    self.size_slider_dragging = false;
                    return true;
                }
                if self.column_press.is_some() {
                    self.end_column_press(cx, f64::from(x) / k);
                    return true;
                }
                if self.press.is_none() {
                    return false;
                }
                self.press = None;
                if self.is_dragging {
                    self.is_dragging = false;
                    let target = self.move_target.take();
                    // Dropped in the panel: the chip settles onto the folder row or the insertion line, not just vanishes.
                    match &target {
                        Some(t) => cx.ui.drop_drag(CGPoint { x: t.cue.mid_x(), y: t.cue.mid_y() }),
                        None => cx.ui.clear_drag(),
                    }
                    let drag = self.drag_refs();
                    // Dropped on a folder or between rows of the panel: the items move there (the host sees a canceled drag).
                    if let Some(t) = target {
                        self.drop_move(cx, &self.selection.clone(), &t);
                        if !drag.is_empty() {
                            self.events.push(ProjectListEvent::Drag { refs: drag, phase: DragPhase::Canceled, x, y });
                        }
                    } else if !drag.is_empty() {
                        self.events.push(ProjectListEvent::Drag { refs: drag, phase: DragPhase::Ended, x, y });
                    }
                }
                true
            }
            InputEvent::Scroll { x, y, dx, dy, .. } => {
                if !self.frame.contains(pt(x, y)) {
                    return false;
                }
                let max_scroll = (content - lr.height).max(0.0);
                self.scroll_body.wheel(cx.ui.gesture, dx, dy, k, max_scroll, lr.height, cx.now);
                true
            }
            InputEvent::KeyDown { key: InputKey::Escape, .. } if self.is_dragging => {
                self.press = None;
                self.is_dragging = false;
                self.move_target = None;
                cx.ui.clear_drag();
                let drag = self.drag_refs();
                if !drag.is_empty() {
                    self.events.push(ProjectListEvent::Drag { refs: drag, phase: DragPhase::Canceled, x: 0.0, y: 0.0 });
                }
                true
            }
            InputEvent::KeyDown { key, modifiers } => {
                if self.search.is_editing() {
                    self.search_key(cx, key, modifiers);
                    return true;
                }
                if !self.has_focus || self.selection.is_empty() {
                    return false;
                }
                match key {
                    InputKey::Delete | InputKey::Backspace => {
                        self.delete_selection(cx);
                        true
                    }
                    InputKey::Enter => {
                        if self.selection.len() == 1 {
                            self.events.push(ProjectListEvent::Rename(self.selection[0]));
                        }
                        true
                    }
                    _ => false,
                }
            }
            InputEvent::MouseMoved { x, y } => {
                let p = pt(x, y);
                self.health_hover = self.health_part(cx, p);
                self.hover_row = self.row_at(cx.model, p);
                self.scrub = self.scrub_state(cx, p);
                let tip = self.item_tip(cx, p);
                cx.ui.hover.offer_tip(tip.as_deref());
                false
            }
        }
    }

    /// What a drag carries: the selected media and sequences (folders do not drag onto the timeline).
    fn drag_refs(&self) -> Vec<BinItemRef> {
        self.selection.iter().copied().filter(|r| !matches!(r, BinItemRef::Bin(_))).collect()
    }

    /// The chip at the pointer from the first move of the drag: the first item's name and kind icon (and the count for several).
    fn show_drag_preview(&self, cx: &mut ProjectListCx, p: CGPoint) {
        let drag = self.drag_refs();
        let Some(first) = drag.first().copied() else { return };
        let kind = cx.model.item_kind(first);
        let nested = kind == sq_editor_session::ProjectItemKind::NestedSequence;
        let symbol =
            ProjectItemIcon::icon(if nested { sq_editor_session::ProjectItemKind::Sequence } else { kind }, false)
                .symbol;
        let name = cx.model.display_name(first);
        let title = if drag.len() > 1 { format!("{name} +{}", drag.len() - 1) } else { name };
        cx.ui.show_drag(&title, SQIcon::from_raw(symbol).unwrap_or(SQIcon::Unknown), p);
    }

    fn click(&mut self, cx: &mut ProjectListCx, p: CGPoint, m: InputModifiers) {
        let list = self.items(cx.model);
        let secondary = m.contains(InputModifiers::SECONDARY);
        let Some(i) = self.item_at(cx.model, p) else {
            if !secondary {
                self.selection.clear();
            } else {
                self.present_menu(cx, p);
            }
            return;
        };
        let item = list[i];
        let rows = if self.settings.view_mode == ViewMode::List { self.rows(cx.model) } else { Vec::new() };
        if let (Some(row), BinItemRef::Sequence(sid)) = (rows.get(i), item)
            && let Some(v) = row.variant
        {
            // A variant row selects nothing (no drag, no delete of its sequence); a double-click opens it.
            self.selection.clear();
            if secondary {
                return;
            }
            let t = cx.now;
            self.variant_selection = Some(v);
            let last = self.last_click.replace((item, Some(v), t));
            if let Some((r, lv, lt)) = last
                && r == item
                && lv == Some(v)
                && t - lt < Self::DOUBLE_CLICK
            {
                self.last_click = None;
                self.events.push(ProjectListEvent::OpenVariant(sid, v));
            }
            return;
        }
        self.variant_selection = None;
        if m.contains(InputModifiers::COMMAND) {
            if let Some(at) = self.selection.iter().position(|r| *r == item) {
                self.selection.remove(at);
            } else {
                self.selection.push(item);
            }
        } else if m.contains(InputModifiers::SHIFT)
            && let Some(anchor) = self.selection.last()
            && let Some(a) = list.iter().position(|r| r == anchor)
        {
            // Variant rows repeat their sequence's ref; keep each item once.
            let mut seen = BTreeSet::new();
            self.selection = list[a.min(i)..=a.max(i)].iter().copied().filter(|r| seen.insert(*r)).collect();
        } else if !(secondary && self.selection.contains(&item)) {
            self.selection = vec![item];
        }
        if secondary {
            self.present_menu(cx, p);
            return;
        }
        // The disclosure arrow sits before a folder's chip.
        if let (Some(row), BinItemRef::Bin(id)) = (rows.get(i), item)
            && p.x < self.frame.min_x() + Self::NAME_LEAD + Self::indent(row.depth + 1)
        {
            self.toggle(id);
            return;
        }
        let t = cx.now;
        let last = self.last_click.replace((item, None, t));
        if let Some((r, lv, lt)) = last
            && r == item
            && lv.is_none()
            && t - lt < Self::DOUBLE_CLICK
        {
            self.last_click = None;
            self.open(cx, item);
        }
    }

    /// Double-click or Open: a folder opens, a sequence and a media item go to the host.
    pub fn open(&mut self, cx: &mut ProjectListCx, r: BinItemRef) {
        match r {
            BinItemRef::Bin(id) => {
                if self.settings.view_mode == ViewMode::Icons {
                    self.enter(cx.model, id);
                } else {
                    self.toggle(id);
                }
            }
            BinItemRef::Sequence(id) => self.events.push(ProjectListEvent::OpenSequence(id)),
            BinItemRef::Media(id) => self.events.push(ProjectListEvent::OpenMedia(id)),
        }
    }

    // MARK: Menu and actions (ProjectPanelMenus.items: the Mac `ProjectPanelView.menuItems` rows and context)

    fn present_menu(&mut self, cx: &mut ProjectListCx, at: CGPoint) {
        let items = self.menu(cx);
        self.events.push(ProjectListEvent::PresentMenu { items, at, anchor: None });
    }

    /// The right-click menu for the current selection (empty = the empty-area menu), built as the Mac panel builds it.
    pub fn menu(&mut self, cx: &mut ProjectListCx) -> Vec<SQMenuItem> {
        let targets = self.selection.clone();
        let project = cx.model.project();
        let media: Vec<Id> =
            targets.iter().filter_map(|t| if let BinItemRef::Media(id) = t { Some(*id) } else { None }).collect();
        let non_bin: Vec<BinItemRef> = targets.iter().copied().filter(|t| !matches!(t, BinItemRef::Bin(_))).collect();
        let mut labels: Vec<LabelColor> = Vec::new();
        for t in &non_bin {
            let l = cx.model.label(*t);
            if !labels.contains(&l) {
                labels.push(l);
            }
        }
        let counts: Vec<Option<i64>> = media
            .iter()
            .map(|id| {
                project.media(*id).and_then(|r| r.info.as_ref()?.audio.as_ref().map(|a| a.mappable_channels(&r.path)))
            })
            .collect();
        let same_channels = counts.iter().all(|c| *c == counts.first().copied().flatten().map(Some).unwrap_or(None));
        let mut c = ProjectMenuContext {
            media: media.clone(),
            has_bin: targets.iter().any(|t| matches!(t, BinItemRef::Bin(_))),
            has_sequence: targets.iter().any(|t| matches!(t, BinItemRef::Sequence(_))),
            target_count: targets.len(),
            all_media_online: !media.is_empty() && media.iter().all(|m| !cx.model.is_offline(*m)),
            single_media_offline: media.len() == 1 && cx.model.is_offline(media[0]),
            single_media_has_poster: media.len() == 1
                && project.media(media[0]).is_some_and(|m| m.poster_time.is_some()),
            single_media_has_marks: media.len() == 1 && !project.source_marks_for(media[0]).is_empty(),
            shared_label: if labels.len() == 1 { labels.first().copied() } else { None },
            first_label: non_bin.first().map(|t| cx.model.label(*t)),
            has_non_bin_target: !non_bin.is_empty(),
            is_icon_view: self.settings.view_mode == ViewMode::Icons,
            can_go_up: cx.model.browse_bin() != project.root_bin.id,
            hover_scrub: self.settings.hover_scrub,
            ..ProjectMenuContext::default()
        };
        let q = Rc::clone(&self.queue);
        let t2 = targets.clone();
        let pick: Rc<dyn Fn(Option<sq_core_model::PixelAspect>)> =
            Rc::new(move |a| q.borrow_mut().push(ListAction::Menu(ProjectMenuAction::SetPixelAspect(a), t2.clone())));
        let q = Rc::clone(&self.queue);
        let t3 = targets.clone();
        let custom: Rc<dyn Fn()> =
            Rc::new(move || q.borrow_mut().push(ListAction::Menu(ProjectMenuAction::CustomPixelAspect, t3.clone())));
        c.pixel_aspect_rows =
            PixelAspectChoices::state(project, &media).map(|s| PixelAspectChoices::items(&s, pick, custom));
        if same_channels && let Some(first) = counts.first().copied() {
            c.audio_channels = first.unwrap_or(0);
        }
        c.deinterlace = cx.model.deinterlace_state(&media);
        c.any_media_used = media.iter().any(|m| !project.sequence_names_using(*m).is_empty());
        c.can_fill_reel = cx.session.reel_slot_count() > 0;
        let q = Rc::clone(&self.queue);
        let t4 = targets;
        let map = sq_uikit::command_map::CommandMap::premiere_default();
        let run: sq_editor_session::MenuRun = Rc::new(move |a| q.borrow_mut().push(ListAction::Menu(a, t4.clone())));
        ProjectPanelMenus::items(&c, &|cmd| ProjectPanelMenus::shortcut(cmd, &map), run)
    }

    /// Performs the rows picked in a menu (call after the menu closed).
    pub fn run_queued(&mut self, cx: &mut ProjectListCx) {
        let queued: Vec<ListAction> = self.queue.borrow_mut().drain(..).collect();
        for a in queued {
            match a {
                ListAction::Menu(ProjectMenuAction::ToggleColumn(c), _) => self.toggle_column(c),
                ListAction::Menu(ProjectMenuAction::ResetColumns, _) => self.reset_columns(),
                ListAction::Menu(a, targets) => self.run(cx, a, &targets),
                ListAction::SetViewMode(m) => self.set_view_mode(cx.model, m),
                ListAction::ToggleSearch => self.toggle_search(cx.model),
                ListAction::SetFilter(f) => cx.model.set_media_filter(f),
                ListAction::ToggleSpoken => {
                    let on = !cx.model.search_spoken();
                    cx.model.set_search_spoken(on);
                }
                ListAction::SaveFilter => self.save_filter_as_smart_folder(cx),
                ListAction::ToggleSmart(id) => {
                    let next = if cx.model.active_smart_bin() == Some(id) { None } else { Some(id) };
                    cx.model.set_active_smart_bin(next);
                    if self.settings.view_mode == ViewMode::Icons {
                        let root = cx.model.project().root_bin.id;
                        cx.model.set_browse_bin(root);
                        cx.model.set_current_bin(root);
                    }
                }
                ListAction::DeleteSmart(id) => {
                    cx.model.remove_smart_bin(cx.session, id);
                }
                ListAction::ShowMissing => cx.model.set_media_filter(MediaFilter::Offline),
                ListAction::Reconnect => self.events.push(ProjectListEvent::Reconnect),
                ListAction::Collect => self.events.push(ProjectListEvent::Collect),
            }
        }
    }

    /// The Mac `ProjectPanelView.run`: what each menu row does with the clicked items.
    pub fn run(&mut self, cx: &mut ProjectListCx, action: ProjectMenuAction, targets: &[BinItemRef]) {
        use ProjectMenuAction as A;
        let media: Vec<Id> =
            targets.iter().filter_map(|t| if let BinItemRef::Media(id) = t { Some(*id) } else { None }).collect();
        let sequences: Vec<Id> =
            targets.iter().filter_map(|t| if let BinItemRef::Sequence(id) = t { Some(*id) } else { None }).collect();
        match action {
            A::NewFolder => self.new_folder(cx),
            A::GoUp => self.go_up(cx.model),
            A::ToggleHoverScrub => {
                // The Mac context menu switches without a status line (`ProjectListView.perform`).
                let on = !self.settings.hover_scrub;
                self.set_hover_scrub(on);
            }
            A::OpenInSource => {
                if let Some(id) = media.first() {
                    self.events.push(ProjectListEvent::OpenMedia(*id));
                }
            }
            A::OpenInTimeline => {
                if let Some(id) = sequences.first() {
                    self.events.push(ProjectListEvent::OpenSequence(*id));
                }
            }
            A::SequenceFromClip => {
                if let Some(id) = media.first() {
                    cx.session.new_sequence_from_media(*id);
                }
            }
            A::MakeSubclip => {
                if let Some(id) = media.first()
                    && cx.session.make_subclip(*id, None).is_none()
                    && let Some(e) = cx.session.last_error()
                {
                    self.events.push(ProjectListEvent::Flash(e.to_string()));
                }
            }
            A::Rename => {
                if targets.len() == 1 {
                    self.events.push(ProjectListEvent::Rename(targets[0]));
                }
            }
            A::DeletePoster => {
                cx.model.set_poster(cx.session, None, targets);
            }
            A::Delete => self.delete_selection(cx),
            A::ClearUsedMedia => {
                let r = cx.model.clear(cx.session, targets);
                if let Some(m) = r.message() {
                    self.events.push(ProjectListEvent::Message(ProjectPanelModel::delete_name(targets).to_string(), m));
                }
                if r.changed {
                    self.selection.clear();
                }
            }
            A::ExtractAudio => {
                if let Some(id) = media.first() {
                    self.events.push(ProjectListEvent::ExtractAudio(*id));
                }
            }
            A::ConformToConstantFrameRate => {
                let ids: Vec<Id> = media
                    .iter()
                    .copied()
                    .filter(|id| {
                        cx.model
                            .project()
                            .media(*id)
                            .is_some_and(sq_editor_session::ConstantFrameRateConform::is_eligible)
                    })
                    .collect();
                if !ids.is_empty() {
                    self.events.push(ProjectListEvent::ConformToConstantFrameRate(ids));
                }
            }
            A::SetPixelAspect(a) => {
                cx.model.set_pixel_aspect(cx.session, a, targets);
            }
            A::SetDeinterlace(on) => {
                cx.model.set_deinterlace(cx.session, on, targets);
            }
            A::SetLabel(l) => {
                cx.model.set_label(cx.session, l, targets);
            }
            A::SelectLabelGroup(l) => self.selection = cx.model.project().items_with_label(l),
            A::SetAudioChannels(m) => {
                cx.model.set_audio_channels(cx.session, m.as_ref(), targets);
            }
            // the column header's own menu (Chrome)
            A::ToggleColumn(_) | A::ResetColumns => {}
            other => self.events.push(ProjectListEvent::Host(other, targets.to_vec())),
        }
    }

    /// New Folder in the selected folder, or at the top.
    pub fn new_folder(&mut self, cx: &mut ProjectListCx) {
        let model = &mut *cx.model;
        if let (Some(BinItemRef::Bin(id)), 1) = (self.selection.first().copied(), self.selection.len()) {
            model.set_current_bin(id);
            self.expanded.insert(id);
        } else {
            let to = if self.settings.view_mode == ViewMode::Icons {
                model.browse_bin()
            } else {
                model.project().root_bin.id
            };
            model.set_current_bin(to);
        }
        if let Some(id) = model.new_bin(cx.session, "New Folder") {
            self.selection = vec![BinItemRef::Bin(id)];
        }
    }

    /// Sets the label of the selected media and sequences.
    pub fn set_label(&mut self, cx: &mut ProjectListCx, l: Option<LabelColor>) {
        let refs: Vec<BinItemRef> =
            self.selection.iter().copied().filter(|r| !matches!(r, BinItemRef::Bin(_))).collect();
        cx.model.set_label(cx.session, l, &refs);
    }

    /// Removes the selected items.
    pub fn delete_selection(&mut self, cx: &mut ProjectListCx) {
        if self.selection.is_empty() {
            return;
        }
        let sel = self.selection.clone();
        let r = cx.model.delete(cx.session, &sel);
        if let Some(msg) = r.message() {
            self.events.push(ProjectListEvent::Message(ProjectPanelModel::delete_name(&sel).to_string(), msg));
        }
        if r.changed {
            self.selection.clear();
        }
    }

    /// The answer of the Rename dialog.
    pub fn rename_to(&mut self, cx: &mut ProjectListCx, r: BinItemRef, name: &str) {
        let t = name.trim_matches(|c| c == ' ' || c == '\t');
        if !t.is_empty() {
            cx.model.rename(cx.session, r, t);
        }
    }
}

// MARK: Chrome (ProjectListView+Chrome.swift)

struct StripRects {
    more: CGRect,
    folder: CGRect,
    count: f64,
}

impl ProjectListView {
    fn right_aligned(c: Column) -> bool {
        c == Column::Duration || c == Column::FrameRate
    }

    /// The header row is gone while the dock's tab strip carries the item count, New Folder and "..." (Mac `TabStrip`).
    fn header_rect(&self) -> CGRect {
        CGRect::new(
            self.frame.min_x(),
            self.frame.min_y(),
            self.frame.width,
            if self.strip.is_none() { Self::HEADER_HEIGHT } else { 0.0 },
        )
    }

    /// The strip tools of the Project tab: "..." at the right end, New Folder left of it, the count left of that
    /// (`TabStrip.layout`: 28 pt buttons 2 pt apart, the count label 6 pt wider than its text).
    fn strip_rects(&self) -> Option<StripRects> {
        let s = self.strip?.strip;
        if s.height <= 0.0 {
            return None;
        }
        let h = 22.0;
        let more = CGRect::new(
            s.max_x() - spacing::SM as f64 - Self::STRIP_BUTTON,
            ((s.height - 1.0 - h) / 2.0).round() + s.min_y(),
            Self::STRIP_BUTTON,
            h,
        );
        let folder = CGRect::new(more.x - (Self::STRIP_BUTTON + 2.0), more.y, more.width, more.height);
        Some(StripRects { more, folder, count: folder.min_x() - 2.0 - 6.0 })
    }

    /// A press on the strip tools; true when taken.
    fn strip_click(&mut self, cx: &mut ProjectListCx, p: CGPoint) -> bool {
        let Some(t) = self.strip_rects() else { return false };
        if t.folder.contains(p) {
            self.new_folder(cx);
            return true;
        }
        if t.more.contains(p) {
            let items = self.options_menu(cx);
            self.events.push(ProjectListEvent::PresentMenu {
                items,
                at: CGPoint::new(t.more.min_x(), t.more.max_y()),
                anchor: None,
            });
            return true;
        }
        if let Some(r) = self.size_slider_rect(cx)
            && r.inset_by(-4.0, -4.0).contains(p)
        {
            self.size_slider_dragging = true;
            self.set_thumb_size_at(cx, p.x);
            return true;
        }
        false
    }

    fn search_rect(&self, _model: &ProjectPanelModel) -> CGRect {
        let h = self.header_rect();
        CGRect::new(
            self.frame.min_x(),
            h.max_y(),
            self.frame.width,
            if self.settings.search_visible { Self::SEARCH_ROW_HEIGHT } else { 0.0 },
        )
    }

    fn search_field_rect(&self, model: &ProjectPanelModel) -> CGRect {
        self.search_rect(model).inset_by(spacing::SM as f64, 7.0)
    }

    fn search_clear_rect(&self, model: &ProjectPanelModel) -> CGRect {
        let f = self.search_field_rect(model);
        CGRect::new(f.max_x() - 20.0, f.mid_y() - 8.0, 16.0, 16.0)
    }

    /// Column header (list) or path row (grid inside a folder).
    fn subheader_rect(&self, model: &ProjectPanelModel) -> CGRect {
        let h = if self.settings.view_mode == ViewMode::List {
            Self::COLUMN_HEADER_HEIGHT
        } else if self.is_inside_folder(model) {
            Self::CRUMB_HEIGHT
        } else {
            0.0
        };
        let s = self.search_rect(model);
        CGRect::new(self.frame.min_x(), s.max_y(), self.frame.width, h)
    }

    fn chrome_height(&self, model: &ProjectPanelModel) -> f64 {
        self.subheader_rect(model).max_y() - self.frame.min_y()
    }

    fn options_rect(&self) -> CGRect {
        if let Some(t) = self.strip_rects() {
            return t.more;
        }
        let h = self.header_rect();
        CGRect::new(
            h.max_x() - spacing::SM as f64 - Self::OPTIONS_SIZE,
            h.mid_y() - Self::OPTIONS_SIZE / 2.0,
            Self::OPTIONS_SIZE,
            Self::OPTIONS_SIZE,
        )
    }

    /// The thumbnail size slider in the header, icon grid only (the Mac `sizeSlider`), left of the item count.
    fn size_slider_rect(&self, cx: &ProjectListCx) -> Option<CGRect> {
        if self.settings.view_mode != ViewMode::Icons {
            return None;
        }
        let w = cx.measure.width(&Self::item_count_text(self, cx.model), 11.0, 0);
        if let Some(t) = self.strip_rects() {
            // The slider sits left of the count in the strip, as in Swift `ProjectListView+Chrome` (the Mac panel keeps it on the path row).
            return Some(CGRect::new(
                t.count - w - spacing::MD as f64 - Self::SIZE_SLIDER_WIDTH,
                t.more.mid_y() - 8.0,
                Self::SIZE_SLIDER_WIDTH,
                16.0,
            ));
        }
        let right = self.options_rect().min_x() - spacing::SM as f64 - w - spacing::MD as f64;
        Some(CGRect::new(
            right - Self::SIZE_SLIDER_WIDTH,
            self.header_rect().mid_y() - 8.0,
            Self::SIZE_SLIDER_WIDTH,
            16.0,
        ))
    }

    /// "8 items" (the Mac `ProjectPanelView.itemCountText`): every sequence and clip in the project, or what the open
    /// folder holds in icon view; folders do not count.
    pub fn item_count_text(&self, model: &ProjectPanelModel) -> String {
        let n = if self.settings.view_mode == ViewMode::Icons {
            let bin = model.project().bin(model.browse_bin()).unwrap_or(&model.project().root_bin);
            model.children(bin).len()
        } else {
            model.project().root_bin.all_refs().iter().filter(|r| !matches!(r, BinItemRef::Bin(_))).count()
        };
        if n == 1 { "1 item".to_string() } else { format!("{n} items") }
    }

    fn set_thumb_size_at(&mut self, cx: &ProjectListCx, x: f64) {
        let Some(r) = self.size_slider_rect(cx) else { return };
        let f = InspectorDraw::slider_fraction(x, r);
        self.set_thumb_size((Self::THUMB_RANGE.0 + f * (Self::THUMB_RANGE.1 - Self::THUMB_RANGE.0)).round());
    }

    /// The View > Project Panel rows and View > Hover Scrub (`ShellViewCommands`): the status line to flash, if any.
    /// Thumbnails step 16 points, icon view only (the Mac `stepThumbnailSize`).
    pub fn run_view_command(
        &mut self,
        model: &mut ProjectPanelModel,
        c: sq_uikit::editor_command::EditorCommand,
    ) -> Option<String> {
        use sq_uikit::editor_command::EditorCommand as C;
        match c {
            C::ProjectListView => self.set_view_mode(model, ViewMode::List),
            C::ProjectIconView => self.set_view_mode(model, ViewMode::Icons),
            C::ToggleHoverScrub => {
                let on = !self.settings.hover_scrub;
                self.set_hover_scrub(on);
                return Some(SQL10n::string(if on { "Hover Scrub on" } else { "Hover Scrub off" }));
            }
            C::ProjectThumbnailSmaller | C::ProjectThumbnailLarger if self.settings.view_mode == ViewMode::Icons => {
                let step = if c == C::ProjectThumbnailLarger { 16.0 } else { -16.0 };
                self.set_thumb_size((self.settings.thumb_size + step).clamp(Self::THUMB_RANGE.0, Self::THUMB_RANGE.1));
            }
            _ => {}
        }
        None
    }

    /// Icon grid thumbnail width.
    pub fn set_thumb_size(&mut self, v: f64) {
        self.settings.thumb_size = v;
        self.events.push(ProjectListEvent::SettingsChanged);
    }

    fn is_inside_folder(&self, model: &ProjectPanelModel) -> bool {
        model.browse_bin() != model.project().root_bin.id
    }

    // MARK: View mode, search, columns

    /// Switches between the list and the icon grid.
    pub fn set_view_mode(&mut self, model: &mut ProjectPanelModel, mode: ViewMode) {
        if mode == self.settings.view_mode {
            return;
        }
        self.settings.view_mode = mode;
        self.events.push(ProjectListEvent::SettingsChanged);
        // The grid shows one folder at a time; it starts at the top (the Mac `setViewMode`).
        if mode == ViewMode::Icons {
            let root = model.project().root_bin.id;
            model.set_browse_bin(root);
            model.set_current_bin(root);
        }
        self.set_scroll(0.0);
    }

    /// Shows or hides the search row (kept per user); hiding clears the search, showing puts the cursor in the field.
    pub fn toggle_search(&mut self, model: &mut ProjectPanelModel) {
        self.settings.search_visible = !self.settings.search_visible;
        self.events.push(ProjectListEvent::SettingsChanged);
        if self.settings.search_visible {
            self.search.mouse_down(None, 1);
            self.has_focus = true;
        } else {
            self.search.cancel();
            self.set_search_text(model, "");
            // The Mac also drops the filter chips and the grouping when the search row closes.
            model.set_filter_tokens(Vec::new());
            model.set_grouping(sq_core_project::media_grouping::MediaGrouping::Folders);
        }
    }

    /// The text of the search field.
    pub fn search_text(&self) -> String {
        self.search.editor().map_or_else(|| self.search.text.clone(), |e| e.string())
    }

    fn set_search_text(&mut self, model: &mut ProjectPanelModel, s: &str) {
        self.search.cancel();
        self.search.text = s.to_string();
        model.set_search_text(s);
        self.set_scroll(0.0);
    }

    fn search_key(&mut self, cx: &mut ProjectListCx, k: InputKey, m: InputModifiers) {
        if k == InputKey::Escape {
            // Esc clears the field first, then leaves it.
            if self.search_text().is_empty() {
                self.search.cancel();
            } else {
                self.set_search_text(cx.model, "");
                self.search.mouse_down(None, 1);
            }
            return;
        }
        let _ = self.search.key(k, m, cx.ui);
        let t = self.search_text();
        cx.model.set_search_text(&t);
        self.set_scroll(0.0);
    }

    fn end_search_editing(&mut self) {
        if self.search.is_editing() {
            let _ = self.search.commit();
        }
    }

    /// Shows or hides a column.
    pub fn toggle_column(&mut self, c: Column) {
        self.settings.columns.toggle(c);
        self.events.push(ProjectListEvent::SettingsChanged);
    }

    /// Back to the default columns.
    pub fn reset_columns(&mut self) {
        self.settings.columns = ProjectColumnLayout::defaults();
        self.events.push(ProjectListEvent::SettingsChanged);
    }

    /// View > Hover Scrub: switches it; the app keeps the choice in the user's settings.
    pub fn set_hover_scrub(&mut self, on: bool) {
        self.settings.hover_scrub = on;
        if !on {
            self.scrub = None;
        }
        self.events.push(ProjectListEvent::SettingsChanged);
    }

    /// The column picker (`ProjectPanelMenus.headerItems`): every column but Name, checked when shown, then Reset Columns.
    pub fn column_menu(&self) -> Vec<SQMenuItem> {
        let q = Rc::clone(&self.queue);
        let run: sq_editor_session::MenuRun = Rc::new(move |a| q.borrow_mut().push(ListAction::Menu(a, Vec::new())));
        let columns = self.settings.columns.clone();
        ProjectPanelMenus::header_items(&|c| columns.is_visible(c), run)
    }

    /// The header's "..." menu (`ProjectPanelView.showOptions`): import and creation, the view mode, search, the media filter.
    pub fn options_menu(&mut self, cx: &mut ProjectListCx) -> Vec<SQMenuItem> {
        let q = Rc::clone(&self.queue);
        let row = |title: &str, checked: bool, a: ListAction| {
            let q = Rc::clone(&q);
            let mut i = SQMenuItem::new(title);
            i.is_checked = checked;
            i.action = Some(Rc::new(move || q.borrow_mut().push(a.clone())));
            i
        };
        let menu = |a: ProjectMenuAction| ListAction::Menu(a, Vec::new());
        let mode = self.settings.view_mode;
        let mut rows = vec![
            row("Import…", false, menu(ProjectMenuAction::ImportMedia)),
            row("New Folder", false, ListAction::Menu(ProjectMenuAction::NewFolder, Vec::new())),
            row("New Color Matte…", false, menu(ProjectMenuAction::NewColorMatte)),
            SQMenuItem::separator(),
            row("as List", mode == ViewMode::List, ListAction::SetViewMode(ViewMode::List)),
            row("as Icons", mode == ViewMode::Icons, ListAction::SetViewMode(ViewMode::Icons)),
            SQMenuItem::separator(),
            row("Search", self.settings.search_visible, ListAction::ToggleSearch),
            SQMenuItem::separator(),
        ];
        for f in MediaFilter::ALL {
            rows.push(row(f.title(), cx.model.media_filter() == f, ListAction::SetFilter(f)));
        }
        rows.extend(self.smart_folder_rows(cx.model));
        rows
    }
}

impl ProjectListView {
    /// The Mac `smartBinMenuItems`: Search Spoken Words, Save Filter as Smart Folder, one checked row per saved smart folder
    /// (a click shows its media, a second click returns to the folders), then a Delete row for each.
    fn smart_folder_rows(&self, model: &ProjectPanelModel) -> Vec<SQMenuItem> {
        let row = |title: &str, checked: bool, a: ListAction| {
            let q = Rc::clone(&self.queue);
            let mut i = SQMenuItem::new(title);
            i.is_checked = checked;
            i.action = Some(Rc::new(move || q.borrow_mut().push(a.clone())));
            i
        };
        let mut rows = vec![SQMenuItem::separator()];
        rows.push(row("Search Spoken Words", model.search_spoken(), ListAction::ToggleSpoken));
        rows.push(row("Save Filter as Smart Folder", false, ListAction::SaveFilter));
        for sb in model.project().smart_bin_list() {
            rows.push(row(&sb.name, model.active_smart_bin() == Some(sb.id), ListAction::ToggleSmart(sb.id)));
        }
        for sb in model.project().smart_bin_list() {
            rows.push(row(&format!("Delete Smart Folder \"{}\"", sb.name), false, ListAction::DeleteSmart(sb.id)));
        }
        rows
    }

    /// Saves the search text and the Unused / Offline choice as a smart folder named after them (the Mac
    /// `saveFilterAsSmartBin`: a taken name gets " 2", " 3" ...).
    fn save_filter_as_smart_folder(&mut self, cx: &mut ProjectListCx) {
        let model = &mut *cx.model;
        let q = model.search_text().trim_matches(|c| c == ' ' || c == '\t').to_string();
        let base = if q.is_empty() { model.media_filter().title().to_string() } else { q };
        let taken: BTreeSet<String> = model.project().smart_bin_list().iter().map(|s| s.name.clone()).collect();
        let (mut name, mut n) = (base.clone(), 2);
        while taken.contains(&name) {
            name = format!("{base} {n}");
            n += 1;
        }
        let id = cx.ids.next_id();
        let bin = model.current_filter_as_smart_bin(id, &name);
        model.add_smart_bin(cx.session, bin);
    }

    /// The column frames of the list: Name takes what the other columns leave (at least its minimum); columns that do not
    /// fit any more drop from the right. Automatic widths follow `ProjectColumnSizing`: the widest text plus padding.
    /// Columns resize and move by dragging the header (see `begin_column_press`); no horizontal scrolling.
    pub fn column_frames(&self, cx: &ProjectListCx, refs: Option<&[BinItemRef]>) -> Vec<ColumnFrame> {
        let owned;
        let list: &[BinItemRef] = match refs {
            Some(r) => r,
            None => {
                owned = self.rows(cx.model).iter().map(|r| r.item_ref).collect::<Vec<_>>();
                &owned
            }
        };
        let mut others: Vec<Column> =
            self.settings.columns.visible().iter().copied().filter(|c| *c != Column::Name).collect();
        let width = |c: Column| -> f64 {
            if let Some(w) = self.settings.columns.user_width(c) {
                return w;
            }
            let mut content: f64 = 0.0;
            for r in list.iter().take(200) {
                content = content.max(cx.measure.width(&cx.model.cell_text(c, *r), Self::LIST_FONT, 0));
            }
            let header = cx.measure.width(c.title(), 11.0, 0);
            let w = (content + 2.0 * Self::CELL_INSET)
                .max(header + 2.0 * Self::CELL_PAD + ProjectColumnSizing::HEADER_EXTRA);
            w.max(c.min_width()).min(if c == Column::FilePath { 360.0 } else { 150.0 })
        };
        let mut widths: Vec<f64> = others.iter().map(|c| width(*c)).collect();
        let end = self.frame.max_x();
        while !others.is_empty() && end - widths.iter().sum::<f64>() - self.frame.min_x() < Column::Name.min_width() {
            others.pop();
            widths.pop();
        }
        let mut x = end - widths.iter().sum::<f64>();
        let mut out = vec![ColumnFrame { column: Column::Name, min_x: self.frame.min_x(), max_x: x }];
        for (c, w) in others.into_iter().zip(widths) {
            out.push(ColumnFrame { column: c, min_x: x, max_x: x + w });
            x += w;
        }
        out
    }

    // MARK: Chrome events

    /// A press on the header, the search row or the column header / path row. True when taken.
    fn chrome_click(&mut self, cx: &mut ProjectListCx, p: CGPoint, m: InputModifiers) -> bool {
        if p.y >= self.list_rect(cx.model).min_y() {
            return false;
        }
        let o = self.options_rect();
        if o.inset_by(-2.0, -2.0).contains(p) {
            let items = self.options_menu(cx);
            self.events.push(ProjectListEvent::PresentOptionsMenu { items, at: CGPoint::new(o.min_x(), o.max_y()) });
            return true;
        }
        if let Some(r) = self.size_slider_rect(cx)
            && r.inset_by(-4.0, -4.0).contains(p)
        {
            self.size_slider_dragging = true;
            self.set_thumb_size_at(cx, p.x);
            return true;
        }
        if self.header_rect().contains(p) {
            return true;
        }
        if self.search_rect(cx.model).contains(p) {
            if !self.search_text().is_empty() && self.search_clear_rect(cx.model).contains(p) {
                self.set_search_text(cx.model, "");
                return true;
            }
            if self.search_field_rect(cx.model).contains(p) {
                self.search.mouse_down(None, 1);
            }
            return true;
        }
        if !self.subheader_rect(cx.model).contains(p) {
            return true;
        }
        if self.settings.view_mode == ViewMode::Icons {
            self.go_up(cx.model);
            return true;
        }
        if m.contains(InputModifiers::SECONDARY) {
            let items = self.column_menu();
            self.events.push(ProjectListEvent::PresentMenu { items, at: p, anchor: None });
            return true;
        }
        self.begin_column_press(cx, p);
        true
    }

    // MARK: Column header presses (ProjectListView+Columns.swift)

    /// The column whose left edge is at `x` (a resize handle), never Name (its left edge is the panel's).
    fn resize_column(&self, cx: &ProjectListCx, x: f64) -> Option<ColumnFrame> {
        self.column_frames(cx, None).into_iter().skip(1).find(|f| (f.min_x - x).abs() <= Self::RESIZE_GRAB)
    }

    fn begin_column_press(&mut self, cx: &ProjectListCx, p: CGPoint) {
        let frames = self.column_frames(cx, None);
        if let Some(f) = self.resize_column(cx, p.x) {
            self.column_press = Some(ColumnPress {
                column: f.column,
                kind: ColumnPressKind::Resize { start_width: f.max_x - f.min_x },
                start_x: p.x,
                dragged: false,
            });
        } else if let Some(f) = frames.iter().find(|f| p.x >= f.min_x && p.x < f.max_x) {
            self.column_press =
                Some(ColumnPress { column: f.column, kind: ColumnPressKind::Move, start_x: p.x, dragged: false });
        }
    }

    fn drag_column(&mut self, _cx: &ProjectListCx, x: f64) {
        let Some(mut press) = self.column_press else { return };
        if !press.dragged && (x - press.start_x).abs() < Self::COLUMN_SLOP {
            return;
        }
        press.dragged = true;
        self.column_press = Some(press);
        if let ColumnPressKind::Resize { start_width } = press.kind {
            // The edge moves with the pointer: dragging left widens the column.
            let w = (start_width + (press.start_x - x)).max(press.column.min_width()).min(Self::MAX_COLUMN_WIDTH);
            self.settings.columns.set_width(w, press.column);
        }
    }

    fn end_column_press(&mut self, cx: &mut ProjectListCx, x: f64) {
        let Some(press) = self.column_press.take() else { return };
        match press.kind {
            ColumnPressKind::Resize { .. } => {
                if press.dragged {
                    self.events.push(ProjectListEvent::SettingsChanged);
                } else {
                    Self::sort_by(cx.model, press.column);
                }
            }
            ColumnPressKind::Move => {
                if !press.dragged || press.column == Column::Name {
                    if !press.dragged {
                        Self::sort_by(cx.model, press.column);
                    }
                    return;
                }
                let frames = self.column_frames(cx, None);
                let target = frames.iter().position(|f| x < f.max_x).unwrap_or(frames.len().saturating_sub(1));
                let visible = self.settings.columns.visible().len();
                // Dropping on a column that the narrow panel hides still lands among the visible ones.
                self.settings.columns.move_column(press.column, target.max(1).min(visible.saturating_sub(1)));
                self.events.push(ProjectListEvent::SettingsChanged);
            }
        }
    }

    fn sort_by(model: &mut ProjectPanelModel, col: Column) {
        let ascending = if model.sort_column() == Some(col) { !model.sort_ascending() } else { true };
        model.set_sort(Some(col), ascending);
    }

    // MARK: Icon grid (ProjectListView+Grid.swift)

    fn thumb_height(&self) -> f64 {
        (self.settings.thumb_size * (10.0 / 16.0)).round()
    }

    /// `ProjectIconCell.cellSize(thumb:)`.
    fn cell_size(&self) -> CGSize {
        CGSize::new(
            self.settings.thumb_size + 2.0 * Self::TILE_PAD,
            self.thumb_height() + Self::TILE_NAME_GAP + Self::TILE_NAME_HEIGHT + 2.0 * Self::TILE_PAD,
        )
    }

    fn grid_columns(&self, model: &ProjectPanelModel) -> usize {
        ((self.list_rect(model).width / self.cell_size().width) as usize).max(1)
    }

    /// The items of the folder the grid shows; at the top the sequences come first, as in the list.
    fn grid_items(&self, model: &ProjectPanelModel) -> Vec<BinItemRef> {
        let project = model.project();
        let bin = model.display_bin(model.browse_bin()).unwrap_or_else(|| project.root_bin.clone());
        let all: Vec<BinItemRef> = model.children(&bin).iter().map(BinItem::item_ref).collect();
        if bin.id != project.root_bin.id {
            return all;
        }
        let seq = |r: &BinItemRef| matches!(r, BinItemRef::Sequence(_));
        let mut out: Vec<BinItemRef> = all.iter().copied().filter(|r| seq(r)).collect();
        out.extend(all.iter().copied().filter(|r| !seq(r)));
        out
    }

    fn grid_height(&self, model: &ProjectPanelModel) -> f64 {
        let n = self.grid_items(model).len();
        let cols = self.grid_columns(model);
        n.div_ceil(cols) as f64 * self.cell_size().height + 8.0
    }

    /// The cell of item `i` in window points (scrolled).
    fn tile_rect(&mut self, model: &ProjectPanelModel, i: usize) -> CGRect {
        let (cell, cols) = (self.cell_size(), self.grid_columns(model));
        let lr = self.list_rect(model);
        let spacing = (lr.width - cols as f64 * cell.width) / (cols as f64 + 1.0);
        let scroll = self.scroll();
        CGRect::new(
            lr.min_x() + spacing + (i % cols) as f64 * (cell.width + spacing),
            lr.min_y() + 4.0 + (i / cols) as f64 * cell.height - scroll,
            cell.width,
            cell.height,
        )
    }

    fn thumb_rect(&mut self, model: &ProjectPanelModel, i: usize) -> CGRect {
        let t = self.tile_rect(model, i);
        CGRect::new(
            t.min_x() + Self::TILE_PAD,
            t.min_y() + Self::TILE_PAD,
            self.settings.thumb_size,
            self.thumb_height(),
        )
    }

    fn tile_at(&mut self, model: &ProjectPanelModel, p: CGPoint) -> Option<usize> {
        if self.settings.view_mode != ViewMode::Icons || !self.list_rect(model).contains(p) {
            return None;
        }
        let n = self.grid_items(model).len();
        (0..n).find(|&i| self.tile_rect(model, i).contains(p))
    }

    /// Double-click on a folder tile: the grid shows its content.
    pub fn enter(&mut self, model: &mut ProjectPanelModel, id: Id) {
        model.set_browse_bin(id);
        model.set_current_bin(id);
        self.selection.clear();
        self.set_scroll(0.0);
    }

    /// The path row: back to the folder around the one shown.
    pub fn go_up(&mut self, model: &mut ProjectPanelModel) {
        if model.browse_bin() == model.project().root_bin.id {
            return;
        }
        let from = model.browse_bin();
        let up = model.project().root_bin.parent_of(BinItemRef::Bin(from)).unwrap_or(model.project().root_bin.id);
        self.enter(model, up);
        self.selection = vec![BinItemRef::Bin(from)];
    }

    // MARK: Health line (ProjectListView+Health.swift)

    fn health_rect(&self, model: &ProjectPanelModel) -> Option<CGRect> {
        // The foot always counts the files ("N in folder"); a project with no files has no foot.
        let h = model.health();
        if h.in_folder + h.outside + h.missing == 0 {
            return None;
        }
        Some(CGRect::new(
            self.frame.min_x(),
            self.frame.max_y() - Self::HEALTH_HEIGHT,
            self.frame.width,
            Self::HEALTH_HEIGHT,
        ))
    }

    /// The texts of the segments, in order.
    pub fn health_texts(h: &sq_core_project::relink_scoring::ProjectHealth) -> Vec<(HealthPart, String)> {
        // "N in folder" always; "N outside" and "· N missing" (red triangle) only when there are some.
        let mut out = vec![(HealthPart::InFolder, SQL10n::format("%@ in folder", &[&h.in_folder.to_string()]))];
        if h.outside > 0 {
            out.push((HealthPart::Outside, SQL10n::format("%@ outside", &[&h.outside.to_string()])));
        }
        if h.missing > 0 {
            out.push((HealthPart::Missing, SQL10n::format("%@ missing", &[&h.missing.to_string()])));
        }
        out
    }

    /// The button's label (r8): always "Fix…"; with only missing files it relinks at once like the old "Locate…".
    pub fn fix_label() -> String {
        SQL10n::string("Fix…")
    }

    /// Room before a segment's text: the "· " separator and the red triangle for Missing, nothing for the plain
    /// in-folder count, a dot for Outside.
    fn health_lead(part: HealthPart, m: &TextMeasure) -> f64 {
        let fs = type_size::CAPTION as f64;
        match part {
            HealthPart::Missing => m.width("·", fs, 0) + spacing::XS as f64 + Self::OFFLINE_ICON,
            HealthPart::InFolder | HealthPart::Fix => 0.0,
            HealthPart::Outside => m.width("●", fs, 0),
        }
    }

    /// The segments (dot + count) from the left and the Fix… button at the right, `Theme.Spacing.md` apart.
    fn health_layout(&self, model: &ProjectPanelModel, m: &TextMeasure) -> Vec<(HealthPart, CGRect)> {
        let Some(r) = self.health_rect(model) else { return Vec::new() };
        let (fs, g) = (type_size::CAPTION as f64, spacing::SM as f64);
        let fix_w =
            m.width(&Self::fix_label(), type_size::BODY as f64, 0).ceil() + 2.0 * spacing::MD as f64;
        let fix = CGRect::new(r.max_x() - g - fix_w, r.min_y() + 2.0, fix_w, r.height - spacing::XS as f64);
        let mut out = Vec::new();
        let mut x = r.min_x() + g;
        for (part, text) in Self::health_texts(&model.health()) {
            let lead = Self::health_lead(part, m);
            let gap = if part == HealthPart::InFolder { 0.0 } else { spacing::XS as f64 };
            let w = (lead + gap + m.width(&text, fs, 0)).ceil();
            if x + w > fix.min_x() - g {
                break;
            }
            out.push((part, CGRect::new(x, r.min_y(), w, r.height)));
            x += w + spacing::MD as f64;
        }
        if !model.health().is_healthy() {
            out.push((HealthPart::Fix, fix));
        }
        out
    }

    /// The "Locate…" button runs the relink at once when nothing else (outside files to collect) needs the menu.
    pub fn fix_runs_relink(h: &sq_core_project::relink_scoring::ProjectHealth) -> bool {
        h.missing > 0 && h.outside == 0
    }

    /// The Fix menu's rows for `h` (the Mac `ProjectHealthBar.menuItems`); Collect only when the host can collect.
    pub fn health_menu_items(
        h: &sq_core_project::relink_scoring::ProjectHealth,
        can_collect: bool,
        run: Rc<dyn Fn(HealthPart)>,
        collect: Rc<dyn Fn()>,
    ) -> Vec<SQMenuItem> {
        let mut rows = Vec::new();
        let action = |title: String, f: Rc<dyn Fn()>| {
            let mut i = SQMenuItem::new(&title);
            i.action = Some(f);
            i
        };
        if h.outside > 0 && can_collect {
            rows.push(action(
                SQL10n::plural(h.outside as i64, "Collect %@ file into project", "Collect %@ files into project"),
                Rc::clone(&collect),
            ));
        }
        if h.missing > 0 {
            let r1 = Rc::clone(&run);
            rows.push(action(
                SQL10n::plural(h.missing as i64, "Reconnect %@ missing file…", "Reconnect %@ missing files…"),
                Rc::new(move || r1(HealthPart::Fix)),
            ));
            let r2 = Rc::clone(&run);
            rows.push(action(SQL10n::string("Show missing files"), Rc::new(move || r2(HealthPart::Missing))));
        }
        rows
    }

    fn health_part(&self, cx: &ProjectListCx, p: CGPoint) -> Option<HealthPart> {
        if !self.health_rect(cx.model)?.contains(p) {
            return None;
        }
        self.health_layout(cx.model, &cx.measure).into_iter().find(|(_, r)| r.contains(p)).map(|(part, _)| part)
    }

    /// A click on the health line; true when it was on the line.
    fn health_click(&mut self, cx: &mut ProjectListCx, p: CGPoint) -> bool {
        if !self.health_rect(cx.model).is_some_and(|r| r.contains(p)) {
            return false;
        }
        match self.health_part(cx, p) {
            Some(HealthPart::Missing) => cx.model.set_media_filter(MediaFilter::Offline),
            Some(HealthPart::Outside | HealthPart::Fix) => {
                // "Locate…" with only missing files is the relink itself, not a menu with one more step.
                if Self::fix_runs_relink(&cx.model.health()) {
                    self.queue.borrow_mut().push(ListAction::Reconnect);
                    return true;
                }
                let fix = self
                    .health_layout(cx.model, &cx.measure)
                    .into_iter()
                    .find(|(part, _)| *part == HealthPart::Fix)
                    .map_or(CGRect::default(), |(_, r)| r);
                let q = Rc::clone(&self.queue);
                let run: Rc<dyn Fn(HealthPart)> = Rc::new({
                    let q = Rc::clone(&q);
                    move |part| {
                        q.borrow_mut().push(if part == HealthPart::Missing {
                            ListAction::ShowMissing
                        } else {
                            ListAction::Reconnect
                        })
                    }
                });
                let collect: Rc<dyn Fn()> = Rc::new(move || q.borrow_mut().push(ListAction::Collect));
                let items = Self::health_menu_items(&cx.model.health(), cx.can_collect, run, collect);
                if !items.is_empty() {
                    self.events.push(ProjectListEvent::PresentMenu {
                        items,
                        at: CGPoint::new(fix.min_x(), fix.max_y()),
                        anchor: Some(fix),
                    });
                }
            }
            Some(HealthPart::InFolder) | None => {}
        }
        true
    }

    // MARK: Hover scrub and tips (ProjectListView+HoverScrub.swift)

    /// While Hover Scrub is off, holding Shift scrubs (the Mac `ProjectIconView`, Premiere).
    fn scrub_state(&mut self, cx: &ProjectListCx, p: CGPoint) -> Option<HoverScrubState> {
        let shift = cx.modifiers.contains(InputModifiers::SHIFT);
        if !(self.settings.hover_scrub || shift) || self.is_dragging || self.settings.view_mode != ViewMode::Icons {
            return None;
        }
        let i = self.tile_at(cx.model, p)?;
        let r = self.thumb_rect(cx.model, i);
        if !r.contains(p) {
            return None;
        }
        let items = self.grid_items(cx.model);
        let BinItemRef::Media(id) = *items.get(i)? else { return None };
        let m = cx.model.project().media(id)?;
        if matches!(m.kind(), MediaKind::Audio | MediaKind::Image) || cx.model.is_offline(id) {
            return None;
        }
        let total = m.info.as_ref().map(|i| i.duration).or(m.duration).filter(|t| *t > Time::ZERO)?;
        let frame =
            m.info.as_ref().and_then(|i| i.video.as_ref()).map_or(Time::new(1, 30), |v| v.nominal_frame_duration);
        let t = HoverScrub::time((p.x - r.min_x()) / r.width, total, frame);
        Some(HoverScrubState { item: i, media: id, time: t, x: p.x })
    }

    /// The clip and frame under the pointer in the icon view (Set Poster Frame uses it).
    pub fn hovered_frame(&self) -> Option<(Id, Time)> {
        self.scrub.map(|s| (s.media, s.time))
    }

    /// The scrubbed frame the host should load for the tile under the pointer.
    pub fn scrub_request(&self) -> Option<(Id, Time)> {
        self.hovered_frame()
    }

    fn tile_poster(&self, i: usize, media: Id) -> Option<ProjectPoster> {
        if let Some(s) = self.scrub
            && s.item == i
            && s.media == media
            && let Some((m, t, p)) = &self.scrub_poster
            && *m == media
            && *t == s.time
        {
            return Some(*p);
        }
        self.posters.get(&media).copied()
    }

    /// The tip over a media row or tile: its file path (offline items say so).
    fn item_tip(&mut self, cx: &ProjectListCx, p: CGPoint) -> Option<String> {
        if self.is_dragging {
            return None;
        }
        if let Some((_, tip)) = self.row_tips.iter().find(|(r, _)| r.contains(p)) {
            return Some(tip.clone());
        }
        let i = self.item_at(cx.model, p)?;
        let items = self.items(cx.model);
        let BinItemRef::Media(id) = *items.get(i)? else { return None };
        let m = cx.model.project().media(id)?;
        Some(if cx.model.is_offline(id) { SQL10n::format("Offline: %@", &[&m.path]) } else { m.path.clone() })
    }

    // MARK: Moving items between folders (ProjectListView+Move.swift)

    /// Where dropping the dragged `refs` at `p` would put them, `None` when nothing accepts them there.
    fn compute_move_target(&mut self, cx: &ProjectListCx, p: CGPoint, refs: &[BinItemRef]) -> Option<MoveTarget> {
        let model = &*cx.model;
        if !self.list_rect(model).contains(p) || refs.is_empty() {
            return None;
        }
        let ProjectDrop::Move(items) = model.classify_drop(refs, &[]) else { return None };
        let project = model.project();
        let accepts = |bin: Id| -> bool {
            for r in &items {
                if let BinItemRef::Bin(id) = r {
                    if *id == bin {
                        return false;
                    }
                    // into itself or a descendant
                    if project.bin(*id).is_some_and(|moving| moving.bin(bin).is_some()) {
                        return false;
                    }
                }
            }
            true
        };
        if self.settings.view_mode == ViewMode::Icons {
            let i = self.tile_at(model, p)?;
            let BinItemRef::Bin(id) = *self.grid_items(model).get(i)? else { return None };
            return accepts(id).then(|| MoveTarget {
                bin: id,
                index: None,
                cue: self.tile_rect(model, i),
                is_line: false,
            });
        }
        let list = self.rows(model);
        let Some(i) = self.row_at(model, p) else {
            let root = project.root_bin.id;
            return accepts(root).then(|| MoveTarget {
                bin: root,
                index: None,
                cue: self.list_rect(model),
                is_line: false,
            });
        };
        if list[i].variant.is_some() {
            return None;
        }
        let rr = self.row_rect(model, i);
        let r = list[i].item_ref;
        let parent = project.root_bin.parent_of(r).unwrap_or(project.root_bin.id);
        // Between rows the line shows in every order, like the Mac outline; only where the order is the bin's own (no sort,
        // no filter, no grouped root) does the drop carry an index, otherwise it appends (the Mac `acceptDrop`).
        let ordered = model.sort_column().is_none() && !model.is_filtering();
        let edge = rr.height * Self::INSERT_BAND;
        if (p.y < rr.min_y() + edge || p.y > rr.max_y() - edge)
            && accepts(parent)
            && let Some(bin) = project.bin(parent)
        {
            let top_refs: Vec<BinItemRef> = list.iter().filter(|r| r.depth == 0).map(|r| r.item_ref).collect();
            let bin_refs: Vec<BinItemRef> = bin.children.iter().map(BinItem::item_ref).collect();
            let root_grouped = parent == project.root_bin.id && top_refs != bin_refs;
            let at = bin.children.iter().position(|c| c.item_ref() == r);
            let before = p.y < rr.mid_y();
            let y = if before { rr.min_y() } else { rr.max_y() };
            let index = if ordered && !root_grouped { at.map(|a| if before { a } else { a + 1 }) } else { None };
            return Some(MoveTarget {
                bin: parent,
                index,
                cue: CGRect::new(rr.min_x(), y - 1.0, rr.width, 2.0),
                is_line: true,
            });
        }
        if let BinItemRef::Bin(id) = r {
            return accepts(id).then_some(MoveTarget { bin: id, index: None, cue: rr, is_line: false });
        }
        accepts(parent).then_some(MoveTarget { bin: parent, index: None, cue: rr, is_line: false })
    }

    /// Drops the moved items on `target` (the Mac `acceptDrop` index rule: the index counts the children after the moved
    /// items were taken out).
    fn drop_move(&mut self, cx: &mut ProjectListCx, refs: &[BinItemRef], target: &MoveTarget) -> bool {
        let Some(dest) = cx.model.project().bin(target.bin) else { return false };
        let at = target.index.map(|index| {
            let before = dest.children.iter().take(index).filter(|c| refs.contains(&c.item_ref())).count();
            (index - before) as i64
        });
        cx.model.move_items(cx.session, refs, target.bin, at);
        true
    }

    // MARK: Reveal (ProjectListView+Reveal.swift)

    /// Edit > Find, after the count (Swift `ShellHost.selectFound`): clears the search text, opens the bins that hold
    /// `found` and selects them.
    pub fn reveal_found(&mut self, cx: &mut ProjectListCx, found: Vec<BinItemRef>) {
        if !self.search_text().is_empty() {
            self.set_search_text(cx.model, "");
        }
        let root = cx.model.project().root_bin.clone();
        self.reveal_items(found, &root);
    }

    /// Reveal in Project (the Mac `ProjectPanelView.reveal(media:)`): clears the search, opens every folder above the
    /// item, selects it and scrolls its row into view.
    pub fn reveal_media(&mut self, cx: &mut ProjectListCx, id: Id) {
        if !self.search_text().is_empty() {
            self.set_search_text(cx.model, "");
        }
        let root = cx.model.project().root_bin.clone();
        let mut up = root.parent_of(BinItemRef::Media(id));
        while let Some(b) = up.filter(|b| *b != root.id) {
            if !self.expanded.contains(&b) {
                self.toggle(b);
            }
            up = root.parent_of(BinItemRef::Bin(b));
        }
        self.selection = vec![BinItemRef::Media(id)];
        if self.settings.view_mode != ViewMode::List {
            return;
        }
        let Some(i) = self.rows(cx.model).iter().position(|r| r.item_ref == BinItemRef::Media(id)) else { return };
        let top = i as f64 * Self::ROW_HEIGHT;
        let h = self.list_rect(cx.model).height;
        let scroll = self.scroll();
        if top < scroll {
            self.set_scroll(top);
        } else if h > 0.0 && top + Self::ROW_HEIGHT > scroll + h {
            self.set_scroll(top + Self::ROW_HEIGHT - h);
        }
    }
}

// MARK: Drawing

impl ProjectListView {
    /// Draws the panel into its frame.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut ProjectListCx) {
        if self.frame.width <= 0.0 || self.frame.height <= 0.0 {
            return; // another dock tab is on top: nothing of the list shows
        }
        c.fill(self.frame, t.panel());
        self.draw_chrome(c, t, cx);
        let lr = self.list_rect(cx.model);
        let content = self.content_height(cx.model);
        self.scroll_body.set_range((content - lr.height).max(0.0), lr.height);
        c.save_gstate();
        c.clip_to(lr);
        if self.settings.view_mode == ViewMode::Icons {
            self.draw_grid(c, t, cx);
        } else {
            self.draw_list(c, t, cx);
        }
        c.restore_gstate();
        self.scroll_body.draw_scroller(c, lr, content, t, cx.now);
        if let Some(m) = &self.move_target {
            if m.is_line {
                c.fill(m.cue, t.accent());
            } else {
                c.stroke_rounded(m.cue.inset_by(1.0, 1.0), radius::SMALL as f64, 2.0, t.accent());
            }
        }
        self.draw_info_card(c, t, cx);
        self.draw_health(c, t, cx);
    }

    /// The info card under the list (redesign): the selected clip's "name · size · fps · color · uses" in a quiet group
    /// card, just below the last row, pinned above the footer when the list is long.
    fn draw_info_card(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &ProjectListCx) {
        if self.settings.view_mode != ViewMode::List || self.selection.len() != 1 {
            return;
        }
        let Some(line) = cx.model.info_line(self.selection[0]) else { return };
        let lr = self.list_rect(cx.model);
        let h = 32.0;
        let natural = lr.min_y() + self.rows(cx.model).len() as f64 * Self::ROW_HEIGHT - self.scroll() + 10.0;
        let y = natural.min(lr.max_y() - h - 6.0);
        if y < lr.min_y() {
            return;
        }
        let card = CGRect::new(lr.min_x() + 12.0, y, (lr.width - 24.0).max(0.0), h);
        c.fill_rounded(card, 6.0, t.well());
        c.draw_text_in(&line, card.inset_by(10.0, 0.0), type_size::CAPTION as f64, t.label2(), TextAlign::Left, 0.0, 0);
    }

    fn draw_list(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut ProjectListCx) {
        let list = self.rows(cx.model);
        let refs: Vec<BinItemRef> = list.iter().map(|r| r.item_ref).collect();
        let cols = self.column_frames(cx, Some(&refs));
        let name_end = cols.iter().find(|f| f.column == Column::Name).map_or(self.frame.max_x(), |f| f.max_x);
        let lr = self.list_rect(cx.model);
        self.row_tips.clear();
        for (i, r) in list.iter().enumerate() {
            let rr = self.row_rect(cx.model, i);
            if rr.max_y() < lr.min_y() || rr.min_y() > lr.max_y() {
                continue;
            }
            let indent = Self::indent(r.depth);
            // Artifact: an inset rounded highlight (6 pt radius, margin from the panel edge), not a flat full-width band.
            let selected = if r.variant.is_some() {
                r.variant == self.variant_selection
            } else {
                self.selection.contains(&r.item_ref)
            };
            c.stone_row_pill(rr, selected, self.hover_row == Some(i) && !self.is_dragging, t);
            // A thin guide line under each ancestor's arrow keeps every level readable once the indent shrinks.
            for l in 1..=r.depth {
                let gx = rr.min_x() + Self::NAME_LEAD + Self::indent(l - 1) + 4.0;
                c.fill(CGRect::new(gx, rr.min_y(), 1.0, rr.height), t.separator());
            }
            if let (Some(v), BinItemRef::Sequence(sid)) = (r.variant, r.item_ref)
                && let Some(f) = cx.model.project().timeline(sid).and_then(|tl| tl.variants.iter().find(|x| x.id == v))
            {
                // A format variant: the row part again, named with its aspect ("Vertical 9:16").
                let x = rr.min_x() + Self::NAME_LEAD + indent;
                let chip = CGRect::new(x, rr.mid_y() - Self::CHIP / 2.0, Self::CHIP, Self::CHIP);
                let icon =
                    SQIcon::from_raw(ProjectItemIcon::icon(sq_editor_session::ProjectItemKind::Sequence, false).symbol)
                        .unwrap_or(SQIcon::Unknown);
                c.draw_icon(
                    icon,
                    CGPoint::new(chip.min_x() + 1.0, chip.min_y() + 1.0),
                    Self::CHIP - 2.0,
                    t.label2(),
                    None,
                );
                let label = format!(
                    "{} {}",
                    f.name,
                    sq_core_effects::sequence_conform::SequenceConform::aspect_label(f.width, f.height)
                );
                let cell = CGRect::new(chip.max_x() + 10.0, rr.min_y(), (name_end - chip.max_x() - 14.0).max(0.0), rr.height);
                let cut = sq_draw::middle_fit::truncate_name(&label, |s| c.size_of(s, Self::LIST_FONT, 0).width <= cell.width);
                c.draw_text_in(&cut.shown, cell, Self::LIST_FONT, t.label(), TextAlign::Left, 0.0, 0);
                if let Some(full) = cut.full {
                    self.row_tips.push((cell, full));
                }
                continue;
            }
            let offline = matches!(r.item_ref, BinItemRef::Media(m) if cx.model.is_offline(m));
            let kind = cx.model.item_kind(r.item_ref);
            let mut x = rr.min_x() + Self::NAME_LEAD + indent;
            if let BinItemRef::Bin(id) = r.item_ref {
                let open = self.expanded.contains(&id);
                let mid = CGPoint::new(x + 4.0, rr.mid_y());
                let pts = if open {
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
                x += Self::LEVEL_INDENT;
            }
            // Gray chip, the label color only as a small dot; an offline row gets a red "Offline" tag at the name column's
            // end, no stripe. Artifact: plain line icons, no tile; both sequence kinds share the clapper glyph.
            let chip = CGRect::new(x, rr.mid_y() - Self::CHIP / 2.0, Self::CHIP, Self::CHIP);
            let nested = kind == sq_editor_session::ProjectItemKind::NestedSequence;
            let symbol =
                ProjectItemIcon::icon(if nested { sq_editor_session::ProjectItemKind::Sequence } else { kind }, false)
                    .symbol;
            c.draw_icon(
                SQIcon::from_raw(symbol).unwrap_or(SQIcon::Unknown),
                CGPoint::new(chip.min_x() + 1.0, chip.min_y() + 1.0),
                Self::CHIP - 2.0,
                t.label2(),
                None,
            );
            // The kind shows by the icon shape only (no dot). An offline row: the name in secondary text and a red
            // triangle right after it, tip "Offline: file not found".
            let name_x = chip.max_x() + 10.0;
            let tri = Self::OFFLINE_ICON;
            let name = cx.model.cell_text(Column::Name, r.item_ref);
            let room = (name_end - name_x - 4.0 - if offline { tri + 4.0 } else { 0.0 }).max(0.0);
            let cut = sq_draw::middle_fit::truncate_name(&name, |s| c.size_of(s, Self::LIST_FONT, 0).width <= room);
            let name_w = c.size_of(&cut.shown, Self::LIST_FONT, 0).width.ceil();
            let name_cell = CGRect::new(name_x, rr.min_y(), room, rr.height);
            c.draw_text_in(
                &cut.shown,
                name_cell,
                Self::LIST_FONT,
                if offline { t.label2() } else { t.label() },
                TextAlign::Left,
                0.0,
                0,
            );
            if let Some(full) = cut.full {
                self.row_tips.push((name_cell, full));
            }
            if offline {
                let at = CGRect::new(name_x + name_w + 4.0, rr.mid_y() - tri / 2.0, tri, tri);
                c.draw_icon(SQIcon::Warning, CGPoint::new(at.min_x(), at.min_y()), tri, t.err_text(), None);
                // First in the list, so it wins over the name's own tip.
                self.row_tips.insert(0, (at, SQL10n::string("Offline: file not found")));
            }
            for col in cols.iter().filter(|f| f.column != Column::Name) {
                let cell = CGRect::new(col.min_x, rr.min_y(), col.max_x - col.min_x, rr.height);
                c.draw_text_in(
                    &cx.model.cell_text(col.column, r.item_ref),
                    cell,
                    Self::LIST_FONT,
                    t.label2(),
                    if Self::right_aligned(col.column) { TextAlign::Right } else { TextAlign::Left },
                    Self::CELL_INSET,
                    0,
                );
            }
        }
    }

    fn draw_glyph(&self, c: &mut Canvas, icon: SQIcon, r: CGRect, color: Color) {
        let s = (self.settings.thumb_size * 0.28).round();
        c.draw_icon(icon, CGPoint::new(r.mid_x() - s / 2.0, r.mid_y() - s / 2.0), s, color, None);
    }

    fn draw_grid(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut ProjectListCx) {
        let items = self.grid_items(cx.model);
        let lr = self.list_rect(cx.model);
        for (i, r) in items.iter().enumerate() {
            let tile = self.tile_rect(cx.model, i);
            if tile.max_y() < lr.min_y() || tile.min_y() > lr.max_y() {
                continue;
            }
            let thumb = self.thumb_rect(cx.model, i);
            let rad = radius::CONTROL as f64;
            c.fill_rounded(thumb, rad, t.fill());
            let offline = matches!(r, BinItemRef::Media(m) if cx.model.is_offline(*m));
            let poster = if let BinItemRef::Media(m) = r { self.tile_poster(i, *m) } else { None };
            if offline {
                self.draw_glyph(c, SQIcon::Warning, thumb, Self::OFFLINE_RED);
            } else if let Some(p) = poster {
                p.draw_fit(c, thumb, Some(t.viewer()));
                if let Some(s) = self.scrub.filter(|s| s.item == i) {
                    let line_x = s.x.max(thumb.min_x()).min(thumb.max_x() - Self::SCRUB_LINE_WIDTH);
                    c.fill(CGRect::new(line_x, thumb.min_y(), Self::SCRUB_LINE_WIDTH, thumb.height), t.accent());
                }
            } else {
                let kind = cx.model.item_kind(*r);
                let glyph = match r {
                    BinItemRef::Bin(_) => SQIcon::FolderFilled,
                    BinItemRef::Sequence(_) => SQIcon::Sequence,
                    BinItemRef::Media(_) => {
                        SQIcon::from_raw(ProjectItemIcon::icon(kind, false).symbol).unwrap_or(SQIcon::Unknown)
                    }
                };
                self.draw_glyph(c, glyph, thumb, t.clip(cx.model.label(*r)));
            }
            // The label strip under the poster and the duration on it (media and sequences).
            if !matches!(r, BinItemRef::Bin(_)) {
                c.fill(CGRect::new(thumb.min_x(), thumb.max_y() - 3.0, thumb.width, 3.0), t.clip(cx.model.label(*r)));
                let d = cx.model.cell_text(Column::Duration, *r);
                if !d.is_empty() {
                    let w = c.size_of(&d, 9.0, 0).width + 8.0;
                    let badge = CGRect::new(thumb.max_x() - w - 4.0, thumb.max_y() - 3.0 - 4.0 - 14.0, w, 14.0);
                    c.fill_rounded(badge, radius::SMALL as f64, t.viewer_hud());
                    c.draw_text_in(&d, badge, 9.0, t.on_clip(), TextAlign::Center, 0.0, 0);
                }
            }
            if poster.is_some() || !matches!(r, BinItemRef::Bin(_)) {
                // Poster, label strip and scrub line are square-cornered: give the rounded tile its corners back.
                c.round_picture_corners(thumb, rad, t.panel());
            }
            if self.selection.contains(r) {
                c.stroke_rounded(
                    thumb.inset_by(-Self::RING_WIDTH, -Self::RING_WIDTH),
                    rad + Self::RING_WIDTH,
                    Self::RING_WIDTH,
                    t.accent(),
                );
            }
            let name = CGRect::new(
                tile.min_x() + 2.0,
                thumb.max_y() + Self::TILE_NAME_GAP,
                tile.width - 4.0,
                Self::TILE_NAME_HEIGHT,
            );
            c.draw_text_in(
                &cx.model.cell_text(Column::Name, *r),
                name,
                type_size::BODY as f64,
                if offline { Self::OFFLINE_RED } else { t.label() },
                TextAlign::Center,
                0.0,
                0,
            );
        }
    }

    fn draw_health(&self, c: &mut Canvas, t: &DrawTheme, cx: &ProjectListCx) {
        let Some(r) = self.health_rect(cx.model) else { return };
        c.fill(r, t.panel());
        c.fill(CGRect::new(r.min_x(), r.min_y(), r.width, 1.0), t.hair());
        let fs = type_size::CAPTION as f64;
        let h = cx.model.health();
        let texts = Self::health_texts(&h);
        let m = TextMeasure::new(c.atlas(), c.scale);
        for (part, rect) in self.health_layout(cx.model, &m) {
            if part == HealthPart::Fix {
                InspectorDraw::button(
                    c,
                    &Self::fix_label(),
                    rect,
                    self.health_hover == Some(HealthPart::Fix),
                    false,
                    true,
                    false,
                    sq_draw::InspectorTokens::CAPSULE as f64,
                    t,
                );
                continue;
            }
            let dot = if part == HealthPart::Outside { t.warning() } else { Self::OFFLINE_RED };
            let lead = Self::health_lead(part, &m);
            match part {
                HealthPart::Missing => {
                    // "· " then the red alert triangle, then "N missing".
                    c.draw_text("·", CGPoint::new(rect.min_x(), rect.mid_y() - fs * 0.6), fs, t.label3(), f64::INFINITY, 0);
                    let d = Self::OFFLINE_ICON;
                    c.draw_icon(SQIcon::Warning, CGPoint::new(rect.min_x() + lead - d, rect.mid_y() - d / 2.0), d, t.err_text(), None);
                }
                HealthPart::Outside => {
                    c.fill_ellipse(CGRect::new(rect.min_x(), rect.mid_y() - 3.0, 6.0, 6.0), dot);
                }
                _ => {}
            }
            let tx = rect.min_x() + lead + if part == HealthPart::InFolder { 0.0 } else { spacing::XS as f64 };
            let text = texts.iter().find(|(p, _)| *p == part).map(|(_, s)| s.as_str()).unwrap_or("");
            let hot = self.health_hover == Some(part) && part != HealthPart::InFolder;
            c.draw_text_in(
                text,
                CGRect::new(tx, rect.min_y(), (rect.max_x() - tx).max(0.0), rect.height),
                fs,
                if part == HealthPart::Missing {
                    t.err_text()
                } else if hot {
                    t.label()
                } else {
                    t.label2()
                },
                TextAlign::Left,
                0.0,
                0,
            );
        }
    }

    fn draw_chrome(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut ProjectListCx) {
        let header = self.header_rect();
        if self.shows_title {
            let semibold = c.semibold();
            c.draw_text_in(
                &SQL10n::string("Project"),
                header.inset_by(Self::NAME_LEAD, 0.0),
                type_size::TITLE as f64,
                t.label(),
                TextAlign::Left,
                0.0,
                semibold,
            );
        }
        let o = self.options_rect();
        let count = self.item_count_text(cx.model);
        let cw = c.size_of(&count, 11.0, 0).width;
        if let Some(st) = self.strip_rects() {
            c.draw_icon(SQIcon::Ellipsis, CGPoint::new(o.mid_x() - 6.0, o.mid_y() - 6.0), 12.0, t.label3(), None);
            c.draw_icon(
                SQIcon::FolderAdd,
                CGPoint::new(st.folder.mid_x() - 6.0, st.folder.mid_y() - 6.0),
                12.0,
                t.label2(),
                None,
            );
            c.draw_text(&count, CGPoint::new(st.count - cw, o.mid_y() - 7.0), 11.0, t.label3(), f64::INFINITY, 0);
        } else {
            c.draw_icon(
                SQIcon::Ellipsis,
                CGPoint::new(o.min_x() + 3.0, o.min_y() + 3.0),
                o.width - 6.0,
                t.label2(),
                None,
            );
            c.draw_text(
                &count,
                CGPoint::new(o.min_x() - spacing::SM as f64 - cw, header.mid_y() - 7.0),
                11.0,
                t.label3(),
                f64::INFINITY,
                0,
            );
        }
        if let Some(r) = self.size_slider_rect(cx) {
            let range = Self::THUMB_RANGE.1 - Self::THUMB_RANGE.0;
            InspectorDraw::slider(c, (self.settings.thumb_size - Self::THUMB_RANGE.0) / range, 0.0, r, true, t);
        }
        if header.height > 0.0 {
            c.fill(CGRect::new(self.frame.min_x(), header.max_y() - 1.0, self.frame.width, 1.0), t.row_separator());
        }
        if self.settings.search_visible {
            let f = self.search_field_rect(cx.model);
            self.search.font_size = 11.0;
            let focused = self.search.is_editing();
            self.search.draw(c, f, t, focused, cx.ui);
            if self.search_text().is_empty() && !self.search.is_editing() {
                c.draw_text_in("Search project", f, 11.0, t.label3(), TextAlign::Left, 8.0, 0);
            } else if !self.search_text().is_empty() {
                let x = self.search_clear_rect(cx.model);
                c.draw_icon(
                    SQIcon::CloseCircleFilled,
                    CGPoint::new(x.min_x() + 1.0, x.min_y() + 1.0),
                    x.width - 2.0,
                    t.label3(),
                    None,
                );
            }
        }
        let sub = self.subheader_rect(cx.model);
        if sub.height <= 0.0 {
            return;
        }
        if self.settings.view_mode == ViewMode::List {
            let semibold = c.semibold();
            for col in self.column_frames(cx, None) {
                // `PanelListHeaderCell`: 11 semibold label3, name at the 12 pt lead, others 8 pt in (right-aligned: from the right).
                let x0 = if col.column == Column::Name { col.min_x + Self::NAME_LEAD } else { col.min_x };
                let r = CGRect::new(x0, sub.min_y(), col.max_x - x0, sub.height);
                let right = Self::right_aligned(col.column);
                let inset = if col.column == Column::Name { 0.0 } else { Self::CELL_INSET };
                let w = c.draw_text_in(
                    col.column.title(),
                    r,
                    11.0,
                    t.label3(),
                    if right { TextAlign::Right } else { TextAlign::Left },
                    inset,
                    semibold,
                );
                if cx.model.sort_column() == Some(col.column) {
                    let ax = if right {
                        r.max_x() - Self::CELL_INSET - w - Self::CELL_PAD - 8.0
                    } else {
                        r.min_x() + inset + w + Self::CELL_PAD
                    };
                    c.draw_icon(
                        if cx.model.sort_ascending() { SQIcon::ChevronUp } else { SQIcon::ChevronDown },
                        CGPoint::new(ax, sub.mid_y() - 4.0),
                        8.0,
                        t.label3(),
                        None,
                    );
                }
            }
        } else {
            c.draw_icon(
                SQIcon::ChevronLeft,
                CGPoint::new(sub.min_x() + Self::NAME_LEAD - 2.0, sub.mid_y() - 6.0),
                12.0,
                t.label2(),
                None,
            );
            c.draw_text_in(
                &self.crumb_path(cx.model),
                sub.inset_by(Self::NAME_LEAD + 14.0, 0.0),
                11.0,
                t.label2(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
        c.fill(CGRect::new(self.frame.min_x(), sub.max_y() - 1.0, self.frame.width, 1.0), t.separator());
    }

    /// "Project / Shots / Day 1": the folders from the top to the one the grid shows.
    fn crumb_path(&self, model: &ProjectPanelModel) -> String {
        let mut names: Vec<String> = Vec::new();
        let mut id = Some(model.browse_bin());
        while let Some(b) = id.filter(|b| *b != model.project().root_bin.id) {
            names.insert(0, model.display_name(BinItemRef::Bin(b)));
            id = model.project().root_bin.parent_of(BinItemRef::Bin(b));
        }
        let mut all = vec![SQL10n::string("Project")];
        all.extend(names);
        all.join(" / ")
    }
}

impl crate::shell_host::ShellHost {
    /// The Rename dialog of a Project item (the Mac edits the cell in place): a name field. `None` when canceled or the root
    /// is gone; the app passes the answer to [`ProjectListView::rename_to`].
    pub async fn ask_item_name<R: crate::shell_flows::ShellRoot + ?Sized>(
        h: sq_runtime::UiRef<R>,
        current: String,
    ) -> Option<String> {
        use crate::shell_form::{Row, ShellForm};
        use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
        let mut d = crate::shell_dialog::ShellDialog::new("Rename", "");
        d.form = Some(Box::new(ShellForm::new(vec![Row::field("name", "Name", &current)])));
        d.add_button("Rename", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        if Self::ask(&h, d).await? != SQDialogResponse::FIRST {
            return None;
        }
        let form = h.with(|r| r.shell_parts().shell.take_answered_form())??;
        form.text("name")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::session;
    use sq_core_time::SequentialIds;
    use sq_editor_session::ProjectPanelDeps;

    struct Rig {
        model: ProjectPanelModel,
        session: EditorSession,
        ui: UiCx,
        ids: SequentialIds,
        now: f64,
    }

    impl Rig {
        fn new() -> Rig {
            let session = session();
            let model = ProjectPanelModel::new(session.project().clone(), ProjectPanelDeps::headless());
            Rig { model, session, ui: UiCx::default(), ids: SequentialIds::default(), now: 100.0 }
        }

        fn cx(&mut self) -> ProjectListCx<'_, 'static> {
            ProjectListCx {
                model: &mut self.model,
                session: &mut self.session,
                measure: TextMeasure::new(None, 1.0),
                ui: &mut self.ui,
                ids: &mut self.ids,
                can_collect: true,
                now: self.now,
                modifiers: InputModifiers::NONE,
            }
        }
    }

    fn list() -> ProjectListView {
        let mut v = ProjectListView::new(ProjectListSettings::default());
        v.frame = CGRect::new(0.0, 0.0, 600.0, 400.0);
        v
    }

    fn mouse_down(x: f64, y: f64, m: InputModifiers) -> InputEvent {
        InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: m }
    }

    #[test]
    fn rows_list_the_sequences_before_folders() {
        let mut rig = Rig::new();
        let v = list();
        {
            let Rig { model, session, .. } = &mut rig;
            model.new_bin(session, "B");
        }
        let cx = rig.cx();
        cx.model.new_bin(cx.session, "A");
        let rows = v.rows(cx.model);
        assert!(rows.len() >= 3);
        assert!(matches!(rows[0].item_ref, BinItemRef::Sequence(_)));
        assert!(rows[1..].iter().all(|r| matches!(r.item_ref, BinItemRef::Bin(_)) && r.depth == 0));
    }

    #[test]
    fn a_double_click_on_a_sequence_opens_it() {
        let mut rig = Rig::new();
        let mut v = list();
        let y = v.chrome_height(&rig.model) + ProjectListView::ROW_HEIGHT / 2.0;
        for now in [100.0, 100.2] {
            rig.now = now;
            let mut cx = rig.cx();
            assert!(v.handle(&mut cx, &mouse_down(300.0, y, InputModifiers::NONE), 1.0));
            v.handle(&mut cx, &InputEvent::MouseUp { x: 300.0, y: y as f32 }, 1.0);
        }
        assert!(v.take_events().iter().any(|e| matches!(e, ProjectListEvent::OpenSequence(_))));
        assert_eq!(v.selection().len(), 1);
    }

    #[test]
    fn a_click_in_empty_space_clears_the_selection() {
        let mut rig = Rig::new();
        let mut v = list();
        v.select(vec![BinItemRef::Bin(Id::fixed(1))]);
        let mut cx = rig.cx();
        v.handle(&mut cx, &mouse_down(300.0, 390.0, InputModifiers::NONE), 1.0);
        assert!(v.selection().is_empty());
    }

    #[test]
    fn a_five_level_tree_shows_five_distinct_levels() {
        let xs: Vec<f64> = (0..5).map(ProjectListView::indent).collect();
        assert!(xs.windows(2).all(|w| w[1] > w[0]), "{xs:?}");
        assert_eq!(xs[3] - xs[2], 14.0);
        assert_eq!(xs[4] - xs[3], 4.0);
    }

    #[test]
    fn health_texts_name_the_counts() {
        let h = sq_core_project::relink_scoring::ProjectHealth { in_folder: 312, outside: 4, missing: 1 };
        let t = ProjectListView::health_texts(&h);
        assert_eq!(
            t.iter().map(|(p, _)| *p).collect::<Vec<_>>(),
            [HealthPart::InFolder, HealthPart::Outside, HealthPart::Missing]
        );
        assert_eq!((t[0].1.as_str(), t[2].1.as_str()), ("312 in folder", "1 missing"));
        let two = sq_core_project::relink_scoring::ProjectHealth { in_folder: 0, outside: 0, missing: 2 };
        assert_eq!(
            ProjectListView::health_texts(&two),
            [(HealthPart::InFolder, "0 in folder".to_string()), (HealthPart::Missing, "2 missing".to_string())]
        );
        assert_eq!(ProjectListView::fix_label(), "Fix…");
        let healthy = sq_core_project::relink_scoring::ProjectHealth { in_folder: 2, outside: 0, missing: 0 };
        assert_eq!(ProjectListView::health_texts(&healthy), [(HealthPart::InFolder, "2 in folder".to_string())]);
    }

    #[test]
    fn locate_relinks_at_once_when_only_files_are_missing() {
        use sq_core_project::relink_scoring::ProjectHealth;
        assert!(ProjectListView::fix_runs_relink(&ProjectHealth { in_folder: 3, outside: 0, missing: 1 }));
        assert!(!ProjectListView::fix_runs_relink(&ProjectHealth { in_folder: 3, outside: 2, missing: 1 }));
        assert!(!ProjectListView::fix_runs_relink(&ProjectHealth { in_folder: 3, outside: 2, missing: 0 }));
    }

    #[test]
    fn the_fix_menu_offers_collect_only_when_it_can() {
        let h = sq_core_project::relink_scoring::ProjectHealth { in_folder: 1, outside: 2, missing: 3 };
        let noop: Rc<dyn Fn(HealthPart)> = Rc::new(|_| {});
        let collect: Rc<dyn Fn()> = Rc::new(|| {});
        let with = ProjectListView::health_menu_items(&h, true, Rc::clone(&noop), Rc::clone(&collect));
        let without = ProjectListView::health_menu_items(&h, false, noop, collect);
        assert_eq!(with.len(), 3);
        assert_eq!(without.len(), 2);
        assert_eq!(with[0].title, "Collect 2 files into project");
    }

    /// Contract U4 for every caller of `ProjectPoster::draw_fit` (the Project icon tile 16:10, the card browser's and
    /// the start screen's 16:9 boxes, a square box and a portrait box): 16:9, 9:16, 1:1 and 4:3 pictures keep their
    /// aspect, show whole (no crop) and leave the bar color in the rest of the box.
    #[test]
    fn a_poster_is_fitted_whole_into_every_tile_shape() {
        use sq_draw::software::{RgbaImage, SoftwareRenderer, Sources};
        const SOURCES: [(f64, f64); 4] = [(1920.0, 1080.0), (1080.0, 1920.0), (1000.0, 1000.0), (1440.0, 1080.0)];
        const BOXES: [(f64, f64); 5] = [(96.0, 60.0), (160.0, 90.0), (90.0, 160.0), (100.0, 100.0), (64.0, 36.0)];
        let (pic, bars) = (Color::rgb(1.0, 0.0, 0.0), Color::rgb(0.0, 0.0, 1.0));
        let at = |img: &RgbaImage, x: f64, y: f64| {
            let i = (y as usize * img.width + x as usize) * 4;
            [img.pixels[i], img.pixels[i + 1], img.pixels[i + 2]]
        };
        for (pw, ph) in SOURCES {
            for (bw, bh) in BOXES {
                let poster = ProjectPoster::new(1, CGSize::new(pw, ph));
                let mut c = Canvas::with_size(200.0, 200.0, None, 1.0);
                let bounds = CGRect::new(20.0, 30.0, bw, bh);
                let got = poster.draw_fit(&mut c, bounds, Some(bars));
                let who = format!("{pw}x{ph} in {bw}x{bh}");
                assert!((got.width / got.height - pw / ph).abs() < 1e-9, "{who}: stretched to {got:?}");
                assert!(
                    got.min_x() >= bounds.min_x() - 1e-9 && got.max_x() <= bounds.max_x() + 1e-9,
                    "{who}: {got:?} leaves the box"
                );
                assert!(
                    got.min_y() >= bounds.min_y() - 1e-9 && got.max_y() <= bounds.max_y() + 1e-9,
                    "{who}: {got:?} leaves the box"
                );
                assert_eq!(got, sq_draw::fit_rect(CGSize::new(pw, ph), bounds), "{who}: not the shared fit");
                let images = [None, Some(RgbaImage::filled(8, 8, pic))];
                let img = SoftwareRenderer::render(
                    &c.list,
                    200,
                    200,
                    Color::BLACK,
                    &Sources { images: &images, ..Default::default() },
                );
                let inside = at(&img, got.mid_x(), got.mid_y());
                assert_eq!(inside, [255, 0, 0], "{who}: the picture is in the middle");
                // The picture covers its whole rect (nothing cropped) and the box corners outside it are bars.
                for (x, y) in [(got.min_x() + 1.5, got.min_y() + 1.5), (got.max_x() - 1.5, got.max_y() - 1.5)] {
                    assert_eq!(at(&img, x, y), [255, 0, 0], "{who}: the picture reaches its own corners");
                }
                let wide = got.width < bounds.width - 1.0;
                let probe =
                    if wide { (bounds.min_x() + 0.5, bounds.mid_y()) } else { (bounds.mid_x(), bounds.min_y() + 0.5) };
                if got.width < bounds.width - 1.0 || got.height < bounds.height - 1.0 {
                    assert_eq!(at(&img, probe.0, probe.1), [0, 0, 255], "{who}: the bars show the bar color");
                }
            }
        }
    }

    #[test]
    fn column_frames_give_name_what_the_others_leave() {
        let mut rig = Rig::new();
        let v = list();
        let cx = rig.cx();
        let f = v.column_frames(&cx, None);
        assert_eq!(f[0].column, Column::Name);
        assert_eq!(f[0].min_x, 0.0);
        assert_eq!(f.last().map(|c| c.max_x), Some(600.0));
        assert!(f.windows(2).all(|w| w[0].max_x == w[1].min_x));
    }

    #[test]
    fn a_row_dropped_on_a_folder_settles_the_chip_onto_it() {
        sq_draw::motion::set_reduce_motion(false);
        let mut rig = Rig::new();
        let mut v = list();
        {
            let cx = rig.cx();
            cx.model.new_bin(cx.session, "Shots").expect("folder");
        }
        let y0 = v.chrome_height(&rig.model);
        let (row0, folder_row) = (y0 + ProjectListView::ROW_HEIGHT * 0.5, y0 + ProjectListView::ROW_HEIGHT * 1.5);
        let mut cx = rig.cx();
        v.handle(&mut cx, &mouse_down(300.0, row0, InputModifiers::NONE), 1.0);
        v.handle(&mut cx, &InputEvent::dragged(560.0, folder_row as f32), 1.0);
        assert!(cx.ui.drag_preview.is_some(), "the chip follows the pointer");
        v.handle(&mut cx, &InputEvent::MouseUp { x: 560.0, y: folder_row as f32 }, 1.0);
        assert!(cx.ui.drag_preview.is_none());
        assert!(cx.ui.settling_chip().is_some(), "the chip settles onto the folder instead of only vanishing");
        cx.ui.press();
        assert!(cx.ui.settling_chip().is_none(), "a press lands it at once");
    }

    #[test]
    fn dragging_onto_a_folder_row_moves_into_it() {
        let mut rig = Rig::new();
        let mut v = list();
        let folder = {
            let cx = rig.cx();
            cx.model.new_bin(cx.session, "Shots").expect("folder")
        };
        let y0 = v.chrome_height(&rig.model);
        let cx = rig.cx();
        // row 0: the sequence, row 1: the folder (middle of the row)
        let t = v.compute_move_target(
            &cx,
            CGPoint::new(100.0, y0 + ProjectListView::ROW_HEIGHT * 1.5),
            &[BinItemRef::Sequence(Id::fixed(9))],
        );
        let t = t.expect("a target");
        assert_eq!((t.bin, t.is_line), (folder, false));
        // the top quarter of the row inserts between rows
        let t = v.compute_move_target(
            &cx,
            CGPoint::new(100.0, y0 + ProjectListView::ROW_HEIGHT + 2.0),
            &[BinItemRef::Sequence(Id::fixed(9))],
        );
        assert!(t.is_some_and(|t| t.is_line));
        // a folder never goes into itself
        assert!(
            v.compute_move_target(
                &cx,
                CGPoint::new(100.0, y0 + ProjectListView::ROW_HEIGHT * 1.5),
                &[BinItemRef::Bin(folder)]
            )
            .is_none()
        );
    }

    #[test]
    fn the_insertion_line_shows_with_a_sort_or_filter_but_the_drop_appends() {
        // Swift `theInsertionLineShowsWithASortOrFilterButTheDropAppends` and the empty-space append.
        let mut rig = Rig::new();
        let mut v = list();
        let (a, b) = {
            let cx = rig.cx();
            (cx.model.new_bin(cx.session, "A").expect("a"), cx.model.new_bin(cx.session, "B").expect("b"))
        };
        let root = rig.model.project().root_bin.id;
        let line = |v: &mut ProjectListView, rig: &mut Rig| {
            let m = &rig.model;
            let ib = v.rows(m).iter().position(|r| r.item_ref == BinItemRef::Bin(b)).expect("row of B");
            let y = v.row_rect(m, ib).min_y() + 1.0;
            let cx = rig.cx();
            v.compute_move_target(&cx, CGPoint::new(100.0, y), &[BinItemRef::Bin(a)]).expect("a target")
        };
        let plain = line(&mut v, &mut rig);
        assert!(plain.is_line && plain.index.is_some());
        rig.model.set_sort(Some(Column::Name), false);
        let sorted = line(&mut v, &mut rig);
        assert!(sorted.is_line && sorted.index.is_none() && sorted.bin == root);
        rig.model.set_sort(None, true);
        rig.model.set_search_text("B");
        let filtered = line(&mut v, &mut rig);
        assert!(filtered.is_line && filtered.index.is_none());
        rig.model.set_search_text("");
        let cx = rig.cx();
        let empty = v
            .compute_move_target(&cx, CGPoint::new(10.0, v.list_rect(&*cx.model).max_y() - 2.0), &[BinItemRef::Bin(a)])
            .expect("root target");
        assert!(!empty.is_line && empty.bin == root && empty.index.is_none());
    }

    #[test]
    fn a_click_on_a_column_title_sorts_and_again_flips() {
        let mut rig = Rig::new();
        let mut v = list();
        {
            let cx = rig.cx();
            cx.model.new_bin(cx.session, "B").expect("b");
            cx.model.new_bin(cx.session, "A").expect("a");
        }
        ProjectListView::sort_by(&mut rig.model, Column::Name);
        assert_eq!((rig.model.sort_column(), rig.model.sort_ascending()), (Some(Column::Name), true));
        ProjectListView::sort_by(&mut rig.model, Column::Name);
        assert!(!rig.model.sort_ascending());
        let _ = &mut v;
    }

    #[test]
    fn the_icon_grid_enters_a_folder_and_goes_back_up() {
        let mut rig = Rig::new();
        let mut v = list();
        let folder = {
            let cx = rig.cx();
            cx.model.new_bin(cx.session, "Shots").expect("folder")
        };
        v.set_view_mode(&mut rig.model, ViewMode::Icons);
        assert!(v.take_events().iter().any(|e| matches!(e, ProjectListEvent::SettingsChanged)));
        v.enter(&mut rig.model, folder);
        assert_eq!(v.crumb_path(&rig.model), "Project / Shots");
        v.go_up(&mut rig.model);
        assert_eq!(v.crumb_path(&rig.model), "Project");
        assert_eq!(v.selection(), [BinItemRef::Bin(folder)]);
    }

    #[test]
    fn view_commands_step_thumbnails_and_flash_hover_scrub() {
        use sq_uikit::editor_command::EditorCommand as C;
        let mut rig = Rig::new();
        let mut v = list();
        // List view: the thumbnail keys do nothing.
        assert_eq!(v.run_view_command(&mut rig.model, C::ProjectThumbnailLarger), None);
        assert_eq!(v.settings.thumb_size, 96.0);
        v.run_view_command(&mut rig.model, C::ProjectIconView);
        v.run_view_command(&mut rig.model, C::ProjectThumbnailLarger);
        assert_eq!(v.settings.thumb_size, 112.0);
        v.run_view_command(&mut rig.model, C::ProjectThumbnailSmaller);
        v.run_view_command(&mut rig.model, C::ProjectThumbnailSmaller);
        assert_eq!(v.settings.thumb_size, 80.0);
        for _ in 0..9 {
            v.run_view_command(&mut rig.model, C::ProjectThumbnailSmaller);
        }
        assert_eq!(v.settings.thumb_size, 64.0);
        assert_eq!(v.run_view_command(&mut rig.model, C::ToggleHoverScrub).as_deref(), Some("Hover Scrub on"));
        assert_eq!(v.run_view_command(&mut rig.model, C::ToggleHoverScrub).as_deref(), Some("Hover Scrub off"));
    }

    #[test]
    fn the_item_count_text_counts_sequences_and_clips() {
        let rig = Rig::new();
        let v = list();
        assert_eq!(v.item_count_text(&rig.model), "1 item");
    }

    #[test]
    fn toggling_a_column_asks_the_owner_to_persist() {
        let mut v = list();
        v.toggle_column(Column::Codec);
        assert!(v.settings().columns.is_visible(Column::Codec));
        assert!(matches!(v.take_events().as_slice(), [ProjectListEvent::SettingsChanged]));
        v.reset_columns();
        assert!(!v.settings().columns.is_visible(Column::Codec));
    }

    #[test]
    fn view_mode_names_round_trip() {
        for m in [ViewMode::List, ViewMode::Icons] {
            assert_eq!(ViewMode::from_raw(m.raw_value()), Some(m));
        }
        assert_eq!(ViewMode::from_raw("x"), None);
    }
}
