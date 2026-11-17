// Swift: SQAppShell/GraphicsHost.swift
//! The Graphics panel as an app host: layers and property rows of the selected Graphic. The panel keeps a stand-in
//! session between calls and every call runs inside [`GraphicsPanelDraw::with_session`] with the session of the
//! [`HostCx`]. Menus, color pickers and the template dialogs the panel asks for wait in [`GraphicsHost::take_requests`].

use crate::analysis_links::eyedropper::Eyedropper;
use crate::color_popover::{ColorPopover, PickerAids, PopoverEvent};
use sq_app_shell::{AppEvent, AppHost, HostCx};
use sq_core_time::SequentialIds;
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent, InputModifiers};
use sq_editor_session::{Change, EditorSession, SessionDeps};
use sq_inspector_ui::graphics::editor::GraphicsEditor;
use sq_inspector_ui::graphics::panel_draw::{ColorTarget, GraphicsPanelDraw, PanelRequest};
use sq_inspector_ui::text::block_draw::Layer;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqcolor_value::SQColorValue;

/// The Graphics panel in a dock slot.
pub struct GraphicsHost {
    panel: GraphicsPanelDraw,
    frame: CGRect,
    /// A press started inside the panel: drags and the release follow it outside the frame too.
    pressed: bool,
    /// The modifiers held at the last press or drag: the release of a drag has no modifiers of its own, so it takes these
    /// (Swift `GraphicsHost` reads the live keys on drag and release; Alt copies a dragged layer).
    held: InputModifiers,
    /// The SQ color picker the panel asked for, over the dock.
    popover: Option<ColorPopover<ColorTarget>>,
    /// The recent colors and the monitor pipette the picker offers.
    picker_aids: PickerAids,
    /// The text eyedropper: the dropper shared with the monitor host and the layer it was armed for.
    eyedropper: Option<(Eyedropper, Option<Layer>)>,
    /// The area popovers may use (the window, in points); the root sets it.
    window: CGRect,
    /// Requests the root answers (everything but the pickers).
    pending: Vec<PanelRequest>,
}

impl GraphicsHost {
    /// A host over a fresh panel.
    /// Remembers the Link Scale switch and the layer list height under their `sq.graphics.*` keys.
    pub fn with_defaults(mut self, defaults: Box<dyn sq_uikit::appearance_palette::UiDefaults>) -> GraphicsHost {
        self.panel.set_defaults(defaults);
        self
    }

    pub fn new() -> GraphicsHost {
        let mut ids = SequentialIds::default();
        let project = EditorSession::make_untitled(&mut ids);
        let deps = SessionDeps::headless(std::env::temp_dir().join("sq-graphics-host"));
        let panel = GraphicsPanelDraw::new(
            GraphicsEditor::new(Box::new(SequentialIds::default())),
            EditorSession::new(project, deps),
        );
        GraphicsHost {
            panel,
            frame: CGRect::default(),
            pressed: false,
            held: InputModifiers::NONE,
            popover: None,
            picker_aids: PickerAids::default(),
            eyedropper: None,
            window: CGRect::default(),
            pending: Vec::new(),
        }
    }

    /// The panel (tests, and the root when it answers requests).
    pub fn panel(&mut self) -> &mut GraphicsPanelDraw {
        &mut self.panel
    }

    /// Turns the text eyedropper on: it samples the Program monitor picture through `eyedropper`.
    pub fn with_eyedropper(mut self, eyedropper: Eyedropper) -> GraphicsHost {
        self.eyedropper = Some((eyedropper, None));
        self.panel.can_sample_screen_color = true;
        self
    }

    /// Tells the host how big the window is, so the picker stays inside it.
    pub fn set_window(&mut self, window: CGRect) {
        self.window = window;
    }

    /// Applies what the panel's menus queued and opens the pickers it asked for; the root calls it on every pump,
    /// after a menu row ran.
    pub fn pump(&mut self, cx: &mut HostCx) {
        self.panel.with_session(cx.session, |p| p.run_commands(cx.ui));
        self.finish_eyedropper(cx);
        for r in self.panel.take_requests() {
            self.answer(r, cx);
        }
    }

    /// Commits the fields typed in the form, the text box and a layer rename (a menu chord, a press in another panel).
    pub(crate) fn end_text_edits(&mut self, cx: &mut HostCx) {
        self.panel.with_session(cx.session, |p| p.end_text_edits(cx.ui));
        self.pump(cx);
    }

    /// Connects the app's Look store: the text block lists its Looks, and Save as New Look, Rename and Delete reach the
    /// root as `PanelRequest::StylesChanged`, which writes them to the same store the Inspector and Captions use.
    pub fn with_looks(mut self, looks: std::sync::Arc<sq_editor_session::LookStore>) -> GraphicsHost {
        self.panel.set_text_model(move || {
            sq_inspector_ui::text::inspector_model::TextInspectorModel::new(
                sq_text::text_style::TextStyle::default(),
                sq_core_model::anchored_animation::AnimationSet::new(None, None),
                None,
                Box::new(sq_inspector_ui::text::inspector_model::TextBoxDefaults::installed_families),
                sq_inspector_ui::text::style_library::TextStyleStore::load(&looks),
                // Random: a Look saved now must not take the id of one saved in an earlier session.
                Box::new(sq_core_time::RandomIds),
            )
        });
        self
    }

    /// Gives the picker popover its recent colors and monitor pipette.
    pub fn with_picker_aids(mut self, aids: PickerAids) -> GraphicsHost {
        self.picker_aids = aids;
        self
    }

    /// A pick the pipette of the open picker finished reaches the color it edits.
    fn poll_popover_pick(&mut self, cx: &mut HostCx) {
        if let Some(PopoverEvent::Changed(c)) = self.popover.as_mut().and_then(ColorPopover::poll_pick) {
            self.report_color(Some(c), cx);
        }
    }

    /// Opens the picker or arms the eyedropper; every other request waits for the root.
    fn answer(&mut self, request: PanelRequest, cx: &mut HostCx) {
        match request {
            PanelRequest::PickColor { current, anchor, target } => {
                self.close_popover(cx);
                let at = CGRect::new(anchor.x + self.frame.x, anchor.y + self.frame.y, anchor.width, anchor.height);
                self.popover = Some(ColorPopover::open_with(target, current, at, self.window, &self.picker_aids));
            }
            PanelRequest::SampleColor(layer) => match &mut self.eyedropper {
                Some((dropper, armed)) => {
                    dropper.arm();
                    *armed = Some(layer);
                    cx.events.push(AppEvent::Status("Click a color in the Program monitor picture.".to_string()));
                }
                None => cx.events.push(AppEvent::Status("The eyedropper is not available here.".to_string())),
            },
            other => self.pending.push(other),
        }
    }

    /// Hands a finished monitor pick to the layer it was armed for.
    fn finish_eyedropper(&mut self, cx: &mut HostCx) {
        let Some((dropper, armed)) = &mut self.eyedropper else { return };
        // Another host's pick is not ours: only an armed text pick takes the answer.
        if armed.is_none() || !dropper.has_answer() {
            return;
        }
        let (Some(answer), Some(layer)) = (dropper.take_answer(), armed.take()) else { return };
        let picked = answer.map(|(r, g, b)| SQColorValue::from_rgb(r, g, b, 1.0));
        if picked.is_none() {
            cx.events.push(AppEvent::Status("No color picked.".to_string()));
        }
        self.panel.with_session(cx.session, |p| p.color_sampled(layer, picked, cx.ui));
    }

    /// True while the color picker is open.
    pub fn has_popover(&self) -> bool {
        self.popover.is_some()
    }

    fn report_color(&mut self, color: Option<sq_core_model::EffectColor>, cx: &mut HostCx) {
        let Some(pop) = &self.popover else { return };
        let target = pop.target.clone();
        self.panel.with_session(cx.session, |p| p.color_changed(target, color, cx.ui));
    }

    fn close_popover(&mut self, cx: &mut HostCx) {
        self.report_color(None, cx);
        self.popover = None;
    }

    /// Gives the open picker an event first; true when it took it.
    pub fn handle_popover(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let Some(pop) = &mut self.popover else { return false };
        match pop.handle(e, cx.scale, cx.ui) {
            PopoverEvent::Ignored => false,
            PopoverEvent::Taken => true,
            PopoverEvent::Changed(c) => {
                self.report_color(Some(c), cx);
                true
            }
            PopoverEvent::Closed => {
                self.close_popover(cx);
                true
            }
            PopoverEvent::Dismissed => {
                self.close_popover(cx);
                false
            }
        }
    }

    /// Draws the open picker over everything else.
    pub fn draw_popover(&self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        if let Some(pop) = &self.popover {
            pop.draw(c, t, cx.ui);
        }
    }

    /// The panel's frame (points), where its menu anchors start.
    pub fn frame(&self) -> CGRect {
        self.frame
    }

    /// Effects released at window point `at` (points): on a layer row they go to that layer, elsewhere to the one selected
    /// layer (Swift `GraphicsHost.dropEffects`). False when the point is outside the card or no Graphic is open.
    pub fn drop_effects(&mut self, kinds: &[String], at: CGPoint, cx: &mut HostCx) -> bool {
        if self.frame.width <= 0.0 || !self.frame.contains(at) {
            return false;
        }
        let p = CGPoint::new(at.x - self.frame.x, at.y - self.frame.y);
        self.panel.drop_effects(kinds, Some(p), cx.ui)
    }

    /// An Effects drag is at window point `at` (`None`: it ended or left): the layer row under it takes the accent tint.
    pub fn effect_drag_over(&mut self, at: Option<CGPoint>) {
        let p = at.filter(|p| self.frame.width > 0.0 && self.frame.contains(*p));
        self.panel.effect_drag_over(p.map(|p| CGPoint::new(p.x - self.frame.x, p.y - self.frame.y)));
    }

    /// What the panel asked the root for since the last pump (menus, template dialogs); the pickers are answered here.
    pub fn take_requests(&mut self) -> Vec<PanelRequest> {
        std::mem::take(&mut self.pending)
    }

    /// Queues `request` as if the panel had asked for it.
    #[cfg(test)]
    pub(crate) fn defer(&mut self, request: PanelRequest) {
        self.pending.push(request);
    }
}

fn local(frame: CGRect, x: f32, y: f32, scale: f32) -> CGPoint {
    CGPoint::new(f64::from(x / scale) - frame.x, f64::from(y / scale) - frame.y)
}

fn contains(frame: CGRect, p: CGPoint) -> bool {
    p.x >= 0.0 && p.y >= 0.0 && p.x < frame.width && p.y < frame.height
}

impl Default for GraphicsHost {
    fn default() -> Self {
        GraphicsHost::new()
    }
}

impl AppHost for GraphicsHost {
    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.frame = frame;
        self.panel.set_size(CGSize { width: frame.width, height: frame.height });
        self.panel.with_session(cx.session, |p| p.sync(cx.ui));
        self.poll_popover_pick(cx);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.panel.set_theme(*t);
        c.save_gstate();
        c.translate_by(self.frame.x, self.frame.y);
        c.clip_to(CGRect { x: 0.0, y: 0.0, width: self.frame.width, height: self.frame.height });
        self.panel.with_session(cx.session, |p| p.draw(c, cx.ui));
        c.restore_gstate();
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let (scale, frame) = (cx.scale, self.frame);
        let ui = &mut *cx.ui;
        let taken = match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = local(frame, x, y, scale);
                self.pressed = contains(frame, p);
                self.held = modifiers;
                self.pressed && {
                    self.panel.with_session(cx.session, |g| g.mouse_down(p, modifiers, None, ui));
                    true
                }
            }
            InputEvent::MouseDragged { x, y, modifiers } if self.pressed => {
                let p = local(frame, x, y, scale);
                self.held = modifiers;
                self.panel.with_session(cx.session, |g| g.mouse_dragged(p, modifiers, ui));
                true
            }
            InputEvent::MouseUp { x, y } if self.pressed => {
                self.pressed = false;
                let p = local(frame, x, y, scale);
                let held = self.held;
                self.panel.with_session(cx.session, |g| g.mouse_up(p, held, ui));
                true
            }
            InputEvent::MouseMoved { x, y } => {
                let p = local(frame, x, y, scale);
                self.panel.mouse_moved(Some(p).filter(|p| contains(frame, *p)));
                false
            }
            InputEvent::Scroll { x, y, dy, modifiers, .. } => {
                let p = local(frame, x, y, scale);
                contains(frame, p) && {
                    self.panel.with_session(cx.session, |g| g.scroll(p, f64::from(dy), false, modifiers, ui));
                    true
                }
            }
            InputEvent::KeyDown { key, modifiers } => {
                self.panel.with_session(cx.session, |g| g.key(key, modifiers, ui))
            }
            _ => false,
        };
        if taken {
            self.panel.with_session(cx.session, |p| p.sync(cx.ui));
        }
        taken
    }

    fn a11y(&self, _a: &mut A11y) {}

    fn on_change(&mut self, _changes: Change, cx: &mut HostCx) {
        self.panel.with_session(cx.session, |p| p.sync(cx.ui));
    }
}

#[cfg(test)]
mod tests;
