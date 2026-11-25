// Swift: EffectControlsDrawPanel.swift
//! Effect Controls on the shared toolkit (the Windows port plan, "Panel status: Inspector"): `EffectControlsView` translated
//! row by row onto the draw-kit Canvas. The model, the row layout (`EffectControlsLayout::rows`), the grid (`ControlsGrid`)
//! and every action are the Mac ones; only drawing and event glue are new. Coordinates are points, y down, (0, 0) = the
//! panel's top-left.
//!
//! Mapping (docs/rust/session-ui-design.md section 2): the panel does not hold the model, every call gets it. Hooks
//! (`onMenu`, `confirmRemoveKeyframes`, `onPickColor`, `onEaseCurve`, `onMultibandEditor`, the track hooks) are
//! [`PanelEvent`]s the host drains with [`EffectControlsDrawPanel::take_events`]. The hosting of the clip's content section
//! (`ClipSectionsDraw`, `TextBlockDraw`) belongs to the clip sections task and is not wired here.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

use sq_core_model::{EffectColor, EffectParamKind};
use sq_core_time::Id;
use sq_draw::draw_list::Color;
use sq_draw::inspector::scrub_field_control::Event as ScrubEvent;
use sq_draw::theme::{spacing, type_size};
use sq_draw::{
    Canvas, CheckState, ClickCounter, DrawTheme, InputModifiers, InspectorDraw, InspectorTokens, ScrubFieldControl,
    TextAlign, TextFieldControl, UiCx,
};
use sq_editor_session::EffectSection;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize, ControlsGrid};
use sq_uikit::keyframe_control_state::KeyframeControlState;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;

use super::ModelMenu;
use super::effect_controls_draw_rows::WidgetKind;
use super::effect_controls_draw_surfaces::DrawSurface;
use crate::ec::controls_metrics::Portable;
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::layout::{
    EffectControlsLayout, EffectRow, EffectRowKind, EffectRowsRequest, SpeedControl,
};
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty, StopwatchOutcome};
use crate::ec::effect_controls_model::section::EffectSectionExt;
use crate::ec::prelude::*;

/// The row a control belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RowRef {
    /// A property row.
    Property(EffectProperty),
    /// A row of the Speed section.
    Speed(SpeedControl),
    /// The Blend Mode row.
    Blend,
    /// A field of a translated row (`EffectControlsDrawRows`), by widget key.
    Custom(String),
}

// `SpeedControl` has no `Hash`; its discriminant stands in.
impl std::hash::Hash for RowRef {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        std::mem::discriminant(self).hash(state);
        match self {
            RowRef::Property(p) => p.hash(state),
            RowRef::Speed(k) => std::mem::discriminant(k).hash(state),
            RowRef::Blend => {}
            RowRef::Custom(s) => s.hash(state),
        }
    }
}

/// A scrub field: its row and which component of the value.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FieldId {
    /// The row.
    pub row: RowRef,
    /// The component.
    pub component: EffectComponent,
}

/// What the pointer is over.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Target {
    Chevron(EffectSection),
    Eye(EffectSection),
    SectionReset(EffectSection),
    Header(EffectSection),
    Ring(RowRef),
    Previous(RowRef),
    Key(RowRef),
    Next(RowRef),
    Open(RowRef),
    Reset(RowRef),
    Label(RowRef),
    Field(FieldId),
    Link(EffectProperty),
    KeyPick(EffectProperty),
    Checkbox(RowRef),
    Popup(RowRef),
    Well(EffectProperty),
    /// The Edit Curve button next to a motion effect's Curve popup (FB-T3).
    Curve(EffectProperty),
    Row(RowRef),
    /// A control of a translated row, and the enable box of a disclosure row.
    Widget(String),
    WidgetToggle(String),
    /// A control in the head of an opened curve (Value / Speed, the ease chips).
    GraphHead(EffectProperty, super::graph_chips::GraphHead),
    None,
}

impl Target {
    /// The row a target belongs to (`Target.rowRef`).
    pub fn row_ref(&self) -> Option<RowRef> {
        match self {
            Target::Ring(r)
            | Target::Previous(r)
            | Target::Next(r)
            | Target::Key(r)
            | Target::Open(r)
            | Target::Reset(r)
            | Target::Label(r)
            | Target::Checkbox(r)
            | Target::Popup(r)
            | Target::Row(r) => Some(r.clone()),
            Target::Field(id) => Some(id.row.clone()),
            Target::Link(p) | Target::KeyPick(p) | Target::Well(p) | Target::Curve(p) => {
                Some(RowRef::Property(p.clone()))
            }
            _ => None,
        }
    }
}

/// An edit of the clip's speed: it needs the session, so the host applies it ([`SpeedAction::run`]).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SpeedAction {
    /// A drag or burst begins (one undo step).
    Begin,
    /// A new speed in percent.
    Set(f64),
    /// The gesture ends.
    End,
    /// The animation switch; `true` confirms removing the keys.
    ToggleAnimation(bool),
    /// Add or remove a speed key at the playhead.
    ToggleKey,
    /// Reverse on or off.
    SetReversed(bool),
    /// Keep Pitch on or off.
    SetKeepsPitch(bool),
}

impl SpeedAction {
    /// Applies the edit; the result tells the host to ask first when `ToggleAnimation(false)` would remove keys.
    pub fn run(
        self,
        model: &mut EffectControlsModel,
        session: &mut sq_editor_session::EditorSession,
    ) -> Option<StopwatchOutcome> {
        match self {
            SpeedAction::Begin => model.begin_speed_gesture(session),
            SpeedAction::Set(v) => model.set_speed_percent(session, v),
            SpeedAction::End => model.end_speed_gesture(session),
            SpeedAction::ToggleAnimation(confirm) => return Some(model.toggle_speed_animation(session, confirm)),
            SpeedAction::ToggleKey => {
                let _ = model.toggle_speed_key_at_playhead(session);
            }
            SpeedAction::SetReversed(on) => model.set_reversed_clip(session, on),
            SpeedAction::SetKeepsPitch(on) => model.set_keeps_pitch_clip(session, on),
        }
        None
    }
}

/// What a "remove all keyframes?" question is about.
#[derive(Clone, Debug, PartialEq)]
pub enum RemoveKeys {
    /// A property row.
    Property(EffectProperty),
    /// The Speed row.
    Speed,
}

/// Whose color a picker edits.
#[derive(Clone, Debug, PartialEq)]
pub enum ColorTarget {
    /// A color parameter.
    Property(EffectProperty),
    /// The key color of a Color Range mask.
    MaskRange(Id),
}

/// Which curve the ease popover edits.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum EaseCurveTarget {
    /// The speed transition at the playhead.
    SpeedTransition,
    /// A motion effect's Custom curve.
    Motion(Id),
}

/// What the panel asks its host to do.
pub enum PanelEvent {
    /// A popup or a context menu: the rows and the anchor (panel points).
    Menu { menu: ModelMenu, anchor: CGRect },
    /// Turning a parameter's animation off asks first (R29). Host: show `KeyToolPrompt::remove_keyframes(title)`, then call
    /// [`EffectControlsDrawPanel::confirm_remove_keyframes`].
    ConfirmRemoveKeyframes { title: String, what: RemoveKeys },
    /// A color well was clicked: the host opens its picker at `anchor` and reports every change to
    /// [`EffectControlsDrawPanel::color_picked`], `None` when it closes.
    PickColor { current: EffectColor, anchor: CGRect, target: ColorTarget },
    /// The curve popover for `target` at `anchor` (panel points).
    EaseCurve { target: EaseCurveTarget, anchor: CGRect },
    /// "Edit Custom Setup" of a Multiband Compressor.
    MultibandEditor(Id),
    /// The key eyedropper: the host samples the screen and calls [`EffectControlsDrawPanel::key_color_picked`].
    PickKeyColor(EffectProperty),
    /// An edit of the clip's speed (needs the session).
    Speed(SpeedAction),
    /// Track a mask (`onTrackMask`).
    TrackMask { mask: Id, forward: bool },
    /// Track a Magic mask: one frame back or forward, or `None` to stop (`onTrackMagic`).
    TrackMagic { mask: Id, step: Option<bool> },
    /// "Show me where": the playhead goes to this time (the first stretch the Magic mask might slip).
    ShowWeak(sq_core_time::Time),
}

/// Effect Controls rows column.
pub struct EffectControlsDrawPanel {
    /// Heights of the text clip's Arrange and Animation parts the host draws between the rows (0 = none).
    pub text_slots: (f64, f64),
    /// The colors and sizes.
    pub theme: DrawTheme,
    /// Size of the column in points.
    pub size: CGSize,
    /// The vertical scroll offset.
    pub scroll_y: f64,
    pub(crate) rows: Vec<EffectRow>,
    pub(crate) fields: HashMap<FieldId, ScrubFieldControl>,
    pub(crate) focused_field: Option<FieldId>,
    /// Text fields of translated rows (timecodes), by widget key.
    pub(crate) text_fields: HashMap<String, TextFieldControl>,
    pub(crate) focused_text: Option<String>,
    pub(crate) surfaces: HashMap<String, Box<dyn DrawSurface>>,
    pub(crate) custom_specs: HashMap<String, super::effect_controls_draw_rows::FieldSpec>,
    /// Text widths measured while drawing (button titles), by title; estimates are used until a title was drawn once.
    pub(crate) widths: RefCell<HashMap<String, f64>>,
    pub(crate) wanted_widths: RefCell<HashSet<String>>,
    /// True when the host answers `ConfirmRemoveKeyframes`; false removes the keys without asking.
    pub asks_before_removing: bool,
    /// Whether the host can sample the screen for the Key Hue eyedropper.
    pub has_key_sampler: bool,
    /// Properties a variant overrides: their menu offers "Reset to Automatic" (session fact; the host fills it).
    pub automatic_resettable: std::collections::BTreeSet<EffectProperty>,
    /// What the Magic and picture mask tracking shows on the mask track row; the host fills it.
    pub mask_track: super::effect_controls_draw_rows::MaskTrackView,
    /// Whether the last layout had the Magic Mask notice open (closing it lays the rows out again).
    pub(crate) magic_notice_laid_out: bool,
    /// The experimental notices the layout has rows for.
    pub(crate) notices_laid_out: Vec<sq_draw::experimental::Feature>,
    pub(super) events: Vec<PanelEvent>,
    pub(super) hover_point: Option<CGPoint>,
    /// Section titles cut by the last draw, with their full text (the header tooltip).
    pub(crate) cut_titles: HashMap<EffectSection, (String, CGRect)>,
    /// Set while a row is drawn: the pointer is over it (r8:542-545: its reset shows).
    pub(super) pointer_in_row: bool,
    pub(crate) press_target: Target,
    pub(super) press_point: CGPoint,
    pub(super) press_modifiers: InputModifiers,
    pub(super) reordering: Option<(EffectSection, Option<usize>)>,
    pub(super) clicks: ClickCounter,
    pub(super) scrolled_clip: Option<Id>,
    pub(super) row_fill: Option<Color>,
    pub(super) default_markers: HashMap<EffectSection, CGRect>,
    /// The experimental mark of a header (row-local rect) with its feature: hovering it says "<feature> · experimental".
    pub(super) experimental_marks: HashMap<EffectSection, (CGRect, sq_draw::experimental::Feature)>,
    pub(super) mask_color_began: bool,
}

impl Default for EffectControlsDrawPanel {
    fn default() -> Self {
        Self::new()
    }
}

impl EffectControlsDrawPanel {
    /// A panel without rows.
    pub fn new() -> EffectControlsDrawPanel {
        EffectControlsDrawPanel {
            text_slots: (0.0, 0.0),
            theme: DrawTheme::default(),
            size: CGSize::default(),
            scroll_y: 0.0,
            rows: Vec::new(),
            fields: HashMap::new(),
            focused_field: None,
            text_fields: HashMap::new(),
            focused_text: None,
            surfaces: HashMap::new(),
            custom_specs: HashMap::new(),
            widths: RefCell::new(HashMap::new()),
            wanted_widths: RefCell::new(HashSet::new()),
            asks_before_removing: false,
            has_key_sampler: false,
            automatic_resettable: Default::default(),
            mask_track: super::effect_controls_draw_rows::MaskTrackView::default(),
            magic_notice_laid_out: true,
            notices_laid_out: Vec::new(),
            events: Vec::new(),
            hover_point: None,
            cut_titles: HashMap::new(),
            pointer_in_row: false,
            press_target: Target::None,
            press_point: CGPoint::ZERO,
            press_modifiers: InputModifiers::NONE,
            reordering: None,
            clicks: ClickCounter::new(),
            scrolled_clip: None,
            row_fill: None,
            default_markers: HashMap::new(),
            experimental_marks: HashMap::new(),
            mask_color_began: false,
        }
    }

    /// The rows as laid out.
    pub fn rows(&self) -> &[EffectRow] {
        &self.rows
    }
    /// The scrub fields.
    pub fn fields(&self) -> &HashMap<FieldId, ScrubFieldControl> {
        &self.fields
    }
    /// The scrub field being edited.
    pub fn focused_field(&self) -> Option<&FieldId> {
        self.focused_field.as_ref()
    }
    /// The text field being typed in.
    pub fn focused_text(&self) -> Option<&str> {
        self.focused_text.as_deref()
    }
    /// The text fields of translated rows.
    pub fn text_fields(&self) -> &HashMap<String, TextFieldControl> {
        &self.text_fields
    }
    /// Takes the events pushed since the last call.
    pub fn take_events(&mut self) -> Vec<PanelEvent> {
        std::mem::take(&mut self.events)
    }

    /// `size` with its `didSet`: a width change lays the rows out again.
    pub fn set_size(&mut self, model: &EffectControlsModel, size: CGSize) {
        let wider = size.width != self.size.width;
        self.size = size;
        if wider {
            self.relayout(model);
        }
    }

    // MARK: Layout (EffectControlsView.rebuild)

    /// Rows from the model, with the Mac rebuild's arguments; call after every model change.
    pub fn relayout(&mut self, model: &EffectControlsModel) {
        let mut req = EffectRowsRequest::new(model.visible_sections());
        req.collapsed = model.collapsed_sections().clone();
        req.expanded = if model.graph_editor { Default::default() } else { model.expanded().clone() };
        req.blend_mode_row = true;
        req.group_headers = true;
        req.first_group_header = false;
        req.open_color_groups = model.open_color_groups.clone();
        req.subject_masks = model.subject_mask_ids();
        req.picture_masks = model.picture_mask_ids();
        req.magic_masks = model.magic_mask_ids();
        self.magic_notice_laid_out =
            sq_draw::experimental::prefs().shows_notice(sq_draw::experimental::Feature::MagicMask);
        req.magic_notice = self.magic_notice_laid_out;
        self.notices_laid_out = Self::open_notices();
        req.open_notices = self.notices_laid_out.clone();
        req.color_range_masks = model.color_range_mask_ids();
        req.grade_ranges = model.grade_range_effects();
        req.stabilizers = model.stabilizer_methods();
        req.transform_crop = model.transform_crop_properties();
        req.text_slots = self.text_slots;
        req.row_heights = self.stacked_row_heights(model);
        self.rows = EffectControlsLayout::rows(&req);
        self.sync_fields(model);
        // Another clip starts at the top; the same clip never scrolls past the end of a list that got shorter.
        let id = model.clip().map(|c| c.id);
        if id != self.scrolled_clip {
            self.scrolled_clip = id;
            self.scroll_y = 0.0;
        }
        self.scroll_y = self.scroll_y.min((self.content_height() - self.size.height).max(0.0));
    }

    /// Where the content ends.
    pub fn content_height(&self) -> f64 {
        self.rows.last().map_or(0.0, |r| r.y + r.height)
    }

    /// Heights of the rows whose fields do not fit side by side at the panel's width: they stack (`ControlsGrid::fields_stack`).
    fn stacked_row_heights(&self, model: &EffectControlsModel) -> std::collections::BTreeMap<EffectProperty, f64> {
        let g = self.grid();
        let mut out = std::collections::BTreeMap::new();
        for s in model.visible_sections() {
            let mut props = crate::ec::effect_controls_model::section::section_properties(&s);
            if s == EffectSection::Motion {
                props.extend(model.transform_crop_properties());
            }
            for p in props {
                let (n, link) = (model.value_components(&p).len(), Self::has_link(&p));
                if g.fields_stack(n, link) {
                    out.insert(p, g.fields_row_height(n, link));
                }
            }
        }
        out
    }

    /// The `index`-th number field of the property row `p` (`h` high).
    pub(super) fn field_frame(&self, model: &EffectControlsModel, p: &EffectProperty, index: usize, h: f64) -> CGRect {
        self.grid().field_frame(index, model.value_components(p).len(), Self::has_link(p), h)
    }

    pub(super) fn grid(&self) -> ControlsGrid {
        ControlsGrid::new(self.size.width)
    }

    pub(super) fn row_top(&self, r: &EffectRow) -> f64 {
        r.y - self.scroll_y
    }

    /// The row under `p`.
    pub fn row_at(&self, p: CGPoint) -> Option<&EffectRow> {
        self.rows.iter().find(|r| p.y >= self.row_top(r) && p.y < self.row_top(r) + r.height)
    }

    // MARK: Fields (PropertyRow.update, SpeedControlRow.update)

    /// The scrub fields of a row: one per component, keyed by row and component.
    pub(crate) fn field_ids(&self, model: &EffectControlsModel, kind: &EffectRowKind) -> Vec<FieldId> {
        match kind {
            EffectRowKind::Property(p) if p.param_kind().as_ref().is_none_or(Self::is_number) => model
                .value_components(p)
                .into_iter()
                .map(|c| FieldId { row: RowRef::Property(p.clone()), component: c })
                .collect(),
            EffectRowKind::SpeedControl(SpeedControl::Speed) => {
                vec![FieldId { row: RowRef::Speed(SpeedControl::Speed), component: EffectComponent::All }]
            }
            EffectRowKind::Property(_)
            | EffectRowKind::SpeedControl(_)
            | EffectRowKind::Section(_)
            | EffectRowKind::BlendMode
            | EffectRowKind::Group(_)
            | EffectRowKind::Placeholder(_) => Vec::new(),
            _ => {
                let Some(r) = self.rows.iter().find(|r| &r.kind == kind) else { return Vec::new() };
                let Some(ws) = self.widgets(model, r) else { return Vec::new() };
                ws.into_iter()
                    .filter(|w| matches!(w.kind, WidgetKind::Field(_)))
                    .map(|w| FieldId { row: RowRef::Custom(w.key), component: EffectComponent::All })
                    .collect()
            }
        }
    }

    pub(crate) fn is_number(k: &EffectParamKind) -> bool {
        !matches!(k, EffectParamKind::Color(_) | EffectParamKind::Checkbox | EffectParamKind::Choice(_))
    }

    /// Format and value of every visible field from the model (a field being dragged or typed in keeps its own value).
    pub fn sync_fields(&mut self, model: &EffectControlsModel) {
        let mut specs = HashMap::new();
        let mut texts: HashMap<String, TextFieldControl> = HashMap::new();
        for r in self.rows.clone() {
            let Some(ws) = self.widgets(model, &r) else { continue };
            for w in ws {
                match &w.kind {
                    WidgetKind::Field(spec) => {
                        specs.insert(w.key.clone(), spec.clone());
                    }
                    WidgetKind::TextField(text, _) => {
                        let mut f =
                            self.text_fields.get(&w.key).cloned().unwrap_or_else(|| TextFieldControl::new(text));
                        if !f.is_editing() {
                            f.text = text.clone();
                        }
                        f.is_enabled = w.enabled;
                        texts.insert(w.key.clone(), f);
                    }
                    _ => {}
                }
            }
        }
        self.custom_specs = specs;
        self.text_fields = texts;
        if self.focused_text.as_ref().is_some_and(|k| !self.text_fields.contains_key(k)) {
            self.focused_text = None;
        }
        let mut live: HashMap<FieldId, ScrubFieldControl> = HashMap::new();
        for r in self.rows.clone() {
            for id in self.field_ids(model, &r.kind) {
                let mut f = self.fields.remove(&id).unwrap_or_else(|| ScrubFieldControl::new(0.0));
                self.configure(model, &mut f, &id);
                live.insert(id, f);
            }
        }
        if self.focused_field.as_ref().is_some_and(|f| !live.contains_key(f)) {
            self.focused_field = None;
        }
        self.fields = live;
    }

    fn configure(&self, model: &EffectControlsModel, f: &mut ScrubFieldControl, id: &FieldId) {
        let busy = f.is_dragging() || f.is_editing();
        match &id.row {
            RowRef::Property(p) => {
                let pic = model.display_picture();
                f.range = p.display_range(pic);
                f.step = p.display_step(pic);
                f.unit = p.display_unit(pic);
                f.decimals = p.display_decimals(pic);
                f.leading_text = false; // art.html: value in a well, right aligned
                if *p == EffectProperty::Rotation {
                    // turns + degrees from 360 up ("1x 30.0 deg"), typing "1x30" or "390" both work
                    let current = if f.is_mixed { 0.0 } else { f.value };
                    f.value_formatter = Some(Box::new(sq_uikit::rotation_text::format));
                    f.value_parser = Some(Box::new(move |s: &str| sq_uikit::rotation_text::parse(s, current)));
                }
                let v = match id.component {
                    EffectComponent::X => p.display(model.vector_value(p).x, EffectComponent::X, pic),
                    EffectComponent::Y => p.display(model.vector_value(p).y, EffectComponent::Y, pic),
                    EffectComponent::All => p.display(model.scalar_value(p), EffectComponent::All, pic),
                };
                if !busy {
                    f.value = v;
                }
                f.is_mixed = model.is_mixed(p, id.component);
            }
            RowRef::Speed(_) => {
                f.range = 1.0..=10000.0;
                f.step = 1.0;
                f.decimals = 1;
                f.unit = "%".to_string();
                f.default_value = Some(100.0);
                if !busy {
                    f.value = model.speed_percent();
                }
            }
            RowRef::Blend => {}
            RowRef::Custom(key) => {
                if let Some(spec) = self.custom_specs.get(key) {
                    (spec.configure)(f);
                    if !busy {
                        f.value = spec.value;
                    }
                }
            }
        }
        if let RowRef::Custom(key) = &id.row {
            let enabled = self
                .rows
                .iter()
                .find_map(|r| self.widgets(model, r).and_then(|ws| ws.into_iter().find(|w| &w.key == key)))
                .map(|w| w.enabled);
            if let Some(e) = enabled {
                f.is_enabled = e;
            }
        }
    }

    pub(super) fn apply(&mut self, model: &mut EffectControlsModel, events: Vec<ScrubEvent>, id: &FieldId) {
        for e in events {
            match &id.row {
                RowRef::Property(p) => {
                    let pic = model.display_picture();
                    let comp = id.component;
                    let set = |m: &mut EffectControlsModel, v: f64| {
                        let _ = m.set_value(p, comp, p.native_from_display(v, comp, pic));
                    };
                    match e {
                        ScrubEvent::Begin => model.begin_gesture(),
                        ScrubEvent::Live(v) | ScrubEvent::Change(v) => set(model, v),
                        ScrubEvent::End(_) => model.end_gesture(),
                        ScrubEvent::Cancel(v) => {
                            set(model, v); // PropertyRow has no onCancel: apply the start, then end
                            model.end_gesture();
                        }
                    }
                }
                RowRef::Speed(_) => match e {
                    ScrubEvent::Begin => self.events.push(PanelEvent::Speed(SpeedAction::Begin)),
                    ScrubEvent::Live(v) | ScrubEvent::Change(v) => {
                        self.events.push(PanelEvent::Speed(SpeedAction::Set(v)))
                    }
                    ScrubEvent::End(_) => self.events.push(PanelEvent::Speed(SpeedAction::End)),
                    ScrubEvent::Cancel(v) => {
                        self.events.push(PanelEvent::Speed(SpeedAction::Set(v)));
                        self.events.push(PanelEvent::Speed(SpeedAction::End));
                    }
                },
                RowRef::Blend => {}
                RowRef::Custom(key) => {
                    let Some(spec) = self.custom_specs.get(key).cloned() else { continue };
                    match e {
                        ScrubEvent::Begin => (spec.begin)(model),
                        ScrubEvent::Live(v) | ScrubEvent::Change(v) => (spec.change)(model, v),
                        ScrubEvent::End(_) => (spec.end)(model),
                        ScrubEvent::Cancel(v) => {
                            (spec.change)(model, v);
                            (spec.end)(model);
                        }
                    }
                }
            }
        }
    }

    // MARK: Geometry shared by drawing and hit testing

    fn eye_frame(&self, h: f64) -> CGRect {
        let g = self.grid();
        CGRect::new(g.reset_x() - ControlsGrid::GAP - ControlsGrid::RESET_WIDTH, 0.0, ControlsGrid::RESET_WIDTH, h)
    }
    /// ControlsKeyNavigation: four equal slots (previous, key, next, open) in the navigation column.
    pub(crate) fn navigation_slot(&self, i: usize, h: f64) -> CGRect {
        let n = self.grid().navigation_frame(h);
        let w = n.width / 4.0;
        CGRect::new(n.min_x() + i as f64 * w, 0.0, w, h)
    }
    /// EffectParamRowBase: the control from the value column, `width` at most, before the key navigation. A motion effect's
    /// Curve popup leaves room for its Edit Curve button.
    pub(super) fn param_frame(&self, p: &EffectProperty, kind: &EffectParamKind, h: f64) -> CGRect {
        let g = self.grid();
        if Self::motion_curve_effect(p).is_none() {
            return self.param_control_frame(kind, h);
        }
        g.fill_frame(h, Some(g.value_max_x() - ControlsGrid::RESET_WIDTH - ControlsGrid::GAP), Portable::POPUP_WIDTH)
    }
    pub(super) fn curve_button_frame(&self, p: &EffectProperty, h: f64) -> CGRect {
        let Some(k) = p.param_kind() else { return CGRect::default() };
        self.grid().control_frame(
            self.param_frame(p, &k, h).max_x() + ControlsGrid::GAP,
            ControlsGrid::RESET_WIDTH,
            h,
            ControlsGrid::CONTROL_HEIGHT,
        )
    }
    /// The motion effect whose Curve parameter `p` is (EffectParamRows: the row gets the curve editor button).
    pub(crate) fn motion_curve_effect(p: &EffectProperty) -> Option<Id> {
        if let EffectProperty::Fx { id, kind, key } = p
            && key == sq_core_model::ClipEffect::MOTION_CURVE_KEY
            && sq_core_model::ClipEffect::MOTION_KINDS.contains(&kind.as_str())
        {
            return Some(*id);
        }
        None
    }
    fn param_control_frame(&self, kind: &EffectParamKind, h: f64) -> CGRect {
        let width = match kind {
            EffectParamKind::Color(_) => 44.0,
            EffectParamKind::Checkbox => 22.0,
            _ => Portable::POPUP_WIDTH,
        };
        let g = self.grid();
        g.fill_frame(h, Some(g.value_max_x()), width)
    }
    pub(super) fn has_link(p: &EffectProperty) -> bool {
        p.pair().is_some_and(|x| x.linkable) || *p == EffectProperty::Scale
    }
    /// Color Key's Key Hue: an eyedropper next to the field (EffectControlsView `pick`), where a screen sampler exists.
    pub(super) fn has_key_pick(&self, p: &EffectProperty) -> bool {
        EffectControlsModel::is_key_hue(p) && self.has_key_sampler
    }
    pub(super) fn link_frame(&self, model: &EffectControlsModel, p: &EffectProperty, h: f64) -> CGRect {
        self.grid().link_frame_after(model.value_components(p).len(), Self::has_link(p), h)
    }
    pub(crate) fn blend_frame(&self, h: f64) -> CGRect {
        let g = self.grid();
        let f = g.fill_frame(h, Some(g.value_max_x()), Portable::POPUP_WIDTH);
        // FUNDE: in a narrow panel the pop-up keeps room for its title and arrow instead of shrinking to nothing.
        CGRect::new(f.min_x(), f.min_y(), f.width.max(Self::BLEND_MIN_WIDTH), f.height)
    }
    /// Narrowest the blend-mode pop-up gets: two minimum number fields.
    pub(crate) const BLEND_MIN_WIDTH: f64 = 2.0 * ControlsGrid::MIN_FIELD;
    pub(super) fn checkbox_frame(&self, h: f64) -> CGRect {
        self.grid().control_frame(ControlsGrid::VALUE_X, InspectorTokens::CHECKBOX, h, InspectorTokens::CHECKBOX)
    }

    /// The control under `p` (panel points).
    pub fn target_at(&self, model: &EffectControlsModel, p: CGPoint) -> Target {
        let Some(r) = self.row_at(p) else { return Target::None };
        let l = CGPoint::new(p.x, p.y - self.row_top(r));
        let h = r.height;
        let g = self.grid();
        match &r.kind {
            EffectRowKind::Section(s) => {
                if g.header_toggle_frame(h).contains(l) {
                    return Target::Chevron(s.clone());
                }
                if model.has_fx_toggle(s) && self.eye_frame(h).contains(l) {
                    return Target::Eye(s.clone());
                }
                if g.reset_frame(h).contains(l) {
                    return Target::SectionReset(s.clone());
                }
                Target::Header(s.clone())
            }
            EffectRowKind::Graph(prop) => self.graph_head_target(prop, l),
            EffectRowKind::Property(prop) => {
                let rr = RowRef::Property(prop.clone());
                if let Some(t) =
                    self.key_controls_target(&rr, l, h, &model.keyframe_control_state(prop), prop.has_graph())
                {
                    return t;
                }
                match prop.param_kind() {
                    Some(k) if !Self::is_number(&k) => {
                        if Self::motion_curve_effect(prop).is_some() && self.curve_button_frame(prop, h).contains(l) {
                            return Target::Curve(prop.clone());
                        }
                        if self.param_frame(prop, &k, h).contains(l) {
                            return match k {
                                EffectParamKind::Color(_) => Target::Well(prop.clone()),
                                EffectParamKind::Checkbox => Target::Checkbox(rr),
                                _ => Target::Popup(rr),
                            };
                        }
                    }
                    _ => {
                        for (i, id) in self.field_ids(model, &r.kind).into_iter().enumerate() {
                            if self.field_frame(model, prop, i, h).contains(l) {
                                return Target::Field(id);
                            }
                        }
                        if Self::has_link(prop) && self.link_frame(model, prop, h).contains(l) {
                            return Target::Link(prop.clone());
                        }
                        if self.has_key_pick(prop) && self.link_frame(model, prop, h).contains(l) {
                            return Target::KeyPick(prop.clone());
                        }
                    }
                }
                if g.label_frame(h, None).contains(l) {
                    return Target::Label(rr);
                }
                Target::Row(rr)
            }
            EffectRowKind::SpeedControl(k) => {
                let rr = RowRef::Speed(*k);
                if *k == SpeedControl::Speed {
                    if model.speed_keys_available()
                        && let Some(t) = self.key_controls_target(
                            &rr,
                            l,
                            h,
                            &model.speed_key_control_state(),
                            model.speed_has_transition(),
                        )
                    {
                        return t;
                    }
                    if g.value_frame(0, h).contains(l) {
                        return Target::Field(FieldId { row: rr, component: EffectComponent::All });
                    }
                } else if *k != SpeedControl::TimeInterpolation
                    && self.checkbox_frame(h).inset_by(-4.0, -4.0).contains(l)
                {
                    return Target::Checkbox(rr);
                }
                Target::Row(rr)
            }
            EffectRowKind::BlendMode => {
                if self.blend_frame(h).contains(l) {
                    Target::Popup(RowRef::Blend)
                } else {
                    Target::Row(RowRef::Blend)
                }
            }
            _ => {
                let Some(ws) = self.widgets(model, r) else { return Target::None };
                for w in ws.iter().rev() {
                    if let Some(b) = w.toggle_frame
                        && b.inset_by(-4.0, -4.0).contains(l)
                    {
                        return Target::WidgetToggle(w.key.clone());
                    }
                    match &w.kind {
                        WidgetKind::Navigation(_) | WidgetKind::Progress(_) => continue,
                        WidgetKind::Text(..) if w.help.is_none() => continue,
                        WidgetKind::Field(_) => {
                            if w.frame.contains(l) {
                                return Target::Field(FieldId {
                                    row: RowRef::Custom(w.key.clone()),
                                    component: EffectComponent::All,
                                });
                            }
                        }
                        _ => {
                            if w.frame.contains(l) {
                                return Target::Widget(w.key.clone());
                            }
                        }
                    }
                }
                Target::None
            }
        }
    }

    fn key_controls_target(
        &self,
        rr: &RowRef,
        l: CGPoint,
        h: f64,
        state: &KeyframeControlState,
        shows_open: bool,
    ) -> Option<Target> {
        let g = self.grid();
        if g.toggle_frame(h).contains(l) {
            return Some(Target::Ring(rr.clone()));
        }
        if g.reset_frame(h).contains(l) {
            return Some(Target::Reset(rr.clone()));
        }
        if !state.shows_navigation {
            return None;
        }
        let slots =
            [Target::Previous(rr.clone()), Target::Key(rr.clone()), Target::Next(rr.clone()), Target::Open(rr.clone())];
        for (i, slot) in slots.iter().enumerate().take(if shows_open { 4 } else { 3 }) {
            if self.navigation_slot(i, h).contains(l) {
                return Some(slot.clone());
            }
        }
        None
    }

    // MARK: Drawing

    /// Draws the rows.
    pub fn draw(&mut self, model: &EffectControlsModel, c: &mut Canvas, cx: &mut UiCx) {
        let t = self.theme;
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        // Measure the strings the hit tests asked for (button titles) now that an atlas is at hand.
        let wanted: Vec<String> = self.wanted_widths.borrow_mut().drain().collect();
        for s in wanted {
            let w = c.size_of(&s, type_size::BODY as f64, 0).width;
            self.widths.borrow_mut().insert(s, w);
        }
        let hover = self.hover_point.map_or(Target::None, |p| self.target_at(model, p));
        c.save_gstate();
        c.clip_to(bounds);
        c.fill(bounds, t.panel());
        for r in self.rows.clone() {
            let top = self.row_top(&r);
            if !(top + r.height > 0.0 && top < self.size.height) {
                continue;
            }
            c.save_gstate();
            c.translate_by(0.0, top);
            self.pointer_in_row = self.hover_point.is_some_and(|p| p.y >= top && p.y < top + r.height);
            self.draw_row(model, &r, c, &hover, cx);
            c.restore_gstate();
        }
        if let Some(line) = self.drop_line_y() {
            c.fill(CGRect::new(0.0, line - 1.0, self.size.width, 2.0), t.accent());
        }
        if self.shows_empty_state(model) {
            self.draw_empty_state(c);
        }
        c.restore_gstate();
    }

    /// EffectControlsView.updateChrome: nothing selected shows the empty state.
    pub fn shows_empty_state(&self, model: &EffectControlsModel) -> bool {
        model.clip().is_none()
    }
    /// Title of the empty state.
    pub const EMPTY_TITLE: &'static str = "No Clip Selected";
    /// Hint of the empty state.
    pub const EMPTY_HINT: &'static str = "Select a clip in the timeline to see and keyframe its controls here.";

    /// r8:734: mouse-pointer-2 at 20, the title, then the hint.
    fn draw_empty_state(&self, c: &mut Canvas) {
        const ICON: f64 = 20.0;
        const ICON_GAP: f64 = spacing::MD as f64;
        let hint = SQL10n::string(Self::EMPTY_HINT);
        let area = CGRect::new(0.0, (ICON + ICON_GAP) / 2.0, self.size.width, self.size.height);
        let bottom = c.draw_empty_state(&SQL10n::string(Self::EMPTY_TITLE), &hint, area, 0.0, &self.theme);
        let w = (self.size.width - 2.0 * spacing::LG as f64).max(0.0);
        let lines = c.wrap(&hint, w, type_size::BODY as f64).len().min(3) as f64;
        let text_h = 20.0 + if lines > 0.0 { spacing::XS as f64 + lines * 14.0 } else { 0.0 };
        let top = bottom - text_h - ICON_GAP - ICON;
        let r = CGRect::new(0.0, top, self.size.width, ICON);
        self.icon(c, SQIcon::ToolSelect, r, ICON, self.theme.label3());
    }

    /// RowBackground: fill, the 1 pt row line at the bottom, a hairline at the top of a group.
    fn background(&mut self, c: &mut Canvas, h: f64, fill: Color, bottom_line: bool, top_separator: bool) {
        c.fill(CGRect::new(0.0, 0.0, self.size.width, h), fill);
        self.row_fill = Some(fill);
        if bottom_line {
            c.fill(CGRect::new(0.0, h - 1.0, self.size.width, 1.0), self.theme.row_line());
        }
        if top_separator {
            c.fill(CGRect::new(0.0, 0.0, self.size.width, 1.0), self.theme.separator());
        }
    }

    pub(crate) fn icon(&self, c: &mut Canvas, i: SQIcon, r: CGRect, size: f64, color: Color) {
        c.draw_icon(
            i,
            CGPoint::new((r.mid_x() - size / 2.0).round(), (r.mid_y() - size / 2.0).round()),
            size,
            color,
            None,
        );
    }

    /// IconButton's tint: label2 (or the given one), label while hovered, dimmed while disabled.
    pub(crate) fn button_tint(&self, base: Option<Color>, hovered: bool, enabled: bool, alpha: f32) -> Color {
        let t = &self.theme;
        let mut col = base.unwrap_or_else(|| t.label2());
        if (hovered && enabled && base.is_none()) || (hovered && enabled && base == Some(t.label3())) {
            col = t.label();
        }
        let a = col.a * alpha * if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        col.with_alpha(a)
    }

    /// The name in the label column (ControlsGrid.place: wider into free room, else cut at a word boundary).
    pub(super) fn label(&self, c: &mut Canvas, s: &str, h: f64, max_x: Option<f64>, color: Option<Color>) {
        let text = SQL10n::string(s);
        let fs = type_size::BODY as f64;
        let mut f = self.grid().label_frame(h, None);
        let natural = c.size_of(&text, fs, 0).width.ceil();
        if let Some(max_x) = max_x
            && natural > f.width
        {
            f.width = natural.min((max_x - ControlsGrid::LABEL_X).max(f.width));
        }
        let col = color.unwrap_or_else(|| self.theme.label2());
        Self::draw_label_lines(c, &text, f, h, fs, col);
    }

    /// `text` in `f` by the one label rule of every inspector row: one line when it fits, two lines when it wraps at a
    /// space (centered in a row of height `h`), else cut at a word boundary. The effect rows and the clip sections share it.
    pub fn draw_label_lines(c: &mut Canvas, text: &str, f: CGRect, h: f64, fs: f64, col: Color) {
        match Self::label_lines(text, f.width, |s| c.size_of(s, fs, 0).width).as_slice() {
            [first, second] => {
                // Two lines close together, centered in the row: a long name stays whole without a wider column.
                let pitch = fs - 1.0;
                let top = f.min_y() + ((h - pitch - fs) / 2.0).max(0.0);
                for (i, line) in [first, second].into_iter().enumerate() {
                    let r = CGRect::new(f.min_x(), top + pitch * i as f64, f.width, fs);
                    c.draw_text_in(line, r, fs, col, TextAlign::Left, 0.0, 0);
                }
            }
            lines => {
                c.draw_text_in(lines.first().map_or("", String::as_str), f, fs, col, TextAlign::Left, 0.0, 0);
            }
        }
    }

    /// The label as one line when it fits, as two lines when it wraps at a space into two lines that both fit, else cut
    /// by [`Self::label_cut`] (one line, word boundary).
    pub fn label_lines(s: &str, width: f64, measure: impl Fn(&str) -> f64) -> Vec<String> {
        let fits = |t: &str| measure(t) <= width + 0.5;
        if fits(s) {
            return vec![s.to_string()];
        }
        let words: Vec<&str> = s.split_whitespace().collect();
        let mut first = String::new();
        let mut at = words.len();
        for (i, w) in words.iter().enumerate() {
            let next = if first.is_empty() { (*w).to_string() } else { format!("{first} {w}") };
            if !fits(&next) {
                at = i;
                break;
            }
            first = next;
        }
        let second = words[at..].join(" ");
        if first.is_empty() || second.is_empty() || !fits(&second) {
            return vec![Self::label_cut(s, width, measure)];
        }
        vec![first, second]
    }

    /// The label cut to `width` at a word boundary with a trailing ellipsis ([`sq_draw::glyph_atlas::fit_with_ellipsis`]);
    /// a label that is too narrow for even its first letters gets just the ellipsis.
    pub fn label_cut(s: &str, width: f64, measure: impl Fn(&str) -> f64) -> String {
        if measure(s) <= width + 0.5 {
            return s.to_string();
        }
        // A short label whose first word does not fit goes to the drawing whole: it shrinks one step or hides.
        if sq_draw::glyph_atlas::first_word_overflows(s, |t| measure(t) <= width + 0.5) {
            return s.to_string();
        }
        sq_draw::glyph_atlas::fit_with_ellipsis(s, |t| measure(t) <= width + 0.5)
            .unwrap_or_else(|| "\u{2026}".to_string())
    }

    fn draw_row(&mut self, model: &EffectControlsModel, r: &EffectRow, c: &mut Canvas, hover: &Target, cx: &mut UiCx) {
        let t = self.theme;
        let h = r.height;
        let g = self.grid();
        match &r.kind {
            EffectRowKind::Section(s) => self.draw_section_header(model, s, c, h, hover),
            EffectRowKind::Group(grp) => {
                // The same header as the one above the rows ("Video"): caption text, one hairline under it.
                self.background(c, h, t.panel(), true, false);
                let lead = spacing::MD as f64;
                let bold = c.semibold();
                c.draw_tracked_caps(
                    &SQL10n::string(grp.title()),
                    CGRect::new(lead, 0.0, (self.size.width - 2.0 * lead).max(0.0), h),
                    10.0,
                    t.label4(),
                    bold,
                    0.07,
                );
            }
            EffectRowKind::Placeholder(_) => {
                self.background(c, h, t.panel(), true, false);
                c.draw_text_in(
                    &SQL10n::string("No settings"),
                    g.label_frame(h, Some(g.tail_max_x() + ControlsGrid::GAP)),
                    type_size::BODY as f64,
                    t.label3(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
            EffectRowKind::Property(p) => self.draw_property(model, p, c, h, hover, cx),
            EffectRowKind::Graph(prop) => {
                // EasePaneView: the curve itself is drawn by the lanes; the head (mode toggle, ease chips) sits here. Continues the
                // row above (no top line).
                self.background(c, h, t.panel(), false, false);
                c.fill(CGRect::new(0.0, 0.0, self.size.width, h), t.graph_pane());
                c.fill(CGRect::new(0.0, h - 1.0, self.size.width, 1.0), t.separator());
                self.draw_graph_head(model, prop, c, hover);
            }
            EffectRowKind::SpeedControl(k) => self.draw_speed(model, *k, c, h, hover, cx),
            EffectRowKind::BlendMode => {
                self.background(c, h, t.panel(), true, false);
                let title = if model.is_blend_mode_mixed() {
                    String::new()
                } else {
                    SQL10n::string(model.blend_mode().title())
                };
                super::popup(
                    c,
                    &title,
                    self.blend_frame(h),
                    *hover == Target::Popup(RowRef::Blend),
                    false,
                    model.is_blend_group_enabled(),
                    &t,
                );
                self.label(c, "Blend Mode", h, None, None);
            }
            _ => {
                if let Some(ws) = self.widgets(model, r) {
                    self.draw_widgets(model, r, &ws, c, hover, cx);
                    return;
                }
                // known limit: a row whose Mac view is not translated yet keeps its height and shows its kind; upgrade row by row
                // (WINDOWS-PLAN "missing").
                self.background(c, h, t.panel(), true, false);
                c.draw_text_in(
                    &Self::pending_title(&r.kind),
                    g.label_frame(h, Some(g.tail_max_x())),
                    type_size::CAPTION as f64,
                    t.label3(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
        }
    }

    /// The case name of a row kind (Swift `String(describing:)` up to the payload).
    pub fn pending_title(k: &EffectRowKind) -> String {
        let s = format!("{k:?}");
        s.chars().take_while(|c| *c != '(' && *c != ' ' && *c != '{').collect()
    }

    /// SectionHeaderRow.
    fn draw_section_header(
        &mut self,
        model: &EffectControlsModel,
        s: &EffectSection,
        c: &mut Canvas,
        h: f64,
        hover: &Target,
    ) {
        let t = self.theme;
        let g = self.grid();
        let row_hovered = self.hover_point.is_some_and(|p| {
            let tg = self.target_at(model, p);
            matches!(tg, Target::Header(_))
                || [Target::Chevron(s.clone()), Target::Eye(s.clone()), Target::SectionReset(s.clone())].contains(&tg)
        });
        self.background(c, h, if model.is_section_selected(s) { t.current() } else { t.panel() }, true, false);
        c.fill(CGRect::new(0.0, h - 1.0, self.size.width, 1.0), t.separator()); // `.grp`: border-group
        let collapsed = model.collapsed_sections().contains(s);
        self.icon(
            c,
            if collapsed { SQIcon::ChevronRight } else { SQIcon::ChevronDown },
            g.header_toggle_frame(h),
            9.0,
            t.label3(),
        );
        let on = model.is_effect_enabled(s);
        let mixed = model.is_effect_enabled_mixed(s);
        // Eye and reset are always shown in their fixed slots (feedback 2026-10-11); dim at rest, full while the pointer is over the row.
        let a: f32 = if row_hovered { 1.0 } else { 0.55 };
        if model.has_fx_toggle(s) {
            let icon = if mixed {
                SQIcon::Minus
            } else if on {
                SQIcon::Eye
            } else {
                SQIcon::EyeOff
            };
            let tint = self.button_tint(Some(t.label3()), *hover == Target::Eye(s.clone()), true, a);
            self.icon(c, icon, self.eye_frame(h), 10.0, tint);
        }
        let resettable = s.properties().iter().any(|p| !model.is_default(p)) || !on;
        if self.reset_shown(None, resettable, *hover == Target::SectionReset(s.clone())) {
            let tint = self.button_tint(None, *hover == Target::SectionReset(s.clone()), resettable, a);
            self.icon(c, SQIcon::Reset, g.reset_frame(h), 10.0, tint);
        }
        // Title (bodyStrong), your-default marker, summary right aligned up to the eye slot.
        let fs = type_size::BODY as f64;
        let title_x = ControlsGrid::HEADER_LABEL_X;
        let bold = c.semibold();
        let right_x = self.eye_frame(h).min_x() - ControlsGrid::GAP;
        let user = model.has_user_default(s);
        let marker_w = if user { 14.0 } else { 0.0 };
        let lh = ControlsGrid::LABEL_HEIGHT;
        let ly = ((h - lh) / 2.0).round();
        let mut name = SQL10n::string(&s.title());
        if let EffectSection::Mask(id) = s
            && let Some(m) = model.clip().and_then(|c| c.mask(*id))
        {
            name = m.name.clone();
        }
        let title_w = (c.size_of(&name, fs, bold).width.ceil() + 4.0).min((right_x - title_x - marker_w).max(0.0));
        // FUNDE 1: a long effect or mask name is cut in the middle; the tooltip carries the full name.
        let cut = sq_draw::middle_fit::truncate_name(&name, |s| c.size_of(s, fs, bold).width <= title_w + 0.5);
        match &cut.full {
            Some(full) => self.cut_titles.insert(s.clone(), (full.clone(), CGRect::new(title_x, 0.0, title_w, h))),
            None => self.cut_titles.remove(s),
        };
        c.draw_text_in(
            &cut.shown,
            CGRect::new(title_x, ly, title_w, lh),
            fs,
            if on { t.label() } else { t.label3() },
            TextAlign::Left,
            0.0,
            bold,
        );
        let feature = match s {
            EffectSection::Effect { kind, .. } => sq_draw::experimental::Feature::for_effect_kind(kind),
            EffectSection::Mask(id) => model
                .clip()
                .and_then(|c| c.mask(*id))
                .filter(|m| m.source() == sq_core_model::MaskSource::Magic)
                .map(|_| sq_draw::experimental::Feature::MagicMask),
            _ => None,
        };
        self.experimental_marks.remove(s);
        if let Some(f) = feature {
            let mark_x = title_x + title_w + marker_w + 4.0;
            if mark_x + sq_draw::experimental::ICON_SIZE < right_x {
                let origin = CGPoint::new(mark_x, ((h - sq_draw::experimental::ICON_SIZE) / 2.0).round());
                if let Some(r) = c.experimental_mark(f, origin, sq_draw::experimental::ExperimentalMark::Icon, &t) {
                    self.experimental_marks.insert(s.clone(), (r, f));
                }
            }
        }
        if user {
            let marker = CGRect::new(title_x + title_w + 2.0, 0.0, 10.0, h);
            self.default_markers.insert(s.clone(), marker);
            self.icon(c, SQIcon::BookmarkFilled, marker, 9.0, t.label3());
        } else {
            self.default_markers.remove(s);
        }
        let sum_x = title_x + title_w + marker_w + ControlsGrid::GAP;
        if let Some(summary) = model.section_summary(s, None)
            && right_x > sum_x
        {
            c.draw_text_in(
                &summary,
                CGRect::new(sum_x, ly, right_x - sum_x, lh),
                type_size::CAPTION as f64,
                t.label3(),
                TextAlign::Right,
                0.0,
                0,
            );
        }
    }

    /// The ring, key navigation, Open and reset of a keyframable row (ParameterKeyControls).
    fn draw_key_controls(&self, c: &mut Canvas, rr: &RowRef, h: f64, k: &KeyControls, hover: &Target) {
        let KeyControls { state, shows_open, is_open, resettable } = k;
        let (shows_open, is_open, resettable) = (*shows_open, *is_open, *resettable);
        let t = self.theme;
        let g = self.grid();
        let ring = g.toggle_frame(h);
        // The Mac Controls row: a plain diamond switch (AnimateDiamondView), not the dotted ring of the Graphics rows.
        InspectorDraw::animate_switch(
            c,
            state.shows_navigation,
            *hover == Target::Ring(rr.clone()),
            CGPoint::new(ring.mid_x(), ring.mid_y()),
            &t,
        );
        if state.shows_navigation {
            let n = union(self.navigation_slot(0, h), self.navigation_slot(2, h));
            InspectorDraw::navigation(c, state, n, true, self.row_fill, &t);
            if shows_open {
                // v9 `.kcv`: chevron right, turned down and `label` while the curve is open.
                let tint = self.button_tint(
                    Some(if is_open { t.label() } else { t.label3() }),
                    *hover == Target::Open(rr.clone()),
                    true,
                    1.0,
                );
                self.icon(
                    c,
                    if is_open { SQIcon::ChevronDown } else { SQIcon::ChevronRight },
                    self.navigation_slot(3, h),
                    9.0,
                    tint,
                );
            }
        }
        if self.reset_shown(Some(rr), resettable, *hover == Target::Reset(rr.clone())) {
            let tint = self.button_tint(None, *hover == Target::Reset(rr.clone()), resettable, 1.0);
            self.icon(c, SQIcon::Reset, g.reset_frame(h), 10.0, tint);
        }
    }

    /// r8:542-545: reset shows on a changed row, or on the row under the pointer or the keyboard focus.
    pub(crate) fn reset_shown(&self, rr: Option<&RowRef>, changed: bool, on_button: bool) -> bool {
        changed
            || on_button
            || self.pointer_in_row
            || rr.is_some_and(|rr| self.focused_field.as_ref().is_some_and(|f| f.row == *rr))
    }

    /// PropertyRow, and EffectParamRows for color, checkbox and choice parameters.
    fn draw_property(
        &mut self,
        model: &EffectControlsModel,
        p: &EffectProperty,
        c: &mut Canvas,
        h: f64,
        hover: &Target,
        cx: &mut UiCx,
    ) {
        let t = self.theme;
        let rr = RowRef::Property(p.clone());
        let opened = model.expanded().contains(p) && p.has_graph() && !model.graph_editor;
        // `.kp.sel`: a selected row. Open curve: the name row and the pane under it are one lighter element.
        let fill = if model.graph_properties.contains(p) {
            t.current()
        } else if opened {
            t.graph_pane()
        } else {
            t.panel()
        };
        self.background(c, h, fill, !opened, false);
        let keys = KeyControls {
            state: model.keyframe_control_state(p),
            shows_open: p.has_graph(),
            is_open: model.expanded().contains(p),
            resettable: !model.is_default(p),
        };
        self.draw_key_controls(c, &rr, h, &keys, hover);
        if let Some(k) = p.param_kind()
            && !Self::is_number(&k)
        {
            let f = self.param_frame(p, &k, h);
            if Self::motion_curve_effect(p).is_some() {
                let tint = self.button_tint(None, *hover == Target::Curve(p.clone()), true, 1.0);
                self.icon(c, SQIcon::Curve, self.curve_button_frame(p, h), 10.0, tint);
            }
            let mixed = model.is_mixed(p, EffectComponent::All);
            match &k {
                EffectParamKind::Color(_) => {
                    let v = model.color_value(p).clamped();
                    let col =
                        if mixed { t.field() } else { Color::new(v.red as f32, v.green as f32, v.blue as f32, 1.0) };
                    InspectorDraw::color_well(c, col, f, *hover == Target::Well(p.clone()), &t);
                }
                EffectParamKind::Checkbox => {
                    let on = k.is_on(model.scalar_value(p));
                    let s = InspectorTokens::CHECKBOX;
                    let boxed = CGRect::new(f.min_x(), (f.mid_y() - s / 2.0).round(), s, s);
                    let state = if mixed {
                        CheckState::Mixed
                    } else if on {
                        CheckState::On
                    } else {
                        CheckState::Off
                    };
                    InspectorDraw::checkbox(
                        c,
                        state,
                        boxed,
                        *hover == Target::Checkbox(rr.clone()),
                        self.press_target == Target::Checkbox(rr.clone()),
                        true,
                        false,
                        &t,
                    );
                }
                EffectParamKind::Choice(items) => {
                    let i = k.choice_index(model.scalar_value(p));
                    let title = if mixed || i < 0 || i as usize >= items.len() {
                        String::new()
                    } else {
                        SQL10n::string(&items[i as usize])
                    };
                    super::popup(c, &title, f, *hover == Target::Popup(rr.clone()), false, true, &t);
                }
                _ => {}
            }
            self.label(c, &model.property_title(p), h, None, None);
            return;
        }
        for (i, id) in self.field_ids(model, &EffectRowKind::Property(p.clone())).into_iter().enumerate() {
            if let Some(f) = self.fields.get(&id) {
                f.draw(c, self.field_frame(model, p, i, h), &t, self.focused_field.as_ref() == Some(&id), cx);
            }
        }
        if Self::has_link(p) {
            let on = if *p == EffectProperty::Scale { model.uniform_scale } else { model.is_linked(p) };
            let tint = self.button_tint(
                Some(if on { t.label() } else { t.label3() }),
                *hover == Target::Link(p.clone()),
                true,
                1.0,
            );
            self.icon(c, if on { SQIcon::Link } else { SQIcon::Unlink }, self.link_frame(model, p, h), 11.0, tint);
        }
        if self.has_key_pick(p) {
            let tint = self.button_tint(Some(t.label2()), *hover == Target::KeyPick(p.clone()), true, 1.0);
            self.icon(c, SQIcon::Eyedropper, self.link_frame(model, p, h), 11.0, tint);
        }
        self.label(c, &p.title(), h, None, None);
    }

    /// SpeedControlRow.
    fn draw_speed(
        &mut self,
        model: &EffectControlsModel,
        k: SpeedControl,
        c: &mut Canvas,
        h: f64,
        hover: &Target,
        cx: &mut UiCx,
    ) {
        let t = self.theme;
        let rr = RowRef::Speed(k);
        self.background(c, h, t.panel(), true, false);
        let g = self.grid();
        match k {
            SpeedControl::Speed => {
                let id = FieldId { row: rr.clone(), component: EffectComponent::All };
                if let Some(f) = self.fields.get(&id) {
                    f.draw(c, g.value_frame(0, h), &t, self.focused_field.as_ref() == Some(&id), cx);
                }
                let resettable = model.speed_percent() != 100.0 || model.speed_is_animated();
                if model.speed_keys_available() {
                    let keys = KeyControls {
                        state: model.speed_key_control_state(),
                        shows_open: model.speed_has_transition(),
                        is_open: false,
                        resettable,
                    };
                    self.draw_key_controls(c, &rr, h, &keys, hover);
                } else {
                    if self.reset_shown(Some(&rr), resettable, *hover == Target::Reset(rr.clone())) {
                        let tint = self.button_tint(None, *hover == Target::Reset(rr.clone()), resettable, 1.0);
                        self.icon(c, SQIcon::Reset, g.reset_frame(h), 10.0, tint);
                    }
                }
                self.label(c, "Speed", h, None, None);
            }
            SpeedControl::Reverse | SpeedControl::KeepPitch => {
                let on = if k == SpeedControl::Reverse { model.is_reversed() } else { model.keeps_pitch() };
                InspectorDraw::checkbox(
                    c,
                    if on { CheckState::On } else { CheckState::Off },
                    self.checkbox_frame(h),
                    *hover == Target::Checkbox(rr.clone()),
                    self.press_target == Target::Checkbox(rr.clone()),
                    true,
                    false,
                    &t,
                );
                self.label(c, if k == SpeedControl::Reverse { "Reverse" } else { "Keep Pitch" }, h, None, None);
            }
            SpeedControl::TimeInterpolation => self.label(c, "Keep Pitch", h, None, None),
        }
    }

    // MARK: Reorder (EffectControlsView.effectBlocks / reorderMoved / reorderEnded)

    pub(super) fn effect_blocks(&self) -> Vec<(EffectSection, CGRect)> {
        let mut out = Vec::new();
        for (i, row) in self.rows.iter().enumerate() {
            let EffectRowKind::Section(s) = &row.kind else { continue };
            if s.effect_kind().is_none() {
                continue;
            }
            let next = self.rows[i + 1..].iter().find(|r| matches!(r.kind, EffectRowKind::Section(_)));
            let end = next.map_or(self.content_height(), |r| r.y);
            out.push((s.clone(), CGRect::new(0.0, row.y, self.size.width, end - row.y)));
        }
        out
    }

    fn drop_line_y(&self) -> Option<f64> {
        let (section, target) = self.reordering.as_ref()?;
        let target = (*target)?;
        let blocks = self.effect_blocks();
        let from = blocks.iter().position(|b| &b.0 == section)?;
        if target == from || target >= blocks.len() {
            return None;
        }
        Some(if target < from { blocks[target].1.min_y() } else { blocks[target].1.max_y() } - self.scroll_y)
    }
}

/// What the ring, navigation, Open and reset of a keyframable row show.
struct KeyControls {
    state: KeyframeControlState,
    shows_open: bool,
    is_open: bool,
    resettable: bool,
}

/// `CGRect.union`.
pub(crate) fn union(a: CGRect, b: CGRect) -> CGRect {
    let x = a.min_x().min(b.min_x());
    let y = a.min_y().min(b.min_y());
    CGRect::new(x, y, a.max_x().max(b.max_x()) - x, a.max_y().max(b.max_y()) - y)
}

impl EffectControlsModel {
    /// The number fields of a parameter row (PropertyRow.components): Scale shows Width and Height while its link is off,
    /// positions always show X and Y.
    pub fn value_components(&self, p: &EffectProperty) -> Vec<EffectComponent> {
        if p.pair().is_some_and(|x| x.linkable) && self.is_linked(p) {
            return vec![EffectComponent::All]; // P5: Transform Scale, linked
        }
        if p.kind() == crate::ec::effect_controls_model::property::EffectPropertyKind::Vector
            || (*p == EffectProperty::Scale && !self.uniform_scale)
        {
            return vec![EffectComponent::X, EffectComponent::Y];
        }
        vec![EffectComponent::All]
    }
}
