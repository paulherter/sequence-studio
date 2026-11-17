//! The shell's menu model as the system bar needs it: plain data that compares for equality (the bar is rebuilt only when it
//! changes) and the closures of the rows kept apart in a list indexed by slot.

use sq_draw_shell::ShellMenu;
use sq_uikit::key_binding::{Key, KeyModifiers};
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuItemKind};
use std::rc::Rc;

/// One top-level menu.
#[derive(Clone, Debug, PartialEq)]
pub struct NativeMenu {
    /// Shown title.
    pub title: String,
    /// The rows.
    pub items: Vec<NativeItem>,
}

/// One entry of a menu.
#[derive(Clone, Debug, PartialEq)]
pub enum NativeItem {
    /// A divider.
    Separator,
    /// A disabled label.
    Header(String),
    /// A row.
    Row(Row),
    /// A submenu.
    Sub {
        /// Shown title.
        title: String,
        /// Whether it opens.
        enabled: bool,
        /// The rows.
        items: Vec<NativeItem>,
    },
}

/// What the system does for a row instead of the app.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// The row's own action runs.
    Action,
    /// The system's Hide, Hide Others, Show All, Minimize, Zoom, Bring All to Front.
    Hide,
    HideOthers,
    ShowAll,
    Minimize,
    Zoom,
    BringAllToFront,
}

/// An action row.
#[derive(Clone, Debug, PartialEq)]
pub struct Row {
    /// Index into the action list returned with the menus; also the id of the native item.
    pub slot: usize,
    /// Shown title.
    pub title: String,
    /// The key equivalent the row shows and answers to.
    pub shortcut: Option<Shortcut>,
    /// Whether the row can be picked.
    pub enabled: bool,
    /// Check mark.
    pub checked: bool,
    /// The system behavior, if the system owns the row.
    pub role: Role,
}

/// A key equivalent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Shortcut {
    /// Control.
    pub control: bool,
    /// Option.
    pub option: bool,
    /// Shift.
    pub shift: bool,
    /// Command.
    pub command: bool,
    /// The key.
    pub key: ShortcutKey,
}

/// The key of a [`Shortcut`] (lower case for letters).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShortcutKey {
    Char(char),
    Space,
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    Delete,
    Return,
    ForwardDelete,
    Function(i64),
}

/// The actions of the rows by slot (`None` for a row without one).
pub type Actions = Vec<Option<Rc<dyn Fn()>>>;

/// Translates the shell menus. Second result: the action of each row by slot (`None` for a row without one).
pub fn translate(menus: &[ShellMenu]) -> (Vec<NativeMenu>, Actions) {
    let mut actions = Vec::new();
    let native =
        menus.iter().map(|m| NativeMenu { title: m.title.clone(), items: items(&m.items, &mut actions) }).collect();
    (native, actions)
}

fn items(rows: &[SQMenuItem], actions: &mut Actions) -> Vec<NativeItem> {
    rows.iter()
        .map(|r| match r.kind {
            SQMenuItemKind::Separator => NativeItem::Separator,
            SQMenuItemKind::Header | SQMenuItemKind::Caption => NativeItem::Header(r.title.clone()),
            SQMenuItemKind::Action => match &r.submenu {
                Some(sub) => {
                    NativeItem::Sub { title: r.title.clone(), enabled: r.is_enabled, items: items(sub, actions) }
                }
                None => {
                    let slot = actions.len();
                    actions.push(r.action.clone());
                    NativeItem::Row(Row {
                        slot,
                        title: r.title.clone(),
                        shortcut: shortcut(&r.shortcut),
                        enabled: r.is_enabled && r.action.is_some(),
                        checked: r.is_checked,
                        role: role(&r.title),
                    })
                }
            },
        })
        .collect()
}

// shortcut: the system rows are recognized by their English titles; the model carries no role, and its titles are English
// until the app is localized. Upgrade: give `SQMenuItem` an optional role next to `action`.
fn role(title: &str) -> Role {
    match title {
        "Hide Sequence Studio" => Role::Hide,
        "Hide Others" => Role::HideOthers,
        "Show All" => Role::ShowAll,
        "Minimize" => Role::Minimize,
        "Zoom" => Role::Zoom,
        "Bring All to Front" => Role::BringAllToFront,
        _ => Role::Action,
    }
}

/// The key equivalent of a row's shortcut text. Keys without Command or Control are not equivalents (a bare Space or
/// Delete would steal typing from text fields); those rows show no shortcut in the system bar and the key keeps going
/// through the window.
fn shortcut(text: &str) -> Option<Shortcut> {
    let b = KeyBindingText::parse_mac(text)?;
    if !b.modifiers.contains(KeyModifiers::COMMAND) && !b.modifiers.contains(KeyModifiers::CONTROL) {
        return None;
    }
    let key = match b.key {
        Key::Char(c) => ShortcutKey::Char(c),
        Key::Space => ShortcutKey::Space,
        Key::Left => ShortcutKey::Left,
        Key::Right => ShortcutKey::Right,
        Key::Up => ShortcutKey::Up,
        Key::Down => ShortcutKey::Down,
        Key::Home => ShortcutKey::Home,
        Key::End => ShortcutKey::End,
        Key::PageUp => ShortcutKey::PageUp,
        Key::PageDown => ShortcutKey::PageDown,
        Key::Delete => ShortcutKey::Delete,
        Key::ReturnKey => ShortcutKey::Return,
        Key::ForwardDelete => ShortcutKey::ForwardDelete,
        Key::Function(n) => ShortcutKey::Function(n),
    };
    Some(Shortcut {
        control: b.modifiers.contains(KeyModifiers::CONTROL),
        option: b.modifiers.contains(KeyModifiers::OPTION),
        shift: b.modifiers.contains(KeyModifiers::SHIFT),
        command: b.modifiers.contains(KeyModifiers::COMMAND),
        key,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    fn row(title: &str, shortcut: &str, enabled: bool, checked: bool) -> SQMenuItem {
        let mut r = SQMenuItem::new(title);
        r.shortcut = shortcut.to_string();
        r.is_enabled = enabled;
        r.is_checked = checked;
        r.action = Some(Rc::new(|| {}));
        r
    }

    #[test]
    fn rows_keep_state_shortcut_and_slots() {
        let mut sub = SQMenuItem::new("More");
        sub.submenu = Some(vec![row("Deep", "⌘1", true, false)]);
        let menus = vec![ShellMenu::new(
            "Edit",
            vec![
                row("Paste", "⇧⌘V", false, false),
                SQMenuItem::separator(),
                row("Safe Margins", "", true, true),
                sub,
                row("Hide Others", "⌥⌘H", true, false),
                row("Play", "Space", true, false),
            ],
        )];
        let (native, actions) = translate(&menus);
        assert_eq!(actions.len(), 5);
        let NativeItem::Row(paste) = &native[0].items[0] else { panic!("row") };
        assert_eq!((paste.slot, paste.enabled), (0, false));
        let s = paste.shortcut.expect("shortcut");
        assert!(s.shift && s.command && !s.option && s.key == ShortcutKey::Char('v'));
        assert_eq!(native[0].items[1], NativeItem::Separator);
        let NativeItem::Row(margins) = &native[0].items[2] else { panic!("row") };
        assert!(margins.checked && margins.shortcut.is_none());
        let NativeItem::Sub { items, .. } = &native[0].items[3] else { panic!("sub") };
        let NativeItem::Row(deep) = &items[0] else { panic!("row") };
        assert_eq!(deep.slot, 2);
        let NativeItem::Row(hide) = &native[0].items[4] else { panic!("row") };
        assert_eq!(hide.role, Role::HideOthers);
        let NativeItem::Row(play) = &native[0].items[5] else { panic!("row") };
        assert_eq!(play.shortcut, None, "a bare key is no key equivalent");
    }

    #[test]
    fn equal_models_compare_equal_and_actions_are_kept() {
        let hit = Rc::new(Cell::new(0));
        let h = Rc::clone(&hit);
        let mut r = row("Undo", "⌘Z", true, false);
        r.action = Some(Rc::new(move || h.set(h.get() + 1)));
        let menus = vec![ShellMenu::new("Edit", vec![r])];
        let (a, actions) = translate(&menus);
        let (b, _) = translate(&menus);
        assert_eq!(a, b);
        actions[0].as_ref().expect("action")();
        assert_eq!(hit.get(), 1);
        let mut off = menus.clone();
        off[0].items[0].is_enabled = false;
        assert_ne!(translate(&off).0, a);
    }
}
