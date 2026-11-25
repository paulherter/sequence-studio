//! Effect Controls on the shared draw toolkit (Swift `SQInspectorUI/Draw/EffectControls*`, `EffectKeyframeLanesDraw`,
//! `GraphEditorDraw`, `InlineSpeedGraphDraw`, `KeyframeGraphDraw`, `EasingPopoverDraw`).
//!
//! Mapping (docs/rust/session-ui-design.md section 2): the Swift classes held the `EffectControlsModel` and wired `onX`
//! closures. Here the model is passed as `&mut EffectControlsModel` to every call, hooks are event enums the owner drains,
//! and menu items whose closures captured the model are [`ModelMenu`] entries that run against the model later.

pub mod easing_popover_draw;
pub mod effect_controls_draw_input;
pub mod effect_controls_draw_panel;
pub mod effect_controls_draw_rows;
pub mod effect_controls_draw_surfaces;
pub mod effect_controls_draw_view;
pub mod effect_keyframe_lanes_draw;
pub mod graph_chips;
pub mod graph_editor_draw;
pub mod inline_speed_graph_draw;
pub mod keyframe_graph_draw;

#[cfg(test)]
mod tests;

use std::rc::Rc;

use sq_draw::draw_list::Color;
use sq_draw::{Canvas, DrawTheme, InspectorDraw, InspectorTokens, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqmenu_model::SQMenuItem;

use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::property::EffectProperty;
use crate::keyframes::key_tools_input::KeyToolPrompt;

/// What happens with a dialog's answer (`None`: canceled).
pub type PromptDone = Rc<dyn Fn(&mut EffectControlsModel, Option<Vec<String>>)>;

/// A key tool dialog the host shows; `done` gets the typed texts in field order, `None` when canceled.
pub struct PromptRequest {
    /// The dialog as data.
    pub prompt: KeyToolPrompt,
    /// What happens with the answer.
    pub done: PromptDone,
}

/// What a menu entry does when it is chosen.
pub type MenuRun = Rc<dyn Fn(&mut EffectControlsModel, &mut Vec<MenuOutput>)>;

/// What a menu action hands back to its owner besides the model edit.
pub enum MenuOutput {
    /// A dialog to show.
    Prompt(PromptRequest),
    /// An item of a value graph's easing menu (the graph keeps the ease side and the preset library).
    /// "Reset to Automatic" of a property a variant overrides (needs the session).
    ResetToAutomatic(EffectProperty),
    Graph {
        /// The row the graph belongs to.
        property: EffectProperty,
        /// Index of the graph among the row's component graphs.
        index: usize,
        /// The chosen item.
        action: keyframe_graph_draw::GraphMenuAction,
    },
}

/// One row of a [`ModelMenu`]: the item the menu shows, what it runs and its submenu.
pub struct MenuEntry {
    /// The row as the host's menu shows it.
    pub item: SQMenuItem,
    /// Runs when the row is chosen (Swift: the `SQMenuItem` action closure).
    pub run: Option<MenuRun>,
    /// Rows of a submenu.
    pub sub: Vec<MenuEntry>,
}

impl MenuEntry {
    /// An action row.
    pub fn action(
        item: SQMenuItem,
        run: impl Fn(&mut EffectControlsModel, &mut Vec<MenuOutput>) + 'static,
    ) -> MenuEntry {
        MenuEntry { item, run: Some(Rc::new(run)), sub: Vec::new() }
    }
    /// A row without an action (separator, header, disabled row).
    pub fn plain(item: SQMenuItem) -> MenuEntry {
        MenuEntry { item, run: None, sub: Vec::new() }
    }
    /// A row that opens a submenu.
    pub fn submenu(mut item: SQMenuItem, sub: Vec<MenuEntry>) -> MenuEntry {
        item.submenu = Some(sub.iter().map(|e| e.item.clone()).collect());
        MenuEntry { item, run: None, sub }
    }
}

/// A menu whose rows act on the Effect Controls model. The host shows [`ModelMenu::items`] and reports the chosen index
/// path (`SQMenuResult::Run`) to [`ModelMenu::run`].
#[derive(Default)]
pub struct ModelMenu {
    /// The rows.
    pub entries: Vec<MenuEntry>,
}

impl ModelMenu {
    /// The rows for the host's menu.
    pub fn items(&self) -> Vec<SQMenuItem> {
        self.entries.iter().map(|e| e.item.clone()).collect()
    }
    /// True when there is nothing to show.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
    /// Appends the rows of `other`.
    pub fn extend(&mut self, other: ModelMenu) {
        self.entries.extend(other.entries);
    }
    /// Runs the row at `path`; returns what the action handed back (dialogs, graph items).
    pub fn run(&self, path: &[usize], model: &mut EffectControlsModel) -> Vec<MenuOutput> {
        let mut prompts = Vec::new();
        let mut level = &self.entries;
        for (n, &i) in path.iter().enumerate() {
            let Some(e) = level.get(i) else { return prompts };
            if n + 1 == path.len()
                && let Some(run) = &e.run
            {
                run(model, &mut prompts);
            }
            level = &e.sub;
        }
        prompts
    }
}

/// `c.draw(s, in: r, fontSize:, color, align:)`: one line centered vertically in `r`.
pub(crate) fn text_in(c: &mut Canvas, s: &str, r: CGRect, size: f64, color: Color, align: TextAlign) {
    c.draw_text_in(s, r, size, color, align, 0.0, 0);
}

/// `c.draw(s, at: p, fontSize:, color)`: the top-left of the line box at `p`.
pub(crate) fn text_at(c: &mut Canvas, s: &str, p: CGPoint, size: f64, color: Color) {
    c.draw_text(s, p, size, color, f64::INFINITY, 0);
}

/// The marquee rectangle every graph and lane draws: accent tint with a 1 pt accent outline.
pub(crate) fn draw_marquee(c: &mut Canvas, m: CGRect, t: &DrawTheme) {
    c.fill(m, t.accent_tint());
    let e = m.inset_by(0.5, 0.5);
    c.stroke_polygon(
        &[
            CGPoint::new(e.min_x(), e.min_y()),
            CGPoint::new(e.max_x(), e.min_y()),
            CGPoint::new(e.max_x(), e.max_y()),
            CGPoint::new(e.min_x(), e.max_y()),
        ],
        1.0,
        t.accent(),
    );
}

/// `CGRect.offsetBy`.
pub(crate) fn offset_by(r: CGRect, dx: f64, dy: f64) -> CGRect {
    CGRect::new(r.x + dx, r.y + dy, r.width, r.height)
}

/// `CGRect(x: min, y: min, width: abs, height: abs)` from two corners.
pub(crate) fn rect_from(a: CGPoint, b: CGPoint) -> CGRect {
    CGRect::new(a.x.min(b.x), a.y.min(b.y), (b.x - a.x).abs(), (b.y - a.y).abs())
}

/// `InspectorDraw.button` with the Swift defaults (`accent: false`, capsule height).
pub(crate) fn button(
    c: &mut Canvas,
    title: &str,
    r: CGRect,
    hovering: bool,
    pressed: bool,
    enabled: bool,
    t: &DrawTheme,
) {
    InspectorDraw::button(c, title, r, hovering, pressed, enabled, false, InspectorTokens::CAPSULE as f64, t);
}

/// The inspector group header (r8 `.grp`: `border-group` line under it, chevron 9 in `text-tertiary`, semibold title) for
/// the panels that fold their own sections (Text, Captions). `summary` is the quiet text at the right end.
#[allow(clippy::too_many_arguments)]
pub(crate) fn group_header(
    c: &mut Canvas,
    f: CGRect,
    width: f64,
    title: &str,
    open: bool,
    hovered: bool,
    summary: &str,
    top_line: bool,
    t: &DrawTheme,
) {
    use sq_uikit::controls_grid::ControlsGrid;
    use sq_uikit::localization::SQL10n;
    use sq_uikit::sqicon::SQIcon;
    let fs = f64::from(sq_draw::theme::type_size::BODY);
    if top_line {
        c.fill(CGRect::new(0.0, f.min_y(), width, 1.0), t.separator());
    }
    let toggle = CGRect::new(ControlsGrid::HEADER_TOGGLE_X, f.min_y(), 12.0, f.height);
    let icon = if open { SQIcon::ChevronDown } else { SQIcon::ChevronRight };
    let ink = if hovered { t.label2() } else { t.label3() };
    c.draw_icon(icon, CGPoint::new((toggle.mid_x() - 4.5).round(), (f.mid_y() - 4.5).round()), 9.0, ink, None);
    let sx = ControlsGrid::HEADER_LABEL_X + 90.0;
    let sw = (width - ControlsGrid::TRAILING - sx).max(0.0);
    let bold = c.semibold();
    let title = SQL10n::string(title);
    let room = if summary.is_empty() { width - ControlsGrid::HEADER_LABEL_X } else { 90.0 };
    let cut = sq_draw::middle_fit::truncate_name(&title, |n| c.size_of(n, fs, bold).width <= room);
    c.draw_text_in(
        &cut.shown,
        CGRect::new(ControlsGrid::HEADER_LABEL_X, f.min_y(), room.max(0.0), f.height),
        fs,
        t.label(),
        sq_draw::TextAlign::Left,
        0.0,
        bold,
    );
    if !summary.is_empty() {
        c.draw_text_in(
            summary,
            CGRect::new(sx, f.min_y(), sw, f.height),
            fs,
            t.label3(),
            sq_draw::TextAlign::Right,
            0.0,
            0,
        );
    }
    c.fill(CGRect::new(0.0, f.max_y() - 1.0, width, 1.0), t.separator());
}

/// `InspectorDraw.popup` with the Swift defaults (`plain: false`, capsule height, body font).
pub(crate) fn popup(c: &mut Canvas, title: &str, r: CGRect, hovering: bool, open: bool, enabled: bool, t: &DrawTheme) {
    InspectorDraw::popup(c, title, r, hovering, open, enabled, true, InspectorTokens::CAPSULE as f64, None, t);
}

/// The mask modes in menu order (`MaskMode.allCases`; the core crate has no list yet).
pub(crate) const MASK_MODES: [sq_core_model::MaskMode; 4] = [
    sq_core_model::MaskMode::Add,
    sq_core_model::MaskMode::Subtract,
    sq_core_model::MaskMode::Intersect,
    sq_core_model::MaskMode::Difference,
];

/// `MaskMode.title`.
pub(crate) fn mask_mode_title(m: sq_core_model::MaskMode) -> &'static str {
    match m {
        sq_core_model::MaskMode::Add => "Add",
        sq_core_model::MaskMode::Subtract => "Subtract",
        sq_core_model::MaskMode::Intersect => "Intersect",
        sq_core_model::MaskMode::Difference => "Difference",
    }
}

/// `MatteChannel.allCases`.
pub(crate) const MATTE_CHANNELS: [sq_core_model::MatteChannel; 2] =
    [sq_core_model::MatteChannel::Shape, sq_core_model::MatteChannel::Brightness];

/// `MatteChannel.title`.
pub(crate) fn matte_channel_title(c: sq_core_model::MatteChannel) -> &'static str {
    match c {
        sq_core_model::MatteChannel::Shape => "Shape",
        sq_core_model::MatteChannel::Brightness => "Brightness",
    }
}
