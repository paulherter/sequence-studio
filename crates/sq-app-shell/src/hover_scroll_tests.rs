//! A list that scrolls under a resting pointer: the hover follows the row that is under the pointer now, with no pointer
//! move (`App::follow_content_under_pointer`, fed by `sq_draw::scroll::content_epoch`), and an idle window stays idle.

use crate::{AppDeps, AppHost, Headless, HostCx};
use sq_draw::scroll::ScrollBody;
use sq_draw::{Canvas, DrawTheme, InputEvent, InputModifiers};
use sq_editor_session::{EditorSession, SessionDeps};
use sq_runtime::FakeClock;
use sq_uikit::controls_grid::CGRect;
use std::cell::Cell;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

const ROW: f64 = 20.0;
const ROWS: f64 = 100.0;

/// A list of rows like the kit's panels: the offset lives in a `ScrollBody`, a move sets the hovered row from the pointer
/// and the offset, the wheel scrolls, and the draw reports which row it painted lit.
struct Rows {
    body: ScrollBody,
    frame: CGRect,
    hover: Option<usize>,
    drawn: Rc<Cell<Option<usize>>>,
}

impl AppHost for Rows {
    fn layout(&mut self, frame: CGRect, _cx: &mut HostCx) {
        self.frame = frame;
    }
    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, _cx: &mut HostCx) {
        self.body.position();
        c.fill(self.frame, t.panel());
        self.drawn.set(self.hover);
    }
    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let scale = f64::from(cx.scale);
        match *e {
            InputEvent::MouseMoved { y, .. } => {
                let row = (f64::from(y) / scale + self.body.offset(cx.ui.now)) / ROW;
                self.hover = Some(row as usize);
                false
            }
            InputEvent::Scroll { dx, dy, .. } => {
                let (max, extent) = (ROWS * ROW - self.frame.height, self.frame.height);
                self.body.wheel(cx.ui.gesture, dx, dy, scale, max, extent, cx.ui.now);
                true
            }
            _ => false,
        }
    }
}

fn window() -> (Headless, FakeClock, Rc<Cell<Option<usize>>>) {
    let mut ids = sq_core_time::SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-app-shell-hover-scroll"));
    deps.ids = Box::new(ids);
    let clock = FakeClock::new();
    let h = Headless::new(EditorSession::new(project, deps), AppDeps::headless(Arc::new(clock.clone())), 800, 600);
    let drawn = Rc::new(Cell::new(None));
    let rows = Rows { body: ScrollBody::new(0.0), frame: CGRect::default(), hover: None, drawn: Rc::clone(&drawn) };
    h.with(|a| a.add_host(Box::new(rows)));
    h.turn();
    (h, clock, drawn)
}

/// Plays frames at 60 Hz until the window asks for no more (the wheel ease runs out); panics when it never does.
fn settle(h: &Headless, clock: &FakeClock) {
    for _ in 0..120 {
        clock.advance(Duration::from_millis(16));
        h.turn();
        if h.with(|a| !a.needs_redraw()) == Some(true) {
            return;
        }
    }
    panic!("the window still asks for frames two seconds after the wheel");
}

fn wheel(dy: f32) -> InputEvent {
    InputEvent::Scroll { x: 50.0, y: 70.0, dx: 0.0, dy, modifiers: InputModifiers::NONE }
}

#[test]
fn a_wheel_scroll_moves_the_hover_to_the_row_now_under_the_pointer() {
    let (h, clock, drawn) = window();
    assert_eq!(h.with(|a| a.theme().scale), Some(1.0), "the rows below are in points = pixels");
    h.input(&InputEvent::MouseMoved { x: 50.0, y: 70.0 });
    h.turn();
    assert_eq!(drawn.get(), Some(3), "the pointer rests on row 3 (y 60..80)");
    // One notch is 40 px = 2 rows, content up; no move event follows.
    h.input(&wheel(-40.0));
    settle(&h, &clock);
    assert_eq!(drawn.get(), Some(5), "after 2 rows the pointer is over row 5, and the last frame drew it lit");
    assert!(h.turn().1.is_none(), "settled: no more frames");
}

#[test]
fn a_wheel_event_alone_tells_where_the_pointer_is_so_the_row_under_it_lights() {
    let (h, clock, drawn) = window();
    h.input(&wheel(-40.0));
    settle(&h, &clock);
    assert_eq!(drawn.get(), Some(5), "no move came, the wheel's own position is used");
}

#[test]
fn a_held_button_is_a_drag_and_is_not_hit_tested_again_by_a_scroll() {
    let (h, clock, drawn) = window();
    h.input(&InputEvent::MouseMoved { x: 50.0, y: 70.0 });
    h.input(&InputEvent::MouseDown { x: 50.0, y: 70.0, modifiers: InputModifiers::NONE });
    h.input(&wheel(-40.0));
    settle(&h, &clock);
    assert_eq!(drawn.get(), Some(3), "the row the press began on stays");
}

/// A host that remembers the place of the last pointer event it saw: the place its hover would follow.
struct Seen(Rc<Cell<(f32, f32)>>);

impl AppHost for Seen {
    fn layout(&mut self, _frame: CGRect, _cx: &mut HostCx) {}
    fn draw(&mut self, _c: &mut Canvas, _t: &DrawTheme, _cx: &mut HostCx) {}
    fn handle(&mut self, e: &InputEvent, _cx: &mut HostCx) -> bool {
        match *e {
            InputEvent::MouseMoved { x, y } => self.0.set((x, y)),
            // Takes the scroll, so the rows below stay put: no content moves and no epoch change hides the bug.
            InputEvent::Scroll { x, y, .. } => {
                self.0.set((x, y));
                return true;
            }
            _ => {}
        }
        false
    }
}

#[test]
fn a_held_gesture_place_does_not_steal_the_hover_from_a_pointer_that_moved_on() {
    use sq_draw::scroll::{ScrollGesture, ScrollPhase};
    let (h, _clock, _drawn) = window();
    let seen = Rc::new(Cell::new((0.0, 0.0)));
    h.with(|a| a.add_host(Box::new(Seen(Rc::clone(&seen)))));
    let glide =
        |phase| ScrollGesture { delta_y: -4.0, precise: true, phase, host_inertia: true, ..ScrollGesture::default() };
    let scroll = |x: f32, y: f32| InputEvent::Scroll { x, y, dx: 0.0, dy: -4.0, modifiers: InputModifiers::NONE };
    // The gesture begins over one list, the pointer moves to another panel while it glides, its end arrives there.
    h.with(|a| a.handle_with_gesture(&scroll(50.0, 70.0), glide(ScrollPhase::Began)));
    h.input(&InputEvent::MouseMoved { x: 300.0, y: 200.0 });
    h.with(|a| a.handle_with_gesture(&scroll(300.0, 200.0), glide(ScrollPhase::Ended)));
    h.turn();
    assert_eq!(seen.get(), (300.0, 200.0), "the last thing the hosts saw is the pointer, not the held place");
}
