//! The layout tree of a workspace: splits and tab groups of panels, the built-in layouts and the sizing rules.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};
use sq_uikit::keyframe_graph_geometry::Size;
use sq_uikit::panel_id::PanelID;

/// Direction of a split.
// Swift: Workspace.swift:3
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SplitAxis {
    /// Children sit side by side.
    Horizontal,
    /// Children are stacked.
    Vertical,
}

/// Layout tree: splits -> tab groups -> panels. `fractions` of a split sum to 1.
// Swift: Workspace.swift:11
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LayoutNode {
    /// Children along an axis with their shares.
    Split {
        /// Direction.
        axis: SplitAxis,
        /// Child nodes.
        children: Vec<LayoutNode>,
        /// Share of each child.
        fractions: Vec<f64>,
    },
    /// A tab group.
    Tabs {
        /// Tabs in order.
        panels: Vec<PanelID>,
        /// The tab on show.
        selected: PanelID,
    },
}

pub(crate) fn tabs(panels: &[PanelID], selected: PanelID) -> LayoutNode {
    LayoutNode::Tabs { panels: panels.to_vec(), selected }
}

pub(crate) fn split(axis: SplitAxis, children: Vec<LayoutNode>, fractions: &[f64]) -> LayoutNode {
    LayoutNode::Split { axis, children, fractions: fractions.to_vec() }
}

pub(crate) fn horizontal(children: Vec<LayoutNode>, fractions: &[f64]) -> LayoutNode {
    split(SplitAxis::Horizontal, children, fractions)
}

pub(crate) fn vertical(children: Vec<LayoutNode>, fractions: &[f64]) -> LayoutNode {
    split(SplitAxis::Vertical, children, fractions)
}

impl LayoutNode {
    /// Every panel in this subtree, in layout order.
    // Swift: Workspace.swift:16
    pub fn panels(&self) -> Vec<PanelID> {
        match self {
            LayoutNode::Split { children, .. } => children.iter().flat_map(LayoutNode::panels).collect(),
            LayoutNode::Tabs { panels, .. } => panels.clone(),
        }
    }

    /// Saved layouts from before the Source monitor was a placeholder may have it selected: a group holding both
    /// monitors opens on Program.
    // Swift: Workspace.swift:24
    pub fn program_preferred(&self) -> LayoutNode {
        match self {
            LayoutNode::Tabs { panels, selected } => {
                if *selected == PanelID::SourceMonitor && panels.contains(&PanelID::ProgramMonitor) {
                    tabs(panels, PanelID::ProgramMonitor)
                } else {
                    self.clone()
                }
            }
            LayoutNode::Split { axis, children, fractions } => {
                split(*axis, children.iter().map(LayoutNode::program_preferred).collect(), fractions)
            }
        }
    }

    /// Layouts saved before the audio meter existed get it docked right of the timeline group; layouts that have it
    /// (visible or hidden) are returned unchanged.
    // Swift: Workspace.swift:36
    pub fn with_meter_beside_timeline(&self) -> LayoutNode {
        fn wrap(n: &LayoutNode) -> LayoutNode {
            match n {
                LayoutNode::Tabs { panels, .. } if panels.contains(&PanelID::Timeline) => {
                    horizontal(vec![n.clone(), tabs(&[PanelID::AudioMeter], PanelID::AudioMeter)], &[0.95, 0.05])
                }
                LayoutNode::Tabs { .. } => n.clone(),
                LayoutNode::Split { axis, children, fractions } => {
                    split(*axis, children.iter().map(wrap).collect(), fractions)
                }
            }
        }
        let all = self.panels();
        if all.contains(&PanelID::AudioMeter) || !all.contains(&PanelID::Timeline) {
            return self.clone();
        }
        wrap(self)
    }

    /// Layouts saved before the Tools panel or the meter existed get them docked beside the timeline group: one row
    /// `Tools | timeline | meter` when both are missing, else the missing one only.
    pub fn with_side_panels_beside_timeline(&self) -> LayoutNode {
        fn wrap(n: &LayoutNode) -> LayoutNode {
            match n {
                LayoutNode::Tabs { panels, .. } if panels.contains(&PanelID::Timeline) => horizontal(
                    vec![
                        tabs(&[PanelID::Tools], PanelID::Tools),
                        n.clone(),
                        tabs(&[PanelID::AudioMeter], PanelID::AudioMeter),
                    ],
                    &[0.0331, 0.9154, 0.0515],
                ),
                LayoutNode::Tabs { .. } => n.clone(),
                LayoutNode::Split { axis, children, fractions } => {
                    split(*axis, children.iter().map(wrap).collect(), fractions)
                }
            }
        }
        let all = self.panels();
        if !all.contains(&PanelID::Tools) && !all.contains(&PanelID::AudioMeter) && all.contains(&PanelID::Timeline) {
            return wrap(self);
        }
        self.with_tools_beside_timeline().with_meter_beside_timeline()
    }

    /// Layouts saved before the Tools panel existed get it docked left of the timeline group; layouts that have it
    /// (visible or hidden) are returned unchanged.
    pub fn with_tools_beside_timeline(&self) -> LayoutNode {
        fn wrap(n: &LayoutNode) -> LayoutNode {
            match n {
                LayoutNode::Tabs { panels, .. } if panels.contains(&PanelID::Timeline) => {
                    horizontal(vec![tabs(&[PanelID::Tools], PanelID::Tools), n.clone()], &[0.03, 0.97])
                }
                LayoutNode::Tabs { .. } => n.clone(),
                LayoutNode::Split { axis, children, fractions } => {
                    split(*axis, children.iter().map(wrap).collect(), fractions)
                }
            }
        }
        let all = self.panels();
        if all.contains(&PanelID::Tools) || !all.contains(&PanelID::Timeline) {
            return self.clone();
        }
        wrap(self)
    }

    /// Repaired copy: empty tab groups and empty splits removed (with their fractions), `selected` inside `panels`,
    /// single-child splits collapsed, fractions one per child and summing to 1 (equal split otherwise). `None` when
    /// nothing is left.
    // Swift: Workspace.swift:52
    pub fn sanitized(&self) -> Option<LayoutNode> {
        match self {
            LayoutNode::Tabs { panels, selected } => {
                let first = *panels.first()?;
                Some(tabs(panels, if panels.contains(selected) { *selected } else { first }))
            }
            LayoutNode::Split { axis, children, fractions } => {
                let usable = fractions.len() == children.len();
                let mut kept = Vec::new();
                let mut fr = Vec::new();
                for (i, c) in children.iter().enumerate() {
                    if let Some(s) = c.sanitized() {
                        kept.push(s);
                        if usable {
                            fr.push(fractions[i]);
                        }
                    }
                }
                if kept.len() <= 1 {
                    return kept.into_iter().next();
                }
                let sum: f64 = fr.iter().sum();
                let ok = usable && fr.iter().all(|f| f.is_finite() && *f > 0.0) && (sum - 1.0).abs() < 1e-6;
                if !ok {
                    fr = vec![1.0 / kept.len() as f64; kept.len()];
                }
                Some(split(*axis, kept, &fr))
            }
        }
    }
}

/// A named layout plus view state (hidden panels, maximized panel). Value type.
/// Hidden panels stay in `root` and are only pruned from `visible_root`, so show restores the exact previous position
/// and sizes. Decoding repairs a bad saved tree (see [`LayoutNode::sanitized`]) instead of trapping later.
// Swift: Workspace.swift:73
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(from = "WorkspaceRepr")]
pub struct Workspace {
    // Swift: Workspace.swift:75
    pub name: String,
    // Swift: Workspace.swift:76
    pub root: LayoutNode,
    // Swift: Workspace.swift:77
    #[serde(serialize_with = "serialize_hidden")]
    pub hidden: HashSet<PanelID>,
    // Swift: Workspace.swift:78
    #[serde(skip_serializing_if = "Option::is_none")]
    pub maximized: Option<PanelID>,
}

/// The stored form of a workspace, before the layout is validated.
#[derive(Deserialize)]
struct WorkspaceRepr {
    name: String,
    root: LayoutNode,
    #[serde(default)]
    hidden: Vec<PanelID>,
    maximized: Option<PanelID>,
}

/// Stored in panel order so a saved file does not change from run to run.
fn serialize_hidden<S: serde::Serializer>(hidden: &HashSet<PanelID>, s: S) -> Result<S::Ok, S::Error> {
    s.collect_seq(PanelID::ALL.iter().filter(|p| hidden.contains(p)))
}

impl From<WorkspaceRepr> for Workspace {
    // Swift: Workspace.swift:89
    fn from(r: WorkspaceRepr) -> Workspace {
        let saved = r.root.sanitized().map(|n| n.program_preferred());
        let root = saved
            .as_ref()
            .map(LayoutNode::with_side_panels_beside_timeline)
            .unwrap_or_else(|| Workspace::editing_pc().root);
        let mut hidden: HashSet<PanelID> = r.hidden.into_iter().collect();
        // The Color page does not show the meter by default; a layout saved before the meter existed gets it hidden there.
        if r.name == Workspace::color().name && saved.is_some_and(|s| !s.panels().contains(&PanelID::AudioMeter)) {
            hidden.insert(PanelID::AudioMeter);
        }
        Workspace { name: r.name, root, hidden, maximized: r.maximized }
    }
}

impl Workspace {
    /// Smallest share a pane gets.
    // Swift: Workspace.swift:79
    pub const MIN_FRACTION: f64 = 0.05;

    /// A workspace with nothing hidden or maximized.
    // Swift: Workspace.swift:81
    pub fn new(name: &str, root: LayoutNode) -> Workspace {
        Workspace { name: name.to_string(), root, hidden: HashSet::new(), maximized: None }
    }

    fn with_hidden(mut self, hidden: &[PanelID]) -> Workspace {
        self.hidden = hidden.iter().copied().collect();
        self
    }

    // MARK: Built-ins (docs/UX.md section 1)

    /// Color inspector and Scopes belong to the Color page; Edit layouts hold them hidden so the Window menu can show them.
    fn color_panels() -> [PanelID; 2] {
        [PanelID::ColorInspector, PanelID::Scopes]
    }

    /// The tool column left of the timeline and the audio meter docked to its right.
    pub(crate) fn timeline_with_meter() -> LayoutNode {
        horizontal(
            vec![
                tabs(&[PanelID::Tools], PanelID::Tools),
                tabs(&[PanelID::Timeline], PanelID::Timeline),
                tabs(&[PanelID::AudioMeter], PanelID::AudioMeter),
            ],
            &[0.0331, 0.9154, 0.0515],
        )
    }

    /// The v9 default (1440 x 900): Controls | Captions | Graphics and Program | Source on top (43 % / 33 % of the
    /// width; the heights and widths of the redesign frame at 1440 x 900), the timeline with the audio meter below; Library | Effects over Project in the right column (24 %).
    // Swift: Workspace.swift:113
    pub fn editing_pc() -> Workspace {
        use PanelID::*;
        let root = horizontal(
            vec![
                vertical(
                    vec![
                        horizontal(
                            vec![
                                tabs(&[EffectControls, Text, Graphics, ColorInspector], EffectControls),
                                tabs(&[ProgramMonitor, SourceMonitor], ProgramMonitor),
                            ],
                            &[0.5623, 0.4377],
                        ),
                        Self::timeline_with_meter(),
                    ],
                    &[0.5133, 0.4867],
                ),
                vertical(
                    vec![tabs(&[Library, Effects], Library), tabs(&[Project, MarkerList, Scopes], Project)],
                    &[0.5325, 0.4675],
                ),
            ],
            &[0.762, 0.238],
        );
        Workspace::new("Editing \u{2013} PC", root).with_hidden(&Self::color_panels())
    }

    /// Program monitor full height on the right; Library | Effects and Effect Controls group in the middle; Project
    /// and timeline bottom left.
    // Swift: Workspace.swift:128
    pub fn editing_mac_book() -> Workspace {
        use PanelID::*;
        let root = horizontal(
            vec![
                vertical(
                    vec![
                        horizontal(
                            vec![
                                tabs(&[Library, Effects, MarkerList, Scopes], Library),
                                tabs(&[EffectControls, Text, Graphics, ColorInspector], EffectControls),
                            ],
                            &[0.4, 0.6],
                        ),
                        horizontal(vec![tabs(&[Project], Project), Self::timeline_with_meter()], &[0.25, 0.75]),
                    ],
                    &[0.5, 0.5],
                ),
                tabs(&[ProgramMonitor, SourceMonitor], ProgramMonitor),
            ],
            &[0.68, 0.32],
        );
        Workspace::new("Editing \u{2013} MacBook", root).with_hidden(&Self::color_panels())
    }

    /// Portrait work (vertical video): Program monitor far right at full height, a smaller timeline underneath.
    // Swift: Workspace.swift:143
    pub fn editing_portrait() -> Workspace {
        use PanelID::*;
        let root = horizontal(
            vec![
                vertical(
                    vec![
                        horizontal(
                            vec![
                                tabs(&[Library, Effects, MarkerList, Scopes], Library),
                                tabs(&[EffectControls, Text, Graphics, ColorInspector], EffectControls),
                            ],
                            &[0.35, 0.65],
                        ),
                        horizontal(vec![tabs(&[Project], Project), Self::timeline_with_meter()], &[0.2, 0.8]),
                    ],
                    &[0.64, 0.36],
                ),
                tabs(&[ProgramMonitor, SourceMonitor], ProgramMonitor),
            ],
            &[0.66, 0.34],
        );
        Workspace::new("Editing \u{2013} Portrait", root).with_hidden(&Self::color_panels())
    }

    /// 27-inch and larger: Effect Controls, Program and Source side by side above a wide timeline; Library column on the left.
    // Swift: Workspace.swift:158
    pub fn editing27() -> Workspace {
        use PanelID::*;
        let root = horizontal(
            vec![
                vertical(
                    vec![tabs(&[Library], Library), tabs(&[Effects, MarkerList, Project, Scopes], Effects)],
                    &[0.5, 0.5],
                ),
                vertical(
                    vec![
                        horizontal(
                            vec![
                                tabs(&[EffectControls, Text, Graphics, ColorInspector], EffectControls),
                                tabs(&[ProgramMonitor], ProgramMonitor),
                                tabs(&[SourceMonitor], SourceMonitor),
                            ],
                            &[0.28, 0.44, 0.28],
                        ),
                        Self::timeline_with_meter(),
                    ],
                    &[0.5, 0.5],
                ),
            ],
            &[0.17, 0.83],
        );
        Workspace::new("Editing \u{2013} 27\"", root).with_hidden(&Self::color_panels())
    }

    /// The Edit layouts that ship with the app.
    // Swift: Workspace.swift:172
    pub fn built_ins() -> Vec<Workspace> {
        vec![Self::editing_pc(), Self::editing_mac_book(), Self::editing_portrait(), Self::editing27()]
    }

    /// The Color page of the Edit | Color switch (1440 wide: flexible | 340): the viewer with Scopes beside it over one
    /// tabbed lower group (Steps | Timeline | Sources) with the meter and the library group, the Color settings full
    /// height on the right. Every panel is a normal dock tab. Steps is hidden by the shell while the grade is Simple.
    /// Not in `built_ins` (it is a page, not an Edit layout); the other panels are in the tree but hidden so the
    /// Window menu can show them.
    // Swift: Workspace.swift:180
    pub fn color() -> Workspace {
        use PanelID::*;
        let root = horizontal(
            vec![
                vertical(
                    vec![
                        horizontal(
                            vec![tabs(&[ProgramMonitor, SourceMonitor], ProgramMonitor), tabs(&[Scopes], Scopes)],
                            &[0.68, 0.32],
                        ),
                        Self::color_lower(),
                    ],
                    &[0.62, 0.38],
                ),
                tabs(&[ColorInspector, EffectControls, Text, Graphics], ColorInspector),
            ],
            &[0.764, 0.236],
        );
        Workspace::new("Color", root).with_hidden(&Self::color_hidden())
    }

    /// Lower group of the Color page: the tools, Steps | Timeline | Sources as tabs, the meter, and the (hidden) library group.
    fn color_lower() -> LayoutNode {
        use PanelID::*;
        horizontal(
            vec![
                tabs(&[Tools], Tools),
                tabs(&[Steps, Timeline, ColorClips], Timeline),
                tabs(&[AudioMeter], AudioMeter),
                tabs(&[Project, Library, Effects, MarkerList], Project),
            ],
            &[0.04, 0.66, 0.05, 0.25],
        )
    }

    /// The Color layout paired with Editing - MacBook and Editing - Portrait: the viewer sits full height on the far
    /// right (as in those Editing layouts); Scopes | Color settings on top left, the lower group below them.
    fn color_viewer_right(viewer_fraction: f64) -> Workspace {
        use PanelID::*;
        let root = horizontal(
            vec![
                vertical(
                    vec![
                        horizontal(
                            vec![
                                tabs(&[Scopes], Scopes),
                                tabs(&[ColorInspector, EffectControls, Text, Graphics], ColorInspector),
                            ],
                            &[0.4, 0.6],
                        ),
                        Self::color_lower(),
                    ],
                    &[0.6, 0.4],
                ),
                tabs(&[ProgramMonitor, SourceMonitor], ProgramMonitor),
            ],
            &[1.0 - viewer_fraction, viewer_fraction],
        );
        Workspace::new("Color", root).with_hidden(&Self::color_hidden())
    }

    /// The Color layout paired with Editing - MacBook.
    // Swift: Workspace.swift:212
    pub fn color_mac_book() -> Workspace {
        Self::color_viewer_right(0.32)
    }

    /// The Color layout paired with Editing - Portrait.
    // Swift: Workspace.swift:213
    pub fn color_portrait() -> Workspace {
        Self::color_viewer_right(0.34)
    }

    /// Panels the Color page keeps in its tree but hidden (the Window menu can show them).
    fn color_hidden() -> [PanelID; 8] {
        use PanelID::*;
        [Project, Library, Effects, MarkerList, EffectControls, Text, Graphics, AudioMeter]
    }

    // MARK: Queries

    /// Every panel of the layout, hidden ones included.
    // Swift: Workspace.swift:219
    pub fn all_panels(&self) -> Vec<PanelID> {
        self.root.panels()
    }

    /// The panel is in the layout and not hidden.
    // Swift: Workspace.swift:221
    pub fn is_visible(&self, p: PanelID) -> bool {
        self.all_panels().contains(&p) && !self.hidden.contains(&p)
    }

    /// Tree to render: hidden panels pruned, single-child splits collapsed, fractions renormalised. A maximized panel
    /// fills everything. `None` when nothing is visible.
    // Swift: Workspace.swift:225
    pub fn visible_root(&self) -> Option<LayoutNode> {
        if let Some(m) = self.maximized.filter(|m| self.is_visible(*m)) {
            return Some(tabs(&[m], m));
        }
        self.prune(&self.root)
    }

    fn prune(&self, node: &LayoutNode) -> Option<LayoutNode> {
        match node {
            LayoutNode::Tabs { panels, selected } => {
                let vis: Vec<PanelID> = panels.iter().copied().filter(|p| !self.hidden.contains(p)).collect();
                let first = *vis.first()?;
                Some(tabs(&vis, if vis.contains(selected) { *selected } else { first }))
            }
            LayoutNode::Split { axis, children, fractions } => {
                let mut kept = Vec::new();
                let mut fr = Vec::new();
                for (i, c) in children.iter().enumerate() {
                    if let Some(p) = self.prune(c) {
                        kept.push(p);
                        fr.push(fractions[i]);
                    }
                }
                if kept.len() <= 1 {
                    return kept.into_iter().next();
                }
                Some(split(*axis, kept, &Self::normalized(&fr)))
            }
        }
    }

    // MARK: Operations

    /// Hides a panel of the layout; a maximized panel is restored first.
    // Swift: Workspace.swift:247
    pub fn hide(&mut self, p: PanelID) {
        if !self.all_panels().contains(&p) {
            return;
        }
        self.hidden.insert(p);
        if self.maximized == Some(p) {
            self.maximized = None;
        }
    }

    /// Restores the panel at its previous position and selects it in its tab group.
    // Swift: Workspace.swift:255
    pub fn show(&mut self, p: PanelID) {
        // The Color page's clip list docks only where a layout already holds it (the Color layouts).
        if !PanelID::dockable().contains(&p) && !self.all_panels().contains(&p) {
            return;
        }
        if !self.all_panels().contains(&p) {
            self.add_to_tree(p);
        }
        if !self.all_panels().contains(&p) {
            return;
        }
        self.hidden.remove(&p);
        self.root = Self::selecting(p, &self.root);
    }

    /// Makes the panel visible in its tab group without selecting it (the group keeps its selected tab).
    // Swift: Workspace.swift:265
    pub fn reveal(&mut self, p: PanelID) {
        if !PanelID::dockable().contains(&p) && !self.all_panels().contains(&p) {
            return;
        }
        if !self.all_panels().contains(&p) {
            self.add_to_tree(p);
        }
        self.hidden.remove(&p);
    }

    /// The selected tab of the group that holds `p` (`None` when no group does).
    // Swift: Workspace.swift:272
    pub fn selected_tab_in_group_of(&self, p: PanelID) -> Option<PanelID> {
        Self::tab_groups(&self.root).into_iter().find(|(panels, _)| panels.contains(&p)).map(|(_, selected)| selected)
    }

    /// Hides a visible panel, shows a hidden one.
    // Swift: Workspace.swift:275
    pub fn toggle(&mut self, p: PanelID) {
        if self.is_visible(p) {
            self.hide(p);
        } else {
            self.show(p);
        }
    }

    /// Adds a panel that this workspace does not contain as a tab next to a related panel (first group as a fallback).
    pub(crate) fn add_to_tree(&mut self, p: PanelID) {
        let all = self.all_panels();
        if all.contains(&p) {
            return;
        }
        let anchors =
            [PanelID::EffectControls, PanelID::Library, PanelID::ProgramMonitor, PanelID::Project, PanelID::Timeline];
        let Some(anchor) = anchors.into_iter().find(|a| all.contains(a)).or_else(|| all.first().copied()) else {
            return;
        };
        self.root = Self::appending(p, anchor, &self.root);
    }

    fn appending(p: PanelID, anchor: PanelID, node: &LayoutNode) -> LayoutNode {
        match node {
            LayoutNode::Tabs { panels, selected } if panels.contains(&anchor) => {
                let mut with = panels.clone();
                with.push(p);
                tabs(&with, *selected)
            }
            LayoutNode::Tabs { .. } => node.clone(),
            LayoutNode::Split { axis, children, fractions } => {
                split(*axis, children.iter().map(|c| Self::appending(p, anchor, c)).collect(), fractions)
            }
        }
    }

    /// Selects a tab (and shows the panel if it was hidden).
    // Swift: Workspace.swift:294
    pub fn select_tab(&mut self, p: PanelID) {
        self.show(p);
    }

    /// Sets fractions of the split at `visible_path` (child indices in `visible_root`). `fractions` has one entry per
    /// visible child; it is clamped to `MIN_FRACTION` and normalized. Hidden children keep their stored fractions.
    /// Returns false when the path is not a split or the count is wrong.
    // Swift: Workspace.swift:299
    pub fn set_fractions(&mut self, visible_path: &[usize], fractions: &[f64]) -> bool {
        if self.maximized.is_some() {
            return false;
        }
        match self.applying(&self.root, visible_path, fractions) {
            Some(new) => {
                self.root = new;
                true
            }
            None => false,
        }
    }

    /// Maximizes a visible panel; calling again with the same panel restores the layout.
    // Swift: Workspace.swift:307
    pub fn toggle_maximize(&mut self, p: PanelID) {
        if self.maximized == Some(p) {
            self.maximized = None;
        } else if self.is_visible(p) {
            self.maximized = Some(p);
        }
    }

    /// Ends maximize.
    // Swift: Workspace.swift:310
    pub fn restore(&mut self) {
        self.maximized = None;
    }

    // MARK: Helpers

    fn has_visible(&self, n: &LayoutNode) -> bool {
        n.panels().iter().any(|p| !self.hidden.contains(p))
    }

    fn applying(&self, node: &LayoutNode, path: &[usize], new: &[f64]) -> Option<LayoutNode> {
        let LayoutNode::Split { axis, children, fractions: old } = node else { return None };
        let vis: Vec<usize> = (0..children.len()).filter(|i| self.has_visible(&children[*i])).collect();
        let replaced = |i: usize, inner: LayoutNode| {
            let mut c = children.clone();
            c[i] = inner;
            split(*axis, c, old)
        };
        if vis.len() == 1 {
            // Collapsed in visible_root: the path passes through.
            return Some(replaced(vis[0], self.applying(&children[vis[0]], path, new)?));
        }
        if vis.len() < 2 {
            return None;
        }
        if let Some((&i, rest)) = path.split_first() {
            let at = *vis.get(i)?;
            return Some(replaced(at, self.applying(&children[at], rest, new)?));
        }
        if new.len() != vis.len() {
            return None;
        }
        let share = Self::normalized(new);
        let hidden_sum: f64 = (0..children.len()).filter(|i| !vis.contains(i)).map(|i| old[i]).sum();
        let visible_sum = 1.0 - hidden_sum;
        let mut f = old.clone();
        for (k, idx) in vis.iter().enumerate() {
            f[*idx] = share[k] * visible_sum;
        }
        Some(split(*axis, children.clone(), &f))
    }

    /// The panel is the tab its group shows right now (visible, and the group's selected tab).
    // Swift: Workspace.swift:340
    pub fn shows_tab(&self, p: PanelID) -> bool {
        self.visible_root().is_some_and(|r| Self::tab_groups(&r).iter().any(|(_, selected)| *selected == p))
    }

    /// Every tab group of a tree with its selected panel.
    pub(crate) fn tab_groups(node: &LayoutNode) -> Vec<(Vec<PanelID>, PanelID)> {
        match node {
            LayoutNode::Tabs { panels, selected } => vec![(panels.clone(), *selected)],
            LayoutNode::Split { children, .. } => children.iter().flat_map(Self::tab_groups).collect(),
        }
    }

    fn selecting(p: PanelID, node: &LayoutNode) -> LayoutNode {
        match node {
            LayoutNode::Tabs { panels, selected } => tabs(panels, if panels.contains(&p) { p } else { *selected }),
            LayoutNode::Split { axis, children, fractions } => {
                split(*axis, children.iter().map(|c| Self::selecting(p, c)).collect(), fractions)
            }
        }
    }

    /// Non-finite or negative values count as 0; result sums to 1 with every entry >= `MIN_FRACTION` (equal split
    /// when that is impossible or the input is all zero).
    // Swift: Workspace.swift:362
    pub fn normalized(values: &[f64]) -> Vec<f64> {
        let n = values.len();
        if n == 0 {
            return Vec::new();
        }
        let equal = vec![1.0 / n as f64; n];
        let mut v: Vec<f64> = values.iter().map(|x| if x.is_finite() { x.max(0.0) } else { 0.0 }).collect();
        let sum: f64 = v.iter().sum();
        if sum <= 0.0 || n as f64 * Self::MIN_FRACTION >= 1.0 {
            return equal;
        }
        v.iter_mut().for_each(|x| *x /= sum);
        // Raise entries below the minimum, take the excess from the free entries proportionally.
        let mut pinned = HashSet::new();
        for _ in 0..n {
            let low: Vec<usize> = (0..n).filter(|i| !pinned.contains(i) && v[*i] < Self::MIN_FRACTION).collect();
            if low.is_empty() {
                break;
            }
            for i in low {
                v[i] = Self::MIN_FRACTION;
                pinned.insert(i);
            }
            let free: Vec<usize> = (0..n).filter(|i| !pinned.contains(i)).collect();
            let target = 1.0 - pinned.len() as f64 * Self::MIN_FRACTION;
            let free_sum: f64 = free.iter().map(|i| v[*i]).sum();
            if free_sum <= 0.0 {
                return equal;
            }
            for i in free {
                v[i] *= target / free_sum;
            }
        }
        v
    }

    /// Smallest content area the visible layout can be shown in.
    // Swift: LayoutMetrics.swift:60
    pub fn minimum_content_size(&self) -> Size {
        match self.visible_root() {
            Some(root) => {
                let s = LayoutMetrics::min_size_of(&root);
                Size::new(s.width + 2.0 * LayoutMetrics::OUTER_MARGIN, s.height + 2.0 * LayoutMetrics::OUTER_MARGIN)
            }
            None => Size::new(0.0, 0.0),
        }
    }
}

/// Pure sizing rules for the workspace layout: per-panel minimum sizes roll up the layout tree, and split fractions
/// are clamped so no pane ever gets less than its minimum.
// Swift: LayoutMetrics.swift:4
pub enum LayoutMetrics {}

impl LayoutMetrics {
    // Swift: LayoutMetrics.swift:6
    pub const DIVIDER_THICKNESS: f64 = 2.0;
    /// Margin around the whole workspace (design B: equals the gap between panel cards).
    // Swift: LayoutMetrics.swift:8
    pub const OUTER_MARGIN: f64 = 2.0;

    /// Smallest size of a node: tab groups need their largest panel plus the tab strip; horizontal splits add widths,
    /// vertical splits add heights; the other axis takes the maximum.
    // Swift: LayoutMetrics.swift:12
    pub fn min_size_of(node: &LayoutNode) -> Size {
        match node {
            LayoutNode::Tabs { panels, .. } => {
                let w = panels.iter().map(|p| p.min_size().0).fold(0.0, f64::max);
                let h = panels.iter().map(|p| p.min_size().1).fold(0.0, f64::max);
                Size::new(w, h + PanelID::HEADER_HEIGHT)
            }
            LayoutNode::Split { axis, children, .. } => {
                let sizes: Vec<Size> = children.iter().map(Self::min_size_of).collect();
                let gaps = Self::DIVIDER_THICKNESS * children.len().saturating_sub(1) as f64;
                let max_w = sizes.iter().map(|s| s.width).fold(0.0, f64::max);
                let max_h = sizes.iter().map(|s| s.height).fold(0.0, f64::max);
                match axis {
                    SplitAxis::Horizontal => Size::new(sizes.iter().map(|s| s.width).sum::<f64>() + gaps, max_h),
                    SplitAxis::Vertical => Size::new(max_w, sizes.iter().map(|s| s.height).sum::<f64>() + gaps),
                }
            }
        }
    }

    /// Minimum length of each child along the split axis.
    // Swift: LayoutMetrics.swift:29
    pub fn child_minimums(axis: SplitAxis, children: &[LayoutNode]) -> Vec<f64> {
        children
            .iter()
            .map(|c| {
                let s = Self::min_size_of(c);
                if axis == SplitAxis::Horizontal { s.width } else { s.height }
            })
            .collect()
    }

    /// Fractions (summing to 1) for panes sharing `length` points (dividers already subtracted) so that every pane
    /// keeps at least its minimum. Panes below their minimum are raised; the excess is taken from the others in
    /// proportion. When the minimums do not fit, the panes share `length` in proportion to their minimums.
    // Swift: LayoutMetrics.swift:39
    pub fn clamped_fractions(fractions: &[f64], length: f64, mins: &[f64]) -> Vec<f64> {
        let n = fractions.len();
        if n == 0 || mins.len() != n {
            return fractions.to_vec();
        }
        let mins: Vec<f64> = mins.iter().map(|m| if m.is_finite() { m.max(0.0) } else { 0.0 }).collect();
        let equal = vec![1.0 / n as f64; n];
        if !length.is_finite() || length <= 0.0 {
            return equal;
        }
        let min_sum: f64 = mins.iter().sum();
        if min_sum >= length {
            return if min_sum > 0.0 { mins.iter().map(|m| m / min_sum).collect() } else { equal };
        }
        let mut base: Vec<f64> = fractions.iter().map(|f| if f.is_finite() { f.max(0.0) } else { 0.0 }).collect();
        let sum: f64 = base.iter().sum();
        base = if sum > 0.0 { base.iter().map(|f| f / sum).collect() } else { equal.clone() };
        let mut lens: Vec<f64> = base.iter().map(|f| f * length).collect();
        let mut pinned = HashSet::new();
        for _ in 0..=n {
            let low: Vec<usize> = (0..n).filter(|i| !pinned.contains(i) && lens[*i] < mins[*i] - 1e-9).collect();
            if low.is_empty() {
                break;
            }
            for i in low {
                lens[i] = mins[i];
                pinned.insert(i);
            }
            let free: Vec<usize> = (0..n).filter(|i| !pinned.contains(i)).collect();
            let target = length - pinned.iter().map(|i| lens[*i]).sum::<f64>();
            let free_base: f64 = free.iter().map(|i| base[*i]).sum();
            if free_base <= 0.0 {
                break;
            }
            for i in free {
                lens[i] = base[i] / free_base * target;
            }
        }
        let total: f64 = lens.iter().sum();
        if total > 0.0 { lens.iter().map(|l| l / total).collect() } else { equal }
    }

    /// Clamps one proposed divider position between its two panes, each keeping its minimum.
    // Swift: LayoutMetrics.swift:67
    pub fn clamped_divider(proposed: f64, start: f64, end: f64, min_before: f64, min_after: f64) -> f64 {
        let lo = start + min_before;
        let hi = end - min_after;
        if lo <= hi { proposed.max(lo).min(hi) } else { (start + end) / 2.0 }
    }
}

/// Saved layouts from before a panel was removed (Properties) name panels that no longer exist.
// Swift: LayoutMetrics.swift:77
pub enum WorkspaceMigration {}

impl WorkspaceMigration {
    /// Removes unknown panel names from `panels` arrays, `hidden` and `maximized`, and repairs `selected`, anywhere in
    /// the JSON. Returns the input unchanged when it is not JSON.
    // Swift: LayoutMetrics.swift:87
    pub fn drop_unknown_panels(data: &[u8]) -> Vec<u8> {
        match serde_json::from_slice::<serde_json::Value>(data) {
            Ok(obj) => serde_json::to_vec(&Self::walk(obj)).unwrap_or_else(|_| data.to_vec()),
            Err(_) => data.to_vec(),
        }
    }

    /// A panel this version knows. (The Color page's clip list docks again since the version 9 design; Edit layouts
    /// lose it in `WorkspaceStore::load`.)
    fn known(v: &serde_json::Value) -> bool {
        v.as_str().is_some_and(|s| PanelID::ALL.iter().any(|p| p.raw_value() == s))
    }

    fn walk(v: serde_json::Value) -> serde_json::Value {
        use serde_json::Value;
        match v {
            Value::Array(a) => Value::Array(a.into_iter().map(Self::walk).collect()),
            Value::Object(o) => {
                let mut d: serde_json::Map<String, Value> = o.into_iter().map(|(k, x)| (k, Self::walk(x))).collect();
                if let Some(Value::Array(p)) = d.get("panels") {
                    let kept: Vec<Value> = p.iter().filter(|x| Self::known(x)).cloned().collect();
                    let selected_gone =
                        d.get("selected").is_some_and(|sel| !kept.iter().any(|k| k.as_str() == sel.as_str()));
                    if let (true, Some(first)) = (selected_gone, kept.first()) {
                        d.insert("selected".to_string(), first.clone());
                    }
                    d.insert("panels".to_string(), Value::Array(kept));
                }
                if let Some(Value::Array(h)) = d.get("hidden") {
                    let kept: Vec<Value> = h.iter().filter(|x| Self::known(x)).cloned().collect();
                    d.insert("hidden".to_string(), Value::Array(kept));
                }
                if d.get("maximized").is_some_and(|m| !Self::known(m)) {
                    d.remove("maximized");
                }
                Value::Object(d)
            }
            other => other,
        }
    }
}
