import Foundation

/// Which key caps the shortcut text names. The key map itself is one table for both systems (`CommandMap`): on Windows the
/// Command modifier is Ctrl and Option is Alt (DECISIONS "Windows key map").
public enum KeyPlatform: Sendable, Equatable {
    case mac, windows

    #if os(Windows)
    public static let current = KeyPlatform.windows
    #else
    public static let current = KeyPlatform.mac
    #endif
}

/// The text of a key binding: "⇧⌘K" on the Mac (`KeyMapping.hint`, moved here), "Ctrl+Shift+K" on Windows.
public enum KeyBindingText {
    public static func text(_ b: KeyBinding, platform: KeyPlatform = .current) -> String {
        switch platform {
        case .mac: mac(b)
        case .windows: windows(b)
        }
    }

    /// "⇧⌘K" style text of a binding, for menu hints of keys that are not real key equivalents.
    public static func mac(_ b: KeyBinding) -> String {
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
        case .pageUp: s += "Page Up"
        case .pageDown: s += "Page Down"
        case .delete: s += "⌫"
        case .returnKey: s += "↩"
        case .forwardDelete: s += "⌦"
        case .function(let n): s += "F\(n)"
        }
        return s
    }

    /// The binding of a `mac(_:)` text ("⇧⌘K" -> K with Shift and Command); nil for any other text. The Mac system
    /// menu bar reads the shared menu rows' shortcut texts back into key equivalents with it.
    public static func parseMac(_ text: String) -> KeyBinding? {
        var m: KeyModifiers = []
        var rest = Substring(text)
        let marks: [(Character, KeyModifiers)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
        while let first = rest.first, let mod = marks.first(where: { $0.0 == first })?.1 { m.insert(mod); rest = rest.dropFirst() }
        let named: [String: Key] = ["Space": .space, "←": .left, "→": .right, "↑": .up, "↓": .down, "Home": .home, "End": .end,
                                    "Page Up": .pageUp, "Page Down": .pageDown, "⌫": .delete, "↩": .returnKey, "⌦": .forwardDelete]
        let k = String(rest)
        if let key = named[k] { return KeyBinding(key, m) }
        if k.count > 1, k.first == "F", let n = Int(k.dropFirst()) { return KeyBinding(.function(n), m) }
        guard k.count == 1, let c = k.lowercased().first else { return nil }
        return KeyBinding(.char(c), m)
    }

    /// Windows order and names: Ctrl+Alt+Shift+Key. The Mac Control modifier also reads as Ctrl (see `WindowsKeyRoute`).
    public static func windows(_ b: KeyBinding) -> String {
        var parts: [String] = []
        if b.modifiers.contains(.command) || b.modifiers.contains(.control) { parts.append("Ctrl") }
        if b.modifiers.contains(.option) { parts.append("Alt") }
        if b.modifiers.contains(.shift) { parts.append("Shift") }
        let key: String = switch b.key {
        case .char(let c): String(c) == "ß" ? "ß" : String(c).uppercased()
        case .space: "Space"
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "PgUp"
        case .pageDown: "PgDn"
        case .delete: "Backspace"
        case .returnKey: "Enter"
        case .forwardDelete: "Del"
        case .function(let n): "F\(n)"
        }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}

/// How a Windows key press finds its binding in the one key map. Windows has Ctrl, Alt, Shift (the Windows key belongs to
/// the system), the Mac has Command, Option, Shift and Control. Ctrl stands for Command first and for the Mac Control
/// modifier second; Ctrl+Alt also reaches Control+Command bindings last. Backspace and Del both delete like the Mac Delete
/// key unless the map binds Forward Delete itself (the Mac rule of `KeyMapping.keyEvent`).
public enum WindowsKeyRoute {
    /// Windows modifiers in Mac terms: `.command` = Ctrl, `.option` = Alt, `.shift` = Shift (what the host reports).
    public static func candidates(_ key: Key, ctrl: Bool, alt: Bool, shift: Bool) -> [KeyBinding] {
        var base: KeyModifiers = []
        if alt { base.insert(.option) }
        if shift { base.insert(.shift) }
        guard ctrl else { return [KeyBinding(key, base)] }
        return [KeyBinding(key, base.union(.command)), KeyBinding(key, base.union(.control)),
                KeyBinding(key, base.union([.command, .control]))]
    }

    /// The command a Windows key press runs in `focus`, or nil. Focus-scoped bindings win over global ones per candidate.
    public static func command(_ key: Key, ctrl: Bool, alt: Bool, shift: Bool, focus: PanelID?, map: CommandMap) -> EditorCommand? {
        var k = key
        if k == .forwardDelete, !map.entries.contains(where: { $0.binding.key == .forwardDelete }) { k = .delete }
        for b in candidates(k, ctrl: ctrl, alt: alt, shift: shift) {
            if let c = map.command(for: b, focus: focus) { return c }
        }
        return nil
    }

    /// Bindings a Windows keyboard cannot reach: a Control binding whose Ctrl twin (same key, Command instead of Control) is
    /// bound in the same scope or globally. They stay reachable from the menus and Quick Apply.
    public static func shadowed(_ map: CommandMap) -> [CommandMap.Entry] {
        let keys = Set(map.entries.map { ScopedBinding(scope: $0.scope, binding: $0.binding) })
        func bound(_ scope: CommandScope, _ b: KeyBinding) -> Bool {
            keys.contains(ScopedBinding(scope: scope, binding: b)) || keys.contains(ScopedBinding(scope: .global, binding: b))
        }
        return map.entries.filter { e in
            let m = e.binding.modifiers
            guard m.contains(.control) else { return false }
            var twin = m
            twin.remove(.control)
            twin.insert(.command)
            if m.contains(.command) {
                // Control+Command: reached only when neither Ctrl twin is bound.
                var a = m; a.remove(.control)
                var c = m; c.remove(.command)
                return bound(e.scope, KeyBinding(e.binding.key, a)) || bound(e.scope, KeyBinding(e.binding.key, c))
            }
            return bound(e.scope, KeyBinding(e.binding.key, twin))
        }
    }

    private struct ScopedBinding: Hashable { var scope: CommandScope; var binding: KeyBinding }
}
