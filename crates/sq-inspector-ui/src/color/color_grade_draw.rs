// Swift: Draw/ColorGradeDraw.swift
//! The Color panel on the shared toolkit. The Simple grade (the effects with their foldable sections: Basic with the Input
//! LUT, white balance and Sharpen, Creative with the look and the tint wheels, RGB and hue curves, the three wheels, the
//! Zone Board, Color Range, Vignette) and the Pro grade's selected Step (the four primary wheels, its sliders and curves).
//! The logic is the shared `ColorGradeController` and its `ColorInspectorModel`; this draws them and turns pointer and
//! keys into their setters. Coordinates: points, y down, (0, 0) = the panel's top-left; the panel scrolls itself
//! (`scroll_y`).
//!
//! Mapping: the Swift object held the controller; here every call that reads or writes takes the controller (and for
//! writes the session and clipboard) as a [`ColorGradeHost`], and menus are queued as [`GradeMenuRequest`]s whose rows
//! push [`DrawMenuCommand`]s that the host runs with `run_menu_command` after the menu closes.

use super::color_grade_controller::ColorGradeController;
use super::color_grade_target::ColorTargetState;
use super::color_graph_menus::MenuSink;
use super::color_inspector_model::{
    ColorInspectorModel, ColorLUTSlot, ColorPanelKey, ColorParam, ColorWheelSlot, HueCurveKind, LUTChoice,
};
use super::color_inspector_model_graph::{GraphLUTSlot, StepParam};
use super::color_inspector_model_graph_detail::{StepPrimaryRow, StepWindowParam};
use super::color_page_models::{ColorSectionText, ColorValueText};
use super::color_range_model::ColorRangeParam;
use super::color_sharpen::SHARPEN_ROW_RANGE;
use super::color_wheel_math::{ColorWheelMath, ColorWheelValue, PrimaryWheel};
use super::curve_editing::CurveEditing;
use super::geom::offset_by;
use super::step_range_logic::{Grab, StepRangeKind};
use sq_core_color::{BoardZone, ColorSectionKindExt};
use sq_core_model::{ColorSectionKind, CurvePoint, HSLMaskMode, LogMode, RGBCurves, TargetSpace};
use sq_core_time::Id;
use sq_draw::inspector::scrub_field_control::Event as ScrubEvent;
use sq_draw::inspector::{CheckState, ClickCounter, InspectorDraw, InspectorTokens, ScrubFieldControl};
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{spacing, type_size};
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Canvas, Color, DrawTheme, InputKey, InputModifiers, PolygonSpanCache, TextAlign, UiCx};
use sq_editor_session::{ColorClipboard, EditorSession};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::f64::consts::PI;
use std::rc::Rc;

/// What a draw call reads and writes: the controller (and through it the models), the session and the clipboard.
pub struct ColorGradeHost<'a> {
    pub controller: &'a mut ColorGradeController,
    pub session: &'a mut EditorSession,
    pub clipboard: &'a mut ColorClipboard,
}

impl ColorGradeHost<'_> {
    pub fn model(&self) -> Option<&ColorInspectorModel> {
        self.controller.model()
    }

    pub fn model_mut(&mut self) -> Option<&mut ColorInspectorModel> {
        self.controller.model_mut()
    }

    /// Runs the events the model queued (Swift ran its hooks inline).
    pub fn pump(&mut self) {
        self.controller.pump(self.session, self.clipboard);
    }
}

/// One slider of the panel.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Slider {
    Param(i64, ColorParam),
    Range(i64, ColorRangeParam),
    Sharpen,
    ZoneSat(i64, BoardZone),
    Step(Id, StepParam),
    /// The Pro page's own rows: Saturation / Contrast / Pivot (scaled), a Qualifier softness, a window value, a list row's
    /// Mix field.
    Primary(Id, StepPrimaryRow),
    StepQual(Id, ColorRangeParam),
    Window(Id, StepWindowParam),
    Mix(Id),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Wheel {
    Slot(i64, ColorWheelSlot),
    Zone(i64, BoardZone),
    Step(Id, PrimaryWheel),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Curve {
    Rgb(i64),
    Hue(i64),
    StepRgb(Id),
    StepHue(Id),
}

impl Curve {
    pub fn is_hue(self) -> bool {
        matches!(self, Curve::Hue(_) | Curve::StepHue(_))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum InputRow {
    Interpret,
    LogMode,
    Deliver,
    Project,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Control {
    EffectMenu(i64),
    Section(i64, ColorSectionKind),
    SectionMenu(i64, ColorSectionKind),
    Lut(i64, ColorLUTSlot),
    LutStar(i64, ColorLUTSlot),
    Eyedropper(i64),
    Slider(Slider),
    Wheel(Wheel),
    Master(Wheel),
    Channel(Curve, usize),
    Curve(Curve),
    HueKind(i64),
    MaskMode(i64),
    Invert(i64),
    /// "Input color" below the sections: its header, popups and HDR switch.
    InputSection,
    Input(InputRow),
    Conform,
    // The Pro page: layer list, path line, tabs and the tab bodies.
    ListRow(Id),
    ListEye(Id),
    ListBlend(Id),
    ListMix(Id),
    ListAdd,
    ListChip(GraphLUTSlot),
    PathEye,
    PathMore,
    TurnOn,
    StartEmpty,
    StartFromSimple,
    /// The X of the Experimental notice.
    CloseNotice,
    ProTab(usize),
    CurveChip(usize),
    CurveReset,
    StepHueKind,
    QualOn,
    PickColor,
    Matte,
    QualInvert,
    RangeBar(StepRangeKind),
    ShapeChip(usize),
    WindowRemove,
    WindowInvert,
    LutPill,
    LutImport,
    AddEffect,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowStyle {
    Plain,
    Effect,
    Section,
    Group,
    Note,
    /// Pro page: the empty state (label = title, summary = hint), a list row (open = selected, summary = has a LUT), the
    /// list's foot, the Step's path line, a warning band, a caption (lines), an upper-case group head, a form title.
    Empty,
    ListItem,
    ListFoot,
    Path,
    Warning,
    Footnote,
    GroupHead,
    Title,
    /// The closed-once Experimental notice above the Pro empty state (label = its text).
    Notice,
    /// The clip row at the top (label = clip name, summary = what the grade covers).
    File,
}

#[derive(Clone, Debug)]
pub struct Row {
    pub label: Option<String>,
    pub style: RowStyle,
    pub y: f64,
    pub height: f64,
    pub controls: Vec<(Control, CGRect)>,
    pub dim: bool,
    pub summary: Option<String>,
    pub open: bool,
    pub lines: Vec<String>,
    /// Where a plain row's label starts (nil = the Simple grid's label column); a group row's rule above it.
    pub label_x: Option<f64>,
    pub rule: bool,
}

impl Row {
    pub fn new(label: Option<&str>, style: RowStyle, height: f64, controls: Vec<(Control, CGRect)>) -> Row {
        Row {
            label: label.map(str::to_string),
            style,
            y: 0.0,
            height,
            controls,
            dim: false,
            summary: None,
            open: true,
            lines: Vec::new(),
            label_x: None,
            rule: true,
        }
    }

    pub fn plain(label: Option<&str>, height: f64, controls: Vec<(Control, CGRect)>) -> Row {
        Row::new(label, RowStyle::Plain, height, controls)
    }

    pub fn dimmed(mut self, dim: bool) -> Row {
        self.dim = dim;
        self
    }
}

/// The r8 flat drop-down (`.dd`): no well, the title in text-secondary (text-primary for `primary`, and on hover) and a 12 pt
/// chevron right behind it; hover and open get the quiet fill. A title that does not fit is cut Finder-style and comes
/// back whole as the return value (the tooltip).
#[allow(clippy::too_many_arguments)]
pub(crate) fn flat_popup(
    c: &mut Canvas,
    title: &str,
    rect: CGRect,
    hovering: bool,
    open: bool,
    enabled: bool,
    primary: bool,
    max_height: f64,
    font_size: Option<f64>,
    t: &DrawTheme,
) -> Option<String> {
    let h = max_height.min(rect.height);
    let boxed = CGRect::new(rect.min_x(), rect.min_y() + ((rect.height - h) / 2.0).round(), rect.width, h);
    let a = if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
    c.stone_button(boxed, ButtonKind::Quiet, Touch { hovering, pressed: open, disabled: !enabled, focused: false }, t);
    let size = font_size.unwrap_or(f64::from(type_size::BODY));
    let ink = if primary || hovering || open { t.label() } else { t.label2() };
    let chevron = 12.0;
    let pad = f64::from(spacing::MD);
    let text_max = (boxed.width - 2.0 * pad - chevron - 2.0).max(0.0);
    let cut = c.truncated_name(title, size, 0, text_max);
    let text = cut.shown.clone();
    let tw = c.size_of(&text, size, 0).width;
    c.draw_text_in(
        &text,
        CGRect::new(boxed.min_x() + pad, boxed.min_y(), text_max, boxed.height),
        size,
        ink.with_alpha(ink.a * a),
        TextAlign::Left,
        0.0,
        0,
    );
    let cx = boxed.min_x() + pad + tw + 2.0;
    c.draw_icon(
        SQIcon::ChevronDown,
        CGPoint::new(cx, boxed.mid_y() - chevron / 2.0),
        chevron,
        ink.with_alpha(ink.a * a),
        None,
    );
    cut.full
}

/// The Mac `ColorGrid` of the Simple page, in points: the panel inset, the label column (inset + chevron slot), the control
/// column (label 96 + gap), the value column (the 48 wide number + gap), the rows and the section header.
pub struct Mac;

impl Mac {
    pub const INSET: f64 = 12.0;
    pub const LABEL_X: f64 = 28.0;
    pub const CONTROL_X: f64 = 110.0;
    pub const VALUE_WIDTH: f64 = 50.0;
    pub const VALUE_COLUMN: f64 = 63.0;
    /// The number field ends this far before the panel's right inset (redesign R4d: field 50 wide, 23 from the edge).
    pub const VALUE_TRAILING: f64 = 11.0;
    pub const ROW: f64 = 24.0;
    pub const POPUP_ROW: f64 = 28.0;
    /// The hue box in its group stack (measured on the Mac PNG, `window-color-expanded-online`): the "Curve" row is a
    /// default `ColorControlRow` (30 high, `ColorGrid.controlRow`) whose label and popup land where a 28 pt popup row puts
    /// them, the box starts 7 pt below that and 8.5 pt of room follow it; the RGB box keeps 6 / 8.
    pub const HUE_CURVE_TOP: f64 = 7.0;
    pub const HUE_CURVE_BOTTOM: f64 = 8.5;
    pub const SLIDER: f64 = 20.0;
    /// The narrowest slider track (a 240 pt panel would leave 44 pt) and the narrowest label column the slider may squeeze.
    pub const MIN_TRACK: f64 = 56.0;
    pub const MIN_LABEL: f64 = 62.0;
    /// The section header (`Color/GroupHeader`): a 26 high band on the group fill with a hairline at its foot, no gap above.
    pub const SECTION: f64 = sq_uikit::controls_grid::ControlsGrid::HEADER_HEIGHT;
    pub const SECTION_GAP: f64 = 0.0;
    /// The Source LUT / Look LUT rows of the Simple grade (the frame's 24 high rows).
    pub const LUT_ROW: f64 = 24.0;
    pub const ICON: f64 = 24.0;
    pub const CHEVRON_X: f64 = 12.0;
    pub const CHEVRON_GLYPH: f64 = 8.0;
    /// A popup row's popup ends here before the panel's right inset (the star sits in the gap).
    pub const POPUP_TRAILING: f64 = 65.0;
    pub const GROUP: f64 = 22.0;
    pub const RGB_CURVE: f64 = 138.0;
    pub const HUE_CURVE: f64 = 67.0;
    pub const CURVE_TOP: f64 = 6.0;
    pub const CURVE_BOTTOM: f64 = 8.0;
    pub const WHEEL: f64 = 80.0;
    /// The Input color rows sit on the "top" grid: label at the inset, controls from here.
    pub const TOP_CONTROL_X: f64 = 104.0;
    /// The channel dots row: 9 pt dots 10 apart in a 19 pt row, the dots' top 6 pt down.
    pub const DOT: f64 = 9.0;
    pub const DOT_GAP: f64 = 10.0;
    pub const DOT_ROW: f64 = 19.0;
}

/// ControlsGrid numbers the Simple layout starts from (`ControlsGrid.rowHeight`, `controlHeight`, `valueX`, `trailing`).
pub(crate) fn grid_row_height() -> f64 {
    sq_uikit::controls_grid::ControlsGrid::ROW_HEIGHT
}

/// A menu the panel asks the host to show (Swift `onMenu`).
#[derive(Clone, Debug)]
pub struct GradeMenuRequest {
    pub items: Vec<SQMenuItem>,
    /// In panel coordinates (the scroll applied).
    pub anchor: CGRect,
}

/// What the panel asks of the platform's file choosers (Swift `chooseLUTFiles` and friends).
#[derive(Clone, Debug, PartialEq)]
pub enum GradeFileRequest {
    /// Choose File… / Add LUTs to Library…: .cube files; `multiple`; `then` says what the paths are for.
    LutFiles { multiple: bool, then: LutFilesFor },
}

#[derive(Clone, Debug, PartialEq)]
pub enum LutFilesFor {
    /// Choose File… of a Simple LUT popup.
    SetLut(i64, ColorLUTSlot),
    /// Add LUTs to Library… of a Simple LUT popup: the first added LUT is set.
    ImportLuts(i64, ColorLUTSlot),
    /// A Step's LUT.
    StepLut(Id),
}

/// Every action a menu row of the panel can run (Swift closures over the model).
#[derive(Clone, Debug, PartialEq)]
pub enum DrawMenuCommand {
    SetEnabled(i64, ColorSectionKind, bool),
    ResetSection(i64, ColorSectionKind),
    HoldSaturationLegal(i64),
    SetHueKind(i64, HueCurveKind),
    SetStepHueKind(HueCurveKind),
    SetRangeMaskMode(i64, HSLMaskMode),
    SetLut(i64, ColorLUTSlot, Option<LUTChoice>),
    ToggleFavouriteLut(LUTChoice),
    ChooseLutFiles(bool, LutFilesFor),
    InputInterpret(Option<sq_core_model::ColorSpaceID>),
    InputProject(Option<sq_core_model::ColorSpaceID>),
    InputLogMode(LogMode),
    InputDeliver(TargetSpace),
    CopyColor,
    PasteColor,
    AddEffect,
    RemoveEffect(i64),
    GradeAction(super::color_inspector_model::ColorGradeAction),
    GradeWholeSequence,
    UseSimple,
    UsePro,
    SendToPro,
    AutoTone(i64),
    ResetTone(i64),
    ResetSectionOf(i64, ColorSectionKind),
    SetBlend(Id, sq_core_color::StepBlend),
    /// A row of a Step menu (`ColorGraphMenus`): run through its own sink.
    Graph(super::color_graph_menus::GraphMenuCommand),
}

/// The text-measure cache: the layout asks for widths before a canvas exists, the first draw measures what was asked.
#[derive(Default)]
struct MeasureCache {
    known: HashMap<(String, u32, bool), f64>,
    wanted: BTreeSet<(String, u32, bool)>,
}

pub struct ColorGradeDraw {
    pub size: CGSize,
    /// The color wheels' wedge spans (static art, replayed each frame).
    wheel_spans: RefCell<PolygonSpanCache>,
    /// The clip name and the "Applies to ..." line for the file row; None leaves the row out. The host sets it.
    pub file_row: Option<(String, String)>,
    pub(crate) scroll_y: f64,
    /// Popup titles the last draw cut, with their whole text (the tooltip of a long LUT name).
    cut_names: RefCell<Vec<(Control, String)>>,
    /// Menus the panel asked for, oldest first.
    pub menus: Vec<GradeMenuRequest>,
    pub file_requests: Vec<GradeFileRequest>,
    pub(crate) menu_sink: MenuSink<DrawMenuCommand>,
    pub(crate) graph_sink: MenuSink<super::color_graph_menus::GraphMenuCommand>,
    /// What the Step menus' host-only rows ask for (rename, Tidy up, file choosers).
    pub graph_requests: Vec<super::color_graph_menus::GraphMenuHostRequest>,
    /// "Input color" is unfolded (view state; the Mac `inputOpen`, closed at start).
    pub input_open: bool,
    /// The Pro page's tab (0 Primaries ... 5 Effects), the Step hue curve shown.
    pub pro_tab: usize,
    pub(crate) step_hue_kind: HueCurveKind,
    measure: RefCell<MeasureCache>,
    scale: f32,
    pub(crate) list_press: Option<(Id, f64)>,
    pub(crate) list_drag: Option<(Id, usize)>,
    pub(crate) range_drag: Option<(StepRangeKind, Grab)>,
    pub(crate) channels: HashMap<Curve, usize>,
    pub(crate) hue_kinds: HashMap<i64, HueCurveKind>,
    pub(crate) fields: RefCell<HashMap<Slider, ScrubFieldControl>>,
    pub(crate) focused: Option<Slider>,
    pub(crate) hover: Option<Control>,
    pub(crate) pressed: Option<Control>,
    pub(crate) slider_drag: Option<Slider>,
    pub(crate) field_press: Option<Slider>,
    wheel_drag: Option<WheelDrag>,
    curve_drag: Option<(Curve, usize)>,
    counter: ClickCounter,
    last_key: Option<Id>,
}

#[derive(Clone, Copy, Debug)]
struct WheelDrag {
    wheel: Wheel,
    master: bool,
    fine: bool,
    start: ColorWheelValue,
    start_master: f64,
    start_point: (f64, f64),
}

impl Default for ColorGradeDraw {
    fn default() -> Self {
        ColorGradeDraw {
            size: CGSize::new(320.0, 600.0),
            wheel_spans: RefCell::new(PolygonSpanCache::new(16)),
            file_row: None,
            scroll_y: 0.0,
            cut_names: RefCell::default(),
            menus: Vec::new(),
            file_requests: Vec::new(),
            menu_sink: MenuSink::new(),
            graph_sink: MenuSink::new(),
            graph_requests: Vec::new(),
            input_open: false,
            pro_tab: 0,
            step_hue_kind: HueCurveKind::HueVsSat,
            measure: RefCell::new(MeasureCache::default()),
            scale: 1.0,
            list_press: None,
            list_drag: None,
            range_drag: None,
            channels: HashMap::new(),
            hue_kinds: HashMap::new(),
            fields: RefCell::new(HashMap::new()),
            focused: None,
            hover: None,
            pressed: None,
            slider_drag: None,
            field_press: None,
            wheel_drag: None,
            curve_drag: None,
            counter: ClickCounter::new(),
            last_key: None,
        }
    }
}

fn tr(s: &str) -> String {
    SQL10n::string(s)
}

fn box_rect(x: f64, w: f64, h: f64, row_h: f64) -> CGRect {
    CGRect::new(x, ((row_h - h) / 2.0).round(), w.max(0.0), h)
}

impl ColorGradeDraw {
    pub const FIELD_WIDTH: f64 = Mac::VALUE_WIDTH;
    pub const HEADER_HEIGHT: f64 = 28.0;
    pub const PUCK: f64 = 12.0;
    pub const MENU_SIDE: f64 = 22.0;

    pub fn new() -> ColorGradeDraw {
        ColorGradeDraw::default()
    }

    pub fn scroll_y(&self) -> f64 {
        self.scroll_y
    }

    pub fn hover(&self) -> Option<Control> {
        self.hover
    }

    pub fn channel(&self, c: Curve) -> usize {
        self.channels.get(&c).copied().unwrap_or(0)
    }

    pub(crate) fn hue_kind(&self, e: i64) -> HueCurveKind {
        self.hue_kinds.get(&e).copied().unwrap_or(HueCurveKind::HueVsSat)
    }

    fn hue_kind_of(&self, c: Curve) -> HueCurveKind {
        match c {
            Curve::Hue(e) => self.hue_kind(e),
            _ => self.step_hue_kind,
        }
    }

    // MARK: Text measure

    /// The width of `s` at `size` (the atlas measured it on the last frame; before that a rough estimate).
    pub(crate) fn text_width(&self, s: &str, size: f64, bold: bool) -> f64 {
        let key = (tr(s), size.to_bits() as u32 ^ (size.to_bits() >> 32) as u32, bold);
        let mut m = self.measure.borrow_mut();
        if let Some(w) = m.known.get(&key) {
            return *w;
        }
        m.wanted.insert(key.clone());
        key.0.chars().count() as f64 * size * 0.56
    }

    /// Measures what the layout asked for with the frame's canvas.
    fn learn_widths(&self, c: &Canvas) {
        let mut m = self.measure.borrow_mut();
        let wanted: Vec<(String, u32, bool)> = m.wanted.iter().cloned().collect();
        for key in wanted {
            // The size is folded into the key; the common sizes are the two UI sizes.
            for size in [f64::from(type_size::BODY), f64::from(type_size::CAPTION), f64::from(type_size::TITLE)] {
                if key.1 == size.to_bits() as u32 ^ (size.to_bits() >> 32) as u32 {
                    let face = if key.2 { c.semibold() } else { 0 };
                    let w = c.size_of(&key.0, size, face).width.ceil();
                    m.known.insert(key.clone(), w);
                }
            }
        }
        m.wanted.clear();
    }

    // MARK: Layout

    /// The rows of the page the model shows, with `y` set.
    pub fn rows(&self, model: &ColorInspectorModel, steps_shown: bool) -> Vec<Row> {
        let rh = grid_row_height();
        let ch = sq_uikit::controls_grid::ControlsGrid::CONTROL_HEIGHT;
        let x0 = sq_uikit::controls_grid::ControlsGrid::VALUE_X;
        let x1 = (self.size.width - sq_uikit::controls_grid::ControlsGrid::TRAILING).max(x0);
        // The Simple page's own columns (the Mac `ColorGrid`): label 28, controls 124 to the inset, values 56 from the right.
        let mx1 = (self.size.width - Mac::INSET).max(Mac::CONTROL_X);
        let full = box_rect(x0, x1 - x0, ch, rh);
        let mut out: Vec<Row> = Vec::new();
        let mut y = 0.0;
        let mut add = |mut r: Row| {
            r.y = y;
            y += r.height;
            out.push(r);
        };
        if let Some((name, applies)) = &self.file_row {
            let mut file = Row::new(Some(name.as_str()), RowStyle::File, 30.0, Vec::new());
            file.summary = Some(applies.clone());
            add(file);
        }
        if model.shown_grade() == sq_core_color::ActiveGrade::Pro {
            self.pro_rows(model, steps_shown, &mut add);
            self.input_rows(model, &mut add, full);
            return out;
        }
        // Simple rows: 24 high, the slider 20 in the middle; a popup row is 28 with the 22 high popup; the Source / Look LUT rows are 24 with the popup and its star.
        let cap = f64::from(sq_draw::theme::metrics::CAPSULE);
        // A narrow panel (240 pt) moves the slider left so the track keeps `MIN_TRACK`; the labels get what is left of the 110.
        let slider_x = (mx1 - Mac::VALUE_TRAILING - Mac::VALUE_COLUMN - Mac::MIN_TRACK)
            .clamp(Mac::LABEL_X + Mac::MIN_LABEL, Mac::CONTROL_X);
        let slider = box_rect(slider_x, mx1 - slider_x - Mac::VALUE_TRAILING, Mac::SLIDER, Mac::ROW);
        // A narrow panel lets the popup grow toward its star (up to 96 wide) so "Automatic" is not cut to "Autom…".
        let star_gap = mx1 - Mac::ICON - 6.0 - Mac::CONTROL_X;
        let popup_w = (self.size.width - Mac::POPUP_TRAILING - Mac::CONTROL_X).max(star_gap.min(96.0));
        let lut_popup = box_rect(Mac::CONTROL_X, popup_w, cap, Mac::LUT_ROW);
        let lut_star = box_rect(mx1 - Mac::ICON, Mac::ICON, cap, Mac::LUT_ROW);
        let full_popup = box_rect(Mac::CONTROL_X, self.size.width - Mac::INSET - Mac::CONTROL_X, cap, Mac::POPUP_ROW);
        let group = |add: &mut dyn FnMut(Row), title: &str, rule: bool, dim: bool| {
            // The hairline is a pixel row of its own above the 22 pt label band.
            let mut r = Row::new(Some(title), RowStyle::Group, Mac::GROUP + if rule { 1.0 } else { 0.0 }, Vec::new());
            r.dim = dim;
            r.rule = rule;
            add(r);
        };
        let srow = |add: &mut dyn FnMut(Row), label: &str, s: Slider, dim: bool| {
            add(Row::plain(Some(label), Mac::ROW, vec![(Control::Slider(s), slider)]).dimmed(dim));
        };
        let primary_id = model.effects().first().map(|e| e.id);
        let count = model.effects().len();
        for (n, e) in model.effects().iter().enumerate() {
            let id = e.id;
            // One effect is the grade itself (no band); more get a numbered band with their "..." (the Mac effect header).
            if count > 1 {
                add(Row::new(
                    Some(&model.effect_title(id, n as i64 + 1)),
                    RowStyle::Effect,
                    Self::HEADER_HEIGHT,
                    vec![(
                        Control::EffectMenu(id),
                        box_rect(mx1 - Self::MENU_SIDE, Self::MENU_SIDE, ch, Self::HEADER_HEIGHT),
                    )],
                ));
            }
            for kind in ColorSectionText::ORDER {
                let open = !model.is_collapsed(&ColorPanelKey::new(id, kind, None));
                let on = e.is_enabled(kind);
                let hh = Mac::SECTION_GAP + Mac::SECTION;
                let mut hc: Vec<(Control, CGRect)> = Vec::new();
                // Basic's header carries the white balance picker (the Mac eyedropper button).
                // Only while the group is open: a collapsed head shows its summary there, and the picker has nothing to aim at.
                if kind == ColorSectionKind::BasicCorrection && open {
                    hc.push((
                        Control::Eyedropper(id),
                        CGRect::new(
                            mx1 - Mac::ICON,
                            Mac::SECTION_GAP + ((Mac::SECTION - Mac::ICON) / 2.0).round(),
                            Mac::ICON,
                            Mac::ICON,
                        ),
                    ));
                }
                hc.push((Control::Section(id, kind), CGRect::new(0.0, 0.0, self.size.width, hh)));
                let mut r = Row::new(Some(kind.title()), RowStyle::Section, hh, hc);
                r.dim = !on;
                r.summary = Some(ColorSectionText::summary(kind, self.channel(Curve::Rgb(id)) as i64, e));
                r.open = open;
                add(r);
                if !open {
                    continue;
                }
                let dim = !on;
                match kind {
                    ColorSectionKind::BasicCorrection => {
                        add(Row::plain(
                            Some("Source LUT"),
                            Mac::LUT_ROW,
                            vec![
                                (Control::Lut(id, ColorLUTSlot::Input), lut_popup),
                                (Control::LutStar(id, ColorLUTSlot::Input), lut_star),
                            ],
                        )
                        .dimmed(dim));
                        let has_lut = e.input_lut.is_some() && e.input_lut != Some(sq_core_model::LUTRef::Automatic);
                        let primary = Some(id) == primary_id;
                        if !primary && has_lut {
                            srow(
                                &mut add,
                                ColorParam::InputLUTIntensity.title(),
                                Slider::Param(id, ColorParam::InputLUTIntensity),
                                dim,
                            );
                        }
                        for g in ColorParam::layout(kind) {
                            for p in g.1.iter().filter(|p| **p != ColorParam::InputLUTIntensity) {
                                srow(&mut add, p.title(), Slider::Param(id, *p), dim);
                            }
                        }
                        if Some(id) == primary_id {
                            srow(&mut add, "Sharpen", Slider::Sharpen, dim);
                        }
                    }
                    ColorSectionKind::Creative => {
                        add(Row::plain(
                            Some("Look LUT"),
                            Mac::LUT_ROW,
                            vec![
                                (Control::Lut(id, ColorLUTSlot::Look), lut_popup),
                                (Control::LutStar(id, ColorLUTSlot::Look), lut_star),
                            ],
                        )
                        .dimmed(dim));
                        if e.creative.look.is_some() {
                            srow(
                                &mut add,
                                ColorParam::LookIntensity.title(),
                                Slider::Param(id, ColorParam::LookIntensity),
                                dim,
                            );
                        }
                        // Tint Mix only moves the split between the shadow and highlight tints: dimmed while both are neutral.
                        let no_tints = e.creative.shadow_tint.amount == 0.0 && e.creative.highlight_tint.amount == 0.0;
                        for g in ColorParam::layout(kind) {
                            for p in &g.1 {
                                srow(
                                    &mut add,
                                    p.title(),
                                    Slider::Param(id, *p),
                                    dim || (*p == ColorParam::TintBalance && no_tints),
                                );
                            }
                        }
                    }
                    ColorSectionKind::Curves => {
                        let curve = Curve::Rgb(id);
                        group(&mut add, "RGB Curves", false, dim);
                        let n = 4.0 * Mac::DOT + 3.0 * Mac::DOT_GAP;
                        let dx = ((self.size.width - n) / 2.0).round();
                        let dots: Vec<(Control, CGRect)> = (0..4)
                            .map(|i| {
                                (
                                    Control::Channel(curve, i),
                                    CGRect::new(
                                        dx + i as f64 * (Mac::DOT + Mac::DOT_GAP) - Mac::DOT_GAP / 2.0,
                                        0.0,
                                        Mac::DOT + Mac::DOT_GAP,
                                        Mac::DOT_ROW,
                                    ),
                                )
                            })
                            .collect();
                        add(Row::plain(None, Mac::DOT_ROW, dots).dimmed(dim));
                        self.curve_row(curve, dim, &mut add);
                        group(&mut add, "Hue Saturation Curves", true, dim);
                        add(Row::plain(Some("Curve"), Mac::POPUP_ROW, vec![(Control::HueKind(id), full_popup)])
                            .dimmed(dim));
                        self.curve_row(Curve::Hue(id), dim, &mut add);
                    }
                    ColorSectionKind::Wheels => {
                        self.wheels_row(
                            &[
                                Wheel::Slot(id, ColorWheelSlot::Shadows),
                                Wheel::Slot(id, ColorWheelSlot::Midtones),
                                Wheel::Slot(id, ColorWheelSlot::Highlights),
                            ],
                            true,
                            dim,
                            &mut add,
                        );
                        srow(
                            &mut add,
                            ColorParam::WheelsSaturation.title(),
                            Slider::Param(id, ColorParam::WheelsSaturation),
                            dim,
                        );
                    }
                    ColorSectionKind::ZoneBoard => {
                        let wheels: Vec<Wheel> = BoardZone::ALL.iter().map(|z| Wheel::Zone(id, *z)).collect();
                        self.wheels_row(&wheels, true, dim, &mut add);
                        group(&mut add, "Saturation", true, dim);
                        for z in BoardZone::ALL {
                            srow(&mut add, z.title(), Slider::ZoneSat(id, z), dim);
                        }
                    }
                    ColorSectionKind::HslSecondary => {
                        let mode = model.range_mask_mode(id);
                        group(&mut add, "Range", true, dim);
                        add(Row::plain(Some("Mask"), Mac::POPUP_ROW, vec![(Control::MaskMode(id), full_popup)])
                            .dimmed(dim));
                        for p in ColorRangeParam::ALL.iter().filter(|p| p.is_shown(mode) && !p.is_correction()) {
                            srow(&mut add, p.title(), Slider::Range(id, *p), dim);
                        }
                        add(Row::plain(
                            Some("Invert"),
                            Mac::POPUP_ROW,
                            vec![(
                                Control::Invert(id),
                                box_rect(
                                    Mac::CONTROL_X,
                                    self.size.width - Mac::INSET - Mac::CONTROL_X,
                                    Mac::ROW,
                                    Mac::POPUP_ROW,
                                ),
                            )],
                        )
                        .dimmed(dim));
                        group(&mut add, "Correction", true, dim);
                        for p in ColorRangeParam::ALL.iter().filter(|p| p.is_shown(mode) && p.is_correction()) {
                            srow(&mut add, p.title(), Slider::Range(id, *p), dim);
                        }
                    }
                    ColorSectionKind::Vignette => {
                        let mut first = true;
                        for g in ColorParam::layout(kind) {
                            if let Some(title) = g.0 {
                                group(&mut add, title, !first, dim);
                            }
                            first = false;
                            for p in &g.1 {
                                srow(&mut add, p.title(), Slider::Param(id, *p), dim);
                            }
                        }
                    }
                }
            }
        }
        self.input_rows(model, &mut add, full);
        out
    }

    /// A Mac curve box: 6 pt above, 8 below, the inset on both sides (`ColorGrid.rgbCurve` / `hueCurve` high).
    fn curve_row(&self, c: Curve, dim: bool, add: &mut dyn FnMut(Row)) {
        let h = if c.is_hue() { Mac::HUE_CURVE } else { Mac::RGB_CURVE };
        let top = if c.is_hue() { Mac::HUE_CURVE_TOP } else { Mac::CURVE_TOP };
        let bottom = if c.is_hue() { Mac::HUE_CURVE_BOTTOM } else { Mac::CURVE_BOTTOM };
        add(Row::plain(
            None,
            top + h + bottom,
            vec![(Control::Curve(c), CGRect::new(Mac::INSET, top, (self.size.width - 2.0 * Mac::INSET).max(0.0), h))],
        )
        .dimmed(dim));
    }

    /// The Mac wheel row (`wheelRow` / `buildZoneBoard`): cells of 86 x 112 (zone 66 x 92) spread edge to edge, the title at
    /// the cell's top, the disc `cell - 24` wide centered in the 96 (76) pt below the title band, the master slider at its
    /// right.
    fn wheels_row(&self, wheels: &[Wheel], masters: bool, dim: bool, add: &mut dyn FnMut(Row)) {
        let zone = matches!(wheels.first(), Some(Wheel::Zone(..)));
        if !zone && masters {
            self.wheel_blocks_row(wheels, dim, add);
            return;
        }
        let side = if zone { 76.0 } else { Mac::WHEEL };
        let cell_w = side - 10.0;
        let cell_h = side + f64::from(spacing::LG);
        let band = 16.0;
        let d = (cell_w - 14.0 - 10.0).min(side);
        let top = f64::from(spacing::XS);
        // The kit's grid starts 10 pt down and keeps 12 pt between title and disc (the zone row keeps its own).
        let kit = if zone { 0.0 } else { 6.0 };
        let avail = (self.size.width - 2.0 * Mac::INSET).max(0.0);
        let n = wheels.len().max(1) as f64;
        let step = if n > 1.0 { (avail - cell_w) / (n - 1.0) } else { 0.0 };
        let mut controls: Vec<(Control, CGRect)> = Vec::new();
        // The zone row's stack is 8 pt taller than its 92 pt wheels (inset height 100), which centers them 4 pt lower.
        let lift = if zone { f64::from(spacing::SM) } else { 0.0 };
        for (i, w) in wheels.iter().enumerate() {
            let x = Mac::INSET + if n > 1.0 { i as f64 * step } else { (avail - cell_w) / 2.0 };
            let y = top + kit + band + ((cell_h - band - d) / 2.0) + if zone { 0.0 } else { 4.0 };
            controls.push((Control::Wheel(*w), CGRect::new(x, y, d, d)));
            if masters {
                controls.push((Control::Master(*w), CGRect::new(x + d + 10.0, y, 14.0, d)));
            }
        }
        let controls = controls.into_iter().map(|(k, r)| (k, offset_by(&r, 0.0, lift / 2.0))).collect();
        add(Row::plain(None, cell_h + lift + 2.0 * top + if zone { 0.0 } else { 1.0 }, controls).dimmed(dim));
    }

    /// The r8 wheel block (`.col-wheels`: 84 pt disc, title above, master slider under it): the discs share the panel width
    /// minus the inset and 4 pt gaps, so in a 240 pt panel they shrink from 84 to what fits instead of the old 46.
    fn wheel_blocks_row(&self, wheels: &[Wheel], dim: bool, add: &mut dyn FnMut(Row)) {
        let gap = f64::from(spacing::XS);
        let top = f64::from(spacing::MD);
        let n = wheels.len().max(1) as f64;
        let avail = (self.size.width - 2.0 * Mac::INSET).max(0.0);
        let cell_w = ((avail - gap * (n - 1.0)) / n).max(0.0);
        let d = cell_w.min(Self::WHEEL_BLOCK).floor();
        let y = top + Self::WHEEL_TITLE_LEAD;
        let mut controls: Vec<(Control, CGRect)> = Vec::new();
        for (i, w) in wheels.iter().enumerate() {
            let x = Mac::INSET + i as f64 * (cell_w + gap) + ((cell_w - d) / 2.0).floor();
            controls.push((Control::Wheel(*w), CGRect::new(x, y, d, d)));
            controls.push((Control::Master(*w), CGRect::new(x, y + d + 6.0, d, 14.0)));
        }
        add(Row::plain(None, y + d + 6.0 + 14.0 + f64::from(spacing::SM), controls).dimmed(dim));
    }

    /// The wheel's disc size in the Simple wheel block (design draft `wheel(size=84)`).
    pub(crate) const WHEEL_BLOCK: f64 = 84.0;
    /// Title top to disc top in that block: the 16 pt title band and 6 pt of air.
    pub(crate) const WHEEL_TITLE_LEAD: f64 = 22.0;

    pub fn content_height(&self, model: &ColorInspectorModel, steps_shown: bool) -> f64 {
        self.rows(model, steps_shown).last().map_or(0.0, |r| r.y + r.height)
    }

    /// Left edge of the head's own controls (the picker): the title and summary live left of it. The whole-head hit areas
    /// (a Section's or the Input head's) are not controls: counting the Input head's left it no room for its title.
    fn head_controls_left(r: &Row, width: f64) -> f64 {
        r.controls
            .iter()
            .filter(|k| !matches!(k.0, Control::Section(..) | Control::InputSection))
            .map(|k| k.1.min_x())
            .fold(width - Mac::INSET, f64::min)
    }

    pub(crate) fn frame_in(rs: &[Row], c: Control) -> Option<CGRect> {
        for r in rs {
            if let Some(f) = r.controls.iter().find(|f| f.0 == c).map(|f| f.1) {
                return Some(offset_by(&f, 0.0, r.y));
            }
        }
        None
    }

    /// The slider's track and its number: the value column is 56 wide (48 for the number, 8 gap) at the row's right end.
    pub(crate) fn slider_parts(r: CGRect) -> (CGRect, CGRect) {
        let fw = Self::FIELD_WIDTH.min(r.width);
        let field = CGRect::new(r.max_x() - fw, r.min_y(), fw, r.height);
        let track = CGRect::new(r.min_x(), r.min_y(), (r.width - Mac::VALUE_COLUMN).max(0.0), r.height);
        (track, field)
    }

    // MARK: Values

    pub(crate) fn spec(&self, s: Slider) -> SliderSpec {
        let of = |r: (f32, f32), n: f32, d: i64| SliderSpec {
            range: f64::from(r.0)..=f64::from(r.1),
            neutral: f64::from(n),
            decimals: ColorValueText::shown_decimals(r, d),
        };
        match s {
            Slider::Param(_, p) => of(p.range(), p.neutral(), p.decimals()),
            Slider::Range(_, p) => of(p.range(), p.neutral(), p.decimals()),
            Slider::Sharpen => of(SHARPEN_ROW_RANGE, 0.0, 0),
            Slider::ZoneSat(..) => of((0.0, 200.0), 100.0, 0),
            Slider::Step(_, p) => of(p.range(), p.neutral(), p.decimals()),
            Slider::Primary(_, r) => of(r.range(), r.neutral(), 0),
            Slider::StepQual(_, p) => of(p.range(), p.neutral(), 0),
            Slider::Window(_, p) => of(p.range(), p.neutral(), 0),
            Slider::Mix(_) => of((0.0, 100.0), 100.0, 0),
        }
    }

    pub(crate) fn value(&self, m: Option<&ColorInspectorModel>, s: Slider) -> f64 {
        let Some(m) = m else { return self.spec(s).neutral };
        match s {
            Slider::Param(e, p) => f64::from(m.value(e, p)),
            Slider::Range(e, p) => f64::from(m.range_value(e, p)),
            Slider::Sharpen => f64::from(m.sharpen()),
            Slider::ZoneSat(e, z) => f64::from(m.zone_saturation_percent(e, z)),
            Slider::Step(id, p) => f64::from(m.step_value(id, p)),
            Slider::Primary(id, r) => f64::from(m.step_value(id, r.param()) * r.scale()),
            Slider::StepQual(id, p) => f64::from(m.step_qualifier_value(id, p)),
            Slider::Window(id, p) => f64::from(m.step_window_value(id, p)),
            Slider::Mix(id) => f64::from(m.step_value(id, StepParam::Mix)),
        }
    }

    pub(crate) fn set(&self, m: &mut ColorInspectorModel, s: Slider, v: f64) {
        let f = v as f32;
        match s {
            Slider::Param(e, p) => m.set(e, p, f),
            Slider::Range(e, p) => m.set_range(e, p, f),
            Slider::Sharpen => m.set_sharpen(f),
            Slider::ZoneSat(e, z) => m.set_zone_saturation(e, z, f),
            Slider::Step(id, p) => m.set_step(id, p, f),
            Slider::Primary(id, r) => m.set_step(id, r.param(), f / r.scale()),
            Slider::StepQual(id, p) => m.set_step_qualifier(id, p, f),
            Slider::Window(id, p) => m.set_step_window(id, p, f),
            Slider::Mix(id) => m.set_step(id, StepParam::Mix, f),
        }
    }

    /// Wheel state: puck (hue in degrees, amount 0…1) and master (-1…1).
    pub(crate) fn wheel_value(&self, m: Option<&ColorInspectorModel>, w: Wheel) -> (ColorWheelValue, f64) {
        let Some(m) = m else { return (ColorWheelMath::RESET, 0.0) };
        match w {
            Wheel::Slot(e, s) => {
                let v = m.wheel(e, s);
                (ColorWheelValue { hue: f64::from(v.0.hue), amount: f64::from(v.0.amount) }, f64::from(v.1 / 100.0))
            }
            Wheel::Zone(e, z) => {
                let v = m.zone_puck_wheel(e, z);
                (
                    ColorWheelValue { hue: f64::from(v.hue), amount: f64::from(v.amount) },
                    f64::from(m.zone_exposure_slider(e, z)),
                )
            }
            Wheel::Step(id, p) => m.step_wheel(id, p),
        }
    }

    fn set_puck(&self, m: &mut ColorInspectorModel, w: Wheel, v: ColorWheelValue) {
        match w {
            Wheel::Slot(e, s) => m.set_wheel(e, s, v.hue as f32, v.amount as f32),
            Wheel::Zone(e, z) => m.set_zone_puck(e, z, v.hue as f32, v.amount as f32),
            Wheel::Step(id, p) => {
                let master = self.wheel_value(Some(m), w).1;
                m.set_step_wheel(id, p, v, master);
            }
        }
    }

    fn set_master(&self, m: &mut ColorInspectorModel, w: Wheel, v: f64) {
        match w {
            Wheel::Slot(e, s) => m.set_wheel_luma(e, s, (v * 100.0) as f32),
            Wheel::Zone(e, z) => m.set_zone_exposure(e, z, v as f32),
            Wheel::Step(id, p) => {
                let puck = self.wheel_value(Some(m), w).0;
                m.set_step_wheel(id, p, puck, v);
            }
        }
    }

    fn reset_wheel(&self, m: &mut ColorInspectorModel, w: Wheel) {
        match w {
            Wheel::Slot(e, s) => m.reset_wheel(e, s),
            Wheel::Zone(e, z) => m.reset_zone(e, z),
            Wheel::Step(id, p) => m.gesture(|m| m.set_step_wheel(id, p, ColorWheelMath::RESET, 0.0)),
        }
    }

    fn wheel_title(w: Wheel) -> &'static str {
        match w {
            Wheel::Slot(_, s) => s.title(),
            Wheel::Zone(_, z) => z.title(),
            Wheel::Step(_, p) => p.title(),
        }
    }

    pub(crate) fn points(&self, m: Option<&ColorInspectorModel>, c: Curve) -> Vec<CurvePoint> {
        let Some(m) = m else { return RGBCurves::default().master };
        match c {
            Curve::Rgb(e) => Self::channel_points(&m.curves(e), self.channel(c)),
            Curve::Hue(e) => m.hue_curve(e, self.hue_kind(e)),
            Curve::StepRgb(id) => Self::channel_points(&m.step_curves(id), self.channel(c)),
            Curve::StepHue(id) => m.step_hue_curve(id, self.step_hue_kind),
        }
    }

    fn set_points(&self, m: &mut ColorInspectorModel, c: Curve, pts: Vec<CurvePoint>) {
        match c {
            Curve::Rgb(e) => {
                let mut v = m.curves(e);
                Self::write_points(&pts, self.channel(c), &mut v);
                m.set_curves(e, v);
            }
            Curve::Hue(e) => m.set_hue_curve(e, self.hue_kind(e), &pts),
            Curve::StepRgb(id) => {
                let mut v = m.step_curves(id);
                Self::write_points(&pts, self.channel(c), &mut v);
                m.set_step_curves(id, v);
            }
            Curve::StepHue(id) => m.set_step_hue_curve(id, self.step_hue_kind, &pts),
        }
    }

    pub(crate) fn channel_points(c: &RGBCurves, ch: usize) -> Vec<CurvePoint> {
        match ch {
            1 => c.red.clone(),
            2 => c.green.clone(),
            3 => c.blue.clone(),
            _ => c.master.clone(),
        }
    }

    pub(crate) fn write_points(pts: &[CurvePoint], ch: usize, c: &mut RGBCurves) {
        match ch {
            1 => c.red = pts.to_vec(),
            2 => c.green = pts.to_vec(),
            3 => c.blue = pts.to_vec(),
            _ => c.master = pts.to_vec(),
        }
    }

    fn curve_color(&self, t: &DrawTheme, c: Curve) -> Color {
        if c.is_hue() {
            return t.label();
        }
        match self.channel(c) {
            1 => t.red(),
            2 => t.green(),
            3 => t.accent(),
            _ => t.label(),
        }
    }

    /// One scrub field per slider; refilled from the model unless it is in a gesture or being typed into.
    pub(crate) fn field(&self, m: Option<&ColorInspectorModel>, s: Slider) -> ScrubFieldControl {
        let sp = self.spec(s);
        let mut f = self.fields.borrow_mut().remove(&s).unwrap_or_else(|| ScrubFieldControl::new(self.value(m, s)));
        f.range = sp.range.clone();
        f.decimals = sp.decimals;
        f.default_value = Some(sp.neutral);
        f.step = if sp.decimals == 0 { 1.0 } else { 10f64.powi(-(sp.decimals.min(2) as i32)) };
        if !f.is_dragging() && !f.is_editing() {
            f.value = self.value(m, s);
        }
        f
    }

    /// Puts a field taken with `field` back (Swift copied the struct).
    pub(crate) fn put_field(&self, s: Slider, fd: ScrubFieldControl) {
        self.fields.borrow_mut().insert(s, fd);
    }

    fn field_is_editing(&self, m: Option<&ColorInspectorModel>, s: Slider) -> bool {
        let f = self.field(m, s);
        let editing = f.is_editing();
        self.put_field(s, f);
        editing
    }

    /// Turns the field's events into model calls (begin / live / end of one gesture).
    pub(crate) fn apply(&self, host: &mut ColorGradeHost, events: Vec<ScrubEvent>, s: Slider) {
        for e in events {
            match e {
                ScrubEvent::Begin => {
                    if let Some(m) = host.model_mut() {
                        m.emit_gesture_began();
                    }
                }
                ScrubEvent::Live(v) | ScrubEvent::Change(v) => {
                    if let Some(m) = host.model_mut() {
                        self.set(m, s, v);
                    }
                }
                ScrubEvent::End(v) => {
                    if let Some(m) = host.model_mut() {
                        self.set(m, s, v);
                        m.emit_gesture_ended();
                    }
                }
                ScrubEvent::Cancel(v) => {
                    if let Some(m) = host.model_mut() {
                        self.set(m, s, v);
                    }
                    host.pump();
                    host.controller.cancel_gesture(host.session);
                }
            }
            host.pump();
        }
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, host: &ColorGradeController, cx: &mut UiCx) {
        self.scale = c.scale;
        self.learn_widths(c);
        let fs = f64::from(type_size::BODY);
        let size = self.size;
        c.fill(CGRect::new(0.0, 0.0, size.width, size.height), t.panel());
        let Some(model) = host.model() else {
            // No clip to grade: say what is missing instead of an empty panel (the controller's resolution message).
            let (title, hint) = host
                .empty_state()
                .cloned()
                .unwrap_or_else(|| ColorTargetState::empty_state(ColorTargetState::NOTHING_NOTICE));
            let area = CGRect::new(Mac::INSET, 0.0, (size.width - 2.0 * Mac::INSET).max(0.0), size.height);
            c.draw_empty_state(&tr(&title), &tr(&hint), area, 0.0, t);
            return;
        };
        let steps_shown = host.steps_shown();
        self.clamp_scroll(model, steps_shown);
        c.save_gstate();
        c.clip_to(CGRect::new(0.0, 0.0, size.width, size.height));
        c.translate_by(0.0, -self.scroll_y);
        self.cut_names.borrow_mut().clear();
        let rs = self.rows(model, steps_shown);
        for r in rs.iter().filter(|r| r.y + r.height >= self.scroll_y && r.y <= self.scroll_y + size.height) {
            let a: f32 = if r.dim { InspectorTokens::DISABLED_ALPHA } else { 1.0 };
            let label = r.label.as_deref().unwrap_or("");
            match r.style {
                RowStyle::Effect => {
                    c.fill(CGRect::new(0.0, r.y, size.width, r.height), t.ink_fill(0.04));
                    c.draw_text_in(
                        &tr(label),
                        CGRect::new(Mac::INSET, r.y, size.width * 0.7, r.height),
                        fs,
                        t.label().with_alpha(a),
                        TextAlign::Left,
                        0.0,
                        c.semibold(),
                    );
                }
                RowStyle::Section => {
                    // The Mac header: a 4 pt gap, then 25 pt with the chevron, the bold title and the summary at the right.
                    let band = CGRect::new(0.0, r.y + Mac::SECTION_GAP, size.width, Mac::SECTION);
                    // The inspector's group header (`.grp`): the panel fill, a border-group line at the foot, a 9 pt chevron.
                    c.fill(band, t.panel());
                    c.fill(CGRect::new(0.0, band.max_y() - 1.0, size.width, 1.0), t.separator());
                    c.draw_icon(
                        if r.open { SQIcon::ChevronDown } else { SQIcon::ChevronRight },
                        CGPoint::new(Mac::CHEVRON_X, band.mid_y() - 4.5),
                        9.0,
                        t.label3(),
                        None,
                    );
                    // The title keeps its room; the summary gets what is left between the title and the head controls and
                    // is cut with an ellipsis, so nothing on the head ever overlaps another label (narrow panels).
                    let title = tr(label);
                    let title_w = c.size_of(&title, fs, c.semibold()).width;
                    let title_right = Mac::LABEL_X + title_w;
                    let controls_left = Self::head_controls_left(r, size.width);
                    c.draw_text_in(
                        &title,
                        CGRect::new(Mac::LABEL_X, band.min_y(), (controls_left - Mac::LABEL_X).max(0.0), band.height),
                        fs,
                        t.label().with_alpha(a),
                        TextAlign::Left,
                        0.0,
                        c.semibold(),
                    );
                    if let Some(s) = r.summary.as_deref().filter(|s| !s.is_empty() && !r.open) {
                        let room = (controls_left - title_right - Mac::INSET).max(0.0);
                        let text = c.ellipsized(&tr(s), f64::from(type_size::CAPTION), 0, room);
                        c.draw_text_in(
                            &text,
                            CGRect::new(controls_left - room, band.min_y(), room, band.height),
                            f64::from(type_size::CAPTION),
                            t.label3(),
                            TextAlign::Right,
                            0.0,
                            0,
                        );
                    }
                }
                RowStyle::Group => {
                    // ColorGroupLabel: an optional hairline above, the upper-case caption at the inset.
                    if r.rule {
                        c.fill(CGRect::new(0.0, r.y, size.width, 1.0), t.separator().with_alpha(t.separator().a * a));
                    }
                    c.draw_text_in(
                        &tr(label).to_uppercase(),
                        CGRect::new(Mac::INSET, r.y + if r.rule { 0.0 } else { 0.5 }, size.width, r.height),
                        f64::from(type_size::CAPTION),
                        t.label3().with_alpha(a),
                        TextAlign::Left,
                        0.0,
                        c.semibold(),
                    );
                }
                RowStyle::File => {
                    let md = f64::from(spacing::MD);
                    c.draw_icon(SQIcon::Film, CGPoint::new(md, r.y + (r.height - 14.0) / 2.0), 14.0, t.label2(), None);
                    c.draw_text_in(
                        label,
                        CGRect::new(md + 22.0, r.y, size.width, r.height),
                        fs,
                        t.label(),
                        TextAlign::Left,
                        0.0,
                        c.semibold(),
                    );
                    if let Some(applies) = &r.summary {
                        c.draw_text_in(
                            applies,
                            CGRect::new(0.0, r.y, size.width - md, r.height),
                            f64::from(type_size::CAPTION),
                            t.label3(),
                            TextAlign::Right,
                            0.0,
                            0,
                        );
                    }
                    c.fill(CGRect::new(0.0, r.y + r.height - 1.0, size.width, 1.0), t.separator());
                }
                RowStyle::Note => {
                    c.draw_text_in(
                        &tr(label),
                        CGRect::new(sq_uikit::controls_grid::ControlsGrid::LABEL_X, r.y, size.width, r.height),
                        fs,
                        t.label3(),
                        TextAlign::Left,
                        0.0,
                        0,
                    );
                }
                RowStyle::Empty
                | RowStyle::ListItem
                | RowStyle::ListFoot
                | RowStyle::Path
                | RowStyle::Warning
                | RowStyle::Footnote
                | RowStyle::GroupHead
                | RowStyle::Notice
                | RowStyle::Title => self.draw_pro_row(c, t, host, r, a),
                RowStyle::Plain => {
                    if r.label.is_some() {
                        let lx = r.label_x.unwrap_or(Mac::LABEL_X);
                        // The label ends before the row's first control (the slider moves left in a narrow panel).
                        let stop = r.controls.iter().map(|k| k.1.min_x()).fold(Mac::CONTROL_X, f64::min);
                        let room = (stop - lx - Mac::INSET / 2.0).max(0.0);
                        let text = c.ellipsized(&tr(label), fs, 0, room);
                        c.draw_text_in(
                            &text,
                            CGRect::new(lx, r.y, room, r.height),
                            fs,
                            t.label2().with_alpha(a),
                            TextAlign::Left,
                            0.0,
                            0,
                        );
                    }
                }
            }
            for (k, f0) in &r.controls {
                self.draw_control(c, t, host, model, *k, offset_by(f0, 0.0, r.y), !r.dim, cx);
            }
        }
        c.restore_gstate();
    }

    #[allow(clippy::too_many_arguments)]
    fn draw_control(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        host: &ColorGradeController,
        model: &ColorInspectorModel,
        k: Control,
        f: CGRect,
        enabled: bool,
        cx: &mut UiCx,
    ) {
        let hov = self.hover == Some(k);
        let prs = self.pressed == Some(k);
        if self.draw_pro_control(c, t, host, model, k, f, enabled, cx) {
            return;
        }
        let hover_fill =
            |c: &mut Canvas| c.stone_button(f, ButtonKind::Quiet, Touch { hovering: true, ..Touch::default() }, t);
        match k {
            Control::EffectMenu(_) | Control::SectionMenu(..) => {
                if hov {
                    hover_fill(c);
                }
                c.draw_icon(SQIcon::Ellipsis, CGPoint::new(f.mid_x() - 7.0, f.mid_y() - 7.0), 14.0, t.label2(), None);
            }
            Control::Section(..) => {}
            Control::Lut(e, slot) => {
                let title = model.lut_choice(e, slot).map_or("None".to_string(), |c| c.name);
                let name = tr(&title);
                if let Some(full) = flat_popup(c, &name, f, hov, false, enabled, true, f64::MAX, None, t) {
                    self.cut_names.borrow_mut().push((k, full));
                }
            }
            Control::LutStar(e, slot) => {
                let c0 = model.lut_choice(e, slot);
                let on = c0.as_ref().is_some_and(|c| model.is_favourite_lut(c));
                let live = enabled && Self::lut_star_live(model, e, slot);
                if live && hov {
                    hover_fill(c);
                }
                c.draw_icon(
                    if on { SQIcon::StarFilled } else { SQIcon::Star },
                    CGPoint::new(f.mid_x() - 7.0, f.mid_y() - 7.0),
                    14.0,
                    if live { t.label2() } else { t.label3().with_alpha(0.5) },
                    None,
                );
            }
            Control::Eyedropper(_) => {
                let live = enabled && model.sampling_block.is_none() && host.can_pick_screen_color;
                let armed = live && host.eyedropper_armed;
                if armed || (live && prs) {
                    c.stone_button(f, ButtonKind::Quiet, Touch { pressed: true, ..Touch::default() }, t);
                } else if live && hov {
                    hover_fill(c);
                }
                c.draw_icon(
                    SQIcon::Eyedropper,
                    CGPoint::new(f.mid_x() - 7.0, f.mid_y() - 7.0),
                    14.0,
                    if armed {
                        t.accent()
                    } else if live {
                        t.label2()
                    } else {
                        t.label3().with_alpha(0.5)
                    },
                    None,
                );
            }
            Control::Slider(s) => {
                let (track, field) = Self::slider_parts(f);
                let sp = self.spec(s);
                let (lo, hi) = (*sp.range.start(), *sp.range.end());
                let frac = (self.value(Some(model), s) - lo) / (hi - lo).max(1e-9);
                let centred = lo < 0.0 && lo < sp.neutral && sp.neutral < hi;
                let nf = (sp.neutral - lo) / (hi - lo).max(1e-9);
                InspectorDraw::color_slider(
                    c,
                    frac,
                    if centred { Some(nf) } else { None },
                    self.ramp(s),
                    track,
                    enabled,
                    t,
                );
                let mut fd = self.field(Some(model), s);
                fd.is_enabled = enabled;
                fd.value_tint = Some(if enabled {
                    t.label()
                } else {
                    t.label().with_alpha(t.label().a * InspectorTokens::DISABLED_ALPHA)
                });
                fd.hovering = hov;
                fd.draw(c, field, t, self.focused == Some(s), cx);
                self.put_field(s, fd);
            }
            Control::Wheel(w) => {
                let active = enabled && (self.wheel_drag.is_some_and(|d| d.wheel == w && !d.master) || hov);
                self.draw_wheel(c, t, model, w, f, active);
                if !enabled {
                    // Disabled (no Step selected / section off): the disc sinks into the panel ground, the title dims.
                    c.fill_ellipse(f, t.panel_ground().with_alpha(1.0 - InspectorTokens::DISABLED_ALPHA));
                }
            }
            Control::Master(w) => {
                let active = enabled && (self.wheel_drag.is_some_and(|d| d.wheel == w && d.master) || hov);
                self.draw_master(c, t, model, w, f, active);
                if !enabled {
                    c.fill(f.inset_by(-2.0, -2.0), t.panel_ground().with_alpha(1.0 - InspectorTokens::DISABLED_ALPHA));
                }
            }
            Control::Channel(curve, i) => {
                let colors = [t.label().with_alpha(0.9), t.red(), t.green(), t.channel_blue()];
                let dot = CGRect::new(f.mid_x() - Mac::DOT / 2.0, f.min_y() + 6.0, Mac::DOT, Mac::DOT);
                c.fill_ellipse(dot, colors[i].with_alpha(if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA }));
                if self.channel(curve) == i {
                    c.stroke_ellipse(dot.inset_by(-2.5, -2.5), 1.0, t.label());
                }
            }
            Control::Curve(curve) => self.draw_curve(c, t, model, curve, f),
            Control::HueKind(e) => {
                flat_popup(c, &tr(self.hue_kind(e).title()), f, hov, false, enabled, false, f64::MAX, None, t);
            }
            Control::MaskMode(e) => {
                let title = super::color_range_model::mask_mode_title(model.range_mask_mode(e));
                flat_popup(c, &tr(title), f, hov, false, enabled, false, f64::MAX, None, t);
            }
            Control::Invert(e) => {
                let on = model.color_range(e).is_some_and(|r| r.invert);
                InspectorDraw::checkbox(
                    c,
                    if on { CheckState::On } else { CheckState::Off },
                    CGRect::new(f.min_x(), f.mid_y() - 7.0, 14.0, 14.0),
                    hov,
                    prs,
                    enabled,
                    false,
                    t,
                );
                c.draw_text_in(
                    "Correct outside (Inside / Outside)",
                    CGRect::new(f.min_x() + 20.0, f.min_y(), (f.width - 20.0).max(0.0), f.height),
                    f64::from(type_size::BODY),
                    t.label().with_alpha(if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA }),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            Control::InputSection => {}
            Control::Input(r) => {
                flat_popup(c, &tr(&self.input_title(model, r)), f, hov, false, enabled, false, f64::MAX, None, t);
            }
            Control::Conform => {
                InspectorDraw::checkbox(
                    c,
                    if model.hdr_conform() { CheckState::On } else { CheckState::Off },
                    CGRect::new(f.min_x(), f.mid_y() - 7.0, 14.0, 14.0),
                    hov,
                    prs,
                    enabled,
                    false,
                    t,
                );
                c.draw_text_in(
                    "Convert HDR automatically",
                    CGRect::new(f.min_x() + 20.0, f.min_y(), (f.width - 20.0).max(0.0), f.height),
                    f64::from(type_size::BODY),
                    t.label().with_alpha(if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA }),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            _ => {}
        }
    }

    /// Distance from the Mac wheel view's top (where the title is drawn) to the disc: 20 with the master below, else 33 (the
    /// Simple cell centers its smaller disc).
    fn title_lead(w: Wheel) -> f64 {
        match w {
            // The kit (`#wheels` in color.html): 10 pt padding, the 11 pt title, 8 pt of air, then the 96 pt disc.
            Wheel::Step(..) => 26.0,
            Wheel::Zone(..) => 33.0, // 16 title band + the disc centered in the rest of the 76 pt cell
            Wheel::Slot(..) => Self::WHEEL_TITLE_LEAD,
        }
    }

    /// ColorWheelControl.draw: field disc, hue wedges fading to the center, crosshair, puck; the title above.
    fn draw_wheel(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        model: &ColorInspectorModel,
        w: Wheel,
        disc: CGRect,
        active: bool,
    ) {
        c.draw_text_in(
            &tr(Self::wheel_title(w)),
            CGRect::new(disc.min_x() - 10.0, disc.min_y() - Self::title_lead(w), disc.width + 20.0, 14.0),
            f64::from(type_size::BODY),
            t.label2(),
            TextAlign::Center,
            0.0,
            0,
        );
        let ground = Color::new(Self::WHEEL_CENTER.0, Self::WHEEL_CENTER.1, Self::WHEEL_CENTER.2, 1.0);
        c.fill_ellipse(disc, ground);
        let r = disc.width / 2.0;
        // The 144 wedges rasterize to thousands of row spans: built once per disc size, replayed (round 6 profile).
        c.fill_polygons(
            || Self::wedges(r),
            CGPoint::new(disc.min_x(), disc.min_y()),
            r.to_bits(),
            &mut self.wheel_spans.borrow_mut(),
        );
        c.stroke_ellipse(disc.inset_by(0.5, 0.5), 1.0, t.field_edge());
        // The kit's knob: a light 12 pt dot with a hairline and a soft drop (the accent ring stays for the active wheel).
        let pr = self.puck_rect(Some(model), w, disc);
        c.fill_ellipse(pr.inset_by(-0.5, 0.5), t.on_picture_shadow());
        c.fill_ellipse(pr, t.label());
        c.stroke_ellipse(
            pr,
            if active { 1.5 } else { 0.5 },
            if active { t.accent() } else { Color::new(0.0, 0.0, 0.0, 0.6) },
        );
    }

    /// The puck's frame on `disc` (content coordinates).
    pub(crate) fn puck_rect(&self, m: Option<&ColorInspectorModel>, w: Wheel, disc: CGRect) -> CGRect {
        let o = ColorWheelMath::offset(self.wheel_value(m, w).0, disc.width / 2.0);
        let pc = CGPoint::new(disc.mid_x() + o.0, disc.mid_y() - o.1);
        CGRect::new(pc.x - Self::PUCK / 2.0, pc.y - Self::PUCK / 2.0, Self::PUCK, Self::PUCK)
    }

    /// The kit's wheel (`.wheel` in color.html): a conic gradient of six muted hues that starts at 3 o'clock and runs
    /// clockwise, a `#2a2a2d` radial fade (solid to 0.42 of the radius, gone at the rim) and a 10 pt dark ring at the
    /// rim (`inset 0 0 0 10px rgba(0,0,0,.35)` on a 96 pt disc). The fade is the wedge's alpha over the disc's
    /// `WHEEL_CENTER` fill (the same color), so one translucent wedge per ring and sector gives the kit's pixel. One ring
    /// per 0.45 pt of radius keeps neighbouring rings under 3 percent apart; the wedges are opaque (the fade is
    /// pre-blended over the ground) and overlap by a pixel, because translucent pixel-center spans doubled or dropped
    /// coverage along every edge and left the wheel dull and speckled; the spans are built once per size by
    /// `PolygonSpanCache`, so nothing is allocated per frame. Relative to the disc's top-left.
    pub fn wedges(r: f64) -> Vec<(Vec<CGPoint>, Color)> {
        let bands = ((r * 2.2).round() as i64).max(12);
        let max_steps = 72_i64;
        let ctr = CGPoint::new(r, r);
        let ring = (Self::WHEEL_RING / 48.0).min(1.0);
        let mut out: Vec<(Vec<CGPoint>, Color)> = Vec::with_capacity((bands * max_steps * 2 / 3).max(0) as usize);
        for b in 0..bands {
            let r0 = r * b as f64 / bands as f64;
            let r1 = r * (b + 1) as f64 / bands as f64;
            let t = (b as f64 + 0.5) / bands as f64;
            // The fade's opacity at this radius (a circle gradient is sized to the farthest corner, 1.414 R).
            let fade = (1.0 - (t - 0.3 * 2f64.sqrt()) / ((0.72 - 0.3) * 2f64.sqrt())).clamp(0.0, 1.0);
            let alpha = 1.0 - fade;
            let dark = if t > 1.0 - ring { 0.65 } else { 1.0 };
            let steps = 24_i64.max((((max_steps as f64 * t).ceil() / 4.0) as i64) * 4);
            // A whole pixel of overlap: the next ring and the next wedge are drawn later and cover it, so the
            // pixel-center span fill leaves no gap (the dots) and no double coverage (the moire of translucent wedges).
            let grow_r = 0.6;
            for i in 0..steps {
                let a0 = i as f64 / steps as f64 * 2.0 * PI;
                let a1 = (i + 1) as f64 / steps as f64 * 2.0 * PI + 0.6 / r1.max(1.0);
                // Clockwise from 3 o'clock, the way CSS `conic-gradient(from 90deg)` runs.
                let pos = (1.0 - ((i as f64 + 0.5) / steps as f64)).rem_euclid(1.0);
                let rgb = Self::wheel_hue(pos);
                let p = |a: f64, rr: f64| CGPoint::new(ctr.x + rr * a.cos(), ctr.y - rr * a.sin());
                let r1 = if b + 1 == bands { r1 } else { r1 + grow_r };
                // The kit's pixel: the hue over the ground at `alpha`, the rim ring darkening that composite.
                let mix = |h: f32, g: f32| ((f64::from(g) + (f64::from(h) - f64::from(g)) * alpha) * dark) as f32;
                let g = Self::WHEEL_CENTER;
                out.push((
                    vec![p(a0, r0), p(a0, r1), p(a1, r1), p(a1, r0)],
                    Color::new(mix(rgb.0, g.0), mix(rgb.1, g.1), mix(rgb.2, g.2), 1.0),
                ));
            }
        }
        out
    }

    /// The disc's ground and the fade's color, `#2a2a2d`.
    pub const WHEEL_CENTER: (f32, f32, f32) = (42.0 / 255.0, 42.0 / 255.0, 45.0 / 255.0);
    /// The dark rim ring's width at the kit's 48 pt radius.
    pub const WHEEL_RING: f64 = 10.0;

    /// The kit's conic stops at `pos` (0 to 1 clockwise from 3 o'clock): `#d04a4a #d0c04a #4ad06a #4ac4d0 #4a5ad0 #c04ad0`.
    fn wheel_hue(pos: f64) -> (f32, f32, f32) {
        const STOPS: [(f32, f32, f32); 7] = [
            (208.0, 74.0, 74.0),
            (208.0, 192.0, 74.0),
            (74.0, 208.0, 106.0),
            (74.0, 196.0, 208.0),
            (74.0, 90.0, 208.0),
            (192.0, 74.0, 208.0),
            (208.0, 74.0, 74.0),
        ];
        let x = pos.rem_euclid(1.0) * 6.0;
        let i = (x.floor() as usize).min(5);
        let f = (x - i as f64) as f32;
        let (a, b) = (STOPS[i], STOPS[i + 1]);
        ((a.0 + (b.0 - a.0) * f) / 255.0, (a.1 + (b.1 - a.1) * f) / 255.0, (a.2 + (b.2 - a.2) * f) / 255.0)
    }

    /// The version 9 slider below the disc: a 3 pt track with the accent fill from the center, a 4 x 14 bar thumb.
    fn draw_master(
        &self,
        c: &mut Canvas,
        t: &DrawTheme,
        model: &ColorInspectorModel,
        w: Wheel,
        r: CGRect,
        _active: bool,
    ) {
        let master = self.wheel_value(Some(model), w).1;
        if r.height > r.width {
            // ColorWheelControl.drawSlider: a 4 pt field track, center tick, 8 pt knob.
            let track = CGRect::new(r.mid_x() - 2.0, r.min_y(), 4.0, r.height);
            c.stone_field(track, 2.0, false, Touch::default(), t);
            c.fill(CGRect::new(r.min_x() + 1.0, r.mid_y() - 0.5, r.width - 2.0, 1.0), t.label3());
            let ky = r.min_y() + ColorWheelMath::y_for_master(master, r.height);
            c.stone_slider_knob(r.mid_x(), ky, false, Touch::default(), t);
            return;
        }
        let th = 3.0;
        let y = r.mid_y().round();
        let kx = r.min_x() + ColorWheelMath::x_for_master(master, r.width);
        let track = CGRect::new(r.min_x(), y - th / 2.0, r.width, th);
        c.stone_slider_track(track, Some((r.mid_x().min(kx), r.mid_x().max(kx))), Touch::default(), t);
        c.stone_slider_knob(kx, y, true, Touch::default(), t);
    }

    /// The plot inside a curve box: the Mac editor insets its bounds by 6 pt on every side.
    pub(crate) fn curve_plot(f: CGRect) -> CGRect {
        f.inset_by(6.0, 6.0)
    }

    /// ColorCurveEditor.draw: field, quarter grid, the diagonal (RGB) or middle line (hue), the curve and its points.
    fn draw_curve(&self, c: &mut Canvas, t: &DrawTheme, model: &ColorInspectorModel, curve: Curve, boxed: CGRect) {
        let f = Self::curve_plot(boxed);
        c.stone_field(f, f64::from(sq_uikit::redesign_tokens::radius::FIELD), false, Touch::default(), t);
        if curve.is_hue() && self.hue_kind_of(curve).is_hue_keyed() {
            // The Mac's hue strip: a smooth 6 pt ribbon along the plot's bottom edge.
            let n = ((f.width / 2.0) as i64).max(36);
            for i in 0..n {
                let rgb = Self::hsb(i as f64 / n as f64, 0.9, 0.95);
                c.fill(
                    CGRect::new(
                        f.min_x() + f.width * i as f64 / n as f64,
                        f.max_y() - 6.0,
                        f.width / n as f64 + 0.5,
                        6.0,
                    ),
                    Color::new(rgb.0, rgb.1, rgb.2, 1.0),
                );
            }
        }
        for i in 1..4 {
            let x = f.min_x() + f.width * f64::from(i) / 4.0;
            let y = f.min_y() + f.height * f64::from(i) / 4.0;
            c.stroke_line(CGPoint::new(x, f.min_y()), CGPoint::new(x, f.max_y()), 0.5, t.field_edge());
            c.stroke_line(CGPoint::new(f.min_x(), y), CGPoint::new(f.max_x(), y), 0.5, t.field_edge());
        }
        if curve.is_hue() {
            c.stroke_line(CGPoint::new(f.min_x(), f.mid_y()), CGPoint::new(f.max_x(), f.mid_y()), 0.5, t.field_edge());
        } else {
            c.stroke_line(CGPoint::new(f.min_x(), f.max_y()), CGPoint::new(f.max_x(), f.min_y()), 0.5, t.field_edge());
        }
        let pts = self.points(Some(model), curve);
        let samples = sq_core_model::curve_math::sample(&pts, ((f.width / 2.0) as usize).max(16));
        let last = samples.len().saturating_sub(1).max(1) as f64;
        let line: Vec<CGPoint> = samples
            .iter()
            .enumerate()
            .map(|(i, v)| {
                CGPoint::new(f.min_x() + f.width * i as f64 / last, f.max_y() - f.height * f64::from(v.clamp(0.0, 1.0)))
            })
            .collect();
        c.save_gstate();
        c.clip_to(f);
        c.stroke_polyline(&line, 1.5, self.curve_color(t, curve));
        c.restore_gstate();
        for (i, p) in pts.iter().enumerate() {
            let q = CGPoint::new(f.min_x() + f64::from(p.x) * f.width, f.max_y() - f64::from(p.y) * f.height);
            let dot = CGRect::new(q.x - 3.5, q.y - 3.5, 7.0, 7.0);
            let dragging = self.curve_drag == Some((curve, i));
            c.fill_ellipse(dot, if dragging { t.accent() } else { t.label() });
        }
    }

    /// HSB to RGB (the wheel backdrop's wedge colors).
    pub fn hsb(h: f64, s: f64, v: f64) -> (f32, f32, f32) {
        let i = ((h * 6.0).floor() as i64) % 6;
        let f = h * 6.0 - (h * 6.0).floor();
        let p = v * (1.0 - s);
        let q = v * (1.0 - f * s);
        let u = v * (1.0 - (1.0 - f) * s);
        let (r, g, b) = match i {
            0 => (v, u, p),
            1 => (q, v, p),
            2 => (p, v, u),
            3 => (p, q, v),
            4 => (u, p, v),
            _ => (v, p, q),
        };
        (r as f32, g as f32, b as f32)
    }

    // MARK: Pointer

    pub(crate) fn control_at(&self, model: &ColorInspectorModel, steps_shown: bool, p: CGPoint) -> Option<Control> {
        let q = CGPoint::new(p.x, p.y + self.scroll_y);
        for r in self.rows(model, steps_shown).iter().filter(|r| q.y >= r.y && q.y < r.y + r.height) {
            for (k, f) in &r.controls {
                let hit = offset_by(f, 0.0, r.y);
                let wide = match k {
                    Control::Slider(_)
                    | Control::Lut(..)
                    | Control::HueKind(_)
                    | Control::MaskMode(_)
                    | Control::Input(_)
                    | Control::StepHueKind => CGRect::new(hit.min_x(), r.y, hit.width, r.height),
                    _ => hit,
                };
                if wide.contains(q) {
                    return Some(*k);
                }
            }
            if r.style == RowStyle::Section {
                return None;
            }
        }
        None
    }

    fn frame_of(&self, model: &ColorInspectorModel, steps_shown: bool, c: Control) -> Option<CGRect> {
        Self::frame_in(&self.rows(model, steps_shown), c)
    }

    pub fn mouse_moved(&mut self, host: &mut ColorGradeHost, cx: &mut UiCx, p: Option<CGPoint>) {
        if let Some(p) = p {
            let cursor = self.cursor_at(&*host.controller, p);
            cx.hover.request(cursor);
        }
        if self.slider_drag.is_some()
            || self.field_press.is_some()
            || self.wheel_drag.is_some()
            || self.curve_drag.is_some()
        {
            return;
        }
        let steps_shown = host.controller.steps_shown();
        self.hover = match (host.model(), p) {
            (Some(m), Some(p)) => self.control_at(m, steps_shown, p),
            _ => None,
        };
    }

    /// The pointer shape at `p` (view points), the Mac cursor rects: the open hand on a wheel's puck and a curve's points
    /// (the closed hand while dragging them), the crosshair over a curve, side arrows on a master slider and a number field
    /// (the I-beam while it is typed into); nil = the arrow.
    pub fn cursor_at(&self, host: &ColorGradeController, p: CGPoint) -> Option<DrawCursor> {
        let m = host.model()?;
        let steps_shown = host.steps_shown();
        if self.curve_drag.is_some() || self.wheel_drag.is_some_and(|d| !d.master) {
            return Some(DrawCursor::ClosedHand);
        }
        if let Some(d) = self.wheel_drag.filter(|d| d.master) {
            let tall = self.frame_of(m, steps_shown, Control::Master(d.wheel)).is_some_and(|f| f.height > f.width);
            return Some(if tall { DrawCursor::ResizeUpDown } else { DrawCursor::ResizeLeftRight });
        }
        if let Some(s) = self.field_press {
            return Some(if self.field_is_editing(Some(m), s) {
                DrawCursor::IBeam
            } else {
                DrawCursor::ResizeLeftRight
            });
        }
        let k = self.control_at(m, steps_shown, p)?;
        let f = self.frame_of(m, steps_shown, k)?;
        let q = CGPoint::new(p.x, p.y + self.scroll_y);
        match k {
            Control::Wheel(w) => self.puck_rect(Some(m), w, f).contains(q).then_some(DrawCursor::OpenHand),
            Control::Master(w) => {
                let tall = self.frame_of(m, steps_shown, Control::Master(w)).is_some_and(|f| f.height > f.width);
                Some(if tall { DrawCursor::ResizeUpDown } else { DrawCursor::ResizeLeftRight })
            }
            Control::Curve(curve) => {
                let pl = Self::curve_plot(f);
                let hit = CurveEditing::hit(
                    &self.points(Some(m), curve),
                    q.x - pl.min_x(),
                    q.y - pl.min_y(),
                    CGSize::new(pl.width, pl.height),
                    CurveEditing::HIT_RADIUS,
                );
                Some(if hit.is_some() { DrawCursor::OpenHand } else { DrawCursor::Crosshair })
            }
            Control::Slider(s) => {
                if !Self::slider_parts(f).1.contains(q) {
                    return None;
                }
                Some(if self.field_is_editing(Some(m), s) { DrawCursor::IBeam } else { DrawCursor::ResizeLeftRight })
            }
            _ => None,
        }
    }

    pub fn scroll(&mut self, host: &ColorGradeController, dy: f64) {
        self.scroll_y -= dy;
        if let Some(m) = host.model() {
            self.clamp_scroll(m, host.steps_shown());
        }
    }

    fn clamp_scroll(&mut self, model: &ColorInspectorModel, steps_shown: bool) {
        let max = (self.content_height(model, steps_shown) - self.size.height).max(0.0);
        self.scroll_y = self.scroll_y.clamp(0.0, max);
    }

    pub fn mouse_down(
        &mut self,
        host: &mut ColorGradeHost,
        cx: &mut UiCx,
        p: CGPoint,
        modifiers: InputModifiers,
        click_count: Option<i64>,
    ) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        self.mouse_down_inner(host, cx, p, modifiers, n);
        let cursor = self.cursor_at(&*host.controller, p);
        cx.hover.request(cursor);
    }

    fn mouse_down_inner(
        &mut self,
        host: &mut ColorGradeHost,
        cx: &mut UiCx,
        p: CGPoint,
        modifiers: InputModifiers,
        n: i64,
    ) {
        // A press while a drag is still open means its release never arrived (lost with the pointer capture, or taken
        // by another window): end that gesture first, or the controller keeps it open and skips every later reload.
        if self.slider_drag.take().is_some() | self.wheel_drag.take().is_some() | self.curve_drag.take().is_some() {
            if let Some(m) = host.model_mut() {
                m.emit_gesture_ended();
            }
            host.pump();
        }
        let steps_shown = host.controller.steps_shown();
        let k = host.model().and_then(|m| self.control_at(m, steps_shown, p));
        if let Some(s) = self.focused
            && k != Some(Control::Slider(s))
        {
            self.resign_focus(host, cx);
        }
        let Some(k) = k else { return };
        if host.model().is_none() {
            return;
        }
        let q = CGPoint::new(p.x, p.y + self.scroll_y);
        self.pressed = Some(k);
        let frame = host.model().and_then(|m| self.frame_of(m, steps_shown, k));
        if modifiers.contains(InputModifiers::SECONDARY) {
            match k {
                Control::Section(e, kind) => {
                    let anchor = host
                        .model()
                        .and_then(|m| self.frame_of(m, steps_shown, Control::SectionMenu(e, kind)))
                        .unwrap_or_default();
                    self.open_section_menu(host, e, kind, anchor);
                }
                Control::Slider(s) => self.reset_slider(host, s),
                Control::Wheel(w) | Control::Master(w) => {
                    if let Some(m) = host.model_mut() {
                        self.reset_wheel(m, w);
                    }
                    host.pump();
                }
                Control::ListRow(_) | Control::PathMore => self.pro_secondary(host, k),
                _ => {}
            }
            self.pressed = None;
            return;
        }
        match k {
            Control::LutStar(e, slot) => {
                if let Some(m) = host.model_mut()
                    && Self::lut_star_live(m, e, slot)
                    && let Some(c) = m.lut_choice(e, slot)
                {
                    m.toggle_favourite_lut(&c);
                }
                host.pump();
                self.pressed = None;
            }
            Control::EffectMenu(_)
            | Control::SectionMenu(..)
            | Control::Lut(..)
            | Control::HueKind(_)
            | Control::MaskMode(_)
            | Control::Input(_) => {
                self.open_menu(host, k);
                self.pressed = None;
            }
            Control::InputSection => {
                self.input_open = !self.input_open;
                self.pressed = None;
            }
            Control::Section(e, kind) => {
                if let Some(m) = host.model_mut() {
                    let key = ColorPanelKey::new(e, kind, None);
                    let on = !m.is_collapsed(&key);
                    m.set_collapsed(key, on);
                }
                self.pressed = None;
            }
            Control::Eyedropper(_) | Control::Invert(_) | Control::Conform => {}
            Control::Channel(curve, i) => {
                self.channels.insert(curve, i);
                self.pressed = None;
            }
            Control::Slider(s) => {
                let Some(f) = frame else { return };
                let (track, field) = Self::slider_parts(f);
                if q.x >= field.min_x() {
                    let mut fd = self.field(host.model(), s);
                    let events = fd.mouse_down(q.x as f32, n);
                    self.apply(host, events, s);
                    self.put_field(s, fd);
                    self.field_press = Some(s);
                    self.focused = Some(s);
                } else if n >= 2 {
                    self.reset_slider(host, s);
                } else {
                    self.slider_drag = Some(s);
                    if let Some(m) = host.model_mut() {
                        m.emit_gesture_began();
                    }
                    host.pump();
                    self.set_from_slider(host, s, q.x, track);
                }
            }
            Control::Wheel(w) | Control::Master(w) => {
                if n >= 2 {
                    if let Some(m) = host.model_mut() {
                        self.reset_wheel(m, w);
                    }
                    host.pump();
                    self.pressed = None;
                    return;
                }
                let Some(f) = frame else { return };
                let is_master = matches!(k, Control::Master(_));
                let v = self.wheel_value(host.model(), w);
                let fine = modifiers.contains(InputModifiers::OPTION);
                let local = if is_master { (q.x - f.min_x(), 0.0) } else { (q.x - f.mid_x(), f.mid_y() - q.y) };
                self.wheel_drag = Some(WheelDrag {
                    wheel: w,
                    master: is_master,
                    fine,
                    start: v.0,
                    start_master: v.1,
                    start_point: local,
                });
                if let Some(m) = host.model_mut() {
                    m.emit_gesture_began();
                }
                host.pump();
                self.drag_wheel(host, q, modifiers);
            }
            Control::Curve(curve) => {
                let Some(f) = frame else { return };
                let pts = self.points(host.model(), curve);
                let pl = Self::curve_plot(f);
                let lx = q.x - pl.min_x();
                let ly = q.y - pl.min_y();
                let size = CGSize::new(pl.width, pl.height);
                if let Some(i) = CurveEditing::hit(&pts, lx, ly, size, CurveEditing::HIT_RADIUS) {
                    if n >= 2 || modifiers.contains(InputModifiers::OPTION) {
                        let removed = CurveEditing::remove(&pts, i);
                        if let Some(m) = host.model_mut() {
                            m.gesture(|m| self.set_points(m, curve, removed));
                        }
                        host.pump();
                        return;
                    }
                    if let Some(m) = host.model_mut() {
                        m.emit_gesture_began();
                    }
                    host.pump();
                    self.curve_drag = Some((curve, i));
                } else {
                    if let Some(m) = host.model_mut() {
                        m.emit_gesture_began();
                    }
                    host.pump();
                    let (added, index) = CurveEditing::add(
                        &pts,
                        (lx / pl.width.max(1.0)) as f32,
                        (1.0 - ly / pl.height.max(1.0)) as f32,
                    );
                    if let Some(m) = host.model_mut() {
                        self.set_points(m, curve, added);
                    }
                    host.pump();
                    self.curve_drag = Some((curve, index));
                }
            }
            _ => self.pro_mouse_down(host, cx, k, q, modifiers, n),
        }
    }

    pub fn mouse_dragged(&mut self, host: &mut ColorGradeHost, cx: &mut UiCx, p: CGPoint, modifiers: InputModifiers) {
        let q = CGPoint::new(p.x, p.y + self.scroll_y);
        let steps_shown = host.controller.steps_shown();
        if let Some(s) = self.slider_drag {
            let frame = host.model().and_then(|m| self.frame_of(m, steps_shown, Control::Slider(s)));
            if let Some(f) = frame {
                self.set_from_slider(host, s, q.x, Self::slider_parts(f).0);
            }
        } else if let Some(s) = self.field_press {
            let mut fd = self.field(host.model(), s);
            let events = fd.mouse_dragged(q.x as f32, modifiers, self.scale, cx);
            self.apply(host, events, s);
            self.put_field(s, fd);
        } else if self.pro_mouse_dragged(host, q) {
        } else if self.wheel_drag.is_some() {
            self.drag_wheel(host, q, modifiers);
        } else if let Some((curve, index)) = self.curve_drag {
            let frame = host.model().and_then(|m| self.frame_of(m, steps_shown, Control::Curve(curve)));
            if let Some(f) = frame {
                let pl = Self::curve_plot(f);
                let x = ((q.x - pl.min_x()) / pl.width.max(1.0)) as f32;
                let y = (1.0 - (q.y - pl.min_y()) / pl.height.max(1.0)) as f32;
                let moved = CurveEditing::move_point(&self.points(host.model(), curve), index, x, y);
                if let Some(m) = host.model_mut() {
                    self.set_points(m, curve, moved);
                }
                host.pump();
            }
        }
        let cursor = self.cursor_at(&*host.controller, p);
        cx.hover.request(cursor);
    }

    fn drag_wheel(&mut self, host: &mut ColorGradeHost, q: CGPoint, modifiers: InputModifiers) {
        let Some(mut d) = self.wheel_drag else { return };
        let steps_shown = host.controller.steps_shown();
        let k = if d.master { Control::Master(d.wheel) } else { Control::Wheel(d.wheel) };
        let Some(f) = host.model().and_then(|m| self.frame_of(m, steps_shown, k)) else { return };
        let fine = modifiers.contains(InputModifiers::OPTION);
        let current = self.wheel_value(host.model(), d.wheel);
        if d.master && f.height > f.width {
            // The Mac's vertical master beside the disc.
            let y = q.y - f.min_y();
            if fine != d.fine {
                d.fine = fine;
                d.start_master = current.1;
                d.start_point = (y, 0.0);
                self.wheel_drag = Some(d);
            }
            let h = f.height;
            let m = if fine {
                ColorWheelMath::master_for_y(
                    ColorWheelMath::y_for_master(d.start_master, h)
                        + (y - d.start_point.0) * ColorWheelMath::FINE_FACTOR,
                    h,
                )
            } else {
                ColorWheelMath::master_for_y(y, h)
            };
            if let Some(model) = host.model_mut() {
                self.set_master(model, d.wheel, m);
            }
        } else if d.master {
            let x = q.x - f.min_x();
            if fine != d.fine {
                // Re-anchor so toggling Option does not jump the thumb.
                d.fine = fine;
                d.start_master = current.1;
                d.start_point = (x, 0.0);
                self.wheel_drag = Some(d);
            }
            let w = f.width;
            let m = if fine {
                ColorWheelMath::master_for_x(
                    ColorWheelMath::x_for_master(d.start_master, w)
                        + (x - d.start_point.0) * ColorWheelMath::FINE_FACTOR,
                    w,
                )
            } else {
                ColorWheelMath::master_for_x(x, w)
            };
            if let Some(model) = host.model_mut() {
                self.set_master(model, d.wheel, m);
            }
        } else {
            let pt = (q.x - f.mid_x(), f.mid_y() - q.y);
            if fine != d.fine {
                d.fine = fine;
                d.start = current.0;
                d.start_point = pt;
                self.wheel_drag = Some(d);
            }
            let v = ColorWheelMath::drag(d.start, d.start_point, pt, f.width / 2.0, fine);
            if let Some(model) = host.model_mut() {
                self.set_puck(model, d.wheel, v);
            }
        }
        host.pump();
    }

    pub fn mouse_up(&mut self, host: &mut ColorGradeHost, cx: &mut UiCx, p: CGPoint) {
        self.mouse_up_inner(host, cx, p);
        self.pressed = None;
        self.mouse_moved(host, cx, Some(p));
    }

    fn mouse_up_inner(&mut self, host: &mut ColorGradeHost, cx: &mut UiCx, p: CGPoint) {
        if self.pro_mouse_up(host) {
            return;
        }
        if self.slider_drag.take().is_some() || self.wheel_drag.take().is_some() || self.curve_drag.take().is_some() {
            if let Some(m) = host.model_mut() {
                m.emit_gesture_ended();
            }
            host.pump();
            return;
        }
        if let Some(s) = self.field_press {
            let mut fd = self.field(host.model(), s);
            let events = fd.mouse_up(cx);
            self.apply(host, events, s);
            self.put_field(s, fd);
            self.field_press = None;
            return;
        }
        let steps_shown = host.controller.steps_shown();
        let Some(k) = self.pressed else { return };
        if host.model().and_then(|m| self.control_at(m, steps_shown, p)) != Some(k) {
            return;
        }
        match k {
            Control::Eyedropper(e) => {
                if let Some(m) = host.model_mut()
                    && m.sampling_block.is_none()
                {
                    m.emit_pick_white_balance(e);
                }
                host.pump();
            }
            Control::Invert(e) => {
                if let Some(m) = host.model_mut() {
                    let on = m.color_range(e).is_some_and(|r| r.invert);
                    m.set_range_invert(e, !on);
                }
                host.pump();
            }
            Control::Conform => {
                if let Some(m) = host.model_mut() {
                    let on = m.hdr_conform();
                    m.set_hdr_conform(!on);
                }
                host.pump();
            }
            _ => self.pro_clicked(host, k),
        }
    }

    pub(crate) fn reset_slider(&mut self, host: &mut ColorGradeHost, s: Slider) {
        let neutral = self.spec(s).neutral;
        let Some(m) = host.model_mut() else { return };
        match s {
            Slider::Param(e, p) => m.reset_parameter(e, p),
            Slider::Range(e, p) => m.reset_range_parameter(e, p),
            Slider::Step(id, p) => m.gesture(|m| m.set_step(id, p, p.neutral())),
            Slider::Primary(id, r) => m.gesture(|m| m.reset_step_value(id, r.param())),
            Slider::StepQual(id, p) => m.gesture(|m| m.reset_step_qualifier_parameter(id, p)),
            Slider::Window(id, p) => m.gesture(|m| m.reset_step_window_parameter(id, p)),
            Slider::Mix(_) => m.gesture(|m| self.set(m, s, 100.0)),
            Slider::Sharpen | Slider::ZoneSat(..) => m.gesture(|m| self.set(m, s, neutral)),
        }
        host.pump();
    }

    fn set_from_slider(&self, host: &mut ColorGradeHost, s: Slider, x: f64, track: CGRect) {
        let sp = self.spec(s);
        let raw =
            *sp.range.start() + InspectorDraw::color_slider_fraction(x, track) * (*sp.range.end() - *sp.range.start());
        let k = 10f64.powi(sp.decimals as i32);
        if let Some(m) = host.model_mut() {
            self.set(m, s, (raw * k).round() / k);
        }
        host.pump();
    }

    /// Keys for the focused value field (typing, arrows, Enter, Esc); false when nothing is focused.
    pub fn key(&mut self, host: &mut ColorGradeHost, cx: &mut UiCx, k: InputKey, modifiers: InputModifiers) -> bool {
        if k == InputKey::Escape
            && (self.wheel_drag.is_some() || self.curve_drag.is_some() || self.slider_drag.is_some())
            && host.model().is_some()
        {
            self.wheel_drag = None;
            self.curve_drag = None;
            self.slider_drag = None;
            host.controller.cancel_gesture(host.session);
            return true;
        }
        let Some(s) = self.focused else { return false };
        let mut fd = self.field(host.model(), s);
        if k == InputKey::Character('\t') {
            let events = fd.resign_focus(cx);
            self.apply(host, events, s);
            self.put_field(s, fd);
            self.focused = None;
            return true;
        }
        let (events, used) = fd.key_used(k, modifiers, cx.now, cx);
        let ended = !fd.is_editing() && matches!(k, InputKey::Enter | InputKey::Escape);
        self.apply(host, events, s);
        self.put_field(s, fd);
        // Enter or Esc ends the typing and the field lets go of the keyboard (as in Effect Controls); other keys go on.
        if ended {
            self.focused = None;
        }
        used
    }

    pub fn resign_focus(&mut self, host: &mut ColorGradeHost, cx: &mut UiCx) {
        let Some(s) = self.focused else { return };
        let mut fd = self.field(host.model(), s);
        let events = fd.resign_focus(cx);
        self.apply(host, events, s);
        self.put_field(s, fd);
        self.focused = None;
    }

    /// Per frame: ends arrow / wheel step bursts (one undo step each); forgets fields of a switched clip.
    pub fn tick(&mut self, host: &mut ColorGradeHost, now: f64) {
        let keys: Vec<Slider> = self.fields.borrow().keys().copied().collect();
        for s in keys {
            let Some(mut fd) = self.fields.borrow_mut().remove(&s) else { continue };
            let events = fd.tick(now);
            self.apply(host, events, s);
            self.put_field(s, fd);
        }
        let key = host.controller.key();
        if self.last_key != key {
            self.last_key = key;
            self.fields.borrow_mut().clear();
            self.focused = None;
            self.scroll_y = 0.0;
        }
    }

    /// The controls inside the viewport for assistive technology: a stable key, a label, whether it is a slider, and its
    /// rect in the panel's points (scroll applied). Rust-only: the Swift draw UI exposes no nodes.
    pub fn a11y_controls(&self, model: &ColorInspectorModel, steps_shown: bool) -> Vec<(String, String, bool, CGRect)> {
        let mut out = Vec::new();
        for r in self.rows(model, steps_shown) {
            for (k, f) in &r.controls {
                let rect = offset_by(f, 0.0, r.y - self.scroll_y);
                if rect.y + rect.height <= 0.0 || rect.y >= self.size.height || rect.width <= 0.0 || rect.height <= 0.0
                {
                    continue;
                }
                let row = r.label.clone().filter(|l| !l.is_empty());
                let label = match k {
                    Control::ProTab(i) => Self::PRO_TAB_TITLES.get(*i).map(|t| tr(t)),
                    Control::Channel(_, i) => {
                        Some(format!("{} {}", row.clone().unwrap_or_else(|| tr("Channel")), i + 1))
                    }
                    _ => row.clone(),
                }
                .unwrap_or_else(|| humanize(&format!("{k:?}")));
                out.push((format!("{k:?}"), label, matches!(k, Control::Slider(_)), rect));
            }
        }
        out
    }

    /// The star acts only on a LUT file: Automatic, None and the built-in looks have nothing to favorite.
    pub(crate) fn lut_star_live(m: &ColorInspectorModel, e: i64, slot: ColorLUTSlot) -> bool {
        m.lut_choice(e, slot).is_some_and(|c| c.file_path().is_some())
    }

    /// The star's tooltip: its job, or why it is dimmed.
    pub(crate) fn lut_star_tip(m: &ColorInspectorModel, e: i64, slot: ColorLUTSlot) -> String {
        if Self::lut_star_live(m, e, slot) {
            tr("Favorite LUT")
        } else {
            tr("Pick a LUT file to favorite it. Automatic, None and built-in looks cannot be starred.")
        }
    }

    pub fn help_at(&self, host: &ColorGradeController, p: CGPoint) -> Option<String> {
        let m = host.model()?;
        let steps_shown = host.steps_shown();
        match self.control_at(m, steps_shown, p)? {
            Control::Eyedropper(_) => Some(m.sampling_block.clone().unwrap_or_else(|| {
                tr("White balance picker: click a neutral gray or white area in the Program monitor")
            })),
            Control::HueKind(e) | Control::Curve(Curve::Hue(e)) => Some(tr(self.hue_kind(e).explanation())),
            Control::Lut(e, s) => {
                let whole =
                    self.cut_names.borrow().iter().find(|(k, _)| *k == Control::Lut(e, s)).map(|(_, n)| n.clone());
                match (whole, m.lut_mismatch(e, s)) {
                    (Some(n), Some(w)) => Some(format!("{n}\n{w}")),
                    (n, w) => n.or(w),
                }
            }
            Control::LutStar(e, s) => Some(Self::lut_star_tip(m, e, s)),
            k => self.pro_help(host, k).or_else(|| self.input_help(k).map(tr)),
        }
    }

    // MARK: Menus

    /// Queues a menu row's action.
    pub(crate) fn row(&self, title: &str, c: DrawMenuCommand) -> SQMenuItem {
        let sink = self.menu_sink.clone();
        let mut i = SQMenuItem::new(title);
        i.action = Some(Rc::new(move || sink.push(c.clone())));
        i
    }

    fn open_menu(&mut self, host: &mut ColorGradeHost, k: Control) {
        let steps_shown = host.controller.steps_shown();
        let Some(m) = host.model() else { return };
        let Some(f) = self.frame_of(m, steps_shown, k) else { return };
        let anchor = offset_by(&f, 0.0, -self.scroll_y);
        let items = match k {
            Control::EffectMenu(e) => self.effect_menu(m, e),
            Control::SectionMenu(e, kind) => {
                let items = self.section_menu(m, e, kind);
                self.menus.push(GradeMenuRequest { items, anchor: offset_by(&f, 0.0, -self.scroll_y) });
                return;
            }
            Control::Lut(e, slot) => self.lut_menu(m, e, slot),
            Control::HueKind(e) => HueCurveKind::ALL
                .iter()
                .map(|kind| {
                    let mut i =
                        self.row(kind.title(), DrawMenuCommand::SetHueKind(e, *kind)).with_help(kind.explanation());
                    i.is_checked = self.hue_kind(e) == *kind;
                    i
                })
                .collect(),
            Control::MaskMode(e) => [HSLMaskMode::Ranges, HSLMaskMode::Volume]
                .iter()
                .map(|mode| {
                    let title = super::color_range_model::mask_mode_title(*mode);
                    let mut i = self.row(title, DrawMenuCommand::SetRangeMaskMode(e, *mode));
                    i.is_checked = m.range_mask_mode(e) == *mode;
                    i
                })
                .collect(),
            Control::Input(r) => self.input_menu(m, r),
            _ => return,
        };
        self.menus.push(GradeMenuRequest { items, anchor });
    }

    /// The section's own menu: on / off, reset, and Hold Saturation Legal for the curves (showSectionMenu).
    pub fn section_menu(&self, m: &ColorInspectorModel, effect: i64, kind: ColorSectionKind) -> Vec<SQMenuItem> {
        let Some(e) = m.effects().iter().find(|e| e.id == effect) else { return Vec::new() };
        let on = e.is_enabled(kind);
        let name = tr(kind.title());
        let mut items = vec![
            self.row(
                &SQL10n::format(if on { "Turn %@ Off" } else { "Turn %@ On" }, &[&name]),
                DrawMenuCommand::SetEnabled(effect, kind, !on),
            ),
            self.row(&SQL10n::format("Reset %@", &[&name]), DrawMenuCommand::ResetSection(effect, kind)),
        ];
        if kind == ColorSectionKind::Curves {
            items.push(self.row("Hold Saturation Legal", DrawMenuCommand::HoldSaturationLegal(effect)));
        }
        items
    }

    fn open_section_menu(&mut self, host: &mut ColorGradeHost, effect: i64, kind: ColorSectionKind, anchor: CGRect) {
        let Some(m) = host.model() else { return };
        let items = self.section_menu(m, effect, kind);
        self.menus.push(GradeMenuRequest { items, anchor: offset_by(&anchor, 0.0, -self.scroll_y) });
    }

    /// The Color tab's "..." menu (the strip hosts the button): layout, grade copy and paste, and the Simple page's actions.
    pub fn panel_menu_items(
        &self,
        host: &ColorGradeController,
        session: &EditorSession,
        clipboard: &ColorClipboard,
    ) -> Vec<SQMenuItem> {
        host.more_menu_items(session, clipboard, self.simple_action_items(host.model()))
    }

    /// What the panel menu adds for the Simple grade of a clip (simpleActionItems).
    pub fn simple_action_items(&self, m: Option<&ColorInspectorModel>) -> Vec<SQMenuItem> {
        let Some(m) = m else { return Vec::new() };
        let Some(e) = m.effects().first() else { return Vec::new() };
        let id = e.id;
        let mut items = vec![self.row("Add Color Effect", DrawMenuCommand::AddEffect)];
        if m.effect_range_labels.contains_key(&id) {
            items.push(self.row(
                "Set Range to In/Out",
                DrawMenuCommand::GradeAction(super::color_inspector_model::ColorGradeAction::SetRangeToInOut(id)),
            ));
            items.push(self.row(
                "Grade Whole Clip",
                DrawMenuCommand::GradeAction(super::color_inspector_model::ColorGradeAction::WholeClip(id)),
            ));
        }
        let mut auto = self.row("Auto Tone", DrawMenuCommand::AutoTone(id));
        auto.is_enabled = m.auto_tone_block(id).is_none();
        items.push(auto);
        items.push(self.row("Reset Tone", DrawMenuCommand::ResetTone(id)));
        let mut resets = SQMenuItem::new("Reset Section");
        resets.submenu = Some(
            m.section_resets(id)
                .into_iter()
                .map(|r| {
                    let mut i = self.row(&r.1, DrawMenuCommand::ResetSectionOf(id, r.0));
                    i.is_enabled = r.2;
                    i
                })
                .collect(),
        );
        items.push(resets);
        let mut sections = SQMenuItem::new("Sections");
        sections.submenu = Some(
            ColorSectionText::ORDER
                .iter()
                .map(|kind| {
                    let on = e.is_enabled(*kind);
                    let mut i = self.row(kind.title(), DrawMenuCommand::SetEnabled(id, *kind, !on));
                    i.is_checked = on;
                    i
                })
                .collect(),
        );
        items.push(sections);
        items
    }

    /// The effect header's "..." (moreActionsPressed): grade copy and links, ranges, the Pro switch, tone and resets.
    fn effect_menu(&self, m: &ColorInspectorModel, effect: i64) -> Vec<SQMenuItem> {
        use super::color_inspector_model::ColorGradeAction as A;
        let mut copy = self.row("Copy Grade", DrawMenuCommand::CopyColor);
        copy.shortcut = sq_uikit::key_binding_text::KeyBindingText::command_hint_here('c');
        let mut paste = self.row("Paste Grade", DrawMenuCommand::PasteColor);
        paste.shortcut = sq_uikit::key_binding_text::KeyBindingText::command_hint_here('v');
        let mut items = vec![
            copy,
            paste,
            self.row("Add Color Effect", DrawMenuCommand::AddEffect),
            SQMenuItem::separator(),
            self.row("Link Grade to Selected Clips", DrawMenuCommand::GradeAction(A::LinkSelected)),
            self.row("Link All Clips of This Source", DrawMenuCommand::GradeAction(A::LinkSource)),
        ];
        if m.linked_clip_count > 1 {
            items.push(self.row("Unlink Grade", DrawMenuCommand::GradeAction(A::Unlink)));
        }
        items.push(self.row("Grade Whole Sequence", DrawMenuCommand::GradeWholeSequence));
        items.push(self.row("Add Range Grade", DrawMenuCommand::GradeAction(A::AddRange)));
        if m.effect_range_labels.contains_key(&effect) {
            items.push(self.row("Set Range to In/Out", DrawMenuCommand::GradeAction(A::SetRangeToInOut(effect))));
            items.push(self.row("Grade Whole Clip", DrawMenuCommand::GradeAction(A::WholeClip(effect))));
        }
        items.push(SQMenuItem::separator());
        if m.shown_grade() == sq_core_color::ActiveGrade::Pro {
            items.push(self.row("Use Simple Grade", DrawMenuCommand::UseSimple));
        } else {
            items.push(self.row("Use Pro Grade (Color Graph)", DrawMenuCommand::UsePro));
            let mut send = self.row("Send Simple Values to Pro", DrawMenuCommand::SendToPro);
            send.is_enabled = m.can_send_to_pro();
            items.push(send);
        }
        items.push(SQMenuItem::separator());
        let mut auto = self.row("Auto Tone", DrawMenuCommand::AutoTone(effect));
        auto.is_enabled = m.auto_tone_block(effect).is_none();
        items.push(auto);
        items.push(self.row("Reset Tone", DrawMenuCommand::ResetTone(effect)));
        for r in m.section_resets(effect) {
            let mut i = self.row(&r.1, DrawMenuCommand::ResetSectionOf(effect, r.0));
            i.is_enabled = r.2;
            items.push(i);
        }
        if m.effects().first().map(|e| e.id) != Some(effect) {
            items.push(SQMenuItem::separator());
            items.push(self.row("Remove Effect", DrawMenuCommand::RemoveEffect(effect)));
        }
        items
    }

    /// The LUT popup in the board order (refreshLUTPopup): Automatic and Embedded (Input LUT of the first effect), None,
    /// Favorites, Library (the other library LUTs, the current file, up to 10 look choices), the two file actions, and the
    /// favorite toggle (the Mac star next to the popup).
    fn lut_menu(&self, m: &ColorInspectorModel, effect: i64, slot: ColorLUTSlot) -> Vec<SQMenuItem> {
        let current = m.lut_choice(effect, slot);
        let is_primary = m.effects().first().map(|e| e.id) == Some(effect);
        let item = |title: &str, c: Option<LUTChoice>| -> SQMenuItem {
            let mut i = self.row(title, DrawMenuCommand::SetLut(effect, slot, c.clone()));
            i.is_checked = c == current;
            i
        };
        let mut items: Vec<SQMenuItem> = Vec::new();
        if slot == ColorLUTSlot::Input && is_primary {
            items.push(item("Automatic", Some(LUTChoice::automatic())));
            if let Some(n) = m.embedded_lut_name() {
                items.push(item(&format!("Embedded: {n}"), Some(LUTChoice::embedded(n))));
            } else if let Some(c) = current.as_ref().filter(|c| c.id == "embedded") {
                items.push(item(&c.name, Some(c.clone())));
            }
        }
        items.push(item("None", None));
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let favourites: Vec<_> = m.library_luts().iter().filter(|e| e.is_favourite).collect();
        let others: Vec<_> = m.library_luts().iter().filter(|e| !e.is_favourite).collect();
        if !favourites.is_empty() {
            items.push(SQMenuItem::separator());
            items.push(SQMenuItem::header("Favorites"));
            for e in &favourites {
                let c = LUTChoice::file(&e.path);
                items.push(item(e.name(), Some(c.clone())));
                seen.insert(c.id);
            }
        }
        let mut library: Vec<SQMenuItem> = Vec::new();
        for e in &others {
            let c = LUTChoice::file(&e.path);
            library.push(item(e.name(), Some(c.clone())));
            seen.insert(c.id);
        }
        if let Some(c) = current.as_ref().filter(|c| c.file_path().is_some() && !seen.contains(&c.id)) {
            library.push(item(&c.name, Some(c.clone())));
            seen.insert(c.id.clone());
        }
        let mut extra = 0;
        for c in m.look_choices() {
            if !seen.contains(&c.id) && extra < 10 {
                library.push(item(&c.name, Some(c.clone())));
                seen.insert(c.id);
                extra += 1;
            }
        }
        if !library.is_empty() {
            items.push(SQMenuItem::separator());
            items.push(SQMenuItem::header("Library"));
            items.extend(library);
        }
        items.push(SQMenuItem::separator());
        items.push(
            self.row(
                "Add LUTs to Library…",
                DrawMenuCommand::ChooseLutFiles(true, LutFilesFor::ImportLuts(effect, slot)),
            ),
        );
        items.push(self.row("Choose File…", DrawMenuCommand::ChooseLutFiles(false, LutFilesFor::SetLut(effect, slot))));
        if let Some(c) = current
            && let Some(path) = c.file_path()
            && m.library_luts().iter().any(|e| e.path == path)
        {
            let starred = m.is_favourite_lut(&c);
            items.push(self.row(
                if starred { "Remove from Favorites" } else { "Add to Favorites" },
                DrawMenuCommand::ToggleFavouriteLut(c.clone()),
            ));
        }
        items
    }

    /// Runs one queued row of a menu on the model; file choosers come back as `file_requests`.
    pub fn run_menu_command(&mut self, host: &mut ColorGradeHost, cmd: DrawMenuCommand) {
        use DrawMenuCommand as C;
        match cmd {
            C::ChooseLutFiles(multiple, then) => {
                self.file_requests.push(GradeFileRequest::LutFiles { multiple, then });
                return;
            }
            C::SetHueKind(e, kind) => {
                self.hue_kinds.insert(e, kind);
                return;
            }
            C::SetStepHueKind(kind) => {
                self.step_hue_kind = kind;
                return;
            }
            C::CopyColor => {
                host.controller.copy_grade(host.session, host.clipboard);
                return;
            }
            C::PasteColor => {
                if !host.controller.paste_grade(host.session, host.clipboard, false) {
                    host.controller.run_menu_command(
                        host.session,
                        host.clipboard,
                        super::color_grade_controller::ColorMenuCommand::PasteGradeOrBeep,
                    );
                }
                return;
            }
            C::GradeWholeSequence => {
                host.controller.pick_whole_sequence(host.session);
                return;
            }
            C::GradeAction(a) => {
                match host.controller.target_clip(host.session).map(|c| c.id) {
                    Some(id) => host.controller.grade_action(host.session, a, id),
                    None => host.controller.run_menu_command(
                        host.session,
                        host.clipboard,
                        super::color_grade_controller::ColorMenuCommand::Extra,
                    ),
                }
                return;
            }
            _ => {}
        }
        let Some(m) = host.model_mut() else { return };
        match cmd {
            C::SetEnabled(e, kind, on) => m.set_enabled(e, kind, on),
            C::ResetSection(e, kind) | C::ResetSectionOf(e, kind) => m.reset_section(e, kind),
            C::HoldSaturationLegal(e) => m.hold_saturation_legal(e),
            C::SetRangeMaskMode(e, mode) => m.set_range_mask_mode(e, mode),
            C::SetLut(e, slot, c) => m.set_lut(e, slot, c.as_ref()),
            C::ToggleFavouriteLut(c) => m.toggle_favourite_lut(&c),
            C::InputInterpret(s) => m.gesture(|m| m.set_source_override(s)),
            C::InputProject(s) => m.set_project_input(s),
            C::InputLogMode(l) => m.set_log_mode(l),
            C::InputDeliver(t) => m.set_target_space(t),
            C::AddEffect => m.add_effect(),
            C::RemoveEffect(e) => m.remove_effect(e),
            C::UseSimple => m.set_active_grade(sq_core_color::ActiveGrade::Simple),
            C::UsePro => m.set_active_grade(sq_core_color::ActiveGrade::Pro),
            C::SendToPro => m.send_to_pro(),
            C::AutoTone(e) => m.emit_auto_tone(e),
            C::ResetTone(e) => m.reset_tone(e),
            C::SetBlend(id, b) => m.set_step_blend(id, b),
            C::Graph(g) => {
                let menus = super::color_graph_menus::ColorGraphMenus::new(MenuSink::new());
                if let Some(req) = menus.apply(m, g) {
                    self.graph_requests.push(req);
                }
            }
            C::ChooseLutFiles(..)
            | C::SetHueKind(..)
            | C::SetStepHueKind(_)
            | C::CopyColor
            | C::PasteColor
            | C::GradeWholeSequence
            | C::GradeAction(_) => {}
        }
        host.pump();
    }

    /// Drains the commands the menu rows queued.
    pub fn take_menu_commands(&self) -> Vec<DrawMenuCommand> {
        self.menu_sink.drain()
    }

    /// Called with the paths of a file chooser the panel asked for.
    pub fn files_chosen(&mut self, host: &mut ColorGradeHost, then: LutFilesFor, paths: Vec<String>) {
        let Some(m) = host.model_mut() else { return };
        match then {
            LutFilesFor::SetLut(e, slot) => {
                if let Some(p) = paths.first() {
                    m.set_lut(e, slot, Some(&LUTChoice::file(p)));
                }
            }
            LutFilesFor::ImportLuts(..) => {
                // The host copies the files into its LUT store and answers with `ImportLuts` events; the first added LUT
                // is set through `LutFilesFor::SetLut` once the store returns it.
                if !paths.is_empty() {
                    m.import_luts(&paths);
                }
            }
            LutFilesFor::StepLut(id) => {
                if let Some(p) = paths.first() {
                    m.set_step_lut(id, Some(&LUTChoice::file(p)));
                }
            }
        }
        host.pump();
    }
}

/// A slider's range, neutral value and decimals.
#[derive(Clone, Debug)]
pub struct SliderSpec {
    pub range: std::ops::RangeInclusive<f64>,
    pub neutral: f64,
    pub decimals: i64,
}

/// "ListAdd(…)" -> "List add": the variant name of a control as a label when its row has none.
fn humanize(debug: &str) -> String {
    let name = debug.split('(').next().unwrap_or(debug);
    let mut out = String::new();
    for (i, c) in name.chars().enumerate() {
        if c.is_uppercase() && i > 0 {
            out.push(' ');
            out.extend(c.to_lowercase());
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn model() -> ColorInspectorModel {
        ColorInspectorModel::new(Box::new(SequentialIds::default()))
    }

    fn sized() -> ColorGradeDraw {
        let mut d = ColorGradeDraw::new();
        d.size = CGSize::new(320.0, 600.0);
        d
    }

    #[test]
    fn rows_stack_without_gaps_and_start_with_the_section_headers() {
        let d = sized();
        let m = model();
        let rows = d.rows(&m, false);
        let mut y = 0.0;
        for r in &rows {
            assert_eq!(r.y, y);
            y += r.height;
        }
        assert_eq!(d.content_height(&m, false), y);
        let sections: Vec<&str> =
            rows.iter().filter(|r| r.style == RowStyle::Section).filter_map(|r| r.label.as_deref()).collect();
        assert_eq!(sections.first().copied(), Some("Basic"));
        assert_eq!(sections.last().copied(), Some("Input color"));
        assert_eq!(sections.len(), 8);
        // One effect: no band; Basic and Creative start open, so their sliders are there.
        assert!(rows.iter().all(|r| r.style != RowStyle::Effect));
        assert!(rows.iter().any(|r| r.controls.iter().any(|c| c.0 == Control::Slider(Slider::Sharpen))));
        assert!(rows.iter().any(|r| r.label.as_deref() == Some("Source LUT")));
    }

    #[test]
    fn a_second_effect_gets_a_numbered_band() {
        let d = sized();
        let mut m = model();
        m.add_effect();
        let rows = d.rows(&m, false);
        let bands: Vec<&str> =
            rows.iter().filter(|r| r.style == RowStyle::Effect).filter_map(|r| r.label.as_deref()).collect();
        assert_eq!(bands, vec!["Color", "Color 2"]);
        // Only the primary effect has the Sharpen row.
        let sharpen =
            rows.iter().filter(|r| r.controls.iter().any(|c| c.0 == Control::Slider(Slider::Sharpen))).count();
        assert_eq!(sharpen, 1);
    }

    #[test]
    fn folding_a_section_drops_its_rows() {
        let d = sized();
        let mut m = model();
        let id = m.effects()[0].id;
        let open = d.rows(&m, false).len();
        m.set_collapsed(ColorPanelKey::new(id, ColorSectionKind::BasicCorrection, None), true);
        assert!(d.rows(&m, false).len() < open);
        // The input color rows come with their header.
        let mut d2 = sized();
        let closed = d2.rows(&m, false).len();
        d2.input_open = true;
        assert_eq!(d2.rows(&m, false).len(), closed + 5);
    }

    #[test]
    fn the_slider_specs_follow_the_parameters() {
        let d = sized();
        let sp = d.spec(Slider::Param(1, ColorParam::Exposure));
        assert_eq!((*sp.range.start(), *sp.range.end(), sp.neutral, sp.decimals), (-5.0, 5.0, 0.0, 2));
        let sp = d.spec(Slider::Param(1, ColorParam::Contrast));
        assert_eq!((sp.decimals, *sp.range.end()), (0, 100.0));
        let sp = d.spec(Slider::Primary(Id::NIL, StepPrimaryRow::Saturation));
        assert_eq!((sp.neutral, *sp.range.end()), (50.0, 200.0));
        let sp = d.spec(Slider::Mix(Id::NIL));
        assert_eq!(sp.neutral, 100.0);
    }

    #[test]
    fn values_read_and_write_through_the_model() {
        let d = sized();
        let mut m = model();
        d.set(&mut m, Slider::Param(1, ColorParam::Temperature), 12.0);
        assert_eq!(d.value(Some(&m), Slider::Param(1, ColorParam::Temperature)), 12.0);
        d.set(&mut m, Slider::ZoneSat(1, BoardZone::Shadows), 150.0);
        assert!((d.value(Some(&m), Slider::ZoneSat(1, BoardZone::Shadows)) - 150.0).abs() < 1e-4);
        d.set(&mut m, Slider::Sharpen, 500.0);
        assert_eq!(d.value(Some(&m), Slider::Sharpen), 100.0);
        assert_eq!(d.value(None, Slider::Mix(Id::NIL)), 100.0);
    }

    #[test]
    fn wheels_write_hue_and_amount() {
        let d = sized();
        let mut m = model();
        let w = Wheel::Slot(1, ColorWheelSlot::Shadows);
        d.set_puck(&mut m, w, ColorWheelValue { hue: 120.0, amount: 0.5 });
        let v = d.wheel_value(Some(&m), w);
        assert!((v.0.hue - 120.0).abs() < 1e-4 && (v.0.amount - 0.5).abs() < 1e-6);
        d.set_master(&mut m, w, 0.5);
        assert!((d.wheel_value(Some(&m), w).1 - 0.5).abs() < 1e-6);
        d.reset_wheel(&mut m, w);
        assert_eq!(d.wheel_value(Some(&m), w), (ColorWheelMath::RESET, 0.0));
    }

    #[test]
    fn hsb_matches_the_primary_colors() {
        assert_eq!(ColorGradeDraw::hsb(0.0, 1.0, 1.0), (1.0, 0.0, 0.0));
        let g = ColorGradeDraw::hsb(1.0 / 3.0, 1.0, 1.0);
        assert!(g.0 < 1e-6 && g.1 == 1.0 && g.2 < 1e-6);
        assert_eq!(ColorGradeDraw::hsb(0.5, 0.0, 0.4), (0.4, 0.4, 0.4));
    }

    #[test]
    fn the_wedges_fade_to_the_center() {
        let w = ColorGradeDraw::wedges(40.0);
        assert!(w.iter().all(|(p, _)| p.len() == 4));
        // Opaque and pre-blended: the first ring is the ground, the last shows the hues.
        assert!(w.iter().all(|(_, c)| c.a == 1.0));
        let ground = ColorGradeDraw::WHEEL_CENTER;
        let from_ground = |c: &Color| (c.r - ground.0).abs() + (c.g - ground.1).abs() + (c.b - ground.2).abs();
        let first = w.first().map_or(1.0, |x| from_ground(&x.1));
        let last = w.last().map_or(0.0, |x| from_ground(&x.1));
        assert!(
            first < 0.01 && last > 0.3,
            "the kit's fade is solid #2a2a2d in the middle and shows the hues at the rim"
        );
        assert_eq!(ColorGradeDraw::wedges(40.0).len(), w.len());
    }

    #[test]
    fn slider_parts_split_track_and_number() {
        let (track, field) = ColorGradeDraw::slider_parts(CGRect::new(124.0, 2.0, 184.0, 20.0));
        assert_eq!(field.width, Mac::VALUE_WIDTH);
        assert_eq!(field.max_x(), 308.0);
        assert_eq!(track.width, 184.0 - Mac::VALUE_COLUMN);
    }

    /// Every control of a row sits inside the row, and no control of a row touches one of the row above: the white-balance
    /// eyedropper on the Basic head never reaches into "Exposure" or onto another section's head, collapsed or open.
    #[test]
    fn head_controls_stay_inside_their_row_and_clear_of_the_row_above_open_and_collapsed() {
        let d = sized();
        let sections = [
            ColorSectionKind::BasicCorrection,
            ColorSectionKind::Creative,
            ColorSectionKind::Curves,
            ColorSectionKind::Wheels,
        ];
        for collapsed in [false, true] {
            let mut m = model();
            let id = m.effects()[0].id;
            for kind in ColorSectionText::ORDER {
                m.set_collapsed(ColorPanelKey::new(id, kind, None), collapsed);
            }
            let rows = d.rows(&m, false);
            assert!(sections.iter().all(|k| ColorSectionText::ORDER.contains(k)));
            let abs = |r: &Row| -> Vec<CGRect> { r.controls.iter().map(|c| offset_by(&c.1, 0.0, r.y)).collect() };
            for (n, r) in rows.iter().enumerate() {
                for f in abs(r) {
                    assert!(
                        f.min_y() >= r.y - 0.001 && f.max_y() <= r.y + r.height + 0.001,
                        "collapsed={collapsed}: {:?} ({:?}) leaves its row {:?}..{:?}",
                        r.label,
                        f,
                        r.y,
                        r.y + r.height
                    );
                    if n > 0 {
                        for above in abs(&rows[n - 1]) {
                            let (w, h) = (
                                f.max_x().min(above.max_x()) - f.min_x().max(above.min_x()),
                                f.max_y().min(above.max_y()) - f.min_y().max(above.min_y()),
                            );
                            assert!(
                                w <= 0.0 || h <= 0.0,
                                "collapsed={collapsed}: a control of {:?} overlaps the row above",
                                r.label
                            );
                        }
                    }
                }
            }
            // Only the Basic head carries the eyedropper; no other head has one.
            let eyes = rows.iter().filter(|r| r.controls.iter().any(|c| matches!(c.0, Control::Eyedropper(_)))).count();
            assert_eq!(eyes, usize::from(!collapsed), "collapsed={collapsed}");
            let basic =
                rows.iter().find(|r| r.label.as_deref() == Some(ColorSectionKind::BasicCorrection.title())).unwrap();
            assert_eq!(basic.controls.iter().any(|c| matches!(c.0, Control::Eyedropper(_))), !collapsed);
        }
    }

    /// Down to the narrowest panel the head controls stay inside the row's width and the picker never sits on the title.
    #[test]
    fn the_eyedropper_stays_inside_a_narrow_panel_and_clear_of_the_title() {
        for width in [240.0, 280.0, 320.0] {
            let mut d = ColorGradeDraw::new();
            d.size = CGSize::new(width, 600.0);
            let m = model();
            let rows = d.rows(&m, false);
            let id = m.effects()[0].id;
            let eye = ColorGradeDraw::frame_in(&rows, Control::Eyedropper(id)).expect("open Basic head has the picker");
            assert!(eye.max_x() <= width && eye.min_x() >= 0.0, "width {width}: {eye:?}");
            assert!(eye.min_x() > Mac::LABEL_X + 60.0, "width {width}: the picker clears the title");
        }
    }

    /// D8: the "Input color" head showed only its chevron: its whole-width hit area counted as a control at x = 0 and
    /// left the title no room.
    #[test]
    fn the_input_head_leaves_its_title_room() {
        let mut d = sized();
        d.size = CGSize::new(300.0, 600.0);
        let m = model();
        let rows = d.rows(&m, false);
        let head = rows.iter().find(|r| r.label.as_deref() == Some("Input color")).expect("the Input head");
        let left = ColorGradeDraw::head_controls_left(head, 300.0);
        assert_eq!(left, 300.0 - Mac::INSET);
        assert!(left > Mac::LABEL_X + 60.0, "room for the title: {left}");
    }

    #[test]
    fn the_lut_star_is_dim_with_a_reason_unless_the_choice_is_a_file() {
        let m = model();
        let id = m.effects()[0].id;
        for slot in [ColorLUTSlot::Input, ColorLUTSlot::Look] {
            if m.lut_choice(id, slot).is_none_or(|c| c.file_path().is_none()) {
                assert!(!ColorGradeDraw::lut_star_live(&m, id, slot));
                assert!(ColorGradeDraw::lut_star_tip(&m, id, slot).starts_with("Pick a LUT file"));
            }
        }
    }

    #[test]
    fn tint_mix_is_dimmed_until_a_shadow_or_highlight_tint_is_set() {
        let d = sized();
        let m = model();
        let row = |m: &ColorInspectorModel| {
            d.rows(m, false)
                .into_iter()
                .find(|r| r.label.as_deref() == Some(ColorParam::TintBalance.title()))
                .map(|r| r.dim)
        };
        assert_eq!(row(&m), Some(true), "neutral tints: Tint Mix has nothing to move");
        let mut m = model();
        let id = m.effects()[0].id;
        m.set_wheel(id, ColorWheelSlot::ShadowTint, 30.0, 0.5);
        assert_eq!(row(&m), Some(false), "a tint is set: Tint Mix acts");
    }

    #[test]
    fn a_press_finds_the_control_under_it_and_a_section_row_hides_the_rest() {
        let d = sized();
        let m = model();
        let rows = d.rows(&m, false);
        let id = m.effects()[0].id;
        let header = rows.iter().find(|r| r.style == RowStyle::Section);
        let Some(header) = header else { return };
        let p = CGPoint::new(100.0, header.y + 10.0);
        assert_eq!(d.control_at(&m, false, p), Some(Control::Section(id, ColorSectionKind::BasicCorrection)));
        let eye = ColorGradeDraw::frame_in(&rows, Control::Eyedropper(id));
        assert!(eye.is_some());
        let slider_row = rows.iter().find(|r| r.controls.iter().any(|c| matches!(c.0, Control::Slider(_))));
        let Some(slider_row) = slider_row else { return };
        let hit = d.control_at(&m, false, CGPoint::new(130.0, slider_row.y + 12.0));
        assert!(matches!(hit, Some(Control::Slider(_))));
        assert_eq!(d.control_at(&m, false, CGPoint::new(5.0, 100_000.0)), None);
    }

    #[test]
    fn the_pro_page_starts_with_its_empty_state() {
        let d = sized();
        let mut m = model();
        m.set_active_grade(sq_core_color::ActiveGrade::Pro);
        let rows = d.rows(&m, false);
        // The Experimental notice sits above the empty state until its X was pressed once.
        assert_eq!(rows[0].style, RowStyle::Notice);
        assert!(rows[0].controls.iter().any(|c| c.0 == Control::CloseNotice));
        let at = rows.iter().position(|r| r.style == RowStyle::Empty).unwrap();
        assert_eq!(rows[at].label.as_deref(), Some("No Pro grade yet"));
        assert!(rows[at + 1].controls.iter().any(|c| c.0 == Control::StartEmpty));
        // With the Steps panel open the buttons are left to the graph.
        let shown = d.rows(&m, true);
        let at = shown.iter().position(|r| r.style == RowStyle::Empty).unwrap();
        assert_eq!(
            shown[at].summary.as_deref(),
            Some("Start from the graph below. Nothing in your Simple grade changes.")
        );
        assert!(shown.iter().all(|r| r.controls.iter().all(|c| c.0 != Control::StartEmpty)));
        // The notice's X closes it for good: the rows lose it and the empty state moves up. One test, because the
        // closed notices are process-wide state.
        let before = d.content_height(&m, false);
        let notice = rows[0].controls.iter().find(|c| c.0 == Control::CloseNotice).unwrap().1;
        assert!(notice.width > 0.0 && notice.max_x() < d.size.width);
        sq_draw::experimental::close_notice(sq_draw::experimental::Feature::ProGrading);
        let after = d.rows(&m, false);
        assert_ne!(after[0].style, RowStyle::Notice);
        assert!(d.content_height(&m, false) < before);
        sq_draw::experimental::set_prefs(sq_draw::experimental::Prefs::default());
    }

    #[test]
    fn the_file_row_leads_every_page_and_ends_in_a_hairline() {
        let mut d = sized();
        let m = model();
        assert!(d.rows(&m, false).iter().all(|r| r.style != RowStyle::File));
        d.file_row = Some(("C2171.MP4".to_string(), "Applies to all 11 uses".to_string()));
        let rows = d.rows(&m, false);
        assert_eq!(rows[0].style, RowStyle::File);
        assert_eq!(rows[0].label.as_deref(), Some("C2171.MP4"));
        assert_eq!(rows[0].summary.as_deref(), Some("Applies to all 11 uses"));
        assert_eq!(rows[0].height, 30.0);
        assert_eq!(rows[1].y, 30.0);
    }

    #[test]
    fn the_pro_page_lists_the_steps_then_the_path_and_the_tabs() {
        let d = sized();
        let mut m = model();
        m.start_empty_graph();
        let rows = d.rows(&m, false);
        assert!(rows.iter().any(|r| r.style == RowStyle::ListItem));
        assert!(rows.iter().any(|r| r.style == RowStyle::ListFoot));
        let path = rows.iter().find(|r| r.style == RowStyle::Path);
        assert_eq!(path.and_then(|r| r.label.as_deref()), Some("01   Step 1"));
        let tabs = rows.iter().find(|r| r.controls.iter().any(|c| matches!(c.0, Control::ProTab(_))));
        assert_eq!(tabs.map(|r| r.controls.len()), Some(5));
        // Primaries: four wheels with masters, and the three scaled rows.
        let wheels = rows
            .iter()
            .flat_map(|r| r.controls.iter())
            .filter(|c| matches!(c.0, Control::Wheel(Wheel::Step(..))))
            .count();
        assert_eq!(wheels, 4);
        let primaries = rows
            .iter()
            .flat_map(|r| r.controls.iter())
            .filter(|c| matches!(c.0, Control::Slider(Slider::Primary(..))))
            .count();
        assert_eq!(primaries, 3);
        // The Steps panel open hides the list.
        assert!(d.rows(&m, true).iter().all(|r| r.style != RowStyle::ListItem));
    }

    #[test]
    fn every_pro_tab_has_rows() {
        let mut d = sized();
        let mut m = model();
        m.start_empty_graph();
        for tab in 1..ColorGradeDraw::PRO_TAB_TITLES.len() {
            d.pro_tab = tab;
            let rows = d.rows(&m, false);
            assert!(rows.len() > 4, "tab {tab}");
        }
        d.pro_tab = 2;
        let q: Vec<_> = d
            .rows(&m, false)
            .into_iter()
            .filter(|r| r.controls.iter().any(|c| matches!(c.0, Control::RangeBar(_))))
            .collect();
        assert_eq!(q.len(), 3);
        assert!(q.iter().all(|r| r.dim), "without a qualifier the bars are dimmed");
    }

    #[test]
    fn color_page_menus_use_the_wording_of_the_platform() {
        let d = sized();
        let m = model();
        let id = m.effects()[0].id;
        let effect = d.effect_menu(&m, id);
        assert!(effect.iter().any(|i| i.title == "Copy Grade" && !i.shortcut.is_empty()));
        crate::assert_menu_wording("Color effect menu", &effect);
        crate::assert_menu_wording("Color section menu", &d.section_menu(&m, id, ColorSectionKind::Curves));
    }

    #[test]
    fn menus_queue_their_commands() {
        let mut d = sized();
        let m = model();
        let id = m.effects()[0].id;
        let items = d.section_menu(&m, id, ColorSectionKind::Curves);
        assert_eq!(items.len(), 3);
        assert_eq!(items[0].title, "Turn Curves Off");
        if let Some(a) = &items[0].action {
            a();
        }
        let cmds = d.take_menu_commands();
        assert_eq!(cmds, vec![DrawMenuCommand::SetEnabled(id, ColorSectionKind::Curves, false)]);
        d.input_open = true;
        let menu = d.input_menu(&m, InputRow::Interpret);
        assert!(menu[0].is_checked);
        assert_eq!(menu[0].title, "Automatic (Rec. 709)");
        assert_eq!(d.input_menu(&m, InputRow::LogMode).len(), 3);
        assert_eq!(d.input_menu(&m, InputRow::Deliver).len(), 4);
        assert_eq!(d.input_title(&m, InputRow::Project), "None (as tagged)");
        assert!(d.input_help(Control::Conform).is_some());
        assert!(d.input_help(Control::Invert(1)).is_none());
    }

    #[test]
    fn tab_widths_use_the_mac_table_for_english_titles() {
        let d = sized();
        assert_eq!(d.tab_text_width("Primaries", 11.0, false), 50.0);
        assert_eq!(d.tab_text_width("Primaries", 11.0, true), 51.0);
        assert_eq!(ColorGradeDraw::PRO_TAB_TITLES.len(), 5, "no dead Effects tab");
        assert!(d.tab_text_width("Unknown", 11.0, false) > 0.0);
    }

    #[test]
    fn blend_titles() {
        use sq_core_color::StepBlend;
        use sq_core_model::LayerMixMode;
        assert_eq!(ColorGradeDraw::blend_title(StepBlend::Series), "Series");
        assert_eq!(ColorGradeDraw::blend_title(StepBlend::Layer(LayerMixMode::Normal)), "Layer");
        assert_eq!(ColorGradeDraw::blend_title(StepBlend::Layer(LayerMixMode::Screen)), "Screen");
    }
}
