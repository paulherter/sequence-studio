//! Popups through the whole root: the control that opened a popup closes it on a second click (and the release of that
//! click does not open it again), and the openers really open something.

use super::menu_click_tests::{new_root, send};
use super::*;

const NONE: InputModifiers = InputModifiers::NONE;

/// A click at window point `p` as the window sends it: device pixels at `scale`.
fn click_at(root: &mut AppRoot, rig: &mut crate::test_rig::Rig, p: CGPoint) {
    let k = f64::from(rig.scale);
    let (x, y) = ((p.x * k) as f32, (p.y * k) as f32);
    send(root, rig, InputEvent::MouseMoved { x, y });
    send(root, rig, InputEvent::MouseDown { x, y, modifiers: NONE });
    send(root, rig, InputEvent::MouseUp { x, y });
}

#[test]
fn the_workspace_button_opens_its_menu_on_the_mac_window() {
    for scale in [1.0_f32, 2.0] {
        let (mut root, mut rig) = new_root();
        rig.scale = scale;
        root.shell.shell().menu_bar.use_system_bar();
        root.shell.shell().window_lights = true;
        root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
        let r = root.chrome.workspace_button().expect("the workspace button");
        click_at(&mut root, &mut rig, CGPoint::new(r.mid_x(), r.mid_y()));
        assert!(root.menu.is_open(), "a click on the workspace button opens the workspace menu at scale {scale}");
        click_at(&mut root, &mut rig, CGPoint::new(r.mid_x(), r.mid_y()));
        assert!(!root.menu.is_open(), "a second click on it closes the menu at scale {scale}");
    }
}

/// A tab dragged over another dock place shows its drop preview (the dimmed target card, its zone highlights and the
/// tab ghost) through the real root: the state is set while the pointer is down and the draw list carries it.
#[test]
fn dragging_a_panel_tab_over_another_place_shows_the_drop_preview() {
    for scale in [1.0_f32, 2.0] {
        let (mut root, mut rig) = new_root();
        rig.scale = scale;
        root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
        let g = root.dock.groups().iter().find(|g| g.panels.contains(&PanelID::Project)).cloned().expect("group");
        let tab = g.tabs[g.panels.iter().position(|p| *p == PanelID::Project).expect("tab")];
        let k = f64::from(scale);
        let at = |x: f64, y: f64| ((x * k) as f32, (y * k) as f32);
        let (x, y) = at(tab.mid_x(), tab.mid_y());
        send(&mut root, &mut rig, InputEvent::MouseMoved { x, y });
        send(&mut root, &mut rig, InputEvent::MouseDown { x, y, modifiers: NONE });
        let timeline = root.dock.card_frame(PanelID::Timeline).expect("timeline frame");
        let (x, y) = at(timeline.mid_x(), timeline.mid_y());
        send(&mut root, &mut rig, InputEvent::MouseDragged { x, y, modifiers: NONE });
        assert!(root.dock.drag_tab().is_some(), "the tab ghost follows the pointer at scale {scale}");
        let target = root.dock.drop_target().expect("a drop target while dragging over another card");
        assert!(target.zone.is_some() || target.strip_highlight, "the target shows where it lands");
        // The preview is in the root's drawn frame, not only in the state.
        let theme = DrawTheme { scale, ..DrawTheme::default() };
        let quads = |root: &mut AppRoot, rig: &mut crate::test_rig::Rig| {
            let mut c = sq_draw::Canvas::with_size(1400.0 * scale, 900.0 * scale, None, scale);
            root.draw(&mut c, &theme, &mut rig.cx());
            c.list.quads().len()
        };
        let during = quads(&mut root, &mut rig);
        send(&mut root, &mut rig, InputEvent::MouseUp { x, y });
        let after = quads(&mut root, &mut rig);
        assert!(during > after, "the preview draws extra shapes while dragging ({during} vs {after}) at scale {scale}");
    }
}

/// Option+Space (Ctrl+Space on Windows and Linux) opens the Quick Apply palette with rows (effects, presets, commands),
/// through the real key path of the root; a second press closes it.
#[test]
fn the_quick_apply_key_opens_the_palette_with_rows_and_toggles_it() {
    let (mut root, mut rig) = new_root();
    let modifiers =
        if sq_os::Platform::current().command_is_cmd_key() { InputModifiers::OPTION } else { InputModifiers::COMMAND };
    let key = InputEvent::KeyDown { key: InputKey::Space, modifiers };
    send(&mut root, &mut rig, key);
    assert!(root.shell.shell().quick_apply_open(), "the Quick Apply key opens it");
    use sq_draw_shell::ShellHooks as _;
    let rows = root.timeline_link.as_ref().map(sq_app_hosts_hooks).expect("link").quick_apply_items();
    let rows = rows.expect("the hook lists rows");
    assert!(rows.iter().any(|r| r.category == "Effect"), "effects are listed");
    assert!(rows.iter().any(|r| r.category == "Command"), "commands are listed");
    send(&mut root, &mut rig, key);
    assert!(!root.shell.shell().quick_apply_open(), "the key again closes it");
}

fn sq_app_hosts_hooks(link: &crate::timeline_commands::TimelineLink) -> crate::timeline_commands::TimelineHooks {
    crate::timeline_commands::TimelineHooks::from_link(link)
}

/// Table over the openers of the editing window that report a button rect: each opens its menu on a click and closes it on
/// a second click on the same button, and the release of that second click does not reopen it.
#[test]
fn every_header_and_title_opener_toggles_its_menu() {
    for scale in [1.0_f32, 2.0] {
        let (mut root, mut rig) = new_root();
        rig.scale = scale;
        root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
        let f = *root.header.bar().frames();
        let openers: Vec<(&str, CGRect)> = vec![
            ("timeline Normal / Fast Cut", f.edit_mode),
            ("timeline Fit", f.fit),
            ("timeline \u{2026}", f.more),
            ("top bar workspace", root.chrome.workspace_button().expect("workspace button")),
        ];
        for (name, r) in openers {
            assert!(r.width > 0.0, "{name}: has a frame");
            let p = CGPoint::new(r.mid_x(), r.mid_y());
            click_at(&mut root, &mut rig, p);
            assert!(root.menu.is_open(), "{name}: a click opens its menu at scale {scale}");
            click_at(&mut root, &mut rig, p);
            assert!(!root.menu.is_open(), "{name}: a second click closes it at scale {scale}");
        }
    }
}

/// The status bar's export ring: a click opens the queue popover, a second click on the ring closes it and the release of
/// that click does not open it again.
#[test]
fn a_second_click_on_the_export_ring_closes_the_queue_popover() {
    let (mut root, mut rig) = new_root();
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    // The ring sits at the right end of the status bar: find it the way a pointer would.
    let mut ring = None;
    let mut x = 1395.0;
    while x > 900.0 && ring.is_none() {
        click_at(&mut root, &mut rig, CGPoint::new(x, 890.0));
        if root.shell.shell().export_queue_popover_frame().is_some() {
            ring = Some(CGPoint::new(x, 890.0));
        }
        x -= 3.0;
    }
    let ring = ring.expect("a click on the ring opens the queue popover");
    click_at(&mut root, &mut rig, ring);
    assert!(root.shell.shell().export_queue_popover_frame().is_none(), "a second click on the ring closes it");
}

/// A click on another control with the queue popover open closes it and acts: the workspace menu opens in the same click.
#[test]
fn a_click_on_another_control_closes_the_queue_popover_and_acts() {
    let (mut root, mut rig) = new_root();
    root.shell.shell().menu_bar.use_system_bar();
    root.shell.shell().window_lights = true;
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let button = root.chrome.workspace_button().expect("the workspace button");
    let mut x = 1395.0;
    while x > 900.0 && root.shell.shell().export_queue_popover_frame().is_none() {
        click_at(&mut root, &mut rig, CGPoint::new(x, 890.0));
        x -= 3.0;
    }
    assert!(root.shell.shell().export_queue_popover_frame().is_some(), "a click on the ring opens the queue popover");
    click_at(&mut root, &mut rig, CGPoint::new(button.mid_x(), button.mid_y()));
    assert!(root.shell.shell().export_queue_popover_frame().is_none(), "the click closed the popover");
    assert!(root.menu.is_open(), "and opened the workspace menu in the same click");
}

/// P24: on the Mac a press in the title row that nothing took starts a native window drag, which swallows the release. So
/// a press on every control of the row must be taken, and a press on empty row space must not be.
#[test]
fn every_title_row_control_takes_its_press_and_empty_space_does_not() {
    for scale in [1.0_f32, 2.0] {
        let (mut root, mut rig) = new_root();
        rig.scale = scale;
        root.shell.shell().menu_bar.use_system_bar();
        root.shell.shell().window_lights = true;
        root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
        let (controls, bottom) = root.chrome.title_drag();
        assert!(controls.len() >= 3, "export, workspace and the page switch have frames");
        let k = f64::from(scale);
        for r in &controls {
            for fx in [0.15, 0.5, 0.85] {
                let (x, y) = (((r.min_x() + r.width * fx) * k) as f32, (r.mid_y() * k) as f32);
                let taken = send(&mut root, &mut rig, InputEvent::MouseDown { x, y, modifiers: NONE });
                send(&mut root, &mut rig, InputEvent::MouseUp { x, y });
                root.menu.dismiss();
                assert!(taken, "a press on a title-row control at ({x}, {y}) is taken (scale {scale})");
            }
        }
        let (x, y) = ((60.0 * k) as f32, ((bottom / 2.0) * k) as f32);
        let free = !controls.iter().any(|r| r.contains(CGPoint::new(60.0, bottom / 2.0)));
        if free {
            let taken = send(&mut root, &mut rig, InputEvent::MouseDown { x, y, modifiers: NONE });
            send(&mut root, &mut rig, InputEvent::MouseUp { x, y });
            assert!(!taken, "empty title-row space is not taken, so it drags the window (scale {scale})");
        }
    }
}

/// Bug 40 (2026-11-14): a double-click on a title-row control (the workspace switch) zoomed the window. The second press
/// of the double-click lands on the control with its popup open; a press nothing takes in the title row starts the native
/// window drag, which zooms on a double-click. So the second press must be taken too, with the popup open or closed.
#[test]
fn a_double_click_on_a_title_row_control_is_taken_both_times() {
    for scale in [1.0_f32, 2.0] {
        let (mut root, mut rig) = new_root();
        rig.scale = scale;
        root.shell.shell().menu_bar.use_system_bar();
        root.shell.shell().window_lights = true;
        root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
        let (controls, _) = root.chrome.title_drag();
        let k = f64::from(scale);
        for r in &controls {
            let (x, y) = (((r.mid_x()) * k) as f32, (r.mid_y() * k) as f32);
            for press in 1..=3 {
                let taken = send(&mut root, &mut rig, InputEvent::MouseDown { x, y, modifiers: NONE });
                send(&mut root, &mut rig, InputEvent::MouseUp { x, y });
                assert!(taken, "press {press} of a quick series on the control at ({x}, {y}) is taken (scale {scale})");
            }
            root.menu.dismiss();
        }
    }
}

fn press_key(root: &mut AppRoot, rig: &mut crate::test_rig::Rig, key: InputKey, modifiers: InputModifiers) {
    send(root, rig, InputEvent::KeyDown { key, modifiers });
}

fn clip_count(rig: &crate::test_rig::Rig) -> usize {
    rig.session.active_timeline().map_or(0, |t| t.tracks.iter().map(|tr| tr.clips().len()).sum())
}

/// AUDIT-SHIP-A A21 / P30: the Timeline-scope keys work in the real root with no panel focused (a fresh window before any
/// click): S toggles snapping, Shift+Backspace ripple deletes.
#[test]
fn timeline_scope_keys_work_with_no_panel_focused() {
    // A fresh window: nothing was clicked, so only the root's own start focus can route the keys.
    let dir = crate::test_rig::unique_dir("sq-fresh-window-keys");
    std::fs::create_dir_all(&dir).expect("dir");
    let mut root = crate::standard_root_with_source(
        &dir,
        std::sync::Arc::new(sq_runtime::FakeClock::new()),
        DrawTheme::default(),
        crate::MonitorPicture::default(),
        Box::new(sq_editor_session::StubProgramEngine::new()),
        crate::MonitorPicture::default(),
    )
    .expect("root");
    let mut rig = crate::test_rig::Rig::new(super::dead_commands_tests::demo_session(
        super::dead_commands_tests::Scenario::Plain,
    ));
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    let all: std::collections::BTreeSet<_> = rig
        .session
        .active_timeline()
        .map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect())
        .unwrap_or_default();
    rig.session.select(all, std::collections::BTreeSet::new());
    root.sync(&rig.session);
    assert_eq!(root.dock.focused(), Some(PanelID::Timeline), "the editing panel starts focused");
    let snapping = |root: &mut AppRoot| root.timeline.inner().panel.tool_state().snapping;
    let before = snapping(&mut root);
    press_key(&mut root, &mut rig, InputKey::Character('s'), NONE);
    assert_ne!(snapping(&mut root), before, "S toggles Snapping with nothing focused");
    let clips = clip_count(&rig);
    press_key(&mut root, &mut rig, InputKey::Backspace, InputModifiers::SHIFT);
    assert!(clip_count(&rig) < clips, "Shift+Backspace deletes the selected clips with nothing focused");
}

/// AUDIT-SHIP-A A22 / P30: Delete then Cmd+Z brings the clips and their selection back.
#[test]
fn undo_after_delete_restores_the_selection() {
    let (mut root, mut rig) = new_root();
    rig.session.set_selection_follows_playhead(false);
    let selected = rig.session.selection().clone();
    assert!(!selected.is_empty(), "the rig selects every clip");
    let clips = clip_count(&rig);
    press_key(&mut root, &mut rig, InputKey::Delete, NONE);
    assert!(clip_count(&rig) < clips, "Delete removed them");
    press_key(&mut root, &mut rig, InputKey::Character('z'), InputModifiers::COMMAND);
    assert_eq!(clip_count(&rig), clips, "Cmd+Z brings the clips back");
    assert_eq!(rig.session.selection(), &selected, "and selects them again");
}
