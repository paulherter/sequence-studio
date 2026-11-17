//! Headless tests of the header host: layout split, tab and button clicks, the tool strip and the drawn header.

use super::*;
use crate::test_rig::Rig;
use sq_core_time::SequentialIds;
use sq_draw::InputModifiers;
use sq_editor_session::{EditorSession, SessionDeps};
use sq_library::library_folder_store::MemorySettings;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-header-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

const FRAME: CGRect = CGRect { x: 0.0, y: 0.0, width: 1000.0, height: 500.0 };

fn laid_out() -> (TimelineHeaderHost, TimelineAppHost, Rig, MemorySettings, CGRect) {
    let mut host = TimelineHeaderHost::new(DrawTheme::default());
    let timeline = TimelineAppHost::new(DrawTheme::default());
    let mut rig = Rig::new(session());
    let settings = MemorySettings::default();
    let lanes = host.layout(FRAME, &mut rig.cx(), &timeline);
    (host, timeline, rig, settings, lanes)
}

fn center(r: CGRect) -> (f32, f32) {
    ((r.x + r.width / 2.0) as f32, (r.y + r.height / 2.0) as f32)
}

fn click(
    host: &mut TimelineHeaderHost,
    timeline: &mut TimelineAppHost,
    rig: &mut Rig,
    settings: &mut MemorySettings,
    at: (f32, f32),
) -> bool {
    let (x, y) = at;
    let down = InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE };
    let taken = host.handle(&down, &mut rig.cx(), timeline, settings);
    host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx(), timeline, settings);
    host.pump(&mut rig.cx(), timeline, settings);
    taken
}

#[test]
fn the_header_takes_the_top_of_the_frame() {
    let (host, _, _, _, lanes) = laid_out();
    let bar = host.bar().bar();
    assert!(bar.height > 0.0 && (bar.width - FRAME.width).abs() < 0.5, "the header runs across the full width");
    assert!(lanes.y >= bar.max_y() - 0.5, "the lanes start below the header");
    assert!((lanes.width - FRAME.width).abs() < 0.5, "the tools are their own panel: the lanes keep the width");
    assert!(lanes.max_y() <= FRAME.max_y() + 0.5);
}

#[test]
fn the_open_sequence_is_a_tab_and_a_click_on_another_tab_switches_to_it() {
    let (mut host, mut timeline, mut rig, mut settings, _) = laid_out();
    let first = rig.session.active_timeline().map(|t| t.id).expect("a sequence");
    let second = rig.session.add_sequence(None, None, None);
    assert_ne!(first, second);
    host.layout(FRAME, &mut rig.cx(), &timeline);
    let tabs = host.bar().tab_rects().to_vec();
    assert_eq!(tabs.len(), 2, "one tab per open sequence");
    assert!(click(&mut host, &mut timeline, &mut rig, &mut settings, center(tabs[0].0)));
    assert_eq!(rig.session.active_timeline().map(|t| t.id), Some(first));
}

#[test]
fn the_close_button_of_a_tab_closes_it() {
    let (mut host, mut timeline, mut rig, mut settings, _) = laid_out();
    rig.session.add_sequence(None, None, None);
    host.layout(FRAME, &mut rig.cx(), &timeline);
    let close = center(host.bar().tab_rects()[1].1);
    // The close button only takes presses while its tab is hovered.
    host.handle(&InputEvent::MouseMoved { x: close.0, y: close.1 }, &mut rig.cx(), &mut timeline, &mut settings);
    click(&mut host, &mut timeline, &mut rig, &mut settings, close);
    assert_eq!(rig.session.sequence_tabs().tabs().len(), 1);
}

#[test]
fn the_snapping_button_runs_the_view_command_on_the_panel() {
    let (mut host, mut timeline, mut rig, mut settings, _) = laid_out();
    let on = timeline.panel.tool_state().snapping;
    let snap = host.bar().frames().snap;
    let bar = host.bar().bar();
    let at = center(CGRect::new(bar.x + snap.x, bar.y + snap.y, snap.width, snap.height));
    assert!(click(&mut host, &mut timeline, &mut rig, &mut settings, at));
    assert_eq!(timeline.panel.tool_state().snapping, !on);
}

#[test]
fn a_click_on_the_lanes_is_not_taken() {
    let (mut host, mut timeline, mut rig, mut settings, lanes) = laid_out();
    let at = ((lanes.x + lanes.width / 2.0) as f32, (lanes.y + lanes.height / 2.0) as f32);
    assert!(!click(&mut host, &mut timeline, &mut rig, &mut settings, at));
}

#[test]
fn the_edit_mode_capsule_opens_a_menu_and_its_pick_switches_to_fast_cut() {
    let (mut host, mut timeline, mut rig, mut settings, _) = laid_out();
    let bar = host.bar().bar();
    let f = host.bar().frames().edit_mode;
    click(
        &mut host,
        &mut timeline,
        &mut rig,
        &mut settings,
        center(CGRect::new(bar.x + f.x, bar.y + f.y, f.width, f.height)),
    );
    let menus = host.take_menus();
    assert_eq!(menus.len(), 1, "the capsule asks for its menu");
    let fast = menus[0].0.iter().find(|i| i.title.contains("Fast Cut")).expect("a Fast Cut row");
    (fast.action.as_ref().expect("a row action"))();
    host.pump(&mut rig.cx(), &mut timeline, &mut settings);
    assert_eq!(rig.session.active_timeline().map(|t| t.edit_mode()), Some(sq_core_model::TimelineEditMode::Magnetic));
}

#[test]
fn the_header_region_of_a_drawn_frame_is_not_empty() {
    use sq_draw::{Color, SoftwareRenderer, Sources};
    let (mut host, _timeline, _rig, _, _) = laid_out();
    let mut list = sq_draw::Canvas::with_size(1000.0, 500.0, None, 1.0);
    host.draw(&mut list, &DrawTheme::default());
    let image =
        SoftwareRenderer::render(&list.list, 1000, 500, Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 }, &Sources::default());
    let bar = host.bar().bar();
    let px = |x: usize, y: usize| image.pixels.get((y * 1000 + x) * 4..(y * 1000 + x) * 4 + 4).map(<[u8]>::to_vec);
    let first = px(0, 0);
    let mut colors = std::collections::HashSet::new();
    for y in 0..bar.max_y() as usize {
        for x in (0..1000).step_by(3) {
            colors.extend(px(x, y));
        }
    }
    assert!(first.is_some() && colors.len() > 1, "the header paints more than one color");
}
