//! MonitorPictureToolsTests of the Swift package: Create tool, caption press, Dynamic Zoom / Step window editors, the
//! angle tiles and the loupe on the canvas monitor.

use crate::angle_tile::{AngleTile, AngleTilePicture};
use crate::color_loupe::ColorLoupe;
use crate::create_tool_drag::CreateToolDrag;
use crate::monitor_panel::{MonitorPanel, PanelEvent, PanelWiring, PictureToolsHost};
use crate::monitor_panel_model::{MonitorEvent, SourceItem};
use crate::step_window_overlay::StepWindowOverlay;
use crate::test_support::{Rig, draw, panel};
use crate::transform_overlay::{Phase, TransformOverlay};
use crate::zoom_edit_overlay::{ZoomEditEvent, ZoomEditOverlay};
use sq_core_effects::dynamic_zoom::ZoomRect;
use sq_core_model::{ClipTransform, ShapeKind, StepWindow};
use sq_core_time::{Id, Vec2};
use sq_draw::InputModifiers;
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_draw::monitor::step_window_edit_geometry::StepWindowEditGeometry;
use sq_draw::monitor::transform_overlay_geometry::TransformOverlayGeometry;
use sq_draw::monitor::zoom_edit_geometry::ZoomEditGeometry;
use sq_draw::theme::DrawTheme;
use sq_draw::ui_cx::DrawCursor;
use sq_editor_session::EditorSession;
use sq_editor_session::es01_session_core::CreateToolMode;
use sq_editor_session::es02_timeline_ops::SnapResult;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use std::cell::RefCell;
use std::rc::Rc;

fn tools(mode: MonitorMode) -> MonitorPanel {
    let mut p = panel(mode);
    p.wiring = PanelWiring::all();
    p.set_sequence_size(CGSize::new(1920.0, 1080.0));
    p.has_picture = true;
    draw(&mut p);
    p
}

fn at(p: &MonitorPanel, fx: f64, fy: f64) -> CGPoint {
    let c = p.canvas_rect();
    CGPoint::new(c.min_x() + c.width * fx, c.min_y() + c.height * fy)
}

fn press_drag_release(p: &mut MonitorPanel, rig: &mut Rig, a: CGPoint, to: CGPoint) {
    rig.down(p, a.x, a.y, InputModifiers::NONE);
    rig.drag(p, to.x, to.y);
    rig.up(p, to.x, to.y);
}

fn shapes(p: &mut MonitorPanel) -> Vec<(ShapeKind, Vec2, Vec2)> {
    p.take_events()
        .into_iter()
        .filter_map(|e| if let PanelEvent::CreateShape(k, a, b) = e { Some((k, a, b)) } else { None })
        .collect()
}

#[test]
fn cursors_follow_the_tool_and_stay_during_drags() {
    let mut p = tools(MonitorMode::Program);
    let mut rig = Rig::new();
    let c = at(&p, 0.5, 0.5);
    p.create_mode_now = Some(CreateToolMode::Rectangle);
    rig.moved(&mut p, c.x, c.y);
    assert_eq!(rig.ui.hover.cursor, Some(DrawCursor::Crosshair));
    rig.down(&mut p, c.x, c.y, InputModifiers::NONE);
    assert_eq!(rig.ui.hover.cursor, Some(DrawCursor::Crosshair));
    rig.drag(&mut p, c.x + 30.0, c.y + 30.0);
    assert_eq!(rig.ui.hover.cursor, Some(DrawCursor::Crosshair));
    rig.up(&mut p, c.x + 30.0, c.y + 30.0);
    p.create_mode_now = Some(CreateToolMode::Text);
    rig.moved(&mut p, c.x, c.y);
    assert_eq!(rig.ui.hover.cursor, None);
    p.create_mode_now = None;
    rig.ui.now = 5.0;
    p.hand_tool_on = true;
    rig.down(&mut p, c.x, c.y, InputModifiers::NONE);
    assert_eq!(rig.ui.hover.cursor, Some(DrawCursor::ClosedHand));
    rig.drag(&mut p, c.x + 5.0, c.y);
    assert_eq!(rig.ui.hover.cursor, Some(DrawCursor::ClosedHand));
    rig.up(&mut p, c.x + 5.0, c.y);
    assert_eq!(rig.ui.hover.cursor, Some(DrawCursor::OpenHand));
}

#[test]
fn create_drag_makes_a_rectangle_in_sequence_pixels() {
    let mut p = tools(MonitorMode::Program);
    let mut rig = Rig::new();
    p.create_mode_now = Some(CreateToolMode::Rectangle);
    let (a, b) = (at(&p, 0.25, 0.25), at(&p, 0.75, 0.75));
    rig.down(&mut p, a.x, a.y, InputModifiers::NONE);
    rig.drag(&mut p, b.x, b.y);
    assert!(p.is_dragging());
    draw(&mut p);
    rig.up(&mut p, b.x, b.y);
    let ev = p.take_events();
    let made: Vec<(ShapeKind, Vec2, Vec2)> = ev
        .iter()
        .filter_map(|e| if let PanelEvent::CreateShape(k, a, b) = e { Some((*k, *a, *b)) } else { None })
        .collect();
    assert_eq!(made.len(), 1);
    assert_eq!(made[0].0, ShapeKind::Rectangle);
    assert!((made[0].1.x + 480.0).abs() < 3.0 && (made[0].1.y + 270.0).abs() < 3.0);
    assert!((made[0].2.x - 480.0).abs() < 3.0 && (made[0].2.y - 270.0).abs() < 3.0);
    assert!(ev.iter().all(|e| !matches!(e, PanelEvent::PickClip(_))));
    assert!(!p.is_dragging());
}

#[test]
fn create_click_makes_nothing_and_shift_makes_a_square() {
    let mut p = tools(MonitorMode::Program);
    let mut rig = Rig::new();
    p.create_mode_now = Some(CreateToolMode::Ellipse);
    let m = at(&p, 0.5, 0.5);
    rig.click(&mut p, m);
    assert!(shapes(&mut p).is_empty()); // a click makes nothing
    // Shift pressed after the press, on the drag event only: the live keys decide, not those of the press.
    let a = at(&p, 0.3, 0.3);
    rig.down(&mut p, a.x, a.y, InputModifiers::NONE);
    let shift = sq_draw::InputEvent::MouseDragged {
        x: (a.x + 100.0) as f32,
        y: (a.y + 40.0) as f32,
        modifiers: InputModifiers::SHIFT,
    };
    rig.send(&mut p, shift);
    rig.up(&mut p, a.x + 100.0, a.y + 40.0);
    let made = shapes(&mut p);
    assert!(made.len() == 1 && made[0].0 == ShapeKind::Ellipse);
    let size = made[0].2 - made[0].1;
    assert!((size.x - size.y).abs() < 0.5); // Shift: a circle
}

#[test]
fn freehand_stroke_and_esc_cancel() {
    let mut p = tools(MonitorMode::Program);
    let mut rig = Rig::new();
    p.create_mode_now = Some(CreateToolMode::Draw);
    let a = at(&p, 0.4, 0.4);
    rig.down(&mut p, a.x, a.y, InputModifiers::NONE);
    for i in 1..=10 {
        rig.drag(&mut p, a.x + f64::from(i) * 5.0, a.y + f64::from(i * i) * 0.5);
    }
    rig.up(&mut p, a.x + 50.0, a.y + 50.0);
    let strokes = |p: &mut MonitorPanel| -> Vec<(Vec<Vec2>, f64)> {
        p.take_events()
            .into_iter()
            .filter_map(|e| if let PanelEvent::CreateStroke(pts, t) = e { Some((pts, t)) } else { None })
            .collect()
    };
    let s = strokes(&mut p);
    assert_eq!(s.len(), 1);
    assert!(s[0].0.len() >= 5);
    assert!(s[0].1 > CreateToolDrag::STROKE_TOLERANCE); // view tolerance in sequence px (the view shrinks it)
    rig.down(&mut p, a.x, a.y, InputModifiers::NONE);
    rig.drag(&mut p, a.x + 60.0, a.y);
    assert!(rig.key(&mut p, sq_draw::InputKey::Escape));
    rig.up(&mut p, a.x + 60.0, a.y);
    assert!(strokes(&mut p).is_empty());
}

#[derive(Default)]
struct CaptionLog {
    began: Vec<Vec2>,
    moves: Vec<(Vec2, f64)>,
    ended: usize,
}

struct Captions(Rc<RefCell<CaptionLog>>);

impl PictureToolsHost for Captions {
    fn caption_hit_test(&self, _s: &EditorSession, p: Vec2) -> bool {
        p.y > 300.0 // the caption sits in the lower part of the picture
    }
    fn caption_drag_began(&mut self, _s: &mut EditorSession, p: Vec2) -> bool {
        self.0.borrow_mut().began.push(p);
        true
    }
    fn caption_drag_moved(&mut self, _s: &mut EditorSession, delta: Vec2, snap: f64) -> SnapResult {
        self.0.borrow_mut().moves.push((delta, snap));
        SnapResult::none()
    }
    fn caption_drag_ended(&mut self, _s: &mut EditorSession) {
        self.0.borrow_mut().ended += 1;
    }
}

#[test]
fn caption_drag_moves_with_snap_and_double_click_edits() {
    let mut p = tools(MonitorMode::Program);
    let mut rig = Rig::new();
    let log: Rc<RefCell<CaptionLog>> = Rc::default();
    p.captions = Some(Box::new(Captions(Rc::clone(&log))));
    rig.ui.now = 10.0;
    let a = at(&p, 0.5, 0.9);
    rig.down(&mut p, a.x, a.y, InputModifiers::NONE);
    rig.drag(&mut p, a.x + 1.0, a.y); // under 3 pt: still a click
    assert!(log.borrow().moves.is_empty());
    rig.drag(&mut p, a.x + 40.0, a.y);
    rig.up(&mut p, a.x + 40.0, a.y);
    assert!(log.borrow().began.len() == 1 && log.borrow().ended == 1);
    assert!(p.take_events().iter().all(|e| !matches!(e, PanelEvent::PickClip(_))));
    let k = p.canvas_rect().width / 1920.0;
    let (delta, snap) = log.borrow().moves.last().copied().unwrap_or((Vec2::ZERO, 0.0));
    assert!((delta.x - 40.0 / k).abs() < 0.5);
    assert!((snap - TransformOverlay::SNAP_DISTANCE / k).abs() < 0.01);
    rig.ui.now += 1.0;
    rig.click(&mut p, a);
    rig.ui.now += 0.2;
    rig.click(&mut p, a);
    let edits = |p: &mut MonitorPanel| {
        p.take_events().iter().filter(|e| matches!(e, PanelEvent::CaptionDoubleClick(_))).count()
    };
    assert_eq!(edits(&mut p), 1);
    let off = at(&p, 0.5, 0.2);
    rig.click(&mut p, off); // not on the caption: the pick
    assert!(p.take_events().iter().any(|e| matches!(e, PanelEvent::PickClip(_))));
}

fn layer(p: &MonitorPanel) -> ZoomEditGeometry {
    ZoomEditGeometry::new(TransformOverlayGeometry::new(
        p.sequence_size(),
        p.canvas_rect(),
        16.0 / 9.0,
        ClipTransform::IDENTITY,
        None,
    ))
}

#[test]
fn zoom_edit_drags_the_end_window_and_done_closes() {
    let mut p = tools(MonitorMode::Program);
    let mut rig = Rig::new();
    let mut z = ZoomEditOverlay::new();
    z.geometry = layer(&p);
    z.set_end(ZoomRect::centred(2.0, Vec2::new(0.5, 0.5)));
    p.zoom_edit = Some(z);
    draw(&mut p);
    let center = p.zoom_edit.as_ref().map(|z| z.geometry.centre_of(&z.end())).unwrap_or(CGPoint::ZERO);
    let to = CGPoint::new(center.x + p.canvas_rect().width * 0.1, center.y);
    press_drag_release(&mut p, &mut rig, center, to);
    let z = p.zoom_edit.as_mut().unwrap_or_else(|| panic!("zoom edit"));
    let ev: Vec<ZoomEditEvent> = std::mem::take(&mut z.events);
    let phases: Vec<Phase> =
        ev.iter().filter_map(|e| if let ZoomEditEvent::Change(ph, ..) = e { Some(*ph) } else { None }).collect();
    assert_eq!(phases, [Phase::Began, Phase::Changed, Phase::Ended]);
    assert!((z.end().x - 0.35).abs() < 0.01); // moved right by a tenth of the picture
    assert!(z.start.x.abs() < 1e-9);
    let d = z.done_rect();
    rig.click(&mut p, CGPoint::new(d.mid_x(), d.mid_y()));
    let done = |p: &mut MonitorPanel| -> usize {
        p.zoom_edit
            .as_mut()
            .map_or(0, |z| std::mem::take(&mut z.events).iter().filter(|e| **e == ZoomEditEvent::Done).count())
    };
    assert_eq!(done(&mut p), 1);
    assert!(rig.key(&mut p, sq_draw::InputKey::Escape)); // Esc closes too
    assert_eq!(done(&mut p), 1);
}

#[test]
fn zoom_edit_swallows_a_press_outside_its_windows() {
    let mut p = tools(MonitorMode::Program);
    let mut rig = Rig::new();
    let mut z = ZoomEditOverlay::new();
    z.geometry = layer(&p);
    z.start = ZoomRect::centred(2.0, Vec2::new(0.5, 0.5));
    z.set_end(ZoomRect::centred(4.0, Vec2::new(0.5, 0.5)));
    p.zoom_edit = Some(z);
    draw(&mut p);
    // A corner of the picture outside both windows: the transform overlay and the clip pick never see it (the Mac
    // overlay view covers the picture).
    let q = at(&p, 0.05, 0.9);
    let hit = p.zoom_edit.as_ref().and_then(|z| z.geometry.hit_test(q, &z.start, &z.end(), 8.0));
    assert!(hit.is_none());
    rig.click(&mut p, q);
    assert!(p.take_events().iter().all(|e| !matches!(e, PanelEvent::PickClip(_))));
    assert!(p.zoom_edit.is_some());
}

#[test]
fn zoom_field_scrub_sets_the_end_zoom() {
    let mut p = tools(MonitorMode::Program);
    let mut rig = Rig::new();
    let mut z = ZoomEditOverlay::new();
    z.geometry = layer(&p);
    p.zoom_edit = Some(z);
    draw(&mut p);
    let f = p.zoom_edit.as_ref().map(|z| z.field_rect()).unwrap_or_default();
    let f = CGPoint::new(f.mid_x(), f.mid_y());
    press_drag_release(&mut p, &mut rig, f, CGPoint::new(f.x + 20.0, f.y));
    let ends: Vec<ZoomRect> = p
        .zoom_edit
        .as_mut()
        .map(|z| std::mem::take(&mut z.events))
        .unwrap_or_default()
        .into_iter()
        .filter_map(|e| if let ZoomEditEvent::Change(_, _, end) = e { Some(end) } else { None })
        .collect();
    assert!(ends.last().is_some_and(|e| e.zoom() > 1.25));
}

#[test]
fn step_window_moves_and_passes_other_presses_on() {
    let mut p = tools(MonitorMode::Program);
    let mut rig = Rig::new();
    let mut s = StepWindowOverlay::new();
    s.geometry = StepWindowEditGeometry::new(layer(&p));
    let c = s.geometry.center_point(&s.step_window);
    p.step_window_edit = Some(s);
    press_drag_release(&mut p, &mut rig, c, CGPoint::new(c.x + 30.0, c.y));
    let s = p.step_window_edit.as_mut().unwrap_or_else(|| panic!("step window"));
    let phases: Vec<Phase> = std::mem::take(&mut s.events).into_iter().map(|e| e.0).collect();
    assert_eq!(phases, [Phase::Began, Phase::Changed, Phase::Ended]);
    assert!(s.step_window != StepWindow::default());
    let q = at(&p, 0.02, 0.02);
    rig.click(&mut p, q);
    assert!(p.take_events().iter().any(|e| matches!(e, PanelEvent::PickClip(_))));
}

#[test]
fn angle_tile_press_picks_that_angle() {
    let mut p = tools(MonitorMode::Source);
    let mut rig = Rig::new();
    p.model.source_items = vec![SourceItem { id: Id::from_u128(1), name: "Angles".into() }];
    p.model.angle_tiles = Some(
        (0..4).map(|i| AngleTile::new(&format!("Cam {}", i + 1), Some(AngleTilePicture::new(0)), i == 0)).collect(),
    );
    p.layout_px(sq_draw::Rect::new(0.0, 0.0, 800.0, 500.0), 1.0);
    draw(&mut p);
    let cells = p.angle_cells();
    assert_eq!(cells.len(), 4);
    rig.click(&mut p, CGPoint::new(cells[3].mid_x(), cells[3].mid_y()));
    let picked: Vec<usize> = p
        .model
        .take_events()
        .into_iter()
        .filter_map(|e| if let MonitorEvent::PickAngle(i) = e { Some(i) } else { None })
        .collect();
    assert_eq!(picked, [3]);
}

#[test]
fn color_loupe_flips_at_the_edges_and_draws() {
    let side = ColorLoupe::SIDE;
    let mut px = vec![[0u8; 3]; side * side];
    px[(side / 2) * side + side / 2] = [12, 200, 7];
    let l = ColorLoupe::new(side, side, px);
    let b = CGRect::new(0.0, 0.0, 800.0, 500.0);
    let near = ColorLoupe::frame(l.size(), CGPoint::new(100.0, 100.0), b);
    assert!(near.min_x() > 100.0 && near.min_y() > 100.0); // below right of the pointer
    let edge = ColorLoupe::frame(l.size(), CGPoint::new(790.0, 490.0), b);
    assert!(edge.max_x() < 790.0 && edge.max_y() < 490.0); // flipped above left near the corner
    assert!(edge.min_x() >= 0.0 && edge.max_x() <= 800.0 && edge.min_y() >= 0.0 && edge.max_y() <= 500.0);
    let mut c = sq_draw::canvas::Canvas::with_size(800.0, 500.0, None, 1.0);
    l.draw(&mut c, CGPoint::new(100.0, 100.0), b, &DrawTheme::default());
    assert!(!c.list.quads().is_empty());
}
