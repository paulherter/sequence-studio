//! Tests of the monitor host: session-only events run, the rest is queued; then the card through the headless App.

use super::*;
use sq_app_shell::{AppDeps, Headless};
use sq_core_masks::masks::{ClipMasksExt, MaskPathExt};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use sq_draw::InputModifiers;
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_draw_monitor::monitor_panel_model::MonitorPanelModel;
use sq_editor_session::SessionDeps;
use sq_runtime::FakeClock;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::sync::Arc;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

fn card() -> MonitorPanel {
    MonitorPanel::new(MonitorPanelModel::new(Time::new(1001, 30000), MonitorMode::Program), None)
}

#[test]
fn seek_moves_the_playhead() {
    let mut s = session();
    let t = Time::new(3003, 30000);
    let rest = route_monitor(
        &mut s,
        Vec::new(),
        vec![MonitorEvent::ScrubBegan, MonitorEvent::Scrub(t), MonitorEvent::ScrubEnded],
    );
    assert!(rest.is_empty());
    assert_eq!(s.playhead(), t);
    let t2 = Time::new(6006, 30000);
    route_monitor(&mut s, Vec::new(), vec![MonitorEvent::Seek(t2)]);
    assert_eq!(s.playhead(), t2);
}

#[test]
fn a_pick_on_an_empty_sequence_selects_nothing() {
    let mut s = session();
    let at = sq_core_time::Vec2::new(0.0, 0.0);
    // The pick needs the Graphics editor, so the root runs it.
    let rest = route_monitor(&mut s, vec![PanelEvent::PickClip(at)], Vec::new());
    assert!(matches!(rest.as_slice(), [MonitorDeferred::Panel(PanelEvent::PickClip(_))]));
    pick_clip(&mut s, None, at);
    assert!(s.selection().is_empty());
}

#[test]
fn a_pick_on_a_graphics_text_layer_selects_the_graphic_and_the_layer() {
    // Layout needs the bundled fonts (the Swift package folder, as sq-text's own tests use).
    sq_text::portable_font_match::set_fonts_root(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts"),
    );
    let mut s = session();
    let mut editor = GraphicsEditor::new(Box::new(SequentialIds::default()));
    editor.new_graphics_clip(&mut s).expect("graphic");
    editor.add_text(&mut s, "Hello");
    let clip = editor.clip(&s).map(|c| c.id).expect("clip");
    s.select(BTreeSet::new(), BTreeSet::new());
    editor.sync(&mut s);
    assert!(editor.selected_layers(&s).is_empty());
    // The text sits in the middle of the picture; without the editor the Graphic is no picture clip to pick.
    let middle = sq_core_time::Vec2::new(0.0, 0.0);
    pick_clip(&mut s, None, middle);
    assert!(s.selection().is_empty());
    pick_clip(&mut s, Some(&mut editor), middle);
    assert_eq!(s.selection().iter().copied().collect::<Vec<_>>(), vec![clip]);
    assert_eq!(editor.selected_layers(&s).len(), 1);
    // Far from any text nothing is picked.
    s.select(BTreeSet::new(), BTreeSet::new());
    pick_clip(&mut s, Some(&mut editor), sq_core_time::Vec2::new(900.0, 500.0));
    assert!(s.selection().is_empty());
}

#[test]
fn menus_and_format_choices_are_deferred_in_order() {
    let mut s = session();
    let panel = vec![
        PanelEvent::SelectTab(1),
        PanelEvent::Menu { items: Vec::<SQMenuItem>::new(), anchor: CGRect::default(), pointer: None },
    ];
    let model = vec![MonitorEvent::PickSource(Id::from_u128(7)), MonitorEvent::FullScreen];
    let rest = route_monitor(&mut s, panel, model);
    assert!(matches!(
        rest.as_slice(),
        [
            MonitorDeferred::Panel(PanelEvent::SelectTab(1)),
            MonitorDeferred::Panel(PanelEvent::Menu { .. }),
            MonitorDeferred::Model(MonitorEvent::PickSource(_)),
            MonitorDeferred::Model(MonitorEvent::FullScreen),
        ]
    ));
}

#[test]
fn the_card_draws_through_the_app_and_takes_clicks_inside_its_frame() {
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 800, 600);
    h.with(|a| {
        let id = a.add_host(Box::new(MonitorHost::new(card())));
        a.set_host_frame(id, Some(CGRect::new(0.0, 0.0, 400.0, 300.0)));
    });
    let (_, list) = h.turn();
    assert!(list.is_some_and(|l| !l.quads().is_empty()), "the card draws");
    let outside = InputEvent::MouseDown { x: 700.0, y: 500.0, modifiers: InputModifiers::NONE };
    assert!(!h.input(&outside), "outside the frame");
}

#[test]
fn enter_confirms_the_magic_prompt_and_escape_forgets_it() {
    use crate::analysis_links::magic_flow::{FlowRequest, MagicFlow};
    use crate::test_rig::Rig;
    let flow = MagicFlow::default();
    let mut host = MonitorHost::new(card()).with_magic_flow(flow.clone());
    host.panel.overlay.mask_tool = Some(MaskToolMode::Magic);
    let mut rig = Rig::new(session());
    let key = |key| InputEvent::KeyDown { key, modifiers: InputModifiers::NONE };
    flow.arm(true);
    flow.click(sq_core_time::Vec2::new(0.5, 0.5), false);
    assert!(host.handle(&key(InputKey::Escape), &mut rig.cx()));
    assert!(flow.points().is_empty());
    flow.click(sq_core_time::Vec2::new(0.2, 0.3), true);
    assert!(host.handle(&key(InputKey::Enter), &mut rig.cx()));
    assert_eq!(flow.take_requests(), [FlowRequest::Confirm(vec![(sq_core_time::Vec2::new(0.2, 0.3), true)])]);
    // Without a prompt the keys belong to the card again.
    host.handle(&key(InputKey::Enter), &mut rig.cx());
    assert!(flow.take_requests().is_empty());
}

#[test]
fn a_magic_click_on_the_picture_becomes_a_prompt_point() {
    use crate::analysis_links::magic_flow::MagicFlow;
    use crate::test_rig::Rig;
    let flow = MagicFlow::default();
    let mut host = MonitorHost::new(card()).with_magic_flow(flow.clone());
    let mut rig = Rig::new(session());
    host.panel.overlay.mask_tool = Some(MaskToolMode::Magic);
    host.panel.overlay.is_shown = true;
    let frame = CGRect::new(0.0, 0.0, 800.0, 600.0);
    host.layout(frame, &mut rig.cx());
    let c = host.panel.canvas_rect();
    let (x, y) = ((c.x + c.width * 0.5) as f32, (c.y + c.height * 0.5) as f32);
    host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
    host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    assert_eq!(flow.points().len(), 1, "{:?}", c);
    assert!((flow.points()[0].0.x - 0.5).abs() < 0.05);
}

#[test]
fn a_magic_drag_on_the_picture_counts_as_a_box_prompt() {
    use crate::analysis_links::magic_flow::MagicFlow;
    use crate::test_rig::Rig;
    let flow = MagicFlow::default();
    let mut host = MonitorHost::new(card()).with_magic_flow(flow.clone());
    let mut rig = Rig::new(session());
    host.panel.overlay.mask_tool = Some(MaskToolMode::Magic);
    host.panel.overlay.is_shown = true;
    host.layout(CGRect::new(0.0, 0.0, 800.0, 600.0), &mut rig.cx());
    let c = host.panel.canvas_rect();
    let at = |fx: f64, fy: f64| ((c.x + c.width * fx) as f32, (c.y + c.height * fy) as f32);
    let ((x0, y0), (x1, y1)) = (at(0.2, 0.2), at(0.6, 0.6));
    host.handle(&InputEvent::MouseDown { x: x0, y: y0, modifiers: InputModifiers::NONE }, &mut rig.cx());
    host.handle(&InputEvent::dragged(x1, y1), &mut rig.cx());
    host.handle(&InputEvent::MouseUp { x: x1, y: y1 }, &mut rig.cx());
    let points = flow.points();
    assert_eq!(points.len(), 1);
    assert!((points[0].0.x - 0.4).abs() < 0.05 && !points[0].1, "{points:?}");
}

#[test]
fn header_popups_and_footer_buttons_are_nodes_and_a_click_runs_them() {
    use crate::test_rig::Rig;
    use accesskit::Role;
    let mut host = MonitorHost::new(card());
    let mut rig = Rig::new(session());
    host.layout(CGRect::new(0.0, 0.0, 800.0, 600.0), &mut rig.cx());
    host.draw(&mut Canvas::with_size(800.0, 600.0, None, 1.0), &DrawTheme::default(), &mut rig.cx());
    let mut a = A11y::new(true);
    host.a11y(&mut a);
    let named = |a: &A11y, label: &str| a.nodes().iter().find(|(_, n)| n.label() == Some(label)).map(|(id, _)| *id);
    let zoom = named(&a, "Zoom: Fit, or 10 to 800 %").expect("zoom popup");
    assert!(named(&a, "Mark In").is_some() && named(&a, "Step Forward").is_some());
    assert!(a.nodes().iter().any(|(_, n)| n.role() == Role::Button));
    assert!(host.a11y_action(zoom, sq_app_shell::A11yAction::Click, &mut rig.cx()));
    assert!(
        host.take_deferred().iter().any(|d| matches!(d, MonitorDeferred::Panel(PanelEvent::Menu { .. }))),
        "the zoom popup opens its menu"
    );
    let mark_in = named(&a, "Mark In").expect("mark in");
    assert!(host.a11y_action(mark_in, sq_app_shell::A11yAction::Click, &mut rig.cx()));
}

#[test]
fn the_stored_subject_edges_reach_the_tracking_runs() {
    use sq_analysis::subject_mask_quality::{SubjectEdgesChoice, SubjectMaskQuality};
    let choice = SubjectEdgesChoice::default();
    let mut host = MonitorHost::new(card()).with_subject_edges(choice.clone());
    for q in SubjectMaskQuality::ALL {
        host.set_subject_edges(q);
        assert_eq!(choice.get(), q);
    }
}

/// A selected rectangle shape with one rectangle mask, shown in Effect Controls, with the overlay on it.
fn masked_shape() -> (crate::test_rig::Rig, crate::InspectorHost, MonitorHost, Id, Id) {
    let mut rig = crate::test_rig::Rig::new(session());
    let clip =
        rig.session.add_shape_clip(sq_core_model::ShapeKind::Rectangle, None, None, Time::seconds(5)).expect("shape");
    rig.session.set_selection([clip].into(), Default::default());
    let mut inspector = crate::InspectorHost::new(Box::new(|_, _| panic!("no audio clip is shown")));
    inspector.sync(&rig.session);
    let mask = inspector.controls().model.add_mask(sq_core_model::MaskShapeKind::Rectangle).expect("mask");
    inspector.route_model(&mut rig.cx());
    inspector.sync(&rig.session);
    let mut host = MonitorHost::new(card());
    host.sync_with(&rig.session, &inspector.controls().model);
    assert!(host.overlay_target.is_some(), "the overlay is on the selected clip");
    (rig, inspector, host, clip, mask)
}

fn the_mask(rig: &crate::test_rig::Rig, clip: Id, mask: Id) -> sq_core_model::MaskPath {
    let tl = rig.session.active_timeline().expect("timeline");
    let c = tl.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == clip).expect("clip");
    c.mask(mask).expect("mask").path.value_at_local(Time::ZERO)
}

#[test]
fn a_mask_vertex_drag_from_the_picture_moves_the_vertex_in_one_undo_step() {
    use sq_draw_monitor::transform_overlay::Phase;
    let (mut rig, mut inspector, mut host, clip, mask) = masked_shape();
    let before = the_mask(&rig, clip, mask);
    let to = sq_core_time::Vec2::new(0.9, 0.1);
    host.overlay_rest = vec![
        OverlayEvent::MaskVertex(Phase::Began, mask, 0, before.vertices[0].point),
        OverlayEvent::MaskVertex(Phase::Changed, mask, 0, to),
        OverlayEvent::MaskVertex(Phase::Ended, mask, 0, to),
    ];
    let status = host.apply_overlay_events(&mut rig.session, &mut inspector.controls().model);
    inspector.route_model(&mut rig.cx());
    assert!(status.is_empty(), "{status:?}");
    let after = the_mask(&rig, clip, mask);
    assert_eq!(after.vertices[0].point, to);
    assert_eq!(after.vertices[1], before.vertices[1], "only the dragged vertex moved");
    rig.session.undo();
    assert_eq!(the_mask(&rig, clip, mask), before, "one undo step puts the vertex back");
}

#[test]
fn a_whole_mask_move_and_a_canceled_drag_reach_the_model() {
    use sq_draw_monitor::mask_handle_edit::MaskHandleEdit;
    use sq_draw_monitor::transform_overlay::Phase;
    let (mut rig, mut inspector, mut host, clip, mask) = masked_shape();
    let before = the_mask(&rig, clip, mask);
    let delta = sq_core_time::Vec2::new(0.1, 0.0);
    let edit = MaskHandleEdit::Move { mask, delta };
    host.overlay_rest = vec![OverlayEvent::MaskEdit(Phase::Began, edit), OverlayEvent::MaskEdit(Phase::Changed, edit)];
    host.apply_overlay_events(&mut rig.session, &mut inspector.controls().model);
    inspector.route_model(&mut rig.cx());
    assert_eq!(the_mask(&rig, clip, mask), before.translated(delta));
    host.overlay_rest = vec![OverlayEvent::DragCanceled];
    host.apply_overlay_events(&mut rig.session, &mut inspector.controls().model);
    inspector.route_model(&mut rig.cx());
    assert_eq!(the_mask(&rig, clip, mask), before, "Esc puts the mask back");
}

#[test]
fn a_press_on_a_mask_selects_it_and_a_drawn_shape_adds_one() {
    use sq_draw_monitor::transform_overlay::Phase;
    let (mut rig, mut inspector, mut host, clip, mask) = masked_shape();
    host.overlay_rest = vec![OverlayEvent::MaskSelect(mask)];
    host.apply_overlay_events(&mut rig.session, &mut inspector.controls().model);
    assert_eq!(inspector.controls().model.selected_section, Some(sq_editor_session::EffectSection::Mask(mask)));
    let drawn = sq_core_model::MaskPath::ellipse(sq_core_time::Vec2::new(0.5, 0.5), sq_core_time::Vec2::new(0.2, 0.2));
    host.overlay_rest = vec![OverlayEvent::MaskShapeDrawn(sq_core_model::MaskShapeKind::Ellipse, drawn)];
    host.apply_overlay_events(&mut rig.session, &mut inspector.controls().model);
    inspector.route_model(&mut rig.cx());
    let tl = rig.session.active_timeline().expect("timeline");
    let c = tl.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == clip).expect("clip");
    assert_eq!(c.masks().len(), 2, "the drawn mask joined the clip");
    let _ = Phase::Began;
}

#[test]
fn a_timeline_mask_tool_reaches_the_overlay_on_the_next_sync() {
    let (rig, mut inspector, mut host, _, _) = masked_shape();
    host.set_mask_tool(Some(MaskToolMode::Pen));
    host.sync_with(&rig.session, &inspector.controls().model);
    assert_eq!(host.panel.overlay.mask_tool, Some(MaskToolMode::Pen));
}

#[test]
fn the_color_page_monitor_shows_no_transform_handles() {
    let (rig, mut inspector, mut host, _, _) = masked_shape();
    host.sync_with(&rig.session, &inspector.controls().model);
    assert!(host.panel.overlay.is_shown, "the edit page shows the box");
    host.hides_transform_handles = true;
    host.sync_with(&rig.session, &inspector.controls().model);
    assert!(!host.panel.overlay.is_shown, "the Color page does not");
}

#[test]
fn a_transform_box_drag_writes_the_position_in_one_undo_step() {
    use sq_draw_monitor::transform_overlay::Phase;
    let (mut rig, mut inspector, mut host, clip, _) = masked_shape();
    let start = host.overlay_target.as_ref().expect("target").display_transform();
    let mut moved = start;
    moved.position = moved.position + sq_core_time::Vec2::new(40.0, -20.0);
    let position = |rig: &crate::test_rig::Rig| {
        let tl = rig.session.active_timeline().expect("timeline");
        tl.tracks
            .iter()
            .flat_map(|t| t.clips().iter())
            .find(|c| c.id == clip)
            .expect("clip")
            .transform(Time::ZERO)
            .position
    };
    let before = position(&rig);
    host.overlay_rest = vec![
        OverlayEvent::Transform(Phase::Began, start),
        OverlayEvent::Transform(Phase::Changed, moved),
        OverlayEvent::Transform(Phase::Ended, moved),
    ];
    host.apply_overlay_events(&mut rig.session, &mut inspector.controls().model);
    inspector.route_model(&mut rig.cx());
    assert_ne!(position(&rig), before, "the drag reached the clip");
    rig.session.undo();
    assert_eq!(position(&rig), before, "one undo step");
}

#[test]
fn a_text_clip_scale_handle_drag_resizes_the_font_keeps_scale_and_is_one_undo_step() {
    use sq_draw_monitor::transform_overlay::Phase;
    use sq_text::text_generator::TextGenerator;
    // Layout needs the bundled fonts (the Swift package folder, as sq-text's own tests use).
    sq_text::portable_font_match::set_fonts_root(
        &std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts"),
    );
    let mut rig = crate::test_rig::Rig::new(session());
    let template = sq_text::text_template::TextTemplate::new("Title", "Hello", Default::default());
    let size0 = template.style.size;
    let clip = rig.session.add_text_clip(&template, None, None, Time::seconds(5), None, false).expect("text clip");
    rig.session.set_selection([clip].into(), Default::default());
    let mut inspector = crate::InspectorHost::new(Box::new(|_, _| panic!("no audio clip is shown")));
    inspector.sync(&rig.session);
    let mut host = MonitorHost::new(card());
    host.sync_with(&rig.session, &inspector.controls().model);
    let target = host.overlay_target.clone().expect("target");
    assert!(target.is_text);
    let start = target.display_transform();
    let mut bigger = start;
    bigger.scale = sq_core_time::Vec2::new(start.scale.x * 2.0, start.scale.y * 2.0);
    let depth = rig.session.undo_depth();
    host.overlay_rest = vec![
        OverlayEvent::Transform(Phase::Began, start),
        OverlayEvent::Transform(Phase::Changed, bigger),
        OverlayEvent::Transform(Phase::Ended, bigger),
    ];
    host.apply_overlay_events(&mut rig.session, &mut inspector.controls().model);
    inspector.route_model(&mut rig.cx());
    let read = |rig: &crate::test_rig::Rig| {
        let tl = rig.session.active_timeline().expect("timeline");
        let c = tl.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == clip).expect("clip");
        let (t, _) = TextGenerator::decode(c.generator.as_ref().expect("generator")).expect("text");
        (t.style.size, c.transform(Time::ZERO).scale)
    };
    let (size, scale) = read(&rig);
    assert!((size - size0 * 2.0).abs() < 1e-6, "font {size0} -> {size}");
    assert_eq!(scale, start.scale, "Scale stays");
    assert_eq!(rig.session.undo_depth(), depth + 1, "one undo step");
    rig.session.undo();
    assert_eq!(read(&rig).0, size0);
}

#[test]
fn the_eyedropper_loupe_follows_the_pointer_over_the_picture_and_hides_on_a_press() {
    let mut rig = crate::test_rig::Rig::new(session());
    let picture = crate::MonitorPicture::default();
    let dropper = crate::Eyedropper::default();
    let mut host = MonitorHost::new(card()).with_picture(picture.clone()).with_eyedropper(dropper.clone());
    host.layout(CGRect::new(0.0, 0.0, 800.0, 500.0), &mut rig.cx());
    let c = host.panel.canvas_rect();
    let at = |u: f64, v: f64| InputEvent::MouseMoved { x: (c.x + c.width * u) as f32, y: (c.y + c.height * v) as f32 };
    host.handle(&at(0.5, 0.5), &mut rig.cx());
    assert!(host.loupe.is_none(), "not armed: no loupe");
    dropper.arm();
    host.handle(&at(0.5, 0.5), &mut rig.cx());
    assert!(host.loupe.is_none(), "no picture to magnify yet");
    picture.set(Some(sq_draw::RgbaImage { width: 20, height: 20, pixels: vec![9; 20 * 20 * 4] }));
    host.handle(&at(0.5, 0.5), &mut rig.cx());
    assert_eq!(host.loupe.as_ref().map(|l| l.0.center()), Some([9, 9, 9]));
    host.handle(&InputEvent::MouseMoved { x: 1.0, y: 1.0 }, &mut rig.cx());
    assert!(host.loupe.is_none(), "outside the picture");
}

#[test]
fn the_step_window_handles_show_for_the_monitors_clip_and_hand_each_drag_to_the_grade() {
    use sq_draw_monitor::transform_overlay::Phase;
    use sq_inspector_ui::color::color_grade_controller::WindowEditTarget;
    let (mut rig, _inspector, mut host, clip, _) = masked_shape();
    host.layout(CGRect::new(0.0, 0.0, 800.0, 500.0), &mut rig.cx());
    let window = sq_core_model::StepWindow { center_x: 0.3, ..Default::default() };
    let target = WindowEditTarget { clip, window: window.clone() };
    host.refresh_step_window(&rig.session, Some(&target));
    let overlay = host.panel.step_window_edit.as_ref().expect("handles over the clip");
    assert_eq!(overlay.step_window, window);
    // The center handle of the window drags it: the events carry begin, change and end.
    let c = host.panel.canvas_rect();
    let at = |x: f32, y: f32| (c.x as f32 + c.width as f32 * x, c.y as f32 + c.height as f32 * y);
    let (x, y) = at(0.3, 0.5);
    host.panel
        .step_window_edit
        .as_mut()
        .expect("overlay")
        .mouse_down(sq_uikit::controls_grid::CGPoint::new(x.into(), y.into()));
    host.panel
        .step_window_edit
        .as_mut()
        .expect("overlay")
        .mouse_up(sq_uikit::controls_grid::CGPoint::new(x.into(), y.into()));
    let phases: Vec<Phase> = host.take_step_window_events().into_iter().map(|e| e.0).collect();
    assert_eq!(phases, vec![Phase::Began, Phase::Ended]);
    assert!(host.take_step_window_events().is_empty(), "taken once");
    // Another clip than the monitor's, or no target: the handles go.
    host.refresh_step_window(&rig.session, Some(&WindowEditTarget { clip: Id::from_u128(999), window }));
    assert!(host.panel.step_window_edit.is_none());
}

#[test]
fn the_strip_grips_and_the_range_drag_set_the_marks() {
    use sq_draw::monitor::monitor_footer::ScrubHit;
    let mut s = session();
    s.add_sequence(None, None, None);
    let fd = s.active_timeline().expect("sequence").frame_duration();
    let t = Time::new(2, 1);
    let rest = route_monitor(&mut s, Vec::new(), vec![MonitorEvent::MarkEdit(ScrubHit::MarkIn, t)]);
    assert!(rest.is_empty());
    // The strip reports the stored Out, one frame past the last frame inside.
    let out = Time::new(4, 1) + fd;
    route_monitor(&mut s, Vec::new(), vec![MonitorEvent::MarkEdit(ScrubHit::MarkOut, out)]);
    assert_eq!(s.active_timeline().and_then(|t| t.in_out), Some(TimeRange::from_end(t, out)));
}

#[test]
fn quality_and_playback_speed_reach_the_session_and_display_only_events_are_consumed() {
    use sq_editor_session::MonitorQuality;
    let mut s = session();
    let rest = route_monitor(
        &mut s,
        Vec::new(),
        vec![
            MonitorEvent::QualityChange(MonitorQuality::Half),
            MonitorEvent::SafeZoneChange(sq_draw_monitor::safe_zone_choice::SafeZoneChoice::Off),
            MonitorEvent::DragEnded,
            MonitorEvent::ShowScopes,
        ],
    );
    assert_eq!(s.engine().quality(), MonitorQuality::Half.decode_scale());
    // The root saves a hand pick as the Default Quality, so the quality change comes back too.
    assert!(
        matches!(
            rest.as_slice(),
            [MonitorDeferred::Model(MonitorEvent::QualityChange(_)), MonitorDeferred::Model(MonitorEvent::ShowScopes)]
        ),
        "{rest:?}"
    );
}
