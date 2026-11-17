//! Tests of the Inspector host: action routing against a real session, then the sections through the headless App.

use super::*;
use crate::analysis_links::picture_sampler::PictureSampler;
use sq_app_shell::{App, AppDeps, Headless};
use sq_core_color::{ColorMatteClipExt, ColorMatteColor};
use sq_core_graphics::format_variants_view::VariantProperty;
use sq_core_model::ClipEffect;
use sq_core_model::{Clip, EffectColor, ShapeKind};
use sq_core_time::{Id, SequentialIds, Time};
use sq_draw::{Canvas, DrawTheme, InputModifiers};
use sq_editor_session::SessionDeps;
use sq_inspector_ui::clip_sections::ClipSectionMode;
use sq_inspector_ui::ec::color_match::ColorMatchRequest;
use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
use sq_inspector_ui::ec_draw::effect_controls_draw_panel::EaseCurveTarget;
use sq_runtime::FakeClock;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-inspector-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

fn no_audio() -> AudioBlockFactory {
    Box::new(|_, _| panic!("no audio clip is shown in these tests"))
}

#[test]
fn a_shape_kind_change_is_one_undo_step() {
    let mut s = session();
    let clip = s.add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    let rest = route_sections(&mut s, vec![SectionAction::SetShapeKind { clip, kind: ShapeKind::Ellipse }]);
    assert!(rest.is_empty());
    assert_eq!(s.undo_name(), Some("Change Shape"));
}

#[test]
fn a_color_matte_edit_runs_and_the_picker_waits() {
    let mut s = session();
    let clip = s.add_color_matte(ColorMatteColor::DEFAULT, "Matte", None, None, Time::seconds(5)).expect("matte");
    let picker = SectionAction::PickMatteColor {
        current: EffectColor { red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0 },
        anchor: CGRect::default(),
    };
    let set = SectionAction::SetColorMatte { clip, color: ColorMatteColor { r: 1, g: 2, b: 3 }, continues: false };
    let rest =
        route_sections(&mut s, vec![set, picker.clone(), SectionAction::HeightChanged, SectionAction::EditGraphics]);
    assert_eq!(
        rest,
        vec![picker, SectionAction::EditGraphics],
        "only what needs a picker or a panel is left, in order"
    );
}

#[test]
fn the_sections_follow_the_selected_clip() {
    let mut s = session();
    s.add_shape_clip(ShapeKind::Line, None, None, Time::seconds(5)).expect("shape");
    let mut host = InspectorHost::new(no_audio());
    host.sync(&s);
    assert_eq!(host.sections().mode(), ClipSectionMode::Shape);
}

#[test]
fn the_host_draws_and_takes_clicks_inside_its_sections_through_the_app() {
    let mut s = session();
    s.add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    let h = Headless::new(s, AppDeps::headless(Arc::new(FakeClock::new())), 800, 600);
    h.with(|a: &mut App| {
        let id = a.add_host(Box::new(InspectorHost::new(no_audio())));
        a.set_host_frame(id, Some(CGRect::new(0.0, 0.0, 320.0, 600.0)));
    });
    let (_, list) = h.turn();
    assert!(list.is_some_and(|l| !l.quads().is_empty()), "the sections draw");
    assert!(!h.input(&InputEvent::MouseDown { x: 700.0, y: 500.0, modifiers: InputModifiers::NONE }), "outside");
    assert!(h.input(&InputEvent::MouseDown { x: 10.0, y: 10.0, modifiers: InputModifiers::NONE }), "on the header");
}

fn shown_clip(s: &EditorSession, id: Id) -> Clip {
    let t = s.active_timeline().expect("timeline");
    t.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == id).expect("clip").clone()
}

#[test]
fn selecting_a_clip_fills_effect_controls_and_an_opacity_edit_undoes() {
    use crate::test_rig::Rig;
    use sq_inspector_ui::ec::effect_controls_model::property::{EffectComponent, EffectProperty};
    let mut rig = Rig::new(session());
    let id = rig.session.add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    rig.session.set_selection([id].into(), Default::default());
    let before = shown_clip(&rig.session, id);
    let mut host = InspectorHost::new(no_audio());
    host.sync(&rig.session);
    assert_eq!(host.controls().model.clip().map(|c| c.id), Some(id), "the selection fills the panel");

    assert!(host.controls().model.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.4));
    host.route(&mut rig.cx());
    let edited = shown_clip(&rig.session, id);
    assert_ne!(edited, before, "the edit reached the session");

    rig.session.undo();
    assert_eq!(shown_clip(&rig.session, id), before, "undo restores the clip");
    host.sync(&rig.session);
    assert_eq!(host.controls().model.clip(), Some(&before), "the panel follows the undo");
}

#[test]
fn an_empty_selection_empties_effect_controls() {
    let mut s = session();
    let id = s.add_shape_clip(ShapeKind::Line, None, None, Time::seconds(5)).expect("shape");
    s.set_selection([id].into(), Default::default());
    let mut host = InspectorHost::new(no_audio());
    host.sync(&s);
    assert!(host.controls().model.clip().is_some());
    s.set_selection(Default::default(), Default::default());
    host.sync(&s);
    assert!(host.controls().model.clip().is_none());
}

#[test]
fn an_effect_added_to_the_selection_shows_in_effect_controls_and_undoes() {
    let mut s = session();
    let id = s.add_shape_clip(ShapeKind::Line, None, None, Time::seconds(5)).expect("shape");
    s.set_selection([id].into(), Default::default());
    let mut host = InspectorHost::new(no_audio());
    host.sync(&s);
    let had = host.controls().model.clip().map_or(0, |c| c.effects.len());
    assert!(s.add_effect("gaussianBlur", &[id].into()));
    host.sync(&s);
    assert_eq!(host.controls().model.clip().map(|c| c.effects.len()), Some(had + 1));
    s.undo();
    host.sync(&s);
    assert_eq!(host.controls().model.clip().map(|c| c.effects.len()), Some(had));
}

#[test]
fn an_effect_controls_menu_row_runs_on_the_session_and_undoes() {
    use crate::test_rig::Rig;
    use sq_inspector_ui::ec::effect_controls_model::property::{EffectComponent, EffectProperty};
    use sq_inspector_ui::ec_draw::{MenuEntry, ModelMenu};
    use sq_uikit::sqmenu_model::SQMenuItem;
    let mut rig = Rig::new(session());
    let id = rig.session.add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    rig.session.set_selection([id].into(), Default::default());
    let before = shown_clip(&rig.session, id);
    let mut host = InspectorHost::new(no_audio());
    host.sync(&rig.session);
    let entry = MenuEntry::action(SQMenuItem::new("Fade"), |m, _| {
        m.set_value(&EffectProperty::Opacity, EffectComponent::All, 0.4);
    });
    host.view_deferred.push(ViewEvent::Menu {
        menu: Rc::new(ModelMenu { entries: vec![entry] }),
        anchor: CGRect::new(5.0, 6.0, 10.0, 10.0),
    });
    let mut menus = host.take_menus();
    assert_eq!(menus.len(), 1);
    assert!(host.take_view_deferred().is_empty(), "the menu left the queue");
    let (items, anchor) = menus.remove(0);
    assert_eq!(anchor.x, 5.0);
    assert_eq!(shown_clip(&rig.session, id), before, "opening changes nothing");
    (items[0].action.as_ref().expect("row action"))();
    host.pump(&mut rig.cx());
    assert_ne!(shown_clip(&rig.session, id), before, "the row reached the session");
    rig.session.undo();
    assert_eq!(shown_clip(&rig.session, id), before);
}

#[test]
fn the_layer_menu_opens_with_whole_graphic_first_and_a_pick_reaches_the_sections() {
    use crate::test_rig::Rig;
    let mut rig = Rig::new(session());
    let mut host = InspectorHost::new(no_audio());
    let layer = Id::from_u128(7);
    host.deferred.push(SectionAction::LayerMenu {
        entries: vec![(layer, "Title".to_string())],
        picked: Some(layer),
        anchor: CGRect::default(),
    });
    let (items, _) = host.take_menus().remove(0);
    assert_eq!(items.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(), ["Whole graphic", "Title"]);
    assert!(items[1].is_checked && !items[0].is_checked);
    (items[1].action.as_ref().expect("row action"))();
    host.pump(&mut rig.cx());
    assert!(host.take_deferred().is_empty(), "no graphic clip is shown, so the pick is ignored");
}

fn matte_color(s: &EditorSession, id: Id) -> ColorMatteColor {
    shown_clip(s, id).matte_color().expect("matte")
}

#[test]
fn the_matte_color_picker_opens_edits_the_clip_in_one_undo_step_and_closes() {
    use crate::test_rig::Rig;
    let mut rig = Rig::new(session());
    let id = rig
        .session
        .add_color_matte(ColorMatteColor { r: 255, g: 0, b: 0 }, "Matte", None, None, Time::seconds(5))
        .expect("matte");
    let mut host = InspectorHost::new(no_audio());
    host.set_window(CGRect::new(0.0, 0.0, 800.0, 600.0));
    host.deferred.push(SectionAction::PickMatteColor {
        current: EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 },
        anchor: CGRect::new(20.0, 20.0, 20.0, 12.0),
    });
    // The matte section must know its clip: the sections follow the selection.
    rig.session.set_selection([id].into(), Default::default());
    host.sync(&rig.session);
    host.route(&mut rig.cx());
    assert!(host.has_popover());
    assert!(host.take_deferred().is_empty(), "the request was answered");
    let before = matte_color(&rig.session, id);
    let right = InputEvent::KeyDown { key: sq_draw::InputKey::Right, modifiers: InputModifiers::NONE };
    for _ in 0..2 {
        assert!(host.handle_popover(&right, &mut rig.cx()));
    }
    assert_ne!(matte_color(&rig.session, id), before, "the picker edits the clip");
    let esc = InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: InputModifiers::NONE };
    assert!(host.handle_popover(&esc, &mut rig.cx()));
    assert!(!host.has_popover());
    rig.session.undo();
    assert_eq!(matte_color(&rig.session, id), before, "one picker session is one undo step");
}

#[test]
fn removing_keyframes_asks_first_and_only_a_yes_removes_them() {
    use crate::test_rig::Rig;
    use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
    let mut rig = Rig::new(session());
    let id = rig.session.add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    rig.session.set_selection([id].into(), Default::default());
    let mut host = InspectorHost::new(no_audio());
    host.sync(&rig.session);
    let p = EffectProperty::Opacity;
    let _ = host.controls().model.toggle_stopwatch(&p, true);
    host.route(&mut rig.cx());
    let animated = shown_clip(&rig.session, id);
    for yes in [false, true] {
        let what = RemoveKeys::Property(p.clone());
        host.view_deferred.push(ViewEvent::Panel(PanelEvent::ConfirmRemoveKeyframes { title: "Opacity".into(), what }));
        let mut dialogs = host.take_dialogs();
        assert_eq!(dialogs.len(), 1);
        dialogs[0].press(SQDialogResponse(i64::from(yes)));
        host.pump(&mut rig.cx());
        assert_eq!(shown_clip(&rig.session, id) == animated, !yes, "answer {yes}");
    }
}

#[test]
fn the_text_look_plus_asks_for_a_name_ok_saves_it_and_cancel_does_nothing() {
    use sq_editor_session::LookStore;
    let template =
        sq_text::text_template::TextTemplate::new("Title", "Hello", sq_text::text_style::TextStyle::default());
    let mut s = session();
    let id =
        s.add_text_clip(&template, Some(Time::seconds(0)), None, Time::seconds(3), None, false).expect("a text clip");
    s.set_selection([id].into(), Default::default());
    let mut rig = crate::test_rig::Rig::new(s);
    let store = Arc::new(LookStore::new(None, None, None, None));
    let mut host = InspectorHost::new(no_audio());
    host.set_looks(Arc::clone(&store));
    host.sync(&rig.session);
    let saved = |rig: &crate::test_rig::Rig| -> Vec<String> {
        rig.session.looks(&store).into_iter().filter(|e| e.ref_.scope == LookScope::User).map(|e| e.look.name).collect()
    };
    for ok in [false, true] {
        let mut add = (host.text_block.look_source.as_ref().expect("the Look popup"))().add.expect("the + button");
        add();
        host.route(&mut rig.cx());
        let mut dialogs = host.take_dialogs();
        assert_eq!(dialogs.len(), 1, "the + asks for a name");
        assert!(saved(&rig).is_empty(), "nothing is saved before the answer");
        dialogs[0].press(if ok { SQDialogResponse::FIRST } else { SQDialogResponse::SECOND });
        host.route(&mut rig.cx());
        host.sync(&rig.session);
        assert_eq!(saved(&rig), if ok { vec!["My Look".to_string()] } else { Vec::new() }, "ok {ok}");
    }
    let titles = (host.text_block.look_source.as_ref().expect("the Look popup"))().titles;
    assert!(titles.contains(&"My Look".to_string()), "the popup lists the new Look");
}

#[test]
fn a_template_zones_switch_runs_on_the_session() {
    let mut s = session();
    let id = s.add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    let rest = route_sections(&mut s, vec![SectionAction::Template { clip: id, event: TemplateEvent::Zones(true) }]);
    assert!(rest.is_empty(), "template events are session calls");
}

fn selected_shape(rig: &mut crate::test_rig::Rig) -> (InspectorHost, Id) {
    let id = rig.session.add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    rig.session.set_selection([id].into(), Default::default());
    let mut host = InspectorHost::new(no_audio());
    host.sync(&rig.session);
    (host, id)
}

#[test]
fn a_key_tool_prompt_with_fields_answers_the_texts_and_a_cancel_answers_none() {
    use crate::test_rig::Rig;
    let mut rig = Rig::new(session());
    let (mut host, _) = selected_shape(&mut rig);
    for yes in [true, false] {
        let got: Rc<RefCell<Option<Option<Vec<String>>>>> = Rc::default();
        let sink = Rc::clone(&got);
        let done: sq_inspector_ui::ec_draw::PromptDone = Rc::new(move |_, texts| *sink.borrow_mut() = Some(texts));
        host.view_deferred.push(ViewEvent::Prompt(PromptRequest { prompt: KeyToolPrompt::scale_time(), done }));
        let mut dialogs = host.take_dialogs();
        assert_eq!(dialogs.len(), 1, "a prompt with a field is a dialog now");
        dialogs[0].press(SQDialogResponse(i64::from(yes)));
        host.pump(&mut rig.cx());
        let expected = yes.then(|| vec!["100 %".to_string()]);
        assert_eq!(got.borrow().clone(), Some(expected), "answer {yes}");
    }
}

#[test]
fn naming_a_curve_to_save_asks_with_one_field() {
    use crate::test_rig::Rig;
    let mut rig = Rig::new(session());
    let (mut host, _) = selected_shape(&mut rig);
    host.view_deferred.push(ViewEvent::SaveCurve { property: EffectProperty::Opacity, index: 0 });
    let mut dialogs = host.take_dialogs();
    assert_eq!(dialogs.len(), 1);
    assert_eq!(dialogs[0].message_text, "Save Curve");
    dialogs[0].press(SQDialogResponse(1));
    host.pump(&mut rig.cx());
    assert!(host.take_view_deferred().is_empty(), "the answer is used up, no value graph is open");
}

#[test]
fn reset_to_automatic_maps_the_motion_rows_to_variant_properties() {
    assert_eq!(variant_property(&EffectProperty::Position), Some(VariantProperty::Position));
    assert_eq!(variant_property(&EffectProperty::TiltY), Some(VariantProperty::Tilt));
    assert_eq!(variant_property(&EffectProperty::Opacity), None);
}

#[test]
fn the_curve_popover_of_the_speed_row_needs_a_transition() {
    use crate::test_rig::Rig;
    let mut rig = Rig::new(session());
    let (mut host, _) = selected_shape(&mut rig);
    host.view_deferred.push(ViewEvent::Panel(PanelEvent::EaseCurve {
        target: EaseCurveTarget::SpeedTransition,
        anchor: CGRect::new(10.0, 10.0, 20.0, 12.0),
    }));
    let mut cx = rig.cx();
    host.open_pickers(&mut cx);
    assert!(!host.has_popover());
    assert!(cx.events.iter().any(|e| matches!(e, AppEvent::Status(s) if s.contains("speed transition"))));
}

#[test]
fn the_curve_popover_of_a_motion_effect_opens_edits_and_closes_on_a_click_outside() {
    use crate::test_rig::Rig;
    let mut rig = Rig::new(session());
    let (mut host, id) = selected_shape(&mut rig);
    assert!(rig.session.add_effect(ClipEffect::MOTION_KINDS[0], &[id].into()));
    host.sync(&rig.session);
    let effect = host.controls().model.clip().and_then(|c| c.effects.first().map(|e| e.id)).expect("effect");
    host.set_window(CGRect::new(0.0, 0.0, 800.0, 600.0));
    host.view_deferred.push(ViewEvent::Panel(PanelEvent::EaseCurve {
        target: EaseCurveTarget::Motion(effect),
        anchor: CGRect::new(100.0, 100.0, 20.0, 12.0),
    }));
    let mut cx = rig.cx();
    host.open_pickers(&mut cx);
    assert!(host.has_popover());
    let near = InputEvent::MouseMoved { x: 110.0, y: 130.0 };
    assert!(!host.handle_popover(&near, &mut cx), "a move is not taken");
    let outside = InputEvent::MouseDown { x: 790.0, y: 590.0, modifiers: InputModifiers::NONE };
    assert!(!host.handle_popover(&outside, &mut cx), "a press elsewhere closes it and goes on to the panels");
    assert!(!host.has_popover());
    host.view_deferred.push(ViewEvent::Panel(PanelEvent::EaseCurve {
        target: EaseCurveTarget::Motion(effect),
        anchor: CGRect::new(100.0, 100.0, 20.0, 12.0),
    }));
    host.open_pickers(&mut cx);
    let on_opener = InputEvent::MouseDown { x: 110.0, y: 106.0, modifiers: InputModifiers::NONE };
    assert!(host.handle_popover(&on_opener, &mut cx), "a press on its opener is taken");
    assert!(!host.has_popover(), "and only closes it");
}

#[test]
fn the_multiband_setup_opens_over_the_window_and_esc_closes_it() {
    use crate::test_rig::Rig;
    use sq_core_effects::effects_editing::ClipEffectsEditingExt;
    use sq_core_model::TrackKind;
    use sq_core_time::{SequentialIds, TimeRange};
    use sq_draw::InputKey;
    let mut rig = Rig::new(session());
    let mut host = InspectorHost::new(no_audio());
    let mut clip = Clip::new(
        Id::from_u128(1000),
        "Voice",
        Id::from_u128(1001),
        TrackKind::Audio,
        TimeRange::new(Time::ZERO, Time::new(10, 1)),
        Time::ZERO,
    );
    let effect = clip.add_effect(ClipEffect::AUDIO_MULTIBAND_KIND, None, &mut SequentialIds::default()).expect("fx");
    host.controls().model.set_clip(Some(clip), None, Vec::new(), None);
    host.set_window(CGRect::new(0.0, 0.0, 1280.0, 800.0));
    host.view_deferred.push(ViewEvent::Panel(PanelEvent::MultibandEditor(effect)));
    let mut cx = rig.cx();
    host.open_pickers(&mut cx);
    assert!(host.has_popover(), "the setup is open");
    let outside = InputEvent::MouseDown { x: 1.0, y: 1.0, modifiers: InputModifiers::NONE };
    assert!(!host.handle_popover(&outside, &mut cx), "a press outside goes on to the panels");
    assert!(host.has_popover(), "and the setup stays open");
    host.multiband.as_mut().expect("open").reactivate();
    let esc = InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE };
    assert!(host.handle_popover(&esc, &mut cx));
    assert!(!host.has_popover(), "Esc closes it");
}

#[test]
fn spectrum_at_input_is_read_from_and_stored_in_the_defaults() {
    use crate::test_rig::Rig;
    use sq_draw_shell::MemoryDefaults;
    use sq_inspector_ui::audio_masks::multiband_editor_draw::{MultibandEditorDraw, MultibandEditorRequest};
    let key = MultibandEditorDraw::SPECTRUM_INPUT_DEFAULTS_KEY;
    let store: sq_draw_shell::SharedDefaults = Rc::new(RefCell::new(MemoryDefaults::default()));
    let mut rig = Rig::new(session());
    let mut host = InspectorHost::new(no_audio());
    host.set_settings_store(Rc::clone(&store));
    assert!(!host.spectrum_at_input(), "off until chosen");
    store.borrow_mut().set_integer(key, 1);
    assert!(host.spectrum_at_input(), "a stored choice is read");
    host.multiband =
        Some(MultibandHost::open(Id::from_u128(5), &host.controls().model, CGSize::new(900.0, 700.0), true));
    store.borrow_mut().set_integer(key, 0);
    let mut cx = rig.cx();
    host.multiband.as_mut().expect("open").draw.requests.push(MultibandEditorRequest::SpectrumAtInput(true));
    host.handle_multiband(&InputEvent::MouseDown { x: 1.0, y: 1.0, modifiers: InputModifiers::NONE }, &mut cx);
    assert_eq!(store.borrow().integer(key), Some(1), "the toggle is stored under the Swift key");
}

#[test]
fn the_stabilizer_replan_waits_250_ms_and_a_newer_change_replaces_it() {
    use crate::test_rig::Rig;
    let mut rig = Rig::new(session());
    let mut host = InspectorHost::new(no_audio());
    let (a, b) = (Id::from_u128(1), Id::from_u128(2));
    rig.ui.now = 10.0;
    host.replan_due = Some((vec![a], 10.0 + InspectorHost::REPLAN_DELAY));
    rig.ui.now = 10.2;
    host.run_due_replan(&mut rig.cx());
    assert!(host.replan_due.is_some(), "still inside the pause");
    host.replan_due = Some((vec![b], 10.2 + InspectorHost::REPLAN_DELAY));
    rig.ui.now = 10.4;
    host.run_due_replan(&mut rig.cx());
    assert!(host.replan_due.is_some(), "the newer change moved the end of the pause");
    rig.ui.now = 10.46;
    host.run_due_replan(&mut rig.cx());
    assert!(host.replan_due.is_none(), "the pause is over: it ran");
}

#[test]
fn a_stabilizer_is_replanned_only_when_its_settings_changed() {
    let mut s = session();
    let id = s.add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    let mut c = s.active_timeline().and_then(|t| t.tracks.iter().find_map(|tr| tr.clip(id)).cloned()).expect("clip");
    let mut seen = BTreeMap::new();
    assert!(!stabilizer_changed(&mut seen, &c), "no Stabilizer: nothing to plan");
    c.effects.push(ClipEffect::make(Id::from_u128(77), ClipEffect::STABILIZE_KIND).expect("stabilize"));
    assert!(stabilizer_changed(&mut seen, &c), "first look");
    assert!(!stabilizer_changed(&mut seen, &c), "same settings");
}

#[test]
fn the_opacity_slider_is_a_node_and_its_actions_edit_the_session_and_undo() {
    use crate::test_rig::Rig;
    use accesskit::Role;
    let mut rig = Rig::new(session());
    let id = rig.session.add_shape_clip(ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    rig.session.set_selection([id].into(), Default::default());
    let before = shown_clip(&rig.session, id);
    let mut host = InspectorHost::new(no_audio());
    host.sync(&rig.session);
    host.layout(CGRect::new(0.0, 0.0, 400.0, 900.0), &mut rig.cx());

    let mut a = A11y::new(true);
    host.a11y(&mut a);
    let opacity = A11y::node_id("inspector", Role::Slider, &EffectProperty::Opacity.raw_value());
    let node = a.nodes().iter().find(|(n, _)| *n == opacity).map(|(_, n)| n.clone()).expect("an Opacity node");
    assert_eq!(node.label(), Some("Opacity"));
    assert_eq!(node.numeric_value(), Some(100.0));
    assert_eq!(node.max_numeric_value(), Some(100.0));

    assert!(host.a11y_action(opacity, A11yAction::Decrement, &mut rig.cx()));
    assert_ne!(shown_clip(&rig.session, id), before, "Decrement reached the session");
    assert!(host.a11y_action(opacity, A11yAction::SetValue(40.0), &mut rig.cx()));
    host.sync(&rig.session);
    let mut b = A11y::new(true);
    host.a11y(&mut b);
    let value = b.nodes().iter().find(|(n, _)| *n == opacity).and_then(|(_, n)| n.numeric_value());
    assert_eq!(value, Some(40.0), "the node reports the new value");
    assert!(!host.a11y_action(accesskit::NodeId(1), A11yAction::Increment, &mut rig.cx()), "foreign id");

    rig.session.undo();
    rig.session.undo();
    assert_eq!(shown_clip(&rig.session, id), before, "undo restores the clip");
}

#[test]
fn the_track_buttons_of_effect_controls_become_flow_requests() {
    use crate::test_rig::Rig;
    let mut rig = Rig::new(session());
    let (mut host, _) = selected_shape(&mut rig);
    let flow = MagicFlow::default();
    host = host.with_magic_flow(flow.clone());
    let mask = Id::from_u128(9);
    host.view_deferred.push(ViewEvent::Panel(PanelEvent::TrackMagic { mask, step: Some(true) }));
    host.view_deferred.push(ViewEvent::Panel(PanelEvent::TrackMagic { mask, step: None }));
    host.view_deferred.push(ViewEvent::Panel(PanelEvent::TrackMask { mask, forward: false }));
    host.open_pickers(&mut rig.cx());
    assert_eq!(
        flow.take_requests(),
        vec![
            FlowRequest::TrackMagic { mask, step: Some(true) },
            FlowRequest::TrackMagic { mask, step: None },
            FlowRequest::TrackMask { mask, forward: false, mode: sq_core_masks::mask_motion::MaskTrackMode::Position },
        ]
    );
    assert!(host.view_deferred.is_empty(), "the flow took them");
}

#[test]
fn without_a_flow_the_track_buttons_stay_queued() {
    use crate::test_rig::Rig;
    let mut rig = Rig::new(session());
    let (mut host, _) = selected_shape(&mut rig);
    host.view_deferred.push(ViewEvent::Panel(PanelEvent::TrackMagic { mask: Id::from_u128(9), step: Some(false) }));
    host.open_pickers(&mut rig.cx());
    assert_eq!(host.view_deferred.len(), 1);
}

/// A picture of one flat color, published as a newer composite.
fn show_flat(picture: &crate::MonitorPicture, rgb: [f32; 3]) {
    picture.set(None);
    let reader: crate::LinearReader = Arc::new(move || {
        let bytes = (0..32 * 32)
            .flat_map(|_| [rgb[0], rgb[1], rgb[2], 1.0])
            .flat_map(|v| exr::prelude::f16::from_f32(v).to_bits().to_le_bytes())
            .collect();
        Some(crate::LinearImage { width: 32, height: 32, bytes })
    });
    picture.set_linear(Some(reader));
}

/// Set Reference and Match go the way the app does: the button's event, the host, the sampler over the Program picture.
#[test]
fn set_reference_and_match_read_the_program_picture() {
    use crate::test_rig::Rig;
    use sq_core_effects::effects_editing::ClipEffectsEditingExt;
    use sq_core_model::COLOR_KIND;
    let mut rig = Rig::new(session());
    let mut clip = Clip::new(
        Id::from_u128(2000),
        "Shot",
        Id::from_u128(2001),
        sq_core_model::TrackKind::Video,
        sq_core_time::TimeRange::new(Time::ZERO, Time::new(10, 1)),
        Time::ZERO,
    );
    let effect = clip.add_effect(COLOR_KIND, None, &mut SequentialIds::default()).expect("color effect added");
    let picture = crate::MonitorPicture::default();
    let mut host = InspectorHost::new(no_audio()).with_frame_sampler(PictureSampler::new(picture.clone()));
    host.controls().model.set_clip(Some(clip), None, Vec::new(), None);

    host.controls().model.request_color_match(effect, ColorMatchRequest::SetReference);
    host.route(&mut rig.cx());
    show_flat(&picture, [0.18, 0.18, 0.18]);
    host.poll_color_match(&mut rig.cx());
    let reference = host.controls().model.color_match_reference(effect).expect("reference stored");
    assert!(reference.label.contains("00:00:00:00"), "{}", reference.label);

    let before = host.controls().model.clip().cloned();
    host.controls().model.request_color_match(effect, ColorMatchRequest::Match);
    host.route(&mut rig.cx());
    show_flat(&picture, [0.05, 0.05, 0.05]);
    host.poll_color_match(&mut rig.cx());
    assert_ne!(host.controls().model.clip().cloned(), before, "Match changed the Color wheels");
}

#[test]
fn the_picker_lists_recent_colors_picks_from_the_monitor_and_remembers_the_pick() {
    use crate::PickerAids;
    use crate::analysis_links::eyedropper::Eyedropper;
    use crate::test_rig::Rig;
    use sq_draw_monitor::memory_defaults::MemoryDefaults;
    use sq_uikit::appearance_palette::UiDefaults;
    use sq_uikit::controls_grid::CGPoint;
    use sq_uikit::sqcolor_recents;
    let mut stored = MemoryDefaults::default();
    stored.set_string_array(sqcolor_recents::DEFAULTS_KEY, &["FF00FF".to_string()]);
    let defaults: crate::color_popover::SharedDefaults = Rc::new(RefCell::new(Box::new(stored)));
    let dropper = Eyedropper::default();
    let aids = PickerAids { eyedropper: Some(dropper.clone()), defaults: Some(Rc::clone(&defaults)) };
    let mut rig = Rig::new(session());
    let id = rig
        .session
        .add_color_matte(ColorMatteColor { r: 255, g: 0, b: 0 }, "Matte", None, None, Time::seconds(5))
        .expect("matte");
    let mut host = InspectorHost::new(no_audio()).with_picker_aids(aids);
    host.set_window(CGRect::new(0.0, 0.0, 800.0, 600.0));
    host.deferred.push(SectionAction::PickMatteColor {
        current: EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 },
        anchor: CGRect::new(20.0, 20.0, 20.0, 12.0),
    });
    rig.session.set_selection([id].into(), Default::default());
    host.sync(&rig.session);
    host.route(&mut rig.cx());
    let pop = host.popover.as_ref().expect("picker open");
    assert_eq!(pop.recents(), ["FF00FF".to_string()], "the stored recent colors are listed");
    let CGPoint { x, y } = pop.pipette_center().expect("the pipette shows with a monitor eyedropper");

    let at = |x: f64, y: f64| InputEvent::MouseDown { x: x as f32, y: y as f32, modifiers: InputModifiers::NONE };
    assert!(host.handle_popover(&at(x, y), &mut rig.cx()), "the pipette press is the popover's");
    assert!(dropper.is_armed() && host.popover.as_ref().is_some_and(|p| p.is_awaiting_pick()));
    // The click on the monitor picture is not the popover's: it goes on, and the monitor answers the dropper.
    assert!(!host.handle_popover(&at(700.0, 500.0), &mut rig.cx()));
    let green = sq_draw::RgbaImage { width: 1, height: 1, pixels: vec![0, 255, 0, 255] };
    assert!(dropper.offer(Some(&green), CGRect::new(600.0, 400.0, 100.0, 100.0), 650.0, 450.0));
    host.poll_popover_pick(&mut rig.cx());
    assert_eq!(
        matte_color(&rig.session, id),
        ColorMatteColor { r: 0, g: 255, b: 0 },
        "the picked color reached the clip"
    );
    assert!(!host.popover.as_ref().is_some_and(|p| p.is_awaiting_pick()));

    let esc = InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: InputModifiers::NONE };
    assert!(host.handle_popover(&esc, &mut rig.cx()));
    assert!(!host.has_popover());
    let recents = sqcolor_recents::load(&**defaults.borrow());
    assert_eq!(recents, ["00FF00".to_string(), "FF00FF".to_string()], "the pick leads the recent colors");
}

// MARK: Layout inside the dock frame

/// An audio factory with the real track audio block (the app's), so an audio clip shows its tall Audio controls.
fn real_audio() -> AudioBlockFactory {
    use sq_inspector_ui::audio_masks::track_audio_draw::TrackAudioDraw;
    use sq_inspector_ui::audio_masks::track_audio_inspector_model::TrackAudioInspectorModel;
    Box::new(|_, role| {
        TrackAudioDraw::new(TrackAudioInspectorModel::new(
            sq_audiofx::presets::PresetLibrary::default(),
            None,
            role,
            Box::new(sq_core_time::SequentialIds::default()),
        ))
    })
}

/// A session with one clip of `kind` on a track of that kind, selected.
fn session_with_clip(kind: TrackKind) -> EditorSession {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    let mut clip_id = None;
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        let track = t.tracks.iter_mut().find(|tr| tr.kind == kind).expect("a track of this kind");
        let c = Clip::new(
            Id::from_u128(7),
            "clip",
            Id::from_u128(70),
            kind,
            sq_core_time::TimeRange::new(Time::ZERO, Time::seconds(2)),
            Time::ZERO,
        );
        assert!(track.insert(c, &mut ids).is_ok());
        clip_id = Some(Id::from_u128(7));
    });
    s.select(std::collections::BTreeSet::from([clip_id.expect("clip")]), Default::default());
    s
}

/// Draws `host` in `frame` and returns the largest part of any primitive outside `frame` (zero: all inside).
fn overflow_of(host: &mut InspectorHost, s: &mut EditorSession, frame: CGRect) -> f64 {
    let mut rig = crate::test_rig::Rig::new(session());
    std::mem::swap(&mut rig.session, s);
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    let mut c = Canvas::with_size(800.0, 700.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    std::mem::swap(&mut rig.session, s);
    let (fx0, fy0, fx1, fy1) = (frame.min_x() as f32, frame.min_y() as f32, frame.max_x() as f32, frame.max_y() as f32);
    let mut worst = 0.0_f32;
    let mut drawn = 0;
    for q in c.list.quads() {
        // What shows is the quad cut by its clip.
        let (x0, y0) = (q.rect.x.max(q.clip[0]), q.rect.y.max(q.clip[1]));
        let (x1, y1) = (q.rect.max_x().min(q.clip[2]), q.rect.max_y().min(q.clip[3]));
        if x1 <= x0 || y1 <= y0 {
            continue;
        }
        drawn += 1;
        worst = worst.max(fx0 - x0).max(fy0 - y0).max(x1 - fx1).max(y1 - fy1);
    }
    assert!(drawn > 0, "the panel drew something");
    f64::from(worst)
}

#[test]
fn the_controls_panel_draws_inside_its_dock_frame_for_audio_video_and_text_clips() {
    // 230 pt tall: shorter than the Audio controls of an audio clip, so they must be cut, not drawn over the timeline.
    let frame = CGRect::new(20.0, 90.0, 420.0, 230.0);
    for kind in [TrackKind::Audio, TrackKind::Video] {
        let mut s = session_with_clip(kind);
        let mut host = InspectorHost::new(real_audio());
        let over = overflow_of(&mut host, &mut s, frame);
        assert!(over <= 0.01, "{kind:?} clip: the panel draws {over} pt outside its frame");
    }
    let mut s = session();
    let template =
        sq_text::text_template::TextTemplate::new("Title", "Hello", sq_text::text_style::TextStyle::default());
    s.add_text_clip(&template, None, None, Time::seconds(5), None, false).expect("text clip");
    let mut host = InspectorHost::new(real_audio());
    let over = overflow_of(&mut host, &mut s, frame);
    assert!(over <= 0.01, "text clip: the panel draws {over} pt outside its frame");
}

#[test]
fn the_audio_controls_taller_than_the_panel_scroll_below_the_clip_header_and_rows() {
    let frame = CGRect::new(20.0, 90.0, 420.0, 230.0);
    let mut s = session_with_clip(TrackKind::Audio);
    let mut host = InspectorHost::new(real_audio());
    let mut rig = crate::test_rig::Rig::new(session());
    std::mem::swap(&mut rig.session, &mut s);
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    assert!(host.closing(), "the Audio block closes the column like Swift's");
    assert!(host.sections().height() > frame.height, "the Audio controls are taller than this panel");
    assert!(host.sections_scroll_max() > 0.0);
    // The wheel moves the stack up until its end shows; it never moves past either end.
    let wheel = |dy: f32| InputEvent::Scroll { x: 100.0, y: 150.0, dx: 0.0, dy, modifiers: InputModifiers::NONE };
    assert!(host.handle(&wheel(-60.0), &mut rig.cx()));
    assert!((host.sections_scroll - 60.0).abs() < 1e-9);
    host.handle(&wheel(-5000.0), &mut rig.cx());
    assert!((host.sections_scroll - host.sections_scroll_max()).abs() < 1e-9);
    // At the end the Audio block's last row lies on the panel's bottom edge.
    assert!((host.sections_y() + host.sections().height() - frame.height).abs() < 1e-9);
    host.handle(&wheel(5000.0), &mut rig.cx());
    assert_eq!(host.sections_scroll, 0.0);
}

#[test]
fn the_clip_header_row_lies_above_the_audio_block_and_inside_the_frame() {
    let frame = CGRect::new(20.0, 90.0, 420.0, 230.0);
    let mut s = session_with_clip(TrackKind::Audio);
    let mut host = InspectorHost::new(real_audio());
    let mut rig = crate::test_rig::Rig::new(session());
    std::mem::swap(&mut rig.session, &mut s);
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    let line = sq_inspector_ui::ec::controls_metrics::ControlsMetrics::CLIP_LINE;
    // Panel space: the clip line starts at the top, the Audio block starts below the header and the rows.
    assert!(host.controls_y().abs() < 1e-9, "the controls start at the panel's top edge");
    assert!(host.sections_y() >= host.controls.top(), "the Audio block lies below the clip line and header");
    assert!(host.sections_y() > host.controls_y());
    let mut c = Canvas::with_size(800.0, 700.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    let (top, bottom) = (frame.min_y() as f32, frame.max_y() as f32);
    let mut in_line = 0;
    for q in c.list.quads() {
        let (y0, y1) = (q.rect.y.max(q.clip[1]), q.rect.max_y().min(q.clip[3]));
        if y1 <= y0 {
            continue;
        }
        assert!(y0 >= top - 0.01 && y1 <= bottom + 0.01, "a quad shows outside the frame: {y0}..{y1}");
        if y0 < top + line as f32 {
            in_line += 1;
        }
    }
    assert!(in_line > 0, "the clip line row draws at the panel's top edge");
}

fn session_with_shape_clip() -> EditorSession {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let track = p.timelines[0].tracks.iter_mut().find(|tr| tr.kind == TrackKind::Video).expect("video track");
        let mut c = Clip::new(
            Id::from_u128(8),
            "shape",
            Id::from_u128(80),
            TrackKind::Video,
            sq_core_time::TimeRange::new(Time::ZERO, Time::seconds(2)),
            Time::ZERO,
        );
        c.generator = Some(sq_core_model::GeneratorRef::shape(sq_core_model::ShapeKind::Rectangle));
        assert!(track.insert(c, &mut ids).is_ok());
    });
    s.select(std::collections::BTreeSet::from([Id::from_u128(8)]), Default::default());
    s
}

fn text_session() -> EditorSession {
    let mut s = session();
    let template =
        sq_text::text_template::TextTemplate::new("Title", "Hello", sq_text::text_style::TextStyle::default());
    s.add_text_clip(&template, None, None, Time::seconds(5), None, false).expect("text clip");
    let ids: std::collections::BTreeSet<Id> = s
        .active_timeline()
        .map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect())
        .unwrap_or_default();
    s.set_selection_follows_playhead(false);
    s.select(ids, Default::default());
    s
}

/// The clip line and header lie on top, the leading section directly below them, the rows below the section, and
/// nothing draws outside the frame (a tall frame and a short one that scrolls).
#[test]
fn a_leading_section_sits_below_the_clip_header_and_above_the_rows_inside_the_frame() {
    let line = sq_inspector_ui::ec::controls_metrics::ControlsMetrics::CLIP_LINE;
    let head = sq_inspector_ui::ec::controls_metrics::ControlsMetrics::HEADER;
    for (name, make) in [("text", text_session as fn() -> EditorSession), ("shape", session_with_shape_clip)] {
        for height in [900.0, 230.0] {
            let frame = CGRect::new(20.0, 90.0, 420.0, height);
            let mut s = make();
            let mut host = InspectorHost::new(real_audio());
            let mut rig = crate::test_rig::Rig::new(session());
            std::mem::swap(&mut rig.session, &mut s);
            host.sync(&rig.session);
            host.layout(frame, &mut rig.cx());
            assert!(
                host.leading(),
                "{name}: the section leads (mode {:?}, height {}, clip {})",
                host.sections().mode(),
                host.sections().height(),
                host.controls.model.clip().is_some()
            );
            assert!(host.controls_y().abs() < 1e-9, "{name}: the clip line starts at the panel's top edge");
            assert!(
                (host.sections_y() - line).abs() < 1e-9,
                "{name}: the selected item starts right below the clip line (redesign #34)"
            );
            let section_h = host.sections().height();
            assert!(
                host.controls.top() >= host.sections_y() + section_h + head - 1e-9,
                "{name}: the Video header and then the rows start below the section"
            );
            let mut c = Canvas::with_size(800.0, 1200.0, None, 1.0);
            host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
            let (top, bottom) = (frame.min_y() as f32, frame.max_y() as f32);
            let mut in_line = 0;
            for q in c.list.quads() {
                let (y0, y1) = (q.rect.y.max(q.clip[1]), q.rect.max_y().min(q.clip[3]));
                if y1 <= y0 {
                    continue;
                }
                assert!(y0 >= top - 0.01 && y1 <= bottom + 0.01, "{name}: a quad shows outside the frame");
                if y0 < top + line as f32 {
                    in_line += 1;
                }
            }
            assert!(in_line > 0, "{name}: the clip line row draws at the panel's top edge");
            if height < 500.0 {
                assert!(host.sections_scroll_max() > 0.0, "{name}: the whole stack scrolls in a short panel");
            }
        }
    }
}

/// A selected text clip: the Text block reports its real height to the sections, shows between the clip header and the
/// rows inside the dock frame, and typing in its box edits the clip text.
#[test]
fn the_text_block_of_a_text_clip_has_its_own_height_and_takes_typing() {
    use sq_draw::InputKey;
    use sq_inspector_ui::text::block_draw::{Control, Part};
    let line = sq_inspector_ui::ec::controls_metrics::ControlsMetrics::CLIP_LINE;
    let head = sq_inspector_ui::ec::controls_metrics::ControlsMetrics::HEADER;
    let frame = CGRect::new(20.0, 90.0, 420.0, 900.0);
    let mut rig = crate::test_rig::Rig::new(text_session());
    let mut host = InspectorHost::new(real_audio());
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    let own = host.text_block.height(&host.text_model, Part::Text);
    assert!(own > 0.0, "the block measures a height");
    assert!((host.sections().height() - own).abs() < 1e-9, "the section is as tall as the block");
    assert!(host.leading());
    assert!((host.sections_y() - line).abs() < 1e-9, "right below the clip line");
    assert!(
        host.controls.top() >= host.sections_y() + own + head - 1e-9,
        "Video header, then the rows, below the block"
    );
    assert!(host.sections_y() + own <= frame.height, "inside the frame");
    let mut c = Canvas::with_size(800.0, 1200.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    let (top, bottom) = ((frame.y + host.sections_y()) as f32, (frame.y + host.sections_y() + own) as f32);
    let drawn = c.list.quads().iter().filter(|q| q.rect.y >= top - 0.01 && q.rect.max_y() <= bottom + 0.01).count();
    assert!(drawn > 0, "the block draws in its band");
    let boxf = host.text_block.frame(&host.text_model, &Control::TextBox, Part::Text).expect("text box");
    let (x, y) = ((frame.x + boxf.x + 10.0) as f32, (frame.y + host.sections_y() + boxf.y + 10.0) as f32);
    let down = InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE };
    assert!(host.handle(&down, &mut rig.cx()), "the press lands in the block");
    host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    let key = InputEvent::KeyDown { key: InputKey::Character('Z'), modifiers: InputModifiers::NONE };
    assert!(host.handle(&key, &mut rig.cx()), "the box takes the key");
    let typed = rig.session.selected_edit_clips().remove(0);
    let text = sq_text::text_generator::TextGenerator::decode(typed.generator.as_ref().expect("generator"))
        .expect("decodes")
        .0
        .text;
    assert!(text.contains('Z'), "the typed key reached the clip: {text}");
}

/// The text color of the selected text clip.
fn text_color(s: &EditorSession) -> sq_text::text_style::RGBAColor {
    let clip = s.selected_edit_clips().remove(0);
    sq_text::text_generator::TextGenerator::decode(clip.generator.as_ref().expect("generator"))
        .expect("decodes")
        .0
        .style
        .color
}

/// A text clip's Text block hosts the color picker like the Graphics panel: the Fill well opens it, a pick changes the
/// text color, closing it is one undo step.
#[test]
fn a_color_request_of_the_text_block_opens_the_picker_and_a_pick_is_one_undo_step() {
    use sq_inspector_ui::text::block_draw::{Control, Layer, Part};
    let frame = CGRect::new(20.0, 90.0, 420.0, 900.0);
    let mut rig = crate::test_rig::Rig::new(text_session());
    let mut host = InspectorHost::new(real_audio());
    host.set_window(CGRect::new(0.0, 0.0, 1000.0, 1000.0));
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    let before = text_color(&rig.session);
    let well = host.text_block.frame(&host.text_model, &Control::Well(Layer::Fill), Part::Text).expect("fill well");
    let (x, y) = ((frame.x + well.x + 4.0) as f32, (frame.y + host.sections_y() + well.y + 4.0) as f32);
    assert!(host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx()));
    host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    assert!(host.has_popover(), "the well opens the picker");
    for key in [sq_draw::InputKey::Left, sq_draw::InputKey::Down, sq_draw::InputKey::Down] {
        let e = InputEvent::KeyDown { key, modifiers: InputModifiers::NONE };
        assert!(host.handle_popover(&e, &mut rig.cx()));
    }
    assert_ne!(text_color(&rig.session), before, "the pick changed the text color");
    let esc = InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: InputModifiers::NONE };
    assert!(host.handle_popover(&esc, &mut rig.cx()));
    assert!(!host.has_popover());
    rig.session.undo();
    assert_eq!(text_color(&rig.session), before, "one picker session is one undo step");
}

/// The Fill eyedropper of the Text block samples the monitor picture and the pick is one undo step.
#[test]
fn the_text_block_eyedropper_samples_the_monitor_into_the_text_color() {
    use crate::analysis_links::eyedropper::Eyedropper;
    use sq_inspector_ui::text::block_draw::{Control, Layer, Part};
    let dropper = Eyedropper::default();
    let frame = CGRect::new(20.0, 90.0, 420.0, 900.0);
    let mut rig = crate::test_rig::Rig::new(text_session());
    let mut host = InspectorHost::new(real_audio()).with_eyedropper(dropper.clone());
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    let before = text_color(&rig.session);
    let drop = host
        .text_block
        .frame(&host.text_model, &Control::Eyedropper(Layer::Fill), Part::Text)
        .expect("fill eyedropper");
    let (x, y) = ((frame.x + drop.x + 4.0) as f32, (frame.y + host.sections_y() + drop.y + 4.0) as f32);
    assert!(host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx()));
    host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    assert!(dropper.is_armed(), "the eyedropper arms the monitor pick");
    let green = sq_draw::RgbaImage { width: 1, height: 1, pixels: vec![0, 255, 0, 255] };
    assert!(dropper.offer(Some(&green), CGRect::new(600.0, 400.0, 100.0, 100.0), 650.0, 450.0));
    host.layout(frame, &mut rig.cx());
    let after = text_color(&rig.session);
    assert_ne!(after, before, "the sample changed the text color");
    assert!((after.green - 1.0).abs() < 0.01 && after.red < 0.01, "green was picked: {after:?}");
    rig.session.undo();
    assert_eq!(text_color(&rig.session), before, "one undo step");
}

/// The Arrange and Animation parts of a text clip's Text block sit between the Controls rows (after Transform), draw inside
/// the frame, and a press in one reaches the block (Swift `arrangeFrame`, `animationFrame`).
#[test]
fn a_text_clip_shows_its_arrange_and_animation_parts_between_the_rows_and_they_take_presses() {
    use sq_inspector_ui::text::block_draw::Part;
    let frame = CGRect::new(20.0, 90.0, 420.0, 1400.0);
    let mut rig = crate::test_rig::Rig::new(text_session());
    let mut host = InspectorHost::new(real_audio());
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    host.layout(frame, &mut rig.cx());
    let slots = host.slot_frames();
    let parts: Vec<Part> = slots.iter().map(|(p, _)| *p).collect();
    assert!(parts.contains(&Part::Arrange) && parts.contains(&Part::Animation), "both parts have rows: {parts:?}");
    for (part, f) in &slots {
        let own = host.text_block.height(&host.text_model, *part);
        assert!((f.height - own).abs() < 1e-9, "{part:?} is as tall as the block says");
        assert!(
            f.y >= host.sections_y() + host.sections().height() - 1e-9,
            "{part:?} sits below the leading Text part"
        );
    }
    let (_, arrange) = slots.iter().find(|(p, _)| *p == Part::Arrange).expect("arrange");
    let mut c = Canvas::with_size(800.0, 1600.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    let hit = c
        .list
        .quads()
        .iter()
        .filter(|q| {
            q.rect.y >= (frame.y + arrange.y) as f32 - 0.01
                && q.rect.max_y() <= (frame.y + arrange.max_y()) as f32 + 0.01
        })
        .count();
    assert!(hit > 0, "the Arrange part draws in its band");
    let (x, y) = ((frame.x + 5.0) as f32, (frame.y + arrange.y + 5.0) as f32);
    assert!(
        host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx()),
        "taken by the block"
    );
    assert!(host.slot_pressed.is_some_and(|(p, _)| p == Part::Arrange));
    host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    assert!(host.slot_pressed.is_none());
}

#[test]
fn my_curves_load_into_the_keyframe_easing_and_a_library_change_is_stored() {
    use sq_draw_shell::{MemoryDefaults, SharedView};
    use sq_editor_session::MyCurves;
    let store: sq_draw_shell::SharedDefaults = Rc::new(RefCell::new(MemoryDefaults::default()));
    let mut ids = sq_core_time::SequentialIds::default();
    MyCurves::save(&mut SharedView(Rc::clone(&store)), &mut ids, &sq_core_time::EasingCurve::ease_in(), "Punchy");
    let mut host = InspectorHost::new(no_audio());
    host.set_settings_store(Rc::clone(&store));
    assert_eq!(host.controls().model.easing_library.user_curves().len(), 1, "the stored curves are listed");
    let mut library = host.controls().model.easing_library.clone();
    library.add(sq_core_time::EasingCurve::ease_out());
    host.store_my_curves(&library);
    assert_eq!(MyCurves::load(&SharedView(store)).user_curves().len(), 2, "a saved curve reaches the preferences");
}

fn session_with_transition() -> (EditorSession, Id) {
    use sq_core_effects::transition::{NewTransition, TimelineTransitions};
    use sq_core_model::{Project, SequenceFormat, Timeline, TrackKind, TransitionAlignment, TransitionKind};
    use sq_core_time::TimeRange;
    let fd = Time::new(1, 30);
    let mut ids = SequentialIds::default();
    let mut track = sq_core_model::Track::new(Id::from_u128(100), TrackKind::Video);
    let clip = |n: u128, start: i64| {
        let mut c = Clip::new(
            Id::from_u128(n),
            "C",
            Id::from_u128(900 + n),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, fd * 120),
            fd * start,
        );
        c.media_duration = Some(fd * 240);
        c
    };
    let (a, b) = (clip(1, 0), clip(2, 120));
    assert!(track.overwrite(a.clone(), &mut ids).is_ok() && track.overwrite(b.clone(), &mut ids).is_ok());
    let mut t = Timeline::new(Id::from_u128(50), "Main", SequenceFormat::new(fd), vec![track]);
    let new = NewTransition {
        kind: TransitionKind::SoftWipe,
        track: Id::from_u128(100),
        outgoing: Some(a.id),
        incoming: Some(b.id),
        duration: fd * 30,
        alignment: TransitionAlignment::Center,
        custom_before: Time::ZERO,
    };
    let id = t.add_transition(&new, &mut ids).expect("transition");
    let project = Project::new(Id::from_u128(1), "P", Vec::new(), vec![t]);
    let deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-inspector-transition"));
    (EditorSession::new(project, deps), id)
}

#[test]
fn a_selected_transition_shows_its_controls_and_a_clip_selection_brings_the_clip_back() {
    let (mut s, id) = session_with_transition();
    let mut host = InspectorHost::new(no_audio());
    s.select_transition(Some(id), false);
    host.sync(&s);
    assert!(host.shows_transition(), "Effect Controls shows the transition");
    assert!(host.transition.rows().contains(&sq_inspector_ui::audio_masks::transition_controls_model::Row::Easing));
    s.select_transition(None, false);
    host.sync(&s);
    assert!(!host.shows_transition(), "no transition selected: the clip controls are back");
}

/// D7: the Controls view fills its whole bounds, so a leading section (Text, Graphic...) must be painted after it, else
/// the gap between the clip line and "Video · whole clip" stays blank.
#[test]
fn the_leading_section_paints_over_the_controls_fill() {
    let frame = CGRect::new(0.0, 0.0, 420.0, 1400.0);
    let mut rig = crate::test_rig::Rig::new(text_session());
    let mut host = InspectorHost::new(real_audio());
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    host.layout(frame, &mut rig.cx());
    let line = sq_inspector_ui::ec::controls_metrics::ControlsMetrics::CLIP_LINE as f32;
    let mut c = Canvas::with_size(800.0, 1600.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    let quads = c.list.quads();
    let covers = |q: &sq_draw::draw_list::DrawQuad| {
        q.rect.x <= 0.5 && q.rect.w >= 419.0 && q.rect.y <= line + 0.5 && q.rect.max_y() >= line + 70.0
    };
    let last_cover = quads.iter().rposition(covers).expect("something fills the lead band");
    let after = quads[last_cover + 1..].iter().filter(|q| q.rect.y >= line && q.rect.max_y() <= line + 70.0).count();
    assert!(after > 0, "nothing of the leading section is painted over the Controls fill");
}

/// D9: a Windows mouse wheel notch (`LineDelta` through `WinScroll`: 40 px per notch, and the notch gesture on the UI
/// context) scrolls the Controls panel like the plain wheel event does.
#[test]
fn a_windows_wheel_notch_scrolls_the_controls_panel() {
    use sq_draw::scroll::{ScrollGesture, WinScroll};
    for (kind, scale) in [(TrackKind::Audio, 1.0_f32), (TrackKind::Audio, 1.5), (TrackKind::Video, 1.0)] {
        let frame = CGRect::new(20.0, 90.0, 420.0, 230.0);
        let mut s = session_with_clip(kind);
        let mut host = InspectorHost::new(real_audio());
        let mut rig = crate::test_rig::Rig::new(session()).at_scale(scale);
        std::mem::swap(&mut rig.session, &mut s);
        host.sync(&rig.session);
        host.layout(frame, &mut rig.cx());
        let max = host.sections_scroll_max() + host.controls.rows_panel.content_height();
        assert!(max > 0.0, "{kind:?}: the panel has something to scroll");
        let notch = |lines: f64| {
            let mut w = WinScroll::default();
            let g = w.wheel((lines * f64::from(WinScroll::WHEEL_DELTA)) as i32, false, false, 0.0);
            let (dx, dy) = WinScroll::pixels(&g, scale);
            (g, InputEvent::Scroll { x: 100.0 * scale, y: 150.0 * scale, dx, dy, modifiers: InputModifiers::NONE })
        };
        let moved = |host: &InspectorHost| host.sections_scroll + host.controls.rows_panel.scroll_y;
        for _ in 0..3 {
            let (g, e): (ScrollGesture, InputEvent) = notch(-1.0);
            rig.ui.gesture = Some(g);
            host.handle(&e, &mut rig.cx());
            rig.ui.gesture = None;
            host.layout(frame, &mut rig.cx());
        }
        assert!(moved(&host) > 0.0, "{kind:?} at scale {scale}: three wheel notches moved nothing");
    }
}

#[test]
fn the_audio_dropdowns_open_on_a_real_press_and_release_and_a_pick_reaches_the_project() {
    use sq_inspector_ui::audio_masks::track_audio_draw::Control;
    use sq_uikit::controls_grid::ControlsGrid;
    for scale in [1.0_f32, 1.5] {
        let frame = CGRect::new(20.0, 90.0, 420.0, 900.0);
        let mut host = InspectorHost::new(real_audio());
        let mut rig = crate::test_rig::Rig::new(session_with_clip(TrackKind::Audio)).at_scale(scale);
        host.sync(&rig.session);
        host.layout(frame, &mut rig.cx());
        let mut c = Canvas::with_size(900.0, 1000.0, None, scale);
        host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
        let track = rig
            .session
            .active_timeline()
            .expect("tl")
            .tracks
            .iter()
            .find(|t| t.kind == TrackKind::Audio)
            .expect("audio")
            .id;
        // The Effects tab holds Preset; the Track tab holds Loudness.
        for (control, tab) in [(Control::Loudness, false), (Control::Preset, true)] {
            if tab {
                let t = host.sections.audio_block_mut().expect("block");
                t.set_tab(sq_inspector_ui::audio_masks::audio_effects_tab::Tab::Effects);
                host.layout(frame, &mut rig.cx());
                host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
            }
            let f = host.sections().audio_block().and_then(|a| a.frame(control)).expect("the row");
            let (x, y) = (
                (frame.x + f.mid_x()) * f64::from(scale),
                (frame.y + host.sections_y() + ControlsGrid::HEADER_HEIGHT + f.mid_y()) * f64::from(scale),
            );
            let (x, y) = (x as f32, y as f32);
            assert!(host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx()));
            host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
            let mut menus = host.take_menus();
            assert_eq!(menus.len(), 1, "{control:?} opens one menu at scale {scale}");
            let (items, anchor) = menus.remove(0);
            assert!(anchor.contains(CGPoint::new(x as f64 / f64::from(scale), y as f64 / f64::from(scale))));
            assert!(items.len() > 1);
            if control == Control::Loudness {
                (items[2].action.as_ref().expect("row action"))(); // Streaming, -16 LUFS
                host.pump(&mut rig.cx());
                let t = rig.session.active_timeline().expect("tl");
                assert_eq!(t.track(track).and_then(|t| t.loudness_target_lufs), Some(-16.0), "scale {scale}");
            }
        }
    }
}

/// A video clip and its audio clip sharing one link, both selected (what a click on a linked pair selects).
fn session_with_linked_pair() -> EditorSession {
    let mut s = session();
    s.set_selection_follows_playhead(false);
    let link = Id::from_u128(9);
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        for (n, kind) in [(7u128, TrackKind::Video), (8, TrackKind::Audio)] {
            let track = t.tracks.iter_mut().find(|tr| tr.kind == kind).expect("a track of this kind");
            let mut c = Clip::new(
                Id::from_u128(n),
                "clip",
                Id::from_u128(70 + n),
                kind,
                sq_core_time::TimeRange::new(Time::ZERO, Time::seconds(2)),
                Time::ZERO,
            );
            c.link = Some(link);
            assert!(track.insert(c, &mut ids).is_ok());
        }
    });
    s.select(std::collections::BTreeSet::from([Id::from_u128(7), Id::from_u128(8)]), Default::default());
    s
}

#[test]
fn a_linked_pair_shows_the_audio_clips_track_sections() {
    let s = session_with_linked_pair();
    let mut host = InspectorHost::new(real_audio());
    host.sync(&s);
    assert_eq!(host.sections().mode(), ClipSectionMode::Audio, "the linked pair offers the audio sections");
    let audio_track =
        s.active_timeline().and_then(|t| t.tracks.iter().find(|tr| tr.kind == TrackKind::Audio)).map(|tr| tr.id);
    assert_eq!(host.sections().audio_track_id(), audio_track, "the sections edit the audio clip's track");
    // A video clip without a partner keeps no sections.
    let s = session_with_clip(TrackKind::Video);
    let mut host = InspectorHost::new(no_audio());
    host.sync(&s);
    assert_eq!(host.sections().mode(), ClipSectionMode::None);
}

#[test]
fn an_edit_keeps_the_sections_scroll_and_another_selection_resets_it() {
    let frame = CGRect::new(20.0, 90.0, 420.0, 230.0);
    let mut host = InspectorHost::new(real_audio());
    let mut rig = crate::test_rig::Rig::new(session_with_clip(TrackKind::Audio));
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    let wheel = |dy: f32| InputEvent::Scroll { x: 100.0, y: 150.0, dx: 0.0, dy, modifiers: InputModifiers::NONE };
    host.handle(&wheel(-60.0), &mut rig.cx());
    assert!((host.sections_scroll - 60.0).abs() < 1e-9);
    // Every edit notifies PROJECT and SELECTION together (the same clip stays selected).
    rig.session.notify(sq_editor_session::Change::PROJECT | sq_editor_session::Change::SELECTION);
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    assert!((host.sections_scroll - 60.0).abs() < 1e-9, "a committed edit keeps the scroll position");
    rig.session.select(Default::default(), Default::default());
    host.sync(&rig.session);
    assert_eq!(host.sections_scroll, 0.0, "another selection starts at the top");
}

// MARK: EQ typed into the Controls panel reaches the exported sound

/// RMS level in dB of `v`.
fn rms_db(v: &[f32]) -> f64 {
    20.0 * (v.iter().map(|x| f64::from(*x).powi(2)).sum::<f64>() / v.len() as f64).sqrt().log10()
}

/// Renders the sequence's audio like the export does (the one `AudioFeeder`) and returns the level of each window in dB.
fn render_levels(t: &sq_core_model::Timeline, hz: f64, windows: &[(f64, f64)]) -> Vec<f64> {
    use sq_media::memory_audio_source::{AudioSource, MemoryAudioSource};
    let rate = 48_000.0;
    let tone: Arc<dyn AudioSource> = Arc::new(MemoryAudioSource::mono(
        (0..96_000).map(|i| (0.1 * (2.0 * std::f64::consts::PI * hz * f64::from(i) / rate).sin()) as f32).collect(),
    ));
    let mut f = sq_playback::audio::AudioFeeder::new(t.clone(), 1024, Arc::new(move |_| Ok(Arc::clone(&tone))));
    f.handle().seek(0, false);
    let mut out = Vec::new();
    for _ in 0..(6.0 * rate / 1024.0) as usize {
        let (mut l, mut r) = (vec![0.0f32; 1024], vec![0.0f32; 1024]);
        let n = f.next_block(&mut l, &mut r);
        out.extend_from_slice(&l[..n]);
    }
    windows.iter().map(|(a, b)| rms_db(&out[(a * rate) as usize..(b * rate) as usize])).collect()
}

/// A real press and release at `at` (a point of the audio block, in points) of the host's frame.
fn click_in_audio_block(host: &mut InspectorHost, rig: &mut crate::test_rig::Rig, frame: CGRect, at: CGPoint) {
    use sq_uikit::controls_grid::ControlsGrid;
    let k = f64::from(rig.scale);
    let x = ((frame.x + at.x) * k) as f32;
    let y = ((frame.y + host.sections_y() + ControlsGrid::HEADER_HEIGHT + at.y) * k) as f32;
    host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
    host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
}

/// Types `text` and Enter into the value field of `slider` with real key events.
fn type_in_audio_field(
    host: &mut InspectorHost,
    rig: &mut crate::test_rig::Rig,
    frame: CGRect,
    slider: sq_inspector_ui::audio_masks::track_audio_draw::Slider,
    text: &str,
) {
    use sq_inspector_ui::audio_masks::track_audio_draw::Control;
    let block = host.sections().audio_block().expect("the audio block");
    let row = block.frame(Control::Slider(slider)).expect("the row is shown");
    let at = CGPoint::new(block.slider_parts(row).1.mid_x(), row.mid_y());
    click_in_audio_block(host, rig, frame, at);
    for ch in text.chars() {
        let key = if ch == '-' { sq_draw::InputKey::Minus } else { sq_draw::InputKey::Character(ch) };
        host.handle(&InputEvent::KeyDown { key, modifiers: InputModifiers::NONE }, &mut rig.cx());
    }
    host.handle(&InputEvent::KeyDown { key: sq_draw::InputKey::Enter, modifiers: InputModifiers::NONE }, &mut rig.cx());
}

#[test]
fn a_typed_eq_band_gives_its_gain_at_its_frequency_in_the_export_and_only_on_its_own_track() {
    use sq_inspector_ui::audio_masks::audio_effects_tab::Tab;
    use sq_inspector_ui::audio_masks::track_audio_draw::{Control, Slider};
    // A1: the selected clip (0-2 s) and a second clip of the same track (4-6 s); A2: an unselected clip (2-4 s).
    let mut s = session();
    s.set_selection_follows_playhead(false);
    s.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        let t = &mut p.timelines[0];
        t.tracks.push(sq_core_model::Track::new(Id::from_u128(500), TrackKind::Audio));
        let clip = |n: u128, at: i64| {
            Clip::new(
                Id::from_u128(n),
                "clip",
                Id::from_u128(70 + n),
                TrackKind::Audio,
                sq_core_time::TimeRange::new(Time::ZERO, Time::seconds(2)),
                Time::seconds(at),
            )
        };
        let a: Vec<Id> = t.tracks.iter().filter(|tr| tr.kind == TrackKind::Audio).map(|tr| tr.id).collect();
        for (track, c) in [(a[0], clip(7, 0)), (a[1], clip(8, 2)), (a[0], clip(9, 4))] {
            let tr = t.tracks.iter_mut().find(|tr| tr.id == track).expect("track");
            assert!(tr.insert(c, &mut ids).is_ok());
        }
    });
    s.select(std::collections::BTreeSet::from([Id::from_u128(7)]), Default::default());
    let windows = [(0.5, 1.5), (2.5, 3.5), (4.5, 5.5)];
    let before = render_levels(s.active_timeline().expect("timeline"), 200.0, &windows);

    let frame = CGRect::new(20.0, 90.0, 420.0, 900.0);
    let mut host = InspectorHost::new(real_audio());
    let mut rig = crate::test_rig::Rig::new(s);
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    host.sections().audio_block_mut().expect("block").set_tab(Tab::Effects);
    host.layout(frame, &mut rig.cx());
    let mut c = Canvas::with_size(900.0, 1000.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());

    // Band 2 (Bell), Frequency 200 Hz, Gain +12 dB, typed like a user on the A1 track's compressor-off block.
    let chip = host.sections().audio_block().and_then(|a| a.frame(Control::EqBand(1))).expect("the chip");
    click_in_audio_block(&mut host, &mut rig, frame, CGPoint::new(chip.mid_x(), chip.mid_y()));
    type_in_audio_field(&mut host, &mut rig, frame, Slider::EqFrequency, "200");
    type_in_audio_field(&mut host, &mut rig, frame, Slider::EqGain, "12");
    host.pump(&mut rig.cx());

    let after = render_levels(rig.session.active_timeline().expect("timeline"), 200.0, &windows);
    let gain = |i: usize| after[i] - before[i];
    assert!((gain(0) - 12.0).abs() <= 0.5, "the selected clip's 200 Hz tone gains {:.2} dB, not +12", gain(0));
    assert!(gain(1).abs() < 0.01, "the clip of the other track is untouched, got {:.3} dB", gain(1));
    // The EQ is the track's: another clip of the same track follows (the panel says so).
    assert!((gain(2) - 12.0).abs() <= 0.5, "a clip of the same track follows, got {:.2} dB", gain(2));

    // What is saved. The EQ has no band record of its own, as in Swift (`RoleVoicing`: "EQ = per-band gain"): the
    // gain is the compressor band's `gainDB`, the frequency moves the crossovers around the band.
    let saved = |rig: &crate::test_rig::Rig| {
        let t = rig.session.active_timeline().expect("timeline");
        let preset = t.tracks.iter().find(|tr| tr.kind == TrackKind::Audio).and_then(|tr| tr.audio_preset.clone());
        preset.expect("the typed EQ made the track's preset")
    };
    let band_gains = |preset: &serde_json::Value| -> Vec<f64> {
        let bands = preset["compressor"]["bands"].as_array().expect("four bands");
        bands.iter().map(|b| b["gainDB"].as_f64().unwrap_or(0.0)).collect()
    };
    let preset = saved(&rig);
    let crossovers: Vec<f64> = preset["compressor"]["crossoversHz"]
        .as_array()
        .expect("crossovers")
        .iter()
        .filter_map(serde_json::Value::as_f64)
        .collect();
    assert_eq!(band_gains(&preset), [0.0, 12.0, 0.0, 0.0], "only the typed band's gainDB changed");
    let middle = (crossovers[0] * crossovers[1]).sqrt();
    assert!((middle - 200.0).abs() < 2.0, "the bell's middle is the typed 200 Hz, got {middle:.1}: {crossovers:?}");

    // A typed `+3` is relative to the field's value (Swift `ScrubMath.evaluate`), a plain `3` and `-4` are absolute.
    for (typed, want) in [("+3", 15.0), ("3", 3.0), ("-4", -4.0)] {
        type_in_audio_field(&mut host, &mut rig, frame, Slider::EqGain, typed);
        host.pump(&mut rig.cx());
        assert_eq!(band_gains(&saved(&rig))[1], want, "typed {typed:?} into a Gain field that held the last value");
    }
}

#[test]
fn a_linked_pair_with_linked_selection_on_offers_the_track_tabs_and_the_eq() {
    // Linux round 5: a click on the audio clip of a linked pair showed no Track/Effects tabs and no EQ.
    use sq_inspector_ui::audio_masks::audio_effects_tab::Tab;
    use sq_inspector_ui::audio_masks::track_audio_draw::{Control, Slider};
    let frame = CGRect::new(20.0, 90.0, 420.0, 900.0);
    let mut host = InspectorHost::new(real_audio());
    let mut rig = crate::test_rig::Rig::new(session_with_linked_pair());
    assert!(rig.session.linked_selection(), "Linked Selection is on by default");
    host.sync(&rig.session);
    host.layout(frame, &mut rig.cx());
    assert_eq!(host.sections().mode(), ClipSectionMode::Audio);
    let block = host.sections().audio_block().expect("the audio block of the pair's audio track");
    assert!(block.frame(Control::Tab).is_some(), "the Track and Effects tabs are there");
    host.sections().audio_block_mut().expect("block").set_tab(Tab::Effects);
    host.layout(frame, &mut rig.cx());
    let block = host.sections().audio_block().expect("block");
    for c in [Control::EqGraph, Control::Slider(Slider::EqFrequency), Control::Slider(Slider::EqGain)] {
        assert!(block.frame(c).is_some(), "{c:?} is reachable from the linked pair");
    }
    // The audio clip alone (Alt+click) shows the same block.
    let mut s = session_with_linked_pair();
    s.select(std::collections::BTreeSet::from([Id::from_u128(8)]), Default::default());
    let mut host = InspectorHost::new(real_audio());
    host.sync(&s);
    assert_eq!(host.sections().mode(), ClipSectionMode::Audio);
}
