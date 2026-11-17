//! A panel that is not on screen takes no pointer: a hidden or covered panel (another tab on top, or another panel
//! maximized) offers no tip, no cursor and runs no control. The use pass found the Program monitor's header tips and the
//! timeline header's "Add marker (M)" tip over a maximized Effect Controls, Text or Graphics panel: both panels kept the
//! control rectangles of their last drawn frame and the root still routed every pointer event to them.

use super::menu_click_tests::new_root;
use super::*;
use crate::test_rig::Rig;
use sq_app_shell::AppHost;
use std::collections::{BTreeMap, BTreeSet};

const WINDOW: CGRect = CGRect { x: 0.0, y: 0.0, width: 1400.0, height: 900.0 };
/// The distance between the points of a sweep (points): finer than the smallest header button.
const PITCH: usize = 8;

fn frame(root: &mut AppRoot, rig: &mut Rig) {
    root.sync(&rig.session);
    root.layout(WINDOW, &mut rig.cx());
    let theme = DrawTheme::default();
    let mut canvas = sq_draw::Canvas::with_size(WINDOW.width as f32, WINDOW.height as f32, None, 1.0);
    root.draw(&mut canvas, &theme, &mut rig.cx());
}

/// The tip the app would show with the pointer at `p`, routed as the window routes a move.
fn tip_at(root: &mut AppRoot, rig: &mut Rig, p: CGPoint) -> Option<String> {
    let e = InputEvent::MouseMoved { x: p.x as f32, y: p.y as f32 };
    rig.ui.hover.begin_event(&e);
    root.handle(&e, &mut rig.cx());
    rig.ui.hover.end_event(&e, rig.ui.now);
    rig.ui.hover.tooltip.text.clone()
}

fn grid() -> impl Iterator<Item = CGPoint> {
    (0..WINDOW.height as usize / PITCH).flat_map(|gy| {
        (0..WINDOW.width as usize / PITCH)
            .map(move |gx| CGPoint::new((gx * PITCH + PITCH / 2) as f64, (gy * PITCH + PITCH / 2) as f64))
    })
}

/// Every tip the panels offer on the plain Edit page, by the panel whose card the pointer is on.
fn tips_by_panel() -> BTreeMap<String, BTreeSet<String>> {
    let (mut root, mut rig) = new_root();
    frame(&mut root, &mut rig);
    let mut by_panel: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for p in grid() {
        let Some(panel) = root.dock.panel_at(p) else { continue };
        if let Some(tip) = tip_at(&mut root, &mut rig, p) {
            by_panel.entry(format!("{panel:?}")).or_default().insert(tip);
        }
    }
    by_panel
}

/// The poses that maximize one panel, and the panel each leaves on screen.
const MAXIMIZING: [(&str, &str); 3] =
    [("max-ec", "EffectControls"), ("captions-list", "Text"), ("graphics", "Graphics")];

#[test]
fn a_covered_panel_offers_no_tip() {
    let tips = tips_by_panel();
    assert!(tips.len() >= 4, "the plain Edit page offers tips from several panels: {:?}", tips.keys());
    for (pose, shown) in MAXIMIZING {
        let (mut root, mut rig) = new_root();
        // The panels draw once while they are all on screen, so their control rectangles are the last drawn ones.
        frame(&mut root, &mut rig);
        assert!(AppHost::shot_pose(&mut root, pose, &mut rig.cx()), "pose {pose}");
        frame(&mut root, &mut rig);
        let own: BTreeSet<&String> = tips.get(shown).into_iter().flatten().collect();
        let covered: BTreeMap<&String, &String> = tips
            .iter()
            .filter(|(panel, _)| panel.as_str() != shown)
            .flat_map(|(panel, set)| set.iter().map(move |t| (t, panel)))
            .filter(|(t, _)| !own.contains(t))
            .collect();
        // The first point of each stale tip is enough to find it.
        let mut stale: BTreeMap<String, String> = BTreeMap::new();
        for p in grid() {
            if let Some(tip) = tip_at(&mut root, &mut rig, p)
                && let Some(panel) = covered.get(&tip)
            {
                stale.entry(tip).or_insert_with(|| format!("of {panel} at {},{}", p.x, p.y));
            }
        }
        assert!(stale.is_empty(), "{pose}: tips of panels the {shown} panel covers: {stale:?}");
    }
}

/// The node ids a collector holds after `push`.
fn node_ids(push: impl FnOnce(&mut sq_draw::A11y)) -> BTreeSet<u64> {
    let mut a = sq_draw::A11y::new(true);
    push(&mut a);
    a.nodes().iter().map(|(id, _)| id.0).collect()
}

/// A screen reader sees only what the dock draws: a covered panel keeps the controls of its last frame, and offering them
/// would let an assistive "click" run a control nobody can see.
#[test]
fn a_covered_panel_pushes_no_a11y_nodes() {
    let mut covered_nodes = 0;
    for (pose, shown) in MAXIMIZING {
        let (mut root, mut rig) = new_root();
        frame(&mut root, &mut rig);
        assert!(AppHost::shot_pose(&mut root, pose, &mut rig.cx()), "pose {pose}");
        frame(&mut root, &mut rig);
        let all = node_ids(|a| AppHost::a11y(&root, a));
        let panels = [
            (PanelID::ProgramMonitor, node_ids(|a| root.monitor.a11y(a))),
            (PanelID::Library, node_ids(|a| root.library.a11y(a))),
            (PanelID::Timeline, node_ids(|a| root.timeline.a11y(a))),
            (PanelID::EffectControls, node_ids(|a| root.inspector.a11y(a))),
            (PanelID::Project, node_ids(|a| root.project.a11y(a))),
        ];
        for (panel, own) in panels {
            let on_screen =
                if panel == PanelID::ProgramMonitor { root.monitor_shown() } else { root.dock.shows(panel) };
            let leaked: Vec<u64> = own.intersection(&all).copied().collect();
            if on_screen {
                assert_eq!(leaked.len(), own.len(), "{pose}: the shown {panel:?} drops its nodes");
            } else {
                covered_nodes += own.len();
                assert!(
                    leaked.is_empty(),
                    "{pose}: the {shown} panel covers {panel:?}, which still pushes {} nodes",
                    leaked.len()
                );
            }
        }
    }
    assert!(covered_nodes > 0, "the covered panels held nodes to leak, or the test proves nothing");
}

/// A click where a covered panel had a control runs nothing: the use pass found the title bar's "Sequence" menu dead
/// over a maximized panel, because the hidden timeline header (laid out in an empty frame, at the window's corner) still
/// answered there with "Add marker".
#[test]
fn a_click_where_a_covered_panel_had_a_control_runs_nothing() {
    for (pose, shown) in MAXIMIZING {
        let (mut root, mut rig) = new_root();
        frame(&mut root, &mut rig);
        assert!(AppHost::shot_pose(&mut root, pose, &mut rig.cx()), "pose {pose}");
        frame(&mut root, &mut rig);
        let f = root.header.bar().frames();
        let controls = [("Snapping", f.snap), ("Linked Selection", f.link), ("Add marker", f.marker)];
        assert!(
            controls.iter().all(|(_, r)| r.width > 0.0),
            "the hidden header kept its button rectangles: {controls:?}"
        );
        for (name, r) in controls {
            let at = CGPoint::new(r.mid_x(), r.mid_y());
            let before = (
                rig.session.version(sq_editor_session::Change::PROJECT),
                root.timeline.inner().panel.tool_state().snapping,
            );
            let title = root.shell.shell().menu_bar.title_frames().iter().any(|t| t.contains(at));
            let (x, y) = (at.x as f32, at.y as f32);
            for e in [
                InputEvent::MouseMoved { x, y },
                InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE },
                InputEvent::MouseUp { x, y },
            ] {
                root.handle(&e, &mut rig.cx());
            }
            let after = (
                rig.session.version(sq_editor_session::Change::PROJECT),
                root.timeline.inner().panel.tool_state().snapping,
            );
            assert_eq!(after, before, "{pose}: a click at {at:?} ({name}) over the {shown} panel changed the editor");
            if title {
                assert!(root.shell.menu_open(), "{pose}: the menu title at {at:?} opens its menu");
                key_escape(&mut root, &mut rig);
            }
        }
    }
}

fn key_escape(root: &mut AppRoot, rig: &mut Rig) {
    root.handle(
        &InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: InputModifiers::NONE },
        &mut rig.cx(),
    );
}

/// How a test opens each surface that covers the whole window: a dialog of the root, a dialog or sheet of the shell, the
/// Keyboard Shortcuts page (Settings is a shell dialog like the others; it needs the app's flows, which the rig lacks).
type Opener = Box<dyn Fn(&mut AppRoot)>;

fn sheets() -> Vec<(&'static str, Opener)> {
    vec![
        ("a root dialog", Box::new(|r| r.show_dialog(sq_draw_shell::ShellDialog::new("Match Loudness", "Done")))),
        ("the About dialog", Box::new(|r| assert!(r.shell.shell().present_sample_dialog("about")))),
        ("the Save Changes dialog", Box::new(|r| assert!(r.shell.shell().present_sample_dialog("save")))),
        ("the Keyboard Shortcuts page", Box::new(|r| r.shell.shell().show_shortcuts_page())),
    ]
}

/// A sheet or dialog is modal for the pointer too: with one up, the panels behind it get no hover (no tip, no highlight) and
/// no click (the use pass checks the same with the Settings sheet).
#[test]
fn a_sheet_blocks_hover_and_clicks_for_the_panels_behind_it() {
    let behind = tips_by_panel().into_values().flatten().collect::<BTreeSet<String>>();
    for (name, open) in sheets() {
        let (mut root, mut rig) = new_root();
        frame(&mut root, &mut rig);
        let f = root.header.bar().frames();
        let (snap, marker) =
            (CGPoint::new(f.snap.mid_x(), f.snap.mid_y()), CGPoint::new(f.marker.mid_x(), f.marker.mid_y()));
        open(&mut root);
        frame(&mut root, &mut rig);
        // Hover: no tip of a panel behind the sheet, and no header button lights up under the pointer.
        let mut leaked = BTreeSet::new();
        for p in grid() {
            if let Some(tip) = tip_at(&mut root, &mut rig, p)
                && behind.contains(&tip)
            {
                leaked.insert(tip);
            }
        }
        assert!(leaked.is_empty(), "{name}: tips of the panels behind it: {leaked:?}");
        for p in [snap, marker] {
            tip_at(&mut root, &mut rig, p);
            assert_eq!(
                root.header.bar().hovered(),
                None,
                "{name}: a header button lights up behind the sheet at {p:?}"
            );
        }
        // Click: nothing behind the sheet runs.
        let state = |root: &mut AppRoot, rig: &Rig| {
            (rig.session.version(sq_editor_session::Change::PROJECT), root.timeline.inner().panel.tool_state().snapping)
        };
        let before = state(&mut root, &rig);
        for p in [snap, marker] {
            let (x, y) = (p.x as f32, p.y as f32);
            for e in [
                InputEvent::MouseMoved { x, y },
                InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE },
                InputEvent::MouseUp { x, y },
            ] {
                root.handle(&e, &mut rig.cx());
            }
        }
        assert_eq!(state(&mut root, &rig), before, "{name}: a click behind the sheet changed the editor");
    }
}
