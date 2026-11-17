//! Drag-to-dock: drop zones, tree surgery for moving a panel, and the library of named workspaces.

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Serialize};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};
use sq_uikit::panel_id::PanelID;

use super::layout::{LayoutNode, SplitAxis, Workspace};

/// Where a dragged panel lands relative to a target tab group.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DropZone {
    /// As a tab of the target group.
    Center,
    /// A new group left of the target.
    Left,
    /// A new group right of the target.
    Right,
    /// A new group above the target.
    Top,
    /// A new group below the target.
    Bottom,
}

impl DropZone {
    /// Share of each side (normalized) that counts as an edge band; the inner rect is the center zone.
    // Swift: WorkspaceDocking.swift:18
    pub const EDGE_BAND: f64 = 0.25;

    /// Every zone, in declaration order.
    pub const ALL: [DropZone; 5] = [DropZone::Center, DropZone::Left, DropZone::Right, DropZone::Top, DropZone::Bottom];

    /// The split direction of an edge zone; `None` for the center.
    // Swift: WorkspaceDocking.swift:6
    pub fn axis(self) -> Option<SplitAxis> {
        match self {
            DropZone::Center => None,
            DropZone::Left | DropZone::Right => Some(SplitAxis::Horizontal),
            DropZone::Top | DropZone::Bottom => Some(SplitAxis::Vertical),
        }
    }

    /// True when the new group goes before the target.
    fn inserts_before(self) -> bool {
        matches!(self, DropZone::Left | DropZone::Top)
    }

    /// Pure geometry for the drag overlay (Premiere-like). In the corners the edge with the smaller normalized
    /// distance wins (ties prefer left/right). `None` outside `rect` or for empty rects. Coordinates are plain
    /// (y grows downward; `Top` = smaller y).
    // Swift: WorkspaceDocking.swift:23
    pub fn zone(point: Point, rect: Rect) -> Option<DropZone> {
        if rect.width <= 0.0 || rect.height <= 0.0 || !point.x.is_finite() || !point.y.is_finite() {
            return None;
        }
        let u = (point.x - rect.x) / rect.width;
        let v = (point.y - rect.y) / rect.height;
        if !(0.0..=1.0).contains(&u) || !(0.0..=1.0).contains(&v) {
            return None;
        }
        let (dl, dr, dt, db) = (u, 1.0 - u, v, 1.0 - v);
        let m = dl.min(dr).min(dt).min(db);
        Some(if m >= Self::EDGE_BAND {
            DropZone::Center
        } else if m == dl {
            DropZone::Left
        } else if m == dr {
            DropZone::Right
        } else if m == dt {
            DropZone::Top
        } else {
            DropZone::Bottom
        })
    }

    /// The region of `rect` that `zone` covers, for the drag overlay highlight (edge bands are `EDGE_BAND` wide).
    // Swift: DockDragHelpers.swift:6
    pub fn highlight_rect(zone: DropZone, rect: Rect) -> Rect {
        let bw = rect.width * Self::EDGE_BAND;
        let bh = rect.height * Self::EDGE_BAND;
        match zone {
            DropZone::Center => Rect::new(rect.x + bw, rect.y + bh, rect.width - 2.0 * bw, rect.height - 2.0 * bh),
            DropZone::Left => Rect::new(rect.x, rect.y, bw, rect.height),
            DropZone::Right => Rect::new(rect.x + rect.width - bw, rect.y, bw, rect.height),
            DropZone::Top => Rect::new(rect.x, rect.y, rect.width, bh),
            DropZone::Bottom => Rect::new(rect.x, rect.y + rect.height - bh, rect.width, bh),
        }
    }
}

/// Tab strip reordering by drag.
// Swift: DockDragHelpers.swift:19
pub enum TabReorder {}

impl TabReorder {
    /// Final index for `move_tab` when the tab at `current` is dropped with the pointer at `x`. `mid_xs` are the tab
    /// centers in strip order (including the dragged tab). The tab lands before the first tab whose center lies right of `x`.
    // Swift: DockDragHelpers.swift:22
    pub fn final_index(current: usize, x: f64, mid_xs: &[f64]) -> usize {
        if mid_xs.is_empty() {
            return 0;
        }
        let slot = mid_xs.iter().filter(|m| **m < x).count();
        let final_index = if slot > current { slot - 1 } else { slot };
        final_index.min(mid_xs.len() - 1)
    }
}

impl Workspace {
    /// The drop zone of `point` inside `rect` (Swift `Workspace.dropZone`).
    // Swift: WorkspaceDocking.swift:23
    pub fn drop_zone(point: Point, rect: Rect) -> Option<DropZone> {
        DropZone::zone(point, rect)
    }

    /// The panel a drop onto a tab group should be relative to: the group's selected panel, or another one when the
    /// dragged panel is itself the selected one. `None` when the group holds only the dragged panel.
    // Swift: DockDragHelpers.swift:32
    pub fn dock_anchor(group: &[PanelID], selected: PanelID, dragging: PanelID) -> Option<PanelID> {
        if selected != dragging {
            return Some(selected);
        }
        group.iter().copied().find(|p| *p != dragging)
    }

    // MARK: Docking

    /// Drops `panel` onto the tab group that contains `target`. `Center` appends a tab and selects it; edges split the
    /// target group (new group gets 50 % of the target's share). The panel is first removed from its source group
    /// (empty groups and singleton splits collapse, fractions renormalise) and is shown if it was hidden.
    /// Returns false (workspace unchanged) for unknown panels or `panel == target`.
    pub fn dock(&mut self, panel: PanelID, target: PanelID, zone: DropZone) -> bool {
        let all = self.all_panels();
        if panel == target || !all.contains(&panel) || !all.contains(&target) {
            return false;
        }
        let Some(stripped) = Self::removing(panel, &self.root) else { return false };
        if !stripped.panels().contains(&target) {
            return false;
        }
        let placed = match zone {
            DropZone::Center => Self::map_group(target, &stripped, &|panels, _| {
                let mut with = panels.to_vec();
                with.push(panel);
                LayoutNode::Tabs { panels: with, selected: panel }
            }),
            _ => Self::splitting(target, &stripped, panel, zone),
        };
        self.root = Self::flattened(placed);
        self.hidden.remove(&panel);
        self.maximized = None;
        true
    }

    /// Reorders a tab inside its group. `index` is the final position and is clamped; the selection is kept.
    pub fn move_tab(&mut self, panel: PanelID, index: i64) -> bool {
        if !self.all_panels().contains(&panel) {
            return false;
        }
        self.root = Self::map_group(panel, &self.root, &|panels, selected| {
            let mut p: Vec<PanelID> = panels.iter().copied().filter(|x| *x != panel).collect();
            let at = usize::try_from(index.max(0)).unwrap_or(0).min(p.len());
            p.insert(at, panel);
            LayoutNode::Tabs { panels: p, selected }
        });
        true
    }

    /// Everything that violates the layout invariants; empty for a valid workspace.
    // Swift: WorkspaceDocking.swift:81
    pub fn validation_problems(&self) -> Vec<String> {
        let mut problems = Vec::new();
        let all = self.all_panels();
        let distinct: std::collections::HashSet<_> = all.iter().collect();
        if distinct.len() != all.len() {
            problems.push("duplicate panel".to_string());
        }
        Self::validate(&self.root, &mut problems);
        problems
    }

    // MARK: Tree surgery

    /// Tree without `panel`; `None` when nothing is left. Removes empty groups, collapses singleton splits.
    fn removing(panel: PanelID, node: &LayoutNode) -> Option<LayoutNode> {
        match node {
            LayoutNode::Tabs { panels, selected } => {
                if !panels.contains(&panel) {
                    return Some(node.clone());
                }
                let rest: Vec<PanelID> = panels.iter().copied().filter(|p| *p != panel).collect();
                if rest.is_empty() {
                    return None;
                }
                if *selected != panel {
                    return Some(LayoutNode::Tabs { panels: rest, selected: *selected });
                }
                let i = panels.iter().position(|p| *p == panel).unwrap_or(0);
                let next = rest[i.min(rest.len() - 1)];
                Some(LayoutNode::Tabs { panels: rest, selected: next })
            }
            LayoutNode::Split { axis, children, fractions } => {
                let mut kept = Vec::new();
                let mut fr = Vec::new();
                for (i, c) in children.iter().enumerate() {
                    if let Some(n) = Self::removing(panel, c) {
                        kept.push(n);
                        fr.push(fractions[i]);
                    }
                }
                if kept.len() <= 1 {
                    return kept.into_iter().next();
                }
                let fractions =
                    if kept.len() == children.len() { fractions.clone() } else { Workspace::normalized(&fr) };
                Some(LayoutNode::Split { axis: *axis, children: kept, fractions })
            }
        }
    }

    fn map_group(p: PanelID, node: &LayoutNode, f: &dyn Fn(&[PanelID], PanelID) -> LayoutNode) -> LayoutNode {
        match node {
            LayoutNode::Tabs { panels, selected } if panels.contains(&p) => f(panels, *selected),
            LayoutNode::Tabs { .. } => node.clone(),
            LayoutNode::Split { axis, children, fractions } => LayoutNode::Split {
                axis: *axis,
                children: children.iter().map(|c| Self::map_group(p, c, f)).collect(),
                fractions: fractions.clone(),
            },
        }
    }

    fn splitting(target: PanelID, node: &LayoutNode, panel: PanelID, zone: DropZone) -> LayoutNode {
        let Some(axis) = zone.axis() else { return node.clone() };
        let new = LayoutNode::Tabs { panels: vec![panel], selected: panel };
        match node {
            LayoutNode::Tabs { panels, .. } => {
                if !panels.contains(&target) {
                    return node.clone();
                }
                let children = if zone.inserts_before() { vec![new, node.clone()] } else { vec![node.clone(), new] };
                LayoutNode::Split { axis, children, fractions: vec![0.5, 0.5] }
            }
            LayoutNode::Split { axis: a, children, fractions } => {
                let direct = children
                    .iter()
                    .position(|c| matches!(c, LayoutNode::Tabs { panels, .. } if panels.contains(&target)));
                if let (Some(i), true) = (direct, *a == axis) {
                    // Same axis as the parent: insert as a sibling, halving the target's share.
                    let mut c = children.clone();
                    let mut f = fractions.clone();
                    let half = f[i] / 2.0;
                    f[i] = half;
                    let at = if zone.inserts_before() { i } else { i + 1 };
                    c.insert(at, new);
                    f.insert(at, half);
                    return LayoutNode::Split { axis: *a, children: c, fractions: f };
                }
                LayoutNode::Split {
                    axis: *a,
                    children: children.iter().map(|c| Self::splitting(target, c, panel, zone)).collect(),
                    fractions: fractions.clone(),
                }
            }
        }
    }

    /// Merges nested splits of the same axis into their parent and collapses singleton splits.
    fn flattened(node: LayoutNode) -> LayoutNode {
        let LayoutNode::Split { axis, children, fractions } = node else { return node };
        let mut c = Vec::new();
        let mut f = Vec::new();
        for (i, child) in children.into_iter().enumerate() {
            match Self::flattened(child) {
                LayoutNode::Split { axis: a2, children: c2, fractions: f2 } if a2 == axis => {
                    c.extend(c2);
                    f.extend(f2.into_iter().map(|x| x * fractions[i]));
                }
                n => {
                    c.push(n);
                    f.push(fractions[i]);
                }
            }
        }
        if c.len() == 1 {
            return c.remove(0);
        }
        let sum: f64 = f.iter().sum();
        let fractions = if (sum - 1.0).abs() < 1e-12 { f } else { Workspace::normalized(&f) };
        LayoutNode::Split { axis, children: c, fractions }
    }

    fn validate(node: &LayoutNode, out: &mut Vec<String>) {
        match node {
            LayoutNode::Tabs { panels, selected } => {
                if panels.is_empty() {
                    out.push("empty group".to_string());
                } else if !panels.contains(selected) {
                    out.push("selected not in group".to_string());
                }
            }
            LayoutNode::Split { children, fractions, .. } => {
                if children.len() < 2 {
                    out.push("split with fewer than 2 children".to_string());
                }
                if children.len() != fractions.len() {
                    out.push("fraction count mismatch".to_string());
                }
                if (fractions.iter().sum::<f64>() - 1.0).abs() > 1e-9 {
                    out.push("fractions do not sum to 1".to_string());
                }
                for c in children {
                    Self::validate(c, out);
                }
            }
        }
    }

    /// This layout without the Color page's clip list (unchanged when it does not hold it or holds nothing else).
    pub fn without_color_clips(&self) -> Workspace {
        if !self.all_panels().contains(&PanelID::ColorClips) {
            return self.clone();
        }
        let Some(rest) = Self::removing(PanelID::ColorClips, &self.root) else { return self.clone() };
        let mut w = self.clone();
        w.root = rest;
        w.hidden.remove(&PanelID::ColorClips);
        if w.maximized == Some(PanelID::ColorClips) {
            w.maximized = None;
        }
        w
    }
}

// MARK: - Library

/// Why a stored library could not be used.
// Swift: WorkspaceDocking.swift:174
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkspaceLoadError {
    /// Written by a newer version.
    UnsupportedVersion(i64),
    /// Not a workspace library.
    Malformed(String),
}

impl fmt::Display for WorkspaceLoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WorkspaceLoadError::UnsupportedVersion(v) => {
                write!(f, "workspace library version {v} is newer than this app")
            }
            WorkspaceLoadError::Malformed(m) => write!(f, "workspace library unreadable: {m}"),
        }
    }
}

impl std::error::Error for WorkspaceLoadError {}

/// The user's workspaces plus edits to built-ins, persisted as versioned JSON. Built-ins cannot be deleted or
/// renamed; an edited built-in is stored as an override and can be reset to its default. Names compare
/// case-insensitively.
// Swift: WorkspaceDocking.swift:172
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceLibrary {
    pub(crate) version: i64,
    pub(crate) user_workspaces: Vec<Workspace>,
    /// Edited built-ins, keyed by built-in name.
    pub(crate) built_in_overrides: BTreeMap<String, Workspace>,
}

impl Default for WorkspaceLibrary {
    fn default() -> WorkspaceLibrary {
        WorkspaceLibrary::new(Vec::new(), BTreeMap::new())
    }
}

impl WorkspaceLibrary {
    // Swift: WorkspaceDocking.swift:184
    pub const CURRENT_VERSION: i64 = 1;

    // Swift: WorkspaceDocking.swift:192
    pub fn new(user_workspaces: Vec<Workspace>, built_in_overrides: BTreeMap<String, Workspace>) -> WorkspaceLibrary {
        WorkspaceLibrary { version: Self::CURRENT_VERSION, user_workspaces, built_in_overrides }
    }

    /// Version of the stored format.
    pub fn version(&self) -> i64 {
        self.version
    }

    /// The user's own workspaces.
    pub fn user_workspaces(&self) -> &[Workspace] {
        &self.user_workspaces
    }

    /// Edited built-ins, keyed by built-in name.
    pub fn built_in_overrides(&self) -> &BTreeMap<String, Workspace> {
        &self.built_in_overrides
    }

    // MARK: Queries

    /// Built-ins (with overrides applied) followed by user workspaces.
    // Swift: WorkspaceDocking.swift:202
    pub fn all(&self) -> Vec<Workspace> {
        let mut all: Vec<Workspace> = Workspace::built_ins()
            .into_iter()
            .map(|b| self.built_in_overrides.get(&b.name).cloned().unwrap_or(b))
            .collect();
        all.extend(self.user_workspaces.iter().cloned());
        all
    }

    // Swift: WorkspaceDocking.swift:203
    pub fn names(&self) -> Vec<String> {
        self.all().into_iter().map(|w| w.name).collect()
    }

    // Swift: WorkspaceDocking.swift:204
    pub fn workspace_named(&self, name: &str) -> Option<Workspace> {
        self.all().into_iter().find(|w| Self::same(&w.name, name))
    }

    // Swift: WorkspaceDocking.swift:205
    pub fn is_built_in(&self, name: &str) -> bool {
        Workspace::built_ins().iter().any(|b| Self::same(&b.name, name))
    }

    // Swift: WorkspaceDocking.swift:206
    pub fn is_modified_built_in(&self, name: &str) -> bool {
        self.built_in_overrides.keys().any(|k| Self::same(k, name))
    }

    // MARK: Operations (false = rejected, library unchanged)

    /// Stores a copy of `workspace` under `name` (trimmed). Overwrites a user workspace of that name; rejects empty
    /// names and built-in names.
    // Swift: WorkspaceDocking.swift:212
    pub fn save_as(&mut self, name: &str, workspace: &Workspace) -> bool {
        let n = Self::clean(name);
        if n.is_empty() || self.is_built_in(&n) {
            return false;
        }
        let mut copy = workspace.clone();
        copy.name = n.clone();
        copy.maximized = None;
        match self.user_workspaces.iter().position(|w| Self::same(&w.name, &n)) {
            Some(i) => self.user_workspaces[i] = copy,
            None => self.user_workspaces.push(copy),
        }
        true
    }

    /// `base` if free, else `base 2`, `base 3`, ... (case-insensitive, also avoiding built-in names).
    // Swift: WorkspaceDocking.swift:223
    pub fn suggested_new_name(&self, base: &str) -> String {
        let cleaned = Self::clean(base);
        let b = if cleaned.is_empty() { "Workspace".to_string() } else { cleaned };
        if self.workspace_named(&b).is_none() {
            return b;
        }
        let mut n = 2;
        while self.workspace_named(&format!("{b} {n}")).is_some() {
            n += 1;
        }
        format!("{b} {n}")
    }

    /// Saves edits in place: user workspaces are replaced, built-ins stored as override. False for unknown names.
    // Swift: WorkspaceDocking.swift:232
    pub fn update(&mut self, workspace: &Workspace) -> bool {
        let mut w = workspace.clone();
        w.maximized = None;
        if let Some(b) = Workspace::built_ins().into_iter().find(|b| Self::same(&b.name, &workspace.name)) {
            w.name = b.name.clone();
            self.built_in_overrides.insert(b.name, w);
            return true;
        }
        let Some(i) = self.user_workspaces.iter().position(|u| Self::same(&u.name, &workspace.name)) else {
            return false;
        };
        w.name = self.user_workspaces[i].name.clone();
        self.user_workspaces[i] = w;
        true
    }

    /// Renames a user workspace; rejects built-ins, empty names and collisions (a case-only change is fine).
    // Swift: WorkspaceDocking.swift:247
    pub fn rename(&mut self, old: &str, new: &str) -> bool {
        let n = Self::clean(new);
        if n.is_empty() || self.is_built_in(old) || self.is_built_in(&n) {
            return false;
        }
        let Some(i) = self.user_workspaces.iter().position(|w| Self::same(&w.name, old)) else { return false };
        if self.user_workspaces.iter().enumerate().any(|(k, w)| k != i && Self::same(&w.name, &n)) {
            return false;
        }
        self.user_workspaces[i].name = n;
        true
    }

    /// Deletes a user workspace. Built-ins cannot be deleted.
    // Swift: WorkspaceDocking.swift:258
    pub fn delete(&mut self, name: &str) -> bool {
        if self.is_built_in(name) {
            return false;
        }
        let Some(i) = self.user_workspaces.iter().position(|w| Self::same(&w.name, name)) else { return false };
        self.user_workspaces.remove(i);
        true
    }

    /// Drops the override of a built-in. False when it was not modified.
    // Swift: WorkspaceDocking.swift:266
    pub fn reset_built_in(&mut self, name: &str) -> bool {
        let Some(key) = self.built_in_overrides.keys().find(|k| Self::same(k, name)).cloned() else { return false };
        self.built_in_overrides.remove(&key);
        true
    }

    /// Self-healing for persisted state: a user workspace whose name collides with a built-in (it would be shadowed
    /// and vanish from the list) or with an earlier user workspace is kept under a new name; overrides of unknown
    /// built-ins are dropped. Built-ins themselves are always listed (`all`), whatever the file held.
    // Swift: WorkspaceDocking.swift:276
    pub fn healed(&self) -> WorkspaceLibrary {
        let mut out = self.clone();
        let built_ins = Workspace::built_ins();
        let mut seen: std::collections::HashSet<String> =
            built_ins.iter().map(|b| Self::clean(&b.name).to_lowercase()).collect();
        let mut users = Vec::new();
        for w in &self.user_workspaces {
            let mut w = w.clone();
            let mut name = Self::clean(&w.name);
            if name.is_empty() {
                name = "Workspace".to_string();
            }
            if seen.contains(&name.to_lowercase()) {
                let base = name;
                let mut n = 2;
                name = format!("{base} (saved)");
                while seen.contains(&name.to_lowercase()) {
                    name = format!("{base} (saved {n})");
                    n += 1;
                }
            }
            seen.insert(name.to_lowercase());
            w.name = name;
            users.push(w);
        }
        out.user_workspaces = users;
        out.built_in_overrides = self
            .built_in_overrides
            .iter()
            .filter(|(k, _)| built_ins.iter().any(|b| &b.name == *k))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect();
        out
    }

    /// Drops every override: all built-ins are back at their shipped layout (user workspaces stay).
    // Swift: WorkspaceDocking.swift:299
    pub fn reset_all_built_ins(&mut self) {
        self.built_in_overrides.clear();
    }

    // MARK: Persistence

    // Swift: WorkspaceDocking.swift:302
    pub fn encoded(&self) -> Result<Vec<u8>, serde_json::Error> {
        super::encode_sorted_pretty(self)
    }

    /// Rejects files written by a newer version.
    // Swift: WorkspaceDocking.swift:310
    pub fn decoded(data: &[u8]) -> Result<WorkspaceLibrary, WorkspaceLoadError> {
        let lib: WorkspaceLibrary =
            serde_json::from_slice(data).map_err(|e| WorkspaceLoadError::Malformed(e.to_string()))?;
        if lib.version > Self::CURRENT_VERSION {
            return Err(WorkspaceLoadError::UnsupportedVersion(lib.version));
        }
        Ok(lib)
    }

    fn clean(s: &str) -> String {
        s.trim().to_string()
    }

    fn same(a: &str, b: &str) -> bool {
        Self::clean(a).to_lowercase() == Self::clean(b).to_lowercase()
    }

    /// Edit layouts never dock the Color page's clip list: a stored layout that holds it loses it.
    pub fn dropping_color_clips(&self) -> WorkspaceLibrary {
        let mut out = self.clone();
        out.user_workspaces = self.user_workspaces.iter().map(Workspace::without_color_clips).collect();
        out.built_in_overrides =
            self.built_in_overrides.iter().map(|(k, v)| (k.clone(), v.without_color_clips())).collect();
        out
    }
}
