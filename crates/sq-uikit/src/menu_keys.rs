// Swift: MenuKeys.swift
//! Which Command-key bindings belong to menu items (macOS fires those itself) and which the key router must handle.

use crate::command_map::CommandMap;
use crate::editor_command::{CommandScope, EditorCommand};
use crate::key_binding::{KeyBinding, KeyModifiers};
use crate::menu_spec::EditorMenus;
use std::collections::HashSet;
use std::sync::OnceLock;

/// Which Command-key bindings belong to menu items.
pub enum MenuKeys {}

impl MenuKeys {
    /// Commands that live in menus the app builds itself (app menu, Window > Workspaces > Reset) or whose items the app adds (Window panels).
    pub const APP_MENU_COMMANDS: [EditorCommand; 3] =
        [EditorCommand::Preferences, EditorCommand::KeyboardShortcuts, EditorCommand::ResetLayout];

    /// Bindings carried by a visible menu item as its key equivalent (what `CommandMap::binding_for` gives the item).
    pub fn owned(map: &CommandMap, is_visible: impl Fn(EditorCommand) -> bool) -> HashSet<KeyBinding> {
        // `visible`: a command left out of the menu bar keeps its key, the key router handles it.
        let mut cmds: Vec<EditorCommand> =
            EditorMenus::visible().iter().flat_map(|m| m.commands()).filter(|c| is_visible(*c)).collect();
        cmds.extend(Self::APP_MENU_COMMANDS);
        cmds.extend(EditorMenus::window_panels().iter().map(|p| EditorCommand::FocusPanel(*p)));
        cmds.into_iter().filter_map(|c| map.binding_for(&c)).collect()
    }

    /// Commands that keep their standard meaning while a text field is edited. Everything else bound only to a
    /// Command-key combination in one panel scope (Cmd+K in the Timeline, Cmd+R ...) must not fire from a text field.
    pub fn text_editing() -> &'static HashSet<EditorCommand> {
        static SET: OnceLock<HashSet<EditorCommand>> = OnceLock::new();
        SET.get_or_init(|| {
            use EditorCommand as C;
            HashSet::from([C::Undo, C::Redo, C::Cut, C::Copy, C::Paste, C::Delete, C::DeleteProjectItems, C::SelectAll])
        })
    }

    /// True when a menu item for `c` must be disabled while the user types: a Command shortcut that only exists in a
    /// panel scope (not global) would otherwise act on timeline clips from inside a text field.
    pub fn blocked_while_typing(c: &EditorCommand, map: &CommandMap) -> bool {
        if Self::text_editing().contains(c) {
            return false;
        }
        let own: Vec<_> = map.entries.iter().filter(|e| e.command == *c).collect();
        if own.is_empty() || !own.iter().all(|e| e.scope != CommandScope::Global) {
            return false;
        }
        own.iter().any(|e| e.binding.modifiers.contains(KeyModifiers::COMMAND))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn panel_scoped_command_shortcuts_are_blocked_while_typing() {
        let map = CommandMap::premiere_default();
        // Cmd+K in the Timeline is Add Edit and exists in no other scope.
        assert!(MenuKeys::blocked_while_typing(&EditorCommand::AddEdit, &map));
        // Cut/Copy/Paste keep their meaning in a text field, and Save is global.
        assert!(!MenuKeys::blocked_while_typing(&EditorCommand::Paste, &map));
        assert!(!MenuKeys::blocked_while_typing(&EditorCommand::Save, &map));
        // A command without any binding is not blocked.
        assert!(!MenuKeys::blocked_while_typing(&EditorCommand::Revert, &map));
    }

    #[test]
    fn owned_bindings_include_menu_and_app_menu_keys() {
        let map = CommandMap::premiere_default();
        let owned = MenuKeys::owned(&map, |_| true);
        let preferences = map.binding_for(&EditorCommand::Preferences);
        assert!(preferences.is_some_and(|b| owned.contains(&b)));
        let save = map.binding_for(&EditorCommand::Save);
        assert!(save.is_some_and(|b| owned.contains(&b)));
        // A command hidden by the caller keeps its key for the router.
        let hidden = MenuKeys::owned(&map, |c| c != EditorCommand::Save);
        assert!(save.is_some_and(|b| !hidden.contains(&b)));
    }
}
