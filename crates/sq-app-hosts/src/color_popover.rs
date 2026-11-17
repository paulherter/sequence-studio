// Swift: SQColorPickerView in an SQPopover (inspector color wells)
//! The color picker popover the inspector opens for color wells: it owns a [`ColorPickerControl`], follows the pointer
//! and reports every change as an [`EffectColor`]. Clicking outside or Esc closes it.

use crate::analysis_links::eyedropper::Eyedropper;
use sq_core_model::EffectColor;
use sq_draw::inspector::color_picker_control::Outcome;
use sq_draw::{Canvas, ColorPickerControl, DrawTheme, InputEvent, InputKey, UiCx};
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqcolor_recents;
use sq_uikit::sqcolor_value::SQColorValue;
use std::cell::RefCell;
use std::rc::Rc;

/// The shared defaults the recent colors live in.
pub type SharedDefaults = Rc<RefCell<Box<dyn UiDefaults>>>;

/// What a picker may use besides its own drawing: the stored recent colors and the monitor eyedropper (Swift
/// `SQColorRecents` and `AppScreenSampler`). Without either the picker shows neither.
#[derive(Clone, Default)]
pub struct PickerAids {
    /// Samples the Program monitor picture; the picker's pipette button shows only with it.
    pub eyedropper: Option<Eyedropper>,
    /// Where the recent colors are stored (`sq.color.recents`).
    pub defaults: Option<SharedDefaults>,
}

/// What an event did to the popover.
#[derive(Debug, PartialEq)]
pub enum PopoverEvent {
    /// Not for the popover.
    Ignored,
    /// Taken, nothing to report.
    Taken,
    /// The color changed.
    Changed(EffectColor),
    /// The popover closed and the event is taken (Esc, or a press on the control that opened it).
    Closed,
    /// The popover closed on a press elsewhere, which goes on to what is under the pointer.
    Dismissed,
}

/// An open color picker popover.
pub struct ColorPopover<T> {
    /// What the color belongs to; handed back with every report.
    pub target: T,
    picker: ColorPickerControl,
    frame: CGRect,
    /// The control that opened it (window points): a press there only closes the popover.
    opener: CGRect,
    dragging: bool,
    aids: PickerAids,
    /// The pipette was pressed: the next click on the monitor picture picks.
    awaiting_pick: bool,
}

/// The color that led the recents when the popover closes is stored (Swift `closePicker`: `commitRecent`).
impl<T> Drop for ColorPopover<T> {
    fn drop(&mut self) {
        if self.awaiting_pick
            && let Some(dropper) = &self.aids.eyedropper
        {
            dropper.cancel();
        }
        if self.picker.commit_recent()
            && let Some(defaults) = &self.aids.defaults
        {
            sqcolor_recents::remember(&self.picker.value, &mut **defaults.borrow_mut());
        }
    }
}

impl<T> ColorPopover<T> {
    /// A popover for `current` below `anchor`, kept inside `visible` (all in points), without recents or a pipette.
    #[cfg(test)]
    pub fn open(target: T, current: EffectColor, anchor: CGRect, visible: CGRect) -> ColorPopover<T> {
        Self::open_with(target, current, anchor, visible, &PickerAids::default())
    }

    /// [`open`](Self::open) with the recent colors and the monitor pipette `aids` offer.
    pub fn open_with(
        target: T,
        current: EffectColor,
        anchor: CGRect,
        visible: CGRect,
        aids: &PickerAids,
    ) -> ColorPopover<T> {
        let value = SQColorValue::from_rgb(current.red, current.green, current.blue, current.alpha);
        let recents = aids.defaults.as_ref().map(|d| sqcolor_recents::load(&**d.borrow())).unwrap_or_default();
        let picker = ColorPickerControl::new(value, false, aids.eyedropper.is_some(), recents);
        let frame = picker.frame(anchor, visible);
        ColorPopover {
            target,
            picker,
            frame,
            opener: anchor,
            dragging: false,
            aids: aids.clone(),
            awaiting_pick: false,
        }
    }

    /// The recent colors the picker shows, newest first (tests).
    #[cfg(test)]
    pub(crate) fn recents(&self) -> &[String] {
        &self.picker.recents
    }

    /// The center of the pipette button in window points (tests).
    #[cfg(test)]
    pub(crate) fn pipette_center(&self) -> Option<CGPoint> {
        let r = self.picker.eyedropper_frame()?;
        Some(CGPoint::new(self.frame.x + r.mid_x(), self.frame.y + r.mid_y()))
    }

    /// True while the pipette waits for its click on the picture.
    #[cfg(test)]
    pub(crate) fn is_awaiting_pick(&self) -> bool {
        self.awaiting_pick
    }

    /// The monitor's answer to the pipette, once it is there: a picked color changes the value (the alpha stays); a
    /// click outside the picture only ends the pick.
    pub fn poll_pick(&mut self) -> Option<PopoverEvent> {
        let dropper = self.aids.eyedropper.as_ref().filter(|d| self.awaiting_pick && d.has_answer())?;
        let answer = dropper.take_answer()?;
        self.awaiting_pick = false;
        let (r, g, b) = answer?;
        let o = self.picker.pick(SQColorValue::from_rgb(r, g, b, 1.0));
        Some(self.outcome(o))
    }

    fn color(&self) -> EffectColor {
        let (red, green, blue) = self.picker.value.rgb();
        EffectColor { red, green, blue, alpha: self.picker.value.a }
    }

    fn local(&self, x: f32, y: f32, scale: f32) -> CGPoint {
        let k = f64::from(scale);
        CGPoint::new(f64::from(x) / k - self.frame.x, f64::from(y) / k - self.frame.y)
    }

    fn outcome(&mut self, o: Outcome) -> PopoverEvent {
        match o {
            Outcome::Changed => PopoverEvent::Changed(self.color()),
            Outcome::Eyedropper => {
                if let Some(dropper) = &self.aids.eyedropper {
                    dropper.arm();
                    self.awaiting_pick = true;
                    self.dragging = false;
                }
                PopoverEvent::Taken
            }
            _ => PopoverEvent::Taken,
        }
    }

    /// Routes an event in pixels; `scale` converts to points.
    pub fn handle(&mut self, e: &InputEvent, scale: f32, cx: &mut UiCx) -> PopoverEvent {
        // The pipette waits for a click on the monitor picture: that press is not the popover's (Esc ends the pick).
        if self.awaiting_pick {
            match *e {
                InputEvent::MouseDown { .. } | InputEvent::MouseUp { .. } | InputEvent::MouseDragged { .. } => {
                    return PopoverEvent::Ignored;
                }
                InputEvent::KeyDown { key: InputKey::Escape, .. } => {
                    if let Some(dropper) = &self.aids.eyedropper {
                        dropper.cancel();
                        dropper.take_answer();
                    }
                    self.awaiting_pick = false;
                    return PopoverEvent::Taken;
                }
                _ => {}
            }
        }
        match *e {
            InputEvent::MouseDown { x, y, .. } => {
                let p = self.local(x, y, scale);
                if !CGRect::new(0.0, 0.0, self.frame.width, self.frame.height).contains(p) {
                    let taken = e.closing_popover_is_taken(scale, self.opener);
                    return if taken { PopoverEvent::Closed } else { PopoverEvent::Dismissed };
                }
                self.dragging = true;
                let o = self.picker.mouse_down(p);
                self.outcome(o)
            }
            InputEvent::MouseDragged { x, y, .. } if self.dragging => {
                let o = self.picker.mouse_dragged(self.local(x, y, scale));
                self.outcome(o)
            }
            InputEvent::MouseUp { .. } if self.dragging => {
                self.dragging = false;
                self.picker.mouse_up();
                PopoverEvent::Taken
            }
            InputEvent::MouseMoved { x, y } => {
                self.picker.mouse_moved(self.local(x, y, scale));
                PopoverEvent::Ignored
            }
            InputEvent::KeyDown { key, modifiers } => {
                let (used, o) = self.picker.key(key, modifiers, cx);
                if o == Outcome::Changed {
                    PopoverEvent::Changed(self.color())
                } else if used {
                    PopoverEvent::Taken
                } else if key == InputKey::Escape {
                    PopoverEvent::Closed
                } else {
                    PopoverEvent::Ignored
                }
            }
            _ => PopoverEvent::Ignored,
        }
    }

    /// Draws the popover at its place (the canvas origin is the window's).
    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        c.save_gstate();
        c.translate_by(self.frame.x, self.frame.y);
        self.picker.draw(c, t, cx);
        c.restore_gstate();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_draw::InputModifiers;

    fn red() -> EffectColor {
        EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 }
    }

    #[test]
    fn a_press_on_the_hue_bar_changes_the_color_and_a_press_outside_closes() {
        let mut ui = UiCx::new();
        let anchor = CGRect::new(100.0, 100.0, 20.0, 12.0);
        let mut p = ColorPopover::open((), red(), anchor, CGRect::new(0.0, 0.0, 800.0, 600.0));
        let hue = p.picker.hue_frame();
        let at = |x: f64, y: f64| InputEvent::MouseDown {
            x: (x + p.frame.x) as f32,
            y: (y + p.frame.y) as f32,
            modifiers: InputModifiers::NONE,
        };
        let down = at(hue.min_x() + hue.width * 0.5, hue.mid_y());
        let PopoverEvent::Changed(c) = p.handle(&down, 1.0, &mut ui) else { panic!("no change") };
        assert!(c.green > 0.5 && c.red < 0.5, "half way round the hue wheel is cyan");
        let outside = InputEvent::MouseDown { x: 790.0, y: 590.0, modifiers: InputModifiers::NONE };
        assert_eq!(p.handle(&outside, 1.0, &mut ui), PopoverEvent::Dismissed, "a press elsewhere closes and goes on");
        let on_opener = InputEvent::MouseDown { x: 110.0, y: 106.0, modifiers: InputModifiers::NONE };
        assert_eq!(p.handle(&on_opener, 1.0, &mut ui), PopoverEvent::Closed, "a press on the opener only closes");
        let esc = InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE };
        assert_eq!(p.handle(&esc, 1.0, &mut ui), PopoverEvent::Closed);
    }
}
