import AppKit

/// Tooltip text convention (INTERACTION-AUDIT §9): the control's name plus its key, "Name (Key)"; just the name when it
/// has no key. Never a sentence: explanations belong in DESIGN.md or the status line, so a trailing period is dropped.
/// Keys come from the live `CommandMap`, so a rebinding never leaves a stale tooltip.
public enum Tooltip {
    /// "Mark In (I)"; "Snap" when `shortcut` is nil or empty.
    public static func text(_ name: String, shortcut: String?) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.hasSuffix("."), !n.hasSuffix("..") { n.removeLast() }
        guard let k = shortcut?.trimmingCharacters(in: .whitespaces), !k.isEmpty else { return n }
        return "\(n) (\(k))"
    }

    /// Name plus the binding's display text ("⇧⌘Z").
    public static func text(_ name: String, binding: KeyBinding?) -> String {
        text(name, shortcut: binding.map { KeyboardListing.text(for: $0) })
    }

    /// Name plus the command's current key.
    public static func text(_ name: String, command: EditorCommand, map: CommandMap = .current) -> String {
        text(name, binding: map.binding(for: command))
    }
}

public extension NSView {
    /// Sets `toolTip` by the convention (name plus the command's key, when given).
    @MainActor func setTooltip(_ name: String, command: EditorCommand? = nil) {
        sqToolTip = command.map { Tooltip.text(name, command: $0) } ?? Tooltip.text(name, shortcut: nil)
    }
}
