//! Input events of the portable UI (Swift `Input.swift`): the host maps its key codes and pointer data onto these.

use sq_uikit::controls_grid::{CGPoint, CGRect};

/// Keys the portable UI handles.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum InputKey {
    /// Space bar.
    Space,
    /// Cursor left.
    Left,
    /// Cursor right.
    Right,
    /// Cursor up.
    Up,
    /// Cursor down.
    Down,
    /// Home.
    Home,
    /// End.
    End,
    /// Forward delete.
    Delete,
    /// Backspace.
    Backspace,
    /// Escape.
    Escape,
    /// Return or Enter.
    Enter,
    /// Plus key.
    Plus,
    /// Minus key.
    Minus,
    /// Page up.
    PageUp,
    /// Page down.
    PageDown,
    /// F1...F12.
    Function(u8),
    /// Any other key by its character; Tab is `'\t'`.
    Character(char),
}

impl InputKey {
    /// Whether this key with `modifiers` is a chord of the app's menu while a text field has the keyboard (Export, Save, Group
    /// ...): Command (Ctrl on Windows and Linux) or the Mac's Control held with a key that is no text verb. Select all, copy,
    /// cut, paste, undo and redo, the cursor keys and the delete keys stay the field's; a field neither takes nor keeps the
    /// rest, so a menu shortcut works whatever field was typed in last.
    pub fn is_menu_chord(self, modifiers: InputModifiers) -> bool {
        // Option+Space is Quick Apply on the Mac; it types only a no-break space, so a field never keeps it.
        if self == InputKey::Space && modifiers.contains(InputModifiers::OPTION) {
            return true;
        }
        if !(modifiers.contains(InputModifiers::COMMAND) || modifiers.contains(InputModifiers::CONTROL)) {
            return false;
        }
        match self {
            InputKey::Character(c) => !matches!(c.to_ascii_lowercase(), 'a' | 'c' | 'v' | 'x' | 'z' | 'y' | '\t'),
            InputKey::Function(_)
            | InputKey::Plus
            | InputKey::Minus
            | InputKey::Space
            | InputKey::PageUp
            | InputKey::PageDown => true,
            InputKey::Left
            | InputKey::Right
            | InputKey::Up
            | InputKey::Down
            | InputKey::Home
            | InputKey::End
            | InputKey::Delete
            | InputKey::Backspace
            | InputKey::Escape
            | InputKey::Enter => false,
        }
    }
}

/// Modifier flags of a key or press (a bit set).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct InputModifiers(u8);

impl InputModifiers {
    /// No modifier.
    pub const NONE: InputModifiers = InputModifiers(0);
    /// Shift.
    pub const SHIFT: InputModifiers = InputModifiers(1);
    /// Ctrl on Windows, Command on the Mac: the command modifier of shortcuts.
    pub const COMMAND: InputModifiers = InputModifiers(2);
    /// Option or Alt.
    pub const OPTION: InputModifiers = InputModifiers(4);
    /// The secondary button (right click; Control-click on the Mac): the host sends a `MouseDown` with this flag and the
    /// matching `MouseUp` at once, so a panel opens its context menu on the press.
    pub const SECONDARY: InputModifiers = InputModifiers(8);
    /// The Control key as a shortcut modifier (Mac host only; Windows folds Ctrl into `COMMAND`).
    pub const CONTROL: InputModifiers = InputModifiers(16);

    /// Whether every flag of `other` is set.
    pub fn contains(self, other: InputModifiers) -> bool {
        self.0 & other.0 == other.0
    }
    /// The raw bits (Swift `rawValue`).
    pub fn bits(self) -> u8 {
        self.0
    }
}

impl std::ops::BitOr for InputModifiers {
    type Output = InputModifiers;
    fn bitor(self, rhs: InputModifiers) -> InputModifiers {
        InputModifiers(self.0 | rhs.0)
    }
}

/// One input event in pixels (y down).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum InputEvent {
    /// A button went down.
    MouseDown {
        /// Pointer x.
        x: f32,
        /// Pointer y.
        y: f32,
        /// Modifiers held.
        modifiers: InputModifiers,
    },
    /// The pointer moved with the button down.
    MouseDragged {
        /// Pointer x.
        x: f32,
        /// Pointer y.
        y: f32,
        /// Modifiers held now (not those of the press): a key pressed mid-drag shows here, the live keys Swift's hosts
        /// read from `NSEvent.modifierFlags` (Alt copies a dragged layer, Shift constrains a handle).
        modifiers: InputModifiers,
    },
    /// The button went up.
    MouseUp {
        /// Pointer x.
        x: f32,
        /// Pointer y.
        y: f32,
    },
    /// The pointer moved.
    MouseMoved {
        /// Pointer x.
        x: f32,
        /// Pointer y.
        y: f32,
    },
    /// Wheel: `dx`/`dy` in pixels with AppKit's `scrollingDelta` signs (positive dy = content moves down; lists scroll by
    /// `offset -= dy`). Device data is in [`crate::scroll::ScrollGesture`].
    Scroll {
        /// Pointer x.
        x: f32,
        /// Pointer y.
        y: f32,
        /// Horizontal delta.
        dx: f32,
        /// Vertical delta.
        dy: f32,
        /// Modifiers held.
        modifiers: InputModifiers,
    },
    /// A key went down.
    KeyDown {
        /// The key.
        key: InputKey,
        /// Modifiers held.
        modifiers: InputModifiers,
    },
}

impl InputEvent {
    /// A drag to (`x`, `y`) with no modifier held (tests and hosts that track no keys).
    pub fn dragged(x: f32, y: f32) -> InputEvent {
        InputEvent::MouseDragged { x, y, modifiers: InputModifiers::NONE }
    }

    /// Whether this event, which closes a light popover (a color picker, the curve popover, the export queue), is also
    /// taken. A press on the control that opened it (`opener`, window points; `scale` maps pixels to points) only closes
    /// it, so a second click there toggles. Any other press closes it and goes on to whatever is under the pointer, so
    /// one click on a chevron both closes the popover and folds the section. Esc is taken. Menus and sheets do not use
    /// this: a press outside them only closes them.
    pub fn closing_popover_is_taken(&self, scale: f32, opener: CGRect) -> bool {
        match *self {
            InputEvent::MouseDown { x, y, .. } => {
                let k = f64::from(scale);
                opener.contains(CGPoint::new(f64::from(x) / k, f64::from(y) / k))
            }
            _ => true,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn option_space_is_a_menu_chord_so_a_field_never_keeps_it() {
        assert!(InputKey::Space.is_menu_chord(InputModifiers::OPTION));
        assert!(!InputKey::Space.is_menu_chord(InputModifiers::NONE));
        assert!(!InputKey::Character('e').is_menu_chord(InputModifiers::OPTION), "Option letters still type");
    }

    #[test]
    fn a_menu_chord_is_a_command_key_that_is_no_text_verb() {
        let cmd = InputModifiers::COMMAND;
        assert!(InputKey::Character('m').is_menu_chord(cmd));
        assert!(InputKey::Character('m').is_menu_chord(cmd | InputModifiers::SHIFT));
        assert!(InputKey::Character('m').is_menu_chord(InputModifiers::CONTROL));
        assert!(InputKey::Function(9).is_menu_chord(cmd));
        for field_key in [
            InputKey::Character('a'),
            InputKey::Character('C'),
            InputKey::Character('v'),
            InputKey::Left,
            InputKey::Backspace,
        ] {
            assert!(!field_key.is_menu_chord(cmd), "{field_key:?} stays the field's");
        }
        assert!(!InputKey::Character('m').is_menu_chord(InputModifiers::NONE), "typing m");
        assert!(!InputKey::Character('m').is_menu_chord(InputModifiers::OPTION), "Option+m types a letter on the Mac");
    }

    #[test]
    fn a_press_closing_a_light_popover_is_taken_only_on_its_opener() {
        let opener = CGRect::new(100.0, 50.0, 20.0, 12.0);
        let down = |x: f32, y: f32| InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE };
        assert!(down(220.0, 112.0).closing_popover_is_taken(2.0, opener), "pixels map to points: on the opener");
        assert!(!down(400.0, 400.0).closing_popover_is_taken(2.0, opener), "elsewhere it goes on");
        let esc = InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE };
        assert!(esc.closing_popover_is_taken(1.0, opener), "Esc is taken");
    }

    #[test]
    fn modifiers_combine_and_test_like_an_option_set() {
        let m = InputModifiers::SHIFT | InputModifiers::COMMAND;
        assert!(m.contains(InputModifiers::SHIFT) && m.contains(InputModifiers::COMMAND));
        assert!(!m.contains(InputModifiers::OPTION));
        assert_eq!(m.bits(), 3);
        assert_eq!([1, 2, 4, 8, 16], [1u8, 2, 4, 8, 16].map(|b| InputModifiers(b).bits()));
    }
}
