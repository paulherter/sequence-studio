// Swift: ShellKeys.swift
//! The event glue of the shortcut system: a shared-toolkit key press becomes the `Key` of the Mac key map, then
//! `WindowsKeyRoute` picks the command (Ctrl reaches Command bindings first, then Control ones). The map, scopes and
//! conflict rules are the Mac ones (`CommandMap`), unchanged.

use sq_draw::{InputKey, InputModifiers};
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
use sq_uikit::key_binding_text::WindowsKeyRoute;
use sq_uikit::panel_id::PanelID;

/// Shared-toolkit key to key-map key.
pub enum ShellKeys {}

impl ShellKeys {
    /// `InputKey` to `Key`. Enter is Return, Backspace is the Mac Delete, Del is Forward Delete.
    pub fn key(k: InputKey) -> Option<Key> {
        match k {
            InputKey::Space => Some(Key::Space),
            InputKey::Left => Some(Key::Left),
            InputKey::Right => Some(Key::Right),
            InputKey::Up => Some(Key::Up),
            InputKey::Down => Some(Key::Down),
            InputKey::Home => Some(Key::Home),
            InputKey::End => Some(Key::End),
            InputKey::PageUp => Some(Key::PageUp),
            InputKey::PageDown => Some(Key::PageDown),
            InputKey::Function(n) => Some(Key::Function(i64::from(n))),
            InputKey::Backspace => Some(Key::Delete),
            InputKey::Delete => Some(Key::ForwardDelete),
            InputKey::Enter => Some(Key::ReturnKey),
            // The Mac map binds the unshifted key of the +/= cap.
            InputKey::Plus => Some(Key::Char('=')),
            InputKey::Minus => Some(Key::Char('-')),
            InputKey::Character(c) => c.to_lowercase().next().map(Key::Char),
            // Esc closes menus and dialogs first; the host routes it there.
            InputKey::Escape => None,
        }
    }

    /// The key press the window sends for `b`: the reverse of [`ShellKeys::key`] and the modifier mapping of
    /// [`ShellKeys::command`]. `mac`: Command and Control are two keys; elsewhere both read as the one Ctrl (`COMMAND`).
    pub fn press(b: &KeyBinding, mac: bool) -> (InputKey, InputModifiers) {
        let key = match b.key {
            Key::Space => InputKey::Space,
            Key::Left => InputKey::Left,
            Key::Right => InputKey::Right,
            Key::Up => InputKey::Up,
            Key::Down => InputKey::Down,
            Key::Home => InputKey::Home,
            Key::End => InputKey::End,
            Key::PageUp => InputKey::PageUp,
            Key::PageDown => InputKey::PageDown,
            Key::Delete => InputKey::Backspace,
            Key::ForwardDelete => InputKey::Delete,
            Key::ReturnKey => InputKey::Enter,
            // The window reports the minus cap as `Minus` (sequence-studio/src/input.rs).
            Key::Char('-') => InputKey::Minus,
            Key::Char(c) => InputKey::Character(c),
            Key::Function(n) => InputKey::Function(u8::try_from(n).unwrap_or(u8::MAX)),
        };
        let m = b.modifiers;
        let mut mods = InputModifiers::NONE;
        if m.contains(KeyModifiers::COMMAND) || (!mac && m.contains(KeyModifiers::CONTROL)) {
            mods = mods | InputModifiers::COMMAND;
        }
        if mac && m.contains(KeyModifiers::CONTROL) {
            mods = mods | InputModifiers::CONTROL;
        }
        if m.contains(KeyModifiers::OPTION) {
            mods = mods | InputModifiers::OPTION;
        }
        if m.contains(KeyModifiers::SHIFT) {
            mods = mods | InputModifiers::SHIFT;
        }
        (key, mods)
    }

    /// Ctrl+Q on Linux: the desktop's Quit key. Mac has Cmd+Q in its menu bar and Windows has the system's Alt+F4; Linux has
    /// neither, so the shell takes the chord itself (then the same Save Changes question as File > Exit).
    pub fn is_quit_chord(k: InputKey, m: InputModifiers, platform: sq_os::Platform) -> bool {
        platform == sq_os::Platform::Linux
            && m == InputModifiers::COMMAND
            && matches!(k, InputKey::Character(c) if c.eq_ignore_ascii_case(&'q'))
    }

    /// Alt held with a letter or digit on Windows or Linux: the chord that opens the menu bar's title with that mnemonic,
    /// unless the key map binds it (Alt+M, Alt+V, Alt+W are bound; the caller checks `command` first).
    pub fn is_menu_mnemonic_chord(k: InputKey, m: InputModifiers, platform: sq_os::Platform) -> bool {
        platform != sq_os::Platform::Mac
            && m == InputModifiers::OPTION
            && matches!(k, InputKey::Character(c) if c.is_alphanumeric())
    }

    /// The command a key press runs with `focus`, or `None` (`InputModifiers::COMMAND` is the Ctrl key on Windows).
    /// `mac`: the Mac window, where Command and Control are two keys and a chord is looked up as pressed (Windows has one
    /// Ctrl that reaches both kinds of binding).
    pub fn command(
        k: InputKey,
        m: InputModifiers,
        focus: Option<PanelID>,
        map: &CommandMap,
        mac: bool,
    ) -> Option<EditorCommand> {
        let mut key = Self::key(k)?;
        // Forward Delete runs Delete unless the map binds Forward Delete itself (Fn+Backspace, an external Del key).
        if key == Key::ForwardDelete && !map.entries.iter().any(|e| e.binding.key == Key::ForwardDelete) {
            key = Key::Delete;
        }
        if mac || m.contains(InputModifiers::CONTROL) {
            let mut mods = KeyModifiers::EMPTY;
            if m.contains(InputModifiers::COMMAND) {
                mods |= KeyModifiers::COMMAND;
            }
            if m.contains(InputModifiers::CONTROL) {
                mods |= KeyModifiers::CONTROL;
            }
            if m.contains(InputModifiers::OPTION) {
                mods |= KeyModifiers::OPTION;
            }
            if m.contains(InputModifiers::SHIFT) {
                mods |= KeyModifiers::SHIFT;
            }
            return map.command_for(&KeyBinding::new(key, mods), focus);
        }
        WindowsKeyRoute::command(
            key,
            m.contains(InputModifiers::COMMAND),
            m.contains(InputModifiers::OPTION),
            m.contains(InputModifiers::SHIFT),
            focus,
            map,
        )
    }
}

/// Alt pressed and released alone focuses the menu bar (`MenuBar::alt_tapped`), the Windows menu-key rule. The window feeds
/// raw presses: Alt down (repeats keep it armed), any other key or a mouse press in between disarms it (Alt+key shortcuts,
/// Alt+click), Alt up reports the tap.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AltTap {
    down: bool,
    clean: bool,
}

impl AltTap {
    /// A tracker with Alt up.
    pub fn new() -> AltTap {
        AltTap::default()
    }

    /// Alt went down (a repeat keeps it armed).
    pub fn alt_down(&mut self) {
        if !self.down {
            self.down = true;
            self.clean = true;
        }
    }

    /// Another key or a mouse button while Alt is down: a shortcut, not a tap.
    pub fn other(&mut self) {
        self.clean = false;
    }

    /// Alt released: true when nothing else happened since it went down.
    pub fn alt_up(&mut self) -> bool {
        let tap = self.down && self.clean;
        self.down = false;
        self.clean = false;
        tap
    }
}

/// Window title and dirty state: the Mac sets `window.title = session.displayName` and `isDocumentEdited` (the dot in the close
/// button). Windows shows the edited state the platform way, a leading "*", and names the app after the project.
pub enum ShellWindowTitle {}

impl ShellWindowTitle {
    /// The title for the project (`None` or empty: the app name alone).
    pub fn text(project_name: Option<&str>, dirty: bool) -> String {
        match project_name {
            Some(name) if !name.is_empty() => {
                format!("{}{} - Sequence Studio", if dirty { "*" } else { "" }, name)
            }
            _ => "Sequence Studio".to_string(),
        }
    }
}

#[cfg(test)]
mod windows_chord_tests {
    use super::*;

    const FOCI: [Option<PanelID>; 6] = [
        None,
        Some(PanelID::Timeline),
        Some(PanelID::ProgramMonitor),
        Some(PanelID::SourceMonitor),
        Some(PanelID::Project),
        Some(PanelID::EffectControls),
    ];

    /// Ctrl as the Windows and Linux window reports it: the Command flag, with Shift and Alt as bound.
    fn ctrl_press(b: &KeyBinding) -> InputModifiers {
        let mut m = InputModifiers::COMMAND;
        if b.modifiers.contains(KeyModifiers::SHIFT) {
            m = m | InputModifiers::SHIFT;
        }
        if b.modifiers.contains(KeyModifiers::OPTION) {
            m = m | InputModifiers::OPTION;
        }
        m
    }

    fn input_key(k: Key) -> Option<InputKey> {
        match k {
            Key::Char(c) => Some(InputKey::Character(c)),
            _ => None,
        }
    }

    /// Every Ctrl chord of the key map (punctuation included) runs a command that itself is bound with Ctrl (Command or
    /// Control): it never falls through to the bare-key command of the same key (`,` Insert, Shift+`,` Nudge Left 10).
    #[test]
    fn a_ctrl_chord_never_falls_through_to_a_bare_key_command() {
        for (name, map) in [("sq", CommandMap::sq_default()), ("premiere", CommandMap::premiere_default())] {
            for e in map.entries.iter().filter(|e| {
                e.binding.modifiers.contains(KeyModifiers::COMMAND)
                    || e.binding.modifiers.contains(KeyModifiers::CONTROL)
            }) {
                let Some(k) = input_key(e.binding.key) else { continue };
                for focus in FOCI {
                    let Some(c) = ShellKeys::command(k, ctrl_press(&e.binding), focus, &map, false) else { continue };
                    let ctrl_bound = map.entries.iter().any(|o| {
                        o.command == c
                            && o.binding.key == e.binding.key
                            && (o.binding.modifiers.contains(KeyModifiers::COMMAND)
                                || o.binding.modifiers.contains(KeyModifiers::CONTROL))
                    });
                    assert!(
                        ctrl_bound,
                        "{name}: Ctrl chord {:?} in {focus:?} ran {c:?}, a bare-key binding",
                        e.binding
                    );
                }
            }
        }
    }

    /// The press `ShellKeys::press` builds for a binding runs that binding's command in the panel of its scope, on every
    /// system (a Control chord whose Ctrl twin is taken is the one Windows and Linux cannot press: `shadowed`).
    #[test]
    fn the_press_of_every_binding_runs_its_command() {
        use sq_os::Platform;
        use sq_uikit::editor_command::CommandScope;
        for platform in [Platform::Mac, Platform::Windows, Platform::Linux] {
            let map = CommandMap::sq_default_for(platform);
            let mac = platform == Platform::Mac;
            let shadowed = sq_uikit::key_binding_text::WindowsKeyRoute::shadowed(&map);
            for e in &map.entries {
                if !mac && shadowed.contains(e) {
                    continue;
                }
                let focus = match e.scope {
                    CommandScope::Global => None,
                    CommandScope::Timeline => Some(PanelID::Timeline),
                    CommandScope::Program => Some(PanelID::ProgramMonitor),
                    CommandScope::Source => Some(PanelID::SourceMonitor),
                    CommandScope::Project => Some(PanelID::Project),
                    CommandScope::EffectControls => Some(PanelID::EffectControls),
                };
                let (key, mods) = ShellKeys::press(&e.binding, mac);
                assert_eq!(
                    ShellKeys::command(key, mods, focus, &map, mac),
                    Some(e.command),
                    "{platform:?}: {:?} in {focus:?}",
                    e.binding
                );
            }
        }
    }

    /// Ctrl+, opens Settings and Ctrl+. is not a bare-key command, in every focus, as a Windows or Linux window sends it.
    #[test]
    fn ctrl_comma_is_settings_in_every_focus_and_ctrl_period_is_not_overwrite() {
        for map in [CommandMap::sq_default(), CommandMap::premiere_default()] {
            for focus in FOCI {
                let comma = ShellKeys::command(InputKey::Character(','), InputModifiers::COMMAND, focus, &map, false);
                assert_eq!(comma, Some(EditorCommand::Preferences), "Ctrl+, in {focus:?}");
                let period = ShellKeys::command(InputKey::Character('.'), InputModifiers::COMMAND, focus, &map, false);
                assert!(
                    !matches!(period, Some(EditorCommand::Overwrite | EditorCommand::Insert)),
                    "Ctrl+. in {focus:?} ran {period:?}"
                );
            }
        }
    }
}
