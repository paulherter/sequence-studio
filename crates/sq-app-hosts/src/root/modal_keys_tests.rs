//! The keyboard rule through the real root: while any palette, popup, sheet or menu is open it owns the keyboard, so typed
//! letters, Ctrl+A, Backspace and Delete never reach the timeline (a Ctrl+A and Backspace behind Quick Apply once deleted
//! every clip).

use super::menu_click_tests::{click, new_root, open_down_to, send};
use super::*;

const NONE: InputModifiers = InputModifiers::NONE;

/// What an editor shortcut would change: the clips, the selection, the tool and the snapping switch.
fn fingerprint(root: &mut AppRoot, rig: &crate::test_rig::Rig) -> String {
    let clips: usize = rig.session.active_timeline().map_or(0, |t| t.tracks.iter().map(|k| k.clips().len()).sum());
    let tool = root.timeline.inner().panel.tool_state();
    format!(
        "{clips} clips, {} selected, {:?}, snapping {}, can_undo {}",
        rig.session.selection().len(),
        tool.tool,
        tool.snapping,
        rig.session.can_undo()
    )
}

/// The Quick Apply chord of this system as the window reports it (Option on the Mac, Ctrl elsewhere).
fn quick_apply_chord() -> InputEvent {
    let m =
        if sq_os::Platform::current().command_is_cmd_key() { InputModifiers::OPTION } else { InputModifiers::COMMAND };
    InputEvent::KeyDown { key: InputKey::Space, modifiers: m }
}

fn key(root: &mut AppRoot, rig: &mut crate::test_rig::Rig, k: InputKey, m: InputModifiers, text: Option<&str>) {
    rig.ui.typed_text = text.map(str::to_string);
    send(root, rig, InputEvent::KeyDown { key: k, modifiers: m });
    rig.ui.typed_text = None;
}

type Opener = fn(&mut AppRoot, &mut crate::test_rig::Rig);

fn open_menu(root: &mut AppRoot, rig: &mut crate::test_rig::Rig) {
    let bar = &root.shell.shell().menu_bar;
    let i = bar.menus().iter().position(|m| m.title == "Edit").expect("Edit menu");
    let title = bar.title_frames()[i];
    click(root, rig, CGPoint::new(title.mid_x(), title.mid_y()));
}

fn open_chord(k: InputKey, m: InputModifiers) -> impl Fn(&mut AppRoot, &mut crate::test_rig::Rig) {
    move |root, rig| key(root, rig, k, m, None)
}

/// Every surface that owns the keyboard, with the way a user opens it.
type OpenFn = Box<dyn Fn(&mut AppRoot, &mut crate::test_rig::Rig)>;

fn surfaces() -> Vec<(&'static str, OpenFn)> {
    let c = |ch: char| InputKey::Character(ch);
    vec![
        (
            "quick apply by its key",
            Box::new(|r, g| {
                send(r, g, quick_apply_chord());
            }),
        ),
        (
            "quick apply from the Window menu",
            Box::new(|r, g| {
                let at = open_down_to(r, g, "Window", &["Quick Apply\u{2026}"]);
                click(r, g, at);
            }),
        ),
        ("an open menu", Box::new(open_menu as Opener)),
        ("settings", Box::new(open_chord(c(','), InputModifiers::COMMAND))),
        ("the shortcuts page", Box::new(open_chord(c('k'), InputModifiers::COMMAND | InputModifiers::OPTION))),
        ("a dialog", Box::new(|r, _| r.show_dialog(ShellDialog::new("Match Loudness", "Done")))),
    ]
}

#[test]
fn no_surface_that_owns_the_keyboard_lets_a_key_reach_the_timeline() {
    let mut tested = Vec::new();
    for (name, open) in surfaces() {
        let (mut root, mut rig) = new_root();
        let before = fingerprint(&mut root, &rig);
        open(&mut root, &mut rig);
        // shortcut: Settings and the shortcuts page need the app's preference services, which the test rig lacks; the
        // surfaces that did not open here are reported, not tested, and the list below pins the ones that must.
        if !(root.shell.owns_keyboard() || root.has_dialog()) {
            sq_os::errln!("not opened in the test rig: {name}");
            continue;
        }
        tested.push(name);
        for (k, m, text) in [
            (InputKey::Character('v'), NONE, Some("v")),
            (InputKey::Character('h'), NONE, Some("h")),
            (InputKey::Character('s'), NONE, Some("s")),
            (InputKey::Character('a'), InputModifiers::COMMAND, None),
            (InputKey::Backspace, NONE, None),
            (InputKey::Delete, NONE, None),
            (InputKey::Delete, InputModifiers::SHIFT, None),
            (InputKey::Minus, NONE, Some("-")),
            (InputKey::Space, NONE, Some(" ")),
        ] {
            key(&mut root, &mut rig, k, m, text);
            assert_eq!(fingerprint(&mut root, &rig), before, "{name}: {k:?} {m:?} changed the editor");
        }
    }
    for must in ["quick apply by its key", "quick apply from the Window menu", "an open menu", "a dialog"] {
        assert!(tested.contains(&must), "{must} was tested, got {tested:?}");
    }
}

/// Esc closes Quick Apply and a click outside closes it; neither leaves it half open.
#[test]
fn quick_apply_closes_on_escape_and_on_a_click_outside() {
    let (mut root, mut rig) = new_root();
    send(&mut root, &mut rig, quick_apply_chord());
    assert!(root.shell.shell().quick_apply_open());
    key(&mut root, &mut rig, InputKey::Escape, NONE, None);
    assert!(!root.shell.shell().quick_apply_open(), "Esc closes it");
    send(&mut root, &mut rig, quick_apply_chord());
    assert!(root.shell.shell().quick_apply_open());
    click(&mut root, &mut rig, CGPoint::new(5.0, 890.0));
    assert!(!root.shell.shell().quick_apply_open(), "a click outside closes it");
    send(&mut root, &mut rig, quick_apply_chord());
    send(&mut root, &mut rig, quick_apply_chord());
    assert!(!root.shell.shell().quick_apply_open(), "its own key closes it again");
}

/// Letters typed into Quick Apply land in its field and narrow the list.
#[test]
fn typing_into_quick_apply_fills_its_field() {
    let (mut root, mut rig) = new_root();
    send(&mut root, &mut rig, quick_apply_chord());
    for ch in "vhs".chars() {
        key(&mut root, &mut rig, InputKey::Character(ch), NONE, Some(&ch.to_string()));
    }
    assert_eq!(root.shell.shell().quick_apply_query(), Some("vhs"));
}
