// Swift: ShellModalKeys.swift
//! Which shell overlays own the keyboard.

use crate::shell_host::ShellHost;

impl ShellHost {
    /// True while a shell overlay owns the keyboard: a dialog, the shortcuts editor, the open menu, the start screen, Quick
    /// Apply or the export queue popover. The host routes every key to the shell first then, so the panels behind (the
    /// timeline's own Esc, letter shortcuts) do not see it.
    pub fn owns_keyboard(&self) -> bool {
        self.dialog().is_some()
            || self.shortcuts.is_some()
            || self.export.popover.is_some()
            || self.menu_bar.controller.is_open()
            || self.is_start_shown()
            || self.quick_apply.is_some()
    }
}
