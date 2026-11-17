// Swift: KeyBindingText.swift
//! The text of a key binding, per system, and how a Windows key press finds its binding in the one key map.

use crate::command_map::{CommandMap, Entry};
use crate::editor_command::{CommandScope, EditorCommand};
use crate::key_binding::{Key, KeyBinding, KeyModifiers};
use crate::layout_keys;
use crate::panel_id::PanelID;
use sq_core_time::text::graphemes;
use sq_os::keyboard::ActiveKeyboard;
use sq_os::{KeyTextStyle, Platform};
use std::collections::HashSet;

/// The text of a key binding: "⇧⌘K" on the Mac, "Ctrl+Shift+K" on Windows and Linux (the Command key is Ctrl there,
/// DECISIONS "Windows key map").
pub enum KeyBindingText {}

impl KeyBindingText {
    /// The shortcut hint of Command + `key` as `platform` writes it ("\u{2318}C" on the Mac, "Ctrl+C" elsewhere): what a
    /// menu row shows. Menus never spell the glyph themselves.
    pub fn command_hint(key: char, platform: Platform) -> String {
        Self::text(&KeyBinding::new(Key::Char(key.to_ascii_lowercase()), KeyModifiers::COMMAND), platform)
    }

    /// [`KeyBindingText::command_hint`] on the system the app runs on.
    pub fn command_hint_here(key: char) -> String {
        Self::command_hint(key, Platform::current())
    }

    /// The shortcut hint of the Delete key (the Backspace key on a PC) on the system the app runs on, for a menu row.
    pub fn delete_hint_here() -> String {
        Self::text(&KeyBinding::new(Key::Delete, KeyModifiers::EMPTY), Platform::current())
    }

    /// The text for `platform`.
    pub fn text(b: &KeyBinding, platform: Platform) -> String {
        match platform.key_text_style() {
            KeyTextStyle::Symbols => Self::mac(b),
            KeyTextStyle::Words => Self::windows(b),
        }
    }

    /// "⇧⌘K" style text of a binding, for menu hints of keys that are not real key equivalents.
    pub fn mac(b: &KeyBinding) -> String {
        let mut s = String::new();
        if b.modifiers.contains(KeyModifiers::CONTROL) {
            s += "⌃";
        }
        if b.modifiers.contains(KeyModifiers::OPTION) {
            s += "⌥";
        }
        if b.modifiers.contains(KeyModifiers::SHIFT) {
            s += "⇧";
        }
        if b.modifiers.contains(KeyModifiers::COMMAND) {
            s += "⌘";
        }
        match b.key {
            Key::Char(c) => s.extend(c.to_uppercase()),
            Key::Space => s += "Space",
            Key::Left => s += "←",
            Key::Right => s += "→",
            Key::Up => s += "↑",
            Key::Down => s += "↓",
            Key::Home => s += "↖",
            Key::End => s += "↘",
            Key::PageUp => s += "⇞",
            Key::PageDown => s += "⇟",
            Key::Delete => s += "⌫",
            Key::ReturnKey => s += "↩",
            Key::ForwardDelete => s += "⌦",
            Key::Function(n) => s += &format!("F{n}"),
        }
        s
    }

    /// The binding of a `mac` text ("⇧⌘K" -> K with Shift and Command); `None` for any other text. The Mac system
    /// menu bar reads the shared menu rows' shortcut texts back into key equivalents with it.
    pub fn parse_mac(text: &str) -> Option<KeyBinding> {
        let mut m = KeyModifiers::EMPTY;
        let marks = [
            ('⌃', KeyModifiers::CONTROL),
            ('⌥', KeyModifiers::OPTION),
            ('⇧', KeyModifiers::SHIFT),
            ('⌘', KeyModifiers::COMMAND),
        ];
        let mut rest = text;
        while let Some((first, tail)) = rest.chars().next().map(|c| (c, &rest[c.len_utf8()..])) {
            let Some(&(_, modifier)) = marks.iter().find(|(c, _)| *c == first) else { break };
            m |= modifier;
            rest = tail;
        }
        let named = [
            ("Space", Key::Space),
            // The dock's tab menu still spells its key out.
            ("Backtick", Key::Char('`')),
            ("←", Key::Left),
            ("→", Key::Right),
            ("↑", Key::Up),
            ("↓", Key::Down),
            ("↖", Key::Home),
            ("↘", Key::End),
            ("⇞", Key::PageUp),
            ("⇟", Key::PageDown),
            ("⌫", Key::Delete),
            ("↩", Key::ReturnKey),
            ("⌦", Key::ForwardDelete),
        ];
        if let Some(&(_, key)) = named.iter().find(|(n, _)| *n == rest) {
            return Some(KeyBinding::new(key, m));
        }
        let count = graphemes(rest).count();
        if let Some(n) = rest.strip_prefix('F').filter(|_| count > 1).and_then(|r| r.parse::<i64>().ok()) {
            return Some(KeyBinding::new(Key::Function(n), m));
        }
        if count != 1 {
            return None;
        }
        let c = rest.to_lowercase().chars().next()?;
        Some(KeyBinding::new(Key::Char(c), m))
    }

    /// The binding of a `windows` text ("Ctrl+Shift+K" -> K with Command and Shift); `None` for any other text. Ctrl reads
    /// as Command: the text cannot tell it from the Mac Control modifier, and a Ctrl press reaches the Command binding first.
    pub fn parse_windows(text: &str) -> Option<KeyBinding> {
        let mut m = KeyModifiers::EMPTY;
        let mut rest = text;
        while let Some((word, tail)) = rest.split_once('+').filter(|(w, _)| !w.is_empty()) {
            m |= match word {
                "Ctrl" => KeyModifiers::COMMAND,
                "Alt" => KeyModifiers::OPTION,
                "Shift" => KeyModifiers::SHIFT,
                _ => break,
            };
            rest = tail;
        }
        let named = [
            ("Space", Key::Space),
            ("Backtick", Key::Char('`')),
            ("Left", Key::Left),
            ("Right", Key::Right),
            ("Up", Key::Up),
            ("Down", Key::Down),
            ("Home", Key::Home),
            ("End", Key::End),
            ("PgUp", Key::PageUp),
            ("PgDn", Key::PageDown),
            ("Backspace", Key::Delete),
            ("Enter", Key::ReturnKey),
            ("Del", Key::ForwardDelete),
        ];
        if let Some(&(_, key)) = named.iter().find(|(n, _)| *n == rest) {
            return Some(KeyBinding::new(key, m));
        }
        let count = graphemes(rest).count();
        if let Some(n) = rest.strip_prefix('F').filter(|_| count > 1).and_then(|r| r.parse::<i64>().ok()) {
            return Some(KeyBinding::new(Key::Function(n), m));
        }
        if count != 1 {
            return None;
        }
        Some(KeyBinding::new(Key::Char(rest.to_lowercase().chars().next()?), m))
    }

    /// The binding a shown shortcut text stands for on `platform` (Mac glyphs or Windows and Linux words); `None` for text
    /// that names no key.
    pub fn parse(text: &str, platform: Platform) -> Option<KeyBinding> {
        match platform.key_text_style() {
            KeyTextStyle::Symbols => Self::parse_mac(text),
            KeyTextStyle::Words => Self::parse_windows(text),
        }
    }

    /// Windows order and names: Ctrl+Alt+Shift+Key, the key as the keyboard layout in use shows it (`layout_keys`).
    pub fn windows(b: &KeyBinding) -> String {
        let layout = sq_os::keyboard::active();
        CommandMap::with_current(|map| Self::windows_on(b, layout.as_deref(), map))
    }

    /// [`KeyBindingText::windows`] on a given layout (`None`: the US keyboard) and key map. A character key is named by the
    /// key that types it there, with the Shift that typing needs: Ctrl+/ is "Ctrl+Shift+7" on a German keyboard. A binding no
    /// key reaches keeps its US name.
    pub fn windows_on(b: &KeyBinding, layout: Option<&ActiveKeyboard>, map: &CommandMap) -> String {
        let m = b.modifiers;
        let (ctrl, alt) =
            (m.contains(KeyModifiers::COMMAND) || m.contains(KeyModifiers::CONTROL), m.contains(KeyModifiers::OPTION));
        let typed = match b.key {
            Key::Char(c) => {
                let binds =
                    |c: char, shift: bool| map.binds_press(Key::Char(layout_keys::map_char(c)), ctrl, alt, shift);
                layout_keys::typing(layout, c, m.contains(KeyModifiers::SHIFT), &binds)
            }
            _ => None,
        };
        let mut parts: Vec<String> = Vec::new();
        if ctrl {
            parts.push("Ctrl".to_string());
        }
        if alt {
            parts.push("Alt".to_string());
        }
        if typed.map_or(m.contains(KeyModifiers::SHIFT), |t| t.shift) {
            parts.push("Shift".to_string());
        }
        let key = match (b.key, typed) {
            (Key::Char(_), Some(t)) => Self::cap_name(layout_keys::cap(layout, t.position)),
            (Key::Char(c), None) => Self::cap_name(c),
            (Key::Space, _) => "Space".to_string(),
            (Key::Left, _) => "Left".to_string(),
            (Key::Right, _) => "Right".to_string(),
            (Key::Up, _) => "Up".to_string(),
            (Key::Down, _) => "Down".to_string(),
            (Key::Home, _) => "Home".to_string(),
            (Key::End, _) => "End".to_string(),
            (Key::PageUp, _) => "PgUp".to_string(),
            (Key::PageDown, _) => "PgDn".to_string(),
            (Key::Delete, _) => "Backspace".to_string(),
            (Key::ReturnKey, _) => "Enter".to_string(),
            (Key::ForwardDelete, _) => "Del".to_string(),
            (Key::Function(n), _) => format!("F{n}"),
        };
        parts.push(key);
        parts.join("+")
    }

    /// The name of a key cap on a PC: the letter in upper case, the grave key spelled out ("Ctrl+`" reads like a typo).
    pub(crate) fn cap_name(c: char) -> String {
        match c {
            'ß' => "ß".to_string(),
            '`' => "Backtick".to_string(),
            c => c.to_uppercase().collect(),
        }
    }
}

/// How a Windows key press finds its binding in the one key map. Windows has Ctrl, Alt, Shift (the Windows key belongs to
/// the system), the Mac has Command, Option, Shift and Control. Ctrl stands for Command first and for the Mac Control
/// modifier second; Ctrl+Alt also reaches Control+Command bindings last. Backspace and Del both delete like the Mac Delete
/// key unless the map binds Forward Delete itself (the Mac rule of `KeyMapping.keyEvent`).
pub enum WindowsKeyRoute {}

impl WindowsKeyRoute {
    /// Windows modifiers in Mac terms: `COMMAND` = Ctrl, `OPTION` = Alt, `SHIFT` = Shift (what the host reports).
    pub fn candidates(key: Key, ctrl: bool, alt: bool, shift: bool) -> Vec<KeyBinding> {
        let mut base = KeyModifiers::EMPTY;
        if alt {
            base |= KeyModifiers::OPTION;
        }
        if shift {
            base |= KeyModifiers::SHIFT;
        }
        if !ctrl {
            return vec![KeyBinding::new(key, base)];
        }
        vec![
            KeyBinding::new(key, base | KeyModifiers::COMMAND),
            KeyBinding::new(key, base | KeyModifiers::CONTROL),
            KeyBinding::new(key, base | KeyModifiers::COMMAND | KeyModifiers::CONTROL),
        ]
    }

    /// The command a Windows key press runs in `focus`, or `None`. Focus-scoped bindings win over global ones per candidate.
    pub fn command(
        key: Key,
        ctrl: bool,
        alt: bool,
        shift: bool,
        focus: Option<PanelID>,
        map: &CommandMap,
    ) -> Option<EditorCommand> {
        let mut k = key;
        if k == Key::ForwardDelete && !map.entries.iter().any(|e| e.binding.key == Key::ForwardDelete) {
            k = Key::Delete;
        }
        Self::candidates(k, ctrl, alt, shift).into_iter().find_map(|b| map.command_for(&b, focus))
    }

    /// Bindings a Windows keyboard cannot reach: a Control binding whose Ctrl twin (same key, Command instead of Control) is
    /// bound in the same scope or globally. They stay reachable from the menus and Quick Apply.
    pub fn shadowed(map: &CommandMap) -> Vec<Entry> {
        let keys: HashSet<(CommandScope, KeyBinding)> = map.entries.iter().map(|e| (e.scope, e.binding)).collect();
        let bound = |scope: CommandScope, b: KeyBinding| {
            keys.contains(&(scope, b)) || keys.contains(&(CommandScope::Global, b))
        };
        let without = |m: KeyModifiers, drop: KeyModifiers| KeyModifiers(m.0 & !drop.0);
        map.entries
            .iter()
            .filter(|e| {
                let m = e.binding.modifiers;
                if !m.contains(KeyModifiers::CONTROL) {
                    return false;
                }
                if m.contains(KeyModifiers::COMMAND) {
                    // Control+Command: reached only when neither Ctrl twin is bound.
                    let a = without(m, KeyModifiers::CONTROL);
                    let c = without(m, KeyModifiers::COMMAND);
                    return bound(e.scope, KeyBinding::new(e.binding.key, a))
                        || bound(e.scope, KeyBinding::new(e.binding.key, c));
                }
                let twin = without(m, KeyModifiers::CONTROL) | KeyModifiers::COMMAND;
                bound(e.scope, KeyBinding::new(e.binding.key, twin))
            })
            .copied()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CMD: KeyModifiers = KeyModifiers::COMMAND;
    const SHIFT: KeyModifiers = KeyModifiers::SHIFT;
    const OPT: KeyModifiers = KeyModifiers::OPTION;
    const CTRL: KeyModifiers = KeyModifiers::CONTROL;
    const NONE: KeyModifiers = KeyModifiers::EMPTY;

    fn kb(key: Key, m: KeyModifiers) -> KeyBinding {
        KeyBinding::new(key, m)
    }

    #[test]
    fn mac_text_round_trips() {
        let samples = [
            kb(Key::Char('s'), CMD),
            kb(Key::Char('v'), SHIFT | CMD),
            kb(Key::Char('c'), NONE),
            kb(Key::Char('k'), CTRL | OPT | SHIFT | CMD),
            kb(Key::Space, NONE),
            kb(Key::Left, OPT),
            kb(Key::Delete, CMD),
            kb(Key::ReturnKey, NONE),
            kb(Key::ForwardDelete, NONE),
            kb(Key::Function(5), NONE),
            kb(Key::Function(12), SHIFT),
            kb(Key::Home, NONE),
            kb(Key::PageDown, SHIFT),
            kb(Key::Char('='), NONE),
            kb(Key::Char(','), CMD),
        ];
        for b in samples {
            assert_eq!(KeyBindingText::parse_mac(&KeyBindingText::mac(&b)), Some(b), "{}", KeyBindingText::mac(&b));
        }
    }

    /// Every binding of the shipped key maps reads back from the text each system shows for it (Ctrl as Command on Windows).
    #[test]
    fn every_shown_text_of_the_default_maps_parses_back() {
        for platform in [Platform::Mac, Platform::Windows, Platform::Linux] {
            for e in CommandMap::sq_default_for(platform).entries {
                let text = KeyBindingText::text(&e.binding, platform);
                let back = KeyBindingText::parse(&text, platform).unwrap_or_else(|| panic!("{platform:?}: {text:?}"));
                let mut want = e.binding;
                if platform.key_text_style() == KeyTextStyle::Words && want.modifiers.contains(KeyModifiers::CONTROL) {
                    want.modifiers = KeyModifiers(want.modifiers.0 & !KeyModifiers::CONTROL.0) | KeyModifiers::COMMAND;
                }
                assert_eq!(back, want, "{platform:?}: {text:?}");
            }
        }
    }

    #[test]
    fn empty_or_unknown_text_is_none() {
        assert_eq!(KeyBindingText::parse_mac(""), None);
        assert_eq!(KeyBindingText::parse_mac("⌘"), None);
        assert_eq!(KeyBindingText::parse_mac("Ctrl+S"), None);
    }

    #[test]
    fn windows_text_uses_ctrl_alt_shift_order() {
        let w = |b: KeyBinding| KeyBindingText::windows(&b);
        assert_eq!(w(kb(Key::Char('s'), CMD)), "Ctrl+S");
        assert_eq!(w(kb(Key::Char('k'), CMD | SHIFT)), "Ctrl+Shift+K");
        assert_eq!(w(kb(Key::Char('m'), CTRL | OPT)), "Ctrl+Alt+M");
        assert_eq!(w(kb(Key::Delete, NONE)), "Backspace");
        assert_eq!(w(kb(Key::ForwardDelete, NONE)), "Del");
        assert_eq!(w(kb(Key::PageDown, SHIFT)), "Shift+PgDn");
        assert_eq!(w(kb(Key::Function(5), NONE)), "F5");
        assert_eq!(w(kb(Key::Char('ß'), NONE)), "ß");
    }

    #[test]
    fn mac_text_keeps_the_menu_glyphs() {
        assert_eq!(KeyBindingText::mac(&kb(Key::Char('k'), CMD | SHIFT)), "⇧⌘K");
        assert_eq!(KeyBindingText::mac(&kb(Key::Delete, CTRL)), "⌃⌫");
        assert_eq!(KeyBindingText::text(&kb(Key::Char('s'), CMD), Platform::Windows), "Ctrl+S");
    }

    #[test]
    fn text_per_system_linux_names_ctrl_not_the_command_glyph() {
        let b = kb(Key::Char('k'), CMD | KeyModifiers::SHIFT);
        assert_eq!(KeyBindingText::text(&b, Platform::Mac), "⇧⌘K");
        assert_eq!(KeyBindingText::text(&b, Platform::Windows), "Ctrl+Shift+K");
        assert_eq!(KeyBindingText::text(&b, Platform::Linux), "Ctrl+Shift+K");
    }

    #[test]
    fn the_grave_key_is_named_and_parses_back() {
        let b = kb(Key::Char('`'), KeyModifiers::EMPTY);
        assert_eq!(KeyBindingText::text(&b, Platform::Windows), "Backtick");
        assert_eq!(KeyBindingText::text(&b, Platform::Mac), "`");
        assert_eq!(KeyBindingText::parse_mac("`"), Some(b));
        assert_eq!(KeyBindingText::parse_mac("Backtick"), Some(b));
        let shifted = kb(Key::Char('`'), KeyModifiers::SHIFT);
        assert_eq!(KeyBindingText::text(&shifted, Platform::Linux), "Shift+Backtick");
    }

    #[test]
    fn mac_text_uses_the_glyphs_the_mac_menu_shows_and_parses_back() {
        for (key, glyph) in [(Key::Home, "↖"), (Key::End, "↘"), (Key::PageUp, "⇞"), (Key::PageDown, "⇟")] {
            let b = kb(key, CMD);
            assert_eq!(KeyBindingText::mac(&b), format!("⌘{glyph}"));
            assert_eq!(KeyBindingText::parse_mac(&format!("⌘{glyph}")), Some(b));
        }
        assert_eq!(KeyBindingText::mac(&kb(Key::Space, KeyModifiers::EMPTY)), "Space");
        assert_eq!(KeyBindingText::mac(&kb(Key::Function(9), KeyModifiers::EMPTY)), "F9");
    }

    #[test]
    fn ctrl_reaches_command_first_then_control() {
        let map = CommandMap::premiere_default_for(Platform::Windows);
        let route = |key, ctrl, focus| WindowsKeyRoute::command(key, ctrl, false, false, focus, &map);
        assert_eq!(route(Key::Char('s'), true, None), Some(EditorCommand::Save));
        // Windows binds Quick Apply to Ctrl+Space (Alt+Space is the system menu), so the Command binding wins over the
        // Mac Control binding (Play to Out) that sits on the same key.
        assert_eq!(route(Key::Space, true, None), Some(EditorCommand::QuickApply));
        // Ctrl+Shift+Space has no Command twin: it still falls through to Play from Start.
        assert_eq!(
            WindowsKeyRoute::command(Key::Space, true, false, true, None, &map),
            Some(EditorCommand::PlayFromStart)
        );
        assert_eq!(route(Key::Char('k'), true, Some(PanelID::Timeline)), Some(EditorCommand::AddEdit));
        assert_eq!(route(Key::Space, false, None), Some(EditorCommand::PlayPause));
    }

    #[test]
    fn candidates_order() {
        let c = WindowsKeyRoute::candidates(Key::Char('a'), true, true, false);
        let mods: Vec<KeyModifiers> = c.iter().map(|b| b.modifiers).collect();
        assert_eq!(mods, vec![CMD | OPT, CTRL | OPT, CMD | CTRL | OPT]);
        let s = WindowsKeyRoute::candidates(Key::Char('a'), false, false, true);
        assert_eq!(s.iter().map(|b| b.modifiers).collect::<Vec<_>>(), vec![SHIFT]);
    }

    #[test]
    fn shadowed_lists_control_bindings_with_a_ctrl_twin() {
        let s = WindowsKeyRoute::shadowed(&CommandMap::premiere_default_for(Platform::Windows));
        assert!(s.iter().any(|e| e.command == EditorCommand::JumpCutAlternate)); // Ctrl+K is Add Edit
        assert!(s.iter().any(|e| e.command == EditorCommand::PlayToOut)); // Ctrl+Space is Quick Apply
        assert!(s.iter().all(|e| e.binding.modifiers.contains(CTRL)));
    }
}

#[cfg(test)]
mod command_hint_tests {
    use super::*;

    #[test]
    fn the_command_hint_follows_the_platform() {
        assert_eq!(KeyBindingText::command_hint('c', Platform::Mac), "\u{2318}C");
        assert_eq!(KeyBindingText::command_hint('C', Platform::Windows), "Ctrl+C");
        assert_eq!(KeyBindingText::command_hint('v', Platform::Linux), "Ctrl+V");
    }
}
