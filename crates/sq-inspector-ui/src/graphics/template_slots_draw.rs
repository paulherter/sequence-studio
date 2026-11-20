// Swift: Draw/TemplateSlotsDraw.swift
//! The Template section of Controls: one row per editable slot of an applied title template (text, color, font, number),
//! then "Keep intro and outro" and, while the zones are on, the Middle choice (Hold / Stretch). A slot edit is queued as a
//! [`TemplateEvent`] `(slot, value, continues)` so a drag or a typing run is one undo step. Coordinates: points, y down,
//! (0, 0) = the block's top-left.
//!
//! The Swift class called closures (`onSlotChange`, `onMenu`, `onPickColor`); here the host drains `take_events`,
//! `take_menu` and `take_color_request`, and answers with `flush` (a font choice) and `color_picked`.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use sq_core_model::{AnimationZones, EffectColor, SlotValue, TemplateSlot, TemplateSlotKind, ZoneMiddle};
use sq_core_time::Id;
use sq_draw::inspector::inspector_controls::{CheckState, InspectorDraw, InspectorTokens};
use sq_draw::inspector::scrub_field_control::{ClickCounter, Event, ScrubFieldControl};
use sq_draw::inspector::text_field_control::TextFieldControl;
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, Color, DrawTheme, InputKey, InputModifiers, TextAlign, UiCx};
use sq_uikit::controls_grid::{CGPoint, CGRect, ControlsGrid};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;

use super::form_draw::MenuRequest;

/// What the user did, in order; the host runs it against the session on the template clip.
#[derive(Clone, Debug, PartialEq)]
pub enum TemplateEvent {
    /// `session.set_template_slot`; `continues` joins the open gesture's undo step.
    Slot { slot: Id, value: SlotValue, continues: bool },
    /// `session.set_zones_enabled`.
    Zones(bool),
    /// `session.set_zone_middle`.
    Middle(ZoneMiddle),
}

/// A control of the block.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Control {
    Slot(usize),
    Zones,
    Middle(usize),
}

/// The color picker the host opens for a color slot; answer with [`TemplateSlotsDraw::color_picked`].
#[derive(Clone, Debug, PartialEq)]
pub struct SlotColorRequest {
    pub current: EffectColor,
    pub anchor: CGRect,
}

#[derive(Default)]
pub struct TemplateSlotsDraw {
    pub theme: DrawTheme,
    pub width: f64,
    /// The installed font families for a font slot's popup.
    pub font_families: Vec<String>,
    slots: Vec<TemplateSlot>,
    zones: Option<AnimationZones>,
    gesture_open: HashSet<Id>,
    texts: HashMap<Id, TextFieldControl>,
    numbers: HashMap<Id, ScrubFieldControl>,
    focused: Option<Id>,
    hover: Option<Control>,
    pressed: Option<Control>,
    counter: ClickCounter,
    check_label_width: f64,
    events: Vec<TemplateEvent>,
    menu: Option<MenuRequest>,
    color_slot: Option<Id>,
    color_request: Option<SlotColorRequest>,
    font_choices: Rc<RefCell<Vec<(Id, String)>>>,
}

impl TemplateSlotsDraw {
    pub const ROW_HEIGHT: f64 = ControlsGrid::ROW_HEIGHT;
    pub const SEGMENT_WIDTH: f64 = 64.0;
    pub const SWATCH_HEIGHT: f64 = 18.0;

    pub fn new() -> TemplateSlotsDraw {
        TemplateSlotsDraw { width: 320.0, check_label_width: 160.0, ..TemplateSlotsDraw::default() }
    }

    pub fn slots(&self) -> &[TemplateSlot] {
        &self.slots
    }

    pub fn zones(&self) -> Option<&AnimationZones> {
        self.zones.as_ref()
    }

    pub fn focused(&self) -> Option<Id> {
        self.focused
    }

    pub fn hover(&self) -> Option<Control> {
        self.hover
    }

    pub fn height(&self) -> f64 {
        (self.slots.len() + 1 + usize::from(self.zones.is_some())) as f64 * Self::ROW_HEIGHT
    }

    /// What the user did since the last call.
    pub fn take_events(&mut self) -> Vec<TemplateEvent> {
        std::mem::take(&mut self.events)
    }

    /// The font menu to show, once (anchor in block coordinates).
    pub fn take_menu(&mut self) -> Option<MenuRequest> {
        self.menu.take()
    }

    /// The color picker to open, once.
    pub fn take_color_request(&mut self) -> Option<SlotColorRequest> {
        self.color_request.take()
    }

    /// Shows `slots` and the zones of the selected template clip. Values update in place; a field being typed in or
    /// dragged keeps its own value. True when the height changed.
    pub fn show(&mut self, slots: &[TemplateSlot], zones: Option<AnimationZones>) -> bool {
        let before = self.height();
        let same = slots.iter().map(|s| s.id).eq(self.slots.iter().map(|s| s.id));
        if !same {
            self.texts.clear();
            self.numbers.clear();
            self.gesture_open.clear();
            self.focused = None;
            self.pressed = None;
        }
        self.slots = slots.to_vec();
        self.zones = zones;
        let size = f64::from(type_size::BODY);
        for s in slots {
            match &s.value {
                SlotValue::Text(t) => {
                    let f = self.texts.entry(s.id).or_insert_with(|| TextFieldControl::new(t));
                    f.alignment = sq_draw::inspector::text_field_control::Alignment::Left;
                    f.font_size = size;
                    if !f.is_editing() {
                        f.text = t.clone();
                    }
                }
                SlotValue::Number(n) => {
                    let f = self.numbers.entry(s.id).or_insert_with(|| ScrubFieldControl::new(*n));
                    f.range = 1.0..=1000.0;
                    if !f.is_dragging() && !f.is_editing() {
                        f.value = *n;
                    }
                }
                _ => {}
            }
        }
        self.height() != before
    }

    // MARK: Layout

    fn row_y(i: usize) -> f64 {
        i as f64 * Self::ROW_HEIGHT
    }

    /// The control's frame (block coordinates).
    pub fn frame(&self, k: Control) -> CGRect {
        let (h, ch) = (Self::ROW_HEIGHT, ControlsGrid::CONTROL_HEIGHT);
        let wide = (self.width - ControlsGrid::VALUE_X - ControlsGrid::TRAILING).max(0.0);
        match k {
            Control::Slot(i) => {
                let y = Self::row_y(i);
                match self.slots[i].kind {
                    TemplateSlotKind::Text | TemplateSlotKind::Font => {
                        CGRect::new(ControlsGrid::VALUE_X, y + ((h - ch) / 2.0).round(), wide, ch)
                    }
                    TemplateSlotKind::Color => CGRect::new(
                        ControlsGrid::VALUE_X,
                        y + ((h - Self::SWATCH_HEIGHT) / 2.0).round(),
                        ControlsGrid::VALUE_WIDTH,
                        Self::SWATCH_HEIGHT,
                    ),
                    TemplateSlotKind::Number => {
                        CGRect::new(ControlsGrid::VALUE_X, y + ((h - ch) / 2.0).round(), ControlsGrid::VALUE_WIDTH, ch)
                    }
                }
            }
            Control::Zones => CGRect::new(ControlsGrid::VALUE_X, Self::row_y(self.slots.len()), wide, h),
            Control::Middle(i) => CGRect::new(
                ControlsGrid::VALUE_X + i as f64 * Self::SEGMENT_WIDTH,
                Self::row_y(self.slots.len() + 1) + ((h - ch) / 2.0).round(),
                Self::SEGMENT_WIDTH,
                ch,
            ),
        }
    }

    pub fn control_at(&self, p: CGPoint) -> Option<Control> {
        if p.y < 0.0 || p.y >= self.height() {
            return None;
        }
        let row = (p.y / Self::ROW_HEIGHT) as usize;
        if row < self.slots.len() {
            return self.frame(Control::Slot(row)).contains(p).then_some(Control::Slot(row));
        }
        if row == self.slots.len() {
            let f = self.frame(Control::Zones);
            return (p.x >= f.min_x() && p.x < f.min_x() + 16.0 + self.check_label_width).then_some(Control::Zones);
        }
        (0..2).find(|i| self.frame(Control::Middle(*i)).contains(p)).map(Control::Middle)
    }

    // MARK: Drawing

    pub fn draw(&mut self, c: &mut Canvas, cx: &mut UiCx) {
        let (t, fs, h) = (self.theme, f64::from(type_size::BODY), Self::ROW_HEIGHT);
        for (i, s) in self.slots.iter().enumerate() {
            self.label(c, &s.name, Self::row_y(i));
            let f = self.frame(Control::Slot(i));
            let hov = self.hover == Some(Control::Slot(i));
            match &s.value {
                SlotValue::Text(_) => {
                    if let Some(fd) = self.texts.get_mut(&s.id) {
                        fd.hovering = hov;
                        fd.draw(c, f, &t, false, cx);
                    }
                }
                SlotValue::Color { red, green, blue, alpha } => {
                    let col = Color::new(*red as f32, *green as f32, *blue as f32, *alpha as f32);
                    InspectorDraw::color_well(c, col, f, hov, &t);
                }
                SlotValue::Font(n) => {
                    let title = if n.is_empty() { SQL10n::string("Default") } else { n.clone() };
                    InspectorDraw::popup(
                        c,
                        &title,
                        f,
                        hov,
                        false,
                        true,
                        true,
                        f64::from(InspectorTokens::CAPSULE),
                        None,
                        &t,
                    );
                }
                SlotValue::Number(_) => {
                    if let Some(fd) = self.numbers.get_mut(&s.id) {
                        fd.hovering = hov;
                        fd.draw(c, f, &t, self.focused == Some(s.id), cx);
                    }
                }
            }
        }
        // Keep intro and outro: a checkbox with its title, then Middle while the zones are on.
        let zy = Self::row_y(self.slots.len());
        let boxed = CGRect::new(ControlsGrid::VALUE_X, zy + ((h - 14.0) / 2.0).round(), 14.0, 14.0);
        let state = if self.zones.is_none() { CheckState::Off } else { CheckState::On };
        InspectorDraw::checkbox(
            c,
            state,
            boxed,
            self.hover == Some(Control::Zones),
            self.pressed == Some(Control::Zones),
            true,
            false,
            &t,
        );
        let title = SQL10n::string("Keep intro and outro");
        self.check_label_width = c.size_of(&title, fs, 0).width + 6.0;
        let rect = CGRect::new(
            boxed.max_x() + 6.0,
            zy,
            (self.width - boxed.max_x() - 6.0 - ControlsGrid::TRAILING).max(0.0),
            h,
        );
        crate::ec_draw::effect_controls_draw_panel::EffectControlsDrawPanel::draw_label_lines(c, &title, rect, h, fs, t.label());
        let Some(z) = &self.zones else { return };
        self.label(c, "Middle", Self::row_y(self.slots.len() + 1));
        for (i, name) in ["Hold", "Stretch"].into_iter().enumerate() {
            let f = self.frame(Control::Middle(i));
            let on = (z.middle == ZoneMiddle::Stretch) == (i == 1);
            let fill = if on {
                t.fill_pressed()
            } else if self.hover == Some(Control::Middle(i)) {
                t.fill_hover()
            } else {
                t.fill()
            };
            c.fill_rounded(f.inset_by(1.0, 0.0), f64::from(radius::SMALL), fill);
            let ink = if on { t.label() } else { t.label2() };
            c.draw_text_in(&SQL10n::string(name), f, fs, ink, TextAlign::Center, 0.0, 0);
        }
    }

    fn label(&self, c: &mut Canvas, s: &str, y: f64) {
        let r = CGRect::new(
            ControlsGrid::LABEL_X,
            y,
            ControlsGrid::VALUE_X - ControlsGrid::LABEL_X - ControlsGrid::GAP,
            Self::ROW_HEIGHT,
        );
        crate::ec_draw::effect_controls_draw_panel::EffectControlsDrawPanel::draw_label_lines(
            c,
            &SQL10n::string(s),
            r,
            Self::ROW_HEIGHT,
            f64::from(type_size::BODY),
            self.theme.label2(),
        );
    }

    // MARK: Pointer and keys

    pub fn mouse_moved(&mut self, p: Option<CGPoint>) {
        if self.pressed.is_none() {
            self.hover = p.and_then(|p| self.control_at(p));
        }
    }

    pub fn mouse_down(&mut self, p: CGPoint, click_count: Option<i64>, cx: &mut UiCx) {
        let n = click_count.unwrap_or_else(|| self.counter.press(p.x as f32, p.y as f32, cx.now));
        let k = self.control_at(p);
        if let Some(id) = self.focused
            && k.and_then(|k| self.slot_id(k)) != Some(id)
        {
            self.resign_focus(cx);
        }
        self.pressed = k;
        let Some(Control::Slot(i)) = k else { return };
        let s = self.slots[i].clone();
        match s.kind {
            TemplateSlotKind::Text => {
                if let Some(fd) = self.texts.get_mut(&s.id) {
                    fd.mouse_down(None, n);
                    self.focused = Some(s.id);
                    self.pressed = None;
                }
            }
            TemplateSlotKind::Number => {
                if let Some(fd) = self.numbers.get_mut(&s.id) {
                    let ev = fd.mouse_down(p.x as f32, n);
                    self.focused = Some(s.id);
                    self.apply(ev, s.id);
                }
            }
            TemplateSlotKind::Font => {
                self.pressed = None;
                let cur = if let SlotValue::Font(n) = &s.value { Some(n.as_str()) } else { None };
                if self.font_families.is_empty() {
                    self.font_families = crate::text::inspector_model::TextBoxDefaults::installed_families();
                }
                let items: Vec<SQMenuItem> = self
                    .font_families
                    .iter()
                    .map(|f| {
                        let sink = Rc::clone(&self.font_choices);
                        let (id, name) = (s.id, f.clone());
                        let mut item = SQMenuItem::new(f);
                        item.is_checked = Some(f.as_str()) == cur;
                        item.action = Some(Rc::new(move || sink.borrow_mut().push((id, name.clone()))));
                        item
                    })
                    .collect();
                if !items.is_empty() {
                    self.menu = Some(MenuRequest { items, anchor: self.frame(Control::Slot(i)) });
                }
            }
            TemplateSlotKind::Color => {}
        }
    }

    fn slot_id(&self, k: Control) -> Option<Id> {
        if let Control::Slot(i) = k { Some(self.slots[i].id) } else { None }
    }

    pub fn mouse_dragged(&mut self, p: CGPoint, modifiers: InputModifiers, scale: f32, cx: &mut UiCx) {
        let Some(Control::Slot(i)) = self.pressed else { return };
        let id = self.slots[i].id;
        if self.slots[i].kind != TemplateSlotKind::Number {
            return;
        }
        if let Some(fd) = self.numbers.get_mut(&id) {
            let ev = fd.mouse_dragged(p.x as f32, modifiers, scale, cx);
            self.apply(ev, id);
        }
    }

    pub fn mouse_up(&mut self, p: CGPoint, cx: &mut UiCx) {
        let k = self.pressed.take();
        if let Some(Control::Slot(i)) = k
            && self.slots[i].kind == TemplateSlotKind::Number
        {
            let id = self.slots[i].id;
            if let Some(fd) = self.numbers.get_mut(&id) {
                let ev = fd.mouse_up(cx);
                self.apply(ev, id);
            }
            self.mouse_moved(Some(p));
            return;
        }
        if let Some(k) = k
            && self.control_at(p) == Some(k)
        {
            match k {
                Control::Slot(i) if self.slots[i].kind == TemplateSlotKind::Color => self.pick_color(i),
                Control::Zones => self.events.push(TemplateEvent::Zones(self.zones.is_none())),
                Control::Middle(i) => {
                    self.events.push(TemplateEvent::Middle(if i == 1 {
                        ZoneMiddle::Stretch
                    } else {
                        ZoneMiddle::Hold
                    }));
                }
                Control::Slot(_) => {}
            }
        }
        self.mouse_moved(Some(p));
    }

    /// The SQ color picker through the host; one picker session is one undo step.
    fn pick_color(&mut self, i: usize) {
        let SlotValue::Color { red, green, blue, alpha } = self.slots[i].value else { return };
        let id = self.slots[i].id;
        self.gesture_open.remove(&id);
        let request =
            SlotColorRequest { current: EffectColor { red, green, blue, alpha }, anchor: self.frame(Control::Slot(i)) };
        self.color_slot = Some(id);
        self.color_request = Some(request);
    }

    /// The picker reported a color (`None` = it closed).
    pub fn color_picked(&mut self, color: Option<EffectColor>) {
        let Some(id) = self.color_slot else { return };
        let Some(c) = color else {
            self.gesture_open.remove(&id);
            return;
        };
        self.send(id, SlotValue::Color { red: c.red, green: c.green, blue: c.blue, alpha: c.alpha });
    }

    /// Applies the font choices the popup made since the last call.
    pub fn flush(&mut self) {
        let chosen: Vec<(Id, String)> = std::mem::take(&mut *self.font_choices.borrow_mut());
        for (id, name) in chosen {
            self.send(id, SlotValue::Font(name));
            self.gesture_open.remove(&id);
        }
    }

    fn apply(&mut self, events: Vec<Event>, id: Id) {
        for e in events {
            match e {
                Event::Begin => {
                    self.gesture_open.remove(&id);
                }
                Event::Live(v) | Event::Change(v) => self.send(id, SlotValue::Number(v)),
                Event::End(v) | Event::Cancel(v) => {
                    self.send(id, SlotValue::Number(v));
                    self.gesture_open.remove(&id);
                }
            }
        }
    }

    fn send(&mut self, id: Id, value: SlotValue) {
        let continues = !self.gesture_open.insert(id);
        self.events.push(TemplateEvent::Slot { slot: id, value, continues });
    }

    /// Keys for the focused slot: typing goes out live (one undo step per run), Return / Tab / Esc end the field.
    pub fn key(&mut self, k: InputKey, modifiers: InputModifiers, cx: &mut UiCx) -> bool {
        let Some(id) = self.focused else { return false };
        if let Some(fd) = self.texts.get_mut(&id)
            && fd.is_editing()
        {
            let before = fd.editor().map(|e| e.string());
            let committed = fd.key(k, modifiers, cx);
            let now = fd.editor().map(|e| e.string());
            let editing = fd.is_editing();
            if let Some(s) = now
                && Some(&s) != before.as_ref()
            {
                self.send(id, SlotValue::Text(s));
            }
            if let Some(s) = committed
                && Some(&s) != before.as_ref()
            {
                self.send(id, SlotValue::Text(s));
            }
            if !editing {
                self.gesture_open.remove(&id);
                self.focused = None;
            }
            return true;
        }
        if let Some(fd) = self.numbers.get_mut(&id) {
            let (ev, used) = fd.key_used(k, modifiers, cx.now, cx);
            let ended = !fd.is_editing() && matches!(k, InputKey::Enter | InputKey::Escape);
            self.apply(ev, id);
            if ended {
                self.focused = None;
            }
            return used;
        }
        false
    }

    pub fn resign_focus(&mut self, cx: &mut UiCx) {
        let Some(id) = self.focused.take() else { return };
        if let Some(fd) = self.texts.get_mut(&id) {
            let before = fd.editor().map(|e| e.string());
            if let Some(s) = fd.commit()
                && Some(&s) != before.as_ref()
            {
                self.send(id, SlotValue::Text(s));
            }
        }
        if let Some(fd) = self.numbers.get_mut(&id) {
            let ev = fd.resign_focus(cx);
            self.apply(ev, id);
        }
        self.gesture_open.remove(&id);
    }

    /// Ends idle arrow / wheel bursts of the number slots.
    pub fn tick(&mut self, now: f64) {
        let ids: Vec<Id> = self.numbers.keys().copied().collect();
        for id in ids {
            if let Some(fd) = self.numbers.get_mut(&id) {
                let ev = fd.tick(now);
                self.apply(ev, id);
            }
        }
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        match self.control_at(p)? {
            Control::Zones => Some(SQL10n::string(
                "The first and last moments of the title keep their length when you trim or stretch the clip.",
            )),
            Control::Middle(_) => Some(SQL10n::string("Middle of the title when the clip length changes")),
            Control::Slot(i) => Some(self.slots[i].name.clone()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slot(n: u128, name: &str, kind: TemplateSlotKind, value: SlotValue) -> TemplateSlot {
        TemplateSlot {
            id: Id::from_u128(n),
            name: name.to_string(),
            kind,
            layer: Id::from_u128(100),
            graphics_layer: None,
            path: "p".to_string(),
            value,
        }
    }

    fn rig(zones: bool) -> TemplateSlotsDraw {
        let mut d = TemplateSlotsDraw::new();
        d.font_families = vec!["Inter".to_string(), "Menlo".to_string()];
        let z = zones
            .then(|| AnimationZones::new(sq_core_time::Time::ZERO, sq_core_time::Time::ZERO, ZoneMiddle::Hold, None));
        d.show(
            &[
                slot(1, "Title", TemplateSlotKind::Text, SlotValue::Text("Hello".into())),
                slot(
                    2,
                    "Tint",
                    TemplateSlotKind::Color,
                    SlotValue::Color { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 },
                ),
                slot(3, "Font", TemplateSlotKind::Font, SlotValue::Font(String::new())),
                slot(4, "Size", TemplateSlotKind::Number, SlotValue::Number(10.0)),
            ],
            z,
        );
        d
    }

    fn mid(f: CGRect) -> CGPoint {
        CGPoint::new(f.mid_x(), f.mid_y())
    }

    fn click(d: &mut TemplateSlotsDraw, cx: &mut UiCx, p: CGPoint) {
        d.mouse_down(p, Some(1), cx);
        d.mouse_up(p, cx);
    }

    #[test]
    fn height_counts_slots_zones_toggle_and_middle() {
        assert_eq!(rig(false).height(), 5.0 * TemplateSlotsDraw::ROW_HEIGHT);
        assert_eq!(rig(true).height(), 6.0 * TemplateSlotsDraw::ROW_HEIGHT);
    }

    #[test]
    fn show_reports_a_height_change_only_once() {
        let mut d = rig(false);
        let slots = d.slots().to_vec();
        assert!(d.show(
            &slots,
            Some(AnimationZones::new(sq_core_time::Time::ZERO, sq_core_time::Time::ZERO, ZoneMiddle::Hold, None))
        ));
        assert!(!d.show(&slots, d.zones().cloned()));
    }

    #[test]
    fn the_zones_toggle_and_middle_choice_queue_events() {
        let mut cx = UiCx::new();
        let mut d = rig(true);
        let zones = d.frame(Control::Zones);
        click(&mut d, &mut cx, CGPoint::new(ControlsGrid::VALUE_X + 4.0, zones.mid_y()));
        let at = mid(d.frame(Control::Middle(1)));
        click(&mut d, &mut cx, at);
        assert_eq!(d.take_events(), vec![TemplateEvent::Zones(false), TemplateEvent::Middle(ZoneMiddle::Stretch)]);
    }

    #[test]
    fn a_picked_color_is_one_gesture() {
        let mut cx = UiCx::new();
        let mut d = rig(false);
        let at = mid(d.frame(Control::Slot(1)));
        click(&mut d, &mut cx, at);
        let Some(req) = d.take_color_request() else { panic!("no picker request") };
        assert_eq!(req.current.red, 1.0);
        let c = EffectColor { red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0 };
        d.color_picked(Some(c));
        d.color_picked(Some(c));
        let ev = d.take_events();
        assert!(matches!(ev[0], TemplateEvent::Slot { continues: false, .. }));
        assert!(matches!(ev[1], TemplateEvent::Slot { continues: true, .. }));
    }

    #[test]
    fn a_font_choice_comes_back_through_flush() {
        let mut cx = UiCx::new();
        let mut d = rig(false);
        let at = mid(d.frame(Control::Slot(2)));
        click(&mut d, &mut cx, at);
        let Some(menu) = d.take_menu() else { panic!("no font menu") };
        assert_eq!(menu.items.len(), 2);
        if let Some(a) = &menu.items[1].action {
            a();
        }
        d.flush();
        assert_eq!(
            d.take_events(),
            vec![TemplateEvent::Slot {
                slot: Id::from_u128(3),
                value: SlotValue::Font("Menlo".into()),
                continues: false
            }]
        );
    }

    #[test]
    fn typing_in_a_text_slot_goes_out_live_and_ends_with_return() {
        let mut cx = UiCx::new();
        let mut d = rig(false);
        let at = mid(d.frame(Control::Slot(0)));
        click(&mut d, &mut cx, at);
        assert_eq!(d.focused(), Some(Id::from_u128(1)));
        assert!(d.key(InputKey::Character('x'), InputModifiers::NONE, &mut cx));
        assert!(d.key(InputKey::Enter, InputModifiers::NONE, &mut cx));
        assert_eq!(d.focused(), None);
        let ev = d.take_events();
        assert_eq!(
            ev.first(),
            Some(&TemplateEvent::Slot { slot: Id::from_u128(1), value: SlotValue::Text("x".into()), continues: false })
        );
    }

    #[test]
    fn help_names_the_zones_and_the_slot() {
        let d = rig(true);
        assert_eq!(d.help(mid(d.frame(Control::Slot(3)))).as_deref(), Some("Size"));
        assert!(d.help(CGPoint::new(ControlsGrid::VALUE_X + 2.0, 4.5 * TemplateSlotsDraw::ROW_HEIGHT)).is_some());
        assert_eq!(d.help(CGPoint::new(0.0, 1000.0)), None);
    }
}
