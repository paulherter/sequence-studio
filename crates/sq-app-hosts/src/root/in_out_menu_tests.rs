//! In and Out through the real root. "Remove In and Out" in the right-click menus: a real right-click, the row picked with
//! the mouse, the marks gone from the sequence AND from the Program monitor's strip, and Undo brings them back. A drag on the
//! Program monitor's time bar only moves the playhead.

use super::dead_commands_tests::{Scenario, demo_session};
use super::disabled_commands_tests::frame;
use super::menu_click_tests::{click, send};
use super::*;
use sq_core_time::Time;
use sq_draw::monitor::monitor_footer::MonitorScrubMath;
use sq_runtime::FakeClock;
use std::sync::Arc;

fn standard() -> (AppRoot, crate::test_rig::Rig, std::path::PathBuf) {
    standard_with(Scenario::InOut)
}

fn standard_with(scenario: Scenario) -> (AppRoot, crate::test_rig::Rig, std::path::PathBuf) {
    let dir = crate::test_rig::unique_dir("sq-in-out-menu");
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
    let mut rig = crate::test_rig::Rig::new(demo_session(scenario));
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    frame(&mut root, &mut rig);
    // The drawn menu bar builds its menus on the first event it sees.
    send(&mut root, &mut rig, InputEvent::MouseMoved { x: 700.0, y: 450.0 });
    (root, rig, dir)
}

fn settle(root: &mut AppRoot, rig: &mut crate::test_rig::Rig) {
    root.sync(&rig.session);
    for _ in 0..2 {
        frame(root, rig);
        root.answer(&mut rig.cx());
    }
}

fn in_out(rig: &crate::test_rig::Rig) -> Option<sq_core_time::TimeRange> {
    rig.session.active_timeline().and_then(|t| t.in_out)
}

fn strip_marks(root: &AppRoot) -> (Option<Time>, Option<Time>) {
    (root.monitor.panel.model.mark_in, root.monitor.panel.model.mark_out)
}

/// Right-clicks at `at`, picks "Remove In and Out" with the mouse, and checks the marks go and Undo brings them back.
fn remove_in_and_out_from(place: &str, at: impl FnOnce(&mut AppRoot, &crate::test_rig::Rig) -> (f32, f32)) {
    let (mut root, mut rig, dir) = standard();
    let before = in_out(&rig);
    assert!(before.is_some(), "{place}: the demo has In and Out");
    settle(&mut root, &mut rig);
    assert!(strip_marks(&root).0.is_some(), "{place}: the Program strip shows the sequence's In");
    let (x, y) = at(&mut root, &rig);
    send(&mut root, &mut rig, InputEvent::MouseMoved { x, y });
    send(&mut root, &mut rig, InputEvent::MouseDown { x, y, modifiers: InputModifiers::SECONDARY });
    send(&mut root, &mut rig, InputEvent::MouseUp { x, y });
    settle(&mut root, &mut rig);
    assert!(root.menu.is_open(), "{place}: the right-click opens a menu");
    let titles: Vec<String> = root.menu.root_items().into_iter().map(|i| i.title).collect();
    let index = titles.iter().position(|t| t == "Remove In and Out").unwrap_or(usize::MAX);
    assert!(index < titles.len(), "{place}: no Remove In and Out row in {titles:?}");
    let v = &root.menu.views()[0];
    assert!(v.items[index].is_enabled, "{place}: the row is enabled while In and Out are set");
    let r = v.row_frames[index];
    let row_at = CGPoint::new(v.origin.x + r.mid_x(), v.origin.y + r.mid_y() - v.scroll_offset);
    click(&mut root, &mut rig, row_at);
    settle(&mut root, &mut rig);
    assert_eq!(in_out(&rig), None, "{place}: the marks are gone after the row");
    assert_eq!(strip_marks(&root), (None, None), "{place}: the Program strip shows no marks after the row");
    assert!(rig.session.undo(), "{place}: the removal is one undo step");
    settle(&mut root, &mut rig);
    assert_eq!(in_out(&rig), before, "{place}: Undo brings the marks back");
    assert!(strip_marks(&root).0.is_some(), "{place}: Undo brings the marks back on the strip");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn remove_in_and_out_from_the_ruler_menu() {
    remove_in_and_out_from("ruler", |root, _rig| {
        // The ruler is the top RULER (24 pt, r8) strip of the Timeline panel, under the 30 pt tab header; its middle is clear of the caption lanes.
        let p = &root.timeline.inner().panel;
        let r = root.dock.content_frame(PanelID::Timeline).expect("timeline");
        (
            p.pixel_x(Time::seconds(1)),
            (r.min_y() + PanelID::HEADER_HEIGHT + sq_timeline_ui::TimelineGeometry::RULER_HEIGHT / 2.0) as f32,
        )
    });
}

#[test]
fn remove_in_and_out_from_the_program_monitor_menu() {
    remove_in_and_out_from("program monitor", |root, _| {
        let r = root.dock.content_frame(PanelID::ProgramMonitor).expect("program monitor");
        (r.mid_x() as f32, r.mid_y() as f32)
    });
}

/// Presses at `from` and drags to `to` (fractions of the Program strip's track), then lets go.
fn drag_along_the_program_strip(root: &mut AppRoot, rig: &mut crate::test_rig::Rig, from: f64, to: f64) {
    let strip = root.monitor.panel.footer().scrub_rect();
    let model = &root.monitor.panel.model;
    let m = MonitorScrubMath::new(model.duration, model.frame_duration, strip.width);
    let at = |f: f64| (strip.min_x() + m.inset + f * (strip.width - 2.0 * m.inset)) as f32;
    let y = strip.mid_y() as f32;
    let (x0, x1) = (at(from), at(to));
    send(root, rig, InputEvent::MouseMoved { x: x0, y });
    send(root, rig, InputEvent::MouseDown { x: x0, y, modifiers: InputModifiers::default() });
    for step in 1..=8 {
        let x = x0 + (x1 - x0) * step as f32 / 8.0;
        send(root, rig, InputEvent::MouseDragged { x, y, modifiers: InputModifiers::default() });
    }
    send(root, rig, InputEvent::MouseUp { x: x1, y });
    settle(root, rig);
}

#[test]
fn a_drag_on_the_program_time_bar_moves_the_playhead_and_keeps_in_and_out() {
    for scenario in [Scenario::Plain, Scenario::InOut] {
        let (mut root, mut rig, dir) = standard_with(scenario);
        settle(&mut root, &mut rig);
        let (marks, playhead) = (in_out(&rig), rig.session.playhead());
        // Away from the playhead and from the grips: the old strip marked a new range or moved the whole range here.
        drag_along_the_program_strip(&mut root, &mut rig, 0.55, 0.9);
        assert_eq!(in_out(&rig), marks, "{scenario:?}: the drag left In and Out alone");
        assert_ne!(rig.session.playhead(), playhead, "{scenario:?}: the drag moved the playhead");
        let _ = std::fs::remove_dir_all(dir);
    }
}
