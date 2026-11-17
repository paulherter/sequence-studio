//! Tests of the Graphics host: the panel reads and edits the session of the host context, not its stand-in.

use super::*;
use crate::test_rig::Rig;
use sq_core_model::ShapeKind;
use sq_core_time::SequentialIds;
use sq_draw::InputKey;
use sq_inspector_ui::graphics::panel_draw::ColorTarget;
use sq_inspector_ui::text::block_draw::Layer;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-graphics-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

/// A host over a session that holds a Graphic with three shapes, the Graphic selected.
fn with_graphic() -> (GraphicsHost, Rig) {
    let mut host = GraphicsHost::new();
    let mut rig = Rig::new(session());
    host.panel().with_session(&mut rig.session, |p| {
        assert!(p.host.editor.new_graphics_clip(&mut p.host.session).is_some());
        for k in [ShapeKind::Rectangle, ShapeKind::Ellipse, ShapeKind::Line] {
            p.host.editor.add_shape(&mut p.host.session, k);
        }
    });
    (host, rig)
}

fn frame() -> CGRect {
    CGRect { x: 40.0, y: 20.0, width: 320.0, height: 480.0 }
}

#[test]
fn the_panel_shows_the_selected_graphics_layers() {
    let (mut host, mut rig) = with_graphic();
    host.layout(frame(), &mut rig.cx());
    assert!(host.panel().structure_key().is_some());
    let layers = host
        .panel()
        .with_session(&mut rig.session, |p| p.host.editor.document(&p.host.session).map(|d| d.layers.len()));
    assert_eq!(layers, Some(3));
    let mut c = Canvas::with_size(400.0, 520.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
}

#[test]
fn a_key_edits_the_context_session_and_hands_it_back() {
    let (mut host, mut rig) = with_graphic();
    host.layout(frame(), &mut rig.cx());
    let command_a = InputEvent::KeyDown { key: InputKey::Character('a'), modifiers: InputModifiers::COMMAND };
    assert!(host.handle(&command_a, &mut rig.cx()));
    let selected =
        host.panel().with_session(&mut rig.session, |p| p.host.editor.selected_layers(&p.host.session).len());
    assert_eq!(selected, 3);
    assert_eq!(rig.session.graphic_layer_selection().map(|g| g.layers.len()), Some(3));
}

#[test]
fn a_press_outside_the_frame_is_not_taken() {
    let (mut host, mut rig) = with_graphic();
    host.layout(frame(), &mut rig.cx());
    let outside = InputEvent::MouseDown { x: 10.0, y: 10.0, modifiers: InputModifiers::default() };
    assert!(!host.handle(&outside, &mut rig.cx()));
    let inside = InputEvent::MouseDown { x: 100.0, y: 60.0, modifiers: InputModifiers::default() };
    assert!(host.handle(&inside, &mut rig.cx()));
}

fn pick(host: &mut GraphicsHost, rig: &mut Rig) {
    let anchor = CGRect { x: 10.0, y: 10.0, width: 24.0, height: 14.0 };
    let current = sq_core_model::EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 };
    host.answer(PanelRequest::PickColor { current, anchor, target: ColorTarget::Form(0) }, &mut rig.cx());
}

#[test]
fn a_color_request_opens_the_picker_and_a_press_outside_closes_it() {
    let (mut host, mut rig) = with_graphic();
    host.set_window(CGRect { x: 0.0, y: 0.0, width: 800.0, height: 600.0 });
    host.layout(frame(), &mut rig.cx());
    pick(&mut host, &mut rig);
    assert!(host.has_popover());
    let mut c = Canvas::with_size(800.0, 600.0, None, 1.0);
    host.draw_popover(&mut c, &DrawTheme::default(), &mut rig.cx());
    assert!(!c.list.quads().is_empty());
    let outside = InputEvent::MouseDown { x: 790.0, y: 590.0, modifiers: InputModifiers::default() };
    assert!(!host.handle_popover(&outside, &mut rig.cx()), "a press elsewhere closes it and goes on to the panel");
    assert!(!host.has_popover());
    assert!(!host.handle_popover(&outside, &mut rig.cx()), "no popover, nothing taken");
}

#[test]
fn the_eyedropper_arms_and_a_click_outside_the_picture_ends_it() {
    let (host, mut rig) = with_graphic();
    let dropper = Eyedropper::default();
    let mut host = host.with_eyedropper(dropper.clone());
    assert!(host.panel().can_sample_screen_color, "the text block shows its eyedropper buttons");
    host.answer(PanelRequest::SampleColor(Layer::Fill), &mut rig.cx());
    assert!(dropper.is_armed());
    assert!(matches!(rig.events.last(), Some(AppEvent::Status(_))));
    let image = sq_draw::RgbaImage { width: 1, height: 1, pixels: vec![255, 0, 0, 255] };
    assert!(dropper.offer(Some(&image), CGRect::new(0.0, 0.0, 10.0, 10.0), 5.0, 5.0));
    host.pump(&mut rig.cx());
    assert!(!dropper.is_armed());
    assert!(host.take_requests().is_empty(), "pickers never reach the root");
}

#[test]
fn without_a_dropper_the_text_eyedropper_says_so() {
    let (mut host, mut rig) = with_graphic();
    host.answer(PanelRequest::SampleColor(Layer::Fill), &mut rig.cx());
    assert!(matches!(rig.events.last(), Some(AppEvent::Status(s)) if s.contains("not available")));
}

#[test]
fn alt_pressed_mid_drag_copies_the_dragged_layer() {
    let (mut host, mut rig) = with_graphic();
    host.layout(frame(), &mut rig.cx());
    let down = InputEvent::MouseDown { x: 100.0, y: 88.0, modifiers: InputModifiers::NONE };
    assert!(host.handle(&down, &mut rig.cx()));
    host.handle(&InputEvent::dragged(100.0, 118.0), &mut rig.cx());
    assert!(!host.panel().is_copying_layer(), "no key held on the drag");
    let alt = InputEvent::MouseDragged { x: 100.0, y: 128.0, modifiers: InputModifiers::OPTION };
    host.handle(&alt, &mut rig.cx());
    assert!(host.panel().is_copying_layer(), "Alt pressed after the press shows on the drag");
}
