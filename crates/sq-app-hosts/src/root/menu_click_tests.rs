//! The drawn menu bar through the whole root (Windows and Linux, the bar the Mac replaces with the system one): the open
//! menu is on top of every panel, so its presses and keys reach it before any panel (a panel under a submenu used to take
//! the click, and the focused panel took Enter).

use super::dead_commands_tests::{Scenario, demo_session};
use super::*;
use crate::test_rig::Rig;
use sq_app_shell::AppHost;
use sq_runtime::FakeClock;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::sync::Arc;

const NONE: InputModifiers = InputModifiers::NONE;

pub(super) fn new_root() -> (AppRoot, Rig) {
    let dir = crate::test_rig::unique_dir("sq-menu-click-root");
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
    let mut rig = Rig::new(demo_session(Scenario::Plain));
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    root.shell.shell().focus = Some(PanelID::Timeline);
    root.dock.set_focused(Some(PanelID::Timeline));
    // Selecting every clip enables the Clip menu's audio rows the way a user would.
    let all: std::collections::BTreeSet<_> = rig
        .session
        .active_timeline()
        .map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect())
        .unwrap_or_default();
    rig.session.select(all, std::collections::BTreeSet::new());
    root.sync(&rig.session);
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    (root, rig)
}

pub(super) fn send(root: &mut AppRoot, rig: &mut Rig, e: InputEvent) -> bool {
    let taken = root.handle(&e, &mut rig.cx());
    root.sync(&rig.session);
    root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
    taken
}

pub(super) fn click(root: &mut AppRoot, rig: &mut Rig, p: CGPoint) {
    let (x, y) = (p.x as f32, p.y as f32);
    send(root, rig, InputEvent::MouseMoved { x, y });
    send(root, rig, InputEvent::MouseDown { x, y, modifiers: NONE });
    send(root, rig, InputEvent::MouseUp { x, y });
}

/// The center of row `row` of the open level `level` (window points, scale 1).
pub(super) fn row_center(root: &mut AppRoot, level: usize, row: usize) -> CGPoint {
    let v = &root.shell.shell().menu_bar.controller.views()[level];
    let r = v.row_frames[row];
    CGPoint::new(v.origin.x + r.mid_x(), v.origin.y + r.mid_y() - v.scroll_offset)
}

fn position(items: &[SQMenuItem], title: &str) -> usize {
    items.iter().position(|i| i.title == title).unwrap_or_else(|| panic!("no row {title:?}"))
}

/// Clicks `Clip` then every title of `path` but the last in the open levels; returns the point of the last row.
pub(super) fn open_down_to(root: &mut AppRoot, rig: &mut Rig, menu: &str, path: &[&str]) -> CGPoint {
    let bar = &root.shell.shell().menu_bar;
    let i = bar.menus().iter().position(|m| m.title == menu).expect("menu");
    let title = bar.title_frames()[i];
    click(root, rig, CGPoint::new(title.mid_x(), title.mid_y()));
    assert!(root.shell.shell().menu_bar.controller.is_open(), "the click on {menu} opens it");
    let mut level = 0;
    for (n, name) in path.iter().enumerate() {
        let items = root.shell.shell().menu_bar.controller.views()[level].items.clone();
        let row = position(&items, name);
        let at = row_center(root, level, row);
        if n + 1 == path.len() {
            return at;
        }
        click(root, rig, at);
        level += 1;
        assert_eq!(root.shell.shell().menu_bar.controller.depth(), level + 1, "{name} opened its submenu");
    }
    unreachable!("path is not empty")
}

/// What a row's run left behind that a test can see.
fn trace(root: &mut AppRoot, rig: &mut Rig) -> String {
    format!("{}|{}|{:?}", root.shell.shell().dialog().is_some(), rig.events.len(), root.shell.take_deferred().len())
}

#[test]
fn a_click_on_a_third_level_row_runs_it_through_the_root() {
    for (menu, path) in [
        ("Clip", ["Audio Options", "Voice", "Voiceover from Text…"]),
        ("Clip", ["Audio Options", "Loudness and Ducking", "Match Loudness"]),
    ] {
        let (mut root, mut rig) = new_root();
        let before = trace(&mut root, &mut rig);
        let at = open_down_to(&mut root, &mut rig, menu, &path);
        assert_eq!(root.shell.shell().menu_bar.controller.depth(), 3, "{path:?} sits on the third level");
        click(&mut root, &mut rig, at);
        assert!(!root.shell.shell().menu_bar.controller.is_open(), "{path:?} closed the menu");
        assert_ne!(trace(&mut root, &mut rig), before, "{path:?} ran");
    }
}

#[test]
fn enter_as_the_first_key_after_opening_with_the_mouse_runs_the_highlighted_row() {
    // Whichever panel holds the keyboard focus, the open menu gets the key first.
    for focus in
        [PanelID::Timeline, PanelID::Library, PanelID::Project, PanelID::ProgramMonitor, PanelID::EffectControls]
    {
        let (mut root, mut rig) = new_root();
        let before = trace(&mut root, &mut rig);
        let at =
            open_down_to(&mut root, &mut rig, "Clip", &["Audio Options", "Loudness and Ducking", "Match Loudness"]);
        root.dock.set_focused(Some(focus));
        // The pointer rests on the row: it is the highlighted one.
        send(&mut root, &mut rig, InputEvent::MouseMoved { x: at.x as f32, y: at.y as f32 });
        send(&mut root, &mut rig, InputEvent::KeyDown { key: InputKey::Enter, modifiers: NONE });
        assert!(!root.shell.shell().menu_bar.controller.is_open(), "Enter closed the menu with {focus:?} focused");
        assert_ne!(trace(&mut root, &mut rig), before, "the highlighted row ran with {focus:?} focused");
    }
}

/// Clip > Arrange > Save as Template…: the name typed in its dialog saves a title template in the Library (shown under
/// Titles) and never makes a sequence (a Linux check once saw a sequence named like the template; Sequence > Save Sequence
/// as Template… is the other, separate item).
#[test]
fn save_as_template_from_the_clip_menu_saves_a_title_template_and_no_sequence() {
    use sq_core_color::ColorMatteColor;
    use sq_core_time::Time;
    use sq_library::preset_store::PresetKind;
    let (mut root, mut rig) = new_root();
    let matte = rig
        .session
        .add_color_matte(ColorMatteColor::DEFAULT, "Bar", Some(Time::seconds(4)), None, Time::seconds(2))
        .expect("matte");
    rig.session.select(std::collections::BTreeSet::from([matte]), std::collections::BTreeSet::new());
    send(&mut root, &mut rig, InputEvent::MouseMoved { x: 1.0, y: 1.0 });
    let sequences = rig.session.project().timelines.len();
    let at = open_down_to(&mut root, &mut rig, "Clip", &["Arrange", "Save as Template"]);
    click(&mut root, &mut rig, at);
    root.answer(&mut rig.cx());
    assert!(root.has_dialog(), "the name dialog is up");
    let key = |k| InputEvent::KeyDown { key: k, modifiers: NONE };
    for _ in 0.."Bar".len() {
        send(&mut root, &mut rig, key(InputKey::Backspace));
    }
    for c in "My Tpl".chars() {
        send(&mut root, &mut rig, key(InputKey::Character(c)));
    }
    send(&mut root, &mut rig, key(InputKey::Enter));
    assert!(!root.has_dialog(), "Return answers the dialog");
    root.answer(&mut rig.cx());
    assert_eq!(rig.session.project().timelines.len(), sequences, "no sequence was made");
    let saved: Vec<(PresetKind, String)> =
        root.library.panel_host().panel.model.presets().iter().map(|p| (p.kind, p.name.clone())).collect();
    assert!(saved.contains(&(PresetKind::TitleTemplate, "My Tpl".to_string())), "saved presets: {saved:?}");
}
