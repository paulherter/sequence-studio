//! Tests through the real app root (`standard_root_with_source`, as `sequence-studio` main.rs builds it), not a hand-built host.
//! The wiring a user hits: the Create tool on the Program monitor, the Source picture drag.

use super::dead_commands_tests::{Scenario, demo_session};
use super::*;
use sq_core_model::TrackKind;
use sq_draw::InputModifiers;
use sq_editor_session::{CreateToolMode, EffectSection, TimelineTool};
use sq_inspector_ui::audio_masks::track_audio_draw::Control;
use sq_inspector_ui::clip_sections::ClipSectionMode;
use sq_runtime::FakeClock;
use std::sync::Arc;

fn standard(session: EditorSession) -> (AppRoot, crate::test_rig::Rig) {
    let dir = crate::test_rig::test_dir("sq-real-path");
    std::fs::create_dir_all(&dir).expect("dir");
    let mut root = crate::standard_root_with_source(
        &dir,
        Arc::new(FakeClock::new()),
        DrawTheme::default(),
        crate::MonitorPicture::default(),
        Box::new(sq_editor_session::StubProgramEngine::new()),
        crate::MonitorPicture::default(),
    )
    .expect("root");
    let mut rig = crate::test_rig::Rig::new(session);
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    root.sync(&rig.session);
    (root, rig)
}

fn drag(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, from: (f32, f32), to: (f32, f32)) {
    let none = InputModifiers::NONE;
    r.handle(&InputEvent::MouseDown { x: from.0, y: from.1, modifiers: none }, &mut rig.cx());
    r.handle(&InputEvent::MouseDragged { x: to.0, y: to.1, modifiers: none }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x: to.0, y: to.1 }, &mut rig.cx());
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
}

fn graphic_clips(rig: &crate::test_rig::Rig) -> usize {
    rig.session
        .active_timeline()
        .map_or(0, |t| t.tracks.iter().flat_map(|k| k.clips()).filter(|c| c.graphics().is_some()).count())
}

fn create_rectangle(r: &mut AppRoot) {
    let t = r.timeline.inner().panel.tool_state_mut();
    t.tool = TimelineTool::Type;
    t.create_mode = CreateToolMode::Rectangle;
}

fn canvas_points(r: &AppRoot) -> ((f32, f32), (f32, f32)) {
    let c = r.monitor.panel.canvas_rect();
    (
        ((c.min_x() + c.width * 0.3) as f32, (c.min_y() + c.height * 0.3) as f32),
        ((c.min_x() + c.width * 0.6) as f32, (c.min_y() + c.height * 0.6) as f32),
    )
}

#[test]
fn a_create_rectangle_drag_over_a_video_clip_makes_a_shape_not_a_mask() {
    let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
    create_rectangle(&mut r);
    r.sync(&rig.session);
    let (a, b) = canvas_points(&r);
    drag(&mut r, &mut rig, a, b);
    assert_ne!(rig.session.undo_name(), Some("Add Mask"));
    assert_eq!(graphic_clips(&rig), 1, "a new Graphic clip holds the shape ({:?})", rig.session.undo_name());
}

#[test]
fn a_create_rectangle_drag_on_empty_time_with_nothing_selected_makes_a_graphic() {
    let mut s = demo_session(Scenario::Plain);
    s.select(Default::default(), Default::default());
    s.seek(sq_core_time::Time::seconds(60));
    let (mut r, mut rig) = standard(s);
    create_rectangle(&mut r);
    r.sync(&rig.session);
    let (a, b) = canvas_points(&r);
    drag(&mut r, &mut rig, a, b);
    assert_eq!(graphic_clips(&rig), 1, "{:?}", rig.session.undo_name());
}

#[test]
fn a_press_and_drag_on_the_source_picture_places_the_clip_on_the_timeline() {
    let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
    let before: usize = rig.session.active_timeline().map_or(0, |t| t.tracks.iter().map(|k| k.clips().len()).sum());
    assert!(r.source.as_mut().expect("source").open(&mut rig.cx(), sq_core_time::Id::from_u128(902)));
    r.select_monitor_tab(1);
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let c = r.dock.content_frame(PanelID::SourceMonitor).expect("source monitor docked");
    let from = ((c.min_x() + c.width * 0.5) as f32, (c.min_y() + c.height * 0.45) as f32);
    let tl = r.dock.content_frame(PanelID::Timeline).expect("timeline docked");
    let to = ((tl.min_x() + 500.0) as f32, (tl.min_y() + 90.0) as f32);
    let none = InputModifiers::NONE;
    r.handle(&InputEvent::MouseDown { x: from.0, y: from.1, modifiers: none }, &mut rig.cx());
    for i in 1..=5 {
        let f = i as f32 / 5.0;
        let (x, y) = (from.0 + (to.0 - from.0) * f, from.1 + (to.1 - from.1) * f);
        r.handle(&InputEvent::MouseDragged { x, y, modifiers: none }, &mut rig.cx());
        r.pump(&mut rig.cx());
    }
    r.handle(&InputEvent::MouseUp { x: to.0, y: to.1 }, &mut rig.cx());
    r.pump(&mut rig.cx());
    let after: usize = rig.session.active_timeline().map_or(0, |t| t.tracks.iter().map(|k| k.clips().len()).sum());
    assert!(after > before, "the Source clip was placed ({before} -> {after})");
}

#[test]
fn the_create_menu_rectangle_chosen_in_the_strip_then_a_drag_on_the_picture_makes_a_shape() {
    let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
    let slot = r.tools.tools().slots().1[4];
    let (x, y) = ((slot.min_x() + slot.width / 2.0) as f32, (slot.min_y() + slot.height / 2.0) as f32);
    r.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::SECONDARY }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    r.pump(&mut rig.cx());
    assert!(r.menu.is_open(), "the Create slot's menu is open");
    let row = r.menu.root_items().into_iter().find(|i| i.title == "Rectangle").expect("a Rectangle row");
    (row.action.as_ref().expect("the row runs"))();
    r.pump_menu_picks(&mut rig.cx());
    r.sync(&rig.session);
    let st = *r.timeline.inner().panel.tool_state();
    assert_eq!((st.tool, st.create_mode), (TimelineTool::Type, CreateToolMode::Rectangle));
    let (a, b) = canvas_points(&r);
    drag(&mut r, &mut rig, a, b);
    assert_ne!(rig.session.undo_name(), Some("Add Mask"));
    assert_eq!(graphic_clips(&rig), 1, "{:?}", rig.session.undo_name());
}

#[test]
fn reset_to_saved_layout_docks_a_floating_panel_through_the_real_root() {
    let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
    assert!(r.dock.float(PanelID::Effects, None));
    assert!(r.dock.float(PanelID::EffectControls, None));
    r.sync(&rig.session);
    let keys = InputModifiers::OPTION | InputModifiers::SHIFT;
    r.handle(&InputEvent::KeyDown { key: sq_draw::InputKey::Character('0'), modifiers: keys }, &mut rig.cx());
    r.pump(&mut rig.cx());
    assert!(r.dock.floating.panels().is_empty(), "{:?}", r.dock.floating.panels());
    assert!(r.dock.floating.flush(true).is_some(), "the docked state is saved");
}

#[test]
fn window_panel_row_brings_a_floating_window_forward() {
    let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
    assert!(r.dock.float(PanelID::Effects, None));
    r.dock.floating.take_raised();
    let cmd = sq_uikit::editor_command::EditorCommand::FocusPanel(PanelID::Effects);
    r.shell_turn(&mut rig.cx(), |shell, cx| shell.run_command(cx, cmd));
    assert!(r.dock.floating.is_floating(PanelID::Effects), "still floating");
    assert_eq!(r.dock.floating.take_raised(), vec![PanelID::Effects]);
}

/// The Color page with the dock strip's button `which` clicked; the root is on the page, the menu pass has run.
fn color_strip_click(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, which: usize) {
    use sq_inspector_ui::color::color_viewer_header_draw::{ColorStripToolsDraw, StripPanel};
    r.dock.set_page(sq_editor_session::WorkspacePage::Color);
    // The Color page grades one picture clip: select it now that the page is open.
    let clip = rig
        .session
        .active_timeline()
        .expect("sequence")
        .tracks
        .iter()
        .filter(|t| t.kind == sq_core_model::TrackKind::Video)
        .flat_map(|t| t.clips())
        .map(|c| c.id)
        .next()
        .expect("a picture clip");
    rig.session.select(std::collections::BTreeSet::from([clip]), std::collections::BTreeSet::new());
    r.on_change(
        sq_editor_session::Change::PROJECT | sq_editor_session::Change::SELECTION | sq_editor_session::Change::PLAYHEAD,
        &mut rig.cx(),
    );
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let strip = r.dock.groups().iter().find(|g| g.selected == PanelID::Timeline).expect("timeline group").strip;
    let frames = ColorStripToolsDraw::frames(StripPanel::Timeline, strip);
    let b = frames[which].1;
    let (x, y) = (b.mid_x() as f32, b.mid_y() as f32);
    r.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    r.pump(&mut rig.cx());
}

#[test]
fn every_color_strip_dropdown_opens_its_timeline_menu_through_the_real_root() {
    // Sequence, Normal, Fit and "..." (the strip's order).
    let want: [(&str, &str); 4] =
        [("Sequence", "Main"), ("Mode", "Fast Cut"), ("Fit", "Fit Sequence"), ("More", "Add Video Track")];
    for (i, (name, row)) in want.iter().enumerate() {
        let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
        color_strip_click(&mut r, &mut rig, i);
        assert!(r.menu.is_open(), "{name} opens a menu");
        let titles: Vec<String> = r.menu.root_items().into_iter().map(|i| i.title).collect();
        if *name == "Sequence" {
            assert!(!titles.is_empty(), "{name}: the open sequences are listed");
        } else {
            assert!(titles.iter().any(|t| t == row), "{name}: {titles:?}");
        }
    }
}

#[test]
fn the_color_strip_mode_dropdown_switches_to_fast_cut() {
    let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
    color_strip_click(&mut r, &mut rig, 1);
    let row = r.menu.root_items().into_iter().find(|i| i.title == "Fast Cut").expect("a Fast Cut row");
    (row.action.as_ref().expect("the row runs"))();
    r.pump_menu_picks(&mut rig.cx());
    r.pump(&mut rig.cx());
    assert_eq!(rig.session.active_timeline().map(|t| t.edit_mode()), Some(sq_core_model::TimelineEditMode::Magnetic));
}

#[test]
fn copy_and_paste_grade_work_from_the_color_strip_more_menu() {
    let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
    color_strip_click(&mut r, &mut rig, 3);
    let items = r.menu.root_items();
    let copy = items.iter().find(|i| i.title == "Copy Grade").expect("a Copy Grade row");
    assert!(copy.is_enabled, "a clip is selected");
    (copy.action.as_ref().expect("the row runs"))();
    r.pump_menu_picks(&mut rig.cx());
    r.pump(&mut rig.cx());
    r.pump(&mut rig.cx());
    assert!(r.color.clipboard_has_color(), "the grade was copied");
    let mut r2 = r;
    r2.menu.dismiss();
    let strip = r2.dock.groups().iter().find(|g| g.selected == PanelID::Timeline).expect("group").strip;
    let b = sq_inspector_ui::color::color_viewer_header_draw::ColorStripToolsDraw::frames(
        sq_inspector_ui::color::color_viewer_header_draw::StripPanel::Timeline,
        strip,
    )[3]
    .1;
    let (x, y) = (b.mid_x() as f32, b.mid_y() as f32);
    r2.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r2.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx());
    r2.pump(&mut rig.cx());
    let paste = r2.menu.root_items().into_iter().find(|i| i.title == "Paste Grade").expect("a Paste Grade row");
    assert!(paste.is_enabled, "a copied grade can be pasted");
    (paste.action.as_ref().expect("the row runs"))();
    r2.pump_menu_picks(&mut rig.cx());
    r2.pump(&mut rig.cx());
    // The demo clip has no grade, so pasting it changes nothing; the row ran and the page took the pick.
    assert!(r2.color.clipboard_has_color(), "the copied grade stays on the page's clipboard");
}

#[test]
fn the_color_page_timeline_keeps_only_the_timecode_row_and_the_edit_page_its_header() {
    let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    assert!(r.header.bar().bar().height > 0.0, "the Edit page keeps the header row");
    color_strip_click(&mut r, &mut rig, 0);
    assert_eq!(r.header.bar().bar().height, 0.0, "the Color page drops the header row");
    assert!(r.header.bar().frames().snap.width > 0.0, "the toggles stay");
}

/// Windows bug: the export queue popover lies over the panels, but a click on its buttons went to the panel underneath.
#[test]
fn a_click_inside_the_export_queue_popover_does_not_reach_the_panel_under_it() {
    let (mut r, mut rig) = standard(demo_session(Scenario::Plain));
    r.shell.shell().show_export_queue(CGPoint::new(1380.0, 880.0), CGRect::default());
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let frame = r.shell.shell().export_queue_popover_frame().expect("the popover is up");
    let inside = ((frame.mid_x()) as f32, (frame.mid_y()) as f32);
    let under = r.dock.panel_at(CGPoint::new(f64::from(inside.0), f64::from(inside.1))).expect("a panel is under it");
    let other = [
        sq_uikit::panel_id::PanelID::Library,
        sq_uikit::panel_id::PanelID::Effects,
        sq_uikit::panel_id::PanelID::Timeline,
    ]
    .into_iter()
    .find(|p| *p != under)
    .expect("another panel");
    r.dock.focus_press(other);
    let none = InputModifiers::NONE;
    assert!(r.handle(&InputEvent::MouseDown { x: inside.0, y: inside.1, modifiers: none }, &mut rig.cx()));
    r.handle(&InputEvent::MouseUp { x: inside.0, y: inside.1 }, &mut rig.cx());
    assert_eq!(r.dock.focused(), Some(other), "the press stayed in the popover");
    assert!(r.shell.shell().export_queue_popover_frame().is_some(), "a press inside does not close it");
    // Escape closes it.
    r.handle(&InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: none }, &mut rig.cx());
    assert!(r.shell.shell().export_queue_popover_frame().is_none(), "Escape closes the popover");
}

/// A click on the first video clip at 1 s, through `AppRoot::handle` like the window's; then the panels follow the session
/// the way the app loop does (pump, sync, layout).
fn click_the_first_video_clip(r: &mut AppRoot, rig: &mut crate::test_rig::Rig) {
    let track = rig.session.active_timeline().and_then(|t| t.tracks.iter().find(|k| k.kind == TrackKind::Video));
    let y = r.timeline.inner().panel.pixel_y_body_of(track.map(|k| k.id).expect("a video track")).expect("its row");
    let x = r.timeline.inner().panel.pixel_x(sq_core_time::Time::seconds(1));
    r.handle(&InputEvent::MouseDown { x, y: y + 4.0, modifiers: InputModifiers::NONE }, &mut rig.cx());
    r.handle(&InputEvent::MouseUp { x, y: y + 4.0 }, &mut rig.cx());
    r.pump(&mut rig.cx());
    r.sync(&rig.session);
    r.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
}

#[test]
fn a_click_on_the_picture_clip_of_a_linked_pair_shows_the_audio_section_and_tabs_in_controls() {
    let mut s = demo_session(Scenario::Plain);
    s.select(Default::default(), Default::default());
    let (mut r, mut rig) = standard(s);
    assert!(rig.session.linked_selection(), "Linked Selection is on by default");
    click_the_first_video_clip(&mut r, &mut rig);
    assert_eq!(rig.session.selection().len(), 2, "the click selected the picture clip and its audio partner");
    let shown = r.inspector.controls().model.visible_sections();
    assert!(shown.contains(&EffectSection::Volume), "Controls has the AUDIO section: {shown:?}");
    assert_eq!(r.inspector.sections().mode(), ClipSectionMode::Audio, "the audio sections of the pair's track");
    let block = r.inspector.sections().audio_block().expect("the audio block");
    assert!(block.frame(Control::Tab).is_some(), "the Track and Effects tabs are there");
}

#[test]
fn a_click_on_a_picture_clip_without_a_link_shows_only_its_video_controls() {
    // Linux round 5 clicked a red V1 clip whose A1 partner had been unlinked in an earlier session (Detach Audio / Ctrl+L):
    // no pair, so no AUDIO section is right. The linked case above is the one that must show it.
    let mut s = demo_session(Scenario::Plain);
    assert!(s.detach_audio_selection(), "the pairs are unlinked");
    s.select(Default::default(), Default::default());
    let (mut r, mut rig) = standard(s);
    click_the_first_video_clip(&mut r, &mut rig);
    assert_eq!(rig.session.selection().len(), 1, "an unlinked clip is selected alone");
    let shown = r.inspector.controls().model.visible_sections();
    assert!(!shown.contains(&EffectSection::Volume), "no AUDIO section for a clip without a partner: {shown:?}");
    assert_ne!(r.inspector.sections().mode(), ClipSectionMode::Audio);
}
