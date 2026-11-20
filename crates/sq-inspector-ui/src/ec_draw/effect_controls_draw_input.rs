// Swift: EffectControlsDrawPanel.swift (Input, Menus, Keys, Pixels)
//! Pointer, key and menu handling of the rows column.

use sq_core_model::EffectColor;
use sq_draw::scroll::ScrollGesture;
use sq_draw::{InputEvent, InputKey, InputModifiers, UiCx};
use sq_editor_session::EffectSection;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;

use super::effect_controls_draw_panel::{
    ColorTarget, EaseCurveTarget, EffectControlsDrawPanel, FieldId, PanelEvent, RemoveKeys, RowRef, SpeedAction, Target,
};
use super::effect_controls_draw_rows::{PanelCx, Widget, WidgetKind};
use super::{MenuEntry, MenuOutput, ModelMenu};
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::layout::{EffectRow, EffectRowKind, SpeedControl};
use crate::ec::effect_controls_model::property::{EffectComponent, EffectProperty, StopwatchOutcome};

/// A field that takes keyboard focus, in row order.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Focusable {
    Field(FieldId),
    Text(String),
}

impl EffectControlsDrawPanel {
    // MARK: Input (points)

    /// The pointer moved over the panel (`None`: it left).
    pub fn mouse_moved(&mut self, model: &mut EffectControlsModel, p: Option<CGPoint>) {
        self.hover_point = p;
        let over = p.map_or(Target::None, |p| self.target_at(model, p));
        for (id, f) in self.fields.iter_mut() {
            f.hovering = over == Target::Field(id.clone());
        }
        if let (Some(p), Target::Widget(key)) = (p, &over)
            && let Some((r, w)) = self.widget(model, key)
        {
            let top = self.row_top(&r);
            let local = CGPoint::new(p.x, p.y - top);
            if let Some(s) = self.surfaces.get_mut(key) {
                s.mouse_moved(model, Some(local), w.frame);
            }
        }
    }

    /// The row and widget of a translated row's control.
    pub(crate) fn widget(&self, model: &EffectControlsModel, key: &str) -> Option<(EffectRow, Widget)> {
        for r in &self.rows {
            if let Some(w) = self.widgets(model, r).and_then(|ws| ws.into_iter().find(|w| w.key == key)) {
                return Some((r.clone(), w));
            }
        }
        None
    }

    fn over_default_marker(&self, p: CGPoint, s: &EffectSection) -> bool {
        let (Some(r), Some(m)) = (self.row_at(p), self.default_markers.get(s)) else { return false };
        m.inset_by(-2.0, 0.0).contains(CGPoint::new(p.x, p.y - self.row_top(r)))
    }

    /// The feature whose experimental mark of header `s` is under `p`.
    fn over_experimental_mark(&self, p: CGPoint, s: &EffectSection) -> Option<sq_draw::experimental::Feature> {
        let (r, f) = self.experimental_marks.get(s)?;
        let row = self.row_at(p)?;
        r.contains(CGPoint::new(p.x, p.y - self.row_top(row))).then_some(*f)
    }

    /// The tooltip at `p` (`sqToolTip` of the Mac control under the pointer), nil for none.
    pub fn help(&self, model: &EffectControlsModel, p: CGPoint) -> Option<String> {
        let tg = self.target_at(model, p);
        match &tg {
            Target::Widget(_) | Target::Field(_) => {
                let key = match &tg {
                    Target::Widget(k) => k.clone(),
                    Target::Field(FieldId { row: RowRef::Custom(k), .. }) => k.clone(),
                    _ => return None,
                };
                let (r, w) = self.widget(model, &key)?;
                if matches!(w.kind, WidgetKind::Surface(_))
                    && let Some(tip) =
                        self.surfaces.get(&key).and_then(|s| s.help(CGPoint::new(p.x, p.y - self.row_top(&r)), w.frame))
                {
                    return Some(tip);
                }
                w.help.map(|h| SQL10n::string(&h))
            }
            Target::WidgetToggle(key) => {
                let (_, w) = self.widget(model, key)?;
                let WidgetKind::Disclosure { title, .. } = &w.kind else { return None };
                Some(SQL10n::format("Enable %@", &[title]))
            }
            Target::Chevron(s) => Some(SQL10n::format(
                if model.collapsed_sections().contains(s) { "Expand %@" } else { "Collapse %@" },
                &[&SQL10n::string(&s.title())],
            )),
            Target::Eye(s) => {
                Some(SQL10n::string(if model.is_effect_enabled(s) { "Disable Effect" } else { "Enable Effect" }))
            }
            Target::SectionReset(s) => Some(SQL10n::format(
                if model.has_user_default(s) { "Reset %@ to Your Default" } else { "Reset %@" },
                &[&SQL10n::string(&s.title())],
            )),
            Target::Header(s) if self.over_experimental_mark(p, s).is_some() => {
                self.over_experimental_mark(p, s).map(sq_draw::experimental::Feature::tooltip)
            }
            Target::Header(s) if model.has_user_default(s) && self.over_default_marker(p, s) => {
                Some(SQL10n::string("Your Default"))
            }
            // Only over the cut text, not the whole row.
            Target::Header(s) => self
                .cut_titles
                .get(s)
                .filter(|(_, r)| {
                    self.row_at(p).is_some_and(|row| r.contains(CGPoint::new(p.x, p.y - self.row_top(row))))
                })
                .map(|(full, _)| full.clone()),
            Target::Ring(_) => Some(SQL10n::string("Toggle Animation")),
            Target::Previous(_) => Some(SQL10n::string("Go to Previous Keyframe")),
            Target::Key(_) => Some(SQL10n::string("Add or Remove Keyframe")),
            Target::Next(_) => Some(SQL10n::string("Go to Next Keyframe")),
            Target::Open(_) => Some(SQL10n::string("Show Curve")),
            Target::Curve(_) => Some(SQL10n::string("Edit Curve")),
            Target::Reset(_) => Some(SQL10n::string("Reset")),
            Target::Link(prop) => {
                if *prop == EffectProperty::Scale {
                    return Some(SQL10n::string("Uniform Scale"));
                }
                Some(SQL10n::string(if model.is_linked(prop) {
                    "Unlink Width and Height"
                } else {
                    "Link Width and Height"
                }))
            }
            Target::KeyPick(_) => Some(SQL10n::string("Pick Key Color from Monitor")),
            Target::Popup(RowRef::Blend) => Some(SQL10n::string("Blend Mode")),
            Target::Label(RowRef::Property(prop)) => Some(SQL10n::string(&prop.title())),
            _ => None,
        }
    }

    /// A press at `p`.
    pub fn mouse_down(
        &mut self,
        model: &mut EffectControlsModel,
        cx: &mut UiCx,
        p: CGPoint,
        click_count: i64,
        modifiers: InputModifiers,
    ) {
        if modifiers.contains(InputModifiers::SECONDARY) {
            // right click: the row's context menu, no press
            self.press_target = Target::None;
            self.context_menu(model, p);
            return;
        }
        let tg = self.target_at(model, p);
        self.press_target = tg.clone();
        self.press_point = p;
        self.press_modifiers = modifiers;
        if let Some(f) = self.focused_field.clone()
            && tg != Target::Field(f.clone())
        {
            if let Some(mut field) = self.fields.remove(&f) {
                let events = field.resign_focus(cx);
                self.fields.insert(f.clone(), field);
                self.apply(model, events, &f);
            }
            self.focused_field = None;
        }
        if let Some(key) = self.focused_text.clone()
            && tg != Target::Widget(key.clone())
        {
            self.commit_text(model, &key);
        }
        match &tg {
            Target::Widget(key) => {
                let Some((r, w)) = self.widget(model, key) else { return };
                let l = CGPoint::new(p.x, p.y - self.row_top(&r));
                match &w.kind {
                    WidgetKind::TextField(..) => {
                        self.focused_text = Some(key.clone());
                        if let Some(f) = self.text_fields.get_mut(key) {
                            f.mouse_down(None, 1);
                        }
                    }
                    WidgetKind::Surface(kind) => {
                        let kind = kind.clone();
                        self.surface(key, &kind).mouse_down(model, l, w.frame, click_count, modifiers);
                    }
                    WidgetKind::Disclosure { .. } if click_count == 2 => {
                        self.press_target = Target::None; // the first click already toggled
                    }
                    _ => {}
                }
            }
            Target::Header(s) => {
                model.select_effect_header(s);
                if click_count == 2 {
                    self.toggle_collapsed(model, s);
                    self.press_target = Target::None;
                }
            }
            Target::Field(id) => {
                self.focused_field = Some(id.clone());
                if let RowRef::Property(prop) = &id.row {
                    model.focused_property = Some(prop.clone());
                }
                if let Some(mut f) = self.fields.remove(id) {
                    let events = f.mouse_down(p.x as f32, click_count);
                    self.fields.insert(id.clone(), f);
                    self.apply(model, events, id);
                }
            }
            Target::Label(rr) => {
                if let RowRef::Property(prop) = rr {
                    model.focused_property = Some(prop.clone());
                    model.select_property_row(
                        prop,
                        modifiers.contains(InputModifiers::SHIFT) || modifiers.contains(InputModifiers::COMMAND),
                    );
                }
            }
            Target::Row(rr) => {
                if let RowRef::Property(prop) = rr {
                    model.focused_property = Some(prop.clone());
                }
                model.clear_row_selection(false); // a click elsewhere on the row clears; only the label selects
            }
            other => {
                if let Some(RowRef::Property(prop)) = other.row_ref() {
                    model.focused_property = Some(prop);
                }
            }
        }
    }

    /// Drag to `p`; `modifiers` default to those of the press.
    pub fn mouse_dragged(
        &mut self,
        model: &mut EffectControlsModel,
        cx: &mut UiCx,
        p: CGPoint,
        modifiers: Option<InputModifiers>,
    ) {
        let mods = modifiers.unwrap_or(self.press_modifiers);
        match self.press_target.clone() {
            Target::Widget(key) => {
                if let Some((r, w)) = self.widget(model, &key)
                    && matches!(w.kind, WidgetKind::Surface(_))
                {
                    let l = CGPoint::new(p.x, p.y - self.row_top(&r));
                    if let Some(s) = self.surfaces.get_mut(&key) {
                        s.mouse_dragged(model, l, w.frame, mods);
                    }
                }
            }
            Target::Field(id) => {
                if let Some(mut f) = self.fields.remove(&id) {
                    let events = f.mouse_dragged(p.x as f32, mods, 1.0, cx);
                    self.fields.insert(id.clone(), f);
                    self.apply(model, events, &id);
                }
            }
            Target::Header(s) => {
                // Dragging an effect header up or down reorders the effects (the list order is the order they are applied in).
                if s.effect_kind().is_none() {
                    return;
                }
                if self.reordering.is_none() && (p.y - self.press_point.y).abs() > 4.0 {
                    self.reordering = Some((s.clone(), None));
                }
                if self.reordering.is_none() {
                    return;
                }
                let blocks = self.effect_blocks();
                let Some(from) = blocks.iter().position(|b| b.0 == s) else { return };
                let mids: Vec<f64> = blocks.iter().map(|b| b.1.min_y() + 9.0).collect();
                if let Some(r) = self.reordering.as_mut() {
                    r.1 = Some(EffectControlsModel::drop_index(p.y + self.scroll_y, &mids, from));
                }
            }
            _ => {}
        }
    }

    /// Release at `p`.
    pub fn mouse_up(&mut self, model: &mut EffectControlsModel, cx: &mut UiCx, p: CGPoint) {
        let pressed = std::mem::replace(&mut self.press_target, Target::None);
        if let Target::Field(id) = &pressed {
            if let Some(mut f) = self.fields.remove(id) {
                let events = f.mouse_up(cx);
                self.fields.insert(id.clone(), f);
                self.apply(model, events, id);
            }
            return;
        }
        if let Target::Widget(key) = &pressed
            && let Some((r, w)) = self.widget(model, key)
            && matches!(w.kind, WidgetKind::Surface(_))
        {
            let l = CGPoint::new(p.x, p.y - self.row_top(&r));
            if let Some(s) = self.surfaces.get_mut(key) {
                s.mouse_up(model, l, w.frame);
            }
            self.sync_fields(model);
            return;
        }
        if let (Target::Header(s), Some(r)) = (&pressed, self.reordering.take()) {
            let blocks = self.effect_blocks();
            let Some(t) = r.1 else { return };
            let Some(from) = blocks.iter().position(|b| &b.0 == s) else { return };
            if t >= blocks.len() || t == from {
                return;
            }
            let Some(index) = model.effect_index(&blocks[t].0) else { return };
            let _ = model.move_effect(s, index as i64);
            return;
        }
        if pressed != Target::None && self.target_at(model, p) == pressed {
            // buttons fire on release inside
            self.click(model, &pressed, p);
        }
    }

    fn toggle_collapsed(&mut self, model: &mut EffectControlsModel, s: &EffectSection) {
        let mut c = model.collapsed_sections().clone();
        if !c.remove(s) {
            c.insert(s.clone());
        }
        model.set_collapsed_sections(c);
        self.relayout(model);
    }

    fn anchor(&self, model: &EffectControlsModel, tg: &Target, p: CGPoint) -> CGRect {
        let Some(r) = self.row_at(p) else { return CGRect::new(p.x, p.y, 0.0, 0.0) };
        let h = r.height;
        let top = self.row_top(r);
        let mut f = match tg {
            Target::Popup(RowRef::Blend) => self.blend_frame(h),
            Target::Popup(RowRef::Property(prop)) | Target::Checkbox(RowRef::Property(prop)) | Target::Well(prop) => {
                prop.param_kind().map_or(CGRect::default(), |k| self.param_frame(prop, &k, h))
            }
            Target::Open(_) => self.navigation_slot(3, h),
            Target::Curve(prop) => self.curve_button_frame(prop, h),
            Target::Widget(key) => self.widget(model, key).map_or(CGRect::default(), |w| w.1.frame),
            _ => CGRect::new(p.x, p.y - top, 0.0, 0.0),
        };
        f.y += top;
        f
    }

    /// A released button: the Mac handlers of each control.
    fn click(&mut self, model: &mut EffectControlsModel, tg: &Target, p: CGPoint) {
        match tg {
            Target::Chevron(s) => self.toggle_collapsed(model, s),
            Target::Eye(s) => model.toggle_effect_enabled(s),
            Target::SectionReset(s) => model.reset_section(s),
            Target::Ring(RowRef::Property(prop)) => self.stopwatch(model, prop),
            Target::Ring(RowRef::Speed(_)) => self.events.push(PanelEvent::Speed(SpeedAction::ToggleAnimation(false))),
            Target::Previous(RowRef::Property(prop)) => model.go_to_previous_key(prop),
            Target::Next(RowRef::Property(prop)) => model.go_to_next_key(prop),
            Target::Key(RowRef::Property(prop)) => {
                let _ = model.toggle_key_at_playhead(prop);
            }
            Target::Open(RowRef::Property(prop)) => {
                model.toggle_open(prop);
                self.relayout(model);
            }
            Target::Open(RowRef::Speed(_)) => {
                // The ease editor of the speed transition at the playhead (the popover every keyframe curve uses).
                let anchor = self.anchor(model, tg, p);
                self.events.push(PanelEvent::EaseCurve { target: EaseCurveTarget::SpeedTransition, anchor });
            }
            Target::Curve(prop) => {
                if let Some(id) = Self::motion_curve_effect(prop) {
                    let anchor = self.anchor(model, tg, p);
                    self.events.push(PanelEvent::EaseCurve { target: EaseCurveTarget::Motion(id), anchor });
                }
            }
            Target::Reset(RowRef::Property(prop)) => model.reset_all(prop),
            Target::Previous(RowRef::Speed(_)) => model.go_to_previous_speed_key(),
            Target::Next(RowRef::Speed(_)) => model.go_to_next_speed_key(),
            Target::Key(RowRef::Speed(_)) => self.events.push(PanelEvent::Speed(SpeedAction::ToggleKey)),
            Target::Reset(RowRef::Speed(_)) => {
                if model.speed_is_animated() {
                    self.events.push(PanelEvent::Speed(SpeedAction::ToggleAnimation(true)));
                }
                self.events.push(PanelEvent::Speed(SpeedAction::Set(100.0)));
            }
            Target::GraphHead(prop, h) => self.click_graph_head(model, prop, *h),
            Target::Link(prop) => {
                if *prop == EffectProperty::Scale {
                    model.set_uniform_scale(!model.uniform_scale);
                } else {
                    let on = model.is_linked(prop);
                    model.set_linked(prop, !on);
                }
                self.relayout(model);
            }
            Target::KeyPick(prop) => self.events.push(PanelEvent::PickKeyColor(prop.clone())),
            Target::Checkbox(RowRef::Speed(k)) => {
                if *k == SpeedControl::Reverse {
                    self.events.push(PanelEvent::Speed(SpeedAction::SetReversed(!model.is_reversed())));
                } else {
                    self.events.push(PanelEvent::Speed(SpeedAction::SetKeepsPitch(!model.keeps_pitch())));
                }
            }
            Target::Checkbox(RowRef::Property(prop)) => {
                let on = prop.param_kind().is_some_and(|k| k.is_on(model.scalar_value(prop)));
                let _ = model.set_value(
                    prop,
                    EffectComponent::All,
                    if model.is_mixed(prop, EffectComponent::All) || !on { 1.0 } else { 0.0 },
                ); // from mixed: on
            }
            Target::Popup(RowRef::Blend) => {
                if !model.is_blend_group_enabled() {
                    return;
                }
                let anchor = self.anchor(model, tg, p);
                self.events.push(PanelEvent::Menu { menu: self.blend_menu(model), anchor });
            }
            Target::Popup(RowRef::Property(prop)) => {
                let anchor = self.anchor(model, tg, p);
                self.events.push(PanelEvent::Menu { menu: self.choice_menu(model, prop), anchor });
            }
            Target::Well(prop) => {
                model.focused_property = Some(prop.clone());
                let anchor = self.anchor(model, tg, p);
                self.events.push(PanelEvent::PickColor {
                    current: model.color_value(prop).clamped(),
                    anchor,
                    target: ColorTarget::Property(prop.clone()),
                });
            }
            Target::Widget(key) => {
                let Some((_, w)) = self.widget(model, key) else { return };
                if !w.enabled {
                    return;
                }
                let anchor = self.anchor(model, tg, p);
                if let Some(menu) = &w.menu {
                    self.events.push(PanelEvent::Menu { menu: menu(), anchor });
                    return;
                }
                if matches!(w.kind, WidgetKind::TextField(..)) {
                    return;
                }
                if let Some(action) = &w.action {
                    let mut events = Vec::new();
                    action(&mut PanelCx { model, events: &mut events, anchor, asks: self.asks_before_removing });
                    self.events.extend(events);
                }
                self.relayout(model);
                return;
            }
            Target::WidgetToggle(key) => {
                if let Some((_, w)) = self.widget(model, key)
                    && let Some(toggle) = &w.toggle
                {
                    let mut events = Vec::new();
                    toggle(&mut PanelCx {
                        model,
                        events: &mut events,
                        anchor: CGRect::default(),
                        asks: self.asks_before_removing,
                    });
                    self.events.extend(events);
                }
                self.relayout(model);
                return;
            }
            _ => {}
        }
        self.sync_fields(model);
    }

    /// EffectControlsView.stopwatchTapped: turning animation off asks before the keys go.
    pub(crate) fn stopwatch(&mut self, model: &mut EffectControlsModel, p: &EffectProperty) {
        let mut events = Vec::new();
        stopwatch_in(model, &mut events, self.asks_before_removing, p);
        self.events.extend(events);
    }

    /// The host confirmed a [`PanelEvent::ConfirmRemoveKeyframes`] question; Speed needs the session, so the host runs
    /// `SpeedAction::ToggleAnimation(true)` itself for [`RemoveKeys::Speed`].
    pub fn confirm_remove_keyframes(&mut self, model: &mut EffectControlsModel, what: &RemoveKeys) {
        if let RemoveKeys::Property(p) = what {
            let _ = model.toggle_stopwatch(p, true);
        }
    }

    /// The color picker reports a change (`Some`) or closes (`None`).
    pub fn color_picked(&mut self, model: &mut EffectControlsModel, target: &ColorTarget, color: Option<EffectColor>) {
        match target {
            ColorTarget::Property(prop) => match color {
                Some(c) => {
                    let _ = model.set_color_continuously(prop, c);
                }
                None => model.end_color_gesture(),
            },
            ColorTarget::MaskRange(id) => {
                let Some(c) = color.map(|c| c.clamped()) else {
                    if self.mask_color_began {
                        model.end_gesture();
                        self.mask_color_began = false;
                    }
                    return;
                };
                if !self.mask_color_began {
                    model.begin_gesture();
                    self.mask_color_began = true;
                }
                if let Some(k) = model.color_range_of(*id) {
                    model.set_mask_color_range(
                        *id,
                        sq_core_model::ColorRangeKey::new(c.red, c.green, c.blue, k.tolerance, k.softness),
                    );
                }
            }
        }
    }

    /// The screen sampler picked a color for a Key Hue eyedropper.
    pub fn key_color_picked(&mut self, model: &mut EffectControlsModel, prop: &EffectProperty, rgb: (f64, f64, f64)) {
        model.apply_key_color(prop, EffectControlsModel::linear_from_srgb(rgb.0, rgb.1, rgb.2));
    }

    // MARK: Menus

    /// BlendModeRow: the sections of `BlendMode.menuSections` with a separator between them.
    pub fn blend_menu(&self, model: &EffectControlsModel) -> ModelMenu {
        let mut m = ModelMenu::default();
        let current = if model.is_blend_mode_mixed() { None } else { Some(model.blend_mode()) };
        for (n, section) in sq_core_model::BlendMode::menu_sections().iter().enumerate() {
            if n > 0 {
                m.entries.push(MenuEntry::plain(SQMenuItem::separator()));
            }
            for mode in section {
                let mode = *mode;
                let mut item = SQMenuItem::new(mode.title());
                item.is_checked = Some(mode) == current;
                m.entries.push(MenuEntry::action(item, move |mdl, _| mdl.set_blend_mode(mode)));
            }
        }
        m
    }

    /// EffectChoiceRow: the catalog's items; an item can be off for this clip, with the reason as help.
    pub fn choice_menu(&self, model: &EffectControlsModel, p: &EffectProperty) -> ModelMenu {
        let Some(sq_core_model::EffectParamKind::Choice(items)) = p.param_kind() else { return ModelMenu::default() };
        let off = model.disabled_choices(p);
        let current = if model.is_mixed(p, EffectComponent::All) {
            None
        } else {
            p.param_kind().map(|k| k.choice_index(model.scalar_value(p)))
        };
        let mut m = ModelMenu::default();
        for (i, title) in items.iter().enumerate() {
            let mut item = SQMenuItem::new(title);
            item.is_enabled = !off.contains_key(&(i as i64));
            item.is_checked = Some(i as i64) == current;
            item.help = off.get(&(i as i64)).cloned();
            let p = p.clone();
            m.entries.push(MenuEntry::action(item, move |mdl, _| {
                let _ = mdl.set_value(&p, EffectComponent::All, i as f64);
            }));
        }
        m
    }

    /// Right-click at `p`: the row's menu (SectionHeaderRow / PropertyRow / EffectParamRowBase.contextItems).
    pub fn context_menu(&mut self, model: &mut EffectControlsModel, p: CGPoint) {
        let Some(r) = self.row_at(p) else { return };
        let menu = match r.kind.clone() {
            EffectRowKind::Section(s) => self.section_menu(model, &s),
            EffectRowKind::Property(prop) => {
                let numeric = prop.param_kind().as_ref().is_none_or(Self::is_number);
                self.property_menu(model, &prop, numeric)
            }
            _ => return,
        };
        if menu.is_empty() {
            return;
        }
        self.events.push(PanelEvent::Menu { menu, anchor: CGRect::new(p.x, p.y, 0.0, 0.0) });
    }

    /// The right-click menu of a section header.
    pub fn section_menu(&self, model: &mut EffectControlsModel, section: &EffectSection) -> ModelMenu {
        model.selected_section = Some(section.clone());
        let mut m: Vec<MenuEntry> = Vec::new();
        let item = |title: &str,
                    shortcut: &str,
                    enabled: bool,
                    section: EffectSection,
                    run: fn(&mut EffectControlsModel, &EffectSection)| {
            let mut i = SQMenuItem::new(title);
            i.shortcut = shortcut.to_string();
            i.is_enabled = enabled;
            MenuEntry::action(i, move |mdl, _| run(mdl, &section))
        };
        // Order (INTERACTION-AUDIT section 5): edit group, then the effect's own actions, then the destructive ones last.
        let removable = model.can_remove_effect(section);
        if removable {
            m.push(item(
                "Cut",
                &sq_uikit::key_binding_text::KeyBindingText::command_hint('x', sq_os::Platform::current()),
                true,
                section.clone(),
                |mdl, s| {
                    mdl.cut_effect(s);
                },
            ));
        }
        if model.can_copy_effect(section) {
            m.push(item(
                "Copy",
                &sq_uikit::key_binding_text::KeyBindingText::command_hint_here('c'),
                true,
                section.clone(),
                |mdl, s| {
                    if mdl.copy_effect(s) {
                        mdl.mark_effect_copied();
                    }
                },
            ));
        }
        if model.can_paste_effect() {
            m.push(item(
                "Paste",
                &sq_uikit::key_binding_text::KeyBindingText::command_hint_here('v'),
                true,
                section.clone(),
                |mdl, _| {
                    mdl.paste_effect();
                },
            ));
        }
        if removable {
            m.push(item("Duplicate Effect", "", true, section.clone(), |mdl, s| {
                mdl.duplicate_effect(s);
            }));
        }
        if !m.is_empty() {
            m.push(MenuEntry::plain(SQMenuItem::separator()));
        }
        if model.has_fx_toggle(section) {
            let on = model.is_effect_enabled(section) && !model.is_effect_enabled_mixed(section);
            m.push(item(if on { "Disable Effect" } else { "Enable Effect" }, "", true, section.clone(), |mdl, s| {
                mdl.toggle_effect_enabled(s)
            }));
        }
        m.push(item(
            &SQL10n::format(
                if model.has_user_default(section) { "Reset %@ to Your Default" } else { "Reset %@" },
                &[&SQL10n::string(&section.title())],
            ),
            "",
            true,
            section.clone(),
            |mdl, s| mdl.reset_section(s),
        ));
        if model.can_use_as_default(section) {
            m.push(MenuEntry::plain(SQMenuItem::separator()));
            m.push(item("Use as Default", "", true, section.clone(), |mdl, s| {
                mdl.use_as_default(s, true);
            }));
            if model.effect_is_animated(section) {
                m.push(item("Use as Default Without Keyframes", "", true, section.clone(), |mdl, s| {
                    mdl.use_as_default(s, false);
                }));
            }
            m.push(item("Reset Default to Factory", "", model.has_user_default(section), section.clone(), |mdl, s| {
                mdl.reset_default_to_factory(s)
            }));
        }
        if section.effect_kind().is_some() {
            m.push(MenuEntry::plain(SQMenuItem::separator()));
            m.push(item(
                "Convert to Keyframes",
                "",
                model.can_convert_to_keyframes(section, None),
                section.clone(),
                |mdl, s| mdl.convert_to_keyframes(s),
            ));
        } else if *section == EffectSection::Motion {
            m.push(MenuEntry::plain(SQMenuItem::separator()));
            let mut i = SQMenuItem::new(&model.reopen_title());
            i.is_enabled = model.can_reopen_as_effect();
            m.push(MenuEntry::action(i, |mdl, _| mdl.reopen_as_effect()));
        }
        let is_mask = matches!(section, EffectSection::Mask(_));
        if removable || is_mask {
            m.push(MenuEntry::plain(SQMenuItem::separator()));
        }
        if removable && !is_mask {
            m.push(item(
                "Delete",
                &sq_uikit::key_binding_text::KeyBindingText::delete_hint_here(),
                true,
                section.clone(),
                |mdl, s| {
                    mdl.remove_effect(s);
                },
            ));
        }
        if let EffectSection::Mask(id) = section {
            let id = *id;
            m.push(MenuEntry::action(SQMenuItem::new("Delete Mask"), move |mdl, _| mdl.remove_mask(id)));
        }
        ModelMenu { entries: m }
    }

    /// The right-click menu of a property row.
    pub fn property_menu(&self, model: &EffectControlsModel, p: &EffectProperty, numeric: bool) -> ModelMenu {
        let animated = model.is_animated(p);
        let mut m: Vec<MenuEntry> = Vec::new();
        if animated {
            if numeric {
                let st = model.keyframe_control_state(p);
                let mut add = SQMenuItem::new(if st.key_is_on { "Remove Keyframe" } else { "Add Keyframe" });
                add.is_enabled = st.can_toggle_key;
                let pp = p.clone();
                m.push(MenuEntry::action(add, move |mdl, _| {
                    let _ = mdl.toggle_key_at_playhead(&pp);
                }));
                let mut prev = SQMenuItem::new("Go to Previous Keyframe");
                prev.is_enabled = st.can_go_previous;
                let pp = p.clone();
                m.push(MenuEntry::action(prev, move |mdl, _| mdl.go_to_previous_key(&pp)));
                let mut next = SQMenuItem::new("Go to Next Keyframe");
                next.is_enabled = st.can_go_next;
                let pp = p.clone();
                m.push(MenuEntry::action(next, move |mdl, _| mdl.go_to_next_key(&pp)));
                m.push(MenuEntry::plain(SQMenuItem::separator()));
            }
            let mut at = SQMenuItem::new("Reset at Playhead");
            at.is_enabled = model.playhead_in_clip();
            let pp = p.clone();
            m.push(MenuEntry::action(at, move |mdl, _| {
                mdl.reset_at_playhead(&pp);
            }));
        }
        let mut reset = SQMenuItem::new(if animated { "Reset All (Remove Keyframes)" } else { "Reset" });
        reset.is_enabled = !model.is_default(p);
        let pp = p.clone();
        m.push(MenuEntry::action(reset, move |mdl, _| mdl.reset_all(&pp)));
        m.push(MenuEntry::plain(SQMenuItem::separator()));
        let mut ge = SQMenuItem::new(model.graph_editor_menu_title());
        ge.is_enabled = model.clip().is_some();
        m.push(MenuEntry::action(ge, |mdl, _| mdl.toggle_graph_editor()));
        if numeric && self.automatic_resettable.contains(p) {
            // a variant is active and overrides this property
            m.push(MenuEntry::plain(SQMenuItem::separator()));
            let pp = p.clone();
            m.push(MenuEntry::action(SQMenuItem::new("Reset to Automatic"), move |_, out| {
                out.push(MenuOutput::ResetToAutomatic(pp.clone()))
            }));
        }
        ModelMenu { entries: m }
    }

    // MARK: Keys, wheel, timer

    /// The keyboard left the panel (a press elsewhere, another panel's focus, a dialog or menu): the typed value commits
    /// and no field stays focused, so a stale field never takes the next Enter or the next click as its own.
    pub fn blur(&mut self, model: &mut EffectControlsModel, cx: &mut UiCx) {
        if let Some(f) = self.focused_field.take()
            && let Some(mut field) = self.fields.remove(&f)
        {
            let events = field.resign_focus(cx);
            self.fields.insert(f.clone(), field);
            self.apply(model, events, &f);
        }
        if let Some(key) = self.focused_text.clone() {
            self.commit_text(model, &key);
        }
    }

    /// Whether a value field or a text field has the keyboard.
    pub fn has_keyboard_focus(&self) -> bool {
        self.focused_field.is_some() || self.focused_text.is_some()
    }

    /// A key for the focused field (typing, arrows, Esc). Returns whether the panel used it.
    pub fn key(
        &mut self,
        model: &mut EffectControlsModel,
        cx: &mut UiCx,
        k: InputKey,
        modifiers: InputModifiers,
    ) -> bool {
        // Undo / Redo are the project's, not the field's: a value being typed is dropped (as Escape does) and the key goes
        // on to the app, so Cmd+Z after an inspector edit never dies in a field that was left open.
        if modifiers.contains(InputModifiers::COMMAND) && k == InputKey::Character('z') {
            if self.focused_field.is_some() || self.focused_text.is_some() {
                let _ = self.key(model, cx, InputKey::Escape, InputModifiers::NONE);
            }
            return false;
        }
        if k == InputKey::Character('\t') && (self.focused_field.is_some() || self.focused_text.is_some()) {
            self.move_focus(model, cx, modifiers.contains(InputModifiers::SHIFT));
            return true;
        }
        if let Some(key) = self.focused_text.clone()
            && let Some(f) = self.text_fields.get_mut(&key)
        {
            let committed = f.key(k, modifiers, cx);
            let editing = f.is_editing();
            if let Some(text) = committed {
                self.run_commit(model, &key, &text);
            }
            if !editing {
                self.focused_text = None;
            }
            return true;
        }
        let Some(id) = self.focused_field.clone() else { return false };
        let Some(mut f) = self.fields.remove(&id) else { return false };
        let events = f.key(k, modifiers, cx.now, cx);
        let used = !events.is_empty()
            || f.is_editing()
            || [InputKey::Up, InputKey::Down, InputKey::Escape, InputKey::Enter].contains(&k);
        let editing = f.is_editing();
        self.fields.insert(id.clone(), f);
        self.apply(model, events, &id);
        if !editing && (k == InputKey::Enter || k == InputKey::Escape) {
            self.focused_field = None;
        }
        used
    }

    /// The fields in row order (Tab order): the scrub fields of every row and the text fields of translated rows.
    pub(crate) fn focus_order(&self, model: &EffectControlsModel) -> Vec<Focusable> {
        let mut out = Vec::new();
        for r in &self.rows {
            if let Some(ws) = self.widgets(model, r) {
                for w in ws {
                    match w.kind {
                        WidgetKind::Field(_) if w.enabled => {
                            out.push(Focusable::Field(FieldId {
                                row: RowRef::Custom(w.key),
                                component: EffectComponent::All,
                            }));
                        }
                        WidgetKind::TextField(..) if w.enabled => out.push(Focusable::Text(w.key)),
                        _ => {}
                    }
                }
            } else {
                out.extend(
                    self.field_ids(model, &r.kind)
                        .into_iter()
                        .filter(|id| self.fields.get(id).is_some_and(|f| f.is_enabled))
                        .map(Focusable::Field),
                );
            }
        }
        out
    }

    /// Tab / Shift+Tab (ScrubField's nextKeyView chain): commit the current field and open the next one for typing.
    pub(crate) fn move_focus(&mut self, model: &mut EffectControlsModel, cx: &mut UiCx, backward: bool) {
        let order = self.focus_order(model);
        let current =
            self.focused_field.clone().map(Focusable::Field).or_else(|| self.focused_text.clone().map(Focusable::Text));
        if let Some(f) = self.focused_field.take()
            && let Some(mut field) = self.fields.remove(&f)
        {
            let events = field.resign_focus(cx);
            self.fields.insert(f.clone(), field);
            self.apply(model, events, &f);
        }
        if let Some(key) = self.focused_text.clone() {
            self.commit_text(model, &key);
        }
        self.sync_fields(model);
        if order.is_empty() {
            return;
        }
        let i = current.and_then(|c| order.iter().position(|o| *o == c)).unwrap_or(if backward {
            0
        } else {
            order.len() - 1
        });
        let next = order[(i + if backward { order.len() - 1 } else { 1 }) % order.len()].clone();
        match next {
            Focusable::Field(id) => {
                self.focused_field = Some(id.clone());
                if let Some(f) = self.fields.get_mut(&id) {
                    f.begin_editing();
                }
            }
            Focusable::Text(key) => {
                self.focused_text = Some(key.clone());
                if let Some(f) = self.text_fields.get_mut(&key) {
                    f.mouse_down(None, 1);
                }
            }
        }
    }

    fn commit_text(&mut self, model: &mut EffectControlsModel, key: &str) {
        self.focused_text = None;
        let Some(f) = self.text_fields.get_mut(key) else { return };
        let text = f.commit();
        if let Some(text) = text {
            self.run_commit(model, key, &text);
        }
    }

    fn run_commit(&mut self, model: &mut EffectControlsModel, key: &str, text: &str) {
        let Some((_, w)) = self.widget(model, key) else { return };
        let WidgetKind::TextField(_, commit) = &w.kind else { return };
        commit(model, text);
        self.sync_fields(model);
    }

    /// Wheel at `p`: Option steps the hovered or focused field (ScrubField); otherwise the panel scrolls.
    pub fn scroll(
        &mut self,
        model: &mut EffectControlsModel,
        cx: &mut UiCx,
        p: CGPoint,
        dy: f64,
        precise: bool,
        modifiers: InputModifiers,
    ) -> bool {
        if let Target::Field(id) = self.target_at(model, p)
            && let Some(mut f) = self.fields.remove(&id)
        {
            let focused = self.focused_field.as_ref() == Some(&id);
            let (used, events) = f.scroll(dy, precise, modifiers, focused, cx.now, cx);
            self.fields.insert(id.clone(), f);
            self.apply(model, events, &id);
            if used {
                return true;
            }
        }
        if let Target::Widget(key) = self.target_at(model, p)
            && let Some((r, w)) = self.widget(model, &key)
            && matches!(w.kind, WidgetKind::Surface(_))
        {
            let l = CGPoint::new(p.x, p.y - self.row_top(&r));
            let g: Option<ScrollGesture> = cx.gesture;
            if let Some(s) = self.surfaces.get_mut(&key)
                && s.scroll(model, l, w.frame, if precise { dy } else { dy * 4.0 }, g.as_ref())
            {
                return true;
            }
        }
        let max_y = (self.content_height() - self.size.height).max(0.0);
        let y = (self.scroll_y - dy).max(0.0).min(max_y);
        if y == self.scroll_y {
            return false;
        }
        self.scroll_y = y;
        true
    }

    /// The notices of effects (Pro grading, Stabilize) that are not closed yet.
    pub(crate) fn open_notices() -> Vec<sq_draw::experimental::Feature> {
        use sq_draw::experimental::Feature;
        let p = sq_draw::experimental::prefs();
        [Feature::ProGrading, Feature::Stabilize].into_iter().filter(|f| p.shows_notice(*f)).collect()
    }

    /// Ends idle arrow / wheel bursts (call every frame or from a timer).
    pub fn tick(&mut self, model: &mut EffectControlsModel, now: f64) {
        let notice = sq_draw::experimental::prefs().shows_notice(sq_draw::experimental::Feature::MagicMask);
        if notice != self.magic_notice_laid_out || Self::open_notices() != self.notices_laid_out {
            self.relayout(model);
        }
        let ids: Vec<FieldId> = self.fields.keys().cloned().collect();
        for id in ids {
            let Some(mut f) = self.fields.remove(&id) else { continue };
            let events = f.tick(now);
            self.fields.insert(id.clone(), f);
            self.apply(model, events, &id);
        }
    }

    // MARK: Pixels

    /// Host glue: an `InputEvent` in pixels, the panel at `origin` (points) in the window, `scale` pixels per point.
    // Clicks are counted here and a drag keeps the modifiers of its press: both match Swift (`EffectControlsDrawPanel`).
    pub fn handle(
        &mut self,
        model: &mut EffectControlsModel,
        cx: &mut UiCx,
        e: &InputEvent,
        scale: f32,
        origin: CGPoint,
    ) -> bool {
        let pt = |x: f32, y: f32| CGPoint::new((x / scale) as f64 - origin.x, (y / scale) as f64 - origin.y);
        match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = pt(x, y);
                let n = self.clicks.press(p.x as f32, p.y as f32, cx.now);
                self.mouse_down(model, cx, p, n, modifiers);
            }
            InputEvent::MouseDragged { x, y, .. } => self.mouse_dragged(model, cx, pt(x, y), None),
            InputEvent::MouseUp { x, y } => self.mouse_up(model, cx, pt(x, y)),
            InputEvent::MouseMoved { x, y } => {
                let p = pt(x, y);
                self.mouse_moved(model, Some(p));
                let tip = self.help(model, p);
                cx.hover.offer_tip(tip.as_deref());
            }
            InputEvent::Scroll { x, y, dy, modifiers, .. } => {
                return self.scroll(model, cx, pt(x, y), (dy / scale) as f64, true, modifiers);
            }
            InputEvent::KeyDown { key, modifiers } => return self.key(model, cx, key, modifiers),
        }
        true
    }
}

/// `stopwatchTapped`: turning animation off asks before the keys go.
pub(crate) fn stopwatch_in(
    model: &mut EffectControlsModel,
    events: &mut Vec<PanelEvent>,
    asks: bool,
    p: &EffectProperty,
) {
    if model.toggle_stopwatch(p, !asks) == StopwatchOutcome::NeedsConfirmation {
        events.push(PanelEvent::ConfirmRemoveKeyframes { title: p.title(), what: RemoveKeys::Property(p.clone()) });
    }
}
