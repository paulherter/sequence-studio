//! A click on a text inside a Graphic on the Program monitor picks that text, not the whole Graphic (Premiere's way): the
//! click selects the item under the pointer (box, handles, drag moves it alone), empty canvas selects the Graphic, a
//! double-click edits the text with the caret at the click and Esc leaves the edit. Real presses through `AppRoot::handle`.

use super::tests::{root, session};
use super::*;
use crate::test_rig::Rig;
use sq_core_graphics::graphics_editing::GraphicsDocumentEditingExt;
use sq_core_time::{Id, Vec2};
use sq_draw::InputModifiers;
use sq_inspector_ui::graphics::panel_draw::GraphicsPanelDraw;
use std::collections::BTreeSet;

const NONE: InputModifiers = InputModifiers::NONE;

/// A root with a Graphic of two texts ("Left" and "Right", 800 sequence px apart) and no layer selected.
fn two_texts() -> (AppRoot, Rig, Id, Id, Id) {
    // Layout needs the bundled fonts (the Swift package folder, as sq-text's own tests use).
    sq_text::portable_font_match::set_fonts_root(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts"),
    );
    let mut s = session();
    s.add_sequence(None, None, None);
    let mut rig = Rig::new(s);
    let mut r = root().with_graphics(crate::GraphicsHost::new());
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let (clip, left, right) = {
        let g = &mut r.graphics.as_mut().expect("graphics host").panel().host.editor;
        let clip = g.new_graphics_clip(&mut rig.session).expect("graphic");
        let left = g.add_text_at(&mut rig.session, Vec2::new(-400.0, 0.0), "Left", None).expect("left");
        let right = g.add_text_at(&mut rig.session, Vec2::new(400.0, 0.0), "Right", None).expect("right");
        g.select(&mut rig.session, BTreeSet::new());
        (clip, left, right)
    };
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    (r, rig, clip, left, right)
}

/// The view point of a sequence point (px from the picture center, y down).
fn view(r: &AppRoot, p: Vec2) -> (f32, f32) {
    let c = r.monitor.panel.canvas_rect();
    let k = c.width / r.monitor.panel.layer_overlay.sequence_size().width;
    ((c.mid_x() + p.x * k) as f32, (c.mid_y() + p.y * k) as f32)
}

fn press(r: &mut AppRoot, rig: &mut Rig, from: (f32, f32), to: Option<(f32, f32)>) {
    r.handle(&InputEvent::MouseDown { x: from.0, y: from.1, modifiers: NONE }, &mut rig.cx());
    let end = to.unwrap_or(from);
    if to.is_some() {
        r.handle(&InputEvent::MouseDragged { x: end.0, y: end.1, modifiers: NONE }, &mut rig.cx());
    }
    r.handle(&InputEvent::MouseUp { x: end.0, y: end.1 }, &mut rig.cx());
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
}

fn selected_layers(rig: &Rig) -> BTreeSet<Id> {
    rig.session.graphic_layer_selection().map(|g| g.layers.clone()).unwrap_or_default()
}

/// The layer's bounds on the Graphic's canvas.
fn bounds(r: &mut AppRoot, rig: &Rig, id: Id) -> sq_core_graphics::graphics_editing::GraphicsRect {
    let g = &r.graphics.as_mut().expect("graphics host").panel().host.editor;
    let (doc, t, m) =
        (g.document(&rig.session).expect("doc"), g.local_time(&rig.session), g.text_measure(&rig.session));
    doc.bounds_of(id, t, Some(&m)).expect("bounds")
}

#[test]
fn a_click_on_a_text_of_the_selected_graphic_selects_that_text_only() {
    let (mut r, mut rig, clip, left, right) = two_texts();
    assert_eq!(rig.session.selection(), &BTreeSet::from([clip]));
    let at = view(&r, Vec2::new(-400.0, 0.0));
    press(&mut r, &mut rig, at, None);
    assert_eq!(selected_layers(&rig), BTreeSet::from([left]), "the click picks the text under it");
    assert_eq!(rig.session.selection(), &BTreeSet::from([clip]), "the Graphic stays the selected clip");
    let at = view(&r, Vec2::new(400.0, 0.0));
    press(&mut r, &mut rig, at, None);
    assert_eq!(selected_layers(&rig), BTreeSet::from([right]), "another text takes the selection over");
    assert!(!r.monitor.panel.text_field.is_editing(), "one click does not edit");
}

#[test]
fn a_click_on_empty_canvas_goes_back_to_the_whole_graphic() {
    let (mut r, mut rig, clip, left, _) = two_texts();
    let at = view(&r, Vec2::new(-400.0, 0.0));
    press(&mut r, &mut rig, at, None);
    assert_eq!(selected_layers(&rig), BTreeSet::from([left]));
    let at = view(&r, Vec2::new(0.0, 400.0));
    press(&mut r, &mut rig, at, None);
    assert!(selected_layers(&rig).is_empty(), "no text is selected any more");
    assert_eq!(rig.session.selection(), &BTreeSet::from([clip]), "the Graphic stays selected");
}

#[test]
fn a_click_on_a_text_with_nothing_selected_picks_the_graphic_and_the_text() {
    let (mut r, mut rig, clip, left, _) = two_texts();
    rig.session.select(BTreeSet::new(), BTreeSet::new());
    r.sync(&rig.session);
    let at = view(&r, Vec2::new(-400.0, 0.0));
    press(&mut r, &mut rig, at, None);
    assert_eq!(rig.session.selection(), &BTreeSet::from([clip]));
    assert_eq!(selected_layers(&rig), BTreeSet::from([left]));
}

#[test]
fn a_drag_on_a_text_moves_that_text_and_nothing_else() {
    let (mut r, mut rig, _, left, right) = two_texts();
    let (l0, r0) = (bounds(&mut r, &rig, left), bounds(&mut r, &rig, right));
    let from = view(&r, Vec2::new(-400.0, 0.0));
    let k = r.monitor.panel.canvas_rect().width / r.monitor.panel.layer_overlay.sequence_size().width;
    // 100 sequence px down and right.
    press(&mut r, &mut rig, from, Some((from.0 + (100.0 * k) as f32, from.1 + (100.0 * k) as f32)));
    let (l1, r1) = (bounds(&mut r, &rig, left), bounds(&mut r, &rig, right));
    assert!((l1.min_x - l0.min_x - 100.0).abs() < 2.0, "left moved right: {} -> {}", l0.min_x, l1.min_x);
    assert!((l1.min_y - l0.min_y - 100.0).abs() < 2.0, "left moved down: {} -> {}", l0.min_y, l1.min_y);
    assert_eq!(r1, r0, "the other text stays");
}

#[test]
fn a_double_click_on_a_text_edits_it_at_the_click_and_escape_leaves() {
    let (mut r, mut rig, _, left, _) = two_texts();
    // The left edge of the text: the caret goes there, not to the end.
    let edge = r
        .monitor
        .panel
        .layer_overlay
        .snapshot
        .outlines
        .iter()
        .find(|o| o.id == left)
        .map(|o| o.corners.iter().map(|c| c.x).fold(f64::INFINITY, f64::min));
    let edge = edge.expect("the text is outlined");
    let p = view(&r, Vec2::new(edge + 2.0, 0.0));
    rig.ui.now = 10.0;
    press(&mut r, &mut rig, p, None);
    assert_eq!(selected_layers(&rig), BTreeSet::from([left]), "the first click picks the text");
    rig.ui.now += 0.2;
    press(&mut r, &mut rig, p, None);
    assert!(r.monitor.panel.text_field.is_editing(), "the second click opens the field");
    assert_eq!(r.monitor.panel.text_field.text(), "Left");
    let caret = r.monitor.panel.text_field.edit().map(|e| e.caret());
    assert!(caret.is_some_and(|c| c < 4), "the caret sits where the click was, not at the end: {caret:?}");
    r.handle(&InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: NONE }, &mut rig.cx());
    r.pump(&mut rig.cx());
    assert!(!r.monitor.panel.text_field.is_editing(), "Esc leaves the edit");
}

#[test]
fn a_double_click_on_a_text_row_of_the_graphics_panel_edits_that_text_and_escape_leaves() {
    let (mut r, mut rig, clip, left, _) = two_texts();
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    r.dock.show(PanelID::Graphics);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let graphics = r.graphics.as_mut().expect("graphics host");
    let origin = graphics.frame();
    assert!(origin.width > 0.0, "the Graphics panel is laid out");
    let panel = graphics.panel();
    let i = panel.list().rows().iter().position(|row| row.layer_id() == Some(left)).expect("the text has a row");
    let row = panel.list().row_frame(i);
    let p = (
        (origin.x + row.x + row.width * 0.5) as f32,
        (origin.y + GraphicsPanelDraw::HEADER_HEIGHT + row.mid_y()) as f32,
    );
    rig.ui.now = 10.0;
    press(&mut r, &mut rig, p, None);
    assert_eq!(selected_layers(&rig), BTreeSet::from([left]), "the first click selects the text layer");
    assert!(!r.monitor.panel.text_field.is_editing(), "one click does not edit");
    rig.ui.now += 0.2;
    press(&mut r, &mut rig, p, None);
    assert!(r.monitor.panel.text_field.is_editing(), "the second click opens the same field as on the monitor");
    assert_eq!(r.monitor.panel.text_field.text(), "Left");
    assert_eq!(rig.session.selection(), &BTreeSet::from([clip]), "the Graphic stays the selected clip");
    assert!(
        r.graphics.as_mut().is_some_and(|g| g.panel().list().rename_field().is_none()),
        "a text row edits its text instead of renaming"
    );
    r.handle(&InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: NONE }, &mut rig.cx());
    r.pump(&mut rig.cx());
    assert!(!r.monitor.panel.text_field.is_editing(), "Esc leaves the edit");
}

/// The texts the monitor draws as selected (box and handles).
fn outlined(r: &AppRoot, rig: &Rig) -> BTreeSet<Id> {
    let snap = r.monitor.panel.layer_overlay.source.as_ref().expect("layer source").snapshot(&rig.session);
    snap.outlines.iter().filter(|o| o.is_selected).map(|o| o.id).collect()
}

/// Controls' Layer popup choice and the item its rows edit, as of the last frame.
fn controls_item(r: &AppRoot) -> (Option<Id>, Option<Id>) {
    r.inspector.shown_graphic_item()
}

#[test]
fn a_pick_on_the_monitor_shows_that_layer_in_controls_and_an_empty_click_goes_back_to_the_whole_graphic() {
    let (mut r, mut rig, _, left, right) = two_texts();
    assert_eq!(controls_item(&r), (None, None), "nothing picked: Controls shows the whole graphic");
    let at = view(&r, Vec2::new(-400.0, 0.0));
    press(&mut r, &mut rig, at, None);
    assert_eq!(controls_item(&r), (Some(left), Some(left)), "the picked text is the Layer in Controls");
    let at = view(&r, Vec2::new(400.0, 0.0));
    press(&mut r, &mut rig, at, None);
    assert_eq!(controls_item(&r), (Some(right), Some(right)), "another text takes Controls over");
    let at = view(&r, Vec2::new(0.0, 400.0));
    press(&mut r, &mut rig, at, None);
    assert_eq!(controls_item(&r), (None, None), "empty canvas: Whole graphic again");
}

#[test]
fn a_layer_picked_in_controls_is_the_selected_text_on_the_monitor_and_in_the_graphics_panel() {
    let (mut r, mut rig, _, left, right) = two_texts();
    r.inspector.sections().layer_picked(Some(right));
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
    assert_eq!(outlined(&r, &rig), BTreeSet::from([right]), "the monitor outlines the picked text");
    let panel = r.graphics.as_mut().expect("graphics host").panel();
    assert_eq!(panel.host.editor.selected_layers(&rig.session), &BTreeSet::from([right]), "so does the Graphics panel");
    assert_eq!(controls_item(&r), (Some(right), Some(right)));
    r.inspector.sections().layer_picked(Some(left));
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
    assert_eq!(outlined(&r, &rig), BTreeSet::from([left]));
    r.inspector.sections().layer_picked(None);
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
    assert!(outlined(&r, &rig).is_empty(), "Whole graphic clears the outline");
    assert_eq!(controls_item(&r), (None, None));
}

/// One wheel notch (`dy` < 0 scrolls the content up) at a window point, after the pointer moved there.
fn wheel_at(r: &mut AppRoot, rig: &mut Rig, at: (f32, f32), dy: f32) {
    r.handle(&InputEvent::MouseMoved { x: at.0, y: at.1 }, &mut rig.cx());
    r.handle(&InputEvent::Scroll { x: at.0, y: at.1, dx: 0.0, dy, modifiers: NONE }, &mut rig.cx());
    r.pump(&mut rig.cx());
}

#[test]
fn the_wheel_scrolls_the_graphics_panel_rows_when_a_text_is_selected() {
    let (mut r, mut rig, _, left, _) = two_texts();
    r.dock.show(PanelID::Graphics);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    r.graphics.as_mut().expect("graphics host").panel().host.editor.select(&mut rig.session, BTreeSet::from([left]));
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let frame = r.graphics.as_ref().expect("graphics host").frame();
    assert!(frame.height > 0.0, "the Graphics panel is laid out");
    // Over the property rows (below the layer list, which scrolls only its own rows like the Swift panel) each notch
    // moves the rows on.
    let at = (frame.mid_x() as f32, (frame.y + frame.height * 0.9) as f32);
    let mut offsets = vec![0.0];
    for _ in 0..2 {
        wheel_at(&mut r, &mut rig, at, -20.0);
        offsets.push(r.graphics.as_mut().expect("graphics host").panel().form_scroll());
    }
    assert!(offsets.windows(2).all(|w| w[1] > w[0]), "every notch over the rows moved them on: {offsets:?}");
}
