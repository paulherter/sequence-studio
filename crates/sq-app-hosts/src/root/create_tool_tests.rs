//! The Create tool on the Program monitor reaches the session (Swift `MonitorHost.createItem`): a drag adds the shape
//! as one undo step, at the right frame in sequence pixels, as long as the stored New Text Length.

use super::tests::{root, session};
use super::*;
use sq_core_model::ShapeKind;
use sq_draw::InputModifiers;
use sq_draw_shell::ShellHooks;
use sq_editor_session::{CreateToolMode, TimelineTool};

/// Clips of the active sequence, in track order.
fn clips(s: &EditorSession) -> Vec<sq_core_model::Clip> {
    s.active_timeline().map(|t| t.tracks.iter().flat_map(|k| k.clips().to_vec()).collect()).unwrap_or_default()
}

/// A root with a sequence and the Create tool in `mode`, laid out so the monitor shows its picture.
fn armed(mode: CreateToolMode) -> (AppRoot, crate::test_rig::Rig) {
    let mut s = session();
    s.add_sequence(None, None, None);
    let mut rig = crate::test_rig::Rig::new(s);
    let mut r = root().with_graphics(crate::GraphicsHost::new());
    {
        let t = r.timeline.inner().panel.tool_state_mut();
        t.tool = TimelineTool::Type;
        t.create_mode = mode;
    }
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    r.sync(&rig.session);
    (r, rig)
}

/// Press at the picture's fractions `from`, drag and release at `to`; the root answers the event.
fn drag(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, from: (f64, f64), to: (f64, f64)) {
    let c = r.monitor.panel.canvas_rect();
    let at = |f: (f64, f64)| ((c.min_x() + c.width * f.0) as f32, (c.min_y() + c.height * f.1) as f32);
    let (a, b) = (at(from), at(to));
    let none = InputModifiers::NONE;
    r.handle(&InputEvent::MouseDown { x: a.0, y: a.1, modifiers: none }, &mut rig.cx());
    r.handle(&InputEvent::MouseDragged { x: b.0, y: b.1, modifiers: none }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x: b.0, y: b.1 }, &mut rig.cx());
    r.pump(&mut rig.cx());
}

#[test]
fn a_create_drag_on_the_monitor_adds_the_shape_in_one_undo_step() {
    let (mut r, mut rig) = armed(CreateToolMode::Rectangle);
    let depth = rig.session.undo_depth();
    // Center to the right and down by a tenth of the picture: (0, 0) to (192, 108) sequence px of a 1920 x 1080 picture.
    drag(&mut r, &mut rig, (0.5, 0.5), (0.6, 0.6));
    let made = clips(&rig.session);
    assert_eq!(made.len(), 1, "one Graphic clip");
    let layers = &made[0].graphics().expect("a Graphic").layers;
    assert_eq!(layers.len(), 1);
    let p = layers[0].animation.position.value;
    assert!((p.x - 96.0).abs() < 2.0 && (p.y - 54.0).abs() < 2.0, "the box center is {p:?}");
    assert_eq!(rig.session.undo_depth(), depth + 1, "one undo step");
    assert!(rig.session.undo());
    assert!(clips(&rig.session).is_empty(), "undo removes the clip");
}

#[test]
fn the_new_clip_is_as_long_as_the_stored_new_text_length() {
    let (mut r, mut rig) = armed(CreateToolMode::Ellipse);
    let mut defaults = sq_editor_session::AppSettings::standard();
    defaults.default_text_seconds = 8;
    // Without a stored file the root uses 5 s; the stored value reaches it through `new_text_seconds`.
    assert_eq!(r.new_text_seconds(), 5);
    let dir = crate::test_rig::test_dir("sq-app-hosts-create-prefs");
    std::fs::create_dir_all(&dir).expect("dir");
    let store = crate::persist::FileDefaults::shared(&dir);
    let concrete = std::rc::Rc::clone(&store);
    let shared: sq_draw_shell::SharedDefaults = concrete;
    defaults.save(&mut sq_draw_shell::SharedView(shared));
    r = r.with_prefs_store(&dir, store);
    assert_eq!(r.new_text_seconds(), 8);
    drag(&mut r, &mut rig, (0.4, 0.4), (0.6, 0.6));
    let c = clips(&rig.session);
    let fd = rig.session.active_timeline().expect("sequence").frame_duration();
    assert_eq!(c[0].duration(), sq_core_time::Time::new(8, 1).snapped(fd));
}

#[test]
fn a_second_drag_adds_a_layer_to_the_selected_graphic_in_one_more_step() {
    let (mut r, mut rig) = armed(CreateToolMode::Rectangle);
    drag(&mut r, &mut rig, (0.3, 0.3), (0.4, 0.4));
    let depth = rig.session.undo_depth();
    r.sync(&rig.session);
    drag(&mut r, &mut rig, (0.6, 0.6), (0.7, 0.7));
    let made = clips(&rig.session);
    assert_eq!(made.len(), 1, "the same Graphic takes it");
    assert_eq!(made[0].graphics().expect("a Graphic").layers.len(), 2);
    assert_eq!(rig.session.undo_depth(), depth + 1);
}

#[test]
fn a_drawn_stroke_adds_a_path_layer() {
    let (mut r, mut rig) = armed(CreateToolMode::Draw);
    let c = r.monitor.panel.canvas_rect();
    let none = InputModifiers::NONE;
    let pt = |fx: f64, fy: f64| ((c.min_x() + c.width * fx) as f32, (c.min_y() + c.height * fy) as f32);
    let p0 = pt(0.3, 0.5);
    r.handle(&InputEvent::MouseDown { x: p0.0, y: p0.1, modifiers: none }, &mut rig.cx());
    for i in 1..=10 {
        let q = pt(0.3 + 0.04 * f64::from(i), 0.5 + 0.02 * f64::from(i % 3));
        r.handle(&InputEvent::MouseDragged { x: q.0, y: q.1, modifiers: none }, &mut rig.cx());
    }
    let q = pt(0.7, 0.5);
    r.handle(&InputEvent::MouseUp { x: q.0, y: q.1 }, &mut rig.cx());
    r.pump(&mut rig.cx());
    let made = clips(&rig.session);
    assert_eq!(made.len(), 1);
    assert_eq!(made[0].graphics().expect("a Graphic").layers.len(), 1);
}

#[test]
fn sequence_new_shape_takes_the_create_path_into_the_selected_graphic() {
    let (mut r, mut rig) = armed(CreateToolMode::Rectangle);
    drag(&mut r, &mut rig, (0.3, 0.3), (0.4, 0.4));
    r.sync(&rig.session);
    let depth = rig.session.undo_depth();
    let link = r.timeline_link.clone().expect("link");
    assert!(crate::TimelineHooks(link).on_new_shape(ShapeKind::Ellipse));
    r.pump(&mut rig.cx());
    let made = clips(&rig.session);
    assert_eq!(made.len(), 1, "the selected Graphic takes the shape");
    assert_eq!(made[0].graphics().expect("a Graphic").layers.len(), 2);
    assert_eq!(rig.session.undo_depth(), depth + 1);
}
