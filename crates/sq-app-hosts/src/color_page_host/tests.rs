//! Tests of the Color page host: the page switch, the panels' frames, a click in Sources and the status text.

use super::*;
use crate::test_rig::Rig;
use sq_editor_session::SessionDeps;
use sq_uikit::controls_grid::CGRect;

fn rig() -> Rig {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    Rig::new(EditorSession::new(
        project,
        SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-color-tests")),
    ))
}

fn dock(page: WorkspacePage) -> ShellDock {
    let mut d = ShellDock::new(sq_editor_session::WorkspaceStore::default());
    d.set_frame(CGRect::new(0.0, 0.0, 1600.0, 900.0));
    d.set_page(page);
    d
}

#[test]
fn the_edit_page_leaves_the_monitor_card_alone_and_hides_nothing() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let mut d = dock(WorkspacePage::Edit);
    let card = CGRect::new(10.0, 20.0, 600.0, 400.0);
    assert_eq!(host.monitor_card(card, &d), card);
    host.layout(&mut d, &mut rig.cx());
    assert!(!host.is_on_color_page());
    assert!(d.transiently_hidden().is_empty());
    assert_eq!(host.grade_status(&rig.session), "");
}

#[test]
fn the_color_page_takes_the_viewer_header_off_the_monitor_card_and_hides_steps_until_pro() {
    let mut host = ColorPageHost::new();
    host.shows_viewer_header = true; // the Windows-style strip these cases cover
    let mut rig = rig();
    let mut d = dock(WorkspacePage::Color);
    let card = CGRect::new(10.0, 20.0, 600.0, 400.0);
    let body = host.monitor_card(card, &d);
    assert!(body.y > card.y && (body.max_y() - card.max_y()).abs() < 1e-9);
    host.layout(&mut d, &mut rig.cx());
    assert!(host.is_on_color_page());
    assert!(d.transiently_hidden().contains(&PanelID::Steps), "no Pro grade, no Steps panel");
    assert!(host.frames.contains_key(&Part::Grade) && host.frames.contains_key(&Part::Header));
    let mut c = Canvas::with_size(1600.0, 900.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
}

#[test]
fn a_press_outside_every_panel_is_not_taken_and_clears_the_focus() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let mut d = dock(WorkspacePage::Color);
    let card = host.monitor_card(CGRect::new(10.0, 20.0, 600.0, 400.0), &d);
    let _ = card;
    host.layout(&mut d, &mut rig.cx());
    host.focus = Some(Part::Grade);
    let down = InputEvent::MouseDown { x: 1.0, y: 1.0, modifiers: InputModifiers::default() };
    assert!(!host.handle(&down, &mut rig.cx()));
    assert_eq!(host.focus, None);
}

#[test]
fn a_press_in_the_color_settings_gives_them_the_focus() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let mut d = dock(WorkspacePage::Color);
    host.monitor_card(CGRect::new(0.0, 0.0, 600.0, 400.0), &d);
    host.layout(&mut d, &mut rig.cx());
    let f = host.frames[&Part::Grade];
    let (x, y) = ((f.x + f.width / 2.0) as f32, (f.y + f.height / 2.0) as f32);
    let down = InputEvent::MouseDown { x, y, modifiers: InputModifiers::default() };
    assert!(host.handle(&down, &mut rig.cx()));
    assert_eq!(host.focus, Some(Part::Grade));
    assert!(host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx()));
    assert_eq!(host.target(&rig.session), None, "an empty project grades nothing");
}

#[test]
fn the_header_is_gone_again_after_switching_back_to_edit() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let mut d = dock(WorkspacePage::Color);
    host.monitor_card(CGRect::new(0.0, 0.0, 600.0, 400.0), &d);
    host.layout(&mut d, &mut rig.cx());
    d.set_page(WorkspacePage::Edit);
    host.monitor_card(CGRect::new(0.0, 0.0, 600.0, 400.0), &d);
    host.layout(&mut d, &mut rig.cx());
    assert!(!host.frames.contains_key(&Part::Header) && d.transiently_hidden().is_empty());
}

/// Lays the page out on a 1600 x 900 dock, the Program card at the top left.
fn laid_out(host: &mut ColorPageHost, rig: &mut Rig) -> ShellDock {
    let mut d = dock(WorkspacePage::Color);
    host.monitor_card(CGRect::new(0.0, 0.0, 600.0, 400.0), &d);
    host.layout(&mut d, &mut rig.cx());
    d
}

#[test]
fn the_color_strip_keeps_room_for_its_tools_and_a_press_on_them_is_taken() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let d = laid_out(&mut host, &mut rig);
    assert!((d.strip_tools)(PanelID::ColorInspector) > 100.0, "Simple | Pro and the menu need room");
    let strip = host.strips[&StripPanel::ColorInspector];
    let (_, pro) = ColorStripToolsDraw::frames(StripPanel::ColorInspector, strip)
        .into_iter()
        .find(|f| f.0 == sq_inspector_ui::color::color_viewer_header_draw::StripButton::Pro)
        .expect("Pro segment");
    let (x, y) = (pro.mid_x() as f32, pro.mid_y() as f32);
    assert!(host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::default() }, &mut rig.cx()));
    assert!(host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx()));
    assert_eq!(host.pressed_tool, None);
    let mut c = Canvas::with_size(1600.0, 900.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
}

#[test]
fn the_edit_page_reserves_no_strip_room() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let mut d = dock(WorkspacePage::Edit);
    host.monitor_card(CGRect::new(0.0, 0.0, 600.0, 400.0), &d);
    host.layout(&mut d, &mut rig.cx());
    assert!(host.strips.is_empty());
    assert_eq!((d.strip_tools)(PanelID::ColorInspector), 0.0);
}

#[test]
fn before_after_reaches_the_engine() {
    use sq_core_color::{ColorBypass, ColorBypassMode};
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    laid_out(&mut host, &mut rig);
    let bypass = ColorBypass { clips: std::collections::BTreeSet::from([Id::fixed(7)]), mode: ColorBypassMode::Before };
    if let Some(c) = &mut host.controller {
        c.events.push(ColorGradeEvent::SetColorBypass(Some(bypass.clone())));
    }
    host.collect(&mut rig.cx());
    let stub = rig.session.engine().as_any().downcast_ref::<sq_editor_session::StubProgramEngine>();
    assert_eq!(stub.and_then(|s| s.color_bypass.clone()), Some(bypass));
}

struct DecisionPicker(PathBuf);

impl sq_app_shell::ShellFilePicker for DecisionPicker {
    fn choose_project(&mut self) -> sq_runtime::ModalAsk<Option<PathBuf>> {
        sq_app_shell::answered(None)
    }
    fn choose_save_location(&mut self, _: &str, _: &str) -> sq_runtime::ModalAsk<Option<PathBuf>> {
        sq_app_shell::answered(None)
    }
    fn choose_media(&mut self) -> sq_runtime::ModalAsk<Vec<PathBuf>> {
        sq_app_shell::answered(Vec::new())
    }
    fn choose_file(&mut self, _: &str, _: Option<&std::path::Path>) -> sq_runtime::ModalAsk<Option<PathBuf>> {
        sq_app_shell::answered(Some(self.0.clone()))
    }
}

#[test]
fn a_decision_file_is_asked_for_through_the_file_picker() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    rig.services.files = Box::new(DecisionPicker(PathBuf::from("/tmp/look.cdl")));
    laid_out(&mut host, &mut rig);
    host.steps.requests.push(StepsHostRequest::ImportDecision(Id::fixed(3)));
    host.collect(&mut rig.cx());
    assert_eq!(host.decisions.len(), 1);
    host.pump(&mut rig.cx());
    assert!(host.decisions.is_empty());
    assert!(
        rig.events.iter().any(|e| matches!(e, AppEvent::Status(s) if s.contains("look.cdl"))),
        "{:?}",
        rig.events.len()
    );
}

#[test]
fn a_decision_file_sets_the_selected_steps_primaries_and_undoes() {
    use sq_core_time::Time;
    let file = std::env::temp_dir().join(format!("sq-decision-{}.cdl", std::process::id()));
    let cdl = r#"<ColorDecisionList xmlns="urn:ASC:CDL:v1.01"><ColorDecision><ColorCorrection id="warm">
<SOPNode><Slope>1.2 1 0.8</Slope><Offset>0.05 0 0</Offset><Power>1 1 1</Power></SOPNode>
<SATNode><Saturation>0.7</Saturation></SATNode></ColorCorrection></ColorDecision></ColorDecisionList>"#;
    std::fs::write(&file, cdl).expect("write cdl");
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    rig.services.files = Box::new(DecisionPicker(file.clone()));
    let clip = rig.session.add_adjustment_layer(None, None, Time::seconds(5)).expect("adjustment layer");
    rig.session.set_selection([clip].into(), Default::default());
    laid_out(&mut host, &mut rig);
    let step = {
        let Some(controller) = &mut host.controller else { panic!("no controller") };
        let Some(m) = controller.model_mut() else { panic!("no model for the selected clip") };
        m.start_empty_graph();
        ColorGradeHost { controller, session: &mut rig.session, clipboard: &mut host.clipboard }.pump();
        controller.model().and_then(|m| m.selected_step()).expect("the new graph selects its step")
    };
    let primaries = |rig: &Rig| {
        let t = rig.session.active_timeline().expect("timeline");
        let c = t.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == clip).expect("clip");
        c.effects
            .iter()
            .filter_map(|e| e.color_graph.as_ref())
            .find_map(|g| g.steps().iter().find(|s| s.id == step))
            .map(|s| s.primaries.clone())
    };
    let neutral = primaries(&rig).expect("step in the session");

    host.steps.requests.push(StepsHostRequest::ImportDecision(step));
    host.collect(&mut rig.cx());
    host.pump(&mut rig.cx());
    let applied = primaries(&rig).expect("step in the session");
    assert_eq!(applied.saturation, 0.7);
    assert_eq!(applied.gain.r, 1.2);
    assert!(rig.events.iter().any(|e| matches!(e, AppEvent::Status(s) if s.contains("Applied color decision warm"))));

    assert!(rig.session.undo(), "one undo step");
    assert_eq!(primaries(&rig), Some(neutral));
    let _ = std::fs::remove_file(&file);
}

#[test]
fn the_scopes_measure_the_program_picture() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let picture = MonitorPicture::default();
    host.set_picture(picture.clone());
    laid_out(&mut host, &mut rig);
    let before = host.scopes.image_generation();
    picture.set(Some(sq_draw::RgbaImage::filled(64, 36, sq_draw::Color::WHITE)));
    let mut c = Canvas::with_size(1600.0, 900.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    assert!(host.scopes.image_generation() > before, "the pictures were rendered");
    assert_eq!(host.scopes.source.label(), "PROGRAM", "the head names the monitor the scope reads");
    let after = host.scopes.image_generation();
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    assert_eq!(host.scopes.image_generation(), after, "an unchanged frame is measured once");
}

#[test]
fn the_scope_pictures_go_to_the_scope_slots_once_per_change() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let picture = MonitorPicture::default();
    host.set_picture(picture.clone());
    laid_out(&mut host, &mut rig);
    picture.set(Some(sq_draw::RgbaImage::filled(64, 36, sq_draw::Color::WHITE)));
    let mut c = Canvas::with_size(1600.0, 900.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    let uploads = host.take_image_uploads();
    assert!(!uploads.is_empty() && uploads.iter().all(|u| (2..4).contains(&u.slot) && u.at.is_none()));
    assert!(uploads.iter().any(|u| u.image.pixels.iter().any(|&b| b != 0)), "a trace was drawn");
    assert!(host.take_image_uploads().is_empty(), "an unchanged picture is not sent again");
}

#[test]
fn the_header_and_strip_buttons_are_accessibility_nodes() {
    use sq_app_shell::A11yAction;
    let mut host = ColorPageHost::new();
    host.shows_viewer_header = true; // the Windows-style strip these cases cover
    let mut rig = rig();
    let mut off = sq_draw::A11y::new(false);
    host.a11y(&mut off);
    assert!(off.nodes().is_empty());
    laid_out(&mut host, &mut rig);
    let mut a = sq_draw::A11y::new(true);
    host.a11y(&mut a);
    let labels: Vec<&str> = a.nodes().iter().filter_map(|(_, n)| n.label()).collect();
    for want in ["Before", "After", "Split", "Simple", "Pro"] {
        assert!(labels.contains(&want), "{want} missing in {labels:?}");
    }
    let pro = a.nodes().iter().find(|(_, n)| n.label() == Some("Pro")).map(|(id, _)| *id).expect("Pro node");
    assert!(host.a11y_action(pro, A11yAction::Click, &mut rig.cx()));
    assert!(!host.a11y_action(accesskit::NodeId(1), A11yAction::Click, &mut rig.cx()), "foreign id");
}

#[test]
fn the_edit_page_has_no_color_nodes() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let mut d = dock(WorkspacePage::Edit);
    host.layout(&mut d, &mut rig.cx());
    let mut a = sq_draw::A11y::new(true);
    host.a11y(&mut a);
    assert!(a.nodes().is_empty());
}

#[test]
fn the_grade_panels_controls_are_accessibility_nodes() {
    use sq_core_time::Time;
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = rig.session.add_adjustment_layer(None, None, Time::seconds(5)).expect("adjustment layer");
    rig.session.set_selection([clip].into(), Default::default());
    laid_out(&mut host, &mut rig);
    let mut a = sq_draw::A11y::new(true);
    host.a11y(&mut a);
    let grade: Vec<_> = a.nodes().iter().filter(|(_, n)| n.label().is_some()).collect();
    let sliders = grade.iter().filter(|(_, n)| n.role() == accesskit::Role::Slider).count();
    assert!(
        sliders > 0,
        "the Simple grade lists its sliders: {:?}",
        grade.iter().map(|(_, n)| n.label()).collect::<Vec<_>>()
    );
    assert!(grade.iter().all(|(_, n)| n.label().is_some_and(|l| !l.is_empty())));
}

#[test]
fn the_white_balance_eyedropper_is_armed_by_the_panel_and_its_pick_is_consumed() {
    let dropper = Eyedropper::default();
    let mut host = ColorPageHost::new().with_eyedropper(dropper.clone());
    let mut rig = rig();
    laid_out(&mut host, &mut rig);
    host.pump(&mut rig.cx());
    assert!(host.controller.as_ref().is_some_and(|c| c.can_pick_screen_color));
    if let Some(c) = &mut host.controller {
        c.events.push(ColorGradeEvent::PickScreenColor { key: Id::fixed(7), effect: 1 });
    }
    host.collect(&mut rig.cx());
    assert!(dropper.is_armed());
    host.pump(&mut rig.cx());
    assert!(host.controller.as_ref().is_some_and(|c| c.eyedropper_armed), "the button draws armed");
    // The monitor answers with a click outside the picture: the pick ends, nothing is left armed.
    assert!(dropper.offer(None, CGRect::new(0.0, 0.0, 10.0, 10.0), 50.0, 50.0));
    host.pump(&mut rig.cx());
    assert_eq!(dropper.take_answer(), None, "the host took the answer");
    assert!(!dropper.is_armed());
    host.pump(&mut rig.cx());
    assert!(host.controller.as_ref().is_some_and(|c| !c.eyedropper_armed), "the button is released");
}

/// The whole flow on a graded clip: the panel arms the picker, the monitor answers with a warm pixel, Temperature and Tint
/// move so that pixel becomes neutral (one undo step).
#[test]
fn a_white_balance_pick_on_a_warm_pixel_cools_the_clip_and_undoes() {
    use sq_core_time::Time;
    use sq_inspector_ui::color::color_inspector_model::ColorParam;
    let dropper = Eyedropper::default();
    let mut host = ColorPageHost::new().with_eyedropper(dropper.clone());
    let mut rig = rig();
    let clip = rig.session.add_adjustment_layer(None, None, Time::seconds(5)).expect("adjustment layer");
    rig.session.set_selection([clip].into(), Default::default());
    laid_out(&mut host, &mut rig);
    host.pump(&mut rig.cx());
    let (key, effect, before) = {
        let c = ColorPageHost::controller(&mut host.controller, &mut rig.session);
        let m = c.model().expect("a color model for the adjustment layer");
        let e = m.effects()[0].id;
        (c.key().expect("key"), e, (m.value(e, ColorParam::Temperature), m.value(e, ColorParam::Tint)))
    };
    host.controller.as_mut().expect("controller").events.push(ColorGradeEvent::PickScreenColor { key, effect });
    host.collect(&mut rig.cx());
    assert!(dropper.is_armed());
    // A warm gray (red above blue), as the monitor's answer solves it from the frame.
    let controller = host.controller.as_mut().expect("controller");
    let mut clipboard = Default::default();
    let linear = [srgb_to_linear(0.8), srgb_to_linear(0.7), srgb_to_linear(0.55)];
    controller.finish_white_balance(&mut rig.session, &mut clipboard, key, effect, Some(linear));
    let m = controller.model().expect("model");
    let after = (m.value(effect, ColorParam::Temperature), m.value(effect, ColorParam::Tint));
    assert_ne!(before, after, "the pick moved Temperature or Tint: {before:?} -> {after:?}");
    assert!(after.0 < before.0, "a warm pick cools the picture: {before:?} -> {after:?}");
    assert!(rig.session.undo(), "one undo step");
}

#[test]
fn a_saturated_white_balance_pick_says_it_could_not_balance_fully() {
    use sq_core_time::Time;
    let dropper = Eyedropper::default();
    let mut host = ColorPageHost::new().with_eyedropper(dropper);
    let mut rig = rig();
    let clip = rig.session.add_adjustment_layer(None, None, Time::seconds(5)).expect("adjustment layer");
    rig.session.set_selection([clip].into(), Default::default());
    laid_out(&mut host, &mut rig);
    host.pump(&mut rig.cx());
    let (key, effect) = {
        let c = ColorPageHost::controller(&mut host.controller, &mut rig.session);
        let m = c.model().expect("a color model");
        (c.key().expect("key"), m.effects()[0].id)
    };
    let controller = host.controller.as_mut().expect("controller");
    let mut clipboard = Default::default();
    controller.events.clear();
    controller.finish_white_balance(&mut rig.session, &mut clipboard, key, effect, Some([1.0, 0.02, 0.0]));
    assert!(controller.events.iter().any(|e| matches!(e, ColorGradeEvent::Notice(l) if l.contains("too saturated"))));
}

#[test]
fn srgb_picks_become_linear_light() {
    assert_eq!(srgb_to_linear(0.0), 0.0);
    assert!((srgb_to_linear(1.0) - 1.0).abs() < 1e-6);
    assert!((srgb_to_linear(0.5) - 0.214_04).abs() < 1e-4);
}

#[test]
fn the_white_balance_pick_averages_a_linear_patch_of_the_rendered_frame() {
    use crate::analysis_links::eyedropper::Pick;
    use crate::{LinearImage, MonitorPicture};
    // 8 x 8 frame, linear 0.5 everywhere except the pixel under the pick (1.0): the 5 x 5 patch mean sits between.
    let (w, h) = (8usize, 8usize);
    let mut bytes = Vec::new();
    for i in 0..w * h {
        let v = if i == 3 * w + 3 { 1.0 } else { 0.5 };
        for c in [v, v, v, 1.0] {
            bytes.extend(exr::prelude::f16::from_f32(c).to_bits().to_le_bytes());
        }
    }
    let picture = MonitorPicture::default();
    picture.set(None);
    picture
        .set_linear(Some(std::sync::Arc::new(move || Some(LinearImage { width: w, height: h, bytes: bytes.clone() }))));
    let pick = Pick { rgb: (0.9, 0.9, 0.9), at: (0.4, 0.4), on_picture: true };
    let got = ColorPageHost::picked_linear(Some(&picture), pick);
    let expected = (24.0 * 0.5 + 1.0) / 25.0;
    assert!((got[0] - expected).abs() < 1e-3, "patch mean {got:?}, not the sRGB pixel");
    let none = ColorPageHost::picked_linear(None, pick);
    assert!((none[0] - srgb_to_linear(0.9)).abs() < 1e-6, "without a linear picture the shown pixel is used");
}

#[test]
fn the_split_divider_marks_the_middle_of_the_picture_only_while_split_shows() {
    use sq_core_time::Time;
    use sq_inspector_ui::color::color_page_models::ColorCompareMode;
    let mut host = ColorPageHost::new();
    host.shows_viewer_header = true;
    let mut rig = rig();
    let clip = rig.session.add_adjustment_layer(None, None, Time::seconds(5)).expect("adjustment layer");
    rig.session.set_selection([clip].into(), Default::default());
    let mut d = dock(WorkspacePage::Color);
    host.monitor_card(CGRect::new(10.0, 20.0, 600.0, 400.0), &d);
    host.layout(&mut d, &mut rig.cx());
    host.set_picture_view(CGRect::new(110.0, 60.0, 400.0, 225.0), 1920.0);
    assert_eq!(host.split_divider(), None, "After shows no divider");
    let controller = ColorPageHost::controller(&mut host.controller, &mut rig.session);
    controller.set_compare(&mut rig.session, ColorCompareMode::Split);
    let line = host.split_divider().expect("Split shows the divider");
    assert_eq!((line.x, line.width, line.y, line.height), (310.0, 1.0, 60.0, 225.0), "half way over the picture");
    let mut c = Canvas::with_size(1600.0, 900.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    // The picture sticks out of the card at the top: the line is cut to the visible part.
    let cut = ColorPageHost::split_divider_frame(
        CGRect::new(110.0, 0.0, 400.0, 225.0),
        1920.0,
        CGRect::new(10.0, 50.0, 600.0, 300.0),
        1.0,
    )
    .expect("visible");
    assert_eq!((cut.y, cut.height), (50.0, 175.0));
    assert!(
        ColorPageHost::split_divider_frame(
            CGRect::new(0.0, 0.0, 10.0, 10.0),
            100.0,
            CGRect::new(50.0, 50.0, 5.0, 5.0),
            1.0
        )
        .is_none()
    );
}

#[test]
fn the_timelines_strip_gets_its_copy_paste_tools_on_the_color_page_like_the_other_color_panels() {
    use sq_inspector_ui::color::color_viewer_header_draw::StripPanel;
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let mut d = dock(WorkspacePage::Color);
    host.monitor_card(CGRect::new(10.0, 20.0, 600.0, 400.0), &d);
    host.layout(&mut d, &mut rig.cx());
    assert!(d.shows(PanelID::Timeline), "the Color page keeps the timeline");
    assert!(host.tool_widths.contains_key(&StripPanel::Timeline), "room reserved at the timeline strip's right end");
    assert!(host.strips.contains_key(&StripPanel::Timeline), "the strip takes presses for its buttons");
}

#[test]
fn add_step_without_a_graph_menu_beeps_instead_of_doing_nothing() {
    use sq_inspector_ui::color::color_grade_controller::{ColorGradeEvent, ColorMenuCommand};
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let mut d = dock(WorkspacePage::Color);
    host.monitor_card(CGRect::new(10.0, 20.0, 600.0, 400.0), &d);
    host.layout(&mut d, &mut rig.cx());
    let controller = host.controller.as_mut().expect("controller");
    controller.events.clear();
    controller.run_menu_command(&mut rig.session, &mut host.clipboard, ColorMenuCommand::Beep);
    assert!(controller.events.iter().any(|e| matches!(e, ColorGradeEvent::Beep)));
}

/// Swift LUTLibraryStore: Import LUTs copies the file into the library, the model lists it, a star sticks.
#[test]
fn imported_luts_land_in_the_library_and_the_model_lists_them_and_stars_stick() {
    use sq_core_time::{Time, Timestamp};
    use sq_inspector_ui::color::color_inspector_model::ColorInspectorEvent as E;
    let dir = crate::test_rig::unique_dir("sq-app-hosts-lut-library");
    let src = dir.join("Warm.cube");
    std::fs::create_dir_all(&dir).expect("dir");
    // A valid 2 x 2 x 2 table: the import refuses a .cube whose rows do not match its size.
    let rows: String = (0..8).map(|i| format!("{} {} {}\n", i & 1, (i >> 1) & 1, (i >> 2) & 1)).collect();
    std::fs::write(&src, format!("LUT_3D_SIZE 2\n{rows}")).expect("write cube");
    let library = sq_library::lutlibrary::LUTLibrary::new(dir.join("LUTs"), Timestamp::from_unix_seconds(1.0));
    let mut host = ColorPageHost::new().with_lut_library(library);
    let mut rig = rig();
    let clip = rig.session.add_adjustment_layer(None, None, Time::seconds(5)).expect("adjustment layer");
    rig.session.set_selection([clip].into(), Default::default());
    laid_out(&mut host, &mut rig);
    let events = |host: &mut ColorPageHost, e: Vec<E>| {
        host.controller.as_mut().expect("controller").host_lut_events.extend(e);
    };
    events(&mut host, vec![E::ImportLuts(vec![src.to_string_lossy().into_owned()])]);
    host.pump(&mut rig.cx());
    let listed = |host: &ColorPageHost| {
        host.controller.as_ref().and_then(|c| c.model()).map(|m| m.library_luts().to_vec()).unwrap_or_default()
    };
    assert_eq!(listed(&host).iter().map(|e| e.file_name.as_str()).collect::<Vec<_>>(), ["Warm.cube"]);
    assert!(dir.join("LUTs").join("Warm.cube").exists(), "copied, the original stays");
    events(&mut host, vec![E::ToggleFavouriteLut("Warm.cube".into())]);
    host.pump(&mut rig.cx());
    assert!(listed(&host)[0].is_favourite);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Presses the Pro empty state's button through the page host (the real event path) and returns whether a graph exists.
fn press_pro_start(which: sq_inspector_ui::color::color_grade_draw::Control) -> bool {
    press_pro_start_with(which, true).0
}

/// `select` false leaves nothing selected: the target is the whole sequence. Returns (graph exists, Pro tab shown, graph active).
fn press_pro_start_with(which: sq_inspector_ui::color::color_grade_draw::Control, select: bool) -> (bool, bool, bool) {
    use sq_core_time::Time;
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = rig.session.add_adjustment_layer(None, None, Time::seconds(5)).expect("adjustment layer");
    rig.session.set_selection(if select { [clip].into() } else { Default::default() }, Default::default());
    let mut d = laid_out(&mut host, &mut rig);
    {
        let Some(controller) = &mut host.controller else { panic!("no controller") };
        let Some(m) = controller.model_mut() else { panic!("no model") };
        m.set_active_grade(sq_core_color::ActiveGrade::Pro);
        ColorGradeHost { controller, session: &mut rig.session, clipboard: &mut host.clipboard }.pump();
    }
    host.layout(&mut d, &mut rig.cx());
    let mut c = Canvas::with_size(1600.0, 900.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    let f = host.frames[&Part::Grade];
    let rows = {
        let controller = host.controller.as_ref().expect("controller");
        let steps_shown = controller.steps_shown();
        host.grade.rows(controller.model().expect("model"), steps_shown)
    };
    let hit = rows
        .iter()
        .find_map(|r| r.controls.iter().find(|c| c.0 == which).map(|c| (r.y + c.1.y + c.1.height / 2.0, c.1)))
        .expect("the button is a row control");
    let (x, y) = ((f.x + hit.1.x + hit.1.width / 2.0) as f32, (f.y + hit.0) as f32);
    let down = InputEvent::MouseDown { x, y, modifiers: InputModifiers::default() };
    assert!(host.handle(&down, &mut rig.cx()));
    assert!(host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx()));
    // The next frames (the Steps panel joins the layout) must not change what the panel shows.
    for _ in 0..3 {
        // The app reports the session's changes after the event: the edit, then the layer's selection.
        host.on_change(sq_editor_session::Change::PROJECT, &mut rig.cx());
        host.on_change(sq_editor_session::Change::SELECTION, &mut rig.cx());
        host.layout(&mut d, &mut rig.cx());
        host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    }
    let model = host.controller.as_ref().and_then(|c| c.model());
    (
        model.is_some_and(|m| m.graph().is_some()),
        model.is_some_and(|m| m.shown_grade() == sq_core_color::ActiveGrade::Pro),
        model.is_some_and(|m| m.graph().is_some_and(|g| g.is_active)),
    )
}

#[test]
fn start_empty_in_the_pro_empty_state_creates_the_graph() {
    assert!(press_pro_start(sq_inspector_ui::color::color_grade_draw::Control::StartEmpty));
}

#[test]
fn start_from_simple_in_the_pro_empty_state_creates_the_graph() {
    assert!(press_pro_start(sq_inspector_ui::color::color_grade_draw::Control::StartFromSimple));
}

#[test]
fn start_empty_on_the_whole_sequence_shows_the_new_timeline_grade_on_the_pro_tab() {
    let r = press_pro_start_with(sq_inspector_ui::color::color_grade_draw::Control::StartEmpty, false);
    assert_eq!(r, (true, true, true), "graph created, Pro tab kept, the new grade is active");
}

#[test]
fn the_scopes_follow_the_source_monitor_only_while_it_is_the_active_panel() {
    use sq_draw_monitor::scopes_panel::ScopeSource::{Program, Source};
    assert_eq!(choose_scope_source(Some(PanelID::SourceMonitor), true), Source);
    assert_eq!(choose_scope_source(Some(PanelID::ProgramMonitor), true), Program);
    assert_eq!(choose_scope_source(Some(PanelID::Timeline), true), Program);
    assert_eq!(choose_scope_source(None, true), Program);
    // No Source monitor in this build: Program, whatever is focused.
    assert_eq!(choose_scope_source(Some(PanelID::SourceMonitor), false), Program);
}

#[test]
fn switching_the_scopes_source_forgets_the_last_measure_and_the_color_page_stays_on_program() {
    let mut host = ColorPageHost::default();
    host.set_source_picture(MonitorPicture::default());
    host.set_focused_panel(Some(PanelID::SourceMonitor));
    assert_eq!(host.scope_source, ScopeSource::Source);
    host.set_focused_panel(Some(PanelID::Timeline));
    assert_eq!(host.scope_source, ScopeSource::Program);
    host.on_color_page = true;
    host.set_focused_panel(Some(PanelID::SourceMonitor));
    assert_eq!(host.scope_source, ScopeSource::Program);
}

/// How the typing of a value ends.
#[derive(Clone, Copy)]
enum Ending {
    Enter,
    Tab,
    ClickAway,
    Escape,
}

/// Which clip the Simple page grades in the tests below.
#[derive(Clone, Copy, PartialEq)]
enum Subject {
    /// An Adjustment Layer: it carries a Color effect from the start.
    Adjustment,
    /// A footage clip without any Color effect: the first edit has to create the effect.
    Footage,
}

/// Puts the clip on the sequence and selects it; the Color page is laid out and pumped.
fn select_subject(host: &mut ColorPageHost, rig: &mut Rig, subject: Subject) -> sq_core_time::Id {
    use sq_core_time::{Id, Time, TimeRange};
    let clip = match subject {
        Subject::Adjustment => {
            rig.session.add_adjustment_layer(None, None, Time::seconds(5)).expect("adjustment layer")
        }
        Subject::Footage => {
            let id = Id::from_u128(0xF007);
            rig.session.perform("Setup", None, |p| {
                let mut ids = SequentialIds::default();
                let t = &mut p.timelines[0];
                let c = sq_core_model::Clip::new(
                    id,
                    "wide.mp4",
                    Id::from_u128(0xF008),
                    sq_core_model::TrackKind::Video,
                    TimeRange::new(Time::ZERO, Time::seconds(5)),
                    Time::ZERO,
                );
                assert!(t.tracks[0].insert(c, &mut ids).is_ok());
            });
            id
        }
    };
    rig.session.set_selection([clip].into(), Default::default());
    laid_out(host, rig);
    host.pump(&mut rig.cx());
    clip
}

/// The screen position of the Exposure slider of the Simple page: `fraction` along its track (the number field sits
/// to the right of the track; `fraction` 1.0 is the right end of the whole control, inside the number).
fn exposure_point(host: &ColorPageHost, fraction: f64) -> (f32, f32) {
    slider_point(host, sq_inspector_ui::color::color_inspector_model::ColorParam::Exposure, fraction)
}

/// Like `exposure_point` for any Simple slider.
fn slider_point(
    host: &ColorPageHost,
    param: sq_inspector_ui::color::color_inspector_model::ColorParam,
    fraction: f64,
) -> (f32, f32) {
    use sq_inspector_ui::color::color_grade_draw::{Control, Slider};
    let controller = host.controller.as_ref().expect("controller");
    let model = controller.model().expect("model");
    let slider = Slider::Param(model.effects()[0].id, param);
    let rows = host.grade.rows(model, controller.steps_shown());
    // Control rects are relative to their row.
    let (row_y, r) = rows
        .iter()
        .find_map(|row| row.controls.iter().find(|(c, _)| *c == Control::Slider(slider)).map(|(_, r)| (row.y, *r)))
        .expect("slider row");
    let f = host.frames[&Part::Grade];
    let track = r.width - sq_inspector_ui::color::color_grade_draw::Mac::VALUE_COLUMN;
    let along = if fraction >= 1.0 { r.width } else { track * fraction };
    ((f.x + r.x + along) as f32, (f.y + row_y + r.mid_y()) as f32)
}

/// The stored Exposure of `clip` (the first Color effect) and how many Color effects it has.
fn stored_exposure(rig: &Rig, clip: sq_core_time::Id) -> (f32, usize) {
    use sq_core_color::ClipGradeExt;
    use sq_core_time::Time;
    let t = rig.session.active_timeline().expect("timeline");
    let c = t.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == clip).expect("clip");
    let color = c.color_at_local(Time::ZERO);
    (color.effects().first().map_or(0.0, |e| e.basic.exposure), color.effects().len())
}

/// A mid gray as the renderer grades it with the clip's stored color (`pipeline_from_clip_color`, the one path preview
/// and export share): the red channel, 0.5 for an ungraded clip.
fn rendered_gray(rig: &Rig, clip: sq_core_time::Id) -> f32 {
    use sq_core_color::ClipGradeExt;
    use sq_core_time::Time;
    use sq_render::color::{Vec3, pipeline_from_clip_color};
    let t = rig.session.active_timeline().expect("timeline");
    let c = t.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == clip).expect("clip");
    pipeline_from_clip_color(&c.color_at_local(Time::ZERO), c.media, None, None).process(Vec3::new(0.5, 0.5, 0.5)).x
}

/// Double-clicks the Exposure field of the Simple page, types `text`, ends it, and returns the clip's stored Exposure
/// and how many undo steps the typing made. Everything goes through `ColorPageHost::handle`, like a user.
fn type_exposure(text: &str, end: Ending) -> (f32, usize) {
    type_exposure_on(Subject::Adjustment, text, end)
}

fn type_exposure_on(subject: Subject, text: &str, end: Ending) -> (f32, usize) {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, subject);
    let (x, y) = {
        let (x, y) = exposure_point(&host, 1.0);
        (x - 4.0, y)
    };
    let f = host.frames[&Part::Grade];
    let no = InputModifiers::default();
    let depth = rig.session.undo_depth();
    for _ in 0..2 {
        host.handle(&InputEvent::MouseDown { x, y, modifiers: no }, &mut rig.cx());
        host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    }
    let key = |host: &mut ColorPageHost, rig: &mut Rig, key: InputKey| {
        host.handle(&InputEvent::KeyDown { key, modifiers: no }, &mut rig.cx());
    };
    for ch in text.chars() {
        key(&mut host, &mut rig, InputKey::Character(ch));
    }
    match end {
        Ending::Enter => key(&mut host, &mut rig, InputKey::Enter),
        Ending::Tab => key(&mut host, &mut rig, InputKey::Character('\t')),
        Ending::Escape => key(&mut host, &mut rig, InputKey::Escape),
        Ending::ClickAway => {
            let (ax, ay) = (f.x as f32 + 2.0, f.y as f32 + 2.0);
            host.handle(&InputEvent::MouseDown { x: ax, y: ay, modifiers: no }, &mut rig.cx());
        }
    }
    host.pump(&mut rig.cx());
    (stored_exposure(&rig, clip).0, rig.session.undo_depth() - depth)
}

#[test]
fn a_typed_exposure_reaches_the_project_on_enter_tab_and_focus_loss_as_one_undo_step() {
    for (end, name) in [(Ending::Enter, "Enter"), (Ending::Tab, "Tab"), (Ending::ClickAway, "focus loss")] {
        let (exposure, steps) = type_exposure("1", end);
        assert_eq!(exposure, 1.0, "{name} commits the typed Exposure");
        assert_eq!(steps, 1, "{name} makes one undo step");
    }
}

#[test]
fn escape_while_typing_exposure_reverts() {
    let (exposure, steps) = type_exposure("1", Ending::Escape);
    assert_eq!((exposure, steps), (0.0, 0));
}

#[test]
fn a_typed_exposure_on_footage_without_a_color_effect_creates_the_effect_and_keeps_the_value() {
    let (exposure, steps) = type_exposure_on(Subject::Footage, "1.5", Ending::Enter);
    assert_eq!(exposure, 1.5, "typing 1.5 into Exposure of a plain clip");
    assert_eq!(steps, 1);
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    let plain = rendered_gray(&rig, clip);
    let (x, y) = exposure_point(&host, 1.0);
    let no = InputModifiers::default();
    for _ in 0..2 {
        host.handle(&InputEvent::MouseDown { x: x - 4.0, y, modifiers: no }, &mut rig.cx());
        host.handle(&InputEvent::MouseUp { x: x - 4.0, y }, &mut rig.cx());
    }
    for ch in "1.5".chars() {
        host.handle(&InputEvent::KeyDown { key: InputKey::Character(ch), modifiers: no }, &mut rig.cx());
    }
    host.handle(&InputEvent::KeyDown { key: InputKey::Enter, modifiers: no }, &mut rig.cx());
    host.pump(&mut rig.cx());
    assert!(rendered_gray(&rig, clip) > plain + 0.05, "the typed Exposure brightens the rendered gray");
}

#[test]
fn pressing_a_simple_slider_track_on_footage_sets_that_parameter() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    let before = stored_exposure(&rig, clip);
    let plain = rendered_gray(&rig, clip);
    assert_eq!(before.0, 0.0);
    let (x, y) = exposure_point(&host, 0.9);
    let no = InputModifiers::default();
    host.handle(&InputEvent::MouseDown { x, y, modifiers: no }, &mut rig.cx());
    host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    host.pump(&mut rig.cx());
    let after = stored_exposure(&rig, clip);
    assert!(rendered_gray(&rig, clip) > plain + 0.01, "the press brightens the rendered gray");
    assert!(after.0 > 0.5, "a press at 90 percent of the track moved Exposure: {before:?} -> {after:?}");
    assert_eq!(after.1, 1, "one Color effect, not one per click");
}

#[test]
fn dragging_a_simple_slider_on_footage_follows_the_pointer_and_is_one_undo_step() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    let depth = rig.session.undo_depth();
    let (x0, y) = exposure_point(&host, 0.5);
    let (x1, _) = exposure_point(&host, 0.8);
    let no = InputModifiers::default();
    host.handle(&InputEvent::MouseDown { x: x0, y, modifiers: no }, &mut rig.cx());
    host.handle(&InputEvent::MouseDragged { x: x1, y, modifiers: no }, &mut rig.cx());
    host.handle(&InputEvent::MouseUp { x: x1, y }, &mut rig.cx());
    host.pump(&mut rig.cx());
    let after = stored_exposure(&rig, clip);
    assert!(after.0 > 0.0, "the drag moved Exposure: {after:?}");
    assert_eq!(rig.session.undo_depth() - depth, 1, "one undo step for the drag");
}

// MARK: Undo, redo and selection changes keep the panel on the model (Windows acceptance: stale 66 / Exposure 3.32)

use sq_inspector_ui::color::color_inspector_model::ColorParam;

/// What the panel shows for `param` of the first Color effect (the controller's model, which the sliders draw).
fn shown(host: &ColorPageHost, param: ColorParam) -> f32 {
    let model = host.controller.as_ref().expect("controller").model().expect("model");
    model.value(model.effects()[0].id, param)
}

/// The stored value of `param` of `clip`'s first Color effect.
fn stored(rig: &Rig, clip: sq_core_time::Id, param: ColorParam) -> f32 {
    use sq_core_color::ClipGradeExt;
    let t = rig.session.active_timeline().expect("timeline");
    let c = t.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == clip).expect("clip");
    c.color_at_local(sq_core_time::Time::ZERO).effects().first().map_or(param.neutral(), |e| param.read(e))
}

/// The session's changes reach the host, as the app's frame loop does after each input.
fn deliver(host: &mut ColorPageHost, rig: &mut Rig) {
    let changes = rig.session.take_changes();
    host.on_change(changes, &mut rig.cx());
    host.pump(&mut rig.cx());
}

/// A press-drag-release on `param`'s slider from `from` to `to` (fractions of the track), changes delivered.
fn drag(host: &mut ColorPageHost, rig: &mut Rig, param: ColorParam, from: f64, to: f64) {
    let (x0, y) = slider_point(host, param, from);
    let (x1, _) = slider_point(host, param, to);
    let no = InputModifiers::default();
    host.handle(&InputEvent::MouseDown { x: x0, y, modifiers: no }, &mut rig.cx());
    host.handle(&InputEvent::MouseDragged { x: x1, y, modifiers: no }, &mut rig.cx());
    deliver(host, rig);
    host.handle(&InputEvent::MouseUp { x: x1, y }, &mut rig.cx());
    deliver(host, rig);
}

fn undo(host: &mut ColorPageHost, rig: &mut Rig) {
    assert!(rig.session.undo());
    deliver(host, rig);
}

/// Every Simple slider the panel shows equals the stored grade.
fn assert_panel_is_model(host: &ColorPageHost, rig: &Rig, clip: sq_core_time::Id, why: &str) {
    for p in [ColorParam::Exposure, ColorParam::Contrast, ColorParam::Temperature, ColorParam::Saturation] {
        assert_eq!(shown(host, p), stored(rig, clip, p), "{why}: {p:?}");
    }
}

#[test]
fn after_a_slider_drag_and_undo_the_panel_shows_the_model_and_the_next_drag_starts_from_it() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    drag(&mut host, &mut rig, ColorParam::Exposure, 0.5, 0.9);
    assert!(stored(&rig, clip, ColorParam::Exposure) > 0.5);
    undo(&mut host, &mut rig);
    assert_panel_is_model(&host, &rig, clip, "after undo");
    drag(&mut host, &mut rig, ColorParam::Contrast, 0.5, 0.9);
    assert_eq!(
        stored(&rig, clip, ColorParam::Exposure),
        0.0,
        "the second drag does not bring the undone Exposure back"
    );
    assert!(stored(&rig, clip, ColorParam::Contrast) > 10.0);
    assert_panel_is_model(&host, &rig, clip, "after the second drag");
    undo(&mut host, &mut rig);
    assert_panel_is_model(&host, &rig, clip, "after the second undo");
    assert_eq!(stored(&rig, clip, ColorParam::Contrast), 0.0);
}

#[test]
fn a_run_of_drags_each_followed_by_undo_never_collects_values() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    let plain = rendered_gray(&rig, clip);
    for p in [ColorParam::Temperature, ColorParam::Exposure, ColorParam::Contrast, ColorParam::Saturation] {
        drag(&mut host, &mut rig, p, 0.5, 0.9);
        undo(&mut host, &mut rig);
        assert_panel_is_model(&host, &rig, clip, &format!("after {p:?}"));
        assert_eq!(rendered_gray(&rig, clip), plain, "the picture is ungraded after {p:?}");
    }
}

#[test]
fn redo_and_a_changed_selection_refresh_the_panel() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    drag(&mut host, &mut rig, ColorParam::Exposure, 0.5, 0.9);
    let graded = stored(&rig, clip, ColorParam::Exposure);
    undo(&mut host, &mut rig);
    assert!(rig.session.redo());
    deliver(&mut host, &mut rig);
    assert_eq!(shown(&host, ColorParam::Exposure), graded, "redo");
    undo(&mut host, &mut rig);
    let other = rig.session.add_adjustment_layer(None, None, sq_core_time::Time::seconds(2)).expect("layer");
    rig.session.set_selection([other].into(), Default::default());
    deliver(&mut host, &mut rig);
    rig.session.set_selection([clip].into(), Default::default());
    deliver(&mut host, &mut rig);
    assert_panel_is_model(&host, &rig, clip, "after reselecting");
}

#[test]
fn a_typed_value_then_undo_then_a_drag_keeps_the_panel_on_the_model() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    let (x, y) = exposure_point(&host, 1.0);
    let no = InputModifiers::default();
    for _ in 0..2 {
        host.handle(&InputEvent::MouseDown { x: x - 4.0, y, modifiers: no }, &mut rig.cx());
        host.handle(&InputEvent::MouseUp { x: x - 4.0, y }, &mut rig.cx());
    }
    for ch in "1.5".chars() {
        host.handle(&InputEvent::KeyDown { key: InputKey::Character(ch), modifiers: no }, &mut rig.cx());
    }
    host.handle(&InputEvent::KeyDown { key: InputKey::Enter, modifiers: no }, &mut rig.cx());
    deliver(&mut host, &mut rig);
    assert_eq!(stored(&rig, clip, ColorParam::Exposure), 1.5);
    undo(&mut host, &mut rig);
    assert_panel_is_model(&host, &rig, clip, "after undoing the typed value");
    drag(&mut host, &mut rig, ColorParam::Contrast, 0.5, 0.9);
    assert_eq!(stored(&rig, clip, ColorParam::Exposure), 0.0);
    assert_panel_is_model(&host, &rig, clip, "after the drag");
}

#[test]
fn an_undo_that_arrives_while_a_drag_is_in_progress_leaves_the_panel_on_the_model() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    drag(&mut host, &mut rig, ColorParam::Exposure, 0.5, 0.8);
    let no = InputModifiers::default();
    let (x0, y) = slider_point(&host, ColorParam::Contrast, 0.5);
    let (x1, _) = slider_point(&host, ColorParam::Contrast, 0.9);
    host.handle(&InputEvent::MouseDown { x: x0, y, modifiers: no }, &mut rig.cx());
    host.handle(&InputEvent::MouseDragged { x: x1, y, modifiers: no }, &mut rig.cx());
    deliver(&mut host, &mut rig);
    undo(&mut host, &mut rig); // the Contrast drag's step goes
    assert_panel_is_model(&host, &rig, clip, "undo during the drag");
    host.handle(&InputEvent::MouseUp { x: x1, y }, &mut rig.cx());
    deliver(&mut host, &mut rig);
    assert_panel_is_model(&host, &rig, clip, "after the release");
    // The next drag of another slider must not carry the undone Contrast.
    drag(&mut host, &mut rig, ColorParam::Saturation, 0.5, 0.9);
    assert_eq!(stored(&rig, clip, ColorParam::Contrast), 0.0);
    assert_panel_is_model(&host, &rig, clip, "after the next drag");
}

#[test]
fn a_press_that_never_saw_its_release_does_not_leave_a_gesture_open() {
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    let no = InputModifiers::default();
    let (x0, y) = slider_point(&host, ColorParam::Exposure, 0.5);
    // Two presses, one release: the second press must close the drag the first one left open.
    host.handle(&InputEvent::MouseDown { x: x0, y, modifiers: no }, &mut rig.cx());
    host.handle(&InputEvent::MouseDown { x: x0 + 20.0, y, modifiers: no }, &mut rig.cx());
    host.handle(&InputEvent::MouseUp { x: x0 + 20.0, y }, &mut rig.cx());
    deliver(&mut host, &mut rig);
    drag(&mut host, &mut rig, ColorParam::Contrast, 0.5, 0.9);
    undo(&mut host, &mut rig);
    assert_panel_is_model(&host, &rig, clip, "after undo");
    drag(&mut host, &mut rig, ColorParam::Saturation, 0.5, 0.9);
    assert_eq!(stored(&rig, clip, ColorParam::Contrast), 0.0);
}

#[test]
fn a_clip_with_a_known_file_length_keeps_its_selection_and_stays_editable_after_a_drag_and_undo() {
    use sq_core_time::Time;
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let clip = select_subject(&mut host, &mut rig, Subject::Footage);
    // A real file has a length: the Color page then shows the whole file (`color_source_view`).
    rig.session.perform("Probe", None, |p| {
        for t in &mut p.timelines[0].tracks {
            t.map_clips_keeping_timing(|c| {
                let mut c = c.clone();
                c.media_duration = Some(Time::seconds(10));
                c
            });
        }
    });
    // The lower panel on Clips (the Color page's default) is what turns the file view on.
    if let Some(c) = host.controller.as_mut() {
        c.set_sources_shown(&mut rig.session, true);
    }
    deliver(&mut host, &mut rig);
    assert!(rig.session.color_source_view().is_some(), "the Color page shows the file view");
    drag(&mut host, &mut rig, ColorParam::Exposure, 0.5, 0.9);
    assert!(stored(&rig, clip, ColorParam::Exposure) > 0.5);
    undo(&mut host, &mut rig);
    assert_eq!(rig.session.selection(), &[clip].into(), "undo keeps the clip selected");
    assert_panel_is_model(&host, &rig, clip, "after undo");
    drag(&mut host, &mut rig, ColorParam::Contrast, 0.5, 0.9);
    assert!(stored(&rig, clip, ColorParam::Contrast) > 10.0, "the next drag edits the clip");
}

/// Three clips on V1 with real file lengths, the playhead inside the second, the first one selected.
#[test]
fn a_clip_sharing_its_grade_with_other_uses_keeps_its_selection_and_stays_editable_after_a_drag_and_undo() {
    use sq_core_time::{Id, Time, TimeRange};
    let mut host = ColorPageHost::new();
    let mut rig = rig();
    let first = Id::from_u128(0xF101);
    rig.session.perform("Setup", None, |p| {
        let mut ids = SequentialIds::default();
        for (n, at) in [(0u128, 0), (1, 5), (2, 10)] {
            let mut c = sq_core_model::Clip::new(
                Id::from_u128(0xF101 + n),
                "wide.mp4",
                Id::from_u128(0xF008),
                sq_core_model::TrackKind::Video,
                TimeRange::new(Time::ZERO, Time::seconds(5)),
                Time::seconds(at),
            );
            c.media_duration = Some(Time::seconds(10));
            assert!(p.timelines[0].tracks[0].insert(c, &mut ids).is_ok());
        }
    });
    rig.session.seek(Time::seconds(7));
    rig.session.set_selection([first].into(), Default::default());
    laid_out(&mut host, &mut rig);
    if let Some(c) = host.controller.as_mut() {
        c.set_sources_shown(&mut rig.session, true);
    }
    deliver(&mut host, &mut rig);
    assert_eq!(rig.session.selection(), &[first].into(), "selected before the drag");
    drag(&mut host, &mut rig, ColorParam::Exposure, 0.5, 0.9);
    assert!(stored(&rig, first, ColorParam::Exposure) > 0.5);
    assert_eq!(rig.session.selection(), &[first].into(), "selected after the drag");
    undo(&mut host, &mut rig);
    assert_eq!(rig.session.selection(), &[first].into(), "undo keeps the clip selected");
    assert_panel_is_model(&host, &rig, first, "after undo");
    drag(&mut host, &mut rig, ColorParam::Contrast, 0.5, 0.9);
    assert!(stored(&rig, first, ColorParam::Contrast) > 10.0, "the next drag edits the clip");
}
