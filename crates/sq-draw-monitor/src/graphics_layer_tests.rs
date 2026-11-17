//! GraphicsLayerOverlayTests and MonitorHandToolTests of the Swift package.

use crate::graphics_layer_overlay::{
    GraphicsLayerGuides, GraphicsLayerOutline, GraphicsLayerOverlay, GraphicsLayerSnapshot, GraphicsLayerSource,
    ResizeRequest,
};
use crate::monitor_panel::{MonitorPanel, PanelEvent};
use crate::test_support::{Rig, draw, panel};
use sq_core_edit::viewer_zoom::ViewerZoom;
use sq_core_graphics::graphics_editing::GraphicsCorner;
use sq_core_time::{Id, Vec2};
use sq_draw::InputModifiers;
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_draw::ui_cx::DrawCursor;
use sq_editor_session::EditorSession;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;

fn text() -> Id {
    Id::from_u128(1)
}
fn shape() -> Id {
    Id::from_u128(2)
}

struct State {
    selection: BTreeSet<Id>,
    moved: Vec2,
    move_start: Option<Vec2>,
    gestures: usize,
    resized: Vec<(Id, GraphicsCorner, Vec2)>,
}

/// A fake graphic: two layers (a text near the center, a shape below it), edits recorded.
struct FakeLayers(Rc<RefCell<State>>);

fn boxed(cx: f64, cy: f64, w: f64, h: f64) -> Vec<Vec2> {
    vec![
        Vec2::new(cx - w / 2.0, cy - h / 2.0),
        Vec2::new(cx + w / 2.0, cy - h / 2.0),
        Vec2::new(cx + w / 2.0, cy + h / 2.0),
        Vec2::new(cx - w / 2.0, cy + h / 2.0),
    ]
}

fn text_box() -> Vec<Vec2> {
    boxed(100.0, 0.0, 200.0, 80.0)
}

impl GraphicsLayerSource for FakeLayers {
    fn snapshot(&self, _s: &EditorSession) -> GraphicsLayerSnapshot {
        let st = self.0.borrow();
        let outlines = vec![
            GraphicsLayerOutline {
                id: shape(),
                corners: boxed(-300.0, 0.0, 200.0, 200.0),
                is_selected: st.selection.contains(&shape()),
            },
            GraphicsLayerOutline { id: text(), corners: text_box(), is_selected: st.selection.contains(&text()) },
        ];
        let handled = if st.selection.len() == 1 {
            st.selection.iter().next().and_then(|id| outlines.iter().find(|o| o.id == *id).cloned())
        } else {
            None
        };
        GraphicsLayerSnapshot { outlines, handled, selection: st.selection.clone(), is_drawing: false }
    }
    fn layer_at(&self, _s: &EditorSession, p: Vec2) -> Option<Id> {
        if (p.x - 100.0).abs() <= 100.0 && p.y.abs() <= 40.0 {
            return Some(text());
        }
        if (p.x + 300.0).abs() <= 100.0 && p.y.abs() <= 100.0 {
            return Some(shape());
        }
        None
    }
    fn layer_below(&self, _s: &EditorSession, _current: Option<Id>, _p: Vec2) -> Option<Id> {
        None
    }
    fn layers_in_rect(&self, s: &EditorSession, a: Vec2, b: Vec2) -> BTreeSet<Id> {
        let (lo, hi) = (Vec2::new(a.x.min(b.x), a.y.min(b.y)), Vec2::new(a.x.max(b.x), a.y.max(b.y)));
        self.snapshot(s)
            .outlines
            .iter()
            .filter(|o| {
                let xs = o.corners.iter().map(|c| c.x);
                let ys = o.corners.iter().map(|c| c.y);
                xs.clone().fold(f64::MIN, f64::max) >= lo.x
                    && xs.fold(f64::MAX, f64::min) <= hi.x
                    && ys.clone().fold(f64::MIN, f64::max) >= lo.y
                    && ys.fold(f64::MAX, f64::min) <= hi.y
            })
            .map(|o| o.id)
            .collect()
    }
    fn select(&mut self, _s: &mut EditorSession, ids: BTreeSet<Id>) {
        self.0.borrow_mut().selection = ids;
    }
    fn begin_gesture(&mut self, _s: &mut EditorSession) {
        self.0.borrow_mut().gestures += 1;
    }
    fn begin_move(&mut self, _s: &mut EditorSession, p: Vec2, _view_scale: f64) {
        self.0.borrow_mut().move_start = Some(p);
    }
    fn move_to(&mut self, _s: &mut EditorSession, p: Vec2, _snapping: bool) -> GraphicsLayerGuides {
        let mut st = self.0.borrow_mut();
        let start = st.move_start.unwrap_or(p);
        st.moved = p - start;
        GraphicsLayerGuides::default()
    }
    fn resize(&mut self, _s: &mut EditorSession, req: &ResizeRequest) -> GraphicsLayerGuides {
        self.0.borrow_mut().resized.push((req.id, req.corner, req.to));
        GraphicsLayerGuides::default()
    }
    fn add_path(&mut self, _s: &mut EditorSession, _points: &[Vec2]) {}
}

fn canvas_rect() -> CGRect {
    CGRect::new(100.0, 50.0, 960.0, 540.0) // 0.5 view points per sequence px
}

impl State {
    fn new() -> State {
        State { selection: BTreeSet::new(), moved: Vec2::ZERO, move_start: None, gestures: 0, resized: Vec::new() }
    }
}

fn make() -> (GraphicsLayerOverlay, Rc<RefCell<State>>, Rig) {
    let st = Rc::new(RefCell::new(State::new()));
    let rig = Rig::new();
    let mut o = GraphicsLayerOverlay::new();
    o.source = Some(Box::new(FakeLayers(Rc::clone(&st))));
    o.is_shown = true;
    o.set_sequence_size(CGSize::new(1920.0, 1080.0));
    o.refresh(&rig.session);
    (o, st, rig)
}

fn at(q: Vec2) -> CGPoint {
    let c = canvas_rect();
    CGPoint::new(c.mid_x() + q.x * 0.5, c.mid_y() + q.y * 0.5)
}

#[test]
fn click_on_text_selects_only_that_layer() {
    let (mut o, st, mut rig) = make();
    assert!(o.mouse_down(&mut rig.session, at(Vec2::new(100.0, 0.0)), InputModifiers::NONE, canvas_rect()));
    assert_eq!(st.borrow().selection, BTreeSet::from([text()]));
    o.mouse_up(&mut rig.session);
    assert_eq!(st.borrow().selection, BTreeSet::from([text()])); // a click without movement keeps the pick
}

#[test]
fn drag_moves_the_layer_by_sequence_pixels() {
    let (mut o, st, mut rig) = make();
    o.mouse_down(&mut rig.session, at(Vec2::new(100.0, 0.0)), InputModifiers::NONE, canvas_rect());
    o.mouse_dragged(&mut rig.session, at(Vec2::new(160.0, 30.0)), None);
    assert!((st.borrow().moved.x - 60.0).abs() < 1e-6 && (st.borrow().moved.y - 30.0).abs() < 1e-6);
    assert_eq!(st.borrow().gestures, 1);
    assert!(o.is_dragging());
    o.mouse_up(&mut rig.session);
    assert!(!o.is_dragging());
}

#[test]
fn corner_handle_of_the_selected_layer_resizes() {
    let (mut o, st, mut rig) = make();
    st.borrow_mut().selection = BTreeSet::from([text()]);
    o.refresh(&rig.session);
    let corner = text_box()[2];
    assert!(o.mouse_down(&mut rig.session, at(corner), InputModifiers::NONE, canvas_rect()));
    o.mouse_dragged(&mut rig.session, at(Vec2::new(corner.x + 40.0, corner.y + 20.0)), None);
    let st = st.borrow();
    assert!(st.resized.len() == 1 && st.resized[0].0 == text() && st.resized[0].1 == GraphicsCorner::BottomRight);
    assert!((st.resized[0].2.x - (corner.x + 40.0)).abs() < 1e-6);
}

#[test]
fn shift_toggles_and_empty_canvas_clears_only_with_a_selection() {
    let (mut o, st, mut rig) = make();
    let empty = at(Vec2::new(500.0, 300.0));
    assert!(!o.mouse_down(&mut rig.session, empty, InputModifiers::NONE, canvas_rect())); // nothing selected: falls to the clip box
    st.borrow_mut().selection = BTreeSet::from([shape()]);
    o.refresh(&rig.session);
    o.mouse_down(&mut rig.session, at(Vec2::new(100.0, 0.0)), InputModifiers::SHIFT, canvas_rect());
    assert_eq!(st.borrow().selection, BTreeSet::from([shape(), text()]));
    o.mouse_up(&mut rig.session);
    assert!(o.mouse_down(&mut rig.session, empty, InputModifiers::NONE, canvas_rect())); // a selection owns the empty canvas
    o.mouse_up(&mut rig.session);
    assert!(st.borrow().selection.is_empty());
}

#[test]
fn marquee_selects_touched_layers() {
    let (mut o, st, mut rig) = make();
    st.borrow_mut().selection = BTreeSet::from([shape()]);
    o.refresh(&rig.session);
    o.mouse_down(&mut rig.session, at(Vec2::new(-100.0, -200.0)), InputModifiers::NONE, canvas_rect());
    o.mouse_dragged(&mut rig.session, at(Vec2::new(400.0, 200.0)), None);
    assert_eq!(st.borrow().selection, BTreeSet::from([text()]));
    o.mouse_up(&mut rig.session);
}

#[test]
fn hidden_overlay_takes_nothing_and_move_cursor_only_over_the_selected_layer() {
    let (mut o, st, mut rig) = make();
    st.borrow_mut().selection = BTreeSet::from([text()]);
    o.refresh(&rig.session);
    assert_eq!(o.hover_cursor(at(Vec2::new(100.0, 0.0)), canvas_rect()), Some(DrawCursor::Move));
    assert_eq!(o.hover_cursor(at(Vec2::new(-300.0, 0.0)), canvas_rect()), None);
    o.is_shown = false;
    assert!(!o.mouse_down(&mut rig.session, at(Vec2::new(100.0, 0.0)), InputModifiers::NONE, canvas_rect()));
}

#[test]
fn panel_routes_a_layer_press_before_the_clip_box() {
    let mut p = panel(MonitorMode::Program);
    let mut rig = Rig::new();
    p.set_sequence_size(CGSize::new(1920.0, 1080.0));
    p.has_picture = true;
    draw(&mut p);
    let st = Rc::new(RefCell::new(State::new()));
    p.layer_overlay.source = Some(Box::new(FakeLayers(Rc::clone(&st))));
    p.layer_overlay.is_shown = true;
    p.layer_overlay.refresh(&rig.session);
    p.overlay.is_shown = true; // the clip's own box covers the whole canvas
    let r = p.canvas_rect();
    let k = r.width / 1920.0;
    let pt = CGPoint::new(r.mid_x() + 100.0 * k, r.mid_y());
    rig.down(&mut p, pt.x, pt.y, InputModifiers::NONE);
    assert_eq!(st.borrow().selection, BTreeSet::from([text()]));
    assert!(p.layer_overlay.is_dragging());
    assert!(!p.overlay.is_dragging());
    rig.up(&mut p, pt.x, pt.y);
    assert!(p.take_events().iter().all(|e| !matches!(e, PanelEvent::PickClip(_))));
}

// MonitorHandToolTests

fn program() -> MonitorPanel {
    let mut p = panel(MonitorMode::Program);
    p.set_sequence_size(CGSize::new(1920.0, 1080.0));
    p.has_picture = true;
    draw(&mut p);
    p
}

#[test]
fn hand_drag_pans_the_zoomed_picture_and_does_not_pick() {
    let mut p = program();
    let mut rig = Rig::new();
    p.hand_tool_on = true;
    p.zoom_gesture(ViewerZoom::View { scale: 1.0, center_x: 0.0, center_y: 0.0 });
    p.take_events();
    let a = CGPoint::new(p.slot().mid_x(), p.slot().mid_y());
    rig.down(&mut p, a.x, a.y, InputModifiers::NONE);
    assert!(p.is_dragging());
    rig.drag(&mut p, a.x - 50.0, a.y);
    let ViewerZoom::View { center_x, .. } = p.viewer_zoom() else { panic!("not panned") };
    assert!(center_x > 0.0);
    rig.up(&mut p, a.x - 50.0, a.y);
    assert!(!p.is_dragging());
    assert!(p.take_events().iter().all(|e| !matches!(e, PanelEvent::PickClip(_))));
}

#[test]
fn hand_double_click_fits_the_picture() {
    let mut p = program();
    let mut rig = Rig::new();
    p.hand_tool_on = true;
    p.zoom_gesture(ViewerZoom::View { scale: 1.0, center_x: 100.0, center_y: 0.0 });
    let a = CGPoint::new(p.slot().mid_x(), p.slot().mid_y());
    for _ in 0..2 {
        rig.down(&mut p, a.x, a.y, InputModifiers::NONE);
        rig.up(&mut p, a.x, a.y);
        rig.ui.now += 0.1;
    }
    assert!(p.viewer_zoom().is_fit());
}
