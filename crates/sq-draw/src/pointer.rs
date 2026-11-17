//! winit's pointer and modifier events as the draw UI's `InputEvent` (device pixels, y down): one [`Pointer`] for every window
//! of the app (the editor, the start-failure screen, the setup), so a window that opens under a still pointer waits for
//! its first position in every one of them.

use crate::input::{InputEvent, InputModifiers};
use crate::scroll::{GestureKind, ScrollGesture, ScrollPhase, WinScroll};
use sq_os::Platform;
use winit::event::{ElementState, MouseButton, MouseScrollDelta, TouchPhase};
use winit::keyboard::ModifiersState;

/// A momentum tail starts within this long (seconds) after the fingers lifted.
const MOMENTUM_GAP: f64 = 0.25;

/// Where a trackpad scroll is: winit folds touch and momentum phases into one `TouchPhase`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
enum ScrollTrack {
    #[default]
    Idle,
    Touch,
    TouchEnded(f64),
    Momentum,
}

/// The modifier flags: Command is Cmd on the Mac and Ctrl on Windows (Ctrl stays separate on the Mac).
pub fn modifiers(state: ModifiersState) -> InputModifiers {
    modifiers_for(Platform::current(), state)
}

/// [`modifiers`] for a given system.
pub fn modifiers_for(platform: Platform, state: ModifiersState) -> InputModifiers {
    let mut m = InputModifiers::NONE;
    if state.shift_key() {
        m = m | InputModifiers::SHIFT;
    }
    if state.alt_key() {
        m = m | InputModifiers::OPTION;
    }
    if platform.command_is_cmd_key() {
        if state.super_key() {
            m = m | InputModifiers::COMMAND;
        }
        if state.control_key() {
            m = m | InputModifiers::CONTROL;
        }
    } else if state.control_key() {
        m = m | InputModifiers::COMMAND;
    }
    m
}

/// The pointer between events: where it is and whether the primary button is down.
#[derive(Default)]
pub struct Pointer {
    x: f32,
    y: f32,
    down: bool,
    /// No position has arrived yet (the window opened under a pointer that has not moved): a press has no place, and
    /// the default (0, 0) is the window's resize corner, which swallowed the first click.
    awaiting_position: bool,
    /// Buttons pressed while the position was unknown, replayed at the first position by `take_queued` (when it comes
    /// within [`QUEUED_PRESS_LIFETIME`]: a click must not fire at a place the user moved to much later).
    queued: Vec<(std::time::Instant, ElementState, MouseButton, InputModifiers)>,
    scroll: ScrollTrack,
    win_scroll: WinScroll,
}

/// How long a press waits for the pointer's first position.
const QUEUED_PRESS_LIFETIME: std::time::Duration = std::time::Duration::from_millis(300);

/// Where a pointer that left the window is parked (device pixels, outside every rect).
const OFF_WINDOW: f32 = -100_000.0;

/// One winit wheel event of a replayed trackpad flick: the phase, the pixel delta and the time since the flick began.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FlickEvent {
    pub phase: TouchPhase,
    pub pixels: f64,
    pub at: f64,
}

/// The events winit delivers on macOS for one trackpad flick of `total` pixels: `frames` finger moves 8 ms apart
/// (Started, Moved...), the lift (Ended, zero), then the system's momentum tail (a Started within [`MOMENTUM_GAP`], decaying
/// Moved events every 16 ms, an Ended). Both the offscreen `flick:` step and the tests replay this one list.
pub fn flick_events(total: f64, frames: usize) -> Vec<FlickEvent> {
    let frames = frames.max(1);
    let each = total / frames as f64;
    let mut out = Vec::new();
    let mut t = 0.0;
    for i in 0..frames {
        let phase = if i == 0 { TouchPhase::Started } else { TouchPhase::Moved };
        out.push(FlickEvent { phase, pixels: each, at: t });
        t += 0.008;
    }
    out.push(FlickEvent { phase: TouchPhase::Ended, pixels: 0.0, at: t });
    t += 0.016;
    let mut v = each * 2.0;
    out.push(FlickEvent { phase: TouchPhase::Started, pixels: v, at: t });
    for _ in 0..40 {
        t += 0.016;
        v *= 0.9;
        out.push(FlickEvent { phase: TouchPhase::Moved, pixels: v, at: t });
    }
    t += 0.016;
    out.push(FlickEvent { phase: TouchPhase::Ended, pixels: 0.0, at: t });
    out
}

/// Index of the first momentum event in [`flick_events`] (`frames` finger moves, then the lift).
pub fn flick_tail_start(frames: usize) -> usize {
    frames.max(1) + 1
}

/// The phase-less wheel messages Windows delivers for one precision-touchpad flick of `lines` notches (positive = pull down
/// at the top): `frames` finger messages 8 ms apart, then inertia messages decaying every 16 ms; no phase, no end. Each is
/// `(seconds since the flick began, lines)`. A message is never a whole notch, so the route reads it as a touchpad. The
/// inertia starts at index [`win_flick_tail_start`].
pub fn win_flick_events(lines: f64, frames: usize) -> Vec<(f64, f64)> {
    let frames = frames.max(1);
    let each = lines / frames as f64;
    let mut out: Vec<(f64, f64)> = (0..frames).map(|k| (k as f64 * 0.008, each)).collect();
    let (mut t, mut v) = (frames as f64 * 0.008 + 0.016, each * 2.0);
    for _ in 0..40 {
        t += 0.016;
        v *= 0.9;
        out.push((t, v));
    }
    out
}

/// Index of the first inertia message in [`win_flick_events`].
pub fn win_flick_tail_start(frames: usize) -> usize {
    frames.max(1)
}

impl Pointer {
    /// A pointer of the main window: its position is unknown until winit reports the first move.
    pub fn awaiting_position() -> Pointer {
        Pointer { awaiting_position: true, ..Pointer::default() }
    }

    /// The pointer moved to (`x`, `y`) device pixels: a drag while the primary button is down, carrying the modifiers held
    /// now (this is the one place a drag learns its live keys).
    pub fn moved(&mut self, x: f64, y: f64, mods: InputModifiers) -> InputEvent {
        (self.x, self.y) = (x as f32, y as f32);
        self.awaiting_position = false;
        if self.down {
            InputEvent::MouseDragged { x: self.x, y: self.y, modifiers: mods }
        } else {
            InputEvent::MouseMoved { x: self.x, y: self.y }
        }
    }

    /// The pointer left the window with no button held: a move far outside, so no hover stays lit on the last row it
    /// crossed (`None` while a drag holds the pointer).
    pub fn left(&mut self) -> Option<InputEvent> {
        if self.down {
            return None;
        }
        (self.x, self.y) = (OFF_WINDOW, OFF_WINDOW);
        Some(InputEvent::MouseMoved { x: self.x, y: self.y })
    }

    /// The window lost the pointer or focus: a held primary button ends here (`None` when none is held).
    pub fn cancel(&mut self) -> Option<InputEvent> {
        std::mem::take(&mut self.down).then_some(InputEvent::MouseUp { x: self.x, y: self.y })
    }

    /// Whether the primary button is held (an app drag is on: the window's edges must not take the pointer then).
    pub fn is_down(&self) -> bool {
        self.down
    }

    /// Where the pointer is, in device pixels.
    pub fn position(&self) -> (f32, f32) {
        (self.x, self.y)
    }

    /// A button changed. The secondary button (and Control-click on the Mac) is one press and release at once, so
    /// the panel opens its menu on the press; other buttons are ignored.
    pub fn button(&mut self, state: ElementState, button: MouseButton, mods: InputModifiers) -> Vec<InputEvent> {
        // winit gives a press no position: before the first move it waits for one instead of landing at (0, 0).
        if self.awaiting_position && (state == ElementState::Pressed || !self.queued.is_empty()) {
            self.queued.push((std::time::Instant::now(), state, button, mods));
            return Vec::new();
        }
        let (x, y) = (self.x, self.y);
        // Control-click is the Mac's secondary click; on Windows and Linux Ctrl + click stays a click with Ctrl held.
        let secondary =
            button == MouseButton::Right || (cfg!(target_os = "macos") && mods.contains(InputModifiers::CONTROL));
        match (button, state) {
            (MouseButton::Right, ElementState::Pressed) | (MouseButton::Left, ElementState::Pressed) if secondary => {
                vec![
                    InputEvent::MouseDown { x, y, modifiers: mods | InputModifiers::SECONDARY },
                    InputEvent::MouseUp { x, y },
                ]
            }
            (MouseButton::Left, ElementState::Pressed) => {
                self.down = true;
                vec![InputEvent::MouseDown { x, y, modifiers: mods }]
            }
            (MouseButton::Left, ElementState::Released) if self.down => {
                self.down = false;
                vec![InputEvent::MouseUp { x, y }]
            }
            _ => Vec::new(),
        }
    }

    /// The buttons that came before the first position, now placed at it: each with the events it makes.
    pub fn take_queued(&mut self) -> Vec<(ElementState, MouseButton, Vec<InputEvent>)> {
        if self.awaiting_position {
            return Vec::new();
        }
        let queued = std::mem::take(&mut self.queued);
        queued
            .into_iter()
            .filter(|(at, ..)| at.elapsed() <= QUEUED_PRESS_LIFETIME)
            .map(|(_, state, button, mods)| (state, button, self.button(state, button, mods)))
            .collect()
    }

    /// A wheel or trackpad scroll at the current position. The gesture carries AppKit's units and signs (winit's match
    /// them): a trackpad (`PixelDelta`, physical pixels) in points at `scale`, a wheel in lines. The event carries device
    /// pixels for the lists. `now` is seconds on the app clock; it tells a momentum tail from a new touch.
    pub fn wheel(
        &mut self,
        delta: MouseScrollDelta,
        phase: TouchPhase,
        mods: InputModifiers,
        scale: f32,
        now: f64,
    ) -> (InputEvent, ScrollGesture) {
        let scale = f64::from(scale.max(1.0));
        let (px, py, precise) = match delta {
            MouseScrollDelta::LineDelta(x, y) => (
                f64::from(x) * ScrollGesture::WHEEL_PIXELS_PER_NOTCH,
                f64::from(y) * ScrollGesture::WHEEL_PIXELS_PER_NOTCH,
                false,
            ),
            MouseScrollDelta::PixelDelta(p) => (p.x, p.y, true),
        };
        let mut g = ScrollGesture { precise, ..ScrollGesture::default() };
        if precise {
            (g.delta_x, g.delta_y) = (px / scale, py / scale);
            (g.phase, g.momentum_phase) = self.track_phase(phase, now);
        } else {
            (g.delta_x, g.delta_y) =
                (px / ScrollGesture::WHEEL_PIXELS_PER_NOTCH, py / ScrollGesture::WHEEL_PIXELS_PER_NOTCH);
        }
        let ev = InputEvent::Scroll { x: self.x, y: self.y, dx: px as f32, dy: py as f32, modifiers: mods };
        (ev, g)
    }

    /// The Windows wheel route. winit 0.30 turns every `WM_MOUSEWHEEL` into a `LineDelta` (a precision touchpad sends
    /// fractions of a notch, a pinch the same with Ctrl held) and has no pinch event, so [`WinScroll`] tells touchpad,
    /// pinch and mouse notch apart. A pinch carries no scroll pixels, so nothing is handled twice.
    pub fn win_wheel(
        &mut self,
        delta: MouseScrollDelta,
        mods: InputModifiers,
        scale: f32,
        now: f64,
    ) -> (InputEvent, ScrollGesture) {
        let units = |lines: f32| (f64::from(lines) * f64::from(WinScroll::WHEEL_DELTA)).round() as i32;
        let (d, horizontal) = match delta {
            // winit negates the horizontal wheel; WinScroll takes the raw message sign.
            MouseScrollDelta::LineDelta(x, y) if x != 0.0 && y == 0.0 => (-units(x), true),
            MouseScrollDelta::LineDelta(_, y) => (units(y), false),
            MouseScrollDelta::PixelDelta(p) => (units(p.y as f32 / scale.max(1.0) / 40.0), false),
        };
        let g = self.win_scroll.wheel(d, horizontal, mods.contains(InputModifiers::COMMAND), now);
        (self.win_scroll_event(&g, mods, scale), g)
    }

    /// A touchpad gesture is running and still needs its end.
    pub fn win_scroll_active(&self) -> bool {
        self.win_scroll.is_active()
    }

    /// Once per turn on Windows: the end of a touchpad gesture that went quiet.
    pub fn win_idle(&mut self, mods: InputModifiers, scale: f32, now: f64) -> Option<(InputEvent, ScrollGesture)> {
        let g = self.win_scroll.idle(now)?;
        Some((self.win_scroll_event(&g, mods, scale), g))
    }

    fn win_scroll_event(&self, g: &ScrollGesture, mods: InputModifiers, scale: f32) -> InputEvent {
        let (dx, dy) = WinScroll::pixels(g, scale);
        InputEvent::Scroll { x: self.x, y: self.y, dx, dy, modifiers: mods }
    }

    /// winit reports touch and momentum phases alike: a start right after a touch ended is the momentum tail.
    fn track_phase(&mut self, phase: TouchPhase, now: f64) -> (ScrollPhase, ScrollPhase) {
        use ScrollPhase as P;
        match (phase, self.scroll) {
            (TouchPhase::Started, ScrollTrack::TouchEnded(t)) if now - t <= MOMENTUM_GAP => {
                self.scroll = ScrollTrack::Momentum;
                (P::None, P::Began)
            }
            (TouchPhase::Started, _) => {
                self.scroll = ScrollTrack::Touch;
                (P::Began, P::None)
            }
            (TouchPhase::Moved, ScrollTrack::Momentum) => (P::None, P::Changed),
            (TouchPhase::Moved, _) => {
                if self.scroll == ScrollTrack::Idle {
                    self.scroll = ScrollTrack::Touch;
                }
                (P::Changed, P::None)
            }
            (_, ScrollTrack::Momentum) => {
                self.scroll = ScrollTrack::Idle;
                (P::None, P::Ended)
            }
            (TouchPhase::Ended, _) => {
                self.scroll = ScrollTrack::TouchEnded(now);
                (P::Ended, P::None)
            }
            (TouchPhase::Cancelled, _) => {
                self.scroll = ScrollTrack::Idle;
                (P::Cancelled, P::None)
            }
        }
    }

    /// A trackpad pinch (`magnification` 0.1 = 10 % bigger) at the current position, as a scroll of zero pixels.
    pub fn pinch(&self, magnification: f64, phase: TouchPhase, mods: InputModifiers) -> (InputEvent, ScrollGesture) {
        let phase = match phase {
            TouchPhase::Started => ScrollPhase::Began,
            TouchPhase::Moved => ScrollPhase::Changed,
            TouchPhase::Ended => ScrollPhase::Ended,
            TouchPhase::Cancelled => ScrollPhase::Cancelled,
        };
        let g = ScrollGesture { kind: GestureKind::Magnify(magnification), precise: true, phase, ..Default::default() };
        (InputEvent::Scroll { x: self.x, y: self.y, dx: 0.0, dy: 0.0, modifiers: mods }, g)
    }

    /// A two-finger double tap at the current position.
    pub fn smart_magnify(&self, mods: InputModifiers) -> (InputEvent, ScrollGesture) {
        let g = ScrollGesture { kind: GestureKind::SmartMagnify, precise: true, ..Default::default() };
        (InputEvent::Scroll { x: self.x, y: self.y, dx: 0.0, dy: 0.0, modifiers: mods }, g)
    }
}

/// One primary-button change in points.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Click {
    Down { x: f64, y: f64 },
    Up { x: f64, y: f64 },
}

/// The primary presses and releases among the events [`Pointer::button`] made, in points at `scale`, for a view that takes
/// points. A secondary click (right button, Ctrl-click on the Mac) is none of them: the views of the small windows have no
/// menu, and every window must treat it the same way.
pub fn primary_clicks(events: &[InputEvent], scale: f64) -> impl Iterator<Item = Click> + '_ {
    // A secondary click is a press and a release at once: the release goes with it.
    let mut secondary = false;
    events.iter().filter_map(move |e| match *e {
        InputEvent::MouseDown { modifiers, .. } if modifiers.contains(InputModifiers::SECONDARY) => {
            secondary = true;
            None
        }
        InputEvent::MouseDown { x, y, .. } => Some(Click::Down { x: f64::from(x) / scale, y: f64::from(y) / scale }),
        InputEvent::MouseUp { .. } if std::mem::take(&mut secondary) => None,
        InputEvent::MouseUp { x, y } => Some(Click::Up { x: f64::from(x) / scale, y: f64::from(y) / scale }),
        _ => None,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn flick_tail_indexes_point_at_the_first_momentum_event() {
        let mac = flick_events(100.0, 6);
        assert_eq!(mac[flick_tail_start(6)].phase, TouchPhase::Started);
        assert_eq!(mac[flick_tail_start(6) - 1].phase, TouchPhase::Ended);
        let win = win_flick_events(2.5, 8);
        assert!(
            win[win_flick_tail_start(8)].0 > win[win_flick_tail_start(8) - 1].0 + 0.015,
            "a gap before the inertia"
        );
        assert!(win.iter().all(|(_, l)| (l * 120.0).fract().abs() > 1e-6), "never a whole notch");
    }

    use super::*;
    use winit::dpi::PhysicalPosition;

    #[test]
    fn a_pointer_leaving_the_window_parks_off_screen_unless_a_drag_holds_it() {
        let mut p = Pointer::default();
        p.moved(40.0, 50.0, InputModifiers::NONE);
        assert_eq!(p.left(), Some(InputEvent::MouseMoved { x: OFF_WINDOW, y: OFF_WINDOW }));
        p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::default());
        assert_eq!(p.left(), None, "a held button keeps its drag");
    }

    #[test]
    fn command_is_ctrl_on_windows_and_cmd_on_the_mac() {
        for p in [Platform::Mac, Platform::Windows, Platform::Linux] {
            let ctrl = modifiers_for(p, ModifiersState::CONTROL);
            let cmd = modifiers_for(p, ModifiersState::SUPER);
            if p == Platform::Mac {
                assert!(cmd.contains(InputModifiers::COMMAND) && ctrl.contains(InputModifiers::CONTROL));
            } else {
                assert!(ctrl.contains(InputModifiers::COMMAND) && cmd == InputModifiers::NONE, "{p:?}");
            }
        }
    }

    #[test]
    fn primary_press_drags_until_release() {
        let mut p = Pointer::default();
        assert_eq!(p.moved(5.0, 6.0, InputModifiers::NONE), InputEvent::MouseMoved { x: 5.0, y: 6.0 });
        let down = p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::NONE);
        assert_eq!(down, vec![InputEvent::MouseDown { x: 5.0, y: 6.0, modifiers: InputModifiers::NONE }]);
        assert_eq!(p.moved(7.0, 6.0, InputModifiers::NONE), InputEvent::dragged(7.0, 6.0));
        let held = InputModifiers::OPTION | InputModifiers::SHIFT;
        assert_eq!(
            p.moved(7.5, 6.0, held),
            InputEvent::MouseDragged { x: 7.5, y: 6.0, modifiers: held },
            "a key pressed mid-drag shows on the drag event"
        );
        let up = p.button(ElementState::Released, MouseButton::Left, InputModifiers::NONE);
        assert_eq!(up, vec![InputEvent::MouseUp { x: 7.5, y: 6.0 }]);
        assert_eq!(p.moved(8.0, 6.0, InputModifiers::NONE), InputEvent::MouseMoved { x: 8.0, y: 6.0 });
    }

    #[test]
    fn losing_focus_mid_drag_releases_the_button() {
        let mut p = Pointer::default();
        assert_eq!(p.cancel(), None);
        p.moved(3.0, 4.0, InputModifiers::NONE);
        p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::NONE);
        assert_eq!(p.cancel(), Some(InputEvent::MouseUp { x: 3.0, y: 4.0 }));
        assert_eq!(p.moved(5.0, 4.0, InputModifiers::NONE), InputEvent::MouseMoved { x: 5.0, y: 4.0 });
    }

    #[test]
    fn secondary_press_is_down_and_up_at_once() {
        let mut p = Pointer::default();
        let ev = p.button(ElementState::Pressed, MouseButton::Right, InputModifiers::NONE);
        assert_eq!(ev.len(), 2);
        assert!(
            matches!(ev[0], InputEvent::MouseDown { modifiers, .. } if modifiers.contains(InputModifiers::SECONDARY))
        );
        assert!(p.button(ElementState::Released, MouseButton::Right, InputModifiers::NONE).is_empty());
        assert_eq!(p.moved(1.0, 1.0, InputModifiers::NONE), InputEvent::MouseMoved { x: 1.0, y: 1.0 });
    }

    #[test]
    fn a_press_before_the_first_move_waits_for_the_position() {
        let mut p = Pointer::awaiting_position();
        assert!(p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::NONE).is_empty());
        assert!(p.button(ElementState::Released, MouseButton::Left, InputModifiers::NONE).is_empty());
        assert!(p.take_queued().is_empty(), "no position yet");
        p.moved(40.0, 30.0, InputModifiers::NONE);
        let replay = p.take_queued();
        assert_eq!(replay.len(), 2);
        assert_eq!(replay[0].2, [InputEvent::MouseDown { x: 40.0, y: 30.0, modifiers: InputModifiers::NONE }]);
        assert_eq!(replay[1].2, [InputEvent::MouseUp { x: 40.0, y: 30.0 }]);
        assert!(!p.is_down());
        // After that a press is placed at once.
        let now = p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::NONE);
        assert_eq!(now, [InputEvent::MouseDown { x: 40.0, y: 30.0, modifiers: InputModifiers::NONE }]);
    }

    #[test]
    fn a_release_with_no_queued_press_is_not_queued() {
        let mut p = Pointer::awaiting_position();
        assert!(p.button(ElementState::Released, MouseButton::Left, InputModifiers::NONE).is_empty());
        p.moved(1.0, 1.0, InputModifiers::NONE);
        assert!(p.take_queued().is_empty());
    }

    /// Ctrl + left press is the secondary click only on the Mac; elsewhere it is a left press that keeps Ctrl.
    #[test]
    fn control_click_is_secondary_only_on_the_mac() {
        let mut p = Pointer::default();
        let ev = p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::CONTROL);
        if cfg!(target_os = "macos") {
            assert_eq!(ev.len(), 2);
            assert!(
                matches!(ev[0], InputEvent::MouseDown { modifiers, .. } if modifiers.contains(InputModifiers::SECONDARY))
            );
        } else {
            assert_eq!(ev, [InputEvent::MouseDown { x: 0.0, y: 0.0, modifiers: InputModifiers::CONTROL }]);
            assert!(p.is_down());
        }
    }

    #[test]
    fn wheel_lines_are_notches_of_forty_pixels() {
        let mut p = Pointer::default();
        let (e, g) = p.wheel(MouseScrollDelta::LineDelta(0.0, 2.0), TouchPhase::Moved, InputModifiers::NONE, 2.0, 0.0);
        assert_eq!(e, InputEvent::Scroll { x: 0.0, y: 0.0, dx: 0.0, dy: 80.0, modifiers: InputModifiers::NONE });
        assert!(!g.precise && g.delta_y == 2.0 && g.phase == ScrollPhase::None);
    }

    #[test]
    fn trackpad_pixels_become_points_and_keep_the_pixels_for_lists() {
        let mut p = Pointer::default();
        let d = MouseScrollDelta::PixelDelta(PhysicalPosition::new(6.0, -4.0));
        let (e, g) = p.wheel(d, TouchPhase::Started, InputModifiers::NONE, 2.0, 0.0);
        assert!(matches!(e, InputEvent::Scroll { dx: 6.0, dy: -4.0, .. }));
        assert!(g.precise && g.delta_x == 3.0 && g.delta_y == -2.0 && g.phase == ScrollPhase::Began);
    }

    #[test]
    fn momentum_follows_the_lifted_fingers() {
        let mut p = Pointer::default();
        let d = MouseScrollDelta::PixelDelta(PhysicalPosition::new(1.0, 1.0));
        let phases = |p: &mut Pointer, t, now| {
            let g = p.wheel(d, t, InputModifiers::NONE, 1.0, now).1;
            (g.phase, g.momentum_phase)
        };
        assert_eq!(phases(&mut p, TouchPhase::Started, 0.0), (ScrollPhase::Began, ScrollPhase::None));
        assert_eq!(phases(&mut p, TouchPhase::Moved, 0.01), (ScrollPhase::Changed, ScrollPhase::None));
        assert_eq!(phases(&mut p, TouchPhase::Ended, 0.02), (ScrollPhase::Ended, ScrollPhase::None));
        assert_eq!(phases(&mut p, TouchPhase::Started, 0.03), (ScrollPhase::None, ScrollPhase::Began));
        assert_eq!(phases(&mut p, TouchPhase::Moved, 0.04), (ScrollPhase::None, ScrollPhase::Changed));
        assert_eq!(phases(&mut p, TouchPhase::Ended, 0.5), (ScrollPhase::None, ScrollPhase::Ended));
        // a touch much later is a new gesture, not momentum
        assert_eq!(phases(&mut p, TouchPhase::Started, 2.0), (ScrollPhase::Began, ScrollPhase::None));
        assert_eq!(phases(&mut p, TouchPhase::Ended, 2.1), (ScrollPhase::Ended, ScrollPhase::None));
        assert_eq!(phases(&mut p, TouchPhase::Started, 3.0), (ScrollPhase::Began, ScrollPhase::None));
    }

    #[test]
    fn windows_touchpad_scrolls_in_points_and_ends_when_quiet() {
        let mut p = Pointer::default();
        let d = |y| MouseScrollDelta::LineDelta(0.0, y);
        let (e, g) = p.win_wheel(d(0.25), InputModifiers::NONE, 2.0, 0.0);
        assert!(g.precise && g.phase == ScrollPhase::Began && g.delta_y == 10.0);
        assert!(matches!(e, InputEvent::Scroll { dy, .. } if dy == 20.0));
        let g = p.win_wheel(d(0.25), InputModifiers::NONE, 2.0, 0.05).1;
        assert_eq!(g.phase, ScrollPhase::Changed);
        assert!(p.win_idle(InputModifiers::NONE, 2.0, 0.1).is_none());
        assert_eq!(p.win_idle(InputModifiers::NONE, 2.0, 0.5).map(|r| r.1.phase), Some(ScrollPhase::Ended));
    }

    #[test]
    fn windows_pinch_is_ctrl_plus_fractions_and_a_notch_stays_a_notch() {
        let mut p = Pointer::default();
        let (e, g) = p.win_wheel(MouseScrollDelta::LineDelta(0.0, 0.5), InputModifiers::COMMAND, 1.0, 0.0);
        assert!(matches!(g.kind, GestureKind::Magnify(m) if (m - 0.05).abs() < 1e-9));
        assert!(matches!(e, InputEvent::Scroll { dx: 0.0, dy: 0.0, .. }));
        let mut q = Pointer::default();
        let (e, g) = q.win_wheel(MouseScrollDelta::LineDelta(0.0, 1.0), InputModifiers::COMMAND, 1.0, 0.0);
        assert!(!g.precise && g.is_scroll());
        assert!(matches!(e, InputEvent::Scroll { dy: 40.0, .. }));
    }

    #[test]
    fn pinch_is_a_zero_scroll_with_magnification() {
        let p = Pointer::default();
        let (e, g) = p.pinch(0.1, TouchPhase::Moved, InputModifiers::NONE);
        assert!(matches!(e, InputEvent::Scroll { dx: 0.0, dy: 0.0, .. }));
        assert_eq!(g.kind, GestureKind::Magnify(0.1));
        assert_eq!(g.phase, ScrollPhase::Changed);
        assert_eq!(p.smart_magnify(InputModifiers::NONE).1.kind, GestureKind::SmartMagnify);
    }

    #[test]
    fn secondary_clicks_are_no_primary_clicks_and_points_follow_the_scale() {
        let mut p = Pointer::default();
        p.moved(40.0, 20.0, InputModifiers::NONE);
        let right = p.button(ElementState::Pressed, MouseButton::Right, InputModifiers::NONE);
        assert_eq!(primary_clicks(&right, 2.0).count(), 0, "the secondary press and its release");
        let down = p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::NONE);
        let up = p.button(ElementState::Released, MouseButton::Left, InputModifiers::NONE);
        assert_eq!(primary_clicks(&down, 2.0).collect::<Vec<_>>(), [Click::Down { x: 20.0, y: 10.0 }]);
        assert_eq!(primary_clicks(&up, 2.0).collect::<Vec<_>>(), [Click::Up { x: 20.0, y: 10.0 }]);
    }
}
