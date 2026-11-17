// Swift: Draw/TransitionControlsDraw.swift
//! Controls while a transition is selected, on the shared toolkit: the Mac `TransitionControlsView` translated (name,
//! kind line, Type for a transition layer, Duration as timecode, Alignment, the element parameters, Stinger clip and cut
//! point, Color, Easing with Custom, Direction with Reverse, Softness, Border and its color, Motion Blur, the held-frame
//! note, Reset and Save as Preset…, the right-click default menu). Rules and session calls are the shared
//! `TransitionControlsLogic` and `TransitionControlsActions`. Coordinates: points, y down, (0, 0) = the panel's top-left.
//!
//! Hooks (Swift `onMenu`, `onPickColor`, `onEaseCurve`, `onSavePreset`) are `requests` the host drains; the menu rows
//! push commands the host runs with `run_menu_commands` when the menu closes, the picker answers with `color_picked`.
//! Every pointer and key call takes the session the actions edit (the Swift class held it).

use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use sq_core_effects::transition::{
    TransitionAlignmentExt, TransitionDirectionExt, TransitionElementExt, TransitionExt, TransitionKindElement,
    TransitionKindExt,
};
use sq_core_effects::transition_custom_curve::TransitionEasing;
use sq_core_effects::transition_layer::TransitionKindLayer;
use sq_core_model::EaseReading;
use sq_core_model::EasingCurveShape;
use sq_core_model::{
    EffectColor, EffectParamKind, EffectParamSpec, TransitionAlignment, TransitionDirection, TransitionKind,
};
use sq_core_time::{EasingCurve, Id, Time};
use sq_draw::inspector::inspector_controls::Direction;
use sq_draw::inspector::scrub_field_control::Event as ScrubEvent;
use sq_draw::inspector::text_field_control::TAB;
use sq_draw::stone::Touch;
use sq_draw::theme::{spacing, type_size};
use sq_draw::{
    Canvas, CheckState, ClickCounter, Color, DrawTheme, InputEvent, InputKey, InputModifiers, InspectorDraw,
    ScrubFieldControl, TextAlign, UiCx,
};
use sq_editor_session::{EditorSession, TransitionDefaults};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use sq_uikit::timecode::Timecode;

use super::draw_support::MenuRequest;
use super::transition_controls_model::{
    Row, TransitionControlsActions, TransitionControlsLogic, TransitionControlsShown,
};
use crate::color::color_graph_menus::MenuSink;
use crate::ec_draw::easing_popover_draw::EaseSpeedEditorDraw;

/// `TransitionDirection.allCases`.
const ALL_DIRECTIONS: [TransitionDirection; 4] =
    [TransitionDirection::Left, TransitionDirection::Right, TransitionDirection::Up, TransitionDirection::Down];

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Control {
    Row(Row),
    /// The slider track of a slider row.
    Track(Row),
    Reverse,
    Reset,
    SavePreset,
    /// The Options fold bar (closed by default).
    Options,
    /// "Save to My Curves" under the inline curve of a custom easing.
    SaveCurve,
}

/// What the host must do for the panel (Swift `onPickColor`, `onEaseCurve`, `onSavePreset`).
#[derive(Clone, Debug, PartialEq)]
pub enum TransitionControlsRequest {
    /// The SQ color picker as a popover on `row`; every pick goes to `color_picked`, `None` when the picker closes.
    PickColor { row: Row, current: EffectColor, anchor: CGRect },
    /// "Save as Preset…": the host asks for a name and saves the selected transition to the Library.
    SavePreset,
    /// "Save to My Curves": the host stores a copy of the curve (`MyCurves::save`) and refreshes `my_curves`.
    SaveToMyCurves(EasingCurve),
}

/// What a row of an open menu does once the host closes the menu (the rows hold no session).
#[derive(Clone, Debug, PartialEq)]
pub enum TransitionMenuCommand {
    SetKind(TransitionKind),
    SetAlignment(TransitionAlignment),
    SetEasing(EasingCurve),
    EditCustomCurve,
    SaveToMyCurves,
    SetDirection(TransitionDirection),
    SetStingerMedia(Option<Id>),
    SetElementParam(String, f64),
    Reset,
    UseAsDefault,
    ResetDefaultToFactory,
}

pub struct TransitionControlsDraw {
    pub theme: DrawTheme,
    pub size: CGSize,
    pub actions: TransitionControlsActions,
    /// The preferences' standard transition lengths (Reset reads them).
    pub defaults: TransitionDefaults,
    /// Popups and the right-click menu: the shell's menu at `anchor` (panel points), then `run_menu_commands`.
    pub menus: Vec<MenuRequest>,
    pub requests: Vec<TransitionControlsRequest>,
    /// The saved ☆ My Curves (the host loads them from the preferences).
    pub my_curves: Vec<EasingCurve>,
    sink: MenuSink<TransitionMenuCommand>,
    shown: Option<TransitionControlsShown>,
    rows: Vec<Row>,
    fields: HashMap<Row, ScrubFieldControl>,
    /// Rows whose gesture already sent its first change (the Mac `Flag` of `wire`).
    started: HashSet<Row>,
    focused: Option<Row>,
    /// A picker session is open and has sent its first color.
    pick_open: bool,
    hover: Option<Control>,
    pressed: Option<Control>,
    counter: ClickCounter,
    clicks: ClickCounter,
    reverse_title_width: f64,
    reset_width: f64,
    save_width: f64,
    note_lines: usize,
    /// The inline curve of a custom easing (handles to drag) and whether a press on it is running.
    curve: EaseSpeedEditorDraw,
    curve_drag: bool,
    /// Custom was picked: the curve shows even while its shape still equals a preset (Custom never jumps).
    custom_open: bool,
    /// The Options fold (the rows after Easing) is open; closed by default (kit).
    options_open: bool,
    /// Design frames: Custom stays open across the first `show` of a transition.
    pose_custom: bool,
    save_curve_width: f64,
    hint_width: f64,
    /// Each easing chip's slot width (set by `draw`); labeled when the natural widths fit, else equal and icon-only.
    chip_widths: Vec<f64>,
    chips_labeled: bool,
    /// The vertical scroll offset (points); clamped to the content that does not fit the frame.
    pub scroll_y: f64,
    /// The transition the offset belongs to: another one starts at the top.
    scrolled_id: Option<Id>,
}

impl TransitionControlsDraw {
    // MARK: Metrics (the Mac stack: lg padding, sm spacing, 70 pt labels)

    const PAD: f64 = spacing::LG as f64;
    const GAP: f64 = spacing::SM as f64;
    const LABEL_WIDTH: f64 = 70.0;
    const CONTROL_HEIGHT: f64 = ControlsGrid::CONTROL_HEIGHT;
    const PITCH: f64 = ControlsGrid::CONTROL_HEIGHT + spacing::SM as f64;
    const POPUP_WIDTH: f64 = 160.0;
    const DIRECTION_WIDTH: f64 = 120.0;
    /// Kit: a short frame count, then "frames" and the seconds.
    const DURATION_WIDTH: f64 = 56.0;
    /// The easing chips: the four presets, Custom and the ☆ My Curves chip.
    const CHIP_COUNT: usize = 6;
    const SLIDER_WIDTH: f64 = 190.0;
    const SLIDER_FIELD_WIDTH: f64 = 52.0;
    const ELEMENT_FIELD_WIDTH: f64 = 72.0;
    const WELL_WIDTH: f64 = 44.0;
    const CHECK_SIDE: f64 = 14.0;
    const TITLE_HEIGHT: f64 = 18.0;
    const NOTE_WIDTH: f64 = 280.0;
    /// The inline curve under the Easing rows.
    const CURVE_HEIGHT: f64 = 120.0;
    /// One segment of the Alignment switch (kit: Start | Center | End).
    const SEGMENT_WIDTH: f64 = 64.0;

    pub fn new(actions: TransitionControlsActions) -> TransitionControlsDraw {
        TransitionControlsDraw {
            theme: DrawTheme::default(),
            size: CGSize::new(320.0, 400.0),
            actions,
            defaults: TransitionDefaults::STANDARD,
            menus: Vec::new(),
            requests: Vec::new(),
            my_curves: Vec::new(),
            sink: MenuSink::new(),
            shown: None,
            rows: Vec::new(),
            fields: HashMap::new(),
            started: HashSet::new(),
            focused: None,
            pick_open: false,
            hover: None,
            pressed: None,
            counter: ClickCounter::new(),
            clicks: ClickCounter::new(),
            reverse_title_width: 48.0,
            reset_width: 52.0,
            save_width: 110.0,
            note_lines: 0,
            curve: EaseSpeedEditorDraw::new(),
            curve_drag: false,
            custom_open: false,
            options_open: false,
            pose_custom: false,
            save_curve_width: 120.0,
            hint_width: 0.0,
            chip_widths: Vec::new(),
            chips_labeled: false,
            scroll_y: 0.0,
            scrolled_id: None,
        }
    }

    pub fn shown(&self) -> Option<&TransitionControlsShown> {
        self.shown.as_ref()
    }
    pub fn rows(&self) -> &[Row] {
        &self.rows
    }
    pub fn focused(&self) -> Option<&Row> {
        self.focused.as_ref()
    }
    pub fn hover(&self) -> Option<&Control> {
        self.hover.as_ref()
    }
    pub fn pressed(&self) -> Option<&Control> {
        self.pressed.as_ref()
    }

    fn value_x(&self) -> f64 {
        Self::PAD + Self::LABEL_WIDTH + Self::GAP
    }
    fn rows_top(&self) -> f64 {
        // Kit: one header line (name, kind, Save as Preset... and Reset at the right), then the rows.
        -self.scroll_y + Self::PAD + Self::CONTROL_HEIGHT + Self::GAP
    }
    /// Rows up to and including Easing; the rest are the options behind the fold.
    fn is_option(r: &Row) -> bool {
        !matches!(r, Row::Kind | Row::Duration | Row::Alignment | Row::Easing | Row::MyCurves)
    }
    fn main_count(&self) -> usize {
        self.rows.iter().take_while(|r| !Self::is_option(r)).count()
    }
    fn has_options(&self) -> bool {
        self.main_count() < self.rows.len()
    }
    fn row_visible(&self, i: usize) -> bool {
        self.options_open || i < self.main_count()
    }
    /// The inline curve and its hint push every slot below the Easing row down.
    fn curve_extra(&self) -> f64 {
        if self.curve_visible() { Self::CURVE_HEIGHT + Self::GAP + Self::PITCH } else { 0.0 }
    }
    /// The y of slot `n` (the fold bar takes the slot after the main rows).
    fn slot_y(&self, n: usize) -> f64 {
        let below_curve = self.curve_row().is_some_and(|c| n > c);
        self.rows_top() + n as f64 * Self::PITCH + if below_curve { self.curve_extra() } else { 0.0 }
    }
    fn row_y(&self, i: usize) -> f64 {
        let main = self.main_count();
        self.slot_y(if self.has_options() && i >= main { i + 1 } else { i })
    }
    /// The first free y under the rows (or under the closed fold bar).
    fn rows_bottom(&self) -> f64 {
        let main = self.main_count();
        match (self.has_options(), self.options_open) {
            (false, _) => self.slot_y(self.rows.len()),
            (true, true) => self.slot_y(self.rows.len() + 1),
            (true, false) => self.slot_y(main + 1),
        }
    }
    fn options_frame(&self) -> CGRect {
        CGRect::new(0.0, self.slot_y(self.main_count()), self.size.width, Self::CONTROL_HEIGHT)
    }
    /// The fold bar's right-hand summary, from the rows behind it ("Direction, border, motion blur").
    fn options_summary(&self) -> String {
        let Some(k) = self.shown.as_ref().map(|s| s.transition.kind) else { return String::new() };
        let mut names: Vec<String> = Vec::new();
        for r in self.rows.iter().filter(|r| Self::is_option(r)) {
            let t = SQL10n::string(&TransitionControlsLogic::title(r, k));
            if !names.contains(&t) {
                names.push(t);
            }
        }
        let mut out = String::new();
        for (i, n) in names.iter().enumerate() {
            if i == 0 {
                out.push_str(n);
            } else {
                out.push_str(", ");
                out.push_str(&n.to_lowercase());
            }
        }
        out
    }

    /// Design frames: the Options fold open or closed.
    pub fn set_options_open(&mut self, open: bool) {
        self.options_open = open;
    }

    /// Design frames: the Custom curve open from the start.
    pub fn set_custom_open(&mut self, open: bool) {
        self.pose_custom = open;
        self.custom_open = open;
    }

    /// The index of the row the inline curve sits under (Easing), when the curve shows.
    fn curve_row(&self) -> Option<usize> {
        if !self.curve_visible() {
            return None;
        }
        self.rows.iter().position(|r| *r == Row::Easing)
    }

    /// True while the shown transition's easing is a custom curve: the curve shows inline, to drag.
    pub fn curve_visible(&self) -> bool {
        self.shown.as_ref().is_some_and(|s| {
            s.transition.kind.uses_easing()
                && (self.custom_open
                    || TransitionControlsLogic::easing_index(&s.transition.effective_easing())
                        == TransitionControlsLogic::custom_easing_index())
        })
    }

    /// Where the inline curve is drawn (zero-sized while hidden).
    pub fn curve_frame(&self) -> CGRect {
        let Some(i) = self.curve_row() else { return CGRect::new(0.0, 0.0, 0.0, 0.0) };
        let w = (self.size.width - Self::PAD * 2.0).max(0.0);
        CGRect::new(Self::PAD, self.row_y(i) + Self::PITCH, w, Self::CURVE_HEIGHT)
    }

    /// The hint line under the inline curve: its text starts at the left, the Save button follows.
    fn hint_y(&self) -> f64 {
        self.curve_frame().max_y() + Self::GAP
    }

    /// Keeps the offset inside the content: a dock that grew, or rows that got fewer, never leave a gap.
    fn clamp_scroll(&mut self) {
        let max = (self.content_height() - self.size.height).max(0.0);
        self.scroll_y = self.scroll_y.clamp(0.0, max);
    }

    /// Wheel / trackpad: scrolls the content 1:1; false when it already sits at the end.
    pub fn scroll_by(&mut self, dy: f64) -> bool {
        let before = self.scroll_y;
        self.scroll_y = before - dy;
        self.clamp_scroll();
        self.scroll_y != before
    }

    /// Shows a transition (None = nothing); the fields keep the value being typed or dragged.
    pub fn show(&mut self, s: Option<TransitionControlsShown>) {
        let key = |x: &Option<TransitionControlsShown>| x.as_ref().map(|s| (s.transition.id, s.transition.kind));
        if key(&s) != key(&self.shown) {
            self.custom_open = false;
            self.fields.clear();
            self.started.clear();
            self.focused = None;
            self.pressed = None;
        }
        self.shown = s;
        if self.pose_custom {
            self.custom_open = true;
        }
        let id = self.shown.as_ref().map(|s| s.transition.id);
        if id != self.scrolled_id {
            self.scrolled_id = id;
            self.scroll_y = 0.0;
        }
        let Some(s) = self.shown.clone() else {
            self.rows.clear();
            self.sync_curve();
            return;
        };
        self.rows = TransitionControlsLogic::rows(&s);
        let tr = &s.transition;
        let k = tr.kind;
        let fd = s.frame_duration;
        for r in self.rows.clone() {
            let (mut f, v): (ScrubFieldControl, f64) = match &r {
                Row::Duration => {
                    let mut f = self.fields.remove(&r).unwrap_or_else(|| ScrubFieldControl::new(0.0));
                    f.range = 1.0..=1_000_000.0;
                    let tc = Timecode::new(fd, false);
                    // Kit: the field shows whole frames; typing a timecode still works.
                    f.value_formatter = Some(Box::new(|v| format!("{}", v.round() as i64)));
                    f.value_parser = Some(Box::new(move |text| {
                        let t = tc.parse(text).filter(|t| *t > Time::ZERO)?;
                        Some(TransitionControlsLogic::duration_frames(t, fd))
                    }));
                    (f, TransitionControlsLogic::duration_frames(TransitionControlsLogic::shown_duration(&s), fd))
                }
                Row::Softness => (
                    self.slider(
                        &r,
                        TransitionControlsLogic::SOFTNESS_RANGE,
                        TransitionControlsLogic::softness_percent(TransitionKind::DEFAULT_SOFTNESS),
                    ),
                    TransitionControlsLogic::softness_percent(tr.effective_softness()),
                ),
                Row::MotionBlur => (
                    self.slider(
                        &r,
                        TransitionControlsLogic::blur_range(k),
                        TransitionControlsLogic::blur_percent(k.default_motion_blur()),
                    ),
                    TransitionControlsLogic::blur_percent(tr.effective_motion_blur()),
                ),
                Row::Border => (
                    self.slider(&r, TransitionControlsLogic::BORDER_RANGE, 0.0),
                    (tr.border_width.unwrap_or(0.0) * 100.0).round(),
                ),
                Row::StingerCut => (
                    self.slider(&r, TransitionControlsLogic::STINGER_CUT_RANGE, 50.0),
                    (tr.stinger.as_ref().map_or(0.5, |st| st.cut_fraction) * 100.0).round(),
                ),
                Row::Element(key) => {
                    let Some(spec) = k.element_params().into_iter().find(|p| p.key == *key) else { continue };
                    if !matches!(spec.kind, EffectParamKind::Slider) {
                        continue;
                    }
                    let mut f = self.fields.remove(&r).unwrap_or_else(|| ScrubFieldControl::new(spec.default_value));
                    f.range = spec.range.clone();
                    f.step = spec.step;
                    f.decimals = spec.decimals;
                    f.unit = spec.unit.clone();
                    f.default_value = Some(spec.default_value);
                    (f, tr.param(key))
                }
                _ => continue,
            };
            if !f.is_dragging() && !f.is_editing() {
                f.value = v;
            }
            self.fields.insert(r, f);
        }
        self.sync_curve();
    }

    /// The inline curve reads the shown transition's easing (the session is the one truth; a drag writes through it).
    fn sync_curve(&mut self) {
        self.curve.reading = match &self.shown {
            Some(s) if s.transition.kind.uses_easing() => EaseReading::Common(s.transition.effective_easing().shape()),
            _ => EaseReading::Empty,
        };
        let f = self.curve_frame();
        self.curve.size = CGSize::new(f.width, f.height);
    }

    fn slider(&mut self, r: &Row, range: std::ops::RangeInclusive<f64>, def: f64) -> ScrubFieldControl {
        let mut f = self.fields.remove(r).unwrap_or_else(|| ScrubFieldControl::new(def));
        f.range = range;
        f.unit = "%".to_string();
        f.default_value = Some(def);
        f
    }

    fn spec(&self, key: &str) -> Option<EffectParamSpec> {
        self.shown.as_ref()?.transition.kind.element_params().into_iter().find(|p| p.key == key)
    }

    // MARK: Layout

    fn is_slider(r: &Row) -> bool {
        matches!(r, Row::Softness | Row::MotionBlur | Row::Border | Row::StingerCut)
    }

    /// The field / popup / well of a row (for a slider row: its number field).
    pub fn frame(&self, k: &Control) -> CGRect {
        let ch = Self::CONTROL_HEIGHT;
        match k {
            Control::Row(r) | Control::Track(r) => {
                let Some(i) = self.rows.iter().position(|x| x == r) else { return CGRect::new(0.0, 0.0, 0.0, 0.0) };
                if !self.row_visible(i) {
                    return CGRect::new(0.0, 0.0, 0.0, 0.0);
                }
                let y = self.row_y(i);
                let vx = self.value_x();
                let boxed = |w: f64| CGRect::new(vx, y, w.min((self.size.width - vx - Self::PAD).max(0.0)), ch);
                match r {
                    Row::Alignment if self.alignment_segments().len() > 1 => {
                        boxed(Self::SEGMENT_WIDTH * self.alignment_segments().len() as f64)
                    }
                    Row::Kind | Row::Alignment | Row::MyCurves => boxed(Self::POPUP_WIDTH),
                    Row::Easing => boxed(self.size.width),
                    Row::StingerClip => boxed(200.0),
                    Row::Direction => boxed(Self::DIRECTION_WIDTH),
                    Row::Duration => boxed(Self::DURATION_WIDTH),
                    Row::Color | Row::BorderColor => boxed(Self::WELL_WIDTH),
                    Row::Element(key) => match self.spec(key).map(|s| s.kind) {
                        Some(EffectParamKind::Choice(_)) => boxed(Self::POPUP_WIDTH),
                        Some(EffectParamKind::Checkbox) => CGRect::new(
                            vx,
                            y + ((ch - Self::CHECK_SIDE) / 2.0).round(),
                            Self::CHECK_SIDE,
                            Self::CHECK_SIDE,
                        ),
                        _ => boxed(Self::ELEMENT_FIELD_WIDTH),
                    },
                    Row::Softness | Row::MotionBlur | Row::Border | Row::StingerCut => {
                        let whole = boxed(Self::SLIDER_WIDTH);
                        let fw = Self::SLIDER_FIELD_WIDTH.min(whole.width);
                        if matches!(k, Control::Track(_)) {
                            return CGRect::new(
                                whole.min_x(),
                                whole.min_y(),
                                (whole.width - fw - Self::GAP).max(0.0),
                                ch,
                            );
                        }
                        CGRect::new(whole.max_x() - fw, whole.min_y(), fw, ch)
                    }
                }
            }
            Control::Options => self.options_frame(),
            Control::SaveCurve => {
                let h = self.hint_text_width();
                CGRect::new(Self::PAD + h + Self::GAP, self.hint_y(), self.save_curve_width, Self::CONTROL_HEIGHT)
            }
            Control::Reverse => {
                let d = self.frame(&Control::Row(Row::Direction));
                CGRect::new(
                    d.max_x() + Self::GAP,
                    d.min_y() + ((ch - Self::CHECK_SIDE) / 2.0).round(),
                    Self::CHECK_SIDE + 6.0 + self.reverse_title_width,
                    Self::CHECK_SIDE,
                )
            }
            Control::Reset | Control::SavePreset => {
                // The header line: Reset at the right end, Save as Preset... left of it.
                let y = Self::PAD - self.scroll_y;
                let right = self.size.width - Self::PAD;
                let reset_w = if self.shows_reset() { self.reset_width } else { 0.0 };
                if *k == Control::Reset {
                    return CGRect::new(right - reset_w, y, reset_w, ch);
                }
                let gap = if self.shows_reset() { Self::GAP } else { 0.0 };
                CGRect::new(right - reset_w - gap - self.save_width, y, self.save_width, ch)
            }
        }
    }

    /// The Alignment switch's segments in the kit's order: Start, Center, End (+ Custom while it is set). Empty for a
    /// one-sided transition, which keeps the disabled popup.
    fn alignment_segments(&self) -> Vec<(TransitionAlignment, &'static str)> {
        let Some(s) = &self.shown else { return Vec::new() };
        let options = TransitionControlsLogic::alignment_options(s);
        [
            (TransitionAlignment::StartAtCut, "Start"),
            (TransitionAlignment::Center, "Center"),
            (TransitionAlignment::EndAtCut, "End"),
            (TransitionAlignment::Custom, "Custom"),
        ]
        .into_iter()
        .filter(|(a, _)| options.contains(a))
        .collect()
    }

    fn shows_buttons(&self) -> bool {
        self.shown.as_ref().is_some_and(|s| !s.is_layer)
    }
    fn shows_reset(&self) -> bool {
        self.shows_buttons() && self.shown.as_ref().is_some_and(|s| !s.transition.kind.is_stinger())
    }
    fn note_y(&self) -> f64 {
        self.rows_bottom()
    }
    fn note_height(&self) -> f64 {
        if self.note_lines == 0 { 0.0 } else { self.note_lines as f64 * (f64::from(type_size::BODY) + 4.0) + Self::GAP }
    }
    fn buttons_y(&self) -> f64 {
        self.note_y() + self.note_height()
    }
    /// The hint's text width; the long kit sentence only when the Save button still fits beside it.
    fn hint_text_width(&self) -> f64 {
        self.hint_width
    }

    /// The content height (rows, note and buttons).
    pub fn content_height(&self) -> f64 {
        self.scroll_y + self.buttons_y() + Self::PAD
    }

    pub fn control_at(&self, p: CGPoint) -> Option<Control> {
        self.shown.as_ref()?;
        // Rows scrolled past the frame edge take no click.
        if !CGRect::new(0.0, 0.0, self.size.width, self.size.height).contains(p) {
            return None;
        }
        if self.shows_buttons() {
            if self.shows_reset() && self.frame(&Control::Reset).contains(p) {
                return Some(Control::Reset);
            }
            if self.frame(&Control::SavePreset).contains(p) {
                return Some(Control::SavePreset);
            }
        }
        if self.has_options() && self.options_frame().contains(p) {
            return Some(Control::Options);
        }
        if self.curve_visible() && self.frame(&Control::SaveCurve).contains(p) {
            return Some(Control::SaveCurve);
        }
        if self.rows.contains(&Row::Direction) && self.options_open && self.frame(&Control::Reverse).contains(p) {
            return Some(Control::Reverse);
        }
        for r in &self.rows {
            if Self::is_slider(r) && self.frame(&Control::Track(r.clone())).inset_by(-4.0, 0.0).contains(p) {
                return Some(Control::Track(r.clone()));
            }
            if self.frame(&Control::Row(r.clone())).contains(p) {
                return Some(Control::Row(r.clone()));
            }
        }
        None
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, cx: &mut UiCx) {
        let t = self.theme;
        c.fill(CGRect::new(0.0, 0.0, self.size.width, self.size.height), t.panel());
        let Some(s) = self.shown.clone() else { return };
        self.clamp_scroll();
        self.layout_chips(c);
        self.sync_curve();
        c.save_gstate();
        c.clip_to(CGRect::new(0.0, 0.0, self.size.width, self.size.height));
        let fs = f64::from(type_size::BODY);
        let k = s.transition.kind;
        let w = (self.size.width - Self::PAD * 2.0).max(0.0);
        let name = SQL10n::string(k.name());
        let name_w = c.size_of(&name, f64::from(type_size::TITLE), 0).width.ceil();
        let head_y = Self::PAD - self.scroll_y + ((Self::CONTROL_HEIGHT - Self::TITLE_HEIGHT) / 2.0).floor();
        c.draw_text_in(
            &name,
            CGRect::new(Self::PAD, head_y, w, Self::TITLE_HEIGHT),
            f64::from(type_size::TITLE),
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );
        let buttons_x = if self.shows_buttons() { self.frame(&Control::SavePreset).min_x() } else { Self::PAD + w };
        let sub_x = Self::PAD + name_w + 8.0;
        let subtitle = c.ellipsized(
            &SQL10n::string(&TransitionControlsLogic::subtitle(&s)),
            fs,
            0,
            (buttons_x - Self::GAP - sub_x).max(0.0),
        );
        c.draw_text_in(
            &subtitle,
            CGRect::new(sub_x, head_y, (buttons_x - sub_x).max(0.0), Self::TITLE_HEIGHT),
            fs,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        for (i, r) in self.rows.clone().iter().enumerate() {
            if !self.row_visible(i) {
                continue;
            }
            c.draw_text_in(
                &SQL10n::string(&TransitionControlsLogic::title(r, k)),
                CGRect::new(Self::PAD, self.row_y(i), Self::LABEL_WIDTH, Self::CONTROL_HEIGHT),
                fs,
                t.label2(),
                TextAlign::Right,
                0.0,
                0,
            );
            self.draw_control(c, cx, r, &s);
        }
        if self.curve_visible() {
            let f = self.curve_frame();
            c.save_gstate();
            c.clip_to(f);
            c.fill(f, t.well());
            c.translate_by(f.x, f.y);
            self.curve.draw(c, &t);
            c.restore_gstate();
        }
        if self.curve_visible() {
            self.draw_curve_hint(c);
        }
        if self.has_options() {
            self.draw_options_bar(c);
        }
        if let Some(note) = TransitionControlsLogic::note(&s) {
            let nw = Self::NOTE_WIDTH.min(w);
            let text = SQL10n::string(note);
            self.note_lines = c.wrap(&text, nw, fs).len();
            c.draw_wrapped(
                &text,
                CGRect::new(Self::PAD, self.note_y(), nw, self.note_height()),
                fs,
                fs + 4.0,
                t.label3(),
            );
        } else {
            self.note_lines = 0;
        }
        if !self.shows_buttons() {
            c.restore_gstate();
            return;
        }
        self.reset_width = InspectorDraw::button_width(c, &SQL10n::string("Reset"));
        self.save_width = InspectorDraw::button_width(c, &SQL10n::string("Save as Preset\u{2026}"));
        let ch = Self::CONTROL_HEIGHT;
        if self.shows_reset() {
            InspectorDraw::button(
                c,
                &SQL10n::string("Reset"),
                self.frame(&Control::Reset),
                self.hover == Some(Control::Reset),
                self.pressed == Some(Control::Reset),
                true,
                false,
                ch,
                &t,
            );
        }
        InspectorDraw::button(
            c,
            &SQL10n::string("Save as Preset\u{2026}"),
            self.frame(&Control::SavePreset),
            self.hover == Some(Control::SavePreset),
            self.pressed == Some(Control::SavePreset),
            true,
            false,
            ch,
            &t,
        );
        c.restore_gstate();
    }

    /// "Custom is always one click away. Drag the handles, then [Save to My Curves]" under the inline curve.
    fn draw_curve_hint(&mut self, c: &mut Canvas) {
        let t = self.theme;
        let fs = f64::from(type_size::BODY);
        let title = SQL10n::string("\u{2606} Save to My Curves");
        self.save_curve_width = InspectorDraw::button_width(c, &title);
        let long = SQL10n::string("Custom is always one click away. Drag the handles, then");
        let short = SQL10n::string("Drag the handles, then");
        let room = self.size.width - Self::PAD * 2.0 - Self::GAP - self.save_curve_width;
        let long_w = c.size_of(&long, fs, 0).width.ceil();
        let (text, w) = if long_w <= room {
            (long, long_w)
        } else {
            (short, c.size_of(&SQL10n::string("Drag the handles, then"), fs, 0).width.ceil().min(room.max(0.0)))
        };
        self.hint_width = w;
        let y = self.hint_y();
        c.draw_text_in(
            &text,
            CGRect::new(Self::PAD, y, w, Self::CONTROL_HEIGHT),
            fs,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
        InspectorDraw::button(
            c,
            &title,
            self.frame(&Control::SaveCurve),
            self.hover == Some(Control::SaveCurve),
            self.pressed == Some(Control::SaveCurve),
            true,
            false,
            Self::CONTROL_HEIGHT,
            &t,
        );
    }

    /// The Options fold bar: chevron, "Options", the summary of what is behind it at the right.
    fn draw_options_bar(&self, c: &mut Canvas) {
        let t = self.theme;
        let f = self.options_frame();
        let fs = f64::from(type_size::BODY);
        let hot = self.hover == Some(Control::Options);
        c.fill(f, t.well());
        InspectorDraw::chevron(
            c,
            CGRect::new(Self::PAD - 4.0, f.min_y(), 12.0, f.height),
            if self.options_open { Direction::Down } else { Direction::Right },
            if hot { t.label() } else { t.label3() },
            8.0,
        );
        let title = SQL10n::string("Options");
        let tw = c.size_of(&title, fs, 0).width.ceil();
        c.draw_text_in(
            &title,
            CGRect::new(Self::PAD + 12.0, f.min_y(), tw + 4.0, f.height),
            fs,
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );
        if !self.options_open {
            let x = Self::PAD + 12.0 + tw + 12.0;
            let w = (self.size.width - Self::PAD - x).max(0.0);
            let text = c.ellipsized(&self.options_summary(), fs, 0, w);
            c.draw_text_in(&text, CGRect::new(x, f.min_y(), w, f.height), fs, t.label3(), TextAlign::Right, 0.0, 0);
        }
    }

    fn draw_control(&mut self, c: &mut Canvas, cx: &mut UiCx, r: &Row, s: &TransitionControlsShown) {
        let t = self.theme;
        let f = self.frame(&Control::Row(r.clone()));
        let hov = self.hover == Some(Control::Row(r.clone()));
        let tr = &s.transition;
        let ch = Self::CONTROL_HEIGHT;
        let popup = |c: &mut Canvas, title: &str, enabled: bool| {
            InspectorDraw::popup(c, &SQL10n::string(title), f, hov, false, enabled, false, ch, None, &t);
        };
        let well = |c: &mut Canvas, rgb: [u8; 3]| {
            let col = Color::new(f32::from(rgb[0]) / 255.0, f32::from(rgb[1]) / 255.0, f32::from(rgb[2]) / 255.0, 1.0);
            InspectorDraw::color_well(c, col, f, hov, &t);
        };
        let focused = self.focused.as_ref() == Some(r);
        match r {
            Row::Kind => popup(c, tr.kind.name(), true),
            Row::Alignment if self.alignment_segments().len() > 1 => {
                let segments = self.alignment_segments();
                c.stone_segment_track(f, Touch::default(), &t);
                let w = f.width / segments.len() as f64;
                for (i, (a, title)) in segments.into_iter().enumerate() {
                    let seg = CGRect::new(f.min_x() + w * i as f64, f.min_y(), w, f.height);
                    let on = tr.alignment == a;
                    let hot = self.hover == Some(Control::Row(Row::Alignment)) && !on;
                    c.stone_segment(seg.inset_by(2.0, 2.0), on, Touch { hovering: hot, ..Touch::default() }, &t);
                    c.draw_text_in(
                        &SQL10n::string(title),
                        seg,
                        f64::from(type_size::BODY),
                        if on { t.label() } else { t.label3() },
                        TextAlign::Center,
                        0.0,
                        0,
                    );
                }
            }
            Row::Alignment => {
                popup(c, TransitionControlsLogic::shown_alignment(s).name(), TransitionControlsLogic::is_two_sided(s));
            }
            Row::Easing => self.draw_ease_chips(c, f, &tr.effective_easing()),
            Row::MyCurves => popup(c, &format!("{} saved", self.my_curves.len()), true),
            Row::Direction => {
                popup(c, tr.effective_direction().name(), true);
                let rb = self.frame(&Control::Reverse);
                let boxed = CGRect::new(rb.min_x(), rb.min_y(), Self::CHECK_SIDE, Self::CHECK_SIDE);
                InspectorDraw::checkbox(
                    c,
                    if tr.is_reversed() { CheckState::On } else { CheckState::Off },
                    boxed,
                    self.hover == Some(Control::Reverse),
                    self.pressed == Some(Control::Reverse),
                    true,
                    false,
                    &t,
                );
                let title = SQL10n::string("Reverse");
                let body = f64::from(type_size::BODY);
                self.reverse_title_width = c.size_of(&title, body, 0).width;
                c.draw_text_in(
                    &title,
                    CGRect::new(
                        boxed.max_x() + 6.0,
                        boxed.min_y() - 4.0,
                        self.reverse_title_width + 4.0,
                        Self::CHECK_SIDE + 8.0,
                    ),
                    body,
                    t.label(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            Row::StingerClip => {
                let items = TransitionControlsLogic::stinger_items(s);
                popup(c, &items.titles[items.selected], true);
            }
            Row::Color => well(c, TransitionControlsLogic::color(s)),
            Row::BorderColor => well(c, TransitionControlsLogic::border_color(s)),
            Row::Duration => {
                let Some(fd) = self.fields.get_mut(r) else { return };
                fd.hovering = hov;
                fd.draw(c, f, &t, focused, cx);
                // Kit: "8 frames 0.27 s".
                let body = f64::from(type_size::BODY);
                let frames = SQL10n::string("frames");
                let fw = c.size_of(&frames, body, 0).width.ceil();
                c.draw_text_in(
                    &frames,
                    CGRect::new(f.max_x() + 8.0, f.min_y(), fw + 2.0, f.height),
                    body,
                    t.label2(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
                let d = TransitionControlsLogic::shown_duration(s);
                let secs = d.value() as f64 / d.timescale() as f64;
                c.draw_text_in(
                    &format!("{secs:.2} s"),
                    CGRect::new(f.max_x() + 8.0 + fw + 8.0, f.min_y(), 60.0, f.height),
                    body,
                    t.label3(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            Row::Softness | Row::MotionBlur | Row::Border | Row::StingerCut => {
                let track = self.frame(&Control::Track(r.clone()));
                let Some(fd) = self.fields.get_mut(r) else { return };
                let span = fd.range.end() - fd.range.start();
                InspectorDraw::slider(
                    c,
                    if span > 0.0 { (fd.value - fd.range.start()) / span } else { 0.0 },
                    0.0,
                    track,
                    true,
                    &t,
                );
                fd.hovering = hov;
                fd.draw(c, f, &t, focused, cx);
            }
            Row::Element(key) => {
                let Some(sp) = self.spec(key) else { return };
                match &sp.kind {
                    EffectParamKind::Choice(titles) => {
                        let i = sp.kind.choice_index(tr.param(key));
                        popup(c, usize::try_from(i).ok().and_then(|i| titles.get(i)).map_or("", |s| s.as_str()), true);
                    }
                    EffectParamKind::Checkbox => {
                        InspectorDraw::checkbox(
                            c,
                            if sp.kind.is_on(tr.param(key)) { CheckState::On } else { CheckState::Off },
                            f,
                            hov,
                            self.pressed == Some(Control::Row(r.clone())),
                            true,
                            false,
                            &t,
                        );
                    }
                    _ => {
                        let Some(fd) = self.fields.get_mut(r) else { return };
                        fd.hovering = hov;
                        fd.draw(c, f, &t, focused, cx);
                    }
                }
            }
        }
    }

    // MARK: Pointer and keys

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        let on_curve = p.filter(|p| self.curve_visible() && self.curve_frame().contains(*p));
        self.curve.mouse_moved(on_curve.map(|p| self.curve_local(p)));
        if self.pressed.is_none() {
            self.hover = p.and_then(|p| self.control_at(p));
        }
    }

    pub fn mouse_down(
        &mut self,
        session: &mut EditorSession,
        cx: &mut UiCx,
        p: CGPoint,
        click_count: Option<i64>,
        modifiers: InputModifiers,
    ) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        let k = self.control_at(p);
        if let Some(f) = self.focused.clone()
            && k != Some(Control::Row(f))
        {
            self.resign_focus(session, cx);
        }
        // FB-W: right-click anywhere in the controls.
        if modifiers.contains(InputModifiers::SECONDARY) {
            self.pressed = None;
            self.show_context_menu(p);
            return;
        }
        if k.is_none() && self.curve_visible() && self.curve_frame().contains(p) {
            let local = self.curve_local(p);
            if self.curve.press(local) {
                self.curve_drag = true;
                self.pressed = None;
                self.forward_curve(session);
                return;
            }
        }
        self.pressed = k.clone();
        let (Some(k), Some(s)) = (k, self.shown.clone()) else { return };
        match k {
            Control::Track(r) => {
                self.focused = None;
                self.started.remove(&r);
                self.set_from_track(session, &r, p.x, false);
            }
            Control::Row(Row::Easing) => {}
            Control::Row(Row::Alignment) if self.alignment_segments().len() > 1 => {
                let segments = self.alignment_segments();
                let f = self.frame(&Control::Row(Row::Alignment));
                let i = (((p.x - f.min_x()) / (f.width / segments.len() as f64)).floor().max(0.0) as usize)
                    .min(segments.len() - 1);
                self.pressed = None;
                self.actions.set_alignment(session, segments[i].0);
            }
            Control::Row(r) => {
                if !Self::is_popup_row(&r, self.spec_kind(&r))
                    && let Some(mut fd) = self.fields.remove(&r)
                {
                    let ev = fd.mouse_down(p.x as f32, n);
                    self.fields.insert(r.clone(), fd);
                    self.apply(session, ev, &r);
                    self.focused = Some(r);
                    return;
                }
                self.pressed = if self.is_check_row(&r) { Some(Control::Row(r.clone())) } else { None };
                self.open_row(&r, &s);
            }
            _ => {}
        }
    }

    fn spec_kind(&self, r: &Row) -> Option<EffectParamKind> {
        if let Row::Element(key) = r { self.spec(key).map(|s| s.kind) } else { None }
    }

    fn is_popup_row(r: &Row, element_kind: Option<EffectParamKind>) -> bool {
        match r {
            Row::Kind
            | Row::Alignment
            | Row::MyCurves
            | Row::Direction
            | Row::StingerClip
            | Row::Color
            | Row::BorderColor => true,
            Row::Element(_) => matches!(element_kind, Some(EffectParamKind::Choice(_))),
            _ => false,
        }
    }

    fn is_check_row(&self, r: &Row) -> bool {
        matches!(self.spec_kind(r), Some(EffectParamKind::Checkbox))
    }

    fn curve_local(&self, p: CGPoint) -> CGPoint {
        let f = self.curve_frame();
        CGPoint::new(p.x - f.x, p.y - f.y)
    }

    /// Hands the inline curve's gesture events to the session (one undo step per handle drag).
    fn forward_curve(&mut self, session: &mut EditorSession) {
        if let Some(mut source) = self.actions.ease_source(session) {
            self.curve.forward(&mut source);
        }
    }

    pub fn mouse_dragged(&mut self, session: &mut EditorSession, cx: &mut UiCx, p: CGPoint, modifiers: InputModifiers) {
        if self.curve_drag {
            self.curve.drag_gesture(self.curve_local(p), modifiers.contains(InputModifiers::SHIFT));
            self.forward_curve(session);
            return;
        }
        match self.pressed.clone() {
            Some(Control::Track(r)) => self.set_from_track(session, &r, p.x, true),
            Some(Control::Row(r)) if self.fields.contains_key(&r) => {
                let Some(mut fd) = self.fields.remove(&r) else { return };
                let ev = fd.mouse_dragged(p.x as f32, modifiers, self.theme.scale, cx);
                self.fields.insert(r.clone(), fd);
                self.apply(session, ev, &r);
            }
            _ => {}
        }
    }

    pub fn mouse_up(&mut self, session: &mut EditorSession, cx: &mut UiCx, p: CGPoint) {
        if std::mem::take(&mut self.curve_drag) {
            self.curve.release();
            self.forward_curve(session);
            return;
        }
        let k = self.pressed.take();
        self.mouse_up_inner(session, cx, p, k);
        self.mouse_moved(Some(p));
    }

    fn mouse_up_inner(&mut self, session: &mut EditorSession, cx: &mut UiCx, p: CGPoint, k: Option<Control>) {
        match &k {
            Some(Control::Track(r)) => {
                self.started.remove(r);
                return;
            }
            Some(Control::Row(r)) if self.fields.contains_key(r) => {
                let Some(mut fd) = self.fields.remove(r) else { return };
                let ev = fd.mouse_up(cx);
                self.fields.insert(r.clone(), fd);
                self.apply(session, ev, r);
                return;
            }
            _ => {}
        }
        let Some(k) = k else { return };
        let Some(s) = self.shown.clone() else { return };
        if self.control_at(p).as_ref() != Some(&k) {
            return;
        }
        match k {
            Control::Reverse => self.actions.set_reversed(session, !s.transition.is_reversed()),
            Control::Reset => self.actions.reset(session, &self.defaults),
            Control::SavePreset => self.requests.push(TransitionControlsRequest::SavePreset),
            Control::Options => self.options_open = !self.options_open,
            Control::SaveCurve => {
                self.requests.push(TransitionControlsRequest::SaveToMyCurves(s.transition.effective_easing()));
            }
            Control::Row(Row::Easing) => {
                let f = self.frame(&Control::Row(Row::Easing));
                let chip = self.chip_at(p.x, f);
                if chip == Self::CHIP_COUNT - 1 {
                    self.open_my_curves(self.chip_rect(f, chip), &s);
                    return;
                }
                match Self::ease_chips().get(chip).and_then(|c| c.1.clone()) {
                    Some(curve) => {
                        self.custom_open = false;
                        self.actions.set_easing(session, curve);
                    }
                    None => self.edit_custom_curve(session),
                }
            }
            Control::Row(Row::Element(key)) => {
                if let Some(sp) = self.spec(&key) {
                    let on = sp.kind.is_on(s.transition.param(&key));
                    self.actions.set_element_param(session, &key, if on { 0.0 } else { 1.0 });
                }
            }
            _ => {}
        }
    }

    /// A press or drag on a slider track: the value under the pointer, one undo step per drag.
    fn set_from_track(&mut self, session: &mut EditorSession, r: &Row, x: f64, continues: bool) {
        let track = self.frame(&Control::Track(r.clone()));
        let Some(fd) = self.fields.get_mut(r) else { return };
        let range = fd.range.clone();
        let v = (range.start() + InspectorDraw::slider_fraction(x, track) * (range.end() - range.start())).round();
        if continues && v == fd.value {
            return;
        }
        fd.value = v;
        self.report(session, r, v);
    }

    /// The field's begin / change / end events to the session: the first change of a gesture starts the undo step, the
    /// rest join it; a typed value reports once at the end (the Mac `wire` and the element rows' `started` flag).
    fn apply(&mut self, session: &mut EditorSession, events: Vec<ScrubEvent>, r: &Row) {
        let Some(s) = self.shown.clone() else { return };
        for e in events {
            match e {
                ScrubEvent::Begin => {
                    self.started.remove(r);
                }
                ScrubEvent::Live(v) | ScrubEvent::Change(v) => {
                    if *r == Row::Duration {
                        continue;
                    }
                    self.report(session, r, v);
                }
                ScrubEvent::End(v) | ScrubEvent::Cancel(v) => {
                    if *r == Row::Duration {
                        let t = TransitionControlsLogic::duration(v, s.frame_duration);
                        if t != TransitionControlsLogic::shown_duration(&s) {
                            self.actions.set_duration(session, t);
                        }
                    } else if !self.started.contains(r) {
                        self.report(session, r, v);
                    }
                    self.started.remove(r);
                }
            }
        }
    }

    fn report(&mut self, session: &mut EditorSession, r: &Row, value: f64) {
        let cont = self.started.contains(r);
        self.started.insert(r.clone());
        match r {
            Row::Softness => self.actions.set_softness(session, value.round() / 100.0, cont),
            Row::MotionBlur => {
                self.actions.set_motion_blur(session, TransitionControlsLogic::shutter(value.round()), cont)
            }
            Row::Border => self.actions.set_border_width(session, value.round() / 100.0, cont),
            Row::StingerCut => self.actions.set_stinger_cut(session, value.round() / 100.0, cont),
            Row::Element(key) => self.actions.set_element_param_live(session, key, value, cont),
            _ => {}
        }
    }

    fn command_row(&self, title: &str, checked: bool, cmd: TransitionMenuCommand) -> SQMenuItem {
        let mut row = SQMenuItem::new(title);
        row.is_checked = checked;
        let sink = self.sink.clone();
        row.action = Some(Rc::new(move || sink.push(cmd.clone())));
        row
    }

    /// The ☆ My Curves chip: the saved curves, then Save to My Curves.
    fn open_my_curves(&mut self, anchor: CGRect, s: &TransitionControlsShown) {
        let tr = &s.transition;
        let mut items: Vec<SQMenuItem> = Vec::new();
        for c in self.my_curves.clone() {
            let on = tr.effective_easing().shape().is_approximately_equal(&c.shape());
            let title = format!("\u{2606} {}", c.name);
            items.push(self.command_row(&title, on, TransitionMenuCommand::SetEasing(c)));
        }
        items.push(self.command_row("Save to My Curves", false, TransitionMenuCommand::SaveToMyCurves));
        self.menus.push(MenuRequest { items, anchor });
    }

    /// Popups and color wells: the shell menu or the color picker anchored to the control.
    fn open_row(&mut self, r: &Row, s: &TransitionControlsShown) {
        let anchor = self.frame(&Control::Row(r.clone()));
        let tr = &s.transition;
        let mut items: Vec<SQMenuItem> = Vec::new();
        match r {
            Row::Kind => {
                for k in TransitionKind::layer_kinds() {
                    items.push(self.command_row(k.name(), k == tr.kind, TransitionMenuCommand::SetKind(k)));
                }
            }
            Row::Alignment => {
                if !TransitionControlsLogic::is_two_sided(s) {
                    return;
                }
                for a in TransitionControlsLogic::alignment_options(s) {
                    items.push(self.command_row(a.name(), a == tr.alignment, TransitionMenuCommand::SetAlignment(a)));
                }
            }
            Row::Easing => {
                let current = TransitionControlsLogic::easing_index(&tr.effective_easing());
                for (i, c) in TransitionControlsLogic::easings().into_iter().enumerate() {
                    let title = c.display_name().to_string();
                    items.push(self.command_row(&title, i == current, TransitionMenuCommand::SetEasing(c)));
                }
                items.push(self.command_row(
                    TransitionControlsLogic::CUSTOM_EASING_TITLE,
                    current == TransitionControlsLogic::custom_easing_index(),
                    TransitionMenuCommand::EditCustomCurve,
                ));
            }
            Row::MyCurves => {
                self.open_my_curves(anchor, s);
                return;
            }
            Row::Direction => {
                for d in ALL_DIRECTIONS {
                    items.push(self.command_row(
                        d.name(),
                        d == tr.effective_direction(),
                        TransitionMenuCommand::SetDirection(d),
                    ));
                }
            }
            Row::StingerClip => {
                let list = TransitionControlsLogic::stinger_items(s);
                for i in 0..list.titles.len() {
                    items.push(self.command_row(
                        &list.titles[i],
                        i == list.selected,
                        TransitionMenuCommand::SetStingerMedia(list.ids[i]),
                    ));
                }
            }
            Row::Element(key) => {
                let Some(sp) = self.spec(key) else { return };
                let EffectParamKind::Choice(titles) = &sp.kind else { return };
                let current = sp.kind.choice_index(tr.param(key));
                for (i, title) in titles.iter().enumerate() {
                    items.push(self.command_row(
                        title,
                        i as i64 == current,
                        TransitionMenuCommand::SetElementParam(key.clone(), i as f64),
                    ));
                }
            }
            Row::Color => self.pick_color(r, TransitionControlsLogic::color(s), anchor),
            Row::BorderColor => self.pick_color(r, TransitionControlsLogic::border_color(s), anchor),
            _ => {}
        }
        if !items.is_empty() {
            self.menus.push(MenuRequest { items, anchor });
        }
    }

    /// Runs the rows the user picked in a menu this panel asked for (the host calls it when the menu closes).
    pub fn run_menu_commands(&mut self, session: &mut EditorSession) {
        for cmd in self.sink.drain() {
            match cmd {
                TransitionMenuCommand::SetKind(k) => self.actions.set_kind(session, k),
                TransitionMenuCommand::SetAlignment(a) => self.actions.set_alignment(session, a),
                TransitionMenuCommand::SetEasing(c) => {
                    self.custom_open = false;
                    self.actions.set_easing(session, c);
                }
                TransitionMenuCommand::EditCustomCurve => self.edit_custom_curve(session),
                TransitionMenuCommand::SaveToMyCurves => {
                    if let Some(s) = &self.shown {
                        let curve = s.transition.effective_easing();
                        self.requests.push(TransitionControlsRequest::SaveToMyCurves(curve));
                    }
                }
                TransitionMenuCommand::SetDirection(d) => self.actions.set_direction(session, d),
                TransitionMenuCommand::SetStingerMedia(m) => self.actions.set_stinger_media(session, m),
                TransitionMenuCommand::SetElementParam(key, v) => self.actions.set_element_param(session, &key, v),
                TransitionMenuCommand::Reset => self.actions.reset(session, &self.defaults),
                TransitionMenuCommand::UseAsDefault => self.actions.use_as_default(session),
                TransitionMenuCommand::ResetDefaultToFactory => self.actions.reset_default_to_factory(session),
            }
        }
    }

    /// The easing chips, in order; `None` is Custom (it opens the curve to drag).
    pub fn ease_chips() -> [(&'static str, Option<EasingCurve>); 5] {
        [
            ("Linear", Some(EasingCurve::linear())),
            ("Ease In", Some(EasingCurve::ease_in())),
            ("Ease Out", Some(EasingCurve::ease_out())),
            ("Ease In & Out", Some(EasingCurve::ease_in_out())),
            ("Custom", None),
        ]
    }

    /// The slot width of chip `i`.
    fn chip_slot(&self, i: usize) -> f64 {
        self.chip_widths
            .get(i)
            .copied()
            .unwrap_or_else(|| (self.size.width - self.value_x() - Self::PAD).max(0.0) / Self::CHIP_COUNT as f64)
    }

    /// The chip under `x` in the Easing row's frame `f`.
    pub fn chip_at(&self, x: f64, _f: CGRect) -> usize {
        let mut left = self.value_x();
        for i in 0..Self::CHIP_COUNT - 1 {
            left += self.chip_slot(i);
            if x < left {
                return i;
            }
        }
        Self::CHIP_COUNT - 1
    }

    /// Chip `i` of the Easing row in frame `f`.
    fn chip_rect(&self, f: CGRect, i: usize) -> CGRect {
        let x: f64 = self.value_x() + (0..i).map(|k| self.chip_slot(k)).sum::<f64>();
        CGRect::new(x, f.min_y(), self.chip_slot(i) - 4.0, f.height)
    }

    /// Kit: chips as wide as their label when they all fit; too narrow a dock gets equal icon-only chips.
    fn layout_chips(&mut self, c: &mut Canvas) {
        let fs = f64::from(type_size::BODY);
        let names = Self::chip_names().into_iter().chain(["My Curves"]);
        // curve (26) or star (14) + 5 gap + label + 6 + 8 padding + 4 between chips
        let natural: Vec<f64> = names
            .enumerate()
            .map(|(i, n)| {
                let lead = if i == Self::CHIP_COUNT - 1 { 14.0 } else { 26.0 };
                lead + 5.0 + c.size_of(&SQL10n::string(n), fs, 0).width.ceil() + 6.0 + 8.0 + 4.0
            })
            .collect();
        let total = (self.size.width - self.value_x() - Self::PAD).max(0.0);
        if natural.iter().sum::<f64>() <= total {
            self.chip_widths = natural;
            self.chips_labeled = true;
        } else {
            self.chip_widths = vec![total / Self::CHIP_COUNT as f64; Self::CHIP_COUNT];
            self.chips_labeled = false;
        }
    }

    fn draw_ease_chips(&self, c: &mut Canvas, f: CGRect, shown: &EasingCurve) {
        let t = self.theme;
        let chips = Self::ease_chips();
        let current = if self.curve_visible() {
            TransitionControlsLogic::custom_easing_index()
        } else {
            TransitionControlsLogic::easing_index(shown)
        };
        let current_name = TransitionControlsLogic::easings().get(current).map(|e| e.display_name().to_string());
        for (i, (_, curve)) in chips.iter().enumerate() {
            let on = match curve {
                Some(cv) => current_name.as_deref() == Some(cv.display_name()),
                None => current_name.is_none(),
            };
            let r = self.chip_rect(f, i);
            c.stone_chip(r, on, false, Touch::default(), &t);
            // The mini curve: the curve itself (Custom shows the one that is set).
            let src = curve.clone().unwrap_or_else(|| shown.clone());
            // Kit: the mini curve and the name side by side; a chip too narrow for the name keeps the curve alone.
            let labeled = self.chips_labeled;
            let plot_w = if labeled { 26.0 } else { (r.width - 12.0).max(1.0) };
            let plot = CGRect::new(r.min_x() + 6.0, r.min_y() + 4.0, plot_w, (r.height - 8.0).max(1.0));
            let pts: Vec<CGPoint> = (0..=16)
                .map(|k| {
                    let x = f64::from(k) / 16.0;
                    let y = src.progress(x).clamp(-0.2, 1.2);
                    CGPoint::new(plot.min_x() + plot.width * x, plot.max_y() - plot.height * y)
                })
                .collect();
            c.stroke_polyline(&pts, 1.4, if on { t.label() } else { t.label3() });
            if labeled {
                c.draw_text_in(
                    &SQL10n::string(chips[i].0),
                    CGRect::new(plot.max_x() + 5.0, r.min_y(), (r.max_x() - plot.max_x() - 8.0).max(0.0), r.height),
                    f64::from(type_size::BODY),
                    if on { t.label() } else { t.label2() },
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
        }
        // The ☆ My Curves chip: the saved curves, as a menu.
        let r = self.chip_rect(f, Self::CHIP_COUNT - 1);
        c.stone_chip(r, false, true, Touch::default(), &t);
        let star = CGRect::new(r.min_x() + 6.0, r.min_y(), 14.0, r.height);
        c.draw_icon(SQIcon::Star, CGPoint::new(star.min_x(), star.mid_y() - 7.0), 14.0, t.label3(), None);
        if self.chips_labeled {
            c.draw_text_in(
                &SQL10n::string("My Curves"),
                CGRect::new(star.max_x() + 5.0, r.min_y(), (r.max_x() - star.max_x() - 8.0).max(0.0), r.height),
                f64::from(type_size::BODY),
                t.label2(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
    }

    /// The chip names for tooltips and tests.
    pub fn chip_names() -> Vec<&'static str> {
        Self::ease_chips().iter().map(|c| c.0).collect()
    }

    /// Custom: starts from the curve that is shown (a preset's handles), so Custom never jumps; the curve then shows inline
    /// under the Easing rows (`curve_visible`).
    fn edit_custom_curve(&mut self, session: &mut EditorSession) {
        let Some(easing) = self.shown.as_ref().map(|s| s.transition.effective_easing()) else { return };
        self.custom_open = true;
        if easing.matching_transition_preset().is_some()
            && let Some(c) = EasingCurve::transition_custom(&easing.shape())
        {
            self.actions.set_easing(session, c);
        }
    }

    /// One picker session is one undo step: the first pick starts it, the rest join it.
    fn pick_color(&mut self, row: &Row, rgb: [u8; 3], anchor: CGRect) {
        self.pick_open = false;
        self.requests.push(TransitionControlsRequest::PickColor {
            row: row.clone(),
            current: EffectColor {
                red: f64::from(rgb[0]) / 255.0,
                green: f64::from(rgb[1]) / 255.0,
                blue: f64::from(rgb[2]) / 255.0,
                alpha: 1.0,
            },
            anchor,
        });
    }

    /// The picker's answer: every pick, `None` when the picker closes.
    pub fn color_picked(&mut self, session: &mut EditorSession, row: &Row, color: Option<EffectColor>) {
        let Some(color) = color else {
            self.pick_open = false;
            return;
        };
        let byte = |x: f64| (x * 255.0).round().clamp(0.0, 255.0) as u8;
        let rgb = vec![byte(color.red), byte(color.green), byte(color.blue)];
        let cont = self.pick_open;
        match row {
            Row::Color => self.actions.set_color(session, rgb, cont),
            Row::BorderColor => self.actions.set_border_color(session, rgb, cont),
            _ => {}
        }
        self.pick_open = true;
    }

    fn show_context_menu(&mut self, p: CGPoint) {
        let Some(s) = self.shown.as_ref().filter(|s| !s.is_layer) else { return };
        let push = |cmd: TransitionMenuCommand| {
            let sink = self.sink.clone();
            Rc::new(move || sink.push(cmd.clone())) as Rc<dyn Fn()>
        };
        let items = TransitionControlsLogic::context_items(
            s.transition.kind,
            s.has_user_default,
            push(TransitionMenuCommand::Reset),
            push(TransitionMenuCommand::UseAsDefault),
            push(TransitionMenuCommand::ResetDefaultToFactory),
        );
        if !items.is_empty() {
            self.menus.push(MenuRequest { items, anchor: CGRect::new(p.x, p.y, 0.0, 0.0) });
        }
    }

    /// Keys for the focused field: typing, arrows, Return / Esc; Tab moves to the next field.
    pub fn key(&mut self, session: &mut EditorSession, cx: &mut UiCx, k: InputKey, modifiers: InputModifiers) -> bool {
        let Some(r) = self.focused.clone() else { return false };
        let Some(mut fd) = self.fields.remove(&r) else { return false };
        if k == TAB {
            let ev = fd.resign_focus(cx);
            self.fields.insert(r.clone(), fd);
            self.apply(session, ev, &r);
            let order: Vec<Row> = self
                .rows
                .iter()
                .enumerate()
                .filter(|(i, x)| self.row_visible(*i) && self.fields.contains_key(*x))
                .map(|(_, x)| x.clone())
                .collect();
            if let Some(i) = order.iter().position(|x| *x == r).filter(|_| !order.is_empty()) {
                let step = if modifiers.contains(InputModifiers::SHIFT) { order.len() - 1 } else { 1 };
                let next = order[(i + step) % order.len()].clone();
                self.focused = Some(next.clone());
                if let Some(nf) = self.fields.get_mut(&next) {
                    nf.begin_editing();
                }
            }
            return true;
        }
        let (ev, used) = fd.key_used(k, modifiers, cx.now, cx);
        let ended = !fd.is_editing() && matches!(k, InputKey::Enter | InputKey::Escape);
        self.fields.insert(r.clone(), fd);
        self.apply(session, ev, &r);
        if ended {
            self.focused = None;
        }
        used
    }

    pub fn resign_focus(&mut self, session: &mut EditorSession, cx: &mut UiCx) {
        let Some(r) = self.focused.take() else { return };
        if let Some(mut fd) = self.fields.remove(&r) {
            let ev = fd.resign_focus(cx);
            self.fields.insert(r.clone(), fd);
            self.apply(session, ev, &r);
        }
    }

    /// Ends idle arrow / wheel bursts.
    pub fn tick(&mut self, session: &mut EditorSession, now: f64) {
        let keys: Vec<Row> = self.fields.keys().cloned().collect();
        for r in keys {
            let Some(mut fd) = self.fields.remove(&r) else { continue };
            let ev = fd.tick(now);
            self.fields.insert(r.clone(), fd);
            if !ev.is_empty() {
                self.apply(session, ev, &r);
            }
        }
    }

    /// Hover tips (the Mac tool tips and accessibility labels).
    pub fn help(&self, p: CGPoint) -> Option<String> {
        let text = match self.control_at(p)? {
            Control::Reset => {
                TransitionControlsLogic::reset_tip(self.shown.as_ref().is_some_and(|s| s.has_user_default))
            }
            Control::SavePreset => "Save as Preset",
            Control::Reverse => "Reverse transition",
            Control::Row(Row::BorderColor) => "Border Color",
            Control::Row(Row::Color) => "Color",
            Control::Row(Row::StingerClip) => "Stinger Clip",
            Control::Row(Row::StingerCut) | Control::Track(Row::StingerCut) => "Stinger Cut Point",
            Control::Row(Row::Duration) => "Transition duration",
            _ => return None,
        };
        Some(SQL10n::string(text))
    }

    // MARK: Pixels

    /// Host glue: an `InputEvent` in pixels, the panel at `origin` (points) in the window, `scale` pixels per point.
    pub fn handle(
        &mut self,
        session: &mut EditorSession,
        cx: &mut UiCx,
        e: &InputEvent,
        scale: f32,
        origin: CGPoint,
    ) -> bool {
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x / scale) - origin.x, f64::from(y / scale) - origin.y);
        match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = pt(x, y);
                let n = self.clicks.press(p.x as f32, p.y as f32, cx.now);
                self.mouse_down(session, cx, p, Some(n), modifiers);
            }
            InputEvent::MouseDragged { x, y, .. } => self.mouse_dragged(session, cx, pt(x, y), InputModifiers::NONE),
            InputEvent::MouseUp { x, y } => self.mouse_up(session, cx, pt(x, y)),
            InputEvent::MouseMoved { x, y } => {
                self.mouse_moved(Some(pt(x, y)));
                let tip = self.help(pt(x, y));
                cx.hover.offer_tip(tip.as_deref());
            }
            InputEvent::Scroll { x, y, dy, modifiers, .. } => {
                let p = pt(x, y);
                let field = match self.control_at(p) {
                    Some(Control::Row(r)) => self.fields.remove(&r).map(|fd| (r, fd)),
                    _ => None,
                };
                let Some((r, mut fd)) = field else { return self.scroll_by(f64::from(dy / scale)) };
                let focused = self.focused.as_ref() == Some(&r);
                let (used, ev) = fd.scroll(f64::from(dy / scale), true, modifiers, focused, cx.now, cx);
                self.fields.insert(r.clone(), fd);
                self.apply(session, ev, &r);
                return used || self.scroll_by(f64::from(dy / scale));
            }
            InputEvent::KeyDown { key, modifiers } => return self.key(session, cx, key, modifiers),
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_effects::transition::{NewTransition, TimelineTransitions};
    use sq_core_model::{Clip, Project, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange};
    use sq_editor_session::SessionDeps;

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn f(n: i64) -> Time {
        fd() * n
    }

    fn pt(x: f64, y: f64) -> CGPoint {
        CGPoint::new(x, y)
    }

    fn make_session(kind: TransitionKind) -> (EditorSession, Id) {
        make_session_sided(kind, false)
    }

    /// `tail_only`: the transition sits on the end edge of clip A alone (a tail fade) instead of the A/B cut.
    fn make_session_sided(kind: TransitionKind, tail_only: bool) -> (EditorSession, Id) {
        let mut ids = SequentialIds::default();
        let mut v = Track::new(Id::from_u128(100), TrackKind::Video);
        let mut a = Clip::new(
            Id::from_u128(1),
            "A",
            Id::from_u128(901),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, f(120)),
            Time::ZERO,
        );
        a.media_duration = Some(f(240));
        let mut b = Clip::new(
            Id::from_u128(2),
            "B",
            Id::from_u128(902),
            TrackKind::Video,
            TimeRange::new(f(60), f(120)),
            f(120),
        );
        b.media_duration = Some(f(240));
        assert!(v.overwrite(a.clone(), &mut ids).is_ok() && v.overwrite(b.clone(), &mut ids).is_ok());
        let mut t = Timeline::new(Id::from_u128(50), "Main", SequenceFormat::new(fd()), vec![v]);
        let new = NewTransition {
            kind,
            track: Id::from_u128(100),
            outgoing: Some(a.id),
            incoming: (!tail_only).then_some(b.id),
            duration: f(30),
            alignment: TransitionAlignment::Center,
            custom_before: Time::ZERO,
        };
        let id = t.add_transition(&new, &mut ids).unwrap_or_else(|e| panic!("transition: {e:?}"));
        let project = Project::new(Id::from_u128(1), "P", Vec::new(), vec![t]);
        let dir = std::env::temp_dir().join("sq-transition-draw-tests");
        let mut ses = EditorSession::new(project, SessionDeps::headless(dir));
        ses.select_transition(Some(id), false);
        (ses, id)
    }

    fn panel(ses: &EditorSession, id: Id) -> TransitionControlsDraw {
        let mut actions = TransitionControlsActions::new();
        actions.selected_transition = Some(id);
        let mut p = TransitionControlsDraw::new(actions);
        p.size = CGSize::new(360.0, 500.0);
        let shown = p.actions.shown(ses);
        p.show(shown);
        let mut c = Canvas::with_size(360.0, 500.0, None, 1.0);
        p.draw(&mut c, &mut UiCx::new());
        p
    }

    fn tr(ses: &EditorSession, id: Id) -> sq_core_model::Transition {
        ses.active_timeline().and_then(|t| t.transition(id)).map(|x| x.1).unwrap_or_else(|| panic!("no transition"))
    }

    #[test]
    fn rows_follow_the_kind_as_on_the_mac() {
        let (ses, id) = make_session(TransitionKind::SoftWipe);
        let mut actions = TransitionControlsActions::new();
        actions.selected_transition = Some(id);
        let Some(s) = actions.shown(&ses) else { panic!("nothing shown") };
        let rows = TransitionControlsLogic::rows(&s);
        assert!(rows[0] == Row::Duration && rows[1] == Row::Alignment);
        assert!(rows.contains(&Row::Direction) && rows.contains(&Row::Softness));
        assert!(rows.contains(&Row::Border) && rows.contains(&Row::BorderColor));
        assert!(!rows.contains(&Row::Kind) && !rows.contains(&Row::Color) && !rows.contains(&Row::StingerClip));
        let mut layer = s.clone();
        layer.is_layer = true;
        let layer_rows = TransitionControlsLogic::rows(&layer);
        assert!(layer_rows[0] == Row::Kind && !layer_rows.contains(&Row::Border));
        assert_eq!(TransitionControlsLogic::subtitle(&s), "Video Transition");
        assert_eq!(TransitionControlsLogic::subtitle(&layer), "Transition Layer \u{b7} everything below");
        assert_eq!(
            TransitionControlsLogic::alignment_options(&s),
            [TransitionAlignment::Center, TransitionAlignment::StartAtCut, TransitionAlignment::EndAtCut]
        );
    }

    #[test]
    fn nothing_shown_without_a_selected_transition() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        ses.select_transition(None, false);
        let mut p = panel(&ses, id);
        p.actions.selected_transition = None;
        let shown = p.actions.shown(&ses);
        p.show(shown);
        assert!(p.shown().is_none());
        assert!(p.control_at(pt(120.0, 80.0)).is_none());
    }

    #[test]
    fn softness_track_drag_is_one_undo_step() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let before = tr(&ses, id).effective_softness();
        let mut p = open_panel(&ses, id);
        let mut cx = UiCx::new();
        let track = p.frame(&Control::Track(Row::Softness));
        assert!(track.width > 0.0);
        p.mouse_down(
            &mut ses,
            &mut cx,
            pt(track.min_x() + track.width * 0.2, track.mid_y()),
            Some(1),
            InputModifiers::NONE,
        );
        p.mouse_dragged(&mut ses, &mut cx, pt(track.min_x() + track.width * 0.6, track.mid_y()), InputModifiers::NONE);
        p.mouse_dragged(&mut ses, &mut cx, pt(track.max_x(), track.mid_y()), InputModifiers::NONE);
        p.mouse_up(&mut ses, &mut cx, pt(track.max_x(), track.mid_y()));
        assert!((tr(&ses, id).effective_softness() - 0.5).abs() < 1e-9);
        assert!(ses.undo());
        assert!((tr(&ses, id).effective_softness() - before).abs() < 1e-9);
    }

    #[test]
    fn typed_duration_sets_whole_frames() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = panel(&ses, id);
        let mut cx = UiCx::new();
        let field = p.frame(&Control::Row(Row::Duration));
        let mid = pt(field.mid_x(), field.mid_y());
        p.mouse_down(&mut ses, &mut cx, mid, Some(1), InputModifiers::NONE);
        p.mouse_up(&mut ses, &mut cx, mid);
        assert_eq!(p.focused(), Some(&Row::Duration));
        p.key(&mut ses, &mut cx, InputKey::Character('a'), InputModifiers::COMMAND);
        for ch in "15".chars() {
            cx.typed_text = Some(ch.to_string());
            p.key(&mut ses, &mut cx, InputKey::Character(ch), InputModifiers::NONE);
        }
        cx.typed_text = None;
        p.key(&mut ses, &mut cx, InputKey::Enter, InputModifiers::NONE);
        assert_eq!(tr(&ses, id).duration, f(15));
    }

    #[test]
    fn direction_popup_and_reverse_box() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = open_panel(&ses, id);
        let mut cx = UiCx::new();
        let d = p.frame(&Control::Row(Row::Direction));
        p.mouse_down(&mut ses, &mut cx, pt(d.mid_x(), d.mid_y()), Some(1), InputModifiers::NONE);
        p.mouse_up(&mut ses, &mut cx, pt(d.mid_x(), d.mid_y()));
        let menu = p.menus.last().map(|m| m.items.clone()).unwrap_or_default();
        let titles: Vec<String> = menu.iter().map(|i| i.title.clone()).collect();
        let expected: Vec<String> = ALL_DIRECTIONS.iter().map(|d| SQL10n::string(d.name())).collect();
        assert_eq!(titles, expected);
        let current = tr(&ses, id).effective_direction();
        let other = ALL_DIRECTIONS.iter().position(|d| *d != current).unwrap_or(0);
        if let Some(a) = &menu[other].action {
            a();
        }
        p.run_menu_commands(&mut ses);
        assert_eq!(tr(&ses, id).effective_direction(), ALL_DIRECTIONS[other]);
        let shown = p.actions.shown(&ses);
        p.show(shown);
        let r = p.frame(&Control::Reverse);
        p.mouse_down(&mut ses, &mut cx, pt(r.min_x() + 4.0, r.mid_y()), Some(1), InputModifiers::NONE);
        p.mouse_up(&mut ses, &mut cx, pt(r.min_x() + 4.0, r.mid_y()));
        assert!(tr(&ses, id).is_reversed());
    }

    fn click_chip(p: &mut TransitionControlsDraw, ses: &mut EditorSession, i: usize) {
        let e = p.frame(&Control::Row(Row::Easing));
        let x = p.chip_rect(e, i).mid_x();
        let mut cx = UiCx::new();
        p.mouse_down(ses, &mut cx, pt(x, e.mid_y()), Some(1), InputModifiers::NONE);
        p.mouse_up(ses, &mut cx, pt(x, e.mid_y()));
    }

    /// The panel with the Options fold open (the rows behind it take clicks).
    fn open_panel(ses: &EditorSession, id: Id) -> TransitionControlsDraw {
        let mut p = panel(ses, id);
        p.options_open = true;
        let mut c = Canvas::with_size(360.0, 500.0, None, 1.0);
        p.draw(&mut c, &mut UiCx::new());
        p
    }

    fn short_panel(ses: &EditorSession, id: Id) -> TransitionControlsDraw {
        let mut p = open_panel(ses, id);
        p.size = CGSize::new(360.0, 200.0);
        let mut c = Canvas::with_size(360.0, 200.0, None, 1.0);
        p.draw(&mut c, &mut UiCx::new());
        p
    }

    #[test]
    fn content_taller_than_the_frame_scrolls_one_to_one_and_clamps() {
        let (ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = short_panel(&ses, id);
        let max = p.content_height() - 200.0;
        assert!(max > 0.0, "the content must not fit");
        let y0 = p.frame(&Control::Row(Row::Duration)).min_y();
        assert!(p.scroll_by(-30.0));
        assert_eq!(p.scroll_y, 30.0);
        assert_eq!(p.frame(&Control::Row(Row::Duration)).min_y(), y0 - 30.0, "rows follow the wheel 1:1");
        assert!(p.scroll_by(-10_000.0));
        assert_eq!(p.scroll_y, max, "clamped at the end");
        assert!(!p.scroll_by(-5.0), "nothing moves past the end");
        assert!(p.scroll_by(10_000.0));
        assert_eq!(p.scroll_y, 0.0, "clamped at the top");
        assert!(!p.scroll_by(5.0));
    }

    #[test]
    fn a_taller_dock_pulls_the_offset_back_and_content_height_ignores_it() {
        let (ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = short_panel(&ses, id);
        let h = p.content_height();
        p.scroll_by(-10_000.0);
        assert_eq!(p.content_height(), h, "content height does not depend on the offset");
        p.size = CGSize::new(360.0, 500.0);
        let mut c = Canvas::with_size(360.0, 500.0, None, 1.0);
        p.draw(&mut c, &mut UiCx::new());
        assert_eq!(p.scroll_y, 0.0, "everything fits: back to the top");
    }

    #[test]
    fn hit_testing_follows_the_offset_and_the_frame_edge() {
        let (ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = short_panel(&ses, id);
        let before = p.frame(&Control::Row(Row::Duration));
        assert_eq!(p.control_at(pt(before.mid_x(), before.mid_y())), Some(Control::Row(Row::Duration)));
        p.scroll_by(-before.max_y() - 4.0);
        assert!(
            p.control_at(pt(before.mid_x(), before.mid_y())).is_none()
                || p.control_at(pt(before.mid_x(), before.mid_y())) != Some(Control::Row(Row::Duration))
        );
        let moved = p.frame(&Control::Row(Row::Duration));
        assert!(moved.max_y() <= 0.0 || moved.min_y() < before.min_y());
        // A row scrolled past the bottom edge takes no click.
        let (ses2, id2) = make_session(TransitionKind::SoftWipe);
        let q = short_panel(&ses2, id2);
        let last = q.frame(&Control::Row(q.rows().last().unwrap().clone()));
        assert!(last.min_y() > 200.0, "the last row sits below the short frame");
        assert!(q.control_at(pt(last.mid_x(), last.mid_y())).is_none());
    }

    #[test]
    fn easing_chips_pick_a_curve_and_custom_opens_the_curve_to_drag() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = panel(&ses, id);
        assert_eq!(TransitionControlsDraw::chip_names(), ["Linear", "Ease In", "Ease Out", "Ease In & Out", "Custom"]);
        click_chip(&mut p, &mut ses, 1);
        assert_eq!(tr(&ses, id).effective_easing().display_name(), "Ease In");
        assert!(p.menus.is_empty(), "a chip is not a popup");
        let shown = p.actions.shown(&ses);
        p.show(shown);
        assert!(!p.curve_visible(), "a preset shows no inline curve");
        click_chip(&mut p, &mut ses, 4);
        assert!(p.requests.is_empty(), "Custom opens no popover");
        // The shown preset's handles become a hand-drawn curve, so Custom never jumps (the Mac `easingPicked`).
        assert_eq!(tr(&ses, id).effective_easing().name, "Custom");
        let shown = p.actions.shown(&ses);
        p.show(shown);
        assert!(p.curve_visible(), "Custom shows its curve inline");
        let f = p.curve_frame();
        assert!(f.height > 0.0 && f.min_y() > p.frame(&Control::Row(Row::Easing)).max_y() - 1.0);
    }

    #[test]
    fn dragging_a_handle_of_the_inline_curve_edits_the_easing_in_one_undo_step() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = panel(&ses, id);
        click_chip(&mut p, &mut ses, 4);
        let shown = p.actions.shown(&ses);
        p.show(shown);
        let before = tr(&ses, id).effective_easing();
        let f = p.curve_frame();
        let mut hit = None;
        'scan: for yi in 0..(f.height as i64 / 2) {
            for xi in 0..(f.width as i64 / 2) {
                let q = pt(xi as f64 * 2.0, yi as f64 * 2.0);
                if p.curve.handle_at(q).is_some() {
                    hit = Some(q);
                    break 'scan;
                }
            }
        }
        let q = hit.expect("a handle is on the curve");
        let at = |dx: f64| pt(f.x + q.x + dx, f.y + q.y);
        let mut cx = UiCx::new();
        p.mouse_down(&mut ses, &mut cx, at(0.0), Some(1), InputModifiers::NONE);
        p.mouse_dragged(&mut ses, &mut cx, at(20.0), InputModifiers::NONE);
        p.mouse_dragged(&mut ses, &mut cx, at(35.0), InputModifiers::NONE);
        p.mouse_up(&mut ses, &mut cx, at(35.0));
        assert_ne!(tr(&ses, id).effective_easing().shape(), before.shape(), "the handle moved the curve");
    }

    #[test]
    fn rows_run_duration_alignment_easing_then_the_options() {
        let (ses, id) = make_session(TransitionKind::SoftWipe);
        let p = panel(&ses, id);
        let rows = p.rows();
        assert_eq!(&rows[..3], &[Row::Duration, Row::Alignment, Row::Easing]);
        let pos = |r: Row| rows.iter().position(|x| *x == r);
        assert!(pos(Row::Softness) > pos(Row::Easing));
    }

    #[test]
    fn my_curves_menu_lists_saved_curves_and_saves_the_shown_one() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = panel(&ses, id);
        p.my_curves = vec![EasingCurve::fast_start()];
        let mut cx = UiCx::new();
        let f = p.frame(&Control::Row(Row::Easing));
        let at = pt(p.chip_rect(f, 5).mid_x(), f.mid_y());
        p.mouse_down(&mut ses, &mut cx, at, Some(1), InputModifiers::NONE);
        p.mouse_up(&mut ses, &mut cx, at);
        let menu = p.menus.last().map(|m| m.items.clone()).unwrap_or_default();
        assert_eq!(menu.len(), 2);
        assert!(menu[0].title.starts_with('\u{2606}'));
        if let Some(a) = &menu[0].action {
            a();
        }
        p.run_menu_commands(&mut ses);
        assert_eq!(tr(&ses, id).effective_easing().display_name(), "Fast Start");
        let shown = p.actions.shown(&ses);
        p.show(shown);
        if let Some(a) = &menu[1].action {
            a();
        }
        p.run_menu_commands(&mut ses);
        assert!(
            p.requests
                .iter()
                .any(|r| matches!(r, TransitionControlsRequest::SaveToMyCurves(c) if c.display_name() == "Fast Start"))
        );
    }

    #[test]
    fn right_click_offers_the_default_menu() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = panel(&ses, id);
        let mut cx = UiCx::new();
        p.mouse_down(&mut ses, &mut cx, pt(200.0, 20.0), Some(1), InputModifiers::SECONDARY);
        let menu = p.menus.last().map(|m| m.items.clone()).unwrap_or_default();
        assert_eq!(menu.first().map(|m| m.title.clone()), Some(SQL10n::string("Reset")));
        assert!(menu.iter().any(|m| m.title == SQL10n::string("Reset Default to Factory") && !m.is_enabled));
    }

    #[test]
    fn color_well_session_is_one_undo_step() {
        let (mut ses, id) = make_session(TransitionKind::DipToColour);
        let mut p = panel(&ses, id);
        let mut cx = UiCx::new();
        let w = p.frame(&Control::Row(Row::Color));
        p.mouse_down(&mut ses, &mut cx, pt(w.mid_x(), w.mid_y()), Some(1), InputModifiers::NONE);
        let color = |r, g, b| EffectColor { red: r, green: g, blue: b, alpha: 1.0 };
        p.color_picked(&mut ses, &Row::Color, Some(color(1.0, 0.0, 0.0)));
        p.color_picked(&mut ses, &Row::Color, Some(color(0.0, 0.0, 1.0)));
        p.color_picked(&mut ses, &Row::Color, None);
        assert_eq!(tr(&ses, id).color, Some(vec![0, 0, 255]));
        assert!(ses.undo());
        let c = tr(&ses, id).color;
        assert!(c != Some(vec![0, 0, 255]) && c != Some(vec![255, 0, 0]));
    }

    #[test]
    fn alignment_is_a_start_center_end_switch_and_the_buttons_sit_in_the_header_line() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = panel(&ses, id);
        let titles: Vec<&str> = p.alignment_segments().iter().map(|s| s.1).collect();
        assert_eq!(titles, ["Start", "Center", "End"]);
        let f = p.frame(&Control::Row(Row::Alignment));
        let mut cx = UiCx::new();
        let end = CGPoint::new(f.max_x() - 4.0, f.mid_y());
        p.mouse_down(&mut ses, &mut cx, end, Some(1), InputModifiers::NONE);
        assert_eq!(tr(&ses, id).alignment, TransitionAlignment::EndAtCut);
        // Header line: Save as Preset... and Reset share the first line, above the first row.
        let (save, reset) = (p.frame(&Control::SavePreset), p.frame(&Control::Reset));
        assert!(save.max_y() <= p.frame(&Control::Row(Row::Duration)).min_y() && reset.min_y() == save.min_y());
        assert_eq!(reset.max_x(), p.size.width - TransitionControlsDraw::PAD);
    }

    #[test]
    fn a_one_sided_transition_shows_its_alignment_instead_of_a_blank_box() {
        let (ses, id) = make_session_sided(TransitionKind::CrossDissolve, true);
        let p = panel(&ses, id);
        // No switch and no choice for a tail fade, but the disabled box names where it sits.
        assert!(p.alignment_segments().is_empty());
        let shown = p.shown.clone().unwrap_or_else(|| panic!("a transition is shown"));
        assert!(!TransitionControlsLogic::is_two_sided(&shown));
        assert_eq!(tr(&ses, id).alignment, TransitionAlignment::Center);
        assert_eq!(TransitionControlsLogic::shown_alignment(&shown), TransitionAlignment::EndAtCut);
        assert_eq!(TransitionControlsLogic::shown_alignment(&shown).name(), "End at Cut");
        // A two-sided one shows what it has.
        let (ses2, id2) = make_session(TransitionKind::SoftWipe);
        let shown2 = panel(&ses2, id2).shown.clone().unwrap_or_else(|| panic!("a transition is shown"));
        assert_eq!(TransitionControlsLogic::shown_alignment(&shown2), TransitionAlignment::Center);
    }

    fn click(p: &mut TransitionControlsDraw, ses: &mut EditorSession, at: CGPoint) {
        let mut cx = UiCx::new();
        p.mouse_down(ses, &mut cx, at, Some(1), InputModifiers::NONE);
        p.mouse_up(ses, &mut cx, at);
    }

    fn redraw(p: &mut TransitionControlsDraw) {
        let mut c = Canvas::with_size(p.size.width as f32, p.size.height as f32, None, 1.0);
        p.draw(&mut c, &mut UiCx::new());
    }

    #[test]
    fn options_are_folded_by_default_and_the_bar_opens_them() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = panel(&ses, id);
        assert!(p.has_options() && !p.options_open);
        assert_eq!(p.frame(&Control::Row(Row::Softness)).height, 0.0, "a folded row has no frame");
        assert!(p.options_summary().starts_with("Direction"), "{}", p.options_summary());
        let bar = p.frame(&Control::Options);
        assert!(bar.min_y() >= p.frame(&Control::Row(Row::Easing)).max_y());
        click(&mut p, &mut ses, pt(bar.mid_x(), bar.mid_y()));
        redraw(&mut p);
        assert!(p.options_open);
        let soft = p.frame(&Control::Row(Row::Softness));
        assert!(soft.height > 0.0 && soft.min_y() > bar.max_y());
        click(&mut p, &mut ses, pt(bar.mid_x(), bar.mid_y()));
        assert!(!p.options_open);
    }

    #[test]
    fn duration_shows_frames_then_seconds_and_a_custom_curve_offers_save_to_my_curves() {
        let (mut ses, id) = make_session(TransitionKind::SoftWipe);
        let mut p = panel(&ses, id);
        let fd = p.fields.get(&Row::Duration).map(|f| (f.value_formatter.as_ref().map(|g| g(30.0)), f.value));
        assert_eq!(fd, Some((Some("30".to_string()), 30.0)));
        assert!(p.frame(&Control::Row(Row::Duration)).width <= 60.0);
        assert!(p.frame(&Control::SaveCurve).width > 0.0 || !p.curve_visible());
        click_chip(&mut p, &mut ses, 4);
        let shown = p.actions.shown(&ses);
        p.show(shown);
        redraw(&mut p);
        assert!(p.curve_visible());
        let b = p.frame(&Control::SaveCurve);
        assert!(b.min_y() > p.curve_frame().max_y());
        click(&mut p, &mut ses, pt(b.mid_x(), b.mid_y()));
        assert!(p.requests.iter().any(|r| matches!(r, TransitionControlsRequest::SaveToMyCurves(_))));
    }
}
