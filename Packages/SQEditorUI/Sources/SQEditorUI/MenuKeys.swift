import Foundation

/// Which Command-key bindings belong to menu items (macOS fires those itself) and which the key router must handle.
public enum MenuKeys {
    /// Commands that live in menus the app builds itself (app menu) or whose items the app adds (Window panels).
    public static let appMenuCommands: [EditorCommand] = [.preferences, .keyboardShortcuts]

    /// Bindings carried by a visible menu item as its key equivalent (what `CommandMap.binding(for:)` gives the item).
    public static func owned(_ map: CommandMap, isVisible: (EditorCommand) -> Bool) -> Set<KeyBinding> {
        var cmds = EditorMenus.all.flatMap(\.commands).filter(isVisible)
        cmds += appMenuCommands
        cmds += EditorMenus.windowPanels.map(EditorCommand.focusPanel)
        return Set(cmds.compactMap(map.binding(for:)))
    }

    /// Commands that keep their standard meaning while a text field is edited. Everything else bound only to a
    /// Command-key combination in one panel scope (Cmd+K in the Timeline, Cmd+R ...) must not fire from a text field.
    public static let textEditing: Set<EditorCommand> = [.undo, .redo, .cut, .copy, .paste, .delete, .deleteProjectItems, .selectAll]

    /// True when a menu item for `c` must be disabled while the user types: a Command shortcut that only exists in a
    /// panel scope (not global) would otherwise act on timeline clips from inside a text field.
    public static func blockedWhileTyping(_ c: EditorCommand, _ map: CommandMap) -> Bool {
        if textEditing.contains(c) { return false }
        let own = map.entries.filter { $0.command == c }
        guard !own.isEmpty, own.allSatisfy({ $0.scope != .global }) else { return false }
        return own.contains { $0.binding.modifiers.contains(.command) }
    }
}
