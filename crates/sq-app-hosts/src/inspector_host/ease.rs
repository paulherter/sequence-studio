// Swift: SQAppShell/Inspector/InspectorHost.swift (openEase)
//! The curve popover of Effect Controls (a motion effect's Custom curve, the speed transition at the playhead): places an
//! [`EasingPopoverDraw`] near its row, routes pointer events to it and closes it on a click outside or Esc.

use sq_core_time::Id;
use sq_draw::{Canvas, DrawTheme, InputEvent, InputKey, InputModifiers, UiCx};
use sq_editor_session::EditorSession;
use sq_inspector_ui::ec::ease_sources::SpeedRampEaseSource;
use sq_inspector_ui::ec::effect_controls_model::core::EffectControlsModel;
use sq_inspector_ui::ec::motion_curve::MotionCurveEaseSource;
use sq_inspector_ui::ec_draw::easing_popover_draw::{EasingPopoverDraw, EasingPopoverEvent};
use sq_inspector_ui::ec_draw::effect_controls_draw_panel::EaseCurveTarget;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::ease_curve_source::EaseCurveSource;

/// What an event did to the popover.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum EaseEvent {
    /// Not for the popover.
    Ignored,
    /// Taken; the model may have queued edits for the session.
    Taken,
    /// Taken and the popover closed (Esc, or a press on the control that opened it).
    Closed,
    /// The popover closed on a press elsewhere, which goes on to what is under the pointer.
    Dismissed,
}

/// The curve the popover edits, resolved when it opened.
#[derive(Clone, Copy)]
struct Which {
    target: EaseCurveTarget,
    clip: Id,
    segment: usize,
}

/// Runs `f` on the source the popover edits.
fn with_source<R>(
    which: Which,
    custom: &mut Option<Box<dyn EaseCurveSource>>,
    model: &mut EffectControlsModel,
    session: &mut EditorSession,
    f: impl FnOnce(&mut dyn EaseCurveSource) -> R,
) -> R {
    // A source the caller brought (a keystone's own curve) wins over the clip's targets.
    if let Some(source) = custom {
        return f(&mut **source);
    }
    match which.target {
        EaseCurveTarget::Motion(effect) => f(&mut MotionCurveEaseSource { model, effect }),
        EaseCurveTarget::SpeedTransition => f(&mut SpeedRampEaseSource::new(session, which.clip, which.segment)),
    }
}

/// An open curve popover.
pub(super) struct EasePopover {
    which: Which,
    draw: EasingPopoverDraw,
    frame: CGRect,
    /// The control that opened it (window points): a press there only closes the popover.
    opener: CGRect,
    dragging: bool,
    custom: Option<Box<dyn EaseCurveSource>>,
    /// Curves the user saved from the popover (the shape and the typed name); the root files them in the Library.
    saves: Vec<(sq_core_model::EaseShape, String)>,
}

impl EasePopover {
    /// A popover for `target` below `anchor` (window points), kept inside `visible`. `None` when the speed row has no
    /// transition at the playhead.
    pub(super) fn open(
        target: EaseCurveTarget,
        anchor: CGRect,
        visible: CGRect,
        model: &mut EffectControlsModel,
        session: &mut EditorSession,
    ) -> Option<EasePopover> {
        let clip = model.clip().map(|c| c.id)?;
        let segment = match target {
            EaseCurveTarget::SpeedTransition => session.speed_transition_segment(clip, model.local_playhead())?,
            EaseCurveTarget::Motion(_) => 0,
        };
        Some(Self::with(Which { target, clip, segment }, anchor, visible, model, session))
    }

    /// A popover for segment `segment` of the speed transitions of `clip` (the timeline's context menu names both).
    pub(super) fn open_speed(
        clip: Id,
        segment: usize,
        anchor: CGRect,
        visible: CGRect,
        model: &mut EffectControlsModel,
        session: &mut EditorSession,
    ) -> EasePopover {
        let which = Which { target: EaseCurveTarget::SpeedTransition, clip, segment };
        Self::with(which, anchor, visible, model, session)
    }

    fn with(
        which: Which,
        anchor: CGRect,
        visible: CGRect,
        model: &mut EffectControlsModel,
        session: &mut EditorSession,
    ) -> EasePopover {
        let draw = with_source(which, &mut None, model, session, |s| EasingPopoverDraw::new(&*s));
        EasePopover {
            which,
            draw,
            frame: EasingPopoverDraw::frame(anchor, visible),
            opener: anchor,
            dragging: false,
            custom: None,
            saves: Vec::new(),
        }
    }

    /// A popover for a source of its own (Edit Curve of a keystone) below `anchor`, kept inside `visible`.
    pub(super) fn open_source(source: Box<dyn EaseCurveSource>, anchor: CGRect, visible: CGRect) -> EasePopover {
        let draw = EasingPopoverDraw::new(&*source);
        let which = Which { target: EaseCurveTarget::SpeedTransition, clip: Id::from_u128(0), segment: 0 };
        EasePopover {
            which,
            draw,
            frame: EasingPopoverDraw::frame(anchor, visible),
            opener: anchor,
            dragging: false,
            custom: Some(source),
            saves: Vec::new(),
        }
    }

    /// The curves saved from the popover since the last call.
    pub(super) fn take_saves(&mut self) -> Vec<(sq_core_model::EaseShape, String)> {
        std::mem::take(&mut self.saves)
    }

    /// The user's saved curves the preset strip lists (the Library's `.easing` items).
    pub(super) fn set_saved(&mut self, saved: Vec<sq_core_time::EasingCurve>) {
        self.draw.saved = saved;
    }

    /// Routes an event in pixels; `scale` converts to points.
    pub(super) fn handle(
        &mut self,
        e: &InputEvent,
        scale: f32,
        model: &mut EffectControlsModel,
        session: &mut EditorSession,
        cx: &mut UiCx,
    ) -> EaseEvent {
        let (which, frame, draw, custom) = (self.which, self.frame, &mut self.draw, &mut self.custom);
        let local = |x: f32, y: f32| {
            let k = f64::from(scale);
            CGPoint::new(f64::from(x) / k - frame.x, f64::from(y) / k - frame.y)
        };
        let outcome = match *e {
            InputEvent::MouseDown { x, y, .. } => {
                let p = local(x, y);
                let size = EasingPopoverDraw::SIZE;
                if !CGRect::new(0.0, 0.0, size.width, size.height).contains(p) {
                    let taken = e.closing_popover_is_taken(scale, self.opener);
                    return if taken { EaseEvent::Closed } else { EaseEvent::Dismissed };
                }
                self.dragging = true;
                with_source(which, custom, model, session, |s| draw.mouse_down(s, p));
                EaseEvent::Taken
            }
            InputEvent::MouseDragged { x, y, .. } if self.dragging => {
                let p = local(x, y);
                with_source(which, custom, model, session, |s| draw.mouse_dragged(s, p, InputModifiers::NONE));
                EaseEvent::Taken
            }
            InputEvent::MouseUp { x, y } if self.dragging => {
                self.dragging = false;
                let p = local(x, y);
                with_source(which, custom, model, session, |s| draw.mouse_up(s, p));
                EaseEvent::Taken
            }
            InputEvent::MouseMoved { x, y } => {
                draw.mouse_moved(Some(local(x, y)));
                EaseEvent::Ignored
            }
            InputEvent::Scroll { x, y, dx, dy, .. } => {
                let p = local(x, y);
                if draw.scroll(p, f64::from(dx), f64::from(dy)) { EaseEvent::Taken } else { EaseEvent::Ignored }
            }
            InputEvent::KeyDown { key, modifiers } => {
                let used = with_source(which, custom, model, session, |s| draw.key(&*s, key, modifiers, cx));
                if used {
                    EaseEvent::Taken
                } else if key == InputKey::Escape {
                    return EaseEvent::Closed;
                } else {
                    EaseEvent::Ignored
                }
            }
            _ => EaseEvent::Ignored,
        };
        self.saves
            .extend(self.draw.take_events().into_iter().map(|EasingPopoverEvent::Save(shape, name)| (shape, name)));
        outcome
    }

    /// Draws the popover at its place (the canvas origin is the window's).
    pub(super) fn draw(
        &mut self,
        c: &mut Canvas,
        t: &DrawTheme,
        model: &mut EffectControlsModel,
        session: &mut EditorSession,
        cx: &mut UiCx,
    ) {
        let (which, draw, custom) = (self.which, &mut self.draw, &mut self.custom);
        c.save_gstate();
        c.translate_by(self.frame.x, self.frame.y);
        with_source(which, custom, model, session, |s| draw.draw(&*s, c, t, cx));
        c.restore_gstate();
    }
}
