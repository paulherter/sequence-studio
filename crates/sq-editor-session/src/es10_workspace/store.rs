//! Which workspaces exist and which one is showing (`WorkspaceStore`), the workspace each project opens in, and the
//! floating panel windows.

use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Deserializer, Serialize};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};
use sq_uikit::panel_id::PanelID;

use super::docking::WorkspaceLibrary;
use super::layout::{Workspace, WorkspaceMigration};

/// The Edit page or the Color page.
// Swift: WorkspaceStore.swift:9
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WorkspacePage {
    /// The Edit page.
    Edit,
    /// The Color page.
    Color,
}

impl WorkspacePage {
    /// The stored name.
    pub fn raw_value(self) -> &'static str {
        match self {
            WorkspacePage::Edit => "edit",
            WorkspacePage::Color => "color",
        }
    }
}

// Swift: WorkspaceStore.swift:34
/// A field that falls back to its default when it does not decode (Swift `try? decodeIfPresent ?? default`).
fn lenient<'de, D: Deserializer<'de>, T: serde::de::DeserializeOwned + Default>(d: D) -> Result<T, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    Ok(serde_json::from_value(v).unwrap_or_default())
}

fn default_edit_name() -> String {
    Workspace::editing_pc().name
}

/// Which workspaces exist, which one is showing, and their split fractions: everything the window shell persists
/// about layout. Fractions live in the workspaces themselves (`Workspace::set_fractions`), so saving the store
/// saves them per workspace. The Color page is one more workspace (`Workspace::color`) behind the Edit | Color switch.
/// Older stores hold one Color page (`colorWorkspace`) and portrait/square variants: ignored, every preset starts
/// with its automatic Color layout.
// Swift: WorkspaceStore.swift:6
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceStore {
    // Swift: WorkspaceStore.swift:8
    pub library: WorkspaceLibrary,
    /// Color layouts the user changed, keyed by the Edit workspace they are paired with (a preset is a pair: the Edit
    /// layout plus the Color layout under one name). A missing key means the automatic Color layout.
    // Swift: WorkspaceStore.swift:12
    #[serde(default, deserialize_with = "lenient")]
    pub color_layouts: BTreeMap<String, Workspace>,
    /// Name of the Edit workspace in use (built-in or user).
    // Swift: WorkspaceStore.swift:14
    #[serde(default = "default_edit_name")]
    pub edit_name: String,
    // Swift: WorkspaceStore.swift:15
    #[serde(default = "default_page")]
    pub page: WorkspacePage,
    /// Version of the built-in layouts the saved layouts were made for. A store older than `CURRENT_LAYOUT_VERSION` is
    /// migrated once on load (user-made workspaces stay). 1 = redesign round 2 (Main and Color boards): every built-in
    /// reset. 2 = the Color page is one fixed layout with the Clips strip in its lower panel: the Color page reset.
    /// 3 = Color layouts are paired with Edit workspaces (`color_layouts`); the single legacy Color page is dropped.
    /// 4 = "Editing - PC" follows the v9 board proportions: its saved override is dropped once.
    /// 5 = Color panels are normal dock tabs (no Clips column; Steps | Timeline | Sources tabs, Scopes beside the
    /// viewer): saved Color layouts are dropped once.
    // Swift: WorkspaceStore.swift:23
    #[serde(default)]
    pub layout_version: i64,
}

fn default_page() -> WorkspacePage {
    WorkspacePage::Edit
}

impl Default for WorkspaceStore {
    // Swift: WorkspaceStore.swift:25
    fn default() -> WorkspaceStore {
        WorkspaceStore {
            library: WorkspaceLibrary::default(),
            color_layouts: BTreeMap::new(),
            edit_name: default_edit_name(),
            page: WorkspacePage::Edit,
            layout_version: Self::CURRENT_LAYOUT_VERSION,
        }
    }
}

impl WorkspaceStore {
    // Swift: WorkspaceStore.swift:24
    pub const CURRENT_LAYOUT_VERSION: i64 = 5;

    /// The automatic Color layout paired with an Edit workspace: Portrait and MacBook keep the viewer far right like
    /// their Edit layouts, everything else (PC, 27", user presets) gets the landscape layout.
    // Swift: WorkspaceStore.swift:45
    pub fn automatic_color_for_edit(name: &str) -> Workspace {
        if name == Workspace::editing_portrait().name {
            Workspace::color_portrait()
        } else if name == Workspace::editing_mac_book().name {
            Workspace::color_mac_book()
        } else {
            Workspace::color()
        }
    }

    /// The Color layout of the Edit workspace in use (`edit_name`): the user's version or the automatic one.
    // Swift: WorkspaceStore.swift:54
    pub fn color_page(&self) -> Workspace {
        self.color_layouts
            .get(&self.edit_name)
            .cloned()
            .unwrap_or_else(|| Self::automatic_color_for_edit(&self.edit_name))
    }

    /// Stores the Color layout of the Edit workspace in use (never maximized, always named "Color").
    pub fn set_color_page(&mut self, w: Workspace) {
        let mut c = w;
        c.maximized = None;
        c.name = Workspace::color().name;
        self.color_layouts.insert(self.edit_name.clone(), c);
    }

    /// Same as `color_page` (the name from when the Color page was one layout).
    // Swift: WorkspaceStore.swift:62
    pub fn color_workspace(&self) -> Workspace {
        self.color_page()
    }

    /// Same as `set_color_page`.
    pub fn set_color_workspace(&mut self, w: Workspace) {
        self.set_color_page(w);
    }

    /// The Color layout of the Edit workspace in use goes back to its automatic layout.
    // Swift: WorkspaceStore.swift:68
    pub fn reset_current_color(&mut self) {
        self.color_layouts.remove(&self.edit_name);
    }

    /// Every Color layout goes back to its automatic layout.
    // Swift: WorkspaceStore.swift:70
    pub fn reset_all_color(&mut self) {
        self.color_layouts.clear();
    }

    /// The workspace on screen.
    // Swift: WorkspaceStore.swift:73
    pub fn current(&self) -> Workspace {
        match self.page {
            WorkspacePage::Color => self.color_page(),
            WorkspacePage::Edit => self.library.workspace_named(&self.edit_name).unwrap_or_else(Workspace::editing_pc),
        }
    }

    /// Stores changes to the on-screen workspace (fractions, hidden panels, tab selection). A maximized panel is a
    /// transient state and is not saved.
    // Swift: WorkspaceStore.swift:82
    pub fn update_current(&mut self, w: &Workspace) {
        match self.page {
            WorkspacePage::Color => self.set_color_page(w.clone()),
            WorkspacePage::Edit => {
                let mut w = w.clone();
                w.name = self.edit_name.clone();
                self.library.update(&w);
            }
        }
    }

    /// Switches to an Edit workspace by name. False when no such workspace exists.
    // Swift: WorkspaceStore.swift:93
    pub fn select_edit(&mut self, name: &str) -> bool {
        let Some(w) = self.library.workspace_named(name) else { return false };
        self.edit_name = w.name;
        true
    }

    /// "Save as New Workspace": stores the Edit layout in use together with its Color layout as a new user preset (a
    /// pair) with a unique name derived from `base`, and switches to it. The page stays. Returns the name used.
    // Swift: WorkspaceStore.swift:102
    pub fn save_current_as_new(&mut self, base: &str) -> String {
        let name = self.library.suggested_new_name(base);
        let colour = self.color_page();
        let mut w = self.library.workspace_named(&self.edit_name).unwrap_or_else(Workspace::editing_pc);
        w.name = name.clone();
        self.library.save_as(&name, &w);
        self.edit_name = name.clone();
        self.set_color_page(colour);
        name
    }

    // Swift: WorkspaceStore.swift:113
    pub fn set_page(&mut self, p: WorkspacePage) {
        self.page = p;
    }

    /// Renames the current user workspace (both layouts of the pair). False for built-ins, empty or taken names.
    // Swift: DockDragHelpers.swift:44
    pub fn rename_current(&mut self, name: &str) -> bool {
        if !self.library.rename(&self.edit_name, name) {
            return false;
        }
        let old = self.edit_name.clone();
        self.edit_name = self.library.workspace_named(name).map(|w| w.name).unwrap_or_else(|| name.to_string());
        if let Some(c) = self.color_layouts.remove(&old) {
            self.color_layouts.insert(self.edit_name.clone(), c);
        }
        true
    }

    /// Deletes the current user workspace and falls back to the default Edit workspace. False for built-ins.
    // Swift: DockDragHelpers.swift:54
    pub fn delete_current(&mut self) -> bool {
        if !self.library.delete(&self.edit_name) {
            return false;
        }
        self.color_layouts.remove(&self.edit_name);
        self.edit_name = Workspace::editing_pc().name;
        true
    }

    /// True when "Reset to Saved Layout" has something to restore: the Color page, or a built-in with edits.
    // Swift: DockDragHelpers.swift:61
    pub fn can_reset_current(&self) -> bool {
        (self.page == WorkspacePage::Color && self.color_layouts.contains_key(&self.edit_name))
            || self.library.is_modified_built_in(&self.edit_name)
    }

    // Swift: DockDragHelpers.swift:62
    pub fn can_rename_or_delete_current(&self) -> bool {
        !self.library.is_built_in(&self.edit_name)
    }

    // MARK: Persistence

    /// `<application support>/Sequence Studio/workspaces.json`.
    // Swift: WorkspaceStore.swift:117
    pub fn default_path(application_support: &Path) -> PathBuf {
        application_support.join("Sequence Studio").join("workspaces.json")
    }

    /// Missing or unreadable files give the defaults; a stored edit name that no longer exists falls back to the first
    /// built-in. An unreadable file, or one written by a newer version, is kept as `<file>.corrupt`: the next save
    /// would overwrite the user's workspaces.
    // Swift: WorkspaceStore.swift:125
    pub fn load(path: &Path) -> WorkspaceStore {
        let Ok(raw) = fs::read(path) else { return WorkspaceStore::default() };
        let decoded = serde_json::from_slice::<WorkspaceStore>(&WorkspaceMigration::drop_unknown_panels(&raw))
            .ok()
            .filter(|s| s.library.version <= WorkspaceLibrary::CURRENT_VERSION);
        let Some(mut s) = decoded else {
            let mut backup = path.as_os_str().to_owned();
            backup.push(".corrupt");
            let backup = PathBuf::from(backup);
            let _ = fs::remove_file(&backup);
            let _ = fs::copy(path, &backup);
            return WorkspaceStore::default();
        };
        s.library = s.library.healed().dropping_color_clips();
        if s.layout_version < Self::CURRENT_LAYOUT_VERSION {
            if s.layout_version < 1 {
                s.library.reset_all_built_ins();
            }
            if s.layout_version < 4 {
                s.library.reset_built_in(&Workspace::editing_pc().name);
            }
            if s.layout_version < 5 {
                s.color_layouts.clear();
            }
            s.layout_version = Self::CURRENT_LAYOUT_VERSION;
        }
        // Color layouts of presets that are gone, or without the Color settings: back to the automatic layout.
        let lib = s.library.clone();
        s.color_layouts = std::mem::take(&mut s.color_layouts)
            .into_iter()
            .filter(|(name, w)| {
                lib.workspace_named(name).is_some() && w.all_panels().contains(&PanelID::ColorInspector)
            })
            .map(|(name, mut w)| {
                w.name = Workspace::color().name;
                (name, w)
            })
            .collect();
        if s.library.workspace_named(&s.edit_name).is_none() {
            s.edit_name = Workspace::editing_pc().name;
        }
        s
    }

    /// Writes the store atomically (temporary file, then rename).
    // Swift: WorkspaceStore.swift:150
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        write_json(path, &super::encode_sorted_pretty(self).map_err(std::io::Error::other)?)
    }
}

/// Creates the folder and replaces `path` in one step.
fn write_json(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, path)
}

// MARK: - Project choices

/// The Edit workspace each project opens in. A project opens in "Editing - PC" (the arrangement of the design board)
/// unless the user picked another workspace while that project was open; the pick is remembered per project file.
/// Pure: the app stores `by_project` in its defaults (`WorkspaceChoices::DEFAULTS_KEY`) and asks on every project open.
// Swift: WorkspaceChoices.swift:9
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WorkspaceChoices {
    /// Project file path -> workspace name. A project without an entry opens in "Editing - PC".
    pub(crate) by_project: BTreeMap<String, String>,
    /// The pick made in a project that has no file yet.
    pub(crate) untitled: Option<String>,
}

impl WorkspaceChoices {
    // Swift: WorkspaceChoices.swift:11
    pub const DEFAULTS_KEY: &'static str = "sq.workspace.projectChoices";

    // Swift: WorkspaceChoices.swift:13
    pub fn new() -> WorkspaceChoices {
        WorkspaceChoices::default()
    }

    /// From the stored dictionary (`None`: no picks).
    // Swift: WorkspaceChoices.swift:16
    pub fn from_stored(stored: Option<BTreeMap<String, String>>) -> WorkspaceChoices {
        WorkspaceChoices { by_project: stored.unwrap_or_default(), untitled: None }
    }

    /// Project file path -> workspace name.
    pub fn by_project(&self) -> &BTreeMap<String, String> {
        &self.by_project
    }

    /// The pick made in a project that has no file yet.
    pub fn untitled(&self) -> Option<&str> {
        self.untitled.as_deref()
    }

    /// The user picked `name` himself while `project` (file path, `None` = not saved yet) was open.
    // Swift: WorkspaceChoices.swift:19
    pub fn choose(&mut self, name: &str, project: Option<&str>) {
        let pick = (name != Workspace::editing_pc().name).then(|| name.to_string());
        match (project, pick) {
            (Some(p), Some(pick)) => {
                self.by_project.insert(p.to_string(), pick);
            }
            (Some(p), None) => {
                self.by_project.remove(p);
            }
            (None, pick) => self.untitled = pick,
        }
    }

    /// A new, unsaved project starts without a pick.
    // Swift: WorkspaceChoices.swift:25
    pub fn forget_untitled(&mut self) {
        self.untitled = None;
    }

    /// The workspace `project` opens in: its remembered pick while that workspace still exists, else "Editing - PC".
    // Swift: WorkspaceChoices.swift:28
    pub fn name(&self, project: Option<&str>, available: &[String]) -> String {
        let pick = match project {
            Some(p) => self.by_project.get(p),
            None => self.untitled.as_ref(),
        };
        match pick {
            Some(p) if available.contains(p) => p.clone(),
            _ => Workspace::editing_pc().name,
        }
    }
}

/// Picks the Edit workspace for a screen and sequence (pure; the app calls it when a project opens).
// Swift: WorkspaceAutoPick.swift:4
pub enum WorkspaceAutoPick {}

impl WorkspaceAutoPick {
    /// Every format and screen opens with "Editing - PC", the arrangement of the approved design board. The other
    /// built-ins (Portrait, MacBook, 27") stay selectable in the workspace popup but are never picked automatically.
    /// The size parameters stay so callers need no change.
    // Swift: WorkspaceAutoPick.swift:8
    pub fn name(screen_width: f64, screen_height: f64, sequence_width: f64, sequence_height: f64) -> String {
        let _ = (screen_width, screen_height, sequence_width, sequence_height);
        Workspace::editing_pc().name
    }
}

// MARK: - Floating panels

/// Window frame of a floating panel (screen coordinates, points). Plain numbers so the state stays serializable.
// Swift: FloatingPanelState.swift:5
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct FloatingPanelFrame {
    // Swift: FloatingPanelState.swift:7
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl FloatingPanelFrame {
    // Swift: FloatingPanelState.swift:8
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> FloatingPanelFrame {
        FloatingPanelFrame { x, y, width, height }
    }

    // Swift: FloatingPanelState.swift:9
    pub fn from_rect(r: Rect) -> FloatingPanelFrame {
        FloatingPanelFrame::new(r.x, r.y, r.width, r.height)
    }

    // Swift: FloatingPanelState.swift:10
    pub fn rect(&self) -> Rect {
        Rect::new(self.x, self.y, self.width, self.height)
    }
}

/// Which panels float in their own window, per workspace, and where. Persisted next to `workspaces.json` as
/// `floating-panels.json` (not in the project file, not in the layout tree: the panel keeps its dock position, so
/// docking it back restores the exact place). Keyed by workspace (`key`). Unknown and non-dockable panel ids are
/// dropped when it is read.
// Swift: FloatingPanelState.swift:15
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(from = "FloatingRepr")]
pub struct FloatingPanelState {
    layouts: BTreeMap<String, BTreeMap<String, FloatingPanelFrame>>,
}

#[derive(Deserialize)]
struct FloatingRepr {
    layouts: Option<BTreeMap<String, BTreeMap<String, FloatingPanelFrame>>>,
}

impl From<FloatingRepr> for FloatingPanelState {
    // Swift: FloatingPanelState.swift:108
    fn from(r: FloatingRepr) -> FloatingPanelState {
        let dockable: BTreeSet<&str> = PanelID::dockable().iter().map(|p| p.raw_value()).collect();
        let mut layouts = BTreeMap::new();
        for (k, v) in r.layouts.unwrap_or_default() {
            let kept: BTreeMap<String, FloatingPanelFrame> =
                v.into_iter().filter(|(id, _)| dockable.contains(id.as_str())).collect();
            if !kept.is_empty() {
                layouts.insert(k, kept);
            }
        }
        FloatingPanelState { layouts }
    }
}

impl FloatingPanelState {
    /// Margin of the title bar a floating window keeps reachable, in points.
    pub const TITLE_BAR: f64 = 28.0;
    /// Offset of a freshly floated panel from its dock position.
    pub const DEFAULT_OFFSET: f64 = 40.0;
    /// A tab released this far outside the main window pops out.
    pub const TEAR_OFF_MARGIN: f64 = 16.0;

    // Swift: FloatingPanelState.swift:18
    pub fn new() -> FloatingPanelState {
        FloatingPanelState::default()
    }

    /// The workspace a floating set belongs to: the Edit layout by name, the Color layout by its paired Edit name.
    // Swift: FloatingPanelState.swift:22
    pub fn key(page: WorkspacePage, edit_name: &str) -> String {
        format!("{}:{edit_name}", page.raw_value())
    }

    // Swift: FloatingPanelState.swift:23
    pub fn panels(&self, key: &str) -> HashSet<PanelID> {
        self.layouts
            .get(key)
            .map(|m| m.keys().filter_map(|k| PanelID::ALL.into_iter().find(|p| p.raw_value() == k)).collect())
            .unwrap_or_default()
    }

    // Swift: FloatingPanelState.swift:27
    pub fn frame(&self, panel: PanelID, key: &str) -> Option<FloatingPanelFrame> {
        self.layouts.get(key)?.get(panel.raw_value()).copied()
    }

    /// Pops `panel` out. Only dockable panels float (the Color page's Sources and Steps tabs stay in their layout).
    // Swift: FloatingPanelState.swift:31
    pub fn float(&mut self, panel: PanelID, key: &str, frame: FloatingPanelFrame) {
        if !PanelID::dockable().contains(&panel) {
            return;
        }
        self.layouts.entry(key.to_string()).or_default().insert(panel.raw_value().to_string(), frame);
    }

    // Swift: FloatingPanelState.swift:35
    pub fn dock(&mut self, panel: PanelID, key: &str) {
        if let Some(m) = self.layouts.get_mut(key) {
            m.remove(panel.raw_value());
            if m.is_empty() {
                self.layouts.remove(key);
            }
        }
    }

    /// Remembers a moved or resized window; ignored when the panel is not floating.
    // Swift: FloatingPanelState.swift:42
    pub fn set_frame(&mut self, frame: FloatingPanelFrame, panel: PanelID, key: &str) {
        if let Some(slot) = self.layouts.get_mut(key).and_then(|m| m.get_mut(panel.raw_value())) {
            *slot = frame;
        }
    }

    // MARK: Geometry

    /// Keeps the window on a connected display: a frame whose title bar is not reachable on any screen (second
    /// display unplugged) moves onto the first screen, and a frame larger than its screen shrinks to fit. y grows upward.
    // Swift: FloatingPanelState.swift:51
    pub fn clamp(f: Rect, screens: &[Rect], title_bar: f64) -> Rect {
        let Some(first) = screens.first().copied() else { return f };
        let bar = Rect::new(f.min_x(), f.max_y() - title_bar, f.width, title_bar);
        let reachable = screens
            .iter()
            .copied()
            .find(|s| overlap(s, &bar).is_some_and(|i| i.width >= f.width.min(80.0) && i.height >= title_bar / 2.0));
        let screen = reachable.unwrap_or(first);
        let mut r = f;
        r.width = r.width.min(screen.width);
        r.height = r.height.min(screen.height);
        if reachable.is_none() {
            r.x = first.mid_x() - r.width / 2.0;
            r.y = first.mid_y() - r.height / 2.0;
        }
        r.x = r.min_x().max(screen.min_x()).min(screen.max_x() - r.width);
        r.y = r.min_y().max(screen.min_y()).min(screen.max_y() - r.height);
        r
    }

    /// First frame of a panel that was just popped out: its dock size (at least the panel minimum), offset from the
    /// dock position so it does not sit exactly on top of it.
    // Swift: FloatingPanelState.swift:70
    pub fn default_frame(panel: PanelID, current: Rect, offset: f64) -> FloatingPanelFrame {
        let m = panel.min_size();
        let w = current.width.max(m.0 + 40.0);
        let h = current.height.max(m.1 + 60.0);
        FloatingPanelFrame::new(current.min_x() + offset, current.max_y() - h - offset, w, h)
    }

    /// A tab released this far outside the main window (screen coordinates) pops out instead of docking.
    // Swift: FloatingPanelState.swift:77
    pub fn is_torn_off(point: Point, window: Rect, margin: f64) -> bool {
        let r = window.inset_by(-margin, -margin);
        !(point.x >= r.min_x() && point.x <= r.max_x() && point.y >= r.min_y() && point.y <= r.max_y())
    }

    /// Frame (including the title bar) of a panel torn off a tab at `point`: the title bar sits under the pointer.
    // Swift: FloatingPanelState.swift:82
    pub fn tear_off_frame(panel: PanelID, point: Point, title_bar: f64) -> FloatingPanelFrame {
        let m = panel.min_size();
        let w = (m.0 + 80.0).max(480.0);
        let h = (m.1 + 80.0).max(320.0) + title_bar;
        FloatingPanelFrame::new(point.x - w / 2.0, point.y + title_bar / 2.0 - h, w, h)
    }

    // MARK: Persistence

    /// `floating-panels.json` next to `workspaces.json`.
    // Swift: FloatingPanelState.swift:89
    pub fn default_path(application_support: &Path) -> PathBuf {
        WorkspaceStore::default_path(application_support).with_file_name("floating-panels.json")
    }

    /// Missing or unreadable file gives the empty state.
    // Swift: FloatingPanelState.swift:93
    pub fn load(path: &Path) -> FloatingPanelState {
        fs::read(path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    // Swift: FloatingPanelState.swift:97
    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        write_json(path, &serde_json::to_vec(self).map_err(std::io::Error::other)?)
    }
}

/// The overlap of two rects; `None` when they do not share any area or edge (Swift `intersection(_:).isNull`).
fn overlap(a: &Rect, b: &Rect) -> Option<Rect> {
    let (x0, x1) = (a.min_x().max(b.min_x()), a.max_x().min(b.max_x()));
    let (y0, y1) = (a.min_y().max(b.min_y()), a.max_y().min(b.max_y()));
    (x0 <= x1 && y0 <= y1).then(|| Rect::new(x0, y0, x1 - x0, y1 - y0))
}
