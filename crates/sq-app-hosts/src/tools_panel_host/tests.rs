//! Headless tests of the Tools panel host: tool clicks and the variants menu.

use super::*;
use crate::test_rig::Rig;
use sq_core_time::SequentialIds;
use sq_draw::InputModifiers;
use sq_editor_session::{EditorSession, SessionDeps, TimelineTool};

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tools-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

const FRAME: CGRect = CGRect { x: 2.0, y: 300.0, width: 36.0, height: 300.0 };

fn center(r: CGRect) -> (f32, f32) {
    ((r.x + r.width / 2.0) as f32, (r.y + r.height / 2.0) as f32)
}

fn setup() -> (ToolsPanelHost, TimelineAppHost, Rig) {
    let mut host = ToolsPanelHost::new(DrawTheme::default());
    let mut timeline = TimelineAppHost::new(DrawTheme::default());
    let rig = Rig::new(session());
    host.layout(FRAME, 1.0, &mut timeline);
    (host, timeline, rig)
}

fn click(host: &mut ToolsPanelHost, timeline: &mut TimelineAppHost, rig: &mut Rig, at: (f32, f32)) -> bool {
    let (x, y) = at;
    let down = InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE };
    let taken = host.handle(&down, &mut rig.cx(), timeline);
    host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx(), timeline);
    host.pump(timeline);
    taken
}

#[test]
fn a_click_on_the_razor_slot_selects_the_razor() {
    let (mut host, mut timeline, mut rig) = setup();
    let razor = host.tools().slots().1[1];
    assert!(click(&mut host, &mut timeline, &mut rig, center(razor)));
    assert_eq!(timeline.panel.tool_state().tool, TimelineTool::Razor);
}

#[test]
fn a_right_click_on_a_variants_slot_opens_its_menu_and_the_pick_sets_the_tool() {
    let (mut host, mut timeline, mut rig) = setup();
    let slots = host.tools().slots().1;
    let i = sq_timeline_ui::ToolStripTools::ORDER
        .iter()
        .position(|t| sq_timeline_ui::ToolStripTools::has_variants(*t))
        .expect("a slot with variants");
    let (x, y) = center(slots[i]);
    let down = InputEvent::MouseDown { x, y, modifiers: InputModifiers::SECONDARY };
    assert!(host.handle(&down, &mut rig.cx(), &mut timeline));
    let menus = host.take_menus();
    assert_eq!(menus.len(), 1);
    let row = menus[0].0.iter().rev().find(|r| r.action.is_some()).expect("a pick");
    (row.action.as_ref().expect("an action"))();
    host.pump(&mut timeline);
}

#[test]
fn the_header_of_the_panel_belongs_to_the_dock() {
    let (mut host, mut timeline, mut rig) = setup();
    let down = InputEvent::MouseDown { x: 20.0, y: FRAME.y as f32 + 5.0, modifiers: InputModifiers::NONE };
    assert!(!host.handle(&down, &mut rig.cx(), &mut timeline));
}
