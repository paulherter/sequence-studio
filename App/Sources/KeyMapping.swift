import AppKit
import SQEditorUI

/// NSEvent <-> `Key` (physical key identity, ANSI positions, see `Key`). Layout independent on purpose:
/// the shortcut map is about key positions (J K L, I O), not characters.
enum KeyMapping {
    private static let codes: [UInt16: Key] = {
        var m: [UInt16: Key] = [:]
        let letters: [(UInt16, Character)] = [
            (0, "a"), (11, "b"), (8, "c"), (2, "d"), (14, "e"), (3, "f"), (5, "g"), (4, "h"), (34, "i"), (38, "j"),
            (40, "k"), (37, "l"), (46, "m"), (45, "n"), (31, "o"), (35, "p"), (12, "q"), (15, "r"), (1, "s"),
            (17, "t"), (32, "u"), (9, "v"), (13, "w"), (7, "x"), (16, "y"), (6, "z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
            (24, "="), (27, "-"), (30, "]"), (33, "["), (39, "'"), (41, ";"), (42, "\\"), (43, ","), (44, "/"),
            (47, "."), (50, "`"),
        ]
        for (code, c) in letters { m[code] = .char(c) }
        m[49] = .space
        m[123] = .left; m[124] = .right; m[125] = .down; m[126] = .up
        m[115] = .home; m[119] = .end
        m[51] = .delete; m[117] = .delete
        let fkeys: [(UInt16, Int)] = [(122, 1), (120, 2), (99, 3), (118, 4), (96, 5), (97, 6), (98, 7), (100, 8),
                                      (101, 9), (109, 10), (103, 11), (111, 12)]
        for (code, n) in fkeys { m[code] = .function(n) }
        return m
    }()

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var m: KeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }

    /// nil for keys without a `Key` (return, tab, escape, media keys...).
    static func keyEvent(from e: NSEvent) -> KeyEvent? {
        guard e.type == .keyDown || e.type == .keyUp, let key = codes[e.keyCode] else { return nil }
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
        case .delete: "\u{8}"
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

    /// "⇧⌘K" style text of a binding, for menu hints of keys that are not real key equivalents.
    static func hint(for b: KeyBinding) -> String {
        var s = ""
        if b.modifiers.contains(.control) { s += "⌃" }
        if b.modifiers.contains(.option) { s += "⌥" }
        if b.modifiers.contains(.shift) { s += "⇧" }
        if b.modifiers.contains(.command) { s += "⌘" }
        switch b.key {
        case .char(let c): s += String(c).uppercased()
        case .space: s += "Space"
        case .left: s += "←"
        case .right: s += "→"
        case .up: s += "↑"
        case .down: s += "↓"
        case .home: s += "Home"
        case .end: s += "End"
        case .delete: s += "⌫"
        case .function(let n): s += "F\(n)"
        }
        return s
    }
}
