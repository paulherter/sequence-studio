import Foundation

/// Physical-ish key identity. Letters are lowercase; digits and symbols name the key cap without Shift
/// (Shift+1 is `.char("1")` + `.shift`). The AppKit adapter maps key codes to this, not characters.
public enum Key: Sendable, Hashable {
    case char(Character)
    case space, left, right, up, down, home, end, delete
    case function(Int)
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let shift = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
}

public struct KeyBinding: Sendable, Hashable {
    public var key: Key
    public var modifiers: KeyModifiers
    public init(_ key: Key, _ modifiers: KeyModifiers = []) { self.key = key; self.modifiers = modifiers }
}

public struct KeyEvent: Sendable, Hashable {
    public enum Phase: Sendable, Hashable { case down, up }
    public var key: Key
    public var modifiers: KeyModifiers
    public var phase: Phase
    public var isRepeat: Bool
    public init(_ key: Key, _ modifiers: KeyModifiers = [], phase: Phase = .down, isRepeat: Bool = false) {
        self.key = key; self.modifiers = modifiers; self.phase = phase; self.isRepeat = isRepeat
    }
    public var binding: KeyBinding { KeyBinding(key, modifiers) }
}
