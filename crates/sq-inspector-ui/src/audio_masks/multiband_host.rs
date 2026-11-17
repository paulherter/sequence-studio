// Swift: SQAppShell/Inspector/InspectorHost.swift (openMultiband, closeMultiband, handleMultiband, drawPopover)
//! Hosts the Multiband Compressor setup above the window: where it sits, which events it takes, and how it is drawn.
//! The Swift host kept this state next to the color picker; here it is one value the app shell owns.
//!
//! Everything outside the panel goes on to the other panels (the setup stays open while the user plays or scrubs).
//! Coordinates in the events are pixels; `scale` turns them into points.

use sq_core_time::Id;
use sq_draw::{Canvas, InputEvent, InputModifiers, UiCx};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};

use super::draw_support::MenuRequest;
use super::multiband_editor_draw::{MultibandEditorDraw, MultibandEditorRequest};
use crate::ec::effect_controls_model::core::EffectControlsModel;

/// One open setup panel with its place in the window.
pub struct MultibandHost {
    pub draw: MultibandEditorDraw,
    frame: CGRect,
    /// The panel has the keyboard (a press inside it, until a press outside).
    active: bool,
    dragging: bool,
}

impl MultibandHost {
    /// Opens the setup for `effect`, centered in `window`. Starts the live meters.
    pub fn open(effect: Id, model: &EffectControlsModel, window: CGSize, spectrum_at_input: bool) -> MultibandHost {
        let mut draw = MultibandEditorDraw::new(effect, model);
        draw.spectrum_at_input = spectrum_at_input;
        let s = draw.size();
        let frame = CGRect::new(
            ((window.width - s.width) / 2.0).round(),
            (((window.height - s.height) / 2.0).round()).max(6.0),
            s.width,
            s.height,
        );
        draw.start_meters();
        MultibandHost { draw, frame, active: true, dragging: false }
    }

    /// The panel's place in the window (points).
    pub fn frame(&self) -> CGRect {
        self.frame
    }

    /// The effect this panel edits.
    pub fn effect(&self) -> Id {
        self.draw.effect
    }

    /// Whether keys go to the panel.
    pub fn is_active(&self) -> bool {
        self.active
    }

    /// Asking to open the same effect again only gives the panel the keyboard back.
    pub fn reactivate(&mut self) {
        self.active = true;
    }

    /// Stops the meters and drops focus; call before the host lets go of the panel.
    pub fn close(&mut self, model: &mut EffectControlsModel, cx: &mut UiCx) {
        self.draw.resign_focus(model, cx);
        self.draw.stop_meters();
        self.active = false;
        self.dragging = false;
    }

    /// True when the draw asked to be closed (button, Esc, effect gone). The caller then calls [`Self::close`].
    pub fn take_close_request(&mut self) -> bool {
        let before = self.draw.requests.len();
        self.draw.requests.retain(|r| *r != MultibandEditorRequest::Close);
        self.draw.requests.len() != before
    }

    /// The "Spectrum at Input" value to store when it changed since the last call.
    pub fn take_spectrum_at_input(&mut self) -> Option<bool> {
        let mut last = None;
        self.draw.requests.retain(|r| {
            if let MultibandEditorRequest::SpectrumAtInput(v) = r {
                last = Some(*v);
                false
            } else {
                true
            }
        });
        last
    }

    /// Menus the panel asked for, moved into window points.
    pub fn take_menus(&mut self) -> Vec<MenuRequest> {
        let (dx, dy) = (self.frame.min_x(), self.frame.min_y());
        std::mem::take(&mut self.draw.menus)
            .into_iter()
            .map(|m| MenuRequest {
                anchor: CGRect::new(m.anchor.min_x() + dx, m.anchor.min_y() + dy, m.anchor.width, m.anchor.height),
                ..m
            })
            .collect()
    }

    /// A menu row was chosen: runs the panel's commands.
    pub fn menu_closed(&mut self, model: &mut EffectControlsModel) {
        self.draw.run_menu_commands(model);
    }

    /// Per frame: faders, meters and spectrum. True when something to draw changed.
    pub fn tick(&mut self, model: &mut EffectControlsModel, now: f64) -> bool {
        self.draw.tick(model, now)
    }

    /// Draws the panel at its place (call after the other panels).
    pub fn draw(&self, c: &mut Canvas, cx: &mut UiCx) {
        c.save_gstate();
        c.translate_by(self.frame.min_x(), self.frame.min_y());
        self.draw.draw(c, cx);
        c.restore_gstate();
    }

    /// Routes one event. True = taken. `settle` applies the model's edits back to the clip (the host's `set_clip`) after each
    /// call that can edit; the panel syncs afterwards.
    pub fn handle(
        &mut self,
        model: &mut EffectControlsModel,
        cx: &mut UiCx,
        e: &InputEvent,
        scale: f32,
        settle: &mut dyn FnMut(&mut EffectControlsModel),
    ) -> bool {
        let local = |x: f32, y: f32| {
            CGPoint::new(f64::from(x / scale) - self.frame.min_x(), f64::from(y / scale) - self.frame.min_y())
        };
        let inside = |q: CGPoint| CGRect::new(0.0, 0.0, self.frame.width, self.frame.height).contains(q);
        match *e {
            InputEvent::MouseDown { x, y, .. } => {
                let q = local(x, y);
                if !inside(q) {
                    self.active = false;
                    self.draw.resign_focus(model, cx);
                    settle(model);
                    self.draw.sync(model);
                    return false;
                }
                self.active = true;
                self.dragging = true;
                self.draw.mouse_down(model, cx, q, None);
            }
            InputEvent::MouseDragged { x, y, .. } => {
                if !self.dragging {
                    return false;
                }
                self.draw.mouse_dragged(model, cx, local(x, y), InputModifiers::default());
            }
            InputEvent::MouseUp { x, y } => {
                if !self.dragging {
                    return false;
                }
                self.dragging = false;
                self.draw.mouse_up(model, cx, local(x, y));
            }
            InputEvent::MouseMoved { x, y } => {
                let q = local(x, y);
                self.draw.mouse_moved(inside(q).then_some(q));
                return inside(q);
            }
            InputEvent::Scroll { x, y, dy, modifiers, .. } => {
                let q = local(x, y);
                if !inside(q) {
                    return false;
                }
                self.draw.scroll(model, cx, q, f64::from(dy / scale), true, modifiers);
            }
            InputEvent::KeyDown { key, modifiers } => {
                if !self.active || !self.draw.key(model, cx, key, modifiers) {
                    return false;
                }
            }
        }
        settle(model);
        self.draw.sync(model);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_masks::multiband_editor_draw::Control;
    use crate::ec::effect_controls_model::core::EffectControlsEvent;
    use sq_core_effects::effects_editing::ClipEffectsEditingExt;
    use sq_core_model::{Clip, ClipEffect, TrackKind};
    use sq_core_time::{SequentialIds, Time, TimeRange};
    use sq_draw::InputKey;

    fn rig() -> (EffectControlsModel, Id, UiCx) {
        let mut clip = Clip::new(
            Id::from_u128(1000),
            "Voice",
            Id::from_u128(1001),
            TrackKind::Audio,
            TimeRange::new(Time::ZERO, Time::new(10, 1)),
            Time::ZERO,
        );
        let mut ids = SequentialIds::default();
        let Some(id) = clip.add_effect(ClipEffect::AUDIO_MULTIBAND_KIND, None, &mut ids) else {
            panic!("no multiband effect")
        };
        let mut m = EffectControlsModel::new(Box::new(SequentialIds::default()));
        m.set_clip(Some(clip), None, Vec::new(), None);
        let mut cx = UiCx::new();
        cx.now = 100.0;
        (m, id, cx)
    }

    fn settle(m: &mut EffectControlsModel) {
        for ev in m.take_events() {
            if let EffectControlsEvent::Edit { clip, .. } = ev {
                m.set_clip(Some(clip), None, Vec::new(), None);
            }
        }
    }

    fn down_up(h: &mut MultibandHost, m: &mut EffectControlsModel, cx: &mut UiCx, p: CGPoint) -> bool {
        let (x, y) = (p.x as f32, p.y as f32);
        let a =
            h.handle(m, cx, &InputEvent::MouseDown { x, y, modifiers: InputModifiers::default() }, 1.0, &mut settle);
        let b = h.handle(m, cx, &InputEvent::MouseUp { x, y }, 1.0, &mut settle);
        a && b
    }

    #[test]
    fn opens_centered_and_inside_the_window() {
        let (m, id, _) = rig();
        let h = MultibandHost::open(id, &m, CGSize::new(1280.0, 800.0), true);
        let f = h.frame();
        assert_eq!(f.min_x(), ((1280.0 - f.width) / 2.0).round());
        assert!(f.min_y() >= 6.0 && f.max_y() <= 800.0);
        assert!(h.draw.spectrum_at_input && h.is_active() && h.effect() == id);
        // A window shorter than the panel pins it to the top margin.
        let small = MultibandHost::open(id, &m, CGSize::new(1280.0, 100.0), false);
        assert_eq!(small.frame().min_y(), 6.0);
    }

    #[test]
    fn presses_inside_edit_and_outside_pass_through() {
        let (mut m, id, mut cx) = rig();
        let mut h = MultibandHost::open(id, &m, CGSize::new(1280.0, 800.0), false);
        let Some(r) = h.draw.frame_of(&Control::Solo(1)) else { panic!("no solo") };
        let at = CGPoint::new(r.mid_x() + h.frame().min_x(), r.mid_y() + h.frame().min_y());
        assert!(down_up(&mut h, &mut m, &mut cx, at));
        assert!(m.multiband_solo(id, 1));
        // Outside: not taken, keys no longer go to the panel, a drag is ignored.
        assert!(!down_up(&mut h, &mut m, &mut cx, CGPoint::new(1.0, 1.0)));
        assert!(!h.is_active());
        let key = InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::default() };
        assert!(!h.handle(&mut m, &mut cx, &key, 1.0, &mut settle));
        assert!(!h.handle(&mut m, &mut cx, &InputEvent::dragged(5.0, 5.0), 1.0, &mut settle));
        h.reactivate();
        assert!(h.handle(&mut m, &mut cx, &key, 1.0, &mut settle));
        assert!(h.take_close_request());
        assert!(!h.take_close_request());
    }

    #[test]
    fn hover_counts_as_taken_only_inside_and_scale_is_applied() {
        let (mut m, id, mut cx) = rig();
        let mut h = MultibandHost::open(id, &m, CGSize::new(1280.0, 800.0), false);
        let f = h.frame();
        let inside =
            InputEvent::MouseMoved { x: ((f.min_x() + 5.0) * 2.0) as f32, y: ((f.min_y() + 5.0) * 2.0) as f32 };
        assert!(h.handle(&mut m, &mut cx, &inside, 2.0, &mut settle));
        assert!(!h.handle(&mut m, &mut cx, &InputEvent::MouseMoved { x: 2.0, y: 2.0 }, 2.0, &mut settle));
    }

    #[test]
    fn menus_move_into_window_points_and_close_stops_the_meters() {
        let (mut m, id, mut cx) = rig();
        let mut h = MultibandHost::open(id, &m, CGSize::new(1280.0, 800.0), false);
        let Some(r) = h.draw.frame_of(&Control::Preset) else { panic!("no preset") };
        let at = CGPoint::new(r.mid_x() + h.frame().min_x(), r.mid_y() + h.frame().min_y());
        assert!(down_up(&mut h, &mut m, &mut cx, at));
        let menus = h.take_menus();
        assert_eq!(menus.len(), 1);
        assert_eq!(menus[0].anchor.min_x(), r.min_x() + h.frame().min_x());
        assert!(h.take_menus().is_empty());
        h.menu_closed(&mut m);
        h.close(&mut m, &mut cx);
        assert!(!h.is_active());
    }

    #[test]
    fn spectrum_request_is_handed_out_once() {
        let (mut m, id, mut cx) = rig();
        let mut h = MultibandHost::open(id, &m, CGSize::new(1280.0, 800.0), false);
        let Some(r) = h.draw.frame_of(&Control::SpectrumInput) else { panic!("no toggle") };
        let at = CGPoint::new(r.mid_x() + h.frame().min_x(), r.mid_y() + h.frame().min_y());
        assert!(down_up(&mut h, &mut m, &mut cx, at));
        assert_eq!(h.take_spectrum_at_input(), Some(true));
        assert_eq!(h.take_spectrum_at_input(), None);
    }
}
