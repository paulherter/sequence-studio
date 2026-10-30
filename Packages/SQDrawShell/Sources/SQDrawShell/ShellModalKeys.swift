import Foundation

extension ShellHost {
    /// True while a shell overlay owns the keyboard: a dialog, the shortcuts editor, the open menu, the start screen, Quick
    /// Apply or the export queue popover. The host routes every key to the shell first then, so the panels behind (the
    /// timeline's own Esc, letter shortcuts) do not see it.
    public var ownsKeyboard: Bool {
        dialog != nil || shortcutsEditor != nil || menuBar.controller.isOpen || isStartShown || quickApply != nil || queuePopover != nil
    }
}
