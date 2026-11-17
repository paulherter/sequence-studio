//! winit key and IME events to the draw UI's input and the UI's cursor shapes to winit's. The pointer and the modifiers are
//! `sq_draw::pointer`, shared with the setup's window.

use crate::caption::{TitleAction, TitleClicks, WindowHit};
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{InputKey, InputModifiers};
use sq_os::Platform;
use sq_uikit::layout_keys;
use winit::keyboard::{Key, KeyCode, ModifiersState, NamedKey, PhysicalKey};
use winit::platform::modifier_supplement::KeyEventExtModifierSupplement;
use winit::window::CursorIcon;

pub use sq_draw::pointer::{Pointer, modifiers};

/// The key of a real window event and whether Shift stays a modifier of it: the layout's character without modifiers, or
/// the US key position when the character is no key of the map. Windows and Linux match by the rule of
/// `sq_uikit::layout_keys` (a character Shift types on the key, German Shift+7 = `/`, counts as that character, Shift used
/// up); the Mac keeps the plain rule of [`resolve_key`]. `mods` are the modifiers held, as [`modifiers`] made them.
pub fn event_key(e: &winit::event::KeyEvent, mods: InputModifiers) -> Option<(InputKey, bool)> {
    let shift = mods.contains(InputModifiers::SHIFT);
    let bare = e.key_without_modifiers();
    if Platform::current() == Platform::Mac {
        return resolve_key(&bare, e.physical_key).map(|k| (k, shift));
    }
    let (ctrl, alt) = (mods.contains(InputModifiers::COMMAND), mods.contains(InputModifiers::OPTION));
    let binds = |c: char, s: bool| {
        sq_uikit::command_map::CommandMap::current_binds_press(
            sq_uikit::key_binding::Key::Char(layout_keys::map_char(c)),
            ctrl,
            alt,
            s,
        )
    };
    resolve_pc_key(&bare, e.physical_key, shift, sq_os::keyboard::active().as_deref(), &binds)
}

/// [`event_key`] on a keyboard layout, for a press of `shift` state; `binds` says whether the key map binds a character with
/// a Shift state and the modifiers held.
pub fn resolve_pc_key(
    logical: &Key,
    physical: PhysicalKey,
    shift: bool,
    layout: Option<&sq_os::keyboard::ActiveKeyboard>,
    binds: &dyn Fn(char, bool) -> bool,
) -> Option<(InputKey, bool)> {
    let base = resolve_key(logical, physical)?;
    if !matches!(base, InputKey::Character(_) | InputKey::Plus | InputKey::Minus) {
        return Some((base, shift));
    }
    let plain = match logical {
        Key::Character(s) if s.chars().count() == 1 => s.chars().next(),
        _ => None,
    };
    let position = match physical_key(physical) {
        Some(InputKey::Character(c)) => Some(c),
        Some(InputKey::Minus) => Some('-'),
        _ => None,
    };
    let shifted = layout.and_then(|l| l.probes.iter().find(|p| Some(p.position) == position)).and_then(|p| p.shifted);
    let cs = layout_keys::chords(plain, shifted, position, shift);
    Some(match layout_keys::choose(&cs, binds) {
        Some((c, s)) => (input_key_of(c), s),
        None => (base, shift),
    })
}

/// The key a typed character is: `-` and `+` have their own keys in the draw UI.
fn input_key_of(c: char) -> InputKey {
    match c {
        '-' => InputKey::Minus,
        '+' => InputKey::Plus,
        c => InputKey::Character(c),
    }
}

/// `m` with Shift set or cleared.
pub fn with_shift(m: InputModifiers, shift: bool) -> InputModifiers {
    if m.contains(InputModifiers::SHIFT) == shift {
        return m;
    }
    let rest = [InputModifiers::COMMAND, InputModifiers::OPTION, InputModifiers::SECONDARY, InputModifiers::CONTROL]
        .into_iter()
        .filter(|f| m.contains(*f))
        .fold(InputModifiers::NONE, |acc, f| acc | f);
    if shift { rest | InputModifiers::SHIFT } else { rest }
}

/// `logical` is the layout's key without modifiers. Letters and digits follow the cap (Ctrl+Z is the key marked Z), the
/// mapped punctuation follows the character; every other character (German `#`, `ß`, `ü`, `ö`, `ä`, dead keys, non-Latin
/// letters) falls back to the key position, as Swift (`PhysicalKeys`, by key code) and Premiere do: the `#` key sits where
/// `\` is on a US keyboard, so it is Fit Sequence.
pub fn resolve_key(logical: &Key, physical: PhysicalKey) -> Option<InputKey> {
    match key(logical) {
        Some(InputKey::Character(c)) if c.is_ascii_alphanumeric() || layout_keys::MAPPED_PUNCTUATION.contains(c) => {
            Some(InputKey::Character(c))
        }
        Some(k @ (InputKey::Plus | InputKey::Minus)) => Some(k),
        Some(InputKey::Character(c)) if c.is_control() => physical_key(physical),
        Some(k @ InputKey::Character(_)) => physical_key(physical).or(Some(k)),
        Some(k) => Some(k),
        None => match logical {
            Key::Named(_) => None,
            _ => physical_key(physical),
        },
    }
}

/// The US-layout character of a key position (Swift `PhysicalKeys`).
fn physical_key(p: PhysicalKey) -> Option<InputKey> {
    let PhysicalKey::Code(code) = p else { return None };
    let c = match code {
        KeyCode::Backslash => '\\',
        KeyCode::Equal => '=',
        KeyCode::Minus => '-',
        KeyCode::BracketLeft => '[',
        KeyCode::BracketRight => ']',
        KeyCode::Quote => '\'',
        KeyCode::Semicolon => ';',
        KeyCode::Comma => ',',
        KeyCode::Slash => '/',
        KeyCode::Period => '.',
        KeyCode::Backquote => '`',
        KeyCode::IntlBackslash => '<',
        KeyCode::KeyA => 'a',
        KeyCode::KeyB => 'b',
        KeyCode::KeyC => 'c',
        KeyCode::KeyD => 'd',
        KeyCode::KeyE => 'e',
        KeyCode::KeyF => 'f',
        KeyCode::KeyG => 'g',
        KeyCode::KeyH => 'h',
        KeyCode::KeyI => 'i',
        KeyCode::KeyJ => 'j',
        KeyCode::KeyK => 'k',
        KeyCode::KeyL => 'l',
        KeyCode::KeyM => 'm',
        KeyCode::KeyN => 'n',
        KeyCode::KeyO => 'o',
        KeyCode::KeyP => 'p',
        KeyCode::KeyQ => 'q',
        KeyCode::KeyR => 'r',
        KeyCode::KeyS => 's',
        KeyCode::KeyT => 't',
        KeyCode::KeyU => 'u',
        KeyCode::KeyV => 'v',
        KeyCode::KeyW => 'w',
        KeyCode::KeyX => 'x',
        KeyCode::KeyY => 'y',
        KeyCode::KeyZ => 'z',
        KeyCode::Digit0 => '0',
        KeyCode::Digit1 => '1',
        KeyCode::Digit2 => '2',
        KeyCode::Digit3 => '3',
        KeyCode::Digit4 => '4',
        KeyCode::Digit5 => '5',
        KeyCode::Digit6 => '6',
        KeyCode::Digit7 => '7',
        KeyCode::Digit8 => '8',
        KeyCode::Digit9 => '9',
        _ => return None,
    };
    Some(match c {
        '-' => InputKey::Minus,
        c => InputKey::Character(c),
    })
}

/// One line for the `SQ_LOG=debug` log: everything the window knows about a key event.
pub fn describe_key_event(e: &winit::event::KeyEvent, mods: ModifiersState) -> String {
    format!(
        "key {} logical={:?} bare={:?} physical={:?} text={:?} mods={:?} repeat={}",
        if e.state.is_pressed() { "down" } else { "up" },
        e.logical_key,
        e.key_without_modifiers(),
        e.physical_key,
        e.text,
        mods,
        e.repeat
    )
}

/// The key a press maps to (`key_without_modifiers` of the event); `None` for keys the UI ignores.
pub fn key(key: &Key) -> Option<InputKey> {
    Some(match key {
        Key::Named(n) => match n {
            NamedKey::Space => InputKey::Space,
            NamedKey::ArrowLeft => InputKey::Left,
            NamedKey::ArrowRight => InputKey::Right,
            NamedKey::ArrowUp => InputKey::Up,
            NamedKey::ArrowDown => InputKey::Down,
            NamedKey::Home => InputKey::Home,
            NamedKey::End => InputKey::End,
            NamedKey::Delete => InputKey::Delete,
            NamedKey::Backspace => InputKey::Backspace,
            NamedKey::Escape => InputKey::Escape,
            NamedKey::Enter => InputKey::Enter,
            NamedKey::PageUp => InputKey::PageUp,
            NamedKey::PageDown => InputKey::PageDown,
            NamedKey::Tab => InputKey::Character('\t'),
            NamedKey::F1 => InputKey::Function(1),
            NamedKey::F2 => InputKey::Function(2),
            NamedKey::F3 => InputKey::Function(3),
            NamedKey::F4 => InputKey::Function(4),
            NamedKey::F5 => InputKey::Function(5),
            NamedKey::F6 => InputKey::Function(6),
            NamedKey::F7 => InputKey::Function(7),
            NamedKey::F8 => InputKey::Function(8),
            NamedKey::F9 => InputKey::Function(9),
            NamedKey::F10 => InputKey::Function(10),
            NamedKey::F11 => InputKey::Function(11),
            NamedKey::F12 => InputKey::Function(12),
            _ => return None,
        },
        Key::Character(s) => match s.chars().next()? {
            '+' => InputKey::Plus,
            '-' => InputKey::Minus,
            c => InputKey::Character(c.to_lowercase().next().unwrap_or(c)),
        },
        _ => return None,
    })
}

/// The text a key press types: printable characters without the command modifier.
pub fn typed_text(text: Option<&str>, mods: InputModifiers) -> Option<String> {
    let text = text?;
    let printable = !text.is_empty() && !text.chars().any(char::is_control);
    (printable && !mods.contains(InputModifiers::COMMAND)).then(|| text.to_string())
}

/// Which Alt key a key event is. Windows reports AltGr as a synthetic left Ctrl plus the right Alt, so a Ctrl+Alt modifier
/// state alone cannot tell AltGr from a real Ctrl+Alt chord; the Alt key itself can. Microsoft documents the two keys as
/// distinct virtual keys, VK_LMENU 0xA4 and VK_RMENU 0xA5 ("Virtual-Key Codes",
/// https://learn.microsoft.com/windows/win32/inputdev/virtual-key-codes), and the right-hand Alt (and Ctrl) as the
/// "extended key" of a key message ("About Keyboard Input, Keystroke Message Flags",
/// https://learn.microsoft.com/windows/win32/inputdev/about-keyboard-input#keystroke-message-flags). winit maps VK_RMENU of an
/// AltGr layout to `NamedKey::AltGraph`, and Linux (xkb) reports AltGr as ISO_Level3_Shift, which winit also names
/// `AltGraph`, so one rule serves both.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AltKey {
    /// A plain Alt key (left, or the right one of a layout with no AltGr).
    Alt,
    /// The Alt key of a layout whose right Alt is AltGr (VK_RMENU, ISO_Level3_Shift).
    Graph,
}

/// The Alt key a key's logical value is, if it is one.
pub fn alt_key_of(logical: &Key) -> Option<AltKey> {
    match logical {
        Key::Named(NamedKey::Alt) => Some(AltKey::Alt),
        Key::Named(NamedKey::AltGraph) => Some(AltKey::Graph),
        _ => None,
    }
}

/// Which Alt keys are down, and whether Alt alone was tapped (the menu bar's key). The window feeds every key and press.
#[derive(Clone, Copy, Debug, Default)]
pub struct AltKeys {
    alt: bool,
    graph: bool,
    tap: sq_draw_shell::AltTap,
}

impl AltKeys {
    /// An Alt key changed. True when this release completes a lone Alt tap (a plain Alt, not AltGr).
    pub fn alt_changed(&mut self, k: AltKey, pressed: bool) -> bool {
        match k {
            AltKey::Graph => {
                self.graph = pressed;
                self.tap.other();
                false
            }
            AltKey::Alt if pressed => {
                self.alt = true;
                self.tap.alt_down();
                false
            }
            AltKey::Alt => {
                self.alt = false;
                self.tap.alt_up()
            }
        }
    }

    /// Any other key or a mouse press or wheel step: an Alt held now is a shortcut or a zoom, not a tap.
    pub fn other(&mut self) {
        self.tap.other();
    }

    /// The window lost the keyboard: no Alt key counts as held.
    pub fn reset(&mut self) {
        *self = AltKeys::default();
    }

    /// AltGr is down and no plain Alt with it: a press now is a typed character. A real Ctrl+Alt chord has a plain Alt down.
    pub fn altgr_down(&self) -> bool {
        self.graph && !self.alt
    }
}

/// The text of a press that AltGr made. Windows reports AltGr as Ctrl+Alt, so `\ @ { } [ ] | ~ \u{20ac}` on a German map arrive as
/// a Ctrl+Alt chord next to the key's own position (AltGr+ss looked like Ctrl+Alt+-, the interface zoom). A character the
/// press produced while AltGr (and no plain Alt) is down is text, not a chord. `None`: a real Ctrl+Alt shortcut (a plain Alt is
/// down: Quick Export Ctrl+Alt+M, Actual Size, the track targets and fades, whatever character the layout would give it)
/// or another system. Decision: AltGr counts as Ctrl+Alt.
pub fn altgr_text(platform: Platform, text: Option<&str>, mods: InputModifiers, altgr_down: bool) -> Option<String> {
    let both = InputModifiers::COMMAND | InputModifiers::OPTION;
    if platform.command_is_cmd_key() || !altgr_down || !mods.contains(both) {
        return None;
    }
    let text = text?;
    let printable = !text.is_empty() && !text.chars().any(char::is_control);
    printable.then(|| text.to_string())
}

/// The key, typed text and modifiers a key press hands the UI: an AltGr character is text for the focused field only (a key
/// of no binding, no Ctrl+Alt); every other press keeps its key and modifiers.
pub fn press_shape(
    platform: Platform,
    key: InputKey,
    text: Option<&str>,
    mods: InputModifiers,
    altgr_down: bool,
) -> (InputKey, Option<String>, InputModifiers) {
    match altgr_text(platform, text, mods, altgr_down) {
        Some(t) => {
            let shift = if mods.contains(InputModifiers::SHIFT) { InputModifiers::SHIFT } else { InputModifiers::NONE };
            (InputKey::Character('\0'), Some(t), shift)
        }
        None => (key, typed_text(text, mods), mods),
    }
}

/// Alt+F4 on Windows: the window's close (the Save Changes question when the project is edited). The system turns the chord
/// into a close request itself and winit never reports the F4 press; this is the net for a build or an input path where
/// the chord arrives as a plain key press, so it still never goes unanswered. Other systems close through their window manager.
pub fn closes_window(platform: Platform, key: InputKey, mods: InputModifiers) -> bool {
    platform == Platform::Windows
        && key == InputKey::Function(4)
        && mods.contains(InputModifiers::OPTION)
        && !mods.contains(InputModifiers::COMMAND)
}

/// What an input method event asks of the UI.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ImeAction {
    /// Show this uncommitted text inline at the caret (empty: none).
    Composition(String),
    /// The finished text: the focused field types it.
    Commit(String),
    /// Nothing to show or type.
    Nothing,
}

/// `Ime` events of every system (Windows IME/TSF, Mac input methods and dead keys, Linux IBus/Fcitx/XIM) as one action.
pub fn ime_action(e: &winit::event::Ime) -> ImeAction {
    use winit::event::Ime;
    match e {
        Ime::Preedit(text, _) => ImeAction::Composition(text.clone()),
        Ime::Commit(text) if !text.is_empty() => ImeAction::Commit(text.clone()),
        Ime::Commit(_) | Ime::Enabled => ImeAction::Nothing,
        Ime::Disabled => ImeAction::Composition(String::new()),
    }
}

/// Whether a press at `y` device pixels lies in the drawn title row, which moves the window when nothing in it took the
/// press (the Mac has no system title bar).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))] // only the Mac drags by the title row (Windows and Linux have caption.rs)
pub fn in_title_row(y: f32, scale: f32) -> bool {
    y < sq_uikit::design_tokens::sq_tokens::metrics::TOP_BAR * scale
}

/// Decides for every press whether it starts the system window drag, which also zooms the window on a double-click.
/// Only a double-click on EMPTY title-row space may zoom: a press that follows a press a control or a popup row took (the
/// second click of a double-click on the Workspace button or on one of its rows, which has closed by then) is the same
/// double-click and never drags. The count is the caption's (`TitleClicks`, shared with Linux); the Mac's system zooms.
#[derive(Clone, Copy, Debug, Default)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub struct TitleDragGate {
    clicks: TitleClicks,
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
impl TitleDragGate {
    /// A press at (`x`, `y`) device pixels at `now` seconds; `taken` is whether a control or menu took it. `Drag` starts
    /// the system window drag; `ToggleMaximize` is the double-click on empty space, which the caller answers with the
    /// user's title-bar double-click action (the system no longer does: the content view refuses the titlebar drag, so
    /// a drag started by the second press did not zoom, Mac 0.1.2).
    pub fn press(&mut self, x: f32, y: f32, scale: f32, taken: bool, now: f64) -> TitleAction {
        let hit = if in_title_row(y, scale) { WindowHit::Caption } else { WindowHit::Client };
        self.clicks.press(hit, x, y, scale, taken, now)
    }
}

/// What a double-click on empty title-bar space does on the Mac: the system setting "Double-click a window's title bar
/// to" (`AppleActionOnDoubleClick`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub enum DoubleClickAction {
    Zoom,
    Minimize,
    Nothing,
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
impl DoubleClickAction {
    /// From the default's text: "Maximize" zooms, "Minimize" miniaturizes, "None" does nothing; a missing value is the
    /// system default, zoom.
    pub fn from_setting(value: Option<&str>) -> Self {
        match value {
            Some("Minimize") => Self::Minimize,
            Some("None") => Self::Nothing,
            _ => Self::Zoom,
        }
    }
}

/// The system cursor for a UI shape.
/// The tool shapes (`DrawCursor::has_drawn_glyph`) are custom cursors made by the window (`Shell::apply_cursor`); this
/// is the system fallback and the system shapes.
/// The scale a drawn cursor glyph is rendered at. winit's macOS custom cursor takes the image's pixel size as points (it
/// builds an `NSImage` of `width x height` points), so a 2x render showed at twice the size there (Mac 0.1.2): the Mac
/// renders at 1x and gets a 24 pt cursor. Windows and Linux cursors are in device pixels: the window's scale.
pub fn cursor_render_scale(window_scale: f32) -> f32 {
    cursor_render_scale_for(window_scale, cfg!(target_os = "macos"))
}

/// [`cursor_render_scale`] with the platform given (tests).
pub fn cursor_render_scale_for(window_scale: f32, mac: bool) -> f32 {
    if mac { 1.0 } else { window_scale.max(1.0) }
}

pub fn cursor_icon(c: DrawCursor) -> CursorIcon {
    match c {
        DrawCursor::Crosshair => CursorIcon::Crosshair,
        DrawCursor::IBeam => CursorIcon::Text,
        DrawCursor::ResizeLeftRight => CursorIcon::EwResize,
        DrawCursor::ResizeUpDown => CursorIcon::NsResize,
        DrawCursor::OpenHand => CursorIcon::Grab,
        DrawCursor::ClosedHand => CursorIcon::Grabbing,
        DrawCursor::PointingHand => CursorIcon::Pointer,
        DrawCursor::DragCopy => CursorIcon::Copy,
        DrawCursor::ZoomIn => CursorIcon::ZoomIn,
        DrawCursor::NotAllowed => CursorIcon::NotAllowed,
        _ => CursorIcon::Default,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_draw::pointer::modifiers_for;

    #[test]
    fn keys_map_by_name_and_character() {
        assert_eq!(key(&Key::Named(NamedKey::Space)), Some(InputKey::Space));
        assert_eq!(key(&Key::Named(NamedKey::F5)), Some(InputKey::Function(5)));
        assert_eq!(key(&Key::Named(NamedKey::Tab)), Some(InputKey::Character('\t')));
        assert_eq!(key(&Key::Character("K".into())), Some(InputKey::Character('k')));
        assert_eq!(key(&Key::Character("-".into())), Some(InputKey::Minus));
        assert_eq!(key(&Key::Named(NamedKey::Shift)), None);
    }

    #[test]
    fn a_winit_ctrl_shift_m_press_runs_go_to_previous_marker() {
        use sq_uikit::command_map::CommandMap;
        use sq_uikit::editor_command::EditorCommand;
        // What the window does for KeyboardInput: modifiers from the state, the key without modifiers.
        let mods = modifiers(if Platform::current().command_is_cmd_key() {
            ModifiersState::SUPER | ModifiersState::SHIFT
        } else {
            ModifiersState::CONTROL | ModifiersState::SHIFT
        });
        let map = CommandMap::sq_default();
        for typed in ["M", "m"] {
            let k = key(&Key::Character(typed.into())).unwrap();
            let c = sq_draw_shell::ShellKeys::command(k, mods, None, &map, Platform::current().command_is_cmd_key());
            assert_eq!(c, Some(EditorCommand::PreviousMarker), "key {typed}");
        }
    }

    #[test]
    fn a_real_ctrl_comma_opens_preferences_on_windows_and_linux() {
        use sq_uikit::command_map::CommandMap;
        use sq_uikit::editor_command::EditorCommand as C;
        let map = CommandMap::sq_default();
        for p in [Platform::Windows, Platform::Linux] {
            // The window's path: winit modifiers -> `modifiers_for` -> key -> map; and the harness's `--key ctrl+,`.
            let real = modifiers_for(p, ModifiersState::CONTROL);
            let k = resolve_key(&Key::Character(",".into()), PhysicalKey::Code(KeyCode::Comma)).unwrap();
            assert_eq!(sq_draw_shell::ShellKeys::command(k, real, None, &map, false), Some(C::Preferences), "{p:?}");
            assert_eq!(crate::cli::parse_key_for(p, "ctrl+,"), Some((k, real)), "{p:?}");
        }
    }

    #[test]
    fn real_windows_key_shapes_reach_the_map() {
        use sq_uikit::command_map::CommandMap;
        use sq_uikit::editor_command::EditorCommand as C;
        let map = CommandMap::sq_default();
        let run = |logical: Key, code: KeyCode, mods: InputModifiers, focus| {
            let k = resolve_key(&logical, PhysicalKey::Code(code))?;
            sq_draw_shell::ShellKeys::command(k, mods, focus, &map, false)
        };
        let ch = |s: &str| Key::Character(s.into());
        let tl = Some(sq_uikit::panel_id::PanelID::Timeline);
        // German layout, from the real window log: the `#` key (US backslash position) is Fit Sequence, Ctrl+Shift+Z
        // arrives as bare "z" on the key position Y.
        assert_eq!(run(ch("#"), KeyCode::Backslash, InputModifiers::NONE, tl), Some(C::ZoomFit));
        assert_eq!(run(ch("\\"), KeyCode::Backslash, InputModifiers::NONE, tl), Some(C::ZoomFit), "US layout");
        assert_eq!(run(ch("z"), KeyCode::KeyY, InputModifiers::COMMAND | InputModifiers::SHIFT, tl), Some(C::Redo));
        assert_eq!(
            run(ch("m"), KeyCode::KeyM, InputModifiers::COMMAND | InputModifiers::SHIFT, tl),
            Some(C::PreviousMarker)
        );
        assert_eq!(run(ch("-"), KeyCode::Slash, InputModifiers::NONE, tl), Some(C::ZoomOut), "German minus key");
        assert_eq!(run(ch("+"), KeyCode::BracketRight, InputModifiers::NONE, tl), Some(C::ZoomIn), "German plus key");
        assert_eq!(
            resolve_key(&Key::Dead(Some('^')), PhysicalKey::Code(KeyCode::Backquote)),
            Some(InputKey::Character('`'))
        );
    }

    /// A real press on `layout` through the window's rule and the key map: the command it runs in `focus`.
    fn layout_press(
        layout: &str,
        logical: Key,
        code: KeyCode,
        mods: InputModifiers,
        focus: Option<sq_uikit::panel_id::PanelID>,
    ) -> Option<sq_uikit::editor_command::EditorCommand> {
        use sq_uikit::command_map::CommandMap;
        let map = CommandMap::sq_default_for(Platform::Windows);
        let kb = sq_os::keyboard::ActiveKeyboard::from_id(layout);
        let (ctrl, alt) = (mods.contains(InputModifiers::COMMAND), mods.contains(InputModifiers::OPTION));
        let binds = |c: char, s: bool| {
            map.binds_press(sq_uikit::key_binding::Key::Char(layout_keys::map_char(c)), ctrl, alt, s)
        };
        let (k, shift) =
            resolve_pc_key(&logical, PhysicalKey::Code(code), mods.contains(InputModifiers::SHIFT), Some(&kb), &binds)?;
        sq_draw_shell::ShellKeys::command(k, with_shift(mods, shift), focus, &map, false)
    }

    /// A Windows run on a German keyboard: `/` is Shift+7 and the key left of 1 is the dead `^`.
    #[test]
    fn the_keys_a_german_keyboard_types_run_the_shortcuts_the_menus_show() {
        use sq_uikit::editor_command::EditorCommand as C;
        let ch = |s: &str| Key::Character(s.into());
        let (ctrl, shift) = (InputModifiers::COMMAND, InputModifiers::SHIFT);
        // File > New Folder is Ctrl+Shift+7 here, Edit > Duplicate Ctrl+Shift+`-` (the key at the US slash position).
        assert_eq!(layout_press("de", ch("7"), KeyCode::Digit7, ctrl | shift, None), Some(C::NewBin));
        assert_eq!(layout_press("de", ch("-"), KeyCode::Slash, ctrl | shift, None), Some(C::Duplicate));
        // Window > Maximize Panel is the dead `^` key.
        assert_eq!(
            layout_press("de", Key::Dead(Some('^')), KeyCode::Backquote, InputModifiers::NONE, None),
            Some(C::MaximizePanel)
        );
        // The zoom keys keep their characters, `ü` stays the US `[` key, a letter is the key marked so.
        let tl = Some(sq_uikit::panel_id::PanelID::Timeline);
        assert_eq!(layout_press("de", ch("+"), KeyCode::BracketRight, InputModifiers::NONE, tl), Some(C::ZoomIn));
        assert_eq!(layout_press("de", ch("-"), KeyCode::Slash, InputModifiers::NONE, tl), Some(C::ZoomOut));
        assert_eq!(layout_press("de", ch("ü"), KeyCode::BracketLeft, InputModifiers::NONE, tl), Some(C::AudioGainDown));
        // French AZERTY: the key at the US Q position is A (Ctrl+A selects all), Shift+`:` is `/` (Ctrl+Shift+`:` is New Folder).
        assert_eq!(layout_press("fr", ch("a"), KeyCode::KeyQ, ctrl, tl), Some(C::SelectAll));
        assert_eq!(layout_press("fr", ch(":"), KeyCode::Period, ctrl | shift, None), Some(C::NewBin));
        // The US layout is unchanged: `/` is the slash key itself.
        assert_eq!(layout_press("us", ch("/"), KeyCode::Slash, ctrl, None), Some(C::NewBin));
        assert_eq!(layout_press("us", ch("/"), KeyCode::Slash, ctrl | shift, None), Some(C::Duplicate));
        assert_eq!(layout_press("us", ch("`"), KeyCode::Backquote, InputModifiers::NONE, None), Some(C::MaximizePanel));
    }

    /// The audit of the shown shortcuts across layouts (the root audit presses the keys of `ShellKeys::press`): the key press
    /// each layout makes for the shown key of every default binding resolves, through the window's own function, to the very
    /// key and modifiers that audit presses.
    #[test]
    fn the_press_of_every_shown_key_resolves_to_its_binding_on_every_layout() {
        use sq_draw_shell::ShellKeys;
        use sq_uikit::command_map::CommandMap;
        use sq_uikit::key_binding::{Key as K, KeyModifiers as M};
        let letters = [
            KeyCode::KeyA,
            KeyCode::KeyB,
            KeyCode::KeyC,
            KeyCode::KeyD,
            KeyCode::KeyE,
            KeyCode::KeyF,
            KeyCode::KeyG,
            KeyCode::KeyH,
            KeyCode::KeyI,
            KeyCode::KeyJ,
            KeyCode::KeyK,
            KeyCode::KeyL,
            KeyCode::KeyM,
            KeyCode::KeyN,
            KeyCode::KeyO,
            KeyCode::KeyP,
            KeyCode::KeyQ,
            KeyCode::KeyR,
            KeyCode::KeyS,
            KeyCode::KeyT,
            KeyCode::KeyU,
            KeyCode::KeyV,
            KeyCode::KeyW,
            KeyCode::KeyX,
            KeyCode::KeyY,
            KeyCode::KeyZ,
        ];
        let others = [
            KeyCode::Digit1,
            KeyCode::Digit2,
            KeyCode::Digit3,
            KeyCode::Digit4,
            KeyCode::Digit5,
            KeyCode::Digit6,
            KeyCode::Digit7,
            KeyCode::Digit8,
            KeyCode::Digit9,
            KeyCode::Digit0,
            KeyCode::Minus,
            KeyCode::Equal,
            KeyCode::BracketLeft,
            KeyCode::BracketRight,
            KeyCode::Semicolon,
            KeyCode::Quote,
            KeyCode::Comma,
            KeyCode::Period,
            KeyCode::Slash,
            KeyCode::Backslash,
            KeyCode::Backquote,
            KeyCode::IntlBackslash,
        ];
        let code_of = |position: char| {
            letters.iter().chain(others.iter()).copied().find(|c| match physical_key(PhysicalKey::Code(*c)) {
                Some(InputKey::Character(p)) => p == position,
                Some(InputKey::Minus) => position == '-',
                _ => false,
            })
        };
        let map = CommandMap::sq_default_for(Platform::Windows);
        for id in ["us", "gb", "de", "fr"] {
            let kb = sq_os::keyboard::ActiveKeyboard::from_id(id);
            let layout = (id != "us").then_some(&kb);
            for e in map.entries.iter().filter(|e| matches!(e.binding.key, K::Char(_))) {
                if !map.is_pressable_with(e, Platform::Windows, layout) {
                    continue;
                }
                let K::Char(c) = e.binding.key else { continue };
                let m = e.binding.modifiers;
                let (ctrl, alt) = (m.contains(M::COMMAND) || m.contains(M::CONTROL), m.contains(M::OPTION));
                let binds = |c: char, s: bool| map.binds_press(K::Char(layout_keys::map_char(c)), ctrl, alt, s);
                let t = layout_keys::typing(layout, c, m.contains(M::SHIFT), &binds).expect("a shown key is typable");
                let at = layout.and_then(|l| l.probes.iter().find(|p| p.position == t.position));
                let (plain, shifted) = at.map_or((Some(t.position), None), |p| (p.plain, p.shifted));
                let logical = plain.map_or(Key::Dead(None), |p| Key::Character(p.to_string().into()));
                let code = code_of(t.position).unwrap_or_else(|| panic!("{id}: no key code for {:?}", t.position));
                let (want_key, want_mods) = ShellKeys::press(&e.binding, false);
                let (got, shift) = resolve_pc_key(&logical, PhysicalKey::Code(code), t.shift, layout, &binds)
                    .unwrap_or_else(|| panic!("{id}: {:?} resolves to nothing", e.binding));
                let ok = ShellKeys::key(got) == ShellKeys::key(want_key)
                    && with_shift(want_mods, shift) == with_shift(want_mods, m.contains(M::SHIFT));
                assert!(
                    ok,
                    "{id}: {:?} (typed {plain:?}/{shifted:?} at {:?}) became {got:?} shift {shift}",
                    e.binding, t
                );
            }
        }
    }

    /// German layout on Windows: AltGr arrives as Ctrl+Alt, and the characters it makes are text, never a shortcut.
    #[test]
    fn alt_f4_closes_the_window_on_windows_only() {
        let f4 = InputKey::Function(4);
        assert!(closes_window(Platform::Windows, f4, InputModifiers::OPTION));
        assert!(closes_window(Platform::Windows, f4, InputModifiers::OPTION | InputModifiers::SHIFT));
        assert!(!closes_window(Platform::Windows, f4, InputModifiers::NONE), "plain F4 is no close");
        assert!(
            !closes_window(Platform::Windows, f4, InputModifiers::COMMAND | InputModifiers::OPTION),
            "AltGr is text"
        );
        assert!(!closes_window(Platform::Windows, InputKey::Function(5), InputModifiers::OPTION));
        assert!(!closes_window(Platform::Mac, f4, InputModifiers::OPTION));
        assert!(!closes_window(Platform::Linux, f4, InputModifiers::OPTION));
    }

    #[test]
    fn altgr_characters_are_text_not_ctrl_alt_chords() {
        use sq_uikit::command_map::CommandMap;
        let both = InputModifiers::COMMAND | InputModifiers::OPTION;
        let map = CommandMap::sq_default();
        // (AltGr character, the key position it sits on: the position, not the character, is what a chord would use)
        for (text, code) in [
            ("\\", KeyCode::Minus),
            ("@", KeyCode::KeyQ),
            ("{", KeyCode::Digit7),
            ("}", KeyCode::Digit0),
            ("[", KeyCode::Digit8),
            ("]", KeyCode::Digit9),
            ("\u{20ac}", KeyCode::KeyE),
            ("~", KeyCode::BracketRight),
            ("|", KeyCode::IntlBackslash),
        ] {
            // What the window sends for the press: the key position and Ctrl+Alt become a key of no binding plus text.
            let position = resolve_key(&Key::Character(text.into()), PhysicalKey::Code(code)).expect("a key");
            let (k, typed, mods) = press_shape(Platform::Windows, position, Some(text), both, true);
            assert_eq!(typed.as_deref(), Some(text));
            for focus in [None, Some(sq_uikit::panel_id::PanelID::Timeline)] {
                let c = sq_draw_shell::ShellKeys::command(k, mods, focus, &map, false);
                assert_eq!(c, None, "{text} on {code:?} fires no shortcut");
            }
        }
        // Without AltGr text a Ctrl+Alt press stays a chord, and the Mac and a plain Ctrl press never count.
        assert_eq!(altgr_text(Platform::Windows, None, both, true), None);
        assert_eq!(altgr_text(Platform::Windows, Some("\u{1}"), both, true), None, "a control character is no text");
        assert_eq!(altgr_text(Platform::Windows, Some("a"), InputModifiers::COMMAND, true), None);
        assert_eq!(altgr_text(Platform::Mac, Some("\u{20ac}"), both, true), None);
    }

    #[test]
    fn a_real_ctrl_alt_chord_runs_its_shortcut_even_when_the_layout_gives_it_a_character() {
        use sq_uikit::command_map::CommandMap;
        use sq_uikit::editor_command::EditorCommand;
        let both = InputModifiers::COMMAND | InputModifiers::OPTION;
        let map = CommandMap::sq_default();
        // German layout: Windows turns Ctrl+Alt+M into the micro sign, Ctrl+Alt+7 into `{`, Ctrl+Alt+0 into `}`, Ctrl+Alt+8/9
        // into `[` `]`. Left Ctrl + left Alt (no AltGr down) must still reach the key map as the chord.
        for (text, key, expect) in
            [("\u{b5}", 'm', EditorCommand::QuickExport), ("}", '0', EditorCommand::UiScaleReset)]
        {
            let (k, typed, mods) = press_shape(Platform::Windows, InputKey::Character(key), Some(text), both, false);
            assert_eq!((k, typed, mods), (InputKey::Character(key), None, both), "{text}: stays a chord");
            let c = sq_draw_shell::ShellKeys::command(k, mods, None, &map, false);
            assert_eq!(c, Some(expect), "Ctrl+Alt+{key} runs");
        }
        // The same keys with AltGr down (Windows: right Alt + the synthetic left Ctrl) are text and fire nothing.
        for (text, key) in [("\u{b5}", 'm'), ("{", '7'), ("@", 'q')] {
            let (k, typed, mods) = press_shape(Platform::Windows, InputKey::Character(key), Some(text), both, true);
            assert_eq!(typed.as_deref(), Some(text));
            assert_eq!(sq_draw_shell::ShellKeys::command(k, mods, None, &map, false), None);
        }
        // Linux: AltGr is its own modifier, so a Ctrl+Alt press with no AltGr down is a chord there too.
        let (k, typed, _) = press_shape(Platform::Linux, InputKey::Character('7'), Some("7"), both, false);
        assert_eq!((k, typed), (InputKey::Character('7'), None));
    }

    #[test]
    fn the_alt_keys_tell_altgr_from_a_chord_and_a_lone_alt_tap_from_a_shortcut() {
        let mut a = AltKeys::default();
        // AltGr alone is no tap, and while it is down the press is text.
        assert!(!a.alt_changed(AltKey::Graph, true));
        assert!(a.altgr_down());
        assert!(!a.alt_changed(AltKey::Graph, false));
        assert!(!a.altgr_down());
        // A plain Alt tap reports once; a held Alt with a key between is no tap.
        assert!(!a.alt_changed(AltKey::Alt, true));
        assert!(a.alt_changed(AltKey::Alt, false));
        a.alt_changed(AltKey::Alt, true);
        a.other();
        assert!(!a.alt_changed(AltKey::Alt, false));
        // A real Alt down while AltGr is down (Ctrl+Alt chord next to it) counts as the chord.
        a.alt_changed(AltKey::Graph, true);
        a.alt_changed(AltKey::Alt, true);
        assert!(!a.altgr_down());
        a.reset();
        assert!(!a.altgr_down());
        assert_eq!(alt_key_of(&Key::Named(NamedKey::Alt)), Some(AltKey::Alt));
        assert_eq!(alt_key_of(&Key::Named(NamedKey::AltGraph)), Some(AltKey::Graph));
        assert_eq!(alt_key_of(&Key::Character("a".into())), None);
    }

    #[test]
    fn a_hash_without_a_key_position_stays_a_hash() {
        // winit derives the position from the virtual key when the scancode is 0 (keyboard.rs `from_message`), so an
        // unidentified position only appears for a scancode it does not know. Then the typed `#` is kept and the key map
        // has no command for it. Not mapped to `\`: no real-window log shows this path (waiting for a Windows run).
        let unknown = PhysicalKey::Unidentified(winit::keyboard::NativeKeyCode::Windows(0x7e));
        assert_eq!(resolve_key(&Key::Character("#".into()), unknown), Some(InputKey::Character('#')));
    }

    #[test]
    fn typed_text_skips_controls_and_commands() {
        assert_eq!(typed_text(Some("a"), InputModifiers::NONE).as_deref(), Some("a"));
        assert_eq!(typed_text(Some("\r"), InputModifiers::NONE), None);
        assert_eq!(typed_text(Some("a"), InputModifiers::COMMAND), None);
        assert_eq!(typed_text(None, InputModifiers::NONE), None);
    }

    #[test]
    fn ime_events_become_composition_and_commit() {
        use winit::event::Ime;
        assert_eq!(ime_action(&Ime::Preedit("にほ".into(), Some((0, 3)))), ImeAction::Composition("にほ".into()));
        assert_eq!(ime_action(&Ime::Preedit(String::new(), None)), ImeAction::Composition(String::new()));
        assert_eq!(ime_action(&Ime::Commit("日本".into())), ImeAction::Commit("日本".into()));
        assert_eq!(ime_action(&Ime::Commit(String::new())), ImeAction::Nothing);
        assert_eq!(ime_action(&Ime::Disabled), ImeAction::Composition(String::new()));
        assert_eq!(ime_action(&Ime::Enabled), ImeAction::Nothing);
    }

    #[test]
    fn a_double_click_zooms_only_on_empty_space_never_on_what_a_control_or_a_menu_took() {
        use crate::caption::TitleAction::{Drag, Nothing, ToggleMaximize};
        let mut gate = TitleDragGate::default();
        // Two quick presses on empty space: the first drags, the second is the double-click that zooms.
        assert_eq!(gate.press(300.0, 20.0, 2.0, false, 1.0), Drag);
        assert_eq!(gate.press(300.0, 20.0, 2.0, false, 1.2), ToggleMaximize);
        // A control took the first press (the Workspace button): its second press, taken or not, does nothing.
        assert_eq!(gate.press(500.0, 20.0, 2.0, true, 5.0), Nothing);
        assert_eq!(gate.press(500.0, 20.0, 2.0, true, 5.2), Nothing);
        // The popup row took the first press and closed: the second press falls on empty row space and must not zoom.
        assert_eq!(gate.press(520.0, 30.0, 2.0, true, 8.0), Nothing);
        assert_eq!(
            gate.press(521.0, 30.0, 2.0, false, 8.25),
            Nothing,
            "the second half of a double-click on a menu row"
        );
        // Later, or elsewhere, empty space drags again; a single click never zooms.
        assert_eq!(gate.press(521.0, 30.0, 2.0, false, 9.5), Drag);
        assert_eq!(gate.press(521.0, 30.0, 2.0, false, 11.0), Drag, "too slow for a double-click");
        assert_eq!(gate.press(500.0, 20.0, 2.0, true, 12.0), Nothing);
        assert_eq!(gate.press(900.0, 20.0, 2.0, false, 12.1), Drag, "another place is another click");
        assert_eq!(gate.press(900.0, 200.0, 2.0, false, 20.0), Nothing, "below the row nothing drags");
    }

    #[test]
    fn the_title_bar_double_click_follows_the_system_setting() {
        assert_eq!(DoubleClickAction::from_setting(Some("Maximize")), DoubleClickAction::Zoom);
        assert_eq!(DoubleClickAction::from_setting(None), DoubleClickAction::Zoom);
        assert_eq!(DoubleClickAction::from_setting(Some("Minimize")), DoubleClickAction::Minimize);
        assert_eq!(DoubleClickAction::from_setting(Some("None")), DoubleClickAction::Nothing);
    }

    #[test]
    fn the_title_row_is_the_top_bar_height_in_pixels() {
        assert!(in_title_row(79.0, 2.0));
        assert!(!in_title_row(80.0, 2.0));
    }

    #[test]
    fn drawn_cursors_are_system_size_at_one_and_two_x() {
        // Declared points = pixels / (scale the platform applies): 24 pt on every platform and scale.
        for scale in [1.0_f32, 2.0] {
            for mac in [true, false] {
                let img = sq_draw::cursor_glyph::render(DrawCursor::ZoomIn, cursor_render_scale_for(scale, mac))
                    .expect("a drawn glyph");
                let points = if mac { img.side as f32 } else { img.side as f32 / scale };
                assert!((16.0..=28.0).contains(&points), "mac {mac} scale {scale}: {points} pt");
            }
        }
    }

    /// The Mac hands winit pixels that it shows as points: the image is 24 px (24 pt) and the hotspot lies inside it.
    // shortcut: 1x bitmap on Retina (winit builds the NSCursor itself with one pixel per point and offers no 2x
    // representation); upgrade by owning the view's cursor rect in sq-platform-mac when the soft edge matters.
    #[test]
    fn the_mac_cursor_is_24_px_with_its_hotspot_in_points() {
        let scale = cursor_render_scale_for(2.0, true);
        assert_eq!(scale, 1.0);
        for shape in [DrawCursor::ZoomIn, DrawCursor::Crosshair] {
            let Some(img) = sq_draw::cursor_glyph::render(shape, scale) else { continue };
            assert_eq!(img.side, 24, "{shape:?}");
            assert!(img.hot < img.side, "{shape:?}: hotspot {} inside {} pt", img.hot, img.side);
            assert_eq!(img.rgba.len(), (img.side * img.side * 4) as usize);
        }
    }

    #[test]
    fn cursor_shapes_map() {
        assert_eq!(cursor_icon(DrawCursor::IBeam), CursorIcon::Text);
        assert_eq!(cursor_icon(DrawCursor::Arrow), CursorIcon::Default);
    }
}
