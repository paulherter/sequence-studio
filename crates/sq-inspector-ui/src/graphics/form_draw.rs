// Swift: Draw/GraphicsFormDraw.swift
//! The property rows of the Graphics panel on the shared toolkit: the Mac `InspectorSection` / `InspectorRow` /
//! `AppearanceRow` stack, as a list of rows whose values are read through closures on every draw. Sections fold, an
//! Appearance row's chevron opens its detail rows. Coordinates: points, y down, (0, 0) = the form's top-left; the panel
//! scrolls it.
//!
//! The Swift closures captured the `GraphicsEditor`; here the form is generic over the context `C` (the editor and the
//! session the host owns) that every getter and setter receives. Callbacks that need the host (menu, color picker, height
//! change) are requests the host drains with `take_*`; a popup choice or a picked color comes back through `flush` /
//! `change_color`.
//
// The folded sections are remembered in the injected settings store (`set_defaults`), key `sq.inspector.open.graphics.<section>`.

use std::cell::RefCell;
use std::collections::{BTreeSet, HashMap};
use std::rc::Rc;

use crate::open_state::{read_open, write_open};
use sq_core_model::EffectColor;
use sq_draw::inspector::inspector_controls::{CheckState, InspectorDraw, InspectorTokens};
use sq_draw::inspector::scrub_field_control::{ClickCounter, Event, ScrubFieldControl};
use sq_draw::theme::{radius, spacing, type_size};
use sq_draw::{Canvas, Color, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

/// Reads a value; `None` = the targets differ (mixed).
pub type Getter<C> = Rc<dyn Fn(&C) -> Option<f64>>;
/// Writes a value.
pub type Setter<C> = Rc<dyn Fn(&mut C, f64)>;
/// A state read.
pub type Flag<C> = Rc<dyn Fn(&C) -> bool>;
/// An action on the context.
pub type Action<C> = Rc<dyn Fn(&mut C)>;
/// Writes a bool.
pub type BoolSetter<C> = Rc<dyn Fn(&mut C, bool)>;
/// A state read for the nth entry.
pub type IndexFlag<C> = Rc<dyn Fn(&C, usize) -> bool>;
/// Picks the nth entry.
pub type ChooseFn<C> = Rc<dyn Fn(&mut C, usize)>;
/// Reads a color; `None` = mixed or off.
pub type ColorGetter<C> = Rc<dyn Fn(&C) -> Option<EffectColor>>;
/// Writes a color.
pub type ColorSetter<C> = Rc<dyn Fn(&mut C, EffectColor)>;
/// Reads the selected popup entry.
pub type SelectedFn<C> = Rc<dyn Fn(&C) -> Option<usize>>;
/// Reads a tri-state.
pub type TriGetter<C> = Rc<dyn Fn(&C) -> Option<bool>>;

/// One icon button of an Icons row.
pub struct IconItem<C> {
    pub icon: SQIcon,
    pub title: String,
    pub enabled: Flag<C>,
    pub selected: Flag<C>,
    /// Shown instead of `icon` while `selected` is false (Link Scale: link / unlink, as on the Mac).
    pub off_icon: Option<SQIcon>,
    pub action: Action<C>,
}

impl<C> IconItem<C> {
    /// An enabled, unselected button with no alternate icon.
    pub fn new(icon: SQIcon, title: &str, action: Action<C>) -> IconItem<C> {
        IconItem {
            icon,
            title: title.to_string(),
            enabled: Rc::new(|_| true),
            selected: Rc::new(|_| false),
            off_icon: None,
            action,
        }
    }
}

/// An action that gets the anchor frame.
pub type AnchorAction<C> = Rc<dyn Fn(&mut C, CGRect)>;

/// One text button of a Buttons row; the action gets the button's frame (the anchor of a menu).
pub struct TextButton<C> {
    pub title: String,
    pub action: AnchorAction<C>,
}

/// What a row is.
pub enum Kind<C> {
    /// Section header: chevron, title; an effect section has the enable eye and a remove button.
    Section {
        title: String,
        key: String,
        enabled: Option<Flag<C>>,
        set_enabled: Option<BoolSetter<C>>,
        remove: Option<Action<C>>,
    },
    /// One to two ScrubFields; `keyed` tints them while the property has keys; `link` is the Scale link button.
    Numbers {
        title: String,
        keyed: Option<Flag<C>>,
        link: Option<IconItem<C>>,
    },
    Popup {
        title: String,
        titles: Vec<String>,
        selected: SelectedFn<C>,
        enabled: Flag<C>,
        choose: ChooseFn<C>,
    },
    Segments {
        title: String,
        labels: Vec<String>,
        selected: Rc<dyn Fn(&C) -> usize>,
        enabled: IndexFlag<C>,
        choose: ChooseFn<C>,
    },
    Icons {
        title: Option<String>,
        items: Vec<IconItem<C>>,
    },
    Check {
        title: String,
        state: Rc<dyn Fn(&C) -> CheckState>,
        toggle: Action<C>,
    },
    Color {
        title: String,
        get: ColorGetter<C>,
        set: ColorSetter<C>,
    },
    /// Check, swatch and the main value (field 0) inline; detail rows (`detail_of` = key) open under the chevron.
    Appearance {
        title: String,
        key: String,
        on: TriGetter<C>,
        set_on: BoolSetter<C>,
        color: ColorGetter<C>,
        set_color: ColorSetter<C>,
        has_detail: bool,
    },
    Label {
        title: String,
        value: String,
    },
    Buttons(Vec<TextButton<C>>),
}

/// One row with its fields.
pub struct Row<C> {
    pub kind: Rc<Kind<C>>,
    /// Appearance key of the row this one details (shown while that row is open).
    pub detail_of: Option<String>,
    /// The section key this row belongs to (hidden while it is folded).
    pub section: Option<String>,
    pub fields: Vec<ScrubFieldControl>,
    getters: Vec<Getter<C>>,
    setters: Vec<Setter<C>>,
}

/// A part of a row that takes the pointer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Part {
    Fold,
    Enable,
    Remove,
    Field(usize),
    Link,
    Popup,
    Segment(usize),
    Icon(usize),
    Check,
    Well,
    AppCheck,
    AppWell,
    Chevron,
    Button(usize),
}

/// A row index and a part.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hit {
    pub row: usize,
    pub part: Part,
}

/// A popup menu the host shows (items and anchor in form coordinates).
pub struct MenuRequest {
    pub items: Vec<SQMenuItem>,
    pub anchor: CGRect,
}

/// A color picker the host opens; answer with `change_color(row, ..)`.
#[derive(Clone, Debug, PartialEq)]
pub struct ColorRequest {
    pub row: usize,
    pub current: EffectColor,
    pub anchor: CGRect,
}

/// A choice made in a popup menu, applied by `flush`.
type Pending = (usize, usize);

pub struct GraphicsFormDraw<C> {
    pub theme: DrawTheme,
    pub width: f64,
    /// A gesture opens (drag, typed value, picker session, popup choice): one undo step.
    pub begin_gesture: Option<Action<C>>,
    rows: Vec<Row<C>>,
    current_section: Option<String>,
    open_details: BTreeSet<String>,
    folded: BTreeSet<String>,
    defaults: Option<Box<dyn UiDefaults>>,
    menu: Option<MenuRequest>,
    color_request: Option<ColorRequest>,
    height_changed: bool,
    pending: Rc<RefCell<Vec<Pending>>>,
    button_widths: HashMap<String, f64>,
    hover: Option<Hit>,
    pressed: Option<Hit>,
    focused: Option<Hit>,
    counter: ClickCounter,
}

impl<C> Default for GraphicsFormDraw<C> {
    fn default() -> Self {
        GraphicsFormDraw {
            theme: DrawTheme::default(),
            width: 300.0,
            begin_gesture: None,
            rows: Vec::new(),
            current_section: None,
            open_details: BTreeSet::new(),
            folded: BTreeSet::new(),
            defaults: None,
            menu: None,
            color_request: None,
            height_changed: false,
            pending: Rc::new(RefCell::new(Vec::new())),
            button_widths: HashMap::new(),
            hover: None,
            pressed: None,
            focused: None,
            counter: ClickCounter::new(),
        }
    }
}

impl<C> GraphicsFormDraw<C> {
    pub const ROW_HEIGHT: f64 = ControlsGrid::ROW_HEIGHT;
    /// The Controls grid's value width, so the form's columns sit under the Text block's and the Controls panel's.
    pub const FIELD_WIDTH: f64 = ControlsGrid::VALUE_WIDTH;
    pub const ICON_SLOT: f64 = 22.0;
    pub const SWATCH: (f64, f64) = (32.0, 18.0);

    pub fn rows(&self) -> &[Row<C>] {
        &self.rows
    }

    pub fn hover(&self) -> Option<Hit> {
        self.hover
    }

    pub fn focused(&self) -> Option<Hit> {
        self.focused
    }

    pub fn open_details(&self) -> &BTreeSet<String> {
        &self.open_details
    }

    /// The menu to show, once.
    pub fn take_menu(&mut self) -> Option<MenuRequest> {
        self.menu.take()
    }

    /// The color picker to open, once.
    pub fn take_color_request(&mut self) -> Option<ColorRequest> {
        self.color_request.take()
    }

    /// True once after a fold or a detail changed the height (the Swift `onHeightChange`).
    pub fn take_height_changed(&mut self) -> bool {
        std::mem::take(&mut self.height_changed)
    }

    // MARK: Building (GraphicsPanelView begin / add / numberRow)

    pub fn reset(&mut self, cx: &mut UiCx, ctx: &mut C) {
        self.resign_focus(ctx, cx);
        self.rows.clear();
        self.current_section = None;
        self.hover = None;
        self.pressed = None;
    }

    pub fn begin(
        &mut self,
        title: &str,
        key: &str,
        enabled: Option<Flag<C>>,
        set_enabled: Option<BoolSetter<C>>,
        remove: Option<Action<C>>,
    ) {
        self.current_section = None;
        self.add(Kind::Section { title: title.to_string(), key: key.to_string(), enabled, set_enabled, remove }, None);
        self.current_section = Some(key.to_string());
    }

    /// Appends a row; returns its index.
    pub fn add(&mut self, kind: Kind<C>, detail_of: Option<&str>) -> usize {
        self.rows.push(Row {
            kind: Rc::new(kind),
            detail_of: detail_of.map(str::to_string),
            section: self.current_section.clone(),
            fields: Vec::new(),
            getters: Vec::new(),
            setters: Vec::new(),
        });
        self.rows.len() - 1
    }

    /// A row of ScrubFields (drag, click to type, arrows step, double-click resets to `reset`), each read and written
    /// through its closure pair.
    #[allow(clippy::too_many_arguments)]
    pub fn numbers(
        &mut self,
        title: &str,
        unit: &str,
        keyed: Option<Flag<C>>,
        decimals: i64,
        reset: Option<&[f64]>,
        range: Option<std::ops::RangeInclusive<f64>>,
        fields: Vec<(Getter<C>, Setter<C>)>,
        link: Option<IconItem<C>>,
        detail_of: Option<&str>,
        ctx: &C,
    ) -> usize {
        let r = self.add(Kind::Numbers { title: title.to_string(), keyed, link }, detail_of);
        self.attach(r, unit, decimals, reset, range, fields, ctx);
        r
    }

    /// The Appearance row with its main value as field 0.
    #[allow(clippy::too_many_arguments)]
    pub fn appearance(
        &mut self,
        kind: Kind<C>,
        value: Getter<C>,
        set_value: Setter<C>,
        unit: &str,
        reset: f64,
        ctx: &C,
    ) -> usize {
        let r = self.add(kind, None);
        self.attach(r, unit, 0, Some(&[reset]), None, vec![(value, set_value)], ctx);
        r
    }

    #[allow(clippy::too_many_arguments)]
    fn attach(
        &mut self,
        r: usize,
        unit: &str,
        decimals: i64,
        reset: Option<&[f64]>,
        range: Option<std::ops::RangeInclusive<f64>>,
        fields: Vec<(Getter<C>, Setter<C>)>,
        ctx: &C,
    ) {
        for (i, (get, set)) in fields.into_iter().enumerate() {
            let mut s = ScrubFieldControl::new(get(ctx).unwrap_or(0.0));
            s.decimals = decimals;
            s.step = if decimals >= 2 { 0.01 } else { 1.0 };
            s.unit = unit.to_string();
            if let Some(range) = range.clone() {
                s.range = range;
            }
            if let Some(v) = reset.and_then(|d| d.get(i)) {
                s.default_value = Some(*v);
            }
            let row = &mut self.rows[r];
            row.fields.push(s);
            row.getters.push(get);
            row.setters.push(set);
        }
    }

    // MARK: Layout

    /// Folded when the stored open flag is false (the Swift `isFolded`); the struct's own set serves without a store.
    pub fn is_folded(&self, key: &str) -> bool {
        match &self.defaults {
            Some(d) => read_open(d.as_ref(), &Self::open_key(key)) == Some(false),
            None => self.folded.contains(key),
        }
    }

    fn open_key(key: &str) -> String {
        format!("sq.inspector.open.graphics.{key}")
    }

    /// Remembers the folded sections in `defaults` (read on every `is_folded`, written by `set_folded`).
    pub fn set_defaults(&mut self, defaults: Box<dyn UiDefaults>) {
        self.defaults = Some(defaults);
        self.height_changed = true;
    }

    pub fn set_folded(&mut self, key: &str, folded: bool, ctx: &mut C, cx: &mut UiCx) {
        if folded {
            self.folded.insert(key.to_string());
        } else {
            self.folded.remove(key);
        }
        if let Some(d) = self.defaults.as_mut() {
            write_open(d.as_mut(), &Self::open_key(key), !folded);
        }
        self.resign_focus(ctx, cx);
        self.height_changed = true;
    }

    /// The row indices on screen in order (folded sections and closed details left out) with their y.
    pub fn visible(&self) -> Vec<(usize, f64)> {
        let mut out = Vec::new();
        let mut y = 0.0;
        for (i, r) in self.rows.iter().enumerate() {
            if r.section.as_ref().is_some_and(|s| self.is_folded(s)) {
                continue;
            }
            if r.detail_of.as_ref().is_some_and(|d| !self.open_details.contains(d)) {
                continue;
            }
            out.push((i, y));
            y += Self::ROW_HEIGHT;
        }
        out
    }

    pub fn height(&self) -> f64 {
        self.visible().len() as f64 * Self::ROW_HEIGHT
    }

    fn control_y(y: f64, h: f64) -> f64 {
        y + ((Self::ROW_HEIGHT - h) / 2.0).round()
    }

    /// The icon strip starts in the value column when the row has a title, else at the toggle column (Arrange).
    fn icons_x(r: &Row<C>) -> f64 {
        match &*r.kind {
            Kind::Icons { title: Some(_), .. } => ControlsGrid::VALUE_X,
            _ => ControlsGrid::TOGGLE_X,
        }
    }

    fn button_width(&self, title: &str) -> f64 {
        self.button_widths.get(title).copied().unwrap_or(title.chars().count() as f64 * 6.5) + 20.0
    }

    /// The frame of a part in row `r` at `y` (form coordinates).
    pub fn frame(&self, part: Part, r: &Row<C>, y: f64) -> Option<CGRect> {
        let (h, ch, vx) = (Self::ROW_HEIGHT, ControlsGrid::CONTROL_HEIGHT, ControlsGrid::VALUE_X);
        let gap = f64::from(spacing::XS);
        let right = (self.width - ControlsGrid::TRAILING).max(vx);
        match (&*r.kind, part) {
            (Kind::Section { .. }, Part::Fold) => Some(CGRect::new(0.0, y, self.width, h)),
            (Kind::Section { enabled: Some(_), .. }, Part::Enable) => {
                Some(CGRect::new(right - Self::ICON_SLOT * 2.0 - gap, y, Self::ICON_SLOT, h))
            }
            (Kind::Section { remove: Some(_), .. }, Part::Remove) => {
                Some(CGRect::new(right - Self::ICON_SLOT, y, Self::ICON_SLOT, h))
            }
            (Kind::Numbers { .. } | Kind::Appearance { .. }, Part::Field(i)) => {
                if i >= r.fields.len() {
                    return None;
                }
                let mut x = ControlsGrid::value_column(i as i64);
                if matches!(*r.kind, Kind::Appearance { .. }) {
                    x = ControlsGrid::value_column(1); // the swatch fills the first column, the number the second
                }
                Some(CGRect::new(x, Self::control_y(y, ch), Self::FIELD_WIDTH, ch))
            }
            (Kind::Numbers { link: Some(_), .. }, Part::Link) => {
                let x = ControlsGrid::value_column(r.fields.len() as i64);
                Some(CGRect::new(x, y, Self::ICON_SLOT, h))
            }
            (Kind::Popup { .. }, Part::Popup) => {
                Some(CGRect::new(vx, Self::control_y(y, ch), 128.0_f64.min(right - vx), ch))
            }
            (Kind::Segments { labels, .. }, Part::Segment(i)) if i < labels.len() => {
                Some(CGRect::new(vx + i as f64 * 64.0, Self::control_y(y, ch), 64.0, ch))
            }
            (Kind::Icons { items, .. }, Part::Icon(i)) if i < items.len() => Some(CGRect::new(
                Self::icons_x(r) + i as f64 * (Self::ICON_SLOT + gap),
                Self::control_y(y, Self::ICON_SLOT),
                Self::ICON_SLOT,
                Self::ICON_SLOT,
            )),
            (Kind::Check { .. }, Part::Check) => Some(CGRect::new(vx, y, (right - vx).max(0.0), h)),
            (Kind::Color { .. }, Part::Well) | (Kind::Appearance { .. }, Part::AppWell) => {
                Some(CGRect::new(vx, Self::control_y(y, Self::SWATCH.1), Self::SWATCH.0, Self::SWATCH.1))
            }
            (Kind::Appearance { .. }, Part::AppCheck) => {
                Some(CGRect::new(ControlsGrid::TOGGLE_X, y, ControlsGrid::TOGGLE_WIDTH, h))
            }
            (Kind::Appearance { has_detail: true, .. }, Part::Chevron) => {
                Some(CGRect::new(right - Self::ICON_SLOT, y, Self::ICON_SLOT, h))
            }
            (Kind::Buttons(bs), Part::Button(i)) if i < bs.len() => {
                let mut x = ControlsGrid::TOGGLE_X;
                for b in &bs[..i] {
                    x += self.button_width(&b.title) + gap;
                }
                Some(CGRect::new(x, Self::control_y(y, ch), self.button_width(&bs[i].title), ch))
            }
            _ => None,
        }
    }

    fn parts(r: &Row<C>) -> Vec<Part> {
        match &*r.kind {
            Kind::Section { .. } => vec![Part::Enable, Part::Remove, Part::Fold],
            Kind::Numbers { .. } => (0..r.fields.len()).map(Part::Field).chain([Part::Link]).collect(),
            Kind::Popup { .. } => vec![Part::Popup],
            Kind::Segments { labels, .. } => (0..labels.len()).map(Part::Segment).collect(),
            Kind::Icons { items, .. } => (0..items.len()).map(Part::Icon).collect(),
            Kind::Check { .. } => vec![Part::Check],
            Kind::Color { .. } => vec![Part::Well],
            Kind::Appearance { .. } => vec![Part::AppCheck, Part::AppWell, Part::Field(0), Part::Chevron],
            Kind::Label { .. } => vec![],
            Kind::Buttons(bs) => (0..bs.len()).map(Part::Button).collect(),
        }
    }

    pub fn hit(&self, p: CGPoint) -> Option<Hit> {
        for (i, y) in self.visible() {
            if p.y >= y && p.y < y + Self::ROW_HEIGHT {
                let r = &self.rows[i];
                return Self::parts(r)
                    .into_iter()
                    .find(|part| self.frame(*part, r, y).is_some_and(|f| f.contains(p)))
                    .map(|part| Hit { row: i, part });
            }
        }
        None
    }

    fn y_of(&self, row: usize) -> Option<f64> {
        self.visible().into_iter().find(|(i, _)| *i == row).map(|(_, y)| y)
    }

    // MARK: Drawing

    fn refresh_fields(&mut self, i: usize, ctx: &C) {
        let r = &mut self.rows[i];
        for k in 0..r.fields.len() {
            if !r.fields[k].is_editing() && !r.fields[k].is_dragging() {
                let v = (r.getters[k])(ctx);
                r.fields[k].is_mixed = v.is_none();
                if let Some(v) = v {
                    r.fields[k].value = v;
                }
            }
        }
    }

    pub fn draw(&mut self, c: &mut Canvas, ctx: &C, cx: &mut UiCx) {
        let (t, fs) = (self.theme, f64::from(type_size::BODY));
        for (i, y) in self.visible() {
            let h = Self::ROW_HEIGHT;
            let (hover, pressed) = (self.hover, self.pressed);
            let hov = |p: Part| hover == Some(Hit { row: i, part: p });
            let prs = |p: Part| pressed == Some(Hit { row: i, part: p });
            self.refresh_fields(i, ctx);
            if let Kind::Buttons(bs) = &*self.rows[i].kind {
                for b in bs {
                    let w = c.size_of(&SQL10n::string(&b.title), fs, 0).width;
                    self.button_widths.insert(b.title.clone(), w);
                }
            }
            let r = &self.rows[i];
            match &*r.kind {
                Kind::Section { title, key, enabled, remove, .. } => {
                    if i > 0 {
                        c.fill(CGRect::new(0.0, y, self.width, 1.0), t.separator());
                    }
                    let chevron = if self.is_folded(key) { SQIcon::ChevronRight } else { SQIcon::ChevronDown };
                    icon(
                        c,
                        chevron,
                        CGRect::new(ControlsGrid::HEADER_TOGGLE_X, y, ControlsGrid::TOGGLE_WIDTH, h),
                        9.0,
                        t.label3(),
                    );
                    let on = enabled.as_ref().is_none_or(|e| e(ctx));
                    let rect = CGRect::new(
                        ControlsGrid::HEADER_LABEL_X,
                        y,
                        (self.width - ControlsGrid::HEADER_LABEL_X - 60.0).max(0.0),
                        h,
                    );
                    let face = c.semibold();
                    c.draw_text_in(
                        &SQL10n::string(title),
                        rect,
                        fs,
                        if on { t.label() } else { t.label3() },
                        TextAlign::Left,
                        0.0,
                        face,
                    );
                    if enabled.is_some()
                        && let Some(f) = self.frame(Part::Enable, r, y)
                    {
                        let ic = if on { SQIcon::Eye } else { SQIcon::EyeOff };
                        icon(c, ic, f, 10.0, tint(&t, hov(Part::Enable), true));
                    }
                    if remove.is_some()
                        && let Some(f) = self.frame(Part::Remove, r, y)
                    {
                        icon(c, SQIcon::MinusCircle, f, 10.0, tint(&t, hov(Part::Remove), true));
                    }
                }
                Kind::Numbers { title, keyed, link } => {
                    label(c, &t, title, y);
                    let animated = keyed.as_ref().is_some_and(|k| k(ctx));
                    let focused_field = |k: usize| self.focused == Some(Hit { row: i, part: Part::Field(k) });
                    let frames: Vec<Option<CGRect>> =
                        (0..r.fields.len()).map(|k| self.frame(Part::Field(k), r, y)).collect();
                    let link_frame = self.frame(Part::Link, r, y);
                    let hovers: Vec<bool> = (0..frames.len()).map(|k| hov(Part::Field(k))).collect();
                    let focus: Vec<bool> = (0..frames.len()).map(focused_field).collect();
                    let link_state = link.as_ref().map(|l| ((l.selected)(ctx), l.icon, l.off_icon));
                    let link_hover = hov(Part::Link);
                    let r = &mut self.rows[i];
                    for (k, f) in frames.into_iter().enumerate() {
                        let Some(f) = f else { continue };
                        let fd = &mut r.fields[k];
                        fd.hovering = hovers[k];
                        fd.value_tint = if animated { Some(t.keyframe()) } else { None };
                        fd.draw(c, f, &t, focus[k], cx);
                    }
                    if let (Some((selected, on_icon, off_icon)), Some(f)) = (link_state, link_frame) {
                        let ic = if selected { on_icon } else { off_icon.unwrap_or(on_icon) };
                        icon(c, ic, f, 11.0, if selected { t.accent() } else { tint(&t, link_hover, true) });
                    }
                    continue;
                }
                Kind::Popup { title, titles, selected, enabled, .. } => {
                    label(c, &t, title, y);
                    if let Some(f) = self.frame(Part::Popup, r, y) {
                        let s = selected(ctx).and_then(|k| titles.get(k).cloned()).unwrap_or_else(|| "\u{2014}".into());
                        InspectorDraw::popup(
                            c,
                            &SQL10n::string(&s),
                            f,
                            hov(Part::Popup),
                            false,
                            enabled(ctx),
                            true,
                            ControlsGrid::CONTROL_HEIGHT,
                            None,
                            &t,
                        );
                    }
                }
                Kind::Segments { title, labels, selected, enabled, .. } => {
                    label(c, &t, title, y);
                    let sel = selected(ctx);
                    for (k, l) in labels.iter().enumerate() {
                        let Some(f) = self.frame(Part::Segment(k), r, y) else { continue };
                        let (on, en) = (k == sel, enabled(ctx, k));
                        let fill = if on {
                            t.fill_pressed()
                        } else if hov(Part::Segment(k)) && en {
                            t.fill_hover()
                        } else {
                            t.fill()
                        };
                        c.fill_rounded(f.inset_by(1.0, 0.0), f64::from(radius::SMALL), fill);
                        let ink = if !en {
                            t.label3()
                        } else if on {
                            t.label()
                        } else {
                            t.label2()
                        };
                        c.draw_text_in(&SQL10n::string(l), f, fs, ink, TextAlign::Center, 0.0, 0);
                    }
                }
                Kind::Icons { title, items } => {
                    if let Some(title) = title {
                        label(c, &t, title, y);
                    }
                    for (k, it) in items.iter().enumerate() {
                        let Some(f) = self.frame(Part::Icon(k), r, y) else { continue };
                        let (en, sel) = ((it.enabled)(ctx), (it.selected)(ctx));
                        let small = f64::from(radius::SMALL);
                        if sel {
                            c.fill_rounded(f, small, t.accent_tint());
                        } else if hov(Part::Icon(k)) && en {
                            c.fill_rounded(f, small, t.fill_hover());
                        }
                        icon(c, it.icon, f, 12.0, if sel { t.accent() } else { tint(&t, hov(Part::Icon(k)), en) });
                    }
                }
                Kind::Check { title, state, .. } => {
                    let boxed = CGRect::new(ControlsGrid::VALUE_X, Self::control_y(y, 14.0), 14.0, 14.0);
                    InspectorDraw::checkbox(c, state(ctx), boxed, hov(Part::Check), prs(Part::Check), true, false, &t);
                    let rect = CGRect::new(
                        boxed.max_x() + 6.0,
                        y,
                        (self.width - boxed.max_x() - 6.0 - ControlsGrid::TRAILING).max(0.0),
                        h,
                    );
                    c.draw_text_in(&SQL10n::string(title), rect, fs, t.label(), TextAlign::Left, 0.0, 0);
                }
                Kind::Color { title, get, .. } => {
                    label(c, &t, title, y);
                    if let Some(f) = self.frame(Part::Well, r, y) {
                        well(c, &t, get(ctx), f, hov(Part::Well));
                    }
                }
                Kind::Appearance { title, key, on, color, has_detail, .. } => {
                    let state = on(ctx);
                    if let Some(f) = self.frame(Part::AppCheck, r, y) {
                        let boxed = CGRect::new(f.mid_x() - 7.0, Self::control_y(y, 14.0), 14.0, 14.0);
                        let s = match state {
                            None => CheckState::Mixed,
                            Some(true) => CheckState::On,
                            Some(false) => CheckState::Off,
                        };
                        InspectorDraw::checkbox(c, s, boxed, hov(Part::AppCheck), prs(Part::AppCheck), true, false, &t);
                    }
                    label(c, &t, title, y);
                    if let Some(f) = self.frame(Part::AppWell, r, y) {
                        let col = if state == Some(false) { None } else { color(ctx) };
                        well(c, &t, col, f, hov(Part::AppWell));
                    }
                    let field_frame = self.frame(Part::Field(0), r, y);
                    let chevron = self.frame(Part::Chevron, r, y);
                    let (field_hover, focus) =
                        (hov(Part::Field(0)), self.focused == Some(Hit { row: i, part: Part::Field(0) }));
                    let chevron_hover = hov(Part::Chevron);
                    let open = self.open_details.contains(key);
                    let has_detail = *has_detail;
                    let r = &mut self.rows[i];
                    if let (Some(f), Some(fd)) = (field_frame, r.fields.first_mut()) {
                        fd.hovering = field_hover;
                        fd.is_enabled = state != Some(false);
                        fd.draw(c, f, &t, focus, cx);
                    }
                    if has_detail && let Some(f) = chevron {
                        let ic = if open { SQIcon::ChevronDown } else { SQIcon::ChevronRight };
                        icon(c, ic, f, 9.0, tint(&t, chevron_hover, true));
                    }
                    continue;
                }
                Kind::Label { title, value } => {
                    label(c, &t, title, y);
                    let rect = CGRect::new(
                        ControlsGrid::VALUE_X,
                        y,
                        (self.width - ControlsGrid::VALUE_X - ControlsGrid::TRAILING).max(0.0),
                        h,
                    );
                    c.draw_text_in(value, rect, fs, t.label2(), TextAlign::Left, 0.0, 0);
                }
                Kind::Buttons(bs) => {
                    for (k, b) in bs.iter().enumerate() {
                        let Some(f) = self.frame(Part::Button(k), r, y) else { continue };
                        InspectorDraw::button(
                            c,
                            &SQL10n::string(&b.title),
                            f,
                            hov(Part::Button(k)),
                            prs(Part::Button(k)),
                            true,
                            false,
                            ControlsGrid::CONTROL_HEIGHT,
                            &t,
                        );
                    }
                }
            }
        }
    }

    // MARK: Pointer and keys

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        if self.pressed.is_none() {
            self.hover = p.and_then(|p| self.hit(p));
        }
    }

    pub fn mouse_down(&mut self, p: CGPoint, click_count: Option<i64>, ctx: &mut C, cx: &mut UiCx) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        let h = self.hit(p);
        if self.focused.is_some_and(|f| Some(f) != h) {
            self.resign_focus(ctx, cx);
        }
        self.pressed = h;
        let Some(Hit { row, part: Part::Field(k) }) = h else { return };
        let ev = self.rows[row].fields[k].mouse_down(p.x as f32, n);
        self.apply(ev, row, k, ctx);
        self.focused = h;
    }

    pub fn mouse_dragged(&mut self, p: CGPoint, modifiers: InputModifiers, scale: f32, ctx: &mut C, cx: &mut UiCx) {
        let Some(Hit { row, part: Part::Field(k) }) = self.pressed else { return };
        let ev = self.rows[row].fields[k].mouse_dragged(p.x as f32, modifiers, scale, cx);
        self.apply(ev, row, k, ctx);
    }

    pub fn mouse_up(&mut self, p: CGPoint, ctx: &mut C, cx: &mut UiCx) {
        let h = self.pressed.take();
        self.finish_up(h, p, ctx, cx);
        self.mouse_moved(Some(p));
    }

    fn finish_up(&mut self, h: Option<Hit>, p: CGPoint, ctx: &mut C, cx: &mut UiCx) {
        let Some(h) = h else { return };
        if let Part::Field(k) = h.part {
            let ev = self.rows[h.row].fields[k].mouse_up(cx);
            self.apply(ev, h.row, k, ctx);
            return;
        }
        if self.hit(p) != Some(h) {
            return;
        }
        let Some(y) = self.y_of(h.row) else { return };
        let anchor = self.frame(h.part, &self.rows[h.row], y).unwrap_or(CGRect::new(0.0, 0.0, 0.0, 0.0));
        let kind = Rc::clone(&self.rows[h.row].kind);
        match (&*kind, h.part) {
            (Kind::Section { key, .. }, Part::Fold) => {
                let folded = self.is_folded(key);
                self.set_folded(key, !folded, ctx, cx);
            }
            (Kind::Section { enabled, set_enabled, .. }, Part::Enable) => {
                self.begin_undo(ctx);
                if let Some(set) = set_enabled {
                    set(ctx, !enabled.as_ref().is_none_or(|e| e(ctx)));
                }
            }
            (Kind::Section { remove: Some(remove), .. }, Part::Remove) => remove(ctx),
            (Kind::Numbers { link: Some(link), .. }, Part::Link) => (link.action)(ctx),
            (Kind::Popup { titles, selected, enabled, .. }, Part::Popup) => {
                if !enabled(ctx) {
                    return;
                }
                let cur = selected(ctx);
                let items = titles
                    .iter()
                    .enumerate()
                    .map(|(k, title)| {
                        let sink = Rc::clone(&self.pending);
                        let row = h.row;
                        let mut item = SQMenuItem::new(title);
                        item.is_checked = Some(k) == cur;
                        item.action = Some(Rc::new(move || sink.borrow_mut().push((row, k))));
                        item
                    })
                    .collect();
                self.menu = Some(MenuRequest { items, anchor });
            }
            (Kind::Segments { selected, enabled, choose, .. }, Part::Segment(k)) => {
                if enabled(ctx, k) && k != selected(ctx) {
                    choose(ctx, k);
                }
            }
            (Kind::Icons { items, .. }, Part::Icon(k)) => {
                if let Some(it) = items.get(k)
                    && (it.enabled)(ctx)
                {
                    (it.action)(ctx);
                }
            }
            (Kind::Check { toggle, .. }, Part::Check) => {
                self.begin_undo(ctx);
                toggle(ctx);
            }
            (Kind::Color { get, .. }, Part::Well) => self.pick(h.row, get(ctx), anchor, ctx),
            (Kind::Appearance { on, set_on, .. }, Part::AppCheck) => {
                self.begin_undo(ctx);
                set_on(ctx, !on(ctx).unwrap_or(true));
            }
            (Kind::Appearance { on, color, .. }, Part::AppWell) => {
                if on(ctx) != Some(false) {
                    self.pick(h.row, color(ctx), anchor, ctx);
                }
            }
            (Kind::Appearance { key, .. }, Part::Chevron) => {
                if !self.open_details.remove(key) {
                    self.open_details.insert(key.clone());
                }
                self.height_changed = true;
            }
            (Kind::Buttons(bs), Part::Button(k)) => {
                if let Some(b) = bs.get(k) {
                    (b.action)(ctx, anchor);
                }
            }
            _ => {}
        }
    }

    fn begin_undo(&self, ctx: &mut C) {
        if let Some(b) = &self.begin_gesture {
            b(ctx);
        }
    }

    /// The SQ color picker through the host; one picker session is one undo step.
    fn pick(&mut self, row: usize, current: Option<EffectColor>, anchor: CGRect, ctx: &mut C) {
        self.begin_undo(ctx);
        let white = EffectColor { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 };
        self.color_request = Some(ColorRequest { row, current: current.unwrap_or(white), anchor });
    }

    /// The picker reported a color (`None` = canceled); sets it on the row's color property.
    pub fn change_color(&mut self, row: usize, color: Option<EffectColor>, ctx: &mut C) {
        let Some(c) = color else { return };
        match self.rows.get(row).map(|r| &*r.kind) {
            Some(Kind::Color { set, .. }) => set(ctx, c),
            Some(Kind::Appearance { set_color, .. }) => set_color(ctx, c),
            _ => {}
        }
    }

    /// Applies the popup choices the menu made since the last call.
    pub fn flush(&mut self, ctx: &mut C) {
        let chosen: Vec<Pending> = std::mem::take(&mut *self.pending.borrow_mut());
        for (row, k) in chosen {
            if let Some(kind) = self.rows.get(row).map(|r| Rc::clone(&r.kind))
                && let Kind::Popup { choose, .. } = &*kind
            {
                self.begin_undo(ctx);
                choose(ctx, k);
            }
        }
    }

    fn apply(&self, events: Vec<Event>, row: usize, k: usize, ctx: &mut C) {
        for e in events {
            match e {
                Event::Begin => self.begin_undo(ctx),
                Event::Live(v) | Event::Change(v) | Event::End(v) | Event::Cancel(v) => {
                    (Rc::clone(&self.rows[row].setters[k]))(ctx, v);
                }
            }
        }
    }

    /// Keys for the focused field: typing, arrows step, Return / Tab / Esc end it.
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, ctx: &mut C, cx: &mut UiCx) -> bool {
        let Some(Hit { row, part: Part::Field(i) }) = self.focused else { return false };
        if row >= self.rows.len() {
            return false;
        }
        let f = &mut self.rows[row].fields[i];
        let (ev, used) = f.key_used(k, modifiers, cx.now, cx);
        let ended = !f.is_editing() && matches!(k, InputKey::Enter | InputKey::Escape);
        self.apply(ev, row, i, ctx);
        if ended {
            self.focused = None;
        }
        used
    }

    pub fn scroll(
        &mut self,
        p: CGPoint,
        dy: f64,
        precise: bool,
        modifiers: InputModifiers,
        ctx: &mut C,
        cx: &mut UiCx,
    ) -> bool {
        let Some(h) = self.hit(p) else { return false };
        let Part::Field(i) = h.part else { return false };
        let focused = self.focused == Some(h);
        let (used, ev) = self.rows[h.row].fields[i].scroll(dy, precise, modifiers, focused, cx.now, cx);
        self.apply(ev, h.row, i, ctx);
        used
    }

    pub fn resign_focus(&mut self, ctx: &mut C, cx: &mut UiCx) {
        let Some(h) = self.focused.take() else { return };
        let Part::Field(i) = h.part else { return };
        if h.row < self.rows.len() {
            let ev = self.rows[h.row].fields[i].resign_focus(cx);
            self.apply(ev, h.row, i, ctx);
        }
    }

    /// Ends idle arrow / wheel bursts.
    pub fn tick(&mut self, ctx: &mut C, now: f64) {
        for row in 0..self.rows.len() {
            for i in 0..self.rows[row].fields.len() {
                let ev = self.rows[row].fields[i].tick(now);
                self.apply(ev, row, i, ctx);
            }
        }
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        let h = self.hit(p)?;
        match (&*self.rows[h.row].kind, h.part) {
            (Kind::Icons { items, .. }, Part::Icon(k)) => items.get(k).map(|i| SQL10n::string(&i.title)),
            (Kind::Numbers { link, .. }, Part::Link) => link.as_ref().map(|l| SQL10n::string(&l.title)),
            (Kind::Section { title, .. }, Part::Remove) => Some(SQL10n::format("Remove %@", &[&SQL10n::string(title)])),
            (Kind::Section { title, .. }, Part::Enable) => Some(SQL10n::format("Enable %@", &[&SQL10n::string(title)])),
            _ => None,
        }
    }
}

fn label(c: &mut Canvas, t: &DrawTheme, s: &str, y: f64) {
    let rect = CGRect::new(
        ControlsGrid::LABEL_X,
        y,
        ControlsGrid::VALUE_X - ControlsGrid::LABEL_X - ControlsGrid::GAP,
        ControlsGrid::ROW_HEIGHT,
    );
    c.draw_text_in(&SQL10n::string(s), rect, f64::from(type_size::BODY), t.label2(), TextAlign::Left, 0.0, 0);
}

fn icon(c: &mut Canvas, i: SQIcon, r: CGRect, size: f64, color: Color) {
    c.draw_icon(i, CGPoint::new((r.mid_x() - size / 2.0).round(), (r.mid_y() - size / 2.0).round()), size, color, None);
}

fn tint(t: &DrawTheme, hovered: bool, enabled: bool) -> Color {
    let base = if hovered && enabled { t.label() } else { t.label2() };
    if enabled { base } else { base.with_alpha(base.a * InspectorTokens::DISABLED_ALPHA) }
}

/// An empty swatch (mixed or off) draws the field fill with a slash.
fn well(c: &mut Canvas, t: &DrawTheme, color: Option<EffectColor>, f: CGRect, hovering: bool) {
    if let Some(col) = color {
        let col = Color { r: col.red as f32, g: col.green as f32, b: col.blue as f32, a: col.alpha as f32 };
        InspectorDraw::color_well(c, col, f, hovering, t);
    } else {
        let r = InspectorTokens::radius(f);
        c.fill_rounded(f, r, t.field());
        c.stroke_rounded(f, r, 1.0, t.field_edge());
        c.stroke_line(
            CGPoint::new(f.min_x() + 3.0, f.max_y() - 3.0),
            CGPoint::new(f.max_x() - 3.0, f.min_y() + 3.0),
            1.0,
            t.label3(),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Ctx {
        corners: f64,
        on: bool,
        gestures: usize,
        picked: usize,
    }

    fn rig() -> GraphicsFormDraw<Ctx> {
        GraphicsFormDraw {
            width: 360.0,
            begin_gesture: Some(Rc::new(|c: &mut Ctx| c.gestures += 1)),
            ..GraphicsFormDraw::default()
        }
    }

    fn corners(f: &mut GraphicsFormDraw<Ctx>, ctx: &Ctx) {
        f.numbers(
            "Corners",
            "px",
            None,
            0,
            Some(&[0.0]),
            Some(0.0..=f64::MAX),
            vec![(Rc::new(|c: &Ctx| Some(c.corners)), Rc::new(|c: &mut Ctx, v| c.corners = v))],
            None,
            None,
            ctx,
        );
    }

    fn center(f: Option<CGRect>) -> CGPoint {
        let f = f.unwrap_or(CGRect::new(0.0, 0.0, 0.0, 0.0));
        CGPoint::new(f.mid_x(), f.mid_y())
    }

    /// The form's number columns are the Controls grid's, so they sit under the Text block's and the Controls panel's, and
    /// every number is a field of one width and height, centered in its row.
    #[test]
    fn number_fields_share_the_controls_grid_columns_in_every_row() {
        let ctx = Ctx::default();
        let mut f = rig();
        f.begin("Transform", "transform", None, None, None);
        let pair = || -> Vec<(Getter<Ctx>, Setter<Ctx>)> {
            (0..2)
                .map(|_| (Rc::new(|_: &Ctx| Some(0.0)) as Getter<Ctx>, Rc::new(|_: &mut Ctx, _| {}) as Setter<Ctx>))
                .collect()
        };
        f.numbers("Position", "", None, 1, None, None, pair(), None, None, &ctx);
        f.numbers("Scale", "%", None, 1, None, None, pair(), None, None, &ctx);
        corners(&mut f, &ctx);
        let mut y = 0.0;
        for (i, r) in f.rows.iter().enumerate().skip(1) {
            for k in 0..r.fields.len() {
                let Some(fr) = f.frame(Part::Field(k), r, y) else { panic!("row {i} field {k} has no frame") };
                assert_eq!(fr.min_x(), ControlsGrid::value_column(k as i64), "row {i} field {k}");
                assert_eq!(fr.width, ControlsGrid::VALUE_WIDTH);
                assert_eq!(fr.height, ControlsGrid::CONTROL_HEIGHT);
                assert_eq!(fr.mid_y(), y + ControlsGrid::ROW_HEIGHT / 2.0, "row {i} is centered in its row");
            }
            y += ControlsGrid::ROW_HEIGHT;
        }
    }

    #[test]
    fn folded_sections_and_closed_details_leave_the_layout() {
        let (mut ctx, mut cx) = (Ctx::default(), UiCx::new());
        let mut f = rig();
        f.begin("Shape", "shape", None, None, None);
        corners(&mut f, &ctx);
        f.add(Kind::Label { title: "A".into(), value: "b".into() }, Some("detail"));
        assert_eq!(f.height(), 2.0 * ControlsGrid::ROW_HEIGHT);
        f.set_folded("shape", true, &mut ctx, &mut cx);
        assert!(f.take_height_changed() && !f.take_height_changed());
        assert_eq!(f.height(), ControlsGrid::ROW_HEIGHT);
        f.set_folded("shape", false, &mut ctx, &mut cx);
        assert_eq!(f.visible().iter().map(|v| v.0).collect::<Vec<_>>(), vec![0, 1]);
    }

    #[test]
    fn folded_sections_come_back_from_the_settings_store() {
        let (mut ctx, mut cx) = (Ctx::default(), UiCx::new());
        let store = crate::open_state::SharedDefaults::default();
        let build = |store: &crate::open_state::SharedDefaults, ctx: &Ctx| {
            let mut f = rig();
            f.set_defaults(Box::new(store.clone()));
            f.begin("Shape", "shape", None, None, None);
            corners(&mut f, ctx);
            f
        };
        let mut f = build(&store, &ctx);
        assert!(!f.is_folded("shape"));
        f.set_folded("shape", true, &mut ctx, &mut cx);
        assert_eq!(store.0.borrow().get("sq.inspector.open.graphics.shape"), Some(&0));
        let again = build(&store, &ctx);
        assert!(again.is_folded("shape"));
        assert_eq!(again.height(), 0.0 + ControlsGrid::ROW_HEIGHT);
    }

    #[test]
    fn a_typed_value_is_one_gesture_and_reaches_the_setter() {
        let (mut ctx, mut cx) = (Ctx::default(), UiCx::new());
        let mut f = rig();
        corners(&mut f, &ctx);
        let at = center(f.frame(Part::Field(0), &f.rows[0], 0.0));
        f.mouse_down(at, Some(1), &mut ctx, &mut cx);
        f.mouse_up(at, &mut ctx, &mut cx);
        assert_eq!(f.focused(), Some(Hit { row: 0, part: Part::Field(0) }));
        for ch in "24".chars() {
            assert!(f.key(InputKey::Character(ch), InputModifiers::NONE, &mut ctx, &mut cx));
        }
        assert!(f.key(InputKey::Enter, InputModifiers::NONE, &mut ctx, &mut cx));
        assert_eq!(ctx.corners, 24.0);
        assert_eq!(ctx.gestures, 1);
    }

    #[test]
    fn a_check_row_toggles_inside_one_gesture() {
        let (mut ctx, mut cx) = (Ctx::default(), UiCx::new());
        let mut f = rig();
        f.add(
            Kind::Check {
                title: "Lock".into(),
                state: Rc::new(|c: &Ctx| if c.on { CheckState::On } else { CheckState::Off }),
                toggle: Rc::new(|c: &mut Ctx| c.on = !c.on),
            },
            None,
        );
        let at = center(f.frame(Part::Check, &f.rows[0], 0.0));
        f.mouse_down(at, Some(1), &mut ctx, &mut cx);
        f.mouse_up(at, &mut ctx, &mut cx);
        assert!(ctx.on);
        assert_eq!(ctx.gestures, 1);
    }

    #[test]
    fn a_popup_click_asks_for_a_menu_and_the_choice_is_applied_by_flush() {
        let (mut ctx, mut cx) = (Ctx::default(), UiCx::new());
        let mut f = rig();
        f.add(
            Kind::Popup {
                title: "Mode".into(),
                titles: vec!["A".into(), "B".into()],
                selected: Rc::new(|_| Some(0)),
                enabled: Rc::new(|_| true),
                choose: Rc::new(|c: &mut Ctx, k| c.picked = k + 1),
            },
            None,
        );
        let at = center(f.frame(Part::Popup, &f.rows[0], 0.0));
        f.mouse_down(at, Some(1), &mut ctx, &mut cx);
        f.mouse_up(at, &mut ctx, &mut cx);
        let menu = f.take_menu().expect("menu requested");
        assert_eq!(menu.items.len(), 2);
        assert!(menu.items[0].is_checked && !menu.items[1].is_checked);
        if let Some(a) = &menu.items[1].action {
            a();
        }
        f.flush(&mut ctx);
        assert_eq!((ctx.picked, ctx.gestures), (2, 1));
    }

    #[test]
    fn an_appearance_well_is_dead_while_the_row_is_off() {
        let (mut ctx, mut cx) = (Ctx::default(), UiCx::new());
        let mut f = rig();
        let kind = Kind::Appearance {
            title: "Fill".into(),
            key: "fill".into(),
            on: Rc::new(|c: &Ctx| Some(c.on)),
            set_on: Rc::new(|c: &mut Ctx, v| c.on = v),
            color: Rc::new(|_| None),
            set_color: Rc::new(|c: &mut Ctx, _| c.picked += 1),
            has_detail: false,
        };
        f.appearance(kind, Rc::new(|_| Some(100.0)), Rc::new(|_, _| {}), "%", 100.0, &ctx);
        let at = center(f.frame(Part::AppWell, &f.rows[0], 0.0));
        f.mouse_down(at, Some(1), &mut ctx, &mut cx);
        f.mouse_up(at, &mut ctx, &mut cx);
        assert!(f.take_color_request().is_none());
        ctx.on = true;
        f.mouse_down(at, Some(1), &mut ctx, &mut cx);
        f.mouse_up(at, &mut ctx, &mut cx);
        let req = f.take_color_request().expect("picker requested");
        f.change_color(req.row, Some(req.current), &mut ctx);
        assert_eq!(ctx.picked, 1);
        // The chevron of a row without detail has no frame.
        assert!(f.frame(Part::Chevron, &f.rows[0], 0.0).is_none());
    }

    #[test]
    fn drawing_every_kind_does_not_panic_and_hit_testing_follows_the_frames() {
        let (ctx, mut cx) = (Ctx::default(), UiCx::new());
        let mut f = rig();
        f.begin("Shape", "shape", Some(Rc::new(|_| true)), Some(Rc::new(|_, _| {})), Some(Rc::new(|_| {})));
        corners(&mut f, &ctx);
        f.add(Kind::Label { title: "L".into(), value: "v".into() }, None);
        f.add(
            Kind::Buttons(vec![TextButton { title: "Go".into(), action: Rc::new(|c: &mut Ctx, _| c.picked += 1) }]),
            None,
        );
        let mut c = Canvas::with_size(360.0, 200.0, None, 1.0);
        f.draw(&mut c, &ctx, &mut cx);
        let at = center(f.frame(Part::Remove, &f.rows[0], 0.0));
        assert_eq!(f.hit(at), Some(Hit { row: 0, part: Part::Remove }));
        assert_eq!(f.help(at).as_deref(), Some("Remove Shape"));
    }
}
