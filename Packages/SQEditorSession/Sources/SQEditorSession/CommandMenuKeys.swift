import AppKit
import SQUIKit

/// Shows a command's key in a context menu item, read from the key map so rebinding cannot make it stale
/// (INTERACTION-AUDIT §5). The item only displays the key; the menu action still runs the command.
public enum CommandMenuKeys {
    /// Shortcut text of an editor command in the current key map ("" when unbound or not showable).
    @MainActor public static func shortcut(_ command: EditorCommand, map: CommandMap = .current) -> String {
        guard let b = map.binding(for: command), let e = equivalent(for: b) else { return "" }
        return SQMenuShortcut.glyphs(key: e.key, modifiers: e.modifiers)
    }

    /// AppKit key equivalent (character + modifiers) of a binding; nil for keys a menu cannot show (arrows, function keys).
    public static func equivalent(for b: KeyBinding) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        var mods: NSEvent.ModifierFlags = []
        if b.modifiers.contains(.command) { mods.insert(.command) }
        if b.modifiers.contains(.shift) { mods.insert(.shift) }
        if b.modifiers.contains(.option) { mods.insert(.option) }
        if b.modifiers.contains(.control) { mods.insert(.control) }
        switch b.key {
        case .char(let c): return (String(c), mods)
        case .space: return (" ", mods)
        case .delete: return ("\u{8}", mods)
        default: return nil
        }
    }

    /// Sets `item`'s key equivalent from `command`'s binding in `map` (no binding: the item is left as it is).
    @MainActor
    public static func apply(_ command: EditorCommand, to item: NSMenuItem, map: CommandMap = .current) {
        guard let b = map.binding(for: command), let e = equivalent(for: b) else { return }
        item.keyEquivalent = e.key
        item.keyEquivalentModifierMask = e.modifiers
    }
}
