//! The Type tool and the double-click on text on the Program monitor reach the session (Swift `MonitorTextHost`): a click
//! makes point text, a drag area text, a double-click edits the text clip or the caption under the pointer; an empty new text
//! leaves no undo trace, a new one with text is one "Add Text" step.

use super::tests::{root, session};
use super::*;
use sq_draw::InputModifiers;
use sq_editor_session::{CreateToolMode, TimelineTool};

fn clips(s: &EditorSession) -> Vec<sq_core_model::Clip> {
    s.active_timeline().map(|t| t.tracks.iter().flat_map(|k| k.clips().to_vec()).collect()).unwrap_or_default()
}

/// A root with a sequence and the given tool, laid out so the monitor shows its picture.
fn armed(tool: TimelineTool) -> (AppRoot, crate::test_rig::Rig) {
    // Layout needs the bundled fonts (the Swift package folder, as sq-text's own tests use).
    sq_text::portable_font_match::set_fonts_root(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts"),
    );
    let mut s = session();
    s.add_sequence(None, None, None);
    let mut rig = crate::test_rig::Rig::new(s);
    let mut r = root().with_graphics(crate::GraphicsHost::new());
    {
        let t = r.timeline.inner().panel.tool_state_mut();
        t.tool = tool;
        t.create_mode = CreateToolMode::Text;
    }
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    r.sync(&rig.session);
    (r, rig)
}

fn at(r: &AppRoot, f: (f64, f64)) -> (f32, f32) {
    let c = r.monitor.panel.canvas_rect();
    ((c.min_x() + c.width * f.0) as f32, (c.min_y() + c.height * f.1) as f32)
}

fn press(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, from: (f32, f32), to: Option<(f32, f32)>) {
    let none = InputModifiers::NONE;
    r.handle(&InputEvent::MouseDown { x: from.0, y: from.1, modifiers: none }, &mut rig.cx());
    let end = to.unwrap_or(from);
    if to.is_some() {
        r.handle(&InputEvent::MouseDragged { x: end.0, y: end.1, modifiers: none }, &mut rig.cx());
    }
    r.handle(&InputEvent::MouseUp { x: end.0, y: end.1 }, &mut rig.cx());
    r.pump(&mut rig.cx());
}

fn key(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, key: sq_draw::InputKey) {
    r.handle(&InputEvent::KeyDown { key, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.pump(&mut rig.cx());
}

fn text_of(clip: &sq_core_model::Clip) -> String {
    sq_text::text_generator::TextGenerator::decode(clip.generator.as_ref().expect("text clip")).expect("decodes").0.text
}

#[test]
fn a_type_click_makes_point_text_in_one_undo_step_and_the_field_opens() {
    let (mut r, mut rig) = armed(TimelineTool::Type);
    let depth = rig.session.undo_depth();
    let p = at(&r, (0.5, 0.5));
    press(&mut r, &mut rig, p, None);
    assert!(r.monitor.panel.text_field.is_editing(), "the field is open on the new text");
    let made = clips(&rig.session);
    assert_eq!(made.len(), 1, "one Graphic clip");
    let layers = &made[0].graphics().expect("a Graphic").layers;
    assert_eq!(layers.len(), 1);
    // Esc ends the edit: the text stays, the whole add is one undo step.
    key(&mut r, &mut rig, sq_draw::InputKey::Escape);
    assert!(!r.monitor.panel.text_field.is_editing());
    assert_eq!(clips(&rig.session).len(), 1);
    assert_eq!(rig.session.undo_depth(), depth + 1, "one undo step");
    assert!(rig.session.undo());
    assert!(clips(&rig.session).is_empty());
}

#[test]
fn typing_replaces_the_new_text_and_an_empty_new_text_leaves_no_trace() {
    let (mut r, mut rig) = armed(TimelineTool::Type);
    let depth = rig.session.undo_depth();
    let p = at(&r, (0.5, 0.5));
    press(&mut r, &mut rig, p, None);
    // The new text is selected: Backspace empties it, ending it then withdraws everything.
    key(&mut r, &mut rig, sq_draw::InputKey::Backspace);
    key(&mut r, &mut rig, sq_draw::InputKey::Escape);
    assert!(clips(&rig.session).is_empty(), "an empty new text leaves no clip");
    assert_eq!(rig.session.undo_depth(), depth, "and no undo step");
}

#[test]
fn a_type_drag_makes_area_text() {
    let (mut r, mut rig) = armed(TimelineTool::Type);
    let (a, b) = (at(&r, (0.25, 0.25)), at(&r, (0.75, 0.75)));
    press(&mut r, &mut rig, a, Some(b));
    let made = clips(&rig.session);
    assert_eq!(made.len(), 1);
    let layer = &made[0].graphics().expect("a Graphic").layers[0];
    let sq_core_model::GraphicsContent::Text { generator } = &layer.content else { panic!("a text layer") };
    let template = sq_text::text_generator::TextGenerator::decode(generator).expect("decodes").0;
    assert!(template.box_.is_some(), "area text has a box");
}

#[test]
fn a_double_click_on_a_text_clip_edits_it() {
    let (mut r, mut rig) = armed(TimelineTool::Selection);
    let template = sq_text::text_template::TextTemplate::new("Title", "Hello", Default::default());
    let id =
        rig.session.add_text_clip(&template, None, None, sq_core_time::Time::seconds(5), None, false).expect("clip");
    rig.session.set_selection([id].into(), Default::default());
    r.sync(&rig.session);
    let p = at(&r, (0.5, 0.5));
    rig.ui.now = 10.0;
    press(&mut r, &mut rig, p, None);
    rig.ui.now += 0.2;
    press(&mut r, &mut rig, p, None);
    assert!(r.monitor.panel.text_field.is_editing(), "the second press opens the field");
    key(&mut r, &mut rig, sq_draw::InputKey::Backspace);
    assert_eq!(text_of(&clips(&rig.session)[0]), "Hell", "typing reaches the clip at once");
    key(&mut r, &mut rig, sq_draw::InputKey::Escape);
    assert!(!r.monitor.panel.text_field.is_editing());
}

#[test]
fn a_double_click_on_a_caption_edits_it() {
    use sq_core_model::CaptionItem;
    use sq_core_time::{Time, TimeRange};
    let (mut r, mut rig) = armed(TimelineTool::Selection);
    let item = CaptionItem {
        id: rig.session.ids.next_id(),
        lines: vec!["Hi there".to_string()],
        range: TimeRange::from_end(Time::new(0, 1), Time::new(5, 1)),
        style_ref: "default".to_string(),
        animation_ref: String::new(),
        style_overridden: false,
        words: Vec::new(),
        position: None,
    };
    let id = item.id;
    assert!(rig.session.add_captions(vec![item.clone()]));
    r.sync(&rig.session);
    let tl = rig.session.display_timeline().expect("sequence");
    let library = sq_text::caption_presets::CaptionLookRegistry::shared().library_for_project(rig.session.project());
    let rect = sq_editor_session::CaptionMonitorHit::text_rect(&item, &tl.format, &library);
    let c = r.monitor.panel.canvas_rect();
    let k = c.width / f64::from(tl.format.width as u32);
    let p =
        ((c.mid_x() + (rect.x + rect.width / 2.0) * k) as f32, (c.mid_y() + (rect.y + rect.height / 2.0) * k) as f32);
    rig.ui.now = 10.0;
    press(&mut r, &mut rig, p, None);
    rig.ui.now += 0.2;
    press(&mut r, &mut rig, p, None);
    assert!(r.monitor.panel.text_field.is_editing(), "the field opens over the caption");
    key(&mut r, &mut rig, sq_draw::InputKey::Backspace);
    assert_eq!(rig.session.caption_item(id).map(|c| c.lines.join("\n")).as_deref(), Some("Hi ther"));
    key(&mut r, &mut rig, sq_draw::InputKey::Escape);
    assert!(!r.monitor.panel.text_field.is_editing());
}
