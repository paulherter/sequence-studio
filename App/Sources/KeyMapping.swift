import AppKit
import SQEditorUI
import SQUIKit

/// NSEvent <-> `Key` (physical key identity, ANSI positions, see `Key`). Layout independent on purpose:
/// the shortcut map is about key positions (J K L, I O), not characters.
enum KeyMapping {
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }

    /// nil for keys without a `Key` (return, tab, escape, media keys...).
    /// Forward Delete acts as Delete until the user's map binds Forward Delete itself (`capture`: the shortcut window
    /// records the real key so it can be bound).
    static func keyEvent(from e: NSEvent, capture: Bool = false) -> KeyEvent? {
        guard e.type == .keyDown || e.type == .keyUp, var key = PhysicalKeys.codes[e.keyCode] else { return nil }
        if key == .forwardDelete, !capture, !CommandMap.current.entries.contains(where: { $0.binding.key == .forwardDelete }) {
            key = .delete
        }
        return KeyEvent(key, modifiers(e.modifierFlags), phase: e.type == .keyDown ? .down : .up,
                        isRepeat: e.type == .keyDown && e.isARepeat)
    }

    // MARK: Menu key equivalents

    private static func scalar(_ code: Int) -> String { String(UnicodeScalar(UInt32(code))!) }

    static func keyEquivalent(for key: Key) -> String? {
        switch key {
        case .char(let c): String(c)
        case .space: " "
        case .left: scalar(NSLeftArrowFunctionKey)
        case .right: scalar(NSRightArrowFunctionKey)
        case .up: scalar(NSUpArrowFunctionKey)
        case .down: scalar(NSDownArrowFunctionKey)
        case .home: scalar(NSHomeFunctionKey)
        case .end: scalar(NSEndFunctionKey)
        case .pageUp: scalar(NSPageUpFunctionKey)
        case .pageDown: scalar(NSPageDownFunctionKey)
        case .delete: "\u{8}"
        case .returnKey, .forwardDelete: nil   // never a menu key equivalent: a menu would take Return from every button and field
        case .function(let n): (1...12).contains(n) ? scalar(NSF1FunctionKey + n - 1) : nil
        }
    }

    static func modifierMask(_ m: KeyModifiers) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.command) { f.insert(.command) }
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.control) { f.insert(.control) }
        return f
    }

    /// "⇧⌘K" style text of a binding, for menu hints of keys that are not real key equivalents (portable: `KeyBindingText`).
    static func hint(for b: KeyBinding) -> String { KeyBindingText.mac(b) }
}
