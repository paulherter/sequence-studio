import Foundation
import SQCore
import SQUIKit

/// One key cap on the picture, in points.
public struct KeyCap: Equatable, Sendable {
    public var label: String
    /// nil for caps the key map cannot bind (Tab, Caps Lock, Return, modifiers): drawn plain, not selectable.
    public var key: Key?
    public var x: Double, y: Double, w: Double, h: Double
    /// An empty cap (the upper half of the ISO Return key): not drawn, not selectable.
    public var isGhost = false
}

/// Keyboard geometry of the Keyboard Shortcuts window (design board "Windows": 50 x 42 keys, 6 pt gaps, every row centered).
/// The picture follows the chosen layout: the labels (and so the characters a binding is looked up by) move with it.
public enum KeyboardLayout {
    public enum Style: String, CaseIterable, Sendable {
        case us, german

        /// Popup title ("Layout: German").
        public var title: String { "Layout: " + (self == .us ? "US" : "German") }


        public static let defaultsKey = "sq.shortcuts.keyboardLayout"

        /// Saved choice (`sq.shortcuts.keyboardLayout`), else the system's.
        @MainActor public static func saved(_ d: UserDefaults = .standard) -> Style {
            d.string(forKey: defaultsKey).flatMap(Style.init(rawValue:)) ?? system
        }
    }

    public static let keyWidth = 50.0
    public static let keyHeight = 42.0
    public static let gap = 6.0
    public static let width = 840.0
    public static let height = 5 * keyHeight + 4 * gap

    private typealias Cap = (label: String, key: Key?, width: Double)

    /// One letter row: optional lead cap, the character keys, tail cap; `ghostTail` = invisible (ISO Return, upper half).
    private struct Spec {
        var lead: Cap?
        var keys: [String]
        var tail: Cap
        var ghostTail = false
    }

    private static func letters(_ s: String) -> [String] { s.map(String.init) }

    private static func rows(_ style: Style) -> [Spec] {
        switch style {
        case .german:
            return [
                Spec(keys: ["^", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "ß", "´"], tail: ("⌫", .delete, 78)),
                Spec(lead: ("⇥", nil, 62), keys: letters("QWERTZUIOP") + ["Ü", "+"], tail: ("", nil, 72), ghostTail: true),
                Spec(lead: ("⇪", nil, 74), keys: letters("ASDFGHJKL") + ["Ö", "Ä", "#"], tail: ("↩", nil, 60)),
                Spec(lead: ("⇧", nil, 70), keys: ["<"] + letters("YXCVBNM") + [",", ".", "-"], tail: ("⇧", nil, 64)),
            ]
        case .us:
            return [
                Spec(keys: ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="], tail: ("⌫", .delete, 78)),
                Spec(lead: ("⇥", nil, 62), keys: letters("QWERTYUIOP") + ["[", "]"], tail: ("\\", .char("\\"), 72)),
                Spec(lead: ("⇪", nil, 74), keys: letters("ASDFGHJKL") + [";", "'"], tail: ("↩", nil, 84)),
                Spec(lead: ("⇧", nil, 112), keys: letters("ZXCVBNM") + [",", ".", "/"], tail: ("⇧", nil, 112)),
            ]
        }
    }

    public static func caps(_ style: Style) -> [KeyCap] {
        var out: [KeyCap] = []
        func place(_ r: Int, _ items: [(cap: Cap, ghost: Bool)]) {
            let total = items.reduce(0) { $0 + $1.cap.width } + gap * Double(items.count - 1)
            var x = (width - total) / 2
            let y = Double(r) * (keyHeight + gap)
            for item in items {
                var c = KeyCap(label: item.cap.label, key: item.cap.key, x: x, y: y, w: item.cap.width, h: keyHeight)
                c.isGhost = item.ghost
                out.append(c)
                x += item.cap.width + gap
            }
        }
        for (r, spec) in rows(style).enumerated() {
            var items: [(cap: Cap, ghost: Bool)] = []
            if let l = spec.lead { items.append((l, false)) }
            for k in spec.keys { items.append(((k, Key.char(Character(k.lowercased())), keyWidth), false)) }
            items.append((spec.tail, spec.ghostTail))
            place(r, items)
        }
        let bottom: [Cap] = [("fn", nil, 56), ("⌃", nil, 56), ("⌥", nil, 56), ("⌘", nil, 70), ("Space", .space, 232), ("⌘", nil, 60),
                             ("⌥", nil, 50), ("←", .left, 50), ("↑", .up, 50), ("↓", .down, 50), ("→", .right, 50)]
        place(4, bottom.map { ($0, false) })
        return out
    }
}

/// What the picture shows for a modifier layer: which commands each key runs.
public struct KeyboardLayoutModel: Sendable {
    public var map: CommandMap
    public var modifiers: KeyModifiers

    public init(map: CommandMap, modifiers: KeyModifiers = []) { self.map = map; self.modifiers = modifiers }

    /// Bindings of `key` with the current modifiers, any scope; global first.
    public func entries(for key: Key) -> [CommandMap.Entry] {
        let b = KeyBinding(key, modifiers)
        return map.entries.filter { $0.binding == b }.sorted { ($0.scope == .global ? 0 : 1) < ($1.scope == .global ? 0 : 1) }
    }

    /// Color group of a key (the first binding wins); nil when the key is free in this layer.
    public func group(for key: Key) -> KeyGroup? { entries(for: key).first.map { KeyGroup.of($0.command) } }

    /// One-line description for the info label, e.g. "C: Blade Tool (Everywhere)".
    public func summary(for key: Key, platform: KeyPlatform = .mac) -> String {
        let text = KeyBindingText.text(KeyBinding(key, modifiers), platform: platform)
        let es = entries(for: key)
        guard !es.isEmpty else { return "\(text): free" }
        return text + ": " + es.map { "\($0.command.title) (\(KeyboardListing.scopeName($0.scope)))" }.joined(separator: ", ")
    }
}

#if !canImport(AppKit)
extension KeyboardLayout.Style {
    /// The keyboard layout off the Mac: the region of the user's locale (German, Austrian, Swiss: German), else US.
    /// shortcut: reads the locale, not the active Windows keyboard layout (GetKeyboardLayout); upgrade with that.
    @MainActor public static var system: KeyboardLayout.Style {
        ["DE", "AT", "CH"].contains(Locale.current.region?.identifier ?? "") ? .german : .us
    }
}
#endif
