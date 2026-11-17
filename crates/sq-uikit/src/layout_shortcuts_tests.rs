//! "A shown shortcut can be typed on the layout it is shown for": every key the default map shows on a PC is pressed the
//! way each layout presses it (US, UK, German QWERTZ, French AZERTY), through the same key rule the window uses
//! (`layout_keys::chords` + `choose`), and must run the command of the row. A binding no key of the layout reaches shows no key.

use crate::command_map::{CommandMap, Entry};
use crate::key_binding::{Key, KeyBinding, KeyModifiers};
use crate::key_binding_text::{KeyBindingText, WindowsKeyRoute};
use crate::layout_keys;
use sq_os::Platform;
use sq_os::keyboard::ActiveKeyboard;

const POSITIONS: &str = "1234567890-=qwertyuiop[]asdfghjkl;'`\\zxcvbnm,./<";

fn layouts() -> Vec<(&'static str, Option<ActiveKeyboard>)> {
    vec![
        ("us", None),
        ("gb", Some(ActiveKeyboard::from_id("gb"))),
        ("de", Some(ActiveKeyboard::from_id("de"))),
        ("fr", Some(ActiveKeyboard::from_id("fr"))),
    ]
}

/// What a key of `layout` types: (plain, shifted).
fn typed_at(layout: Option<&ActiveKeyboard>, position: char) -> (Option<char>, Option<char>) {
    match layout {
        Some(l) => l.probes.iter().find(|p| p.position == position).map_or((None, None), |p| (p.plain, p.shifted)),
        None => (Some(position), None),
    }
}

/// The press a shown label asks for: modifiers and the key whose cap carries the label's name.
struct Label {
    ctrl: bool,
    alt: bool,
    shift: bool,
    position: char,
}

fn read_label(text: &str, layout: Option<&ActiveKeyboard>) -> Option<Label> {
    let mut rest = text;
    let (mut ctrl, mut alt, mut shift) = (false, false, false);
    loop {
        if let Some(r) = rest.strip_prefix("Ctrl+") {
            (ctrl, rest) = (true, r);
        } else if let Some(r) = rest.strip_prefix("Alt+") {
            (alt, rest) = (true, r);
        } else if let Some(r) = rest.strip_prefix("Shift+") {
            (shift, rest) = (true, r);
        } else {
            break;
        }
    }
    let position = POSITIONS.chars().find(|&p| KeyBindingText::cap_name(layout_keys::cap(layout, p)) == rest)?;
    Some(Label { ctrl, alt, shift, position })
}

/// Every pressable entry with a character key, on `layout`: the ones no key reaches (they show no key) and the ones whose
/// shown label, pressed as a user does, runs something else.
fn audit(layout: Option<&ActiveKeyboard>, map: &CommandMap) -> (Vec<String>, Vec<String>) {
    let (mut unreachable, mut wrong) = (Vec::new(), Vec::new());
    let entries = map
        .entries
        .iter()
        .filter(|e| matches!(e.binding.key, Key::Char(_)) && map.is_pressable_with(e, Platform::Windows, None));
    for e in entries {
        let name = format!("{:?} {}", e.scope, KeyBindingText::windows(&e.binding));
        if !map.is_pressable_with(e, Platform::Windows, layout) {
            unreachable.push(name);
            continue;
        }
        let text = KeyBindingText::windows_on(&e.binding, layout, map);
        let Some(l) = read_label(&text, layout) else {
            wrong.push(format!("{name}: label {text:?} names no key"));
            continue;
        };
        let (plain, shifted) = typed_at(layout, l.position);
        let cs = layout_keys::chords(plain, shifted, Some(l.position), l.shift);
        let binds = |c: char, s: bool| map.binds_press(Key::Char(layout_keys::map_char(c)), l.ctrl, l.alt, s);
        let Some((c, s)) = layout_keys::choose(&cs, &binds) else {
            wrong.push(format!("{name}: {text:?} types nothing"));
            continue;
        };
        let runs = |e: &Entry| {
            e.scope.foci().into_iter().all(|focus| {
                let key = Key::Char(layout_keys::map_char(c));
                WindowsKeyRoute::command(key, l.ctrl, l.alt, s, focus, map) == Some(e.command)
            })
        };
        if !runs(e) {
            wrong.push(format!("{name}: {text:?} runs something else"));
        }
    }
    (unreachable, wrong)
}

#[test]
fn every_shown_shortcut_runs_its_command_on_every_layout() {
    for platform in [Platform::Windows, Platform::Linux] {
        let map = CommandMap::sq_default_for(platform);
        for (id, layout) in layouts() {
            let (_, wrong) = audit(layout.as_ref(), &map);
            assert!(wrong.is_empty(), "{platform:?} {id}: {wrong:#?}");
        }
    }
}

/// The shared keys of a layout: two bindings that want the same key there, so one of them has no key (and shows none).
/// German: the `+` key is Zoom In, so every `]` binding has no key (AltGr+9 is text), and Shift+7 is the Shift+7 binding, so
/// the plain `/` has none (Ctrl+/ is Ctrl+Shift+7). French: the digit 4 and 6 keys type `'` and `-` (Extract, Zoom Out), and
/// Shift+`:` types `/`, so Place on Top (Shift+.) has none.
fn known_gaps(id: &str) -> &'static [&'static str] {
    match id {
        "de" => &[
            "Global /",
            "Timeline ]",
            "Timeline Shift+]",
            "Timeline Alt+]",
            "Program Alt+]",
            "Timeline Ctrl+Alt+]",
            "Project Ctrl+]",
        ],
        "fr" => &[
            "Timeline 4",
            "Program 4",
            "Timeline 6",
            "Program 6",
            "Global Shift+6",
            "Global Shift+.",
            "Global Ctrl+Shift+.",
            "Timeline Ctrl+6",
            "Timeline Ctrl+Alt+6",
        ],
        _ => &[],
    }
}

#[test]
fn the_keys_each_layout_cannot_type_are_the_known_ones() {
    let map = CommandMap::sq_default_for(Platform::Windows);
    for (id, layout) in layouts() {
        let (unreachable, _) = audit(layout.as_ref(), &map);
        assert_eq!(unreachable, known_gaps(id), "{id}");
    }
}

#[test]
fn the_three_reported_keys_on_a_german_keyboard() {
    let map = CommandMap::sq_default_for(Platform::Windows);
    let de = ActiveKeyboard::from_id("de");
    let text =
        |c: char, m: KeyModifiers| KeyBindingText::windows_on(&KeyBinding::new(Key::Char(c), m), Some(&de), &map);
    assert_eq!(text('/', KeyModifiers::COMMAND), "Ctrl+Shift+7", "New Folder");
    assert_eq!(text('/', KeyModifiers::COMMAND | KeyModifiers::SHIFT), "Ctrl+Shift+-", "Duplicate");
    assert_eq!(text('`', KeyModifiers::EMPTY), "^", "Maximize Panel");
}
