// Swift: KeystonePalette.swift
//! Window > Keystones on the shared toolkit, translated from the Mac `KeystonesPanelView` list: the same rows
//! (`KeystonesPanelModel`: built-ins plus saved ones, diamond, name, `subtitle`) on a floating card over the timeline
//! area. Press a row and drag it onto a clip, or double-click to apply it to the selected clip; the header "..." and the
//! right-click menu save, apply, edit the curve and delete (`context_items`, the Mac `contextItems(row:)`).
//!
//! Not ported here (they read the panel struct, see `PANEL-FIELDS-DT3-4.md`): `TimelinePanel+Bands`, `+SpeedBand`,
//! `+SpeedCommands`, `+FastCut`, `+Keystones`, `+TransitionLayer`, `+SilencePreview`, `+SourcePatch`, `+ViewCommands`.

use sq_core_effects::keystone::Keystone;
use sq_core_effects::transition_layer::ClipTransitionLayer;
use sq_core_model::TrackKind;
use sq_core_model::{ClipEdge, Timeline};
use sq_core_time::Id;
use sq_core_time::Time;
use sq_draw::scroll::ScrollBody;
use sq_draw::{Canvas, Color, DrawTheme, InputEvent, InputKey, InputModifiers, TextAlign, UiCx};
use sq_timeline_ui::KeystonesPanelModel;
use sq_timeline_ui::{TimelineGeometry, TrackRow, TransitionLayerLayout, TransitionLayerZone};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{metrics, radius, spacing, type_size};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::collections::BTreeSet;
use std::rc::Rc;

/// What the Keystones card asks of its host.
#[derive(Clone, Debug, PartialEq)]
pub enum KeystonePaletteEvent {
    /// A row is being dragged; the pointer is at window pixels `x`, `y` (the host calls `TimelinePanel.keystoneHover`).
    Drag(Box<Keystone>, f32, f32),
    /// Released at window pixels `x`, `y` (`keystoneDrop` when over the panel, else `keystoneExit`).
    Drop(Box<Keystone>, f32, f32),
    /// Esc during the drag (`keystoneExit`).
    Cancel,
    /// Double-click: the Mac panel's "Apply to Selected Clip".
    Apply(Box<Keystone>),
    /// Right press on the card at window points: the row's keystone (`None` off the rows). The host shows
    /// `KeystonePalette::context_items`.
    Menu(Option<Box<Keystone>>, CGPoint),
    /// The header "..." at window points: the host shows `KeystonePalette::option_items`.
    Options(CGPoint),
    /// Delete key on the selected keystone (the host deletes it when `KeystonesPanelModel::can_delete`).
    Delete(Box<Keystone>),
}

#[derive(Clone, Copy, Debug)]
struct RowPress {
    index: usize,
    start: CGPoint,
}

/// Width of the "changed" chip of an edited built-in keystone row (the Mac `KeystoneChip`): the word plus padding.
pub fn changed_chip_width(c: &Canvas, font: f64, pad: f64) -> f64 {
    c.size_of(&SQL10n::string("changed"), font, 0).width.ceil() + 2.0 * pad - pad
}

/// Draws the "changed" chip with its left edge at `at.x`, centered on `at.y`.
pub fn draw_changed_chip(c: &mut Canvas, t: &DrawTheme, at: CGPoint, width: f64, font: f64) {
    let chip = CGRect::new(at.x, at.y - 10.0, width, 20.0);
    c.fill_rounded(chip, f64::from(radius::MENU), t.fill());
    c.draw_text_in(&SQL10n::string("changed"), chip, font, t.label2(), TextAlign::Center, 0.0, 0);
}

pub struct KeystonePalette {
    pub theme: DrawTheme,
    pub is_visible: bool,
    pub keystones: Vec<Keystone>,
    pub selected_id: Option<Id>,
    /// Built-in keystones the user edited: their row carries the "changed" chip (the Mac `KeystoneChip`).
    pub changed: BTreeSet<Id>,
    /// Seconds clock (injectable for tests).
    pub clock: Box<dyn Fn() -> f64>,
    /// Docked in a dock card (the Mac `KeystonesPanelView` as a Window > Keystones panel): the list fills the card, the
    /// card's tab strip carries the title and the "..." (`layout_docked`); no own header, shadow or close button.
    is_docked: bool,
    /// The card in window points.
    frame: CGRect,
    scale: f32,
    hovered: Option<usize>,
    scroll_body: ScrollBody,
    /// The scroll offset as last read from the body (`tick` and the wheel update it).
    scroll: f64,
    press: Option<RowPress>,
    dragging: Option<Keystone>,
    /// Where the pointer is (window points) while a row is dragged; `None` otherwise.
    drag_point: Option<CGPoint>,
    last_click: Option<(usize, f64)>,
    hover_point: Option<CGPoint>,
}

fn uptime() -> f64 {
    use std::sync::OnceLock;
    use std::time::Instant;
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

impl KeystonePalette {
    // Mac metrics: `Theme.Row.panelList` 24, panel header 30, `Theme.Spacing.sm` padding.
    pub const ROW_HEIGHT: f64 = 24.0;
    pub const HEADER_HEIGHT: f64 = metrics::PANEL_HEADER as f64;
    pub const WIDTH: f64 = 280.0;
    const DRAG_SLOP: f64 = 3.0;
    const DOUBLE_CLICK: f64 = 0.4;

    pub fn new(theme: DrawTheme) -> Self {
        KeystonePalette {
            theme,
            is_visible: false,
            keystones: Vec::new(),
            selected_id: None,
            changed: BTreeSet::new(),
            clock: Box::new(uptime),
            is_docked: false,
            frame: CGRect::new(0.0, 0.0, 0.0, 0.0),
            scale: 1.0,
            hovered: None,
            scroll_body: ScrollBody::new(0.0),
            scroll: 0.0,
            press: None,
            dragging: None,
            drag_point: None,
            last_click: None,
            hover_point: None,
        }
    }

    pub fn is_docked(&self) -> bool {
        self.is_docked
    }

    pub fn frame(&self) -> CGRect {
        self.frame
    }

    pub fn hovered(&self) -> Option<usize> {
        self.hovered
    }

    pub fn scroll(&self) -> f64 {
        self.scroll
    }

    pub fn dragging(&self) -> Option<&Keystone> {
        self.dragging.as_ref()
    }

    /// Where the pointer is while a row is dragged; the host tints the drop target under it.
    pub fn drag_point(&self) -> Option<CGPoint> {
        self.drag_point
    }

    pub fn is_dragging(&self) -> bool {
        self.press.is_some()
    }

    /// Advances a fling or bounce of the list to `now`.
    pub fn tick(&mut self, now: f64) {
        self.scroll = self.scroll_body.offset(now);
    }

    fn set_scroll(&mut self, v: f64) {
        self.scroll_body = ScrollBody::new(v);
        self.scroll_body.max_offset = self.max_scroll();
        self.scroll = self.scroll_body.position();
    }

    /// Anchors the card to the top right of `area` (window points), as tall as its rows allow.
    pub fn layout(&mut self, area: CGRect, scale: f32) {
        self.scale = scale;
        let inset = f64::from(spacing::SM);
        let rows = self.keystones.len() as f64 * Self::ROW_HEIGHT + Self::HEADER_HEIGHT + f64::from(spacing::XS);
        let h = rows.min(area.height - 2.0 * inset).max(Self::HEADER_HEIGHT);
        let w = Self::WIDTH.min((area.width - 2.0 * inset).max(0.0));
        self.frame = CGRect::new(area.max_x() - inset - w, area.min_y() + inset, w, h);
        self.is_docked = false;
        let clamped = self.scroll.min(self.max_scroll());
        self.set_scroll(clamped);
    }

    /// Fills `card` (window points) as a docked panel; `None` hides it (its tab is not the shown one).
    pub fn layout_docked(&mut self, card: Option<CGRect>, scale: f32) {
        self.scale = scale;
        self.is_docked = true;
        self.is_visible = card.is_some();
        self.frame = card.unwrap_or(CGRect::new(0.0, 0.0, 0.0, 0.0));
        let clamped = self.scroll.min(self.max_scroll());
        self.set_scroll(clamped);
    }

    fn header_height_now(&self) -> f64 {
        if self.is_docked { f64::from(spacing::XS) } else { Self::HEADER_HEIGHT }
    }

    fn list_rect(&self) -> CGRect {
        let h = self.header_height_now();
        CGRect::new(self.frame.min_x(), self.frame.min_y() + h, self.frame.width, (self.frame.height - h).max(0.0))
    }

    fn close_rect(&self) -> CGRect {
        let s = 20.0;
        CGRect::new(
            self.frame.max_x() - f64::from(spacing::SM) - s,
            self.frame.min_y() + (Self::HEADER_HEIGHT - s) / 2.0,
            s,
            s,
        )
    }

    /// The header "..." (the Mac panel header's options button), left of the close button.
    fn options_rect(&self) -> CGRect {
        let c = self.close_rect();
        CGRect::new(c.x - c.width - f64::from(spacing::XS), c.y, c.width, c.height)
    }

    fn max_scroll(&self) -> f64 {
        (self.keystones.len() as f64 * Self::ROW_HEIGHT - self.list_rect().height).max(0.0)
    }

    pub fn row_rect(&self, i: usize) -> CGRect {
        CGRect::new(
            self.frame.min_x(),
            self.list_rect().min_y() + i as f64 * Self::ROW_HEIGHT - self.scroll,
            self.frame.width,
            Self::ROW_HEIGHT,
        )
    }

    pub fn row_at(&self, p: CGPoint) -> Option<usize> {
        let list = self.list_rect();
        if !list.contains(p) {
            return None;
        }
        let i = ((p.y - list.min_y() + self.scroll) / Self::ROW_HEIGHT).floor();
        (i >= 0.0 && (i as usize) < self.keystones.len()).then_some(i as usize)
    }

    /// The hover tip of the row at window point `p`: what the keystone animates (the Mac row tooltip).
    pub fn help_at(&self, p: CGPoint) -> Option<String> {
        self.row_at(p).map(|i| KeystonesPanelModel::subtitle(&self.keystones[i]))
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        self.is_visible && self.frame.contains(CGPoint { x: f64::from(x / self.scale), y: f64::from(y / self.scale) })
    }

    // MARK: Events

    /// Events on the card and the drags that start on it; `None` = not the card's (pointer moves always go on).
    pub fn handle(&mut self, e: &InputEvent, cx: &mut UiCx) -> Option<Vec<KeystonePaletteEvent>> {
        if !self.is_visible {
            return None;
        }
        let k = f64::from(self.scale.max(0.01));
        match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = CGPoint { x: f64::from(x) / k, y: f64::from(y) / k };
                if !self.frame.contains(p) {
                    return None;
                }
                if !self.is_docked && self.close_rect().contains(p) {
                    self.is_visible = false;
                    return Some(Vec::new());
                }
                if !self.is_docked && self.options_rect().contains(p) {
                    let o = self.options_rect();
                    return Some(vec![KeystonePaletteEvent::Options(CGPoint { x: o.min_x(), y: o.max_y() })]);
                }
                let secondary = modifiers.contains(InputModifiers::SECONDARY);
                let Some(i) = self.row_at(p) else {
                    return Some(if secondary { vec![KeystonePaletteEvent::Menu(None, p)] } else { Vec::new() });
                };
                self.selected_id = Some(self.keystones[i].id);
                if secondary {
                    return Some(vec![KeystonePaletteEvent::Menu(Some(Box::new(self.keystones[i].clone())), p)]);
                }
                let t = (self.clock)();
                if let Some((index, time)) = self.last_click
                    && index == i
                    && t - time < Self::DOUBLE_CLICK
                {
                    self.last_click = None;
                    return Some(vec![KeystonePaletteEvent::Apply(Box::new(self.keystones[i].clone()))]);
                }
                self.last_click = Some((i, t));
                self.press = Some(RowPress { index: i, start: p });
                Some(Vec::new())
            }
            InputEvent::MouseDragged { x, y, .. } => {
                let pr = self.press?;
                let p = CGPoint { x: f64::from(x) / k, y: f64::from(y) / k };
                if self.dragging.is_none() && (p.x - pr.start.x).hypot(p.y - pr.start.y) < Self::DRAG_SLOP {
                    return Some(Vec::new());
                }
                let ks = self.keystones.get(pr.index)?.clone();
                self.dragging = Some(ks.clone());
                self.drag_point = Some(p);
                self.last_click = None;
                Some(vec![KeystonePaletteEvent::Drag(Box::new(ks), x, y)])
            }
            InputEvent::MouseUp { x, y } => {
                self.press?;
                self.press = None;
                self.drag_point = None;
                let ks = self.dragging.take()?;
                Some(vec![KeystonePaletteEvent::Drop(Box::new(ks), x, y)])
            }
            InputEvent::MouseMoved { x, y } => {
                let p = CGPoint { x: f64::from(x) / k, y: f64::from(y) / k };
                self.hover_point = Some(p);
                self.hovered = self.row_at(p);
                None
            }
            InputEvent::Scroll { x, y, dy, .. } => {
                if !self.frame.contains(CGPoint { x: f64::from(x) / k, y: f64::from(y) / k }) {
                    return None;
                }
                let (max, extent) = (self.max_scroll(), self.list_rect().height);
                self.scroll_body.wheel(cx.gesture, 0.0, dy, k, max, extent, cx.now);
                self.scroll = self.scroll_body.position();
                Some(Vec::new())
            }
            InputEvent::KeyDown { key, modifiers } => {
                // Delete on the selected row while the pointer is over the card (the card has no keyboard focus of its own).
                // Matches Swift (`KeystonePalette`): Delete needs the pointer over the card, the shell tracks no panel focus.
                if (key == InputKey::Delete || key == InputKey::Backspace)
                    && modifiers == InputModifiers::NONE
                    && self.press.is_none()
                    && self.hover_point.is_some_and(|hp| self.frame.contains(hp))
                    && let Some(sel) = self.keystones.iter().find(|ks| Some(ks.id) == self.selected_id)
                {
                    return Some(vec![KeystonePaletteEvent::Delete(Box::new(sel.clone()))]);
                }
                if key != InputKey::Escape || self.press.is_none() {
                    return None;
                }
                let was = self.dragging.is_some();
                self.press = None;
                self.dragging = None;
                self.drag_point = None;
                Some(if was { vec![KeystonePaletteEvent::Cancel] } else { Vec::new() })
            }
        }
    }

    // MARK: Drawing

    pub fn draw(&self, c: &mut Canvas) {
        if !self.is_visible || self.frame.width <= 0.0 {
            return;
        }
        if !self.is_docked {
            self.draw_card(c);
        }
        self.draw_rows(c, 12.0);
    }

    fn draw_card(&self, c: &mut Canvas) {
        let t = &self.theme;
        let r = f64::from(radius::PANEL);
        c.shadow(self.frame, r, 10.0, 4.0, Color::new(0.0, 0.0, 0.0, 0.25), true);
        c.fill_rounded(self.frame, r, t.panel());
        c.stroke_rounded(self.frame.inset_by(0.5, 0.5), r, 1.0, t.separator());
        let header = CGRect::new(self.frame.min_x(), self.frame.min_y(), self.frame.width, Self::HEADER_HEIGHT);
        c.draw_text_in(
            &SQL10n::string("Motion"),
            header.inset_by(f64::from(spacing::MD), 0.0),
            f64::from(type_size::TITLE),
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );
        let g = 12.0;
        let (cl, op) = (self.close_rect(), self.options_rect());
        c.draw_icon(SQIcon::Close, CGPoint { x: cl.mid_x() - g / 2.0, y: cl.mid_y() - g / 2.0 }, g, t.label2(), None);
        c.draw_icon(
            SQIcon::Ellipsis,
            CGPoint { x: op.mid_x() - g / 2.0, y: op.mid_y() - g / 2.0 },
            g,
            t.label2(),
            None,
        );
        c.fill(CGRect::new(self.frame.min_x(), header.max_y() - 1.0, self.frame.width, 1.0), t.separator());
    }

    fn draw_rows(&self, c: &mut Canvas, g: f64) {
        let t = &self.theme;
        let pad = f64::from(spacing::SM);
        let xs = f64::from(spacing::XS);
        if self.keystones.is_empty() && self.is_docked {
            // The Mac panel's empty state.
            c.draw_empty_state(
                &SQL10n::string("No keystones yet"),
                &SQL10n::string("Save the keyframes of a clip as a keystone to reuse them."),
                self.frame,
                0.0,
                t,
            );
            return;
        }
        c.save_gstate();
        c.clip_to(self.list_rect());
        let list = self.list_rect();
        let font = f64::from(type_size::BODY);
        for (i, k) in self.keystones.iter().enumerate() {
            let rr = self.row_rect(i);
            if rr.max_y() < list.min_y() || rr.min_y() > list.max_y() {
                continue;
            }
            let pill = rr.inset_by(xs, 1.0);
            if Some(k.id) == self.selected_id {
                c.fill_rounded(pill, f64::from(radius::SMALL), t.accent_fill());
            } else if self.hovered == Some(i) {
                c.fill_rounded(pill, f64::from(radius::SMALL), t.fill_hover());
            }
            c.draw_icon(
                SQIcon::Diamond,
                CGPoint { x: rr.min_x() + 2.0 * pad, y: rr.mid_y() - g / 2.0 },
                g,
                t.label3(),
                None,
            );
            let name_x = rr.min_x() + 2.0 * pad + 14.0 + xs;
            let meta = KeystonesPanelModel::subtitle(k);
            // The detail keeps its full text; only a very narrow card cuts it, leaving the name 60 pt.
            let mw =
                (c.size_of(&meta, font, 0).width.ceil() + 1.0).min((rr.max_x() - 2.0 * pad - name_x - 60.0).max(0.0));
            let meta_x = rr.max_x() - 2.0 * pad - mw;
            let chip_w = if self.changed.contains(&k.id) { changed_chip_width(c, font, pad) } else { 0.0 };
            let name_w = c
                .size_of(&k.name, font, 0)
                .width
                .min((meta_x - name_x - pad - if chip_w > 0.0 { chip_w + xs } else { 0.0 }).max(0.0));
            c.draw_text_in(
                &k.name,
                CGRect::new(name_x, rr.min_y(), name_w, rr.height),
                font,
                t.label2(),
                TextAlign::Left,
                0.0,
                0,
            );
            if chip_w > 0.0 {
                draw_changed_chip(c, t, CGPoint::new(name_x + name_w + xs, rr.mid_y()), chip_w, font);
            }
            c.draw_text_in(
                &meta,
                CGRect::new(meta_x, rr.min_y(), mw, rr.height),
                font,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
        c.restore_gstate();
    }

    // MARK: Menus

    /// The header "...": Save Motion from Selected Clip, and Apply for the selected keystone (`showOptions`).
    pub fn option_items(selected: Option<&Keystone>, a: &KeystonePaletteActions) -> Vec<SQMenuItem> {
        let mut save = SQMenuItem::new("Save Motion from Selected Clip\u{2026}");
        save.action = Some(Rc::clone(&a.save_from_clip));
        let mut items = vec![save];
        if let Some(k) = selected {
            items.push(Self::row("Apply to Selected Clip", true, k, &a.apply));
        }
        items
    }

    /// The row menu (`contextItems(row:)`): Apply, Edit Curve, Use Keyframe Easing, Save, and Delete Keystone / Reset to
    /// Built-in last for a keystone the user saved or changed (`can_delete`).
    pub fn context_items(k: Option<&Keystone>, can_delete: bool, a: &KeystonePaletteActions) -> Vec<SQMenuItem> {
        let mut save = SQMenuItem::new("Save Motion from Selected Clip\u{2026}");
        save.action = Some(Rc::clone(&a.save_from_clip));
        let Some(k) = k else { return vec![save] };
        let mut items = vec![
            Self::row("Apply to Selected Clip", true, k, &a.apply),
            SQMenuItem::separator(),
            Self::row("Edit Curve\u{2026}", true, k, &a.edit_curve),
            Self::row("Use Keyframe Easing", k.easing.is_some(), k, &a.use_keyframe_easing),
            SQMenuItem::separator(),
            save,
        ];
        if can_delete {
            items.push(SQMenuItem::separator()); // destructive entry last
            items.push(Self::row(
                if k.is_built_in() { "Reset to Built-in" } else { "Delete Motion Preset" },
                true,
                k,
                &a.delete,
            ));
        }
        items
    }

    fn row(title: &str, enabled: bool, k: &Keystone, run: &Rc<dyn Fn(&Keystone)>) -> SQMenuItem {
        let mut i = SQMenuItem::new(title);
        i.is_enabled = enabled;
        let (run, k) = (Rc::clone(run), k.clone());
        i.action = Some(Rc::new(move || run(&k)));
        i
    }
}

/// What the card's menu items do; the host fills these in (the Mac panel's `onApply`, `onSaveFromClip`, `editCurve`,
/// the model's `setEasing` and `onDelete`).
pub struct KeystonePaletteActions {
    pub apply: Rc<dyn Fn(&Keystone)>,
    pub save_from_clip: Rc<dyn Fn()>,
    pub edit_curve: Rc<dyn Fn(&Keystone)>,
    pub use_keyframe_easing: Rc<dyn Fn(&Keystone)>,
    pub delete: Rc<dyn Fn(&Keystone)>,
}

// MARK: Transition layers (Swift: TimelinePanel+TransitionLayer.swift)

/// A transition layer's cut marker or end being dragged (`LayerDrag`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LayerDrag {
    pub id: Id,
    pub zone: TransitionLayerZone,
    pub start_x: f64,
    /// The dragged part's time at the press (the cut, or the end).
    pub cut: Time,
    pub began: bool,
    pub last_frames: i64,
}

/// What one drag step asks the host for (the panel wraps it into `TimelineAction::TransitionLayerCut` / `...Resize`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LayerStep {
    Cut { clip: Id, to: Time, continues: bool },
    Resize { clip: Id, edge: ClipEdge, to: Time, symmetric: bool, continues: bool },
}

impl LayerDrag {
    /// The press on a layer's center marker or end: the drag to keep, or `None` when the press is not on one (or the layer
    /// does not resolve). `clicks` is the click count; only a single press begins a drag.
    pub fn begin(p: CGPoint, clicks: i64, timeline: &Timeline, geometry: &TimelineGeometry) -> Option<LayerDrag> {
        use sq_core_effects::transition_layer::TimelineTransitionLayer;
        if clicks != 1 {
            return None;
        }
        let hit = TransitionLayerLayout::hit_test(p, timeline, geometry)?;
        let r = timeline.resolved_transition_layer(hit.id)?;
        let edge = match hit.zone {
            TransitionLayerZone::Head => r.span.start,
            TransitionLayerZone::Tail => r.span.end(),
            TransitionLayerZone::Cut => r.cut,
        };
        Some(LayerDrag { id: hit.id, zone: hit.zone, start_x: p.x, cut: edge, began: false, last_frames: 0 })
    }

    /// One step: the cut moves to the pointer's frame, or the end to it (the bridge measures the step against the
    /// session's current end, so a model clamp never accumulates). `snapping` is `toolState.snapping != snapInverted`,
    /// `alt` the Option key as the host reports it now. Returns the drag to keep and the step, if any.
    pub fn step(
        mut self,
        p: CGPoint,
        timeline: &Timeline,
        geometry: &TimelineGeometry,
        playhead: Time,
        snapping: bool,
        alt: bool,
    ) -> (LayerDrag, Option<LayerStep>) {
        if !self.began && (p.x - self.start_x).abs() < sq_timeline_ui::TimelineInteraction::DRAG_THRESHOLD {
            return (self, None);
        }
        let fd = timeline.format.frame_duration;
        let frames = (geometry.time(p.x) - geometry.time(self.start_x)).frame_index(fd);
        let mut target = self.cut + fd * frames;
        if snapping && let Some(track) = timeline.tracks.iter().find(|t| t.clips().iter().any(|c| c.id == self.id)) {
            let times = TransitionLayerLayout::snap_times(track.id, timeline, playhead);
            target = TransitionLayerLayout::snapped(target, &times, geometry);
        }
        let key = target.frame_index(fd);
        if self.began && key == self.last_frames {
            return (self, None);
        }
        let continues = self.began;
        self.began = true;
        self.last_frames = key;
        let step = match self.zone {
            TransitionLayerZone::Cut => LayerStep::Cut { clip: self.id, to: target, continues },
            // Alt held now resizes one side only.
            TransitionLayerZone::Head => {
                LayerStep::Resize { clip: self.id, edge: ClipEdge::Head, to: target, symmetric: !alt, continues }
            }
            TransitionLayerZone::Tail => {
                LayerStep::Resize { clip: self.id, edge: ClipEdge::Tail, to: target, symmetric: !alt, continues }
            }
        };
        (self, Some(step))
    }
}

/// What `draw_transition_layers` reads from the panel.
pub struct LayerDrawCx<'a> {
    pub timeline: &'a Timeline,
    pub geometry: &'a TimelineGeometry,
    pub selection: &'a BTreeSet<Id>,
    /// Tracks that hold a layer clip, so a frame does not scan every clip.
    pub transition_layer_tracks: &'a BTreeSet<Id>,
    pub rows: &'a [TrackRow],
}

/// `drawTransitionLayers`: the lead-in / lead-out ramp over each layer clip and its cut marker.
pub fn draw_transition_layers(cv: &mut Canvas, theme: &DrawTheme, cx: &LayerDrawCx, clip: CGRect) {
    let LayerDrawCx { timeline, geometry, selection, transition_layer_tracks, rows } = *cx;
    let fd = timeline.format.frame_duration;
    for row in rows.iter().filter(|r| r.kind == TrackKind::Video) {
        if row.max_y() <= clip.min_y() || row.y >= clip.max_y() || !transition_layer_tracks.contains(&row.track) {
            continue;
        }
        let Some(track) = timeline.track(row.track) else { continue };
        for c in track.clips().iter().filter(|c| c.is_transition_layer()) {
            let Some(r) = c.resolved_transition_layer(fd) else { continue };
            let (x0, x1) = (geometry.x(r.span.start), geometry.x(r.span.end()));
            if x1 < clip.min_x() || x0 > clip.max_x() {
                continue;
            }
            let selected = selection.contains(&c.id);
            let boxed = CGRect::new(x0, row.y + 1.0, x1 - x0, (row.height - 2.0).max(1.0));
            let cx = geometry.x(r.cut);
            // Lead-in rises to the cut, lead-out falls from it: the shape of the mix.
            cv.stroke_polyline(
                &[
                    CGPoint { x: boxed.min_x(), y: boxed.max_y() - 2.0 },
                    CGPoint { x: cx, y: boxed.min_y() + 2.0 },
                    CGPoint { x: boxed.max_x(), y: boxed.max_y() - 2.0 },
                ],
                1.0,
                // Draft `.tl-ramp`: the clip's own white at 75 %, full while selected.
                if selected { theme.on_clip() } else { theme.on_clip().with_alpha(0.75) },
            );
            if selected {
                // Draft `.tl-hdl`: a 6 pt square on each end with the clip ring around it.
                let mid = boxed.min_y() + boxed.height / 2.0;
                for x in [boxed.min_x() + 3.0, boxed.max_x() - 3.0] {
                    let h = CGRect::new(x - 3.0, mid - 3.0, 6.0, 6.0);
                    cv.fill(h, theme.on_clip());
                    cv.stroke_rounded(
                        h.inset_by(-0.5, -0.5),
                        f64::from(sq_uikit::tokens::radius::PANEL),
                        1.0,
                        theme.token(sq_uikit::tokens::color::content::CLIP_RING),
                    );
                }
            }
            draw_cut_marker(cv, theme, cx, boxed.min_y(), boxed.height, selected);
        }
    }
}

/// The center marker: a line through the row with a small downward triangle on top.
pub fn draw_cut_marker(cv: &mut Canvas, theme: &DrawTheme, x: f64, y: f64, height: f64, selected: bool) {
    // Draft `.tl-cut`: the clip's white, selected or not (the end handles carry the selection).
    let _ = selected;
    let color = theme.on_clip();
    cv.fill(CGRect::new(x - 1.0, y, 2.0, height), color);
    cv.fill_polygon(&[CGPoint { x: x - 5.0, y }, CGPoint { x: x + 5.0, y }, CGPoint { x, y: y + 6.0 }], color);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    fn palette() -> KeystonePalette {
        let mut k = KeystonePalette::new(DrawTheme::default());
        k.keystones = Keystone::built_ins().into_iter().take(4).collect();
        k.is_visible = true;
        k.layout(CGRect::new(0.0, 0.0, 1000.0, 400.0), 2.0);
        k
    }

    fn px(p: CGPoint) -> (f32, f32) {
        ((p.x * 2.0) as f32, (p.y * 2.0) as f32)
    }

    fn row_center(k: &KeystonePalette, i: usize) -> (f32, f32) {
        let r = k.row_rect(i);
        px(CGPoint { x: r.mid_x(), y: r.mid_y() })
    }

    fn down(k: &mut KeystonePalette, at: (f32, f32), mods: InputModifiers) -> Option<Vec<KeystonePaletteEvent>> {
        k.handle(&InputEvent::MouseDown { x: at.0, y: at.1, modifiers: mods }, &mut UiCx::new())
    }

    fn ev(k: &mut KeystonePalette, e: InputEvent) -> Option<Vec<KeystonePaletteEvent>> {
        k.handle(&e, &mut UiCx::new())
    }

    #[test]
    fn press_and_drag_reports_the_keystone_until_the_release() {
        let mut k = palette();
        let (x, y) = row_center(&k, 1);
        assert_eq!(down(&mut k, (x, y), InputModifiers::NONE), Some(Vec::new()));
        assert_eq!(k.selected_id, Some(k.keystones[1].id));
        // Inside the slop: nothing yet.
        assert_eq!(ev(&mut k, InputEvent::dragged(x + 2.0, y)), Some(Vec::new()));
        let ks = Box::new(k.keystones[1].clone());
        assert_eq!(
            ev(&mut k, InputEvent::dragged(x - 400.0, y + 300.0)),
            Some(vec![KeystonePaletteEvent::Drag(ks.clone(), x - 400.0, y + 300.0)])
        );
        assert_eq!(
            ev(&mut k, InputEvent::MouseUp { x: x - 400.0, y: y + 300.0 }),
            Some(vec![KeystonePaletteEvent::Drop(ks, x - 400.0, y + 300.0)])
        );
        assert!(!k.is_dragging());
        // No press: not the card's.
        assert_eq!(ev(&mut k, InputEvent::dragged(0.0, 0.0)), None);
    }

    #[test]
    fn drag_point_follows_the_drag_and_clears_on_release() {
        let mut k = palette();
        let (x, y) = row_center(&k, 1);
        down(&mut k, (x, y), InputModifiers::NONE);
        assert_eq!(k.drag_point(), None);
        ev(&mut k, InputEvent::dragged(x - 400.0, y + 300.0));
        assert_eq!(k.drag_point(), Some(CGPoint { x: f64::from(x - 400.0) / 2.0, y: f64::from(y + 300.0) / 2.0 }));
        ev(&mut k, InputEvent::MouseUp { x: x - 400.0, y: y + 300.0 });
        assert_eq!(k.drag_point(), None);
    }

    #[test]
    fn options_menu_and_delete_follow_the_pointer() {
        let mut k = palette();
        let (x, y) = row_center(&k, 2);
        down(&mut k, (x, y), InputModifiers::NONE);
        ev(&mut k, InputEvent::MouseUp { x, y });
        let o = k.options_rect();
        let (ox, oy) = px(CGPoint { x: o.mid_x(), y: o.mid_y() });
        assert!(matches!(
            down(&mut k, (ox, oy), InputModifiers::NONE).as_deref(),
            Some([KeystonePaletteEvent::Options(_)])
        ));
        // Delete goes to the selected row while the pointer is over the card.
        let del = InputEvent::KeyDown { key: InputKey::Delete, modifiers: InputModifiers::NONE };
        assert_eq!(ev(&mut k, del), None);
        ev(&mut k, InputEvent::MouseMoved { x, y });
        assert_eq!(ev(&mut k, del), Some(vec![KeystonePaletteEvent::Delete(Box::new(k.keystones[2].clone()))]));
    }

    #[test]
    fn double_click_applies_and_a_secondary_press_asks_for_a_menu() {
        let now = Rc::new(Cell::new(1.0));
        let mut k = palette();
        let c = Rc::clone(&now);
        k.clock = Box::new(move || c.get());
        let (x, y) = row_center(&k, 0);
        down(&mut k, (x, y), InputModifiers::NONE);
        ev(&mut k, InputEvent::MouseUp { x, y });
        now.set(1.2);
        assert_eq!(
            down(&mut k, (x, y), InputModifiers::NONE),
            Some(vec![KeystonePaletteEvent::Apply(Box::new(k.keystones[0].clone()))])
        );
        let menu = down(&mut k, (x, y), InputModifiers::SECONDARY);
        assert!(matches!(menu.as_deref(), Some([KeystonePaletteEvent::Menu(Some(m), _)]) if m.id == k.keystones[0].id));
        let (hx, hy) = px(CGPoint { x: k.frame().min_x() + 30.0, y: k.frame().min_y() + 5.0 });
        assert!(matches!(
            down(&mut k, (hx, hy), InputModifiers::SECONDARY).as_deref(),
            Some([KeystonePaletteEvent::Menu(None, _)])
        ));
    }

    #[test]
    fn escape_cancels_a_running_drag() {
        let mut k = palette();
        let (x, y) = row_center(&k, 1);
        down(&mut k, (x, y), InputModifiers::NONE);
        ev(&mut k, InputEvent::dragged(x - 400.0, y));
        let esc = InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE };
        assert_eq!(ev(&mut k, esc), Some(vec![KeystonePaletteEvent::Cancel]));
        assert!(!k.is_dragging());
        assert_eq!(ev(&mut k, esc), None);
    }

    #[test]
    fn close_hides_and_outside_clicks_pass_through() {
        let mut k = palette();
        assert_eq!(down(&mut k, (10.0, 10.0), InputModifiers::NONE), None);
        let c = k.close_rect();
        let at = px(CGPoint { x: c.mid_x(), y: c.mid_y() });
        assert_eq!(down(&mut k, at, InputModifiers::NONE), Some(Vec::new()));
        assert!(!k.is_visible);
        assert_eq!(down(&mut k, at, InputModifiers::NONE), None);
    }

    #[test]
    fn docked_list_fills_the_card_and_has_no_close_button() {
        let mut p = KeystonePalette::new(DrawTheme::default());
        p.keystones = Keystone::built_ins();
        p.layout_docked(Some(CGRect::new(10.0, 20.0, 300.0, 400.0)), 1.0);
        assert!(p.is_visible && p.is_docked());
        assert_eq!(p.frame(), CGRect::new(10.0, 20.0, 300.0, 400.0));
        assert_eq!(p.row_at(CGPoint { x: 100.0, y: 20.0 + f64::from(spacing::XS) + 5.0 }), Some(0));
        let c = p.close_rect();
        let at = (c.mid_x() as f32, c.mid_y() as f32);
        ev(&mut p, InputEvent::MouseDown { x: at.0, y: at.1, modifiers: InputModifiers::NONE });
        ev(&mut p, InputEvent::MouseUp { x: at.0, y: at.1 });
        assert!(p.is_visible);
        p.layout_docked(None, 1.0);
        assert!(!p.is_visible);
    }

    #[test]
    fn card_height_and_rows_follow_the_keystone_count() {
        let k = palette();
        assert_eq!(k.frame().height, 4.0 * 24.0 + 28.0 + 4.0);
        assert_eq!(k.frame().max_x(), 1000.0 - 8.0);
        assert_eq!(k.frame().width, 280.0);
        assert_eq!(k.row_at(CGPoint { x: k.frame().min_x() + 5.0, y: k.frame().min_y() + 28.0 + 25.0 }), Some(1));
        assert_eq!(k.row_at(CGPoint { x: k.frame().min_x() + 5.0, y: k.frame().min_y() + 5.0 }), None);
        assert!(k.help_at(CGPoint { x: k.frame().min_x() + 5.0, y: k.frame().min_y() + 31.0 }).is_some());
    }

    #[test]
    fn the_wheel_scrolls_a_long_list_and_stays_in_range() {
        let mut k = KeystonePalette::new(DrawTheme::default());
        k.keystones = Keystone::built_ins();
        k.is_visible = true;
        k.layout(CGRect::new(0.0, 0.0, 600.0, 200.0), 1.0);
        let f = k.frame();
        let wheel = InputEvent::Scroll {
            x: f.mid_x() as f32,
            y: f.mid_y() as f32,
            dx: 0.0,
            dy: -60.0,
            modifiers: InputModifiers::NONE,
        };
        assert_eq!(ev(&mut k, wheel), Some(Vec::new()));
        k.tick(10.0);
        assert!(k.scroll() >= 0.0 && k.scroll() <= k.max_scroll());
    }

    #[test]
    fn menus_follow_the_mac_panel() {
        let log = Rc::new(RefCell::new(Vec::<String>::new()));
        let mk = |tag: &'static str| {
            let l = Rc::clone(&log);
            Rc::new(move |k: &Keystone| l.borrow_mut().push(format!("{tag} {}", k.name))) as Rc<dyn Fn(&Keystone)>
        };
        let l = Rc::clone(&log);
        let a = KeystonePaletteActions {
            apply: mk("apply"),
            save_from_clip: Rc::new(move || l.borrow_mut().push("save".to_string())),
            edit_curve: mk("curve"),
            use_keyframe_easing: mk("keys"),
            delete: mk("delete"),
        };
        let k = Keystone::built_ins().remove(0);
        let none = KeystonePalette::context_items(None, false, &a);
        assert_eq!(
            none.iter().map(|i| i.title.clone()).collect::<Vec<_>>(),
            ["Save Motion from Selected Clip\u{2026}"]
        );
        let items = KeystonePalette::context_items(Some(&k), true, &a);
        let titles: Vec<_> = items.iter().filter(|i| !i.title.is_empty()).map(|i| i.title.clone()).collect();
        assert_eq!(
            titles,
            [
                "Apply to Selected Clip",
                "Edit Curve\u{2026}",
                "Use Keyframe Easing",
                "Save Motion from Selected Clip\u{2026}",
                "Reset to Built-in"
            ]
        );
        for i in items.iter().filter(|i| i.is_enabled) {
            if let Some(f) = &i.action {
                f();
            }
        }
        // No curve of its own: the easing row is dimmed and stays silent.
        assert_eq!(
            *log.borrow(),
            [
                format!("apply {}", k.name),
                format!("curve {}", k.name),
                "save".to_string(),
                format!("delete {}", k.name)
            ]
        );
        let opts = KeystonePalette::option_items(Some(&k), &a);
        assert_eq!(
            opts.iter().map(|i| i.title.clone()).collect::<Vec<_>>(),
            ["Save Motion from Selected Clip\u{2026}", "Apply to Selected Clip"]
        );
    }

    #[test]
    fn draws_the_card_and_its_rows() {
        let mut k = palette();
        k.changed.insert(k.keystones[0].id);
        let mut c = Canvas::with_size(2000.0, 800.0, None, 2.0);
        k.draw(&mut c);
        assert!(c.list.quads().len() > 10);
    }

    // Transition layers.

    const FD: Time = Time::new(1, 24);

    fn layer_timeline() -> (Timeline, Id, TimelineGeometry) {
        use sq_core_effects::transition_layer::{TransitionKindLayer, TransitionLayerExt};
        use sq_core_model::{Clip, GeneratorRef, SequenceFormat, Track, TransitionKind, TransitionLayer};
        use sq_core_time::TimeRange;
        let kind = TransitionKind::layer_kinds()[0];
        let layer = TransitionLayer::new(kind, FD * 24);
        let mut clip = Clip::new(
            Id::from_u128(50),
            "Transition Layer",
            Id::from_u128(51),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, FD * 48),
            Time::ZERO,
        );
        clip.generator = Some(GeneratorRef {
            kind: TransitionLayer::GENERATOR_KIND.to_string(),
            payload: layer.payload(),
            payload_version: TransitionLayer::PAYLOAD_VERSION,
        });
        let mut track = Track::new(Id::from_u128(60), TrackKind::Video);
        track.set_clips(vec![clip]);
        let tl = Timeline::new(Id::from_u128(1), "t", SequenceFormat::new(FD), vec![track]);
        (tl, Id::from_u128(50), TimelineGeometry::with_points_per_frame(FD, 4.0))
    }

    #[test]
    fn a_press_on_the_cut_marker_begins_a_drag_and_steps_move_the_cut_by_frames() {
        let (tl, id, g) = layer_timeline();
        let rows = g.rows(&tl);
        let cx = g.x(FD * 24);
        let p = CGPoint { x: cx, y: rows[0].y + rows[0].height / 2.0 };
        assert!(LayerDrag::begin(p, 2, &tl, &g).is_none());
        let Some(d) = LayerDrag::begin(p, 1, &tl, &g) else { panic!("no drag") };
        assert_eq!((d.id, d.zone, d.cut), (id, TransitionLayerZone::Cut, FD * 24));
        // Inside the threshold: nothing.
        let (d, step) = d.step(CGPoint { x: cx + 1.0, y: p.y }, &tl, &g, Time::ZERO, false, false);
        assert!(step.is_none() && !d.began);
        // Four frames to the right.
        let (d, step) = d.step(CGPoint { x: cx + 16.0, y: p.y }, &tl, &g, Time::ZERO, false, false);
        assert_eq!(step, Some(LayerStep::Cut { clip: id, to: FD * 28, continues: false }));
        // Same frame again: no second step; a further frame continues the undo step.
        let (d, step) = d.step(CGPoint { x: cx + 17.0, y: p.y }, &tl, &g, Time::ZERO, false, false);
        assert!(step.is_none());
        let (_, step) = d.step(CGPoint { x: cx + 20.0, y: p.y }, &tl, &g, Time::ZERO, false, false);
        assert_eq!(step, Some(LayerStep::Cut { clip: id, to: FD * 29, continues: true }));
    }

    #[test]
    fn an_end_drag_resizes_symmetrically_unless_alt_is_held() {
        let (tl, id, g) = layer_timeline();
        let rows = g.rows(&tl);
        let p = CGPoint { x: g.x(FD * 1), y: rows[0].y + rows[0].height / 2.0 };
        let Some(d) = LayerDrag::begin(p, 1, &tl, &g) else { panic!("no drag") };
        assert_eq!(d.zone, TransitionLayerZone::Head);
        let (_, step) = d.step(CGPoint { x: p.x + 8.0, y: p.y }, &tl, &g, Time::ZERO, false, false);
        assert_eq!(
            step,
            Some(LayerStep::Resize { clip: id, edge: ClipEdge::Head, to: FD * 2, symmetric: true, continues: false })
        );
        let (_, step) = d.step(CGPoint { x: p.x + 8.0, y: p.y }, &tl, &g, Time::ZERO, false, true);
        assert_eq!(
            step,
            Some(LayerStep::Resize { clip: id, edge: ClipEdge::Head, to: FD * 2, symmetric: false, continues: false })
        );
    }

    #[test]
    fn layers_draw_a_ramp_and_a_marker_and_selected_ones_the_end_bars() {
        let (tl, id, g) = layer_timeline();
        let rows = g.rows(&tl);
        let tracks: BTreeSet<Id> = tl.tracks.iter().map(|t| t.id).collect();
        let view = CGRect::new(0.0, 0.0, 800.0, 400.0);
        let count = |sel: &BTreeSet<Id>| {
            let mut c = Canvas::with_size(800.0, 400.0, None, 1.0);
            draw_transition_layers(
                &mut c,
                &DrawTheme::default(),
                &LayerDrawCx {
                    timeline: &tl,
                    geometry: &g,
                    selection: sel,
                    transition_layer_tracks: &tracks,
                    rows: &rows,
                },
                view,
            );
            c.list.quads().len()
        };
        let plain = count(&BTreeSet::new());
        let selected = count(&BTreeSet::from([id]));
        assert!(plain > 0 && selected >= plain + 2, "two end handles (fill + ring each) on top of the plain layer");
        // A track that holds no layer is skipped.
        let mut c = Canvas::with_size(800.0, 400.0, None, 1.0);
        draw_transition_layers(
            &mut c,
            &DrawTheme::default(),
            &LayerDrawCx {
                timeline: &tl,
                geometry: &g,
                selection: &BTreeSet::new(),
                transition_layer_tracks: &BTreeSet::new(),
                rows: &rows,
            },
            view,
        );
        assert!(c.list.quads().is_empty());
    }
}
