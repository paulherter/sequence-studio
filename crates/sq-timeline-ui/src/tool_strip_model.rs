// Swift: ToolStripModel.swift
//! The tool bar's dock geometry, preferences, tools and menus, shared by every shell that draws the strip.

use sq_editor_session::{CreateToolMode, MaskToolMode, TimelineTool, ToolState};
use sq_library::library_folder_store::SettingsStore;
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::{EditorCommand, EditorTool};
use sq_uikit::keyboard_listing::KeyboardListing;
use sq_uikit::keyframe_graph_geometry::{Point, Rect, Size};
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::rc::Rc;

/// Where the tool strip is docked. `Floating` = a rounded panel over the timeline.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ToolStripEdge {
    /// Left column.
    Left,
    /// Right column.
    Right,
    /// Row above the lanes.
    Top,
    /// Row below the lanes.
    Bottom,
    /// A panel over the timeline.
    Floating,
}

impl ToolStripEdge {
    /// All cases.
    pub const ALL: [ToolStripEdge; 5] =
        [ToolStripEdge::Left, ToolStripEdge::Right, ToolStripEdge::Top, ToolStripEdge::Bottom, ToolStripEdge::Floating];

    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            ToolStripEdge::Left => "left",
            ToolStripEdge::Right => "right",
            ToolStripEdge::Top => "top",
            ToolStripEdge::Bottom => "bottom",
            ToolStripEdge::Floating => "floating",
        }
    }

    /// From the Swift raw value.
    pub fn from_raw(s: &str) -> Option<ToolStripEdge> {
        Self::ALL.into_iter().find(|e| e.raw_value() == s)
    }

    /// Left and right are columns; top, bottom and the floating bar are rows (v9 `.tbar.floating`: a row).
    pub fn is_vertical(self) -> bool {
        self == ToolStripEdge::Left || self == ToolStripEdge::Right
    }
}

/// Window > Tools: visibility, dock edge and float origin (settings `sq.tools.*`). Swift posts `didChange` after a write;
/// the caller of a setter knows and redraws.
pub struct ToolStripPrefs<'a> {
    store: &'a mut dyn SettingsStore,
}

impl<'a> ToolStripPrefs<'a> {
    /// Settings key of the visibility.
    pub const VISIBLE_KEY: &'static str = "sq.tools.visible";
    /// Settings key of the dock edge.
    pub const EDGE_KEY: &'static str = "sq.tools.edge";
    /// Settings key of the float origin x.
    pub const FLOAT_X_KEY: &'static str = "sq.tools.floatX";
    /// Settings key of the float origin y.
    pub const FLOAT_Y_KEY: &'static str = "sq.tools.floatY";

    /// Preferences over `store`.
    pub fn new(store: &'a mut dyn SettingsStore) -> ToolStripPrefs<'a> {
        ToolStripPrefs { store }
    }

    fn number(&self, key: &str) -> Option<f64> {
        let d = self.store.data(key)?;
        String::from_utf8(d).ok()?.parse().ok()
    }

    /// The strip is shown (default yes).
    pub fn visible(&self) -> bool {
        match self.store.data(Self::VISIBLE_KEY).as_deref() {
            Some(b"true") => true,
            Some(b"false") => false,
            _ => true,
        }
    }

    /// Shows or hides the strip.
    pub fn set_visible(&mut self, v: bool) {
        self.store.set_data(Self::VISIBLE_KEY, if v { b"true".to_vec() } else { b"false".to_vec() });
    }

    /// The dock edge (default left).
    pub fn edge(&self) -> ToolStripEdge {
        self.store
            .data(Self::EDGE_KEY)
            .and_then(|d| String::from_utf8(d).ok())
            .and_then(|s| ToolStripEdge::from_raw(&s))
            .unwrap_or(ToolStripEdge::Left)
    }

    /// Docks the strip.
    pub fn set_edge(&mut self, e: ToolStripEdge) {
        self.store.set_data(Self::EDGE_KEY, e.raw_value().as_bytes().to_vec());
    }

    /// Where the floating strip sits (default 40, 40).
    pub fn float_origin(&self) -> Point {
        Point::new(self.number(Self::FLOAT_X_KEY).unwrap_or(40.0), self.number(Self::FLOAT_Y_KEY).unwrap_or(40.0))
    }

    /// Moves the floating strip.
    pub fn set_float_origin(&mut self, p: Point) {
        self.store.set_data(Self::FLOAT_X_KEY, p.x.to_string().into_bytes());
        self.store.set_data(Self::FLOAT_Y_KEY, p.y.to_string().into_bytes());
    }
}

/// Pure geometry of the tool bar dock. Design v9 `.tbar`: 38 wide beside the lanes with an 18 pt grip on top and
/// 28 pt tools; docked above (or below) the lanes it is a 36 pt row; floating it is a 36 pt row with 4 pt padding.
pub struct ToolStripLayout;

impl ToolStripLayout {
    /// Width of a column bar.
    pub const THICKNESS: f64 = sq_uikit::redesign_tokens::size::TOOL_PANEL as f64;
    /// Height of the bar as a row (docked top / bottom, floating).
    pub const ROW_THICKNESS: f64 = 36.0;
    /// Size of a tool button.
    pub const TOOL_SIZE: f64 = 24.0;
    /// Vertical bar: the 28 pt panel header with the grip.
    pub const GRIP_LENGTH: f64 = sq_uikit::redesign_tokens::size::PANEL_HEADER as f64;
    /// Vertical bar: a tool is 26 x 24, 4 apart, the list starts 8 below the header.
    pub const V_TOOL_W: f64 = sq_uikit::redesign_tokens::size::TOOL_W as f64;
    pub const V_TOOL_H: f64 = sq_uikit::redesign_tokens::size::TOOL_H as f64;
    pub const V_GAP: f64 = 4.0;
    pub const V_TOP_PAD: f64 = 8.0;
    /// Vertical bar: a 4 pt separator (with the gaps around it 12 pt) follows the first this many tools.
    pub const GROUP_SPLIT: usize = 3;
    pub const GROUP_BREAK: f64 = 8.0;
    /// Row: a 24 pt wide grip.
    pub const ROW_GRIP_LENGTH: f64 = 24.0;
    /// Gap between tools.
    pub const TOOL_GAP: f64 = 2.0;
    /// Padding at the ends of a docked bar.
    pub const END_PADDING: f64 = 8.0;
    /// Padding of the floating bar.
    pub const FLOAT_PADDING: f64 = 4.0;
    /// A drag ending this close to the left / right edge docks there (v9: 64).
    pub const SNAP_DISTANCE_X: f64 = 64.0;
    /// A drag ending this close to the top / bottom docks there (v9: 48).
    pub const SNAP_DISTANCE_Y: f64 = 48.0;

    /// Thickness of the bar docked at `edge`.
    pub fn thickness(edge: ToolStripEdge) -> f64 {
        if edge.is_vertical() { Self::THICKNESS } else { Self::ROW_THICKNESS }
    }

    /// Length of the bar along its main axis for `tool_count` tools.
    pub fn length(tool_count: usize, edge: ToolStripEdge) -> f64 {
        let tools = tool_count as f64 * Self::TOOL_SIZE + tool_count.saturating_sub(1) as f64 * Self::TOOL_GAP;
        match edge {
            ToolStripEdge::Left | ToolStripEdge::Right => {
                Self::vertical_tool_y(tool_count.saturating_sub(1)) + Self::V_TOOL_H + Self::END_PADDING
            }
            ToolStripEdge::Top | ToolStripEdge::Bottom => {
                Self::END_PADDING + Self::ROW_GRIP_LENGTH + tools + Self::END_PADDING
            }
            ToolStripEdge::Floating => Self::FLOAT_PADDING + Self::ROW_GRIP_LENGTH + tools + Self::FLOAT_PADDING,
        }
    }

    /// Top of tool `i` in a vertical bar: after the first group the separator adds `GROUP_BREAK`.
    pub fn vertical_tool_y(i: usize) -> f64 {
        let extra = if i >= Self::GROUP_SPLIT { Self::GROUP_BREAK } else { 0.0 };
        Self::GRIP_LENGTH + Self::V_TOP_PAD + i as f64 * (Self::V_TOOL_H + Self::V_GAP) + extra
    }

    /// Edge a drag released at `p` (in the dock's coordinates) docks to; `Floating` when far from every edge.
    pub fn edge_for(p: Point, bounds: &Rect) -> ToolStripEdge {
        if p.x - bounds.min_x() < Self::SNAP_DISTANCE_X {
            return ToolStripEdge::Left;
        }
        if bounds.max_x() - p.x < Self::SNAP_DISTANCE_X {
            return ToolStripEdge::Right;
        }
        if p.y - bounds.min_y() < Self::SNAP_DISTANCE_Y {
            return ToolStripEdge::Top;
        }
        if bounds.max_y() - p.y < Self::SNAP_DISTANCE_Y {
            return ToolStripEdge::Bottom;
        }
        ToolStripEdge::Floating
    }

    /// The highlighted drop zone of a docking edge while the grip is dragged (`None` for floating).
    pub fn zone(edge: ToolStripEdge, bounds: &Rect) -> Option<Rect> {
        match edge {
            ToolStripEdge::Left => {
                Some(Rect::new(bounds.min_x(), bounds.min_y(), Self::SNAP_DISTANCE_X, bounds.height))
            }
            ToolStripEdge::Right => Some(Rect::new(
                bounds.max_x() - Self::SNAP_DISTANCE_X,
                bounds.min_y(),
                Self::SNAP_DISTANCE_X,
                bounds.height,
            )),
            ToolStripEdge::Top => Some(Rect::new(bounds.min_x(), bounds.min_y(), bounds.width, Self::SNAP_DISTANCE_Y)),
            ToolStripEdge::Bottom => Some(Rect::new(
                bounds.min_x(),
                bounds.max_y() - Self::SNAP_DISTANCE_Y,
                bounds.width,
                Self::SNAP_DISTANCE_Y,
            )),
            ToolStripEdge::Floating => None,
        }
    }

    /// Bar frame and the content frame left over (flipped coordinates).
    pub fn frames(
        edge: ToolStripEdge,
        bounds: &Rect,
        tool_count: usize,
        float_origin: Point,
        visible: bool,
    ) -> (Rect, Rect) {
        if !visible {
            return (Rect::new(0.0, 0.0, 0.0, 0.0), *bounds);
        }
        let row = Self::ROW_THICKNESS;
        let t = Self::THICKNESS;
        match edge {
            ToolStripEdge::Left => (
                Rect::new(bounds.min_x(), bounds.min_y(), t, bounds.height),
                Rect::new(bounds.min_x() + t, bounds.min_y(), (bounds.width - t).max(0.0), bounds.height),
            ),
            ToolStripEdge::Right => (
                Rect::new(bounds.max_x() - t, bounds.min_y(), t, bounds.height),
                Rect::new(bounds.min_x(), bounds.min_y(), (bounds.width - t).max(0.0), bounds.height),
            ),
            ToolStripEdge::Top => (
                Rect::new(bounds.min_x(), bounds.min_y(), bounds.width, row),
                Rect::new(bounds.min_x(), bounds.min_y() + row, bounds.width, (bounds.height - row).max(0.0)),
            ),
            ToolStripEdge::Bottom => (
                Rect::new(bounds.min_x(), bounds.max_y() - row, bounds.width, row),
                Rect::new(bounds.min_x(), bounds.min_y(), bounds.width, (bounds.height - row).max(0.0)),
            ),
            ToolStripEdge::Floating => {
                let w = Self::length(tool_count, ToolStripEdge::Floating);
                let h = row;
                let x = float_origin.x.max(bounds.min_x()).min((bounds.max_x() - w).max(bounds.min_x()));
                let y = float_origin.y.max(bounds.min_y()).min((bounds.max_y() - h).max(bounds.min_y()));
                (Rect::new(x, y, w, h), *bounds)
            }
        }
    }

    /// Rect of the grip and of tool `i` inside a bar of `edge`, in the bar's own flipped coordinates.
    pub fn slots(edge: ToolStripEdge, tool_count: usize, size: Size) -> (Rect, Vec<Rect>) {
        let mut tools = Vec::new();
        if edge.is_vertical() {
            let x = ((size.width - Self::V_TOOL_W) / 2.0).round();
            for i in 0..tool_count {
                tools.push(Rect::new(x, Self::vertical_tool_y(i), Self::V_TOOL_W, Self::V_TOOL_H));
            }
            return (Rect::new(0.0, 0.0, size.width, Self::GRIP_LENGTH), tools);
        }
        let lead = if edge == ToolStripEdge::Floating { Self::FLOAT_PADDING } else { Self::END_PADDING };
        let y = ((size.height - Self::TOOL_SIZE) / 2.0).round();
        let x0 = lead + Self::ROW_GRIP_LENGTH;
        for i in 0..tool_count {
            tools.push(Rect::new(
                x0 + i as f64 * (Self::TOOL_SIZE + Self::TOOL_GAP),
                y,
                Self::TOOL_SIZE,
                Self::TOOL_SIZE,
            ));
        }
        (Rect::new(lead, y, Self::ROW_GRIP_LENGTH, Self::TOOL_SIZE), tools)
    }
}

/// The tool bar's tools and menus, shared by the Mac `ToolStripView` and the draw-list strip.
/// `commit` receives the new tool state; the caller hands it to the timeline (and reports the tool change).
pub struct ToolStripTools;

impl ToolStripTools {
    /// Design v9 `TOOLS`, in order.
    pub const ORDER: [TimelineTool; 6] = [
        TimelineTool::Selection,
        TimelineTool::Razor,
        TimelineTool::Slip,
        TimelineTool::Hand,
        TimelineTool::Type,
        TimelineTool::Mask,
    ];

    /// The icon and title of a slot (`None` for tools without a button).
    pub fn symbol(t: TimelineTool) -> Option<(SQIcon, &'static str)> {
        match t {
            TimelineTool::Selection => Some((SQIcon::ToolSelect, "Select")),
            TimelineTool::Razor => Some((SQIcon::ToolBlade, "Blade")),
            TimelineTool::Slip => Some((SQIcon::ToolSlip, "Slip")),
            TimelineTool::Hand => Some((SQIcon::ToolHand, "Hand")),
            TimelineTool::Type => Some((SQIcon::Text, "Create")),
            TimelineTool::Mask => Some((SQIcon::ToolMask, "Mask")),
            _ => None,
        }
    }

    /// Design v9 `TOOLS`: what each tool does (second part of the tooltip).
    pub fn help(t: TimelineTool) -> Option<&'static str> {
        match t {
            TimelineTool::Selection => Some("Select, move and trim clips."),
            TimelineTool::Razor => Some("Cuts a clip where you click."),
            TimelineTool::Slip => Some("Moves the content inside a clip. Hold for keyframe behavior."),
            TimelineTool::Hand => Some("Scrolls the timeline."),
            TimelineTool::Type => Some("Adds an item to a Graphic clip. Hold for the shape."),
            TimelineTool::Mask => Some("Masks the selected clip. Hold for the mask type."),
            _ => None,
        }
    }

    /// The button that shows `t` as active: a tool without a button lights the button of its group, so a key never leaves
    /// an invisible mode (selection family on Select, Slide on Slip, Zoom on Hand).
    pub fn slot_tool(t: TimelineTool) -> TimelineTool {
        match t {
            TimelineTool::TrackSelectForward
            | TimelineTool::RippleEdit
            | TimelineTool::RollEdit
            | TimelineTool::RateStretch
            | TimelineTool::Position => TimelineTool::Selection,
            TimelineTool::Slide => TimelineTool::Slip,
            TimelineTool::Zoom => TimelineTool::Hand,
            other => other,
        }
    }

    /// The short name a lit group button wears for a key-only tool (`None` when `t` has its own button): without it the
    /// Select button looks the same for Ripple, Roll and Rate Stretch and a key press seems to do nothing.
    pub fn badge(t: TimelineTool) -> Option<&'static str> {
        match t {
            TimelineTool::TrackSelectForward => Some("Fwd"),
            TimelineTool::RippleEdit => Some("Rip"),
            TimelineTool::RollEdit => Some("Roll"),
            TimelineTool::RateStretch => Some("Rate"),
            TimelineTool::Position => Some("Pos"),
            TimelineTool::Slide => Some("Slide"),
            TimelineTool::Zoom => Some("Zoom"),
            _ => None,
        }
    }

    /// Tools without a button (v9: "A, B, N, U, R and Z are keyboard only"): listed in the bar's right-click menu.
    pub const KEYBOARD_TOOLS: [(TimelineTool, &'static str); 7] = [
        (TimelineTool::TrackSelectForward, "Select Forward"),
        (TimelineTool::RippleEdit, "Ripple"),
        (TimelineTool::RollEdit, "Roll"),
        (TimelineTool::Slide, "Slide"),
        (TimelineTool::RateStretch, "Rate Stretch"),
        (TimelineTool::Zoom, "Zoom"),
        (TimelineTool::Position, "Position"),
    ];

    /// Tooltip of the grip.
    pub const GRIP_TIP: &'static str =
        "Tools · Drag to move the panel. Right-click a tool for every tool with its key.";

    /// Slots with a hold / right-click menu of variants (the corner mark).
    pub fn has_variants(t: TimelineTool) -> bool {
        t == TimelineTool::Slip || t == TimelineTool::Mask || t == TimelineTool::Type
    }

    /// The icon a slot shows for the current state: Create and Mask show their mode.
    pub fn icon(t: TimelineTool, state: &ToolState) -> SQIcon {
        match t {
            TimelineTool::Type => SQIcon::from_raw(state.create_mode.symbol()).unwrap_or(SQIcon::Text),
            TimelineTool::Mask => SQIcon::from_raw(state.mask_mode.symbol()).unwrap_or(SQIcon::ToolMask),
            _ => Self::symbol(t).map_or(SQIcon::Unknown, |s| s.0),
        }
    }

    /// The key-map tool a slot stands for (every slot has one).
    pub fn editor_tool(t: TimelineTool) -> Option<EditorTool> {
        Some(match t {
            TimelineTool::Selection => EditorTool::Selection,
            TimelineTool::TrackSelectForward => EditorTool::TrackForward,
            TimelineTool::RippleEdit => EditorTool::Ripple,
            TimelineTool::RollEdit => EditorTool::Rolling,
            TimelineTool::Slip => EditorTool::Slip,
            TimelineTool::Slide => EditorTool::Slide,
            TimelineTool::Razor => EditorTool::Razor,
            TimelineTool::Hand => EditorTool::Hand,
            TimelineTool::RateStretch => EditorTool::RateStretch,
            TimelineTool::Zoom => EditorTool::Zoom,
            TimelineTool::Type => EditorTool::Type, // the Create slot: its mode's own key-map tool is `CreateToolMode::editor_tool`
            TimelineTool::Mask => EditorTool::Mask,
            TimelineTool::Position => EditorTool::Position,
        })
    }

    fn checked_item(title: &str, checked: bool, action: impl Fn() + 'static) -> SQMenuItem {
        let mut i = SQMenuItem::new(title);
        i.is_checked = checked;
        i.action = Some(Rc::new(action));
        i
    }

    /// The hold / right-click menu of a slot with variants; empty for the others.
    pub fn variant_items(t: TimelineTool, state: &ToolState, commit: Rc<dyn Fn(ToolState)>) -> Vec<SQMenuItem> {
        let state = *state;
        match t {
            TimelineTool::Slip => {
                // Plain slip (keyframes follow the content) or keyframes stay on the timeline.
                let mut out = vec![SQMenuItem::header("Slip")];
                for (title, stay) in [("Keyframes follow content", false), ("Keyframes stay on the timeline", true)] {
                    let commit = Rc::clone(&commit);
                    out.push(Self::checked_item(title, stay == state.slip_keyframes_stay, move || {
                        let mut s = state;
                        s.tool = TimelineTool::Slip;
                        s.slip_keyframes_stay = stay;
                        commit(s);
                    }));
                }
                out
            }
            TimelineTool::Mask => {
                let mut out = vec![SQMenuItem::header("Mask")];
                for mode in MaskToolMode::ALL {
                    let commit = Rc::clone(&commit);
                    out.push(Self::checked_item(mode.title(), mode == state.mask_mode, move || {
                        let mut s = state;
                        s.tool = TimelineTool::Mask;
                        s.mask_mode = mode;
                        commit(s);
                    }));
                }
                out
            }
            TimelineTool::Type => {
                let mut out = vec![SQMenuItem::header("Create")];
                for mode in CreateToolMode::ALL {
                    let commit = Rc::clone(&commit);
                    out.push(Self::checked_item(mode.title(), mode == state.create_mode, move || {
                        let mut s = state;
                        s.tool = TimelineTool::Type;
                        s.create_mode = mode;
                        commit(s);
                    }));
                }
                out
            }
            _ => Vec::new(),
        }
    }

    /// Right-click on the bar (not on a tool) or a click on the grip: every tool with its key, the keyboard-only ones
    /// included, and where the bar docks. `on_action` receives the dock and hide choices (Swift writes `ToolStripPrefs`).
    pub fn all_tool_items(state: &ToolState, map: &CommandMap, commit: Rc<dyn Fn(ToolState)>) -> Vec<SQMenuItem> {
        let state = *state;
        let key = |t: TimelineTool| -> String {
            Self::editor_tool(t)
                .and_then(|et| map.shown_binding_here(&EditorCommand::Tool(et)))
                .map(|b| KeyboardListing::text_for(&b))
                .unwrap_or_default()
        };
        let item = |t: TimelineTool, title: &str| -> SQMenuItem {
            let commit = Rc::clone(&commit);
            let mut i = Self::checked_item(title, state.tool == t, move || {
                let mut s = state;
                s.tool = t;
                commit(s);
            });
            i.shortcut = key(t);
            i
        };
        let mut items = vec![SQMenuItem::header("Tools")];
        items.extend(Self::ORDER.iter().map(|t| item(*t, Self::symbol(*t).map_or("", |s| s.1))));
        items.push(SQMenuItem::separator());
        items.extend(Self::KEYBOARD_TOOLS.iter().map(|(t, title)| item(*t, title)));
        items
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_key_only_tool_wears_a_badge_on_its_group_button() {
        use super::*;
        for t in TimelineTool::ALL {
            let key_only = ToolStripTools::slot_tool(t) != t;
            assert_eq!(ToolStripTools::badge(t).is_some(), key_only, "{t:?}");
        }
    }

    #[test]
    fn every_tool_lights_exactly_one_button() {
        use super::*;
        for t in TimelineTool::ALL {
            let lit = ToolStripTools::ORDER.iter().filter(|s| **s == ToolStripTools::slot_tool(t)).count();
            assert_eq!(lit, 1, "{t:?}");
        }
    }

    use super::*;
    use crate::rect_math::{intersection, union};
    use sq_library::library_folder_store::MemorySettings;
    use sq_uikit::sqmenu_model::SQMenuItemKind;
    use std::cell::RefCell;

    /// Positive-area overlap: touching edges are no overlap.
    fn overlaps(a: &Rect, b: &Rect) -> bool {
        intersection(a, b).is_some_and(|i| i.width > 0.0 && i.height > 0.0)
    }

    fn bounds() -> Rect {
        Rect::new(0.0, 0.0, 800.0, 300.0)
    }

    fn p(x: f64, y: f64) -> Point {
        Point::new(x, y)
    }

    fn contains(outer: &Rect, r: &Rect) -> bool {
        r.min_x() >= outer.min_x()
            && r.max_x() <= outer.max_x()
            && r.min_y() >= outer.min_y()
            && r.max_y() <= outer.max_y()
    }

    #[test]
    fn drag_near_an_edge_docks_there() {
        let b = bounds();
        assert_eq!(ToolStripLayout::edge_for(p(10.0, 150.0), &b), ToolStripEdge::Left);
        assert_eq!(ToolStripLayout::edge_for(p(790.0, 150.0), &b), ToolStripEdge::Right);
        assert_eq!(ToolStripLayout::edge_for(p(400.0, 5.0), &b), ToolStripEdge::Top);
        assert_eq!(ToolStripLayout::edge_for(p(400.0, 47.0), &b), ToolStripEdge::Top);
        assert_eq!(ToolStripLayout::edge_for(p(63.0, 150.0), &b), ToolStripEdge::Left);
        assert_eq!(ToolStripLayout::edge_for(p(400.0, 295.0), &b), ToolStripEdge::Bottom);
        assert_eq!(ToolStripLayout::edge_for(p(400.0, 150.0), &b), ToolStripEdge::Floating);
    }

    #[test]
    fn docked_strip_takes_its_thickness_from_the_content() {
        let b = bounds();
        for edge in [ToolStripEdge::Left, ToolStripEdge::Right, ToolStripEdge::Top, ToolStripEdge::Bottom] {
            let f = ToolStripLayout::frames(edge, &b, 5, p(0.0, 0.0), true);
            assert!(!overlaps(&f.0, &f.1));
            assert_eq!(union(&f.0, &f.1), b);
        }
        let left = ToolStripLayout::frames(ToolStripEdge::Left, &b, 5, p(0.0, 0.0), true);
        assert!(left.0.width == 36.0 && left.1.min_x() == 36.0);
    }

    #[test]
    fn floating_strip_keeps_content_whole_and_stays_inside() {
        let b = bounds();
        let f = ToolStripLayout::frames(ToolStripEdge::Floating, &b, 5, p(5000.0, -20.0), true);
        assert!(f.1 == b && contains(&b, &f.0));
    }

    #[test]
    fn bar_is_a_column_beside_the_lanes_and_a_row_elsewhere() {
        let b = bounds();
        assert!(
            ToolStripLayout::thickness(ToolStripEdge::Left) == 36.0
                && ToolStripLayout::thickness(ToolStripEdge::Right) == 36.0
        );
        assert!(
            ToolStripLayout::thickness(ToolStripEdge::Top) == 36.0
                && ToolStripLayout::thickness(ToolStripEdge::Floating) == 36.0
        );
        assert!(!ToolStripEdge::Floating.is_vertical());
        assert_eq!(ToolStripLayout::zone(ToolStripEdge::Left, &b).map(|z| z.width), Some(64.0));
        assert_eq!(ToolStripLayout::zone(ToolStripEdge::Top, &b).map(|z| z.height), Some(48.0));
        assert!(ToolStripLayout::zone(ToolStripEdge::Floating, &b).is_none());
    }

    #[test]
    fn hidden_strip_gives_the_content_everything() {
        let b = bounds();
        let f = ToolStripLayout::frames(ToolStripEdge::Left, &b, 5, p(0.0, 0.0), false);
        assert!(f.1 == b && f.0 == Rect::new(0.0, 0.0, 0.0, 0.0));
    }

    #[test]
    fn tools_fit_inside_the_strip() {
        for edge in [ToolStripEdge::Left, ToolStripEdge::Top, ToolStripEdge::Floating] {
            let n = 6;
            let t = ToolStripLayout::thickness(edge);
            let len = ToolStripLayout::length(n, edge);
            let size = if edge.is_vertical() { Size::new(t, len) } else { Size::new(len, t) };
            let s = ToolStripLayout::slots(edge, n, size);
            let rect = Rect::new(0.0, 0.0, size.width, size.height);
            let w = if edge.is_vertical() { 26.0 } else { 24.0 };
            assert!(s.1.iter().all(|r| contains(&rect, r) && r.width == w && r.height == 24.0));
            assert!(contains(&rect, &s.0));
            assert!(s.1.iter().all(|r| !overlaps(r, &s.0)));
        }
    }

    #[test]
    fn the_column_has_a_28_pt_header_and_a_separator_after_the_third_tool() {
        let (grip, tools) = ToolStripLayout::slots(ToolStripEdge::Left, 6, Size::new(36.0, 300.0));
        assert_eq!(grip.height, 28.0);
        assert_eq!((tools[0].min_y(), tools[0].width, tools[0].height), (36.0, 26.0, 24.0));
        assert_eq!(tools[1].min_y() - tools[0].max_y(), 4.0);
        assert_eq!(tools[3].min_y() - tools[2].max_y(), 12.0);
    }

    #[test]
    fn prefs_round_trip_with_defaults() {
        let mut m = MemorySettings::default();
        let mut prefs = ToolStripPrefs::new(&mut m);
        assert!(prefs.visible());
        assert_eq!(prefs.edge(), ToolStripEdge::Left);
        assert_eq!(prefs.float_origin(), p(40.0, 40.0));
        prefs.set_visible(false);
        prefs.set_edge(ToolStripEdge::Bottom);
        prefs.set_float_origin(p(12.5, 3.0));
        assert!(!prefs.visible());
        assert_eq!(prefs.edge(), ToolStripEdge::Bottom);
        assert_eq!(prefs.float_origin(), p(12.5, 3.0));
    }

    #[test]
    fn menus_commit_the_new_state_and_have_no_dock_choices() {
        let got = Rc::new(RefCell::new(Vec::<ToolState>::new()));
        let g = Rc::clone(&got);
        let state = ToolState::default();
        let items = ToolStripTools::all_tool_items(
            &state,
            &CommandMap::premiere_default(),
            Rc::new(move |s| g.borrow_mut().push(s)),
        );
        let run = |title: &str| {
            if let Some(a) = items.iter().find(|i| i.title == title).and_then(|i| i.action.as_ref()) {
                a();
            }
        };
        run("Blade");
        assert_eq!(got.borrow()[0].tool, TimelineTool::Razor);
        assert!(items.iter().all(|i| !i.title.starts_with("Dock") && i.title != "Hide Tool Bar"));
        assert!(items.iter().find(|i| i.title == "Select").is_some_and(|i| i.is_checked && !i.shortcut.is_empty()));
        assert_eq!(items.iter().filter(|i| i.kind == SQMenuItemKind::Separator).count(), 1);
        let g2 = Rc::new(RefCell::new(Vec::<ToolState>::new()));
        let g3 = Rc::clone(&g2);
        let v = ToolStripTools::variant_items(TimelineTool::Slip, &state, Rc::new(move |s| g3.borrow_mut().push(s)));
        assert_eq!(v.len(), 3);
        if let Some(a) = v[2].action.as_ref() {
            a();
        }
        assert!(g2.borrow()[0].slip_keyframes_stay);
        assert!(ToolStripTools::variant_items(TimelineTool::Hand, &state, Rc::new(|_| {})).is_empty());
    }
}
