// Swift: ShellDock.swift, ShellDock+Draw.swift
//! The dockable panel layout on the canvas: the Mac `WorkspaceHostView` (one card per tab group, 2 pt gaps),
//! `DividerSplitView` (drag a gap to resize, panels never squeezed under their minimum), `PanelContainerView` / `TabStrip`
//! (tab strip on top, the timeline-only group without one) and `DockDragSession` (drag a tab onto another group's edge or
//! strip, reorder inside its own strip) translated. The layouts are the shared `WorkspaceStore` (built-ins, the user's
//! workspaces, fractions, hidden panels), saved per workspace like the Mac `workspaces.json`.
//! Coordinates are points; events come in pixels with the scale.
//!
//! Mapping: the hooks `onFocus`, `save`, `presentMenu`, `onChange`, `floatPanel` and `floating.raise` are [`DockEvent`]s the
//! host drains with [`ShellDock::take_events`]. A tab menu row queues a [`TabAction`]; [`ShellDock::run_tab_actions`] performs
//! them after the menu closed. The text measure borrows the glyph atlas, so the dock keeps only the tab title widths of the
//! last [`ShellDock::set_measure`] and lays out from them (the `measure` property of the Swift class).

use crate::shell_floating::ShellFloating;
use sq_draw::theme::{metrics, radius, spacing};
use sq_draw::{Canvas, Color, DrawTheme, InputEvent, InputKey, InputModifiers, TextAlign, TextMeasure};
use sq_editor_session::{
    DropZone, FloatingPanelState, LayoutMetrics, LayoutNode, SplitAxis, TabReorder, Workspace, WorkspacePage,
    WorkspaceStore,
};
use sq_os::Platform;
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::keyframe_graph_geometry::{Point, Rect};
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

/// The tab of a drop that settles: its title, the landing rectangle and the offset it was dropped at.
#[derive(Clone, Copy, Debug, PartialEq)]
struct SettleTab {
    panel: PanelID,
    to: CGRect,
    from: CGPoint,
    offset: CGPoint,
}

/// One tab group on screen.
#[derive(Clone, Debug, PartialEq)]
pub struct Group {
    /// Tabs in order.
    pub panels: Vec<PanelID>,
    /// The tab on show.
    pub selected: PanelID,
    /// The card.
    pub frame: CGRect,
    /// The tab strip (zero height when the group shows none).
    pub strip: CGRect,
    /// Where the selected panel draws.
    pub content: CGRect,
    /// One frame per panel in `panels` (zero width when it does not fit the strip).
    pub tabs: Vec<CGRect>,
    /// A floating panel's rectangle on the shared canvas (`ShellFloating`): the strip is its title row.
    pub is_floating: bool,
    /// The head carries the shared "..." button (a panel with an options button of its own, such as Project and the Marker
    /// list, keeps that one as its "...").
    pub more: bool,
}

impl Group {
    /// The part of the strip the panel's own tools (item count, New Folder, options) may use: a floating window's title
    /// row keeps its Dock and Close buttons at the right end, so the tools stop short of them and never overlap.
    pub fn tools_strip(&self) -> CGRect {
        if self.is_floating {
            let w = (self.strip.width - ShellFloating::buttons_width()).max(0.0);
            CGRect::new(self.strip.min_x(), self.strip.min_y(), w, self.strip.height)
        } else if self.more_rect().is_some() {
            let w = (self.strip.width - ShellDock::MORE_WIDTH).max(0.0);
            CGRect::new(self.strip.min_x(), self.strip.min_y(), w, self.strip.height)
        } else {
            self.strip
        }
    }

    /// The "..." button at the right end of a docked panel head (H10): every docked strip has it except the Tools column
    /// and a floating window (its title row has Dock and Close).
    pub fn more_rect(&self) -> Option<CGRect> {
        (self.more && !self.is_floating && self.strip.height > 0.0).then(|| {
            CGRect::new(self.strip.max_x() - ShellDock::MORE_WIDTH + 2.0, self.strip.mid_y() - 11.0, 22.0, 22.0)
        })
    }
}

/// One gap between two children of a split.
#[derive(Clone, Debug, PartialEq)]
pub struct Divider {
    /// The split's visible path (`Workspace::set_fractions`).
    pub path: Vec<usize>,
    /// The gap lies after child `index`.
    pub index: usize,
    /// The split direction.
    pub axis: SplitAxis,
    /// The drawn 2 pt gap.
    pub frame: CGRect,
    /// Lengths of the split's children along the axis at layout time.
    pub lengths: Vec<f64>,
    /// Their minimums.
    pub mins: Vec<f64>,
}

impl Divider {
    /// The drag target: 2 pt over each neighboring card (the Mac `effectiveRect`).
    pub fn hit_frame(&self) -> CGRect {
        if self.axis == SplitAxis::Horizontal { self.frame.inset_by(-2.0, 0.0) } else { self.frame.inset_by(0.0, -2.0) }
    }
}

/// What a released tab drag does.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum DropAction {
    /// Move the tab inside its strip to an index.
    Reorder(PanelID, i64),
    /// Dock the panel onto the group of the anchor panel.
    Dock(PanelID, PanelID, DropZone),
}

/// What a tab drag would do on release (the Mac `DockOverlayView.State`).
#[derive(Clone, Debug, PartialEq)]
pub struct DropTarget {
    /// The group card the pointer is over.
    pub container: CGRect,
    /// The highlighted zone.
    pub zone: Option<DropZone>,
    /// The insertion line of a reorder.
    pub insertion_x: Option<f64>,
    /// The whole strip is highlighted (join as a tab).
    pub strip_highlight: bool,
    /// What the release does.
    pub action: Option<DropAction>,
}

/// What the dock tells the host (the Swift hooks).
#[derive(Clone, Debug)]
pub enum DockEvent {
    /// `onFocus`: the panel with keyboard focus changed.
    Focus(PanelID),
    /// `save`: write `store` (`WorkspaceStore::save`).
    SaveWorkspaces,
    /// `presentMenu`: a right-click menu of a tab at a window point.
    PresentMenu(Vec<SQMenuItem>, CGPoint),
    /// `onChange`: the layout changed (the host relayouts its panels, the menus refresh).
    Changed,
    /// `floatPanel`: the host moves the panel into a window of its own (call [`ShellDock::float`]).
    FloatPanel(PanelID),
    /// `floating.raise`: the host brings the panel's window forward.
    Raise(PanelID),
}

/// A row of a tab's right-click menu, performed by [`ShellDock::run_tab_actions`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TabAction {
    /// Maximize or restore.
    ToggleMaximize(PanelID),
    /// Move to a floating window.
    Float(PanelID),
    /// Close the panel.
    Close(PanelID),
}

#[derive(Clone, Debug)]
enum Press {
    Divider(Divider, CGPoint),
    Tab { panel: PanelID, start: CGPoint, moved: bool },
}

/// The dockable panel layout on the canvas.
pub struct ShellDock {
    store: WorkspaceStore,
    maximized: Option<PanelID>,
    /// The area between the top bar and the status bar.
    pub frame: CGRect,
    tab_widths: HashMap<PanelID, f64>,
    /// Panels that draw a header of their own (the monitors' Program | Source tabs): their group shows no strip.
    pub owns_header: Box<dyn Fn(PanelID) -> bool>,
    /// Width (points) at the right end of a strip whose selected tab is `p` that the panel's host draws and clicks itself
    /// (header detail and buttons, the Mac `PanelHeaderItems`): no tab goes there, the dock ignores presses on it.
    pub strip_tools: Box<dyn Fn(PanelID) -> f64>,
    /// The width the Project list keeps at the end of its own strip (item count, New Folder, "..."), on top of
    /// `strip_tools`; set each layout by the app, so the Color page's `strip_tools` table does not replace it.
    pub project_tools: f64,
    /// What the Library strip keeps free at its right end for its Import... button (Presets mode); set by the app.
    pub library_tools: f64,
    /// Panels whose strip keeps [`ShellDock::OPTIONS_WIDTH`] free for a "..." button the host draws (`PanelStripOptions`).
    pub option_panels: HashSet<PanelID>,
    focused: Option<PanelID>,
    /// False when another dock lays the panels out and draws their focus frame (the app's); this one then only answers commands.
    pub draws_focus_frame: bool,
    /// Per panel: how far its underline has faded to accent (0 neutral, 1 accent) and the clock of the last tick.
    focus_fade: HashMap<PanelID, f64>,
    fade_clock: Option<f64>,
    /// A dropped tab settling into its place (the `Spring` ease, 180 ms); one state, started by `tick`, ended by a press.
    drop_settle: sq_draw::spring::DropSettle,
    /// The tab being settled, the offset from where it was dropped (starts the settle at the next tick) and where it lands.
    settle_tab: Option<SettleTab>,
    /// The last pointer position (points): Maximize Panel Under Pointer.
    pub pointer: Option<CGPoint>,
    groups: Vec<Group>,
    dividers: Vec<Divider>,
    drop_target: Option<DropTarget>,
    drag_tab: Option<(PanelID, CGPoint)>,
    press: Option<Press>,
    transiently_hidden: HashSet<PanelID>,
    /// The panels popped out into windows of their own (`ShellFloating`).
    pub floating: ShellFloating,
    /// The host has floating windows: the tab menu offers "Move to Floating Window".
    pub can_float_windows: bool,
    pub(crate) events: Vec<DockEvent>,
    tab_actions: Rc<RefCell<Vec<TabAction>>>,
}

impl Default for ShellDock {
    fn default() -> Self {
        ShellDock::new(WorkspaceStore::default())
    }
}

impl ShellDock {
    /// The divider thickness.
    pub const GAP: f64 = LayoutMetrics::DIVIDER_THICKNESS;

    /// Height of a tab strip.
    pub const STRIP_HEIGHT: f64 = metrics::PANEL_HEADER as f64;
    /// Height of one tab.
    pub const TAB_HEIGHT: f64 = sq_draw::theme::tab::HEIGHT;
    /// Padding left and right of a tab title.
    pub const TAB_PADDING: f64 = sq_draw::theme::tab::PADDING;
    const TAB_FONT: f64 = 11.0;
    const DRAG_SLOP: f64 = 4.0;

    /// A dock showing `store`.
    pub fn new(store: WorkspaceStore) -> ShellDock {
        ShellDock {
            store,
            maximized: None,
            frame: CGRect::default(),
            tab_widths: HashMap::new(),
            owns_header: Box::new(|_| false),
            strip_tools: Box::new(|_| 0.0),
            project_tools: 0.0,
            library_tools: 0.0,
            option_panels: HashSet::new(),
            focused: None,
            draws_focus_frame: true,
            focus_fade: HashMap::new(),
            fade_clock: None,
            drop_settle: sq_draw::spring::DropSettle::Rest,
            settle_tab: None,
            pointer: None,
            groups: Vec::new(),
            dividers: Vec::new(),
            drop_target: None,
            drag_tab: None,
            press: None,
            transiently_hidden: HashSet::new(),
            floating: ShellFloating::default(),
            can_float_windows: false,
            events: Vec::new(),
            tab_actions: Rc::new(RefCell::new(Vec::new())),
        }
    }

    /// Sets the area between the top bar and the status bar and lays out again.
    pub fn set_frame(&mut self, frame: CGRect) {
        self.frame = frame;
        self.relayout();
    }

    /// Everything the dock wants its host to know since the last call, in order.
    pub fn take_events(&mut self) -> Vec<DockEvent> {
        std::mem::take(&mut self.events)
    }

    /// The window's height below which a released tab is still a dock drop: the dock area plus the status bar under it.
    fn window_height(&self) -> f64 {
        self.frame.max_y() + metrics::STATUS_BAR as f64
    }

    /// The layouts (built-ins, the user's workspaces, fractions, hidden panels).
    pub fn store(&self) -> &WorkspaceStore {
        &self.store
    }

    /// Transient, never saved (the Mac `maximizedPanel`).
    pub fn maximized(&self) -> Option<PanelID> {
        self.maximized
    }

    /// Takes over the maximized panel of the dock this one mirrors (the window's dock and the shell's copy are two docks).
    pub fn adopt_maximized(&mut self, p: Option<PanelID>) {
        if self.maximized != p {
            self.maximized = p;
            self.relayout();
        }
    }

    /// The panel with keyboard focus: its tab underline turns accent.
    pub fn focused(&self) -> Option<PanelID> {
        self.focused
    }

    /// Seconds the underline takes to turn accent (the motion token; the way back takes `motion::duration::exit` of it).
    pub const FOCUS_FADE: f64 = sq_draw::motion::duration::BASE;

    /// How accent the panel's tab underline is right now: 0 neutral, 1 accent. [`Self::tick`] keeps linear progress;
    /// what is drawn is that progress through `OutCubic`.
    pub fn focus_amount(&self, p: PanelID) -> f64 {
        let linear = self.focus_fade.get(&p).copied().unwrap_or(if self.focused == Some(p) { 1.0 } else { 0.0 });
        sq_draw::motion::Ease::OutCubic.apply(linear)
    }

    /// Advances the underline fades to `now` (seconds, steady clock); true while one still runs (the host redraws).
    pub fn tick(&mut self, now: f64) -> bool {
        let settling = self.tick_drop_settle(now);
        let dt = self.fade_clock.map_or(Self::FOCUS_FADE, |t| (now - t).clamp(0.0, Self::FOCUS_FADE));
        self.fade_clock = Some(now);
        let reduce = sq_draw::motion::reduce_motion();
        let step_in = if reduce { 1.0 } else { dt / Self::FOCUS_FADE };
        let step_out = if reduce { 1.0 } else { dt / sq_draw::motion::duration::exit(Self::FOCUS_FADE) };
        let focused = self.focused;
        let mut running = false;
        for p in PanelID::ALL {
            let target = if focused == Some(p) { 1.0 } else { 0.0 };
            let cur = self.focus_fade.get(&p).copied().unwrap_or(target);
            let next = if cur < target { (cur + step_in).min(target) } else { (cur - step_out).max(target) };
            if next != target {
                running = true;
            }
            if next == target && target == 0.0 {
                self.focus_fade.remove(&p);
            } else {
                self.focus_fade.insert(p, next);
            }
        }
        running || settling
    }

    /// Starts a pending drop settle and advances a running one; true while it runs.
    fn tick_drop_settle(&mut self, now: f64) -> bool {
        if let Some(t) = self.settle_tab.as_mut()
            && !self.drop_settle.is_running()
            && t.offset == t.from
        {
            self.drop_settle = sq_draw::spring::DropSettle::drop(t.from, now);
            if !self.drop_settle.is_running() {
                self.settle_tab = None;
                return false;
            }
        }
        let Some(t) = self.settle_tab.as_mut() else { return false };
        t.offset = self.drop_settle.offset(now);
        if !self.drop_settle.is_running() {
            self.settle_tab = None;
            return false;
        }
        true
    }

    /// The dropped tab and where its ghost is now (title rectangle), while it settles.
    pub fn settling_tab(&self) -> Option<(PanelID, CGRect)> {
        let t = self.settle_tab.filter(|_| self.drop_settle.is_running())?;
        Some((t.panel, CGRect::new(t.to.min_x() + t.offset.x, t.to.min_y() + t.offset.y, t.to.width, t.to.height)))
    }

    /// Remembers a dropped tab: its ghost settles from the drop point to the tab's new place.
    fn begin_tab_settle(&mut self, panel: PanelID, dropped_at: CGPoint) {
        let found = self.groups.iter().find_map(|g| {
            let i = g.panels.iter().position(|q| *q == panel)?;
            g.tabs.get(i).copied().filter(|r| r.width > 0.0)
        });
        let Some(to) = found else { return };
        let from = CGPoint { x: dropped_at.x - to.mid_x(), y: dropped_at.y - to.mid_y() };
        self.drop_settle = sq_draw::spring::DropSettle::Rest;
        self.settle_tab = Some(SettleTab { panel, to, from, offset: from });
    }

    /// Sets the focused panel; the host follows through [`DockEvent::Focus`] (the key map's scope).
    pub fn set_focused(&mut self, p: Option<PanelID>) {
        self.focused = p;
        if let Some(f) = p {
            self.events.push(DockEvent::Focus(f));
        }
    }

    /// The width of the options button of a panel's strip.
    pub const OPTIONS_WIDTH: f64 = 28.0;

    /// The width the shared "..." button of a docked panel head keeps free at the strip's right end.
    pub const MORE_WIDTH: f64 = 28.0;

    /// Whether the head of `p` gets the shared "..." button: not the Tools column, and not a panel whose tools or options
    /// button already holds the head's right end (Project, Marker list, the Color page's strips).
    fn shows_more(&self, p: PanelID) -> bool {
        p != PanelID::Tools && p != PanelID::Project && !self.option_panels.contains(&p) && (self.strip_tools)(p) <= 0.0
    }

    /// What the strip of `p` keeps free at its right end: the host's tools and the options button.
    pub fn tools_width(&self, p: PanelID) -> f64 {
        (self.strip_tools)(p)
            + if p == PanelID::Project { self.project_tools } else { 0.0 }
            + if p == PanelID::Library { self.library_tools } else { 0.0 }
            + if self.option_panels.contains(&p) { Self::OPTIONS_WIDTH } else { 0.0 }
    }

    /// The options button of `p` in window points; `None` while `p` is not the shown tab of a group with a strip.
    pub fn options_rect(&self, p: PanelID) -> Option<CGRect> {
        let g = self.groups.iter().find(|g| g.selected == p && g.strip.height > 0.0)?;
        self.option_panels.contains(&p).then(|| {
            let strip = g.tools_strip();
            CGRect::new(strip.max_x() - Self::OPTIONS_WIDTH + 2.0, strip.mid_y() - 11.0, 22.0, 22.0)
        })
    }

    /// The tab groups on screen, floating windows last.
    pub fn groups(&self) -> &[Group] {
        &self.groups
    }

    /// The gaps between neighbors.
    pub fn dividers(&self) -> &[Divider] {
        &self.dividers
    }

    /// What the tab being dragged would do.
    pub fn drop_target(&self) -> Option<&DropTarget> {
        self.drop_target.as_ref()
    }

    /// The tab being dragged (its ghost follows the pointer).
    pub fn drag_tab(&self) -> Option<(PanelID, CGPoint)> {
        self.drag_tab
    }

    /// Takes the saved layouts (at launch: `WorkspaceStore::load`).
    pub fn load(&mut self, s: WorkspaceStore) {
        self.store = s;
        self.maximized = None;
        self.relayout();
        self.events.push(DockEvent::Changed);
    }

    /// Panels left out of the layout without touching the stored workspace.
    pub fn transiently_hidden(&self) -> &HashSet<PanelID> {
        &self.transiently_hidden
    }

    /// Panels left out of the layout without touching the stored workspace (shown, not stored: the Color page hides Steps
    /// while the grade is Simple, the Mac `applyWorkspace`). Their Window rows are unchecked and disabled, and `toggle` /
    /// `show` leave them hidden.
    pub fn set_transiently_hidden(&mut self, hidden: HashSet<PanelID>) {
        if hidden == self.transiently_hidden {
            return;
        }
        self.transiently_hidden = hidden;
        if let Some(m) = self.maximized
            && self.transiently_hidden.contains(&m)
        {
            self.maximized = None;
        }
        self.relayout();
    }

    /// The workspace on screen with the transient maximize and hides applied.
    pub fn workspace(&self) -> Workspace {
        let mut w = self.store.current();
        let hidden: Vec<PanelID> = self.transiently_hidden.union(&self.floating.panels()).copied().collect();
        for p in hidden {
            w.hide(p);
        }
        w.maximized = self.maximized.filter(|m| w.is_visible(*m));
        w
    }

    /// The visible panels (Window menu check marks).
    pub fn visible_panels(&self) -> HashSet<PanelID> {
        // Real visibility: floating, or the selected tab of its group. A background tab is not checked.
        let mut cur = self.store.current();
        cur.maximized = None;
        cur.all_panels()
            .into_iter()
            .filter(|p| cur.is_visible(*p))
            .filter(|p| !self.transiently_hidden.contains(p))
            .filter(|p| self.floating.is_floating(*p) || cur.shows_tab(*p))
            .collect()
    }

    /// Where `p` draws, when it is the selected tab of a group on screen.
    pub fn content_frame(&self, p: PanelID) -> Option<CGRect> {
        self.groups.iter().find(|g| g.selected == p).map(|g| g.content)
    }

    /// The one monitor card (Program and Source share it and its picture): a floating monitor's window below its title row,
    /// else the docked card; a floating monitor wins over a docked one.
    pub fn monitor_card(&self) -> Option<CGRect> {
        let shown: Vec<&Group> = self
            .groups
            .iter()
            .filter(|g| g.selected == PanelID::ProgramMonitor || g.selected == PanelID::SourceMonitor)
            .collect();
        let g = shown
            .iter()
            .find(|g| g.is_floating)
            .or_else(|| shown.iter().find(|g| g.selected == PanelID::ProgramMonitor))
            .or_else(|| shown.first())?;
        Some(if g.is_floating { g.content } else { g.frame })
    }

    /// The group draws the monitor card (the other monitor group shows a placeholder).
    pub fn is_monitor_card(&self, g: &Group) -> bool {
        Some(if g.is_floating { g.content } else { g.frame }) == self.monitor_card()
    }

    /// The card of the group showing `p` as its selected tab.
    pub fn card_frame(&self, p: PanelID) -> Option<CGRect> {
        self.groups.iter().find(|g| g.selected == p).map(|g| g.frame)
    }

    /// The selected panel of the group under `p` (points).
    pub fn panel_at(&self, p: CGPoint) -> Option<PanelID> {
        self.groups.iter().find(|g| g.frame.contains(p)).map(|g| g.selected)
    }

    /// The panel is the shown tab of its group.
    pub fn shows(&self, p: PanelID) -> bool {
        self.content_frame(p).is_some()
    }

    // MARK: Layout

    /// Remembers the width of every tab title at `m`'s scale and lays out again when one changed.
    pub fn set_measure(&mut self, m: &TextMeasure) {
        let widths: HashMap<PanelID, f64> = PanelID::ALL
            .into_iter()
            .map(|p| (p, m.width(&EditorCommand::localized_panel_title(p), Self::TAB_FONT, m.medium()).ceil()))
            .collect();
        if widths != self.tab_widths {
            self.tab_widths = widths;
            self.relayout();
        }
    }

    /// Lays the groups out again (every mutator does it; the host calls it after changing `frame`).
    pub fn relayout(&mut self) {
        self.groups = Vec::new();
        self.dividers = Vec::new();
        let key = FloatingPanelState::key(self.store.page, &self.store.edit_name);
        self.floating.refresh(&key, self.frame.max_x());
        if self.frame.width > 2.0 * Self::GAP
            && self.frame.height > 2.0 * Self::GAP
            && let Some(root) = self.workspace().visible_root()
        {
            self.place(&root, self.frame.inset_by(Self::GAP, Self::GAP), &[]);
        }
        let bar = ShellFloating::TITLE_BAR;
        for w in self.floating.windows().to_vec() {
            self.groups.push(Group {
                panels: vec![w.panel],
                selected: w.panel,
                frame: w.rect,
                strip: CGRect::new(w.rect.min_x(), w.rect.min_y(), w.rect.width, bar),
                content: CGRect::new(
                    w.rect.min_x(),
                    w.rect.min_y() + bar,
                    w.rect.width,
                    (w.rect.height - bar).max(0.0),
                ),
                tabs: vec![CGRect::default()],
                is_floating: true,
                more: false,
            });
        }
    }

    /// The Tools panel is a fixed column (36 pt, the kit's width), not a share of the row: a fraction would make it
    /// 54 pt at 1440 (the 5 % minimum) and wider on a big window. What it gives up goes to the widest neighbor.
    fn pin_tools_column(children: &[LayoutNode], lengths: &mut [f64], mins: &[f64]) {
        let is_tools =
            |n: &LayoutNode| matches!(n, LayoutNode::Tabs { panels, .. } if panels.as_slice() == [PanelID::Tools]);
        for i in (0..children.len()).filter(|i| is_tools(&children[*i])) {
            let delta = lengths[i] - mins[i];
            let Some(j) = (0..children.len())
                .filter(|j| !is_tools(&children[*j]))
                .max_by(|a, b| lengths[*a].total_cmp(&lengths[*b]))
            else {
                continue;
            };
            lengths[i] -= delta;
            lengths[j] += delta;
        }
    }

    fn place(&mut self, node: &LayoutNode, r: CGRect, path: &[usize]) {
        match node {
            LayoutNode::Tabs { panels, selected } => {
                // A group holding only the Timeline shows no title row (its sequence tabs are the header); a panel with a
                // header of its own replaces the strip.
                let bare = panels.as_slice() == [PanelID::Timeline] || (self.owns_header)(*selected);
                let h = if bare { 0.0 } else { Self::STRIP_HEIGHT.min(r.height) };
                let strip = CGRect::new(r.min_x(), r.min_y(), r.width, h);
                let mut tabs = Vec::new();
                // r8 `.hdr` padding-left 6; the title then sits `.tab` padding (8) inside its frame.
                let mut x = r.min_x() + sq_draw::theme::tab::HEADER_INSET;
                let shows_more = !bare && self.shows_more(*selected);
                let more = if shows_more { Self::MORE_WIDTH } else { 0.0 };
                let limit =
                    r.max_x() - spacing::SM as f64 - if bare { 0.0 } else { self.tools_width(*selected) + more };
                let y = (r.min_y() + (h - 1.0 - Self::TAB_HEIGHT) / 2.0).round();
                for p in panels {
                    let w = self.tab_widths.get(p).copied().unwrap_or(0.0) + 2.0 * Self::TAB_PADDING;
                    // A narrow group shows the tabs that fit.
                    // The Tools panel is a 36 pt column: its grip stands where a tab would.
                    if bare || *p == PanelID::Tools || x + w > limit {
                        tabs.push(CGRect::new(x, y, 0.0, 0.0));
                        continue;
                    }
                    tabs.push(CGRect::new(x, y, w, Self::TAB_HEIGHT));
                    x += w + 2.0;
                }
                self.groups.push(Group {
                    panels: panels.clone(),
                    selected: *selected,
                    frame: r,
                    strip,
                    content: CGRect::new(r.min_x(), r.min_y() + h, r.width, (r.height - h).max(0.0)),
                    tabs,
                    is_floating: false,
                    more: shows_more,
                });
            }
            LayoutNode::Split { axis, children, fractions } => {
                let total = if *axis == SplitAxis::Horizontal { r.width } else { r.height };
                let gap = Self::GAP;
                let length = (total - gap * (children.len() as f64 - 1.0)).max(0.0);
                let mins = LayoutMetrics::child_minimums(*axis, children);
                let f = LayoutMetrics::clamped_fractions(fractions, length, &mins);
                let mut lengths: Vec<f64> = Vec::new();
                let mut used = 0.0;
                for i in 0..children.len() {
                    let l = if i == children.len() - 1 { length - used } else { (f[i] * length).round() };
                    lengths.push(l.max(0.0));
                    used += lengths[i];
                }
                if *axis == SplitAxis::Horizontal {
                    Self::pin_tools_column(children, &mut lengths, &mins);
                }
                let mut pos = if *axis == SplitAxis::Horizontal { r.min_x() } else { r.min_y() };
                for (i, c) in children.iter().enumerate() {
                    let l = lengths[i];
                    let cr = if *axis == SplitAxis::Horizontal {
                        CGRect::new(pos, r.min_y(), l, r.height)
                    } else {
                        CGRect::new(r.min_x(), pos, r.width, l)
                    };
                    let mut child_path = path.to_vec();
                    child_path.push(i);
                    self.place(c, cr, &child_path);
                    pos += l;
                    if i < children.len() - 1 {
                        let g = if *axis == SplitAxis::Horizontal {
                            CGRect::new(pos, r.min_y(), gap, r.height)
                        } else {
                            CGRect::new(r.min_x(), pos, r.width, gap)
                        };
                        self.dividers.push(Divider {
                            path: path.to_vec(),
                            index: i,
                            axis: *axis,
                            frame: g,
                            lengths: lengths.clone(),
                            mins: mins.clone(),
                        });
                        pos += gap;
                    }
                }
            }
        }
    }

    // MARK: Workspace changes (the Mac `mutateWorkspace` and the Window menu actions)

    /// Edits the on-screen workspace and stores it.
    pub fn mutate(&mut self, body: impl FnOnce(&mut Workspace)) {
        let mut w = self.store.current();
        body(&mut w);
        self.store.update_current(&w);
        self.commit();
    }

    fn commit(&mut self) {
        self.events.push(DockEvent::SaveWorkspaces);
        self.relayout();
        self.events.push(DockEvent::Changed);
    }

    /// Window > panel row from a click: shows or hides it (`windowPanelItem`).
    pub fn toggle(&mut self, p: PanelID) {
        if self.transiently_hidden.contains(&p) {
            return;
        }
        if self.floating.is_floating(p) {
            // A floating panel's Window row closes it (Swift `toggle`); the shortcut (`show`) brings its window forward.
            self.close_floating(p);
            return;
        }
        if self.store.current().is_visible(p) && !self.visible_panels().contains(&p) {
            // Checked in the store but behind another tab: the row brings it forward.
            self.show(p);
            return;
        }
        self.maximized = None;
        let was = self.store.current().is_visible(p);
        self.mutate(|w| w.toggle(p));
        if !was {
            self.set_focused(Some(p));
        }
    }

    /// The panel's shortcut or a request from another panel: shown and selected in its group (`showPanel`).
    pub fn show(&mut self, p: PanelID) {
        if self.transiently_hidden.contains(&p) {
            return;
        }
        if self.floating.is_floating(p) {
            // Its window comes forward.
            self.set_focused(Some(p));
            self.floating.raise(p);
            self.events.push(DockEvent::Raise(p));
            return;
        }
        if self.maximized.is_some() && self.maximized != Some(p) {
            self.maximized = None;
        }
        self.mutate(|w| w.show(p));
        self.set_focused(Some(p));
    }

    /// Same as [`ShellDock::show`].
    pub fn select(&mut self, p: PanelID) {
        self.show(p);
    }

    /// Hides the panel.
    pub fn close(&mut self, p: PanelID) {
        self.maximized = None;
        self.mutate(|w| w.hide(p));
        if self.focused == Some(p) {
            let next = if self.store.current().is_visible(PanelID::Timeline) { Some(PanelID::Timeline) } else { None };
            self.focused = next;
            if let Some(f) = next {
                self.events.push(DockEvent::Focus(f));
            }
        }
    }

    /// Maximize or restore the panel.
    pub fn toggle_maximize(&mut self, p: PanelID) {
        // A floating panel's window fills its display (the Mac `toggleFloatingZoom`).
        if self.floating.is_floating(p) {
            self.toggle_floating_zoom(p);
            return;
        }
        self.maximized = if self.maximized == Some(p) { None } else { Some(p) };
        self.set_focused(Some(p));
        self.relayout();
        self.events.push(DockEvent::Changed);
    }

    /// The Edit | Color switch (the Mac `toolbarPage`): the Color page opens on its Color tab.
    pub fn set_page(&mut self, p: WorkspacePage) {
        if self.store.page == p {
            return;
        }
        self.store.set_page(p);
        if p == WorkspacePage::Color {
            let before = self.store.color_page();
            let mut c = before.clone();
            c.select_tab(PanelID::ColorInspector);
            // No override stored for a page switch alone.
            if c != before {
                self.store.set_color_page(c);
            }
        }
        self.maximized = None;
        self.commit();
    }

    /// Picks the Edit workspace `name`.
    pub fn choose_workspace(&mut self, name: &str) {
        if !self.store.select_edit(name) {
            return;
        }
        self.maximized = None;
        self.commit();
    }

    /// Save as New Workspace: a numbered copy for a taken name. Returns the name used.
    pub fn save_as_new(&mut self, name: &str) -> Option<String> {
        let n = name.trim();
        if n.is_empty() {
            return None;
        }
        let used = self.store.save_current_as_new(n);
        self.commit();
        Some(used)
    }

    /// Renames the current user workspace.
    pub fn rename_current(&mut self, name: &str) -> bool {
        if !self.store.rename_current(name.trim()) {
            return false;
        }
        self.commit();
        true
    }

    /// Deletes the current user workspace.
    pub fn delete_current(&mut self) -> bool {
        if !self.store.delete_current() {
            return false;
        }
        self.maximized = None;
        self.commit();
        true
    }

    /// Reset to Saved Layout.
    pub fn reset_layout(&mut self) {
        self.dock_all_floating();
        if self.store.page != WorkspacePage::Edit {
            self.store.reset_current_color();
            self.maximized = None;
            self.commit();
            return;
        }
        let name = self.store.edit_name.clone();
        if !self.store.library.reset_built_in(&name) {
            return;
        }
        self.maximized = None;
        self.commit();
    }

    /// Reset All Workspaces.
    pub fn reset_all(&mut self) {
        self.dock_all_floating();
        self.store.library.reset_all_built_ins();
        self.store.reset_all_color();
        self.maximized = None;
        self.commit();
    }

    /// Right-click menu of a tab (`tabContextItems`). The rows queue a [`TabAction`].
    pub fn tab_menu(&self, p: PanelID) -> Vec<SQMenuItem> {
        let queue = |a: TabAction| -> Option<Rc<dyn Fn()>> {
            let q = Rc::clone(&self.tab_actions);
            Some(Rc::new(move || q.borrow_mut().push(a)))
        };
        let zoomed = self.maximized == Some(p) || self.floating.is_zoomed(p);
        let mut max = SQMenuItem::new(if zoomed { "Restore Panel Size" } else { "Maximize Panel" });
        // The key of the map in the system's own spelling (the grave key is "Backtick" on a US PC, the `^` key on a German one).
        max.shortcut = CommandMap::with_current(|m| m.shown_binding_here(&EditorCommand::MaximizePanel))
            .map(|b| KeyBindingText::text(&b, Platform::current()))
            .unwrap_or_default();
        max.action = queue(TabAction::ToggleMaximize(p));
        let mut items = vec![max];
        if ShellFloating::can_float(p) && self.can_float_windows {
            let mut f = SQMenuItem::new("Move to Floating Window");
            f.action = queue(TabAction::Float(p));
            items.push(f);
        }
        let mut close = SQMenuItem::new("Close Panel");
        close.action = queue(TabAction::Close(p));
        items.push(close);
        items
    }

    /// The "..." menu of a head that keeps its own options button (Project, Marker list, a Color strip): its own `items`,
    /// then the shared rows of every panel's "..." under a separator. `maximize_only` keeps just Maximize (a Color page
    /// strip is not a panel to float or close). The rows queue [`TabAction`]s like the tab menu's.
    pub fn with_panel_rows(&self, p: PanelID, mut items: Vec<SQMenuItem>, maximize_only: bool) -> Vec<SQMenuItem> {
        let shared = self.tab_menu(p);
        if !items.is_empty() {
            items.push(SQMenuItem::separator());
        }
        items.extend(shared.into_iter().take(if maximize_only { 1 } else { usize::MAX }));
        items
    }

    /// Performs the rows picked in a tab menu (call after the menu closed).
    pub fn run_tab_actions(&mut self) {
        let queued: Vec<TabAction> = self.tab_actions.borrow_mut().drain(..).collect();
        for a in queued {
            match a {
                TabAction::ToggleMaximize(p) => self.toggle_maximize(p),
                TabAction::Float(p) => self.events.push(DockEvent::FloatPanel(p)),
                TabAction::Close(p) => self.close(p),
            }
        }
    }

    // MARK: Events

    /// True while a divider or tab press is being tracked (the host sends it the drags and the release first).
    pub fn is_tracking(&self) -> bool {
        self.press.is_some()
    }

    /// One event in pixels; true when the dock took it (a divider, a tab, a strip).
    pub fn handle(&mut self, e: &InputEvent, scale: f32) -> bool {
        let k = f64::from(scale.max(0.01));
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x) / k, f64::from(y) / k);
        match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                self.pointer = Some(pt(x, y));
                self.mouse_down(pt(x, y), modifiers)
            }
            InputEvent::MouseDragged { x, y, .. } => self.mouse_dragged(pt(x, y)),
            InputEvent::MouseUp { x, y } => self.mouse_up(pt(x, y)),
            InputEvent::KeyDown { key, .. } => {
                if self.press.is_none() || key != InputKey::Escape {
                    return false;
                }
                self.press = None;
                self.drop_target = None;
                self.drag_tab = None;
                true
            }
            InputEvent::MouseMoved { x, y } => {
                self.pointer = Some(pt(x, y));
                false
            }
            _ => false,
        }
    }

    /// The pointer is over a divider: the host shows the resize cursor.
    pub fn divider_at(&self, p: CGPoint) -> Option<&Divider> {
        self.dividers.iter().find(|d| d.hit_frame().contains(p))
    }

    fn mouse_down(&mut self, p: CGPoint, m: InputModifiers) -> bool {
        // A press catches a settling drop where it is (it lands at once).
        self.drop_settle.press();
        self.settle_tab = None;
        let secondary = m.contains(InputModifiers::SECONDARY);
        if !self.floating.windows().is_empty()
            && let Some(h) = self.floating.hit(p)
        {
            self.set_focused(Some(h.panel()));
            return self.floating_press(p) && !secondary;
        }
        if !secondary && let Some(d) = self.divider_at(p).cloned() {
            self.press = Some(Press::Divider(d, p));
            return true;
        }
        let Some(g) = self.groups.iter().find(|g| g.strip.contains(p)).cloned() else { return false };
        if !secondary && let Some(more) = g.more_rect() {
            if more.contains(p) {
                // The shared head menu (H10): the same rows as the tab's right-click menu, under the button.
                self.set_focused(Some(g.selected));
                let items = self.tab_menu(g.selected);
                self.events.push(DockEvent::PresentMenu(items, CGPoint::new(more.max_x(), more.max_y() + 2.0)));
                return true;
            }
            if p.x >= more.min_x() - self.tools_width(g.selected) {
                return false;
            }
        } else if p.x >= g.strip.max_x() - self.tools_width(g.selected) && !secondary {
            return false;
        }
        if let Some(i) = g.tabs.iter().position(|t| t.width > 0.0 && t.contains(p)) {
            let panel = g.panels[i];
            if secondary {
                let items = self.tab_menu(panel);
                self.events.push(DockEvent::PresentMenu(items, p));
                return true;
            }
            self.press = Some(Press::Tab { panel, start: p, moved: false });
            self.set_focused(Some(panel));
            return true;
        }
        if secondary {
            let items = self.tab_menu(g.selected);
            self.events.push(DockEvent::PresentMenu(items, p));
        } else if g.panels == [PanelID::Tools] {
            // The grip of the Tools column moves the panel like a tab does.
            self.press = Some(Press::Tab { panel: PanelID::Tools, start: p, moved: false });
        }
        self.set_focused(Some(g.selected));
        true
    }

    /// A press inside a panel's content: that panel becomes the active one (no event while it already is).
    pub fn focus_press(&mut self, p: PanelID) {
        if self.focused != Some(p) {
            self.set_focused(Some(p));
        }
    }

    fn mouse_dragged(&mut self, p: CGPoint) -> bool {
        match self.press.clone() {
            Some(Press::Divider(d, start)) => {
                let delta = if d.axis == SplitAxis::Horizontal { p.x - start.x } else { p.y - start.y };
                self.mutate_fractions(&d, delta);
                true
            }
            Some(Press::Tab { panel, start, moved }) => {
                if !moved && (p.x - start.x).hypot(p.y - start.y) <= Self::DRAG_SLOP {
                    return true;
                }
                self.press = Some(Press::Tab { panel, start, moved: true });
                self.drag_tab = Some((panel, p));
                self.drop_target = self.target(p, panel);
                true
            }
            None => false,
        }
    }

    fn mouse_up(&mut self, p: CGPoint) -> bool {
        let press = self.press.take();
        let handled = self.finish_press(press, p);
        self.drop_target = None;
        self.drag_tab = None;
        handled
    }

    fn finish_press(&mut self, press: Option<Press>, p: CGPoint) -> bool {
        match press {
            Some(Press::Divider(..)) => {
                self.events.push(DockEvent::SaveWorkspaces);
                true
            }
            Some(Press::Tab { panel, moved, .. }) => {
                if !moved {
                    self.select(panel);
                    return true;
                }
                let window = CGSize::new(self.frame.max_x(), self.window_height());
                if self.tear_off(panel, p, window) {
                    return true;
                }
                match self.target(p, panel).and_then(|t| t.action) {
                    Some(DropAction::Reorder(q, i)) => {
                        self.mutate(|w| {
                            w.move_tab(q, i);
                        });
                        self.begin_tab_settle(panel, p);
                    }
                    Some(DropAction::Dock(q, anchor, zone)) => {
                        self.maximized = None;
                        self.mutate(|w| {
                            w.dock(q, anchor, zone);
                        });
                        self.begin_tab_settle(panel, p);
                    }
                    None => {}
                }
                true
            }
            None => false,
        }
    }

    /// The Mac `DividerSplitView` drag: the two neighbors trade length, each kept at its minimum.
    fn mutate_fractions(&mut self, d: &Divider, delta: f64) {
        let mut l = d.lengths.clone();
        let (i, j) = (d.index, d.index + 1);
        let pair = l[i] + l[j];
        let a = (l[i] + delta).max(d.mins[i]).min((pair - d.mins[j]).max(d.mins[i]));
        l[i] = a;
        l[j] = pair - a;
        let sum: f64 = l.iter().sum();
        if sum <= 0.0 {
            return;
        }
        let mut w = self.store.current();
        let fractions: Vec<f64> = l.iter().map(|v| v / sum).collect();
        if !w.set_fractions(&d.path, &fractions) {
            return;
        }
        self.store.update_current(&w);
        self.relayout();
    }

    /// `DockDragSession.hitTest`: the strip of the own group reorders, another strip joins as a tab, a card's edge
    /// bands split it, its center joins as a tab; a lone panel dropped back onto its own group does nothing.
    pub fn target(&self, p: CGPoint, panel: PanelID) -> Option<DropTarget> {
        let g = self.groups.iter().find(|g| g.frame.contains(p))?;
        let own = g.panels.contains(&panel);
        let rect = g.frame;
        if p.y < rect.min_y() + Self::STRIP_HEIGHT {
            let frames: Vec<&CGRect> = g.tabs.iter().filter(|t| t.width > 0.0).collect();
            if own
                && let Some(cur) = g.panels.iter().position(|q| *q == panel)
                && frames.len() == g.panels.len()
            {
                let mids: Vec<f64> = frames.iter().map(|f| f.mid_x()).collect();
                let to = TabReorder::final_index(cur, p.x, &mids);
                let slot = frames.iter().filter(|f| f.mid_x() < p.x).count();
                let line_x = if slot < frames.len() {
                    frames[slot].min_x() - 2.0
                } else {
                    frames.last().map_or(rect.min_x(), |f| f.max_x()) + 2.0
                };
                return Some(DropTarget {
                    container: rect,
                    zone: None,
                    insertion_x: Some(line_x),
                    strip_highlight: false,
                    action: Some(DropAction::Reorder(panel, to as i64)),
                });
            }
            if !own && let Some(anchor) = Workspace::dock_anchor(&g.panels, g.selected, panel) {
                return Some(DropTarget {
                    container: rect,
                    zone: Some(DropZone::Center),
                    insertion_x: None,
                    strip_highlight: true,
                    action: Some(DropAction::Dock(panel, anchor, DropZone::Center)),
                });
            }
        }
        let none = DropTarget { container: rect, zone: None, insertion_x: None, strip_highlight: false, action: None };
        let Some(zone) =
            DropZone::zone(Point::new(p.x, p.y), Rect::new(rect.min_x(), rect.min_y(), rect.width, rect.height))
        else {
            return Some(none);
        };
        let Some(anchor) = Workspace::dock_anchor(&g.panels, g.selected, panel) else { return Some(none) };
        if own && zone == DropZone::Center {
            return Some(none);
        }
        Some(DropTarget {
            container: rect,
            zone: Some(zone),
            insertion_x: None,
            strip_highlight: false,
            action: Some(DropAction::Dock(panel, anchor, zone)),
        })
    }

    /// The next or previous visible panel after `p` in layout order (Select Next / Previous Panel).
    pub fn cycle(&self, p: Option<PanelID>, forward: bool) -> Option<PanelID> {
        let order: Vec<PanelID> = self.groups.iter().map(|g| g.selected).collect();
        if order.is_empty() {
            return None;
        }
        let Some(i) = p.and_then(|p| order.iter().position(|q| *q == p)) else { return Some(order[0]) };
        Some(order[(i + if forward { 1 } else { order.len() - 1 }) % order.len()])
    }

    // MARK: Drawing (ShellDock+Draw.swift)

    /// The divider surface, the cards and their tab strips (the Mac `WorkspaceHostView` background, `PanelContainerView`,
    /// `TabStrip`). Call before the panels draw into `content_frame`.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme) {
        c.fill(self.frame, t.panel_ground());
        let medium = c.medium();
        for g in &self.groups {
            if g.is_floating {
                // A floating window: square card with its own title row (the OS window has no frame of ours).
                c.fill(g.frame, t.panel());
                if let Some(w) = self.floating.window_of(g.selected) {
                    self.floating.draw_title(c, w, t, self.focused == Some(g.selected));
                }
                continue;
            }
            Self::draw_panel_frame(c, g, t);
            if g.strip.height <= 0.0 {
                continue;
            }
            for (i, p) in g.panels.iter().enumerate() {
                if g.tabs[i].width <= 0.0 {
                    continue;
                }
                let r = g.tabs[i];
                let on = *p == g.selected;
                // A hovered tab reads like the selected one (the Mac `TabButton.refresh`), none while a tab is dragged.
                let hover = !on && self.drag_tab.is_none() && self.pointer.is_some_and(|q| r.contains(q));
                c.draw_text_in(
                    &EditorCommand::localized_panel_title(*p),
                    r,
                    Self::TAB_FONT,
                    if on || hover { t.label() } else { t.label2() },
                    TextAlign::Left,
                    Self::TAB_PADDING,
                    if on { medium } else { 0 },
                );
            }
            if let Some(m) = g.more_rect() {
                let hover = self.drag_tab.is_none() && self.pointer.is_some_and(|q| m.contains(q));
                if hover {
                    c.fill_rounded(m, f64::from(sq_uikit::redesign_tokens::size::ICON_TOOL) / 2.0, t.hover());
                }
                let icon = f64::from(sq_uikit::redesign_tokens::size::ICON);
                c.draw_icon(
                    sq_uikit::sqicon::SQIcon::Ellipsis,
                    CGPoint::new(m.mid_x() - icon / 2.0, m.mid_y() - icon / 2.0),
                    icon,
                    if hover { t.label() } else { t.label2() },
                    None,
                );
            }
        }
    }

    /// One docked panel's frame: a square card on the seam ground, and, when it has a strip, the header bar's full-width
    /// `border-row` line under it (r8:501).  Every panel (Tools, Timeline, Meter too) is its own card.
    fn draw_panel_frame(c: &mut Canvas, g: &Group, t: &DrawTheme) {
        c.fill(g.frame, t.panel());
        if g.strip.height > 0.0 {
            c.fill(
                CGRect::new(g.strip.min_x(), g.strip.max_y() - 1.0, g.strip.width, 1.0),
                t.token(sq_uikit::redesign_tokens::color::ROW_LINE),
            );
        }
    }

    /// The focus edge of the panel that took the last press or key focus (r8:534-541): a 1 px square outline on the
    /// panel's own edge, in the seam (1 px of seam stays between neighbours), faded with [`Self::focus_amount`].
    /// The colour is `DrawTheme::focus_edge` (grey at 55 % in a background window). Call after the panels draw.
    pub fn draw_focus_frame(&self, c: &mut Canvas, t: &DrawTheme) {
        if !self.draws_focus_frame {
            return;
        }
        let edge = t.focus_edge();
        for g in self.groups.iter().filter(|g| !g.is_floating) {
            let a = self.focus_amount(g.selected);
            if a > 0.0 {
                // The 1 px outline sits just outside the panel box: its centre line is half a point out.
                c.stroke_rounded(g.frame.inset_by(-0.5, -0.5), 0.0, 1.0, edge.with_alpha(edge.a * a as f32));
            }
        }
    }

    /// A card for a panel this platform does not have yet (inside `content_frame`).
    pub fn draw_placeholder(c: &mut Canvas, panel: PanelID, r: CGRect, t: &DrawTheme) {
        if r.width <= 40.0 || r.height <= 30.0 {
            return;
        }
        let title = EditorCommand::localized_panel_title(panel);
        let semibold = c.semibold();
        c.draw_text_in(
            &title,
            CGRect::new(r.min_x(), r.mid_y() - 18.0, r.width, 18.0),
            13.0,
            t.label2(),
            TextAlign::Center,
            0.0,
            semibold,
        );
        c.draw_text_in(
            &sq_uikit::localization::SQL10n::string(crate::shell_platform_text::ShellPlatformText::panel_missing()),
            CGRect::new(r.min_x(), r.mid_y() + 2.0, r.width, 16.0),
            11.0,
            t.label3(),
            TextAlign::Center,
            0.0,
            0,
        );
    }

    /// The drag overlay (`DockOverlayView`) and the tab ghost; call after the panels.
    pub fn draw_overlay(&self, c: &mut Canvas, t: &DrawTheme, m: &TextMeasure) {
        self.draw_focus_frame(c, t);
        self.draw_drop_preview(c, t, m);
    }

    /// The drop preview of a tab drag: the dimmed target card with its zones, the strip or insertion mark, and the tab
    /// ghost under the pointer (also while the dropped tab settles). The window's root owns the dock the drag runs on, so it
    /// calls this itself after the panels; nothing is drawn while no drag runs.
    pub fn draw_drop_preview(&self, c: &mut Canvas, t: &DrawTheme, m: &TextMeasure) {
        if let Some(d) = &self.drop_target {
            let boxed = d.container;
            c.fill(boxed, Color::BLACK.with_alpha(0.28));
            let b = Rect::new(boxed.min_x(), boxed.min_y(), boxed.width, boxed.height);
            let small = radius::SMALL as f64;
            let zone_rect = |z: DropZone| {
                let h = DropZone::highlight_rect(z, b);
                CGRect::new(h.x, h.y, h.width, h.height).inset_by(2.0, 2.0)
            };
            for z in DropZone::ALL {
                if Some(z) == d.zone {
                    continue;
                }
                let r = zone_rect(z);
                c.fill_rounded(r, small, t.accent().with_alpha(0.10));
                c.stroke_rounded(r, small, 1.0, t.accent().with_alpha(0.35));
            }
            if let Some(z) = d.zone {
                let r = zone_rect(z);
                c.fill_rounded(r, small, t.accent().with_alpha(0.55));
                c.stroke_rounded(r, small, 2.0, t.accent());
            }
            if d.strip_highlight {
                c.fill(
                    CGRect::new(boxed.min_x(), boxed.min_y(), boxed.width, Self::STRIP_HEIGHT),
                    t.accent().with_alpha(0.55),
                );
            }
            if let Some(x) = d.insertion_x {
                c.fill(CGRect::new(x - 1.0, boxed.min_y() + 3.0, 2.0, Self::STRIP_HEIGHT - 6.0), t.accent());
            }
        }
        let settling = self.settling_tab().map(|(p, r)| (p, CGPoint { x: r.mid_x(), y: r.mid_y() }));
        if let Some((p, at)) = self.drag_tab.or(settling) {
            let title = EditorCommand::localized_panel_title(p);
            let medium = c.medium();
            let w = m.width(&title, Self::TAB_FONT, m.medium()).ceil() + 2.0 * Self::TAB_PADDING;
            let r = CGRect::new(at.x - w / 2.0, at.y - Self::TAB_HEIGHT / 2.0, w, Self::TAB_HEIGHT);
            let control = radius::CONTROL as f64;
            c.fill_rounded(r, control, t.panel().with_alpha(0.85));
            c.stroke_rounded(r, control, 1.0, t.separator());
            c.draw_text_in(&title, r, Self::TAB_FONT, t.label(), TextAlign::Center, 0.0, medium);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dock() -> ShellDock {
        let mut d = ShellDock {
            frame: CGRect::new(0.0, 44.0, 1600.0, 900.0),
            owns_header: Box::new(|p| p == PanelID::ProgramMonitor || p == PanelID::SourceMonitor),
            ..ShellDock::default()
        };
        d.set_measure(&TextMeasure::new(None, 1.0));
        d.relayout();
        d
    }

    fn intersects(a: &CGRect, b: &CGRect) -> bool {
        a.min_x() < b.max_x() && b.min_x() < a.max_x() && a.min_y() < b.max_y() && b.min_y() < a.max_y()
    }

    fn down(x: f64, y: f64, m: InputModifiers) -> InputEvent {
        InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: m }
    }

    fn drag(x: f64, y: f64) -> InputEvent {
        InputEvent::dragged(x as f32, y as f32)
    }

    fn up(x: f64, y: f64) -> InputEvent {
        InputEvent::MouseUp { x: x as f32, y: y as f32 }
    }

    fn group_with(d: &ShellDock, p: PanelID) -> Group {
        d.groups().iter().find(|g| g.panels.contains(&p)).cloned().unwrap_or_else(|| panic!("no group holds {p:?}"))
    }

    /// Audit A1: the Tools column is 36 pt wide in the default Editing layout at 1440 x 900 (kit), not wider.
    #[test]
    fn tools_column_is_36_wide_at_1440() {
        let mut d = ShellDock { frame: CGRect::new(0.0, 44.0, 1440.0, 856.0), ..dock() };
        d.relayout();
        let tools = group_with(&d, PanelID::Tools);
        assert!(
            (tools.frame.width - 36.0).abs() <= 1.0,
            "Tools column is {} wide; groups {:?}",
            tools.frame.width,
            d.groups().iter().map(|g| (g.selected, g.frame.x, g.frame.width)).collect::<Vec<_>>()
        );
        let meter = group_with(&d, PanelID::AudioMeter);
        assert!(meter.frame.width >= PanelID::AudioMeter.min_size().0);
    }

    /// The r8 look never merges panels. Tools, Timeline and Meter are three docked panels again, each with
    /// its own frame, its own seam, and its own focus edge.
    #[test]
    fn tools_timeline_and_meter_each_have_their_own_frame() {
        let mut d = ShellDock { frame: CGRect::new(0.0, 44.0, 1440.0, 856.0), ..dock() };
        d.relayout();
        let (tools, tl, meter) =
            (group_with(&d, PanelID::Tools), group_with(&d, PanelID::Timeline), group_with(&d, PanelID::AudioMeter));
        assert_eq!(tools.panels, [PanelID::Tools]);
        assert_eq!(meter.panels, [PanelID::AudioMeter]);
        assert_eq!(tl.frame.min_x() - tools.frame.max_x(), ShellDock::GAP, "a seam between Tools and Timeline");
        assert_eq!(meter.frame.min_x() - tl.frame.max_x(), ShellDock::GAP, "a seam between Timeline and Meter");
        // The seams are dividers (draggable), and Tools and Meter keep a header of their own.
        assert!(d.dividers().iter().filter(|v| v.frame.width == ShellDock::GAP).count() >= 2);
        assert_eq!(tools.strip.height, ShellDock::STRIP_HEIGHT);
        assert_eq!(meter.strip.height, ShellDock::STRIP_HEIGHT);
    }

    /// Tools can be docked at another edge of another panel and floated into a window of its own.
    #[test]
    fn tools_can_move_to_another_dock_zone_and_float() {
        let mut d = dock();
        let tools = group_with(&d, PanelID::Tools);
        let tl = d.card_frame(PanelID::Timeline).expect("timeline card");
        d.handle(&down(tools.strip.mid_x(), tools.strip.mid_y(), InputModifiers::NONE), 1.0);
        let to = CGPoint::new(tl.max_x() - 10.0, tl.mid_y());
        d.handle(&drag(to.x, to.y), 1.0);
        assert_eq!(
            d.drop_target().and_then(|t| t.action),
            Some(DropAction::Dock(PanelID::Tools, PanelID::Timeline, DropZone::Right))
        );
        d.handle(&up(to.x, to.y), 1.0);
        let moved = d.card_frame(PanelID::Tools).expect("tools card");
        assert!(moved.min_x() > d.card_frame(PanelID::Timeline).expect("timeline card").min_x());

        let mut d = dock();
        d.can_float_windows = true;
        d.floating.main_screen_frame = Some(CGRect::new(0.0, 0.0, 1600.0, 1000.0));
        d.floating.screens = vec![CGRect::new(0.0, 0.0, 1600.0, 1000.0)];
        let tools = group_with(&d, PanelID::Tools);
        d.handle(&down(tools.strip.mid_x(), tools.strip.mid_y(), InputModifiers::NONE), 1.0);
        d.handle(&drag(800.0, 0.5), 1.0);
        d.handle(&up(800.0, 0.5), 1.0);
        assert!(d.floating.is_floating(PanelID::Tools));
    }

    /// The tab title starts `.hdr` padding (6) plus `.tab` padding (8) inside the panel.
    #[test]
    fn a_tab_title_starts_14_inside_the_panel() {
        let mut d = ShellDock { frame: CGRect::new(0.0, 44.0, 1440.0, 856.0), ..dock() };
        d.relayout();
        let g = d.groups().iter().find(|g| g.panels.len() > 1 || g.tabs.iter().any(|t| t.width > 0.0)).unwrap();
        let t = g.tabs.iter().find(|t| t.width > 0.0).unwrap();
        assert_eq!(t.x - g.frame.x + ShellDock::TAB_PADDING, 14.0);
    }

    #[test]
    fn editing_layout_places_one_card_per_group() {
        let d = dock();
        let selected: HashSet<PanelID> = d.groups().iter().map(|g| g.selected).collect();
        let expected: HashSet<PanelID> = [
            PanelID::EffectControls,
            PanelID::ProgramMonitor,
            PanelID::Timeline,
            PanelID::Tools,
            PanelID::AudioMeter,
            PanelID::Library,
            PanelID::Project,
        ]
        .into_iter()
        .collect();
        assert_eq!(selected, expected);
        // The timeline-only group and the monitors (their own header) show no strip; the others a 30 pt one.
        let inner = d.frame.inset_by(ShellDock::GAP, ShellDock::GAP);
        for g in d.groups() {
            let bare = g.selected == PanelID::ProgramMonitor || g.panels == [PanelID::Timeline];
            assert_eq!(g.strip.height, if bare { 0.0 } else { ShellDock::STRIP_HEIGHT }, "{:?}", g.selected);
            assert_eq!(g.content.max_y(), g.frame.max_y());
            assert!(inner.contains_rect(&g.frame));
        }
        // Cards never overlap and every gap is a divider.
        for (i, a) in d.groups().iter().enumerate() {
            for b in &d.groups()[i + 1..] {
                assert!(!intersects(&a.frame, &b.frame));
            }
        }
        assert!(d.dividers().len() >= 4);
    }

    #[test]
    fn drag_divider_trades_length_and_keeps_minimums() {
        let mut d = dock();
        let root = |d: &ShellDock| d.dividers().iter().find(|x| x.path.is_empty()).cloned().expect("root divider");
        let div = root(&d);
        let before = d.card_frame(PanelID::Project).expect("project card").width;
        let s = 2.0f32;
        let start = CGPoint::new(div.frame.mid_x(), div.frame.mid_y());
        assert!(d.handle(&down(start.x * 2.0, start.y * 2.0, InputModifiers::NONE), s));
        assert!(d.handle(&drag(start.x * 2.0 - 200.0, start.y * 2.0), s));
        assert!((d.card_frame(PanelID::Project).expect("project card").width - (before + 100.0)).abs() <= 1.0); // 200 px at scale 2
        // Far past the edge: the left side stays at its minimum.
        d.handle(&drag(0.0, start.y * 2.0), s);
        let div = root(&d);
        assert!(div.lengths[0] >= div.mins[0] - 0.5);
        d.take_events();
        assert!(d.handle(&up(0.0, start.y * 2.0), s));
        let saves = d.take_events().iter().filter(|e| matches!(e, DockEvent::SaveWorkspaces)).count();
        assert_eq!(saves, 1);
        assert!(!d.is_tracking());
    }

    #[test]
    fn a_divider_lands_where_the_finger_left_it_without_a_spring() {
        let mut d = dock();
        let root = |d: &ShellDock| d.dividers().iter().find(|x| x.path.is_empty()).cloned().expect("root divider");
        let div = root(&d);
        let s = 2.0f32;
        let start = CGPoint::new(div.frame.mid_x(), div.frame.mid_y());
        d.handle(&down(start.x * 2.0, start.y * 2.0, InputModifiers::NONE), s);
        d.handle(&drag(start.x * 2.0 - 120.0, start.y * 2.0), s);
        let held = d.card_frame(PanelID::Project).expect("card").width;
        // The finger flicks on while it lifts: the release point does not move the divider.
        d.handle(&up(start.x * 2.0 - 400.0, start.y * 2.0), s);
        assert_eq!(d.card_frame(PanelID::Project).expect("card").width, held, "no jump at the release");
        for i in 1..20 {
            assert!(!d.tick(30.0 + f64::from(i) * 0.02) || d.settling_tab().is_none(), "no divider animation");
            assert_eq!(d.card_frame(PanelID::Project).expect("card").width, held, "no spring after the release");
        }
    }

    #[test]
    fn active_underline_moves_with_presses_and_fades() {
        let mut d = dock();
        let a = group_with(&d, PanelID::MarkerList);
        let b = group_with(&d, PanelID::Project);
        let (ta, tb) = (
            a.tabs[a.panels.iter().position(|p| *p == PanelID::MarkerList).unwrap()],
            b.tabs[b.panels.iter().position(|p| *p == PanelID::Project).unwrap()],
        );
        d.handle(&down(ta.mid_x(), ta.mid_y(), InputModifiers::NONE), 1.0);
        d.handle(&up(ta.mid_x(), ta.mid_y()), 1.0);
        d.tick(0.0);
        assert!(d.focus_amount(PanelID::MarkerList) > 0.99);
        d.focus_press(PanelID::Project);
        assert_eq!(d.focused(), Some(PanelID::Project));
        assert!(d.tick(0.06));
        let mid = d.focus_amount(PanelID::MarkerList);
        assert!(mid > 0.0 && mid < 1.0, "{mid}");
        assert!(!d.tick(0.30));
        assert_eq!(d.focus_amount(PanelID::MarkerList), 0.0);
        assert_eq!(d.focus_amount(PanelID::Project), 1.0);
        // Keyboard focus moves it the same way.
        d.set_focused(Some(PanelID::MarkerList));
        d.tick(0.6);
        assert_eq!(d.focus_amount(PanelID::MarkerList), 1.0);
        let _ = tb;
    }

    #[test]
    fn the_focus_line_eases_out_and_leaves_faster_than_it_comes() {
        sq_draw::motion::set_reduce_motion(false);
        let mut d = dock();
        d.tick(0.0);
        d.set_focused(Some(PanelID::Project));
        d.tick(0.0);
        d.tick(ShellDock::FOCUS_FADE / 2.0);
        // Half the time, more than half the way (ease-out, not linear).
        assert!(d.focus_amount(PanelID::Project) > 0.8, "{}", d.focus_amount(PanelID::Project));
        let t = ShellDock::FOCUS_FADE;
        d.tick(t);
        assert_eq!(d.focus_amount(PanelID::Project), 1.0);
        // Leaving: finished after the exit time, which is shorter than the enter time.
        d.set_focused(None);
        let exit = sq_draw::motion::duration::exit(ShellDock::FOCUS_FADE);
        assert!(d.tick(t + exit * 0.5));
        assert!(!d.tick(t + exit * 1.5));
        assert_eq!(d.focus_amount(PanelID::Project), 0.0);
    }

    #[test]
    fn the_focus_line_turns_at_once_under_reduce_motion() {
        sq_draw::motion::set_reduce_motion(true);
        let mut d = dock();
        d.tick(0.0);
        d.set_focused(Some(PanelID::Project));
        assert!(!d.tick(0.01), "no frames asked for");
        assert_eq!(d.focus_amount(PanelID::Project), 1.0);
        sq_draw::motion::set_reduce_motion(false);
    }

    #[test]
    fn click_on_a_tab_selects_it() {
        let mut d = dock();
        let g = group_with(&d, PanelID::MarkerList);
        let tab = g.tabs[g.panels.iter().position(|p| *p == PanelID::MarkerList).expect("tab")];
        d.handle(&down(tab.mid_x(), tab.mid_y(), InputModifiers::NONE), 1.0);
        d.handle(&up(tab.mid_x(), tab.mid_y()), 1.0);
        assert!(d.shows(PanelID::MarkerList) && !d.shows(PanelID::Project));
        assert_eq!(d.focused(), Some(PanelID::MarkerList));
    }

    #[test]
    fn strip_tools_keep_their_width_free_of_tabs_and_presses() {
        let mut d = dock();
        d.strip_tools = Box::new(|p| if p == PanelID::Project { 120.0 } else { 0.0 });
        d.relayout();
        let g = d.groups().iter().find(|g| g.selected == PanelID::Project).cloned().expect("project group");
        for t in g.tabs.iter().filter(|t| t.width > 0.0) {
            assert!(t.max_x() <= g.strip.max_x() - 120.0);
        }
        assert!(!d.handle(&down(g.strip.max_x() - 20.0, g.strip.mid_y(), InputModifiers::NONE), 1.0));
        assert!(d.handle(&down(g.strip.max_x() - 140.0, g.strip.mid_y(), InputModifiers::NONE), 1.0));
    }

    #[test]
    fn every_docked_head_has_a_more_button_that_opens_the_panel_menu() {
        let mut d = dock();
        d.can_float_windows = true;
        let g = group_with(&d, PanelID::Effects);
        let m = g.more_rect().expect("the head has the button");
        assert_eq!(m.max_x(), g.strip.max_x() - ShellDock::MORE_WIDTH + 24.0);
        assert!(g.tools_strip().max_x() <= m.min_x(), "the panel's tools stop short of it");
        assert!(group_with(&d, PanelID::Tools).more_rect().is_none(), "the Tools column has no head");
        assert!(group_with(&d, PanelID::Project).more_rect().is_none(), "Project keeps its own options button");
        assert!(group_with(&d, PanelID::ProgramMonitor).more_rect().is_none(), "a panel with its own header has none");
        assert!(d.handle(&down(m.mid_x(), m.mid_y(), InputModifiers::NONE), 1.0));
        let items = d
            .take_events()
            .into_iter()
            .find_map(|e| if let DockEvent::PresentMenu(items, _) = e { Some(items) } else { None })
            .expect("menu");
        let titles: Vec<&str> = items.iter().map(|i| i.title.as_str()).collect();
        assert_eq!(titles, ["Maximize Panel", "Move to Floating Window", "Close Panel"]);
        for t in g.tabs.iter().filter(|t| t.width > 0.0) {
            assert!(t.max_x() <= m.min_x(), "tabs stop before the button");
        }
    }

    #[test]
    fn a_head_with_its_own_options_button_gets_the_shared_rows_under_a_separator() {
        let mut d = dock();
        d.can_float_windows = true;
        let own = vec![SQMenuItem::new("Export CSV")];
        let titles = |v: &[SQMenuItem]| v.iter().map(|i| i.title.clone()).collect::<Vec<_>>();
        let all = d.with_panel_rows(PanelID::Project, own.clone(), false);
        assert_eq!(titles(&all)[0], "Export CSV");
        assert!(
            all[1].kind == sq_uikit::sqmenu_model::SQMenuItemKind::Separator,
            "separator after the panel's own rows"
        );
        assert_eq!(&titles(&all)[2..], ["Maximize Panel", "Move to Floating Window", "Close Panel"]);
        let strip = d.with_panel_rows(PanelID::Timeline, Vec::new(), true);
        assert_eq!(titles(&strip), ["Maximize Panel"], "no leading separator, no float or close");
    }

    #[test]
    fn an_options_panel_keeps_room_for_its_button_and_reports_where_it_sits() {
        let mut d = dock();
        assert_eq!(d.options_rect(PanelID::Project), None);
        d.option_panels.insert(PanelID::Project);
        d.relayout();
        let g = d.groups().iter().find(|g| g.selected == PanelID::Project).cloned().expect("project group");
        let r = d.options_rect(PanelID::Project).expect("button");
        assert_eq!((r.width, r.height, r.max_x()), (22.0, 22.0, g.strip.max_x() - ShellDock::OPTIONS_WIDTH + 24.0));
        assert!(
            !d.handle(&down(r.mid_x(), r.mid_y(), InputModifiers::NONE), 1.0),
            "the dock leaves the press to the host"
        );
    }

    #[test]
    fn dragging_a_tab_onto_another_cards_edge_splits_it() {
        let mut d = dock();
        let g = group_with(&d, PanelID::MarkerList);
        let tab = g.tabs[g.panels.iter().position(|p| *p == PanelID::MarkerList).expect("tab")];
        let tl = d.card_frame(PanelID::Timeline).expect("timeline card");
        d.handle(&down(tab.mid_x(), tab.mid_y(), InputModifiers::NONE), 1.0);
        let to = CGPoint::new(tl.max_x() - 10.0, tl.mid_y()); // the right edge band
        d.handle(&drag(to.x, to.y), 1.0);
        assert_eq!(
            d.drop_target().and_then(|t| t.action),
            Some(DropAction::Dock(PanelID::MarkerList, PanelID::Timeline, DropZone::Right))
        );
        d.handle(&up(to.x, to.y), 1.0);
        assert!(d.shows(PanelID::MarkerList));
        assert!(
            d.card_frame(PanelID::MarkerList).expect("card").min_x()
                > d.card_frame(PanelID::Timeline).expect("card").min_x()
        );
        assert!(d.drop_target().is_none() && d.drag_tab().is_none());
    }

    /// A maximized window reaches the screen edge: the pointer cannot leave it, so a release on the window's outer rim
    /// (not only beyond the Swift margin) floats the tab. Found in the Windows VM: the drop did nothing there.
    #[test]
    fn releasing_a_tab_on_the_window_rim_floats_it() {
        for (to_x, to_y) in [(1599.5, 300.0), (800.0, 0.5), (0.5, 300.0)] {
            let mut d = dock();
            d.can_float_windows = true;
            d.floating.main_screen_frame = Some(CGRect::new(0.0, 0.0, 1600.0, 1000.0));
            d.floating.screens = vec![CGRect::new(0.0, 0.0, 1600.0, 1000.0)];
            let g = group_with(&d, PanelID::Effects);
            let tab = g.tabs[g.panels.iter().position(|p| *p == PanelID::Effects).expect("tab")];
            d.handle(&down(tab.mid_x(), tab.mid_y(), InputModifiers::NONE), 1.0);
            d.handle(&drag(to_x, to_y), 1.0);
            d.handle(&up(to_x, to_y), 1.0);
            assert!(d.floating.is_floating(PanelID::Effects), "released at {to_x},{to_y}");
        }
    }

    #[test]
    fn releasing_a_tab_well_inside_the_window_does_not_float_it() {
        let mut d = dock();
        d.can_float_windows = true;
        d.floating.main_screen_frame = Some(CGRect::new(0.0, 0.0, 1600.0, 1000.0));
        let g = group_with(&d, PanelID::Effects);
        let tab = g.tabs[g.panels.iter().position(|p| *p == PanelID::Effects).expect("tab")];
        d.handle(&down(tab.mid_x(), tab.mid_y(), InputModifiers::NONE), 1.0);
        d.handle(&drag(1590.0, 300.0), 1.0);
        d.handle(&up(1590.0, 300.0), 1.0);
        assert!(!d.floating.is_floating(PanelID::Effects));
    }

    fn reorder_drop(d: &mut ShellDock) -> CGPoint {
        let g = group_with(d, PanelID::Project);
        let (first, last) = (g.tabs[0], g.tabs[g.panels.len() - 1]);
        d.handle(&down(first.mid_x(), first.mid_y(), InputModifiers::NONE), 1.0);
        let at = CGPoint::new(last.max_x() - 2.0, last.mid_y());
        d.handle(&drag(at.x, at.y), 1.0);
        d.handle(&up(at.x, at.y), 1.0);
        at
    }

    #[test]
    fn a_dropped_tab_settles_into_its_place_with_the_spring_ease() {
        sq_draw::motion::set_reduce_motion(false);
        let mut d = dock();
        let at = reorder_drop(&mut d);
        assert!(d.settling_tab().is_none(), "the settle starts at the next frame");
        assert!(d.tick(10.0), "the host keeps drawing frames");
        let (panel, r0) = d.settling_tab().expect("settling");
        assert_eq!(panel, PanelID::Project);
        assert!((r0.mid_x() - at.x).abs() < 0.5, "starts where it was dropped");
        assert!(d.tick(10.09));
        let r1 = d.settling_tab().expect("still settling").1;
        assert!((r1.mid_x() - at.x).abs() > 1.0, "moves toward its place");
        assert!(!d.tick(10.25), "done after MEDIUM");
        assert!(d.settling_tab().is_none());
    }

    #[test]
    fn a_press_lands_a_settling_tab_at_once_and_reduced_motion_never_settles() {
        sq_draw::motion::set_reduce_motion(false);
        let mut d = dock();
        reorder_drop(&mut d);
        d.tick(10.0);
        assert!(d.settling_tab().is_some());
        d.handle(&down(5.0, 5.0, InputModifiers::NONE), 1.0);
        assert!(d.settling_tab().is_none(), "the press stops it");
        sq_draw::motion::set_reduce_motion(true);
        let mut d = dock();
        reorder_drop(&mut d);
        d.tick(20.0);
        sq_draw::motion::set_reduce_motion(false);
        assert!(d.settling_tab().is_none(), "reduced motion: instant");
    }

    #[test]
    fn dragging_inside_the_own_strip_reorders() {
        let mut d = dock();
        let g = group_with(&d, PanelID::Project);
        let (first, last) = (g.tabs[0], g.tabs[g.panels.len() - 1]);
        d.handle(&down(first.mid_x(), first.mid_y(), InputModifiers::NONE), 1.0);
        d.handle(&drag(last.max_x() - 2.0, last.mid_y()), 1.0);
        assert!(matches!(d.drop_target().and_then(|t| t.action), Some(DropAction::Reorder(PanelID::Project, _))));
        d.handle(&up(last.max_x() - 2.0, last.mid_y()), 1.0);
        assert_eq!(group_with(&d, PanelID::Project).panels.last(), Some(&PanelID::Project));
    }

    #[test]
    fn escape_cancels_a_tab_drag() {
        let mut d = dock();
        let g = group_with(&d, PanelID::MarkerList);
        let tab = g.tabs[g.panels.iter().position(|p| *p == PanelID::MarkerList).expect("tab")];
        d.handle(&down(tab.mid_x(), tab.mid_y(), InputModifiers::NONE), 1.0);
        d.handle(&drag(300.0, 300.0), 1.0);
        assert!(d.handle(&InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE }, 1.0));
        assert!(!d.is_tracking() && d.drop_target().is_none());
    }

    #[test]
    fn built_in_layouts_keep_strips_and_monitors_at_the_window_minimum() {
        let mut d = dock();
        for name in d.store().library.names() {
            d.choose_workspace(&name);
            d.set_frame(CGRect::new(0.0, 0.0, 640.0, 340.0));
            for g in d.groups() {
                let bare = g.strip.height == 0.0;
                assert!(
                    bare || g.strip.height >= ShellDock::STRIP_HEIGHT,
                    "{name}: {:?} keeps its tab strip",
                    g.panels
                );
                assert!(g.frame.width >= 30.0 && g.frame.height >= ShellDock::STRIP_HEIGHT, "{name}: {:?}", g.panels);
                assert!(d.frame.contains_rect(&g.frame), "{name}: {:?} inside the dock", g.panels);
            }
            let card = d.monitor_card().unwrap_or_else(|| panic!("{name}: a monitor is on screen"));
            assert!(card.width >= 160.0 && card.height >= 120.0, "{name}: monitor card {card:?}");
        }
    }

    #[test]
    fn a_background_tab_is_unchecked_and_its_row_shows_it() {
        let mut d = dock();
        let g = d.groups().iter().find(|g| g.panels.len() > 1).expect("a tab group").clone();
        let behind = *g.panels.iter().find(|p| **p != g.selected).expect("a background tab");
        assert!(!d.shows(behind));
        assert!(!d.visible_panels().contains(&behind), "a check mark needs a visible tab");
        d.toggle(behind);
        assert!(d.shows(behind) && d.visible_panels().contains(&behind));
        assert_eq!(d.focused(), Some(behind));
        d.toggle(behind);
        assert!(!d.visible_panels().contains(&behind));
    }

    #[test]
    fn toggling_hides_and_shows_a_panel() {
        let mut d = dock();
        assert!(d.visible_panels().contains(&PanelID::Project));
        d.toggle(PanelID::Project);
        assert!(!d.visible_panels().contains(&PanelID::Project) && !d.shows(PanelID::Project));
        d.toggle(PanelID::Project);
        assert!(d.shows(PanelID::Project) && d.focused() == Some(PanelID::Project));
    }

    #[test]
    fn maximize_fills_the_dock_and_restores() {
        let mut d = dock();
        d.toggle_maximize(PanelID::Timeline);
        assert!(d.groups().len() == 1 && d.groups()[0].selected == PanelID::Timeline);
        assert_eq!(d.groups()[0].frame, d.frame.inset_by(ShellDock::GAP, ShellDock::GAP));
        d.toggle_maximize(PanelID::Timeline);
        assert!(d.groups().len() > 1);
    }

    #[test]
    fn tab_menu_offers_maximize_and_close() {
        let mut d = dock();
        let g = group_with(&d, PanelID::Project);
        let tab = g.tabs[g.panels.iter().position(|p| *p == PanelID::Project).expect("tab")];
        d.handle(&down(tab.mid_x(), tab.mid_y(), InputModifiers::SECONDARY), 1.0);
        let shown = d
            .take_events()
            .into_iter()
            .find_map(|e| if let DockEvent::PresentMenu(items, _) = e { Some(items) } else { None })
            .expect("a menu");
        assert_eq!(shown.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(), ["Maximize Panel", "Close Panel"]);
        if let Some(a) = &shown[1].action {
            a();
        }
        d.run_tab_actions();
        assert!(!d.visible_panels().contains(&PanelID::Project));
    }

    #[test]
    fn cycle_walks_the_groups_in_layout_order() {
        let d = dock();
        let order: Vec<PanelID> = d.groups().iter().map(|g| g.selected).collect();
        assert_eq!(d.cycle(None, true), Some(order[0]));
        assert_eq!(d.cycle(Some(order[0]), true), Some(order[1]));
        assert_eq!(d.cycle(Some(order[0]), false), order.last().copied());
    }

    /// Edit -> Color -> Edit puts every Edit panel back where it was (the Color page's hides and layout never touch it).
    #[test]
    fn the_edit_layout_is_exactly_back_after_a_visit_to_the_color_page() {
        use std::collections::HashSet;
        let mut d = dock();
        d.set_page(WorkspacePage::Edit);
        let frames = |d: &ShellDock| -> Vec<(PanelID, Option<CGRect>)> {
            PanelID::ALL.iter().map(|p| (*p, d.content_frame(*p))).collect()
        };
        let before = frames(&d);
        d.set_page(WorkspacePage::Color);
        d.set_transiently_hidden(HashSet::from([PanelID::Steps]));
        let _ = frames(&d);
        d.set_transiently_hidden(HashSet::new());
        d.set_page(WorkspacePage::Edit);
        assert_eq!(frames(&d), before);
    }
}
