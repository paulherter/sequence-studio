// Swift: EasingPopoverDraw.swift
//! The curve popover on the shared toolkit: `EasingCurvePopoverController` and `EaseSpeedEditorView` translated. The
//! chip items, their thumbnail math and the model's ease source are shared with the Mac popover.
//!
//! The popover does not hold its [`EaseCurveSource`]: every call that reads or writes it gets `&mut dyn EaseCurveSource`
//! (docs/rust/session-ui-design.md section 2). Saving a preset goes out as [`EasingPopoverEvent::Save`]; the preset
//! store itself (`EasingPresets` in Swift, async in SQLibrary) belongs to the library crate.

use std::collections::BTreeSet;

use sq_core_model::keyframes_speed_hill::{EaseTrackSegment, SpeedHill};
use sq_core_model::{EaseReading, EaseShape, EasingCurveShape};
use sq_core_time::ease_names::ease_name;
use sq_core_time::{
    EaseHandle, EaseSide, EasingCurve, EasingLibrary, Id, Interpolation, SpringEasing, SpringPreset, Time,
};
use sq_draw::draw_list::Color;
use sq_draw::theme::type_size;
use sq_draw::{Canvas, DrawTheme, InputKey, InputModifiers, InspectorTokens, TextAlign, TextFieldControl, UiCx};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::ease_curve_source::EaseCurveSource;
use sq_uikit::sqmenu_model::SQMenuLayout;

use super::inline_speed_graph_draw::{InlineSpeedGraphDraw, RowPaint};
use super::{button, text_at, text_in};
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::lane_geometry::KeyframeLaneGeometry;
use crate::keyframes::ease_handle_drag_math::EaseHandleDragMath;
use crate::keyframes::speed_graph_geometry::{SpeedGraphGeometry, SpeedGraphHit};

impl EaseCurveSource for EffectControlsModel {
    fn ease_reading(&self) -> EaseReading {
        EffectControlsModel::ease_reading(self).unwrap_or(EaseReading::Empty)
    }
    fn apply_ease_shape(&mut self, shape: EaseShape) {
        EffectControlsModel::apply_ease_shape(self, &shape);
    }
    fn begin_gesture(&mut self) {
        EffectControlsModel::begin_gesture(self);
    }
    fn end_gesture(&mut self) {
        EffectControlsModel::end_gesture(self);
    }
    fn session_easing_curves(&self) -> Vec<EasingCurve> {
        self.easing_library.user_curves().to_vec()
    }
    fn observe_ease_inputs(&self) {}
    fn empty_ease_hint(&self) -> String {
        "Select keyframes to ease".to_string()
    }
    fn can_bake_spring(&self) -> bool {
        true
    }
    fn apply_spring(&mut self, spring: &SpringEasing) {
        EffectControlsModel::apply_spring(self, spring);
    }
}

impl EffectControlsModel {
    /// Spring presets bake plain linear keys into every selected segment (the file format has no spring): one undo step.
    pub fn apply_spring(&mut self, spring: &SpringEasing) {
        use sq_core_model::EaseSelection;
        use sq_core_model::keyframes_editing::KeyframeSummary;
        let Some(c) = self.working_clip() else { return };
        if self.selection.is_empty() {
            return;
        }
        let mut s = KeyframeSummary::new(Self::tracks_of(&c));
        let sel = EaseSelection::new(&s.clone(), &self.selection, &Self::stepped_properties(&c));
        if sel.bake(spring, &mut s, &mut *self.ids) == 0 {
            return;
        }
        let mut out = c;
        self.write(&s.tracks.clone(), &mut out);
        self.commit(out, "Apply Spring", None);
    }
}

/// One entry of the preset strip under the curve editor: a bezier curve (applies as handles) or a spring (bakes keys).
#[derive(Clone, Debug, PartialEq)]
pub enum EasingChipItem {
    /// A bezier curve.
    Curve(EasingCurve),
    /// A spring.
    Spring(SpringPreset),
}

impl EasingChipItem {
    /// Shown name.
    pub fn name(&self) -> String {
        match self {
            EasingChipItem::Curve(c) => c.display_name().to_string(),
            EasingChipItem::Spring(s) => s.name.to_string(),
        }
    }

    /// Eased progress at `count` points, straight from the core (`previewSamples`).
    pub fn samples(&self, count: i64) -> Vec<f64> {
        match self {
            EasingChipItem::Curve(c) => c.preview_samples(count),
            EasingChipItem::Spring(s) => s.spring.preview_samples(count),
        }
    }
}

/// Thumbnail of an easing curve: pure point math (testable); the Mac renders an image from it. y down.
pub enum EasingThumbnail {}

impl EasingThumbnail {
    /// Samples mapped into `rect`. The vertical range is 0...1 widened to the samples' extent (springs overshoot), so
    /// the start and end values stay on the same two lines for every thumbnail that does not overshoot.
    pub fn points(samples: &[f64], rect: CGRect) -> Vec<CGPoint> {
        if samples.len() <= 1 {
            return Vec::new();
        }
        let lo = samples.iter().copied().fold(f64::INFINITY, f64::min).min(0.0);
        let hi = samples.iter().copied().fold(f64::NEG_INFINITY, f64::max).max(1.0);
        let n = (samples.len() - 1) as f64;
        samples
            .iter()
            .enumerate()
            .map(|(i, v)| {
                CGPoint::new(
                    rect.min_x() + rect.width * i as f64 / n,
                    rect.max_y() - rect.height * ((v - lo) / (hi - lo)),
                )
            })
            .collect()
    }
}

/// The chip list of the strip.
pub enum EasingCurveChips {}

impl EasingCurveChips {
    /// Built-ins first, then saved presets, then curves saved this session from the graph (no duplicates). Without
    /// `hold` no Hold curve is offered (a source that refuses it, e.g. a transition).
    pub fn curves(saved: &[EasingCurve], session: &[EasingCurve], hold: bool) -> Vec<EasingCurve> {
        let mut out = EasingCurve::built_ins();
        if !hold {
            out.retain(|c| !c.interpolation().is_hold());
        }
        for c in saved.iter().chain(session) {
            if !out.iter().any(|o| o.id == c.id) && (hold || !c.interpolation().is_hold()) {
                out.push(c.clone());
            }
        }
        out
    }
}

/// What the speed editor asks of its source.
#[derive(Clone, Copy, Debug, PartialEq)]
enum EditorEvent {
    Begin,
    Change(EaseShape),
    End,
}

struct EditorDrag {
    side: EaseSide,
    base: EaseTrackSegment,
    grab: CGSize,
    origin: CGPoint,
    geometry: SpeedGraphGeometry,
    vertical: bool,
}

/// The speed curve of one eased stretch (`EaseSpeedEditorView`): the single-segment graph that fills the view, both
/// handles shown; sideways sets a handle's Reach, up and down (past the dead zone) the speed at its key.
pub struct EaseSpeedEditorDraw {
    /// What the source shows.
    pub reading: EaseReading,
    /// Text when there is nothing to ease.
    pub empty_hint: String,
    /// What the value part of a handle may be.
    pub value_range: std::ops::RangeInclusive<f64>,
    /// Size in points.
    pub size: CGSize,
    drag: Option<EditorDrag>,
    drag_shape: Option<EaseShape>,
    hovered: Option<EaseSide>,
    events: Vec<EditorEvent>,
}

impl Default for EaseSpeedEditorDraw {
    fn default() -> Self {
        Self::new()
    }
}

impl EaseSpeedEditorDraw {
    const INSET: f64 = 18.0;

    /// An editor with nothing to show.
    pub fn new() -> EaseSpeedEditorDraw {
        EaseSpeedEditorDraw {
            reading: EaseReading::Empty,
            empty_hint: "Nothing to ease".to_string(),
            value_range: -2.0..=3.0,
            size: CGSize::default(),
            drag: None,
            drag_shape: None,
            hovered: None,
            events: Vec::new(),
        }
    }

    /// The handle under the pointer.
    pub fn hovered(&self) -> Option<EaseSide> {
        self.hovered
    }

    fn from_id() -> Id {
        Id::from_u128(1)
    }
    fn to_id() -> Id {
        Id::from_u128(2)
    }

    /// The shape drawn: the one being dragged, the common one, or a straight line for mixed readings.
    pub fn shown_shape(&self) -> Option<EaseShape> {
        if let Some(s) = self.drag_shape {
            return Some(s);
        }
        match &self.reading {
            EaseReading::Empty => None,
            EaseReading::Common(s) => Some(*s),
            EaseReading::Mixed(_) => Some(EaseShape::LINEAR),
        }
    }

    fn is_mixed(&self) -> bool {
        matches!(self.reading, EaseReading::Mixed(_)) && self.drag_shape.is_none()
    }

    fn segment_of(shape: EaseShape) -> EaseTrackSegment {
        EaseTrackSegment::new(Self::from_id(), Self::to_id(), Time::ZERO, Time::new(1, 1), shape, None)
    }

    /// The segment drawn.
    pub fn segment(&self) -> Option<EaseTrackSegment> {
        self.shown_shape().map(Self::segment_of)
    }

    fn ghosts(&self) -> Vec<EaseTrackSegment> {
        match &self.reading {
            EaseReading::Mixed(shapes) if self.drag_shape.is_none() => {
                shapes.iter().copied().map(Self::segment_of).collect()
            }
            _ => Vec::new(),
        }
    }

    /// The geometry of the stretch (frozen while a handle is dragged).
    pub fn geometry(&self) -> SpeedGraphGeometry {
        if let Some(d) = &self.drag {
            return d.geometry;
        }
        let all: Vec<EaseTrackSegment> = self.segment().into_iter().chain(self.ghosts()).collect();
        let mut g = SpeedGraphGeometry::with(
            KeyframeLaneGeometry::with(self.size.width, Time::new(1, 1), Self::INSET, None),
            self.size.height,
            SpeedGraphGeometry::peak_of(&all),
        );
        g.low = SpeedGraphGeometry::low_of(&all);
        g
    }

    /// "Overshoot 12%" / "Wind-Up 8%" when the value leaves the span between its keys, else nil.
    pub fn readout(&self) -> Option<String> {
        if self.is_mixed() {
            return None;
        }
        let (below, above) = self.shown_shape()?.value_excursion();
        let pct = |v: f64| (v >= 0.005).then(|| format!("{}%", (v * 100.0).round() as i64));
        let parts: Vec<String> =
            [pct(below).map(|p| format!("Wind-Up {p}")), pct(above).map(|p| format!("Overshoot {p}"))]
                .into_iter()
                .flatten()
                .collect();
        if parts.is_empty() { None } else { Some(parts.join("  ")) }
    }

    /// The handle at `p`.
    pub fn handle_at(&self, p: CGPoint) -> Option<EaseSide> {
        let s = self.segment()?;
        let sel = BTreeSet::from([Self::from_id(), Self::to_id()]);
        match self.geometry().hit_test(p, &[vec![s]], &[sel]) {
            SpeedGraphHit::Handle { side, .. } => Some(side),
            _ => None,
        }
    }

    /// Draws the editor.
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme) {
        let geo = self.geometry();
        let w = self.size.width;
        let b = geo.baseline();
        c.fill(CGRect::new(0.0, b.round(), w, 1.0), t.graph_grid());
        InlineSpeedGraphDraw::dashed_h(c, (b - geo.unit_height()).round(), 0.0, w, t.graph_grid());
        let none = BTreeSet::new();
        let ghosts = self.ghosts();
        for g in &ghosts {
            let segs = [g.clone()];
            InlineSpeedGraphDraw::draw_row(
                c,
                &geo,
                t,
                &RowPaint { width: w, segments: &segs, selected: &none, color: t.label3() },
                &|_, _| false,
            );
        }
        let Some(s) = self.segment() else {
            if ghosts.is_empty() {
                text_in(
                    c,
                    &self.empty_hint,
                    CGRect::new(0.0, 0.0, self.size.width, self.size.height),
                    type_size::BODY as f64,
                    t.label3(),
                    TextAlign::Center,
                );
            }
            return;
        };
        let selected = BTreeSet::from([Self::from_id(), Self::to_id()]);
        let hovered = self.hovered;
        let dragging = self.drag.as_ref().map(|d| d.side);
        let segs = [s];
        InlineSpeedGraphDraw::draw_row(
            c,
            &geo,
            t,
            &RowPaint {
                width: w,
                segments: &segs,
                selected: &selected,
                color: if self.is_mixed() { Color::CLEAR } else { t.accent() },
            },
            &|_, side| Some(side) == hovered || Some(side) == dragging,
        );
        if let Some(r) = self.readout() {
            let caption = type_size::CAPTION as f64;
            let sz = c.size_of(&r, caption, 0);
            text_at(c, &r, CGPoint::new(w - sz.width - 8.0, 5.0), caption, t.label2());
        }
    }

    /// The pointer moved over the editor (`None`: it left).
    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        if self.drag.is_none() {
            self.hovered = p.and_then(|p| self.handle_at(p));
        }
    }

    /// Press at `p`; true when it grabbed a handle.
    pub fn press(&mut self, p: CGPoint) -> bool {
        let Some(s) = self.segment() else { return false };
        let Some(side) = self.handle_at(p) else { return false };
        let geo = self.geometry();
        let end = geo.handle_true_end(&s, side);
        let speed = if side == EaseSide::In { s.shape.speed_in() } else { s.shape.speed_out() };
        let true_y = geo.baseline() - speed * geo.unit_height();
        self.drag = Some(EditorDrag {
            side,
            base: s,
            grab: CGSize::new(end.x - p.x, true_y - p.y),
            origin: p,
            geometry: geo,
            vertical: false,
        });
        self.events.push(EditorEvent::Begin);
        true
    }

    /// Drag to `p`.
    pub fn drag_gesture(&mut self, p: CGPoint, shift: bool) {
        let Some(d) = self.drag.as_mut() else { return };
        let v = EaseHandleDragMath::is_vertical(d.vertical, d.origin.y, p.y, shift);
        if v != d.vertical {
            d.vertical = v;
        }
        let reach = d.geometry.reach(p.x + d.grab.width, &d.base, d.side);
        let mut s = d.base.shape.setting_reach(reach, d.side);
        let speed = if d.vertical {
            d.geometry.speed_at_y(p.y + d.grab.height)
        } else if d.side == EaseSide::In {
            s.speed_in()
        } else {
            s.speed_out()
        };
        s = s.setting_speed(speed, d.side, Some(&self.value_range));
        self.drag_shape = Some(s);
        self.events.push(EditorEvent::Change(s));
    }

    /// Release.
    pub fn release(&mut self) {
        if self.drag.is_none() {
            return;
        }
        self.drag = None;
        self.drag_shape = None;
        self.events.push(EditorEvent::End);
    }

    /// Hands the gesture events collected so far to `source`.
    pub fn forward(&mut self, source: &mut dyn EaseCurveSource) {
        for e in std::mem::take(&mut self.events) {
            match e {
                EditorEvent::Begin => source.begin_gesture(),
                EditorEvent::Change(s) => source.apply_ease_shape(s),
                EditorEvent::End => source.end_gesture(),
            }
        }
    }
}

// Keep the reach floor in one place with the inline graph.
const _: f64 = SpeedHill::MIN_REACH;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Part {
    Editor,
    Chip(usize),
    /// The pinned Custom chip: a mini curve with two handles to drag.
    Custom,
    Name,
    Save,
}

/// What the popover asks its host to do.
#[derive(Clone, Debug, PartialEq)]
pub enum EasingPopoverEvent {
    /// `onSave`: the shape and the typed name.
    Save(EaseShape, String),
}

/// The curve popover (`EasingCurvePopoverController`, 260 x 200): the speed curve, the preset chips under it (scroll
/// sideways), a name field with Save. Coordinates: the popover's points, (0, 0) top left, chrome included. The host
/// places it (`ColorPickerControl.frame`-style rule in `frame(anchor:in:)`), routes events and saves presets.
pub struct EasingPopoverDraw {
    /// The user's saved curves (the Mac `EasingPresetLibrary.saved`); the host fills it.
    pub saved: Vec<EasingCurve>,
    editor: EaseSpeedEditorDraw,
    /// The shape the Custom chip's drag started from.
    custom_base: Option<EaseShape>,
    chips: Vec<EasingChipItem>,
    chip_scroll: f64,
    name: TextFieldControl,
    hover: Option<Part>,
    pressed: Option<Part>,
    events: Vec<EasingPopoverEvent>,
}

impl EasingPopoverDraw {
    /// Size of the popover.
    pub const SIZE: CGSize = CGSize { width: 260.0, height: 200.0 };
    const PAD: f64 = 8.0;
    const CHIP_WIDTH: f64 = 40.0;
    const CHIP_GAP: f64 = 4.0;
    const THUMB: CGSize = CGSize { width: 34.0, height: 22.0 };
    const EDITOR_FRAME: CGRect = CGRect { x: 0.0, y: 0.0, width: 260.0, height: 126.0 };
    const CHIP_STRIP: CGRect = CGRect { x: 0.0, y: 132.0, width: 260.0, height: 26.0 };
    /// The Custom chip, pinned at the strip's right end (redesign #35): label "Custom" and a draggable mini curve.
    pub const CUSTOM_FRAME: CGRect = CGRect { x: 260.0 - 8.0 - 92.0, y: 132.0, width: 92.0, height: 26.0 };
    /// The word on the Custom chip.
    pub const CUSTOM_LABEL: &'static str = ease_name::CUSTOM;
    const NAME_FRAME: CGRect = CGRect { x: 8.0, y: 167.0, width: 260.0 - 2.0 * 8.0 - 64.0, height: 24.0 };
    const SAVE_FRAME: CGRect = CGRect { x: 260.0 - 8.0 - 60.0, y: 167.0, width: 60.0, height: 24.0 };

    /// A popover for `source`.
    pub fn new(source: &dyn EaseCurveSource) -> EasingPopoverDraw {
        let mut name = TextFieldControl::new("");
        name.alignment = sq_draw::Alignment::Left;
        name.font_size = type_size::BODY as f64;
        let mut p = EasingPopoverDraw {
            saved: Vec::new(),
            editor: EaseSpeedEditorDraw::new(),
            custom_base: None,
            chips: Vec::new(),
            chip_scroll: 0.0,
            name,
            hover: None,
            pressed: None,
            events: Vec::new(),
        };
        p.refresh(source);
        p
    }

    /// Takes the events pushed since the last call.
    pub fn take_events(&mut self) -> Vec<EasingPopoverEvent> {
        std::mem::take(&mut self.events)
    }

    /// The preset strip.
    pub fn chips(&self) -> &[EasingChipItem] {
        &self.chips
    }
    /// How far the strip is scrolled.
    pub fn chip_scroll(&self) -> f64 {
        self.chip_scroll
    }
    /// The speed curve editor.
    pub fn editor(&self) -> &EaseSpeedEditorDraw {
        &self.editor
    }
    /// The name field.
    pub fn name(&self) -> &TextFieldControl {
        &self.name
    }
    /// The name field, mutable.
    pub fn name_mut(&mut self) -> &mut TextFieldControl {
        &mut self.name
    }

    // MARK: Layout

    fn chip_frame(&self, i: usize) -> CGRect {
        CGRect::new(
            Self::PAD + i as f64 * (Self::CHIP_WIDTH + Self::CHIP_GAP) - self.chip_scroll,
            Self::CHIP_STRIP.min_y(),
            Self::CHIP_WIDTH,
            Self::CHIP_STRIP.height,
        )
    }
    fn chips_width(&self) -> f64 {
        2.0 * Self::PAD + self.chips.len() as f64 * (Self::CHIP_WIDTH + Self::CHIP_GAP) - Self::CHIP_GAP
    }
    /// How far the strip may scroll: the preset chips end left of the pinned Custom chip.
    fn max_scroll(&self) -> f64 {
        (self.chips_width() - (Self::CUSTOM_FRAME.min_x() - Self::CHIP_GAP + Self::PAD)).max(0.0)
    }
    /// Where the Custom chip's mini curve is drawn and dragged.
    pub fn custom_plot() -> CGRect {
        let f = Self::CUSTOM_FRAME;
        CGRect::new(f.min_x() + 5.0, f.min_y() + 5.0, 34.0, f.height - 10.0)
    }
    /// The shape a drag at `nx`, `ny` (0...1 inside the mini plot, y up) makes of `base`: left half moves the out handle,
    /// right half the in handle. Always a bezier.
    pub fn custom_shape(base: EaseShape, nx: f64, ny: f64) -> EaseShape {
        let (nx, ny) = (nx.clamp(0.0, 1.0), ny.clamp(0.0, 1.0));
        let (mut out, mut inn) = (base.out, base.r#in);
        if base.interpolation() != Interpolation::Bezier {
            (out, inn) = (EaseHandle::LINEAR, EaseHandle::LINEAR);
        }
        if nx < 0.5 {
            out = EaseHandle { dx: nx, dy: ny };
        } else {
            inn = EaseHandle { dx: 1.0 - nx, dy: 1.0 - ny };
        }
        EaseShape::new(Interpolation::Bezier, out, inn)
    }
    fn custom_point(&self, p: CGPoint) -> (f64, f64) {
        let r = Self::custom_plot();
        ((p.x - r.min_x()) / r.width, 1.0 - (p.y - r.min_y()) / r.height)
    }
    /// Whether the current shape is none of the preset chips (the Custom chip lights up).
    fn is_custom(&self, source: &dyn EaseCurveSource) -> bool {
        Self::common(source).is_some_and(|cur| {
            !self.chips.iter().any(|i| matches!(i, EasingChipItem::Curve(c) if c.shape().is_approximately_equal(&cur)))
        })
    }

    /// Below the anchor, above when it does not fit, kept inside `visible` (SQPopoverLogic: gap 4, margin 6).
    pub fn frame(anchor: CGRect, visible: CGRect) -> CGRect {
        let s = Self::SIZE;
        let gap = 4.0;
        let area = visible.inset_by(6.0, 6.0);
        let mut y = anchor.max_y() + gap;
        if y + s.height > area.max_y() && anchor.min_y() - gap - s.height >= area.min_y() {
            y = anchor.min_y() - gap - s.height;
        }
        let x = (anchor.mid_x() - s.width / 2.0).max(area.min_x()).min(area.min_x().max(area.max_x() - s.width));
        CGRect::new(x, y, s.width, s.height)
    }

    fn part_at(&self, p: CGPoint) -> Option<Part> {
        if Self::EDITOR_FRAME.contains(p) {
            return Some(Part::Editor);
        }
        if Self::CUSTOM_FRAME.contains(p) {
            return Some(Part::Custom);
        }
        if Self::CHIP_STRIP.contains(p) {
            if p.x >= Self::CUSTOM_FRAME.min_x() - Self::CHIP_GAP {
                return None;
            }
            return (0..self.chips.len()).find(|&i| self.chip_frame(i).contains(p)).map(Part::Chip);
        }
        if Self::NAME_FRAME.contains(p) {
            return Some(Part::Name);
        }
        if Self::SAVE_FRAME.contains(p) {
            return Some(Part::Save);
        }
        None
    }

    fn common(source: &dyn EaseCurveSource) -> Option<EaseShape> {
        match source.ease_reading() {
            EaseReading::Common(s) => Some(s),
            _ => None,
        }
    }

    /// Reads the source again (call after every model change while open).
    pub fn refresh(&mut self, source: &dyn EaseCurveSource) {
        self.editor.reading = source.ease_reading();
        self.editor.empty_hint = source.empty_ease_hint();
        self.editor.value_range = source.handle_value_range();
        self.editor.size = Self::EDITOR_FRAME.into_size();
        let mut items: Vec<EasingChipItem> =
            EasingCurveChips::curves(&self.saved, &source.session_easing_curves(), source.allows_hold())
                .into_iter()
                .map(EasingChipItem::Curve)
                .collect();
        if source.can_bake_spring() {
            items.extend(EasingLibrary::spring_presets().into_iter().map(EasingChipItem::Spring));
        }
        self.chips = items;
        self.chip_scroll = self.chip_scroll.min(self.max_scroll());
    }

    // MARK: Input

    /// Press at `p`.
    pub fn mouse_down(&mut self, source: &mut dyn EaseCurveSource, p: CGPoint) {
        let hit = self.part_at(p);
        if hit != Some(Part::Name) && self.name.is_editing() {
            let _ = self.name.commit();
        }
        self.pressed = hit;
        match hit {
            Some(Part::Editor) => {
                self.editor.press(p);
                self.editor.forward(source);
            }
            Some(Part::Name) => self.name.mouse_down(None, 1),
            Some(Part::Custom) if source.ease_reading() != EaseReading::Empty => {
                let base = Self::common(source).unwrap_or(EaseShape::LINEAR);
                self.custom_base = Some(base);
                source.begin_gesture();
                let (nx, ny) = self.custom_point(p);
                source.apply_ease_shape(Self::custom_shape(base, nx, ny));
            }
            _ => {}
        }
    }

    /// Drag to `p`.
    pub fn mouse_dragged(&mut self, source: &mut dyn EaseCurveSource, p: CGPoint, modifiers: InputModifiers) {
        if self.pressed == Some(Part::Editor) {
            self.editor.drag_gesture(p, modifiers.contains(InputModifiers::SHIFT));
            self.editor.forward(source);
        } else if self.pressed == Some(Part::Custom)
            && let Some(base) = self.custom_base
        {
            let (nx, ny) = self.custom_point(p);
            source.apply_ease_shape(Self::custom_shape(base, nx, ny));
        }
    }

    /// Release at `p`.
    pub fn mouse_up(&mut self, source: &mut dyn EaseCurveSource, p: CGPoint) {
        let pressed = self.pressed.take();
        match pressed {
            Some(Part::Editor) => {
                self.editor.release();
                self.editor.forward(source);
            }
            Some(Part::Custom) if self.custom_base.take().is_some() => source.end_gesture(),
            Some(Part::Chip(i))
                if self.part_at(p) == Some(Part::Chip(i)) && source.ease_reading() != EaseReading::Empty =>
            {
                let item = self.chips[i].clone();
                Self::apply(source, &item);
            }
            Some(Part::Save) if self.part_at(p) == Some(Part::Save) => self.save(source),
            _ => {}
        }
        self.refresh(source);
    }

    /// The pointer moved over the popover (`None`: it left).
    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        self.hover = p.and_then(|p| self.part_at(p));
        self.editor.mouse_moved(if self.hover == Some(Part::Editor) { p } else { None });
        self.name.hovering = self.hover == Some(Part::Name);
    }

    /// The chip strip scrolls sideways (wheel or trackpad).
    pub fn scroll(&mut self, p: CGPoint, dx: f64, dy: f64) -> bool {
        if !Self::CHIP_STRIP.contains(p) {
            return false;
        }
        let d = if dx.abs() > dy.abs() { dx } else { dy };
        self.chip_scroll = (self.chip_scroll - d).max(0.0).min(self.max_scroll());
        true
    }

    /// Keys of the name field; Enter there saves (the Mac field's action is the Save button). False: not taken.
    pub fn key(&mut self, source: &dyn EaseCurveSource, k: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> bool {
        if !self.name.is_editing() {
            return false;
        }
        if k == InputKey::Enter {
            let _ = self.name.commit();
            self.save(source);
            return true;
        }
        let _ = self.name.key(k, modifiers, cx);
        true
    }

    fn apply(source: &mut dyn EaseCurveSource, item: &EasingChipItem) {
        match item {
            EasingChipItem::Curve(c) => source.apply_ease_shape(c.shape()),
            EasingChipItem::Spring(s) => source.apply_spring(&s.spring),
        }
    }

    fn save(&mut self, source: &dyn EaseCurveSource) {
        let Some(shape) = Self::common(source) else { return };
        let n = self.name.commit().unwrap_or_else(|| self.name.text.clone());
        self.name.text = String::new();
        self.events.push(EasingPopoverEvent::Save(shape, n));
    }

    // MARK: Drawing

    /// Draws the popover.
    pub fn draw(&mut self, source: &dyn EaseCurveSource, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        self.refresh(source);
        let bounds = CGRect::new(0.0, 0.0, Self::SIZE.width, Self::SIZE.height);
        let radius = SQMenuLayout::CORNER_RADIUS;
        c.shadow(bounds, radius, 10.0, 4.0, Color::new(0.0, 0.0, 0.0, 0.25), false);
        c.fill_rounded(bounds, radius, t.overlay());
        // The editor's content fill under the rounded top corners (the popover window clips its content on the Mac).
        let e = Self::EDITOR_FRAME;
        c.fill_rounded(e, radius, t.content());
        c.fill(CGRect::new(e.min_x(), e.min_y() + radius, e.width, e.height - radius), t.content());
        c.save_gstate();
        c.clip_to(e);
        self.editor.draw(c, t);
        c.restore_gstate();
        c.stroke_rounded(bounds.inset_by(0.25, 0.25), radius, 0.5, t.ink_fill(0.14));
        let enabled = source.ease_reading() != EaseReading::Empty;
        let current = Self::common(source);
        c.save_gstate();
        c.clip_to(CGRect::new(
            0.0,
            Self::CHIP_STRIP.min_y(),
            Self::CUSTOM_FRAME.min_x() - Self::CHIP_GAP,
            Self::CHIP_STRIP.height,
        ));
        for (i, item) in self.chips.iter().enumerate() {
            let f = self.chip_frame(i);
            if f.max_x() <= 0.0 || f.min_x() >= Self::SIZE.width {
                continue;
            }
            let on = match item {
                EasingChipItem::Curve(cv) => current.is_some_and(|cur| cv.shape().is_approximately_equal(&cur)),
                EasingChipItem::Spring(_) => false,
            };
            let hot = self.hover == Some(Part::Chip(i)) && enabled;
            let down = self.pressed == Some(Part::Chip(i));
            let fill = if on {
                t.accent_tint()
            } else if down {
                t.fill_pressed()
            } else if hot {
                t.fill_hover()
            } else {
                t.fill()
            };
            let boxr = f.inset_by(0.0, 1.0);
            let dim = if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
            c.fill_rounded(boxr, InspectorTokens::radius(boxr), fill.with_alpha(fill.a * dim));
            let plot = CGRect::new(
                f.mid_x() - Self::THUMB.width / 2.0,
                f.mid_y() - Self::THUMB.height / 2.0,
                Self::THUMB.width,
                Self::THUMB.height,
            )
            .inset_by(5.0, 4.0);
            let ink = if on { t.accent() } else { t.label() };
            c.stroke_polyline(&EasingThumbnail::points(&item.samples(32), plot), 1.5, ink.with_alpha(ink.a * dim));
        }
        c.restore_gstate();
        self.draw_custom_chip(source, c, t, enabled);
        self.name.draw(c, Self::NAME_FRAME, t, self.name.is_editing(), cx);
        if !self.name.is_editing() && self.name.text.is_empty() {
            text_in(
                c,
                "Preset name",
                Self::NAME_FRAME.inset_by(6.0, 0.0),
                type_size::BODY as f64,
                t.label3(),
                TextAlign::Left,
            );
        }
        button(
            c,
            "Save",
            Self::SAVE_FRAME,
            self.hover == Some(Part::Save),
            self.pressed == Some(Part::Save),
            current.is_some(),
            t,
        );
    }

    /// The Custom chip: the current curve as a mini plot with its two handles, the word beside it.
    fn draw_custom_chip(&self, source: &dyn EaseCurveSource, c: &mut Canvas, t: &DrawTheme, enabled: bool) {
        let f = Self::CUSTOM_FRAME;
        let on = self.is_custom(source);
        let hot = self.hover == Some(Part::Custom) && enabled;
        let fill = if on {
            t.accent_tint()
        } else if self.pressed == Some(Part::Custom) {
            t.fill_pressed()
        } else if hot {
            t.fill_hover()
        } else {
            t.fill()
        };
        let dim = if enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
        let boxr = f.inset_by(0.0, 1.0);
        c.fill_rounded(boxr, InspectorTokens::radius(boxr), fill.with_alpha(fill.a * dim));
        let ink = if on { t.accent() } else { t.label() };
        let ink = ink.with_alpha(ink.a * dim);
        let plot = Self::custom_plot();
        let shape = Self::common(source).unwrap_or(EaseShape::LINEAR);
        let curve = EasingCurve::new(Id::NIL, String::new(), shape.interpolation(), shape.out, shape.r#in);
        c.stroke_polyline(&EasingThumbnail::points(&curve.preview_samples(32), plot), 1.5, ink);
        for (dx, dy) in [(shape.out.dx, shape.out.dy), (1.0 - shape.r#in.dx, 1.0 - shape.r#in.dy)] {
            let (x, y) =
                (plot.min_x() + plot.width * dx.clamp(0.0, 1.0), plot.max_y() - plot.height * dy.clamp(0.0, 1.0));
            c.fill_rounded(CGRect::new(x - 2.0, y - 2.0, 4.0, 4.0), 2.0, ink);
        }
        text_in(
            c,
            Self::CUSTOM_LABEL,
            CGRect::new(plot.max_x() + 6.0, f.min_y(), f.max_x() - plot.max_x() - 8.0, f.height),
            type_size::CAPTION as f64,
            ink,
            TextAlign::Left,
        );
    }

    /// The chip's tooltip (springs bake keys), the Save button's.
    pub fn help(&self, p: CGPoint) -> Option<String> {
        match self.part_at(p)? {
            Part::Chip(i) => Some(match &self.chips[i] {
                EasingChipItem::Spring(_) => format!("{} (bakes keys)", self.chips[i].name()),
                _ => self.chips[i].name(),
            }),
            Part::Custom => Some("Custom: drag the curve".to_string()),
            Part::Save => Some("Save Curve".to_string()),
            _ => None,
        }
    }
}

/// `CGRect.size`.
trait IntoSize {
    fn into_size(self) -> CGSize;
}
impl IntoSize for CGRect {
    fn into_size(self) -> CGSize {
        CGSize::new(self.width, self.height)
    }
}
