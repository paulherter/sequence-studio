import Foundation
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

/// Where the keyboard has a key code: the physical (ANSI position) identity the shortcut map uses, shared by the
/// app's key event adapter and the shortcut import.
public enum PhysicalKeys {
    public static let codes: [UInt16: Key] = {
        var m: [UInt16: Key] = [:]
        let letters: [(UInt16, Character)] = [
            (0, "a"), (11, "b"), (8, "c"), (2, "d"), (14, "e"), (3, "f"), (5, "g"), (4, "h"), (34, "i"), (38, "j"),
            (40, "k"), (37, "l"), (46, "m"), (45, "n"), (31, "o"), (35, "p"), (12, "q"), (15, "r"), (1, "s"),
            (17, "t"), (32, "u"), (9, "v"), (13, "w"), (7, "x"), (16, "y"), (6, "z"),
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
            (24, "="), (27, "-"), (30, "]"), (33, "["), (39, "'"), (41, ";"), (42, "\\"), (43, ","), (44, "/"),
            (47, "."), (50, "`"),
            (10, "<"),   // the extra key left of Z/Y on ISO and JIS keyboards (German "<>|"); has no ANSI counterpart
        ]
        for (code, c) in letters { m[code] = .char(c) }
        m[49] = .space
        m[123] = .left; m[124] = .right; m[125] = .down; m[126] = .up
        m[115] = .home; m[119] = .end; m[116] = .pageUp; m[121] = .pageDown
        m[51] = .delete; m[117] = .forwardDelete
        m[36] = .returnKey; m[76] = .returnKey
        let fkeys: [(UInt16, Int)] = [(122, 1), (120, 2), (99, 3), (118, 4), (96, 5), (97, 6), (98, 7), (100, 8),
                                      (101, 9), (109, 10), (103, 11), (111, 12)]
        for (code, n) in fkeys { m[code] = .function(n) }
        return m
    }()
}

/// The key a typed character sits on, and whether Shift has to be held to type it.
public struct KeyCharacterResolution: Sendable, Equatable {
    public var key: Key
    public var needsShift: Bool
    public init(key: Key, needsShift: Bool) { self.key = key; self.needsShift = needsShift }
}

/// Turns the character another program stored for a shortcut ("ß", "+", "ö") into the physical key our map binds.
/// A Final Cut command set names keys by the character on the keycap, so on a German keyboard Trim Start is "ß" while
/// our map (and the key event adapter) knows key positions: the character has to go through the keyboard layout.
public struct KeyCharacterResolver: Sendable {
    public var resolve: @Sendable (Character) -> KeyCharacterResolution?
    public init(_ resolve: @escaping @Sendable (Character) -> KeyCharacterResolution?) { self.resolve = resolve }

    /// A table of characters, lower-case letters first (see `layout(table:)`).
    public static func table(_ t: [Character: KeyCharacterResolution]) -> KeyCharacterResolver {
        KeyCharacterResolver { c in t[c] ?? t[Character(String(c).lowercased())] }
    }

    /// US keyboard: letters, digits and the unshifted symbols are themselves, shifted symbols sit on their key plus Shift.
    public static let us: KeyCharacterResolver = {
        var t: [Character: KeyCharacterResolution] = [:]
        for (_, key) in PhysicalKeys.codes { if case .char(let c) = key, c != "<" { t[c] = .init(key: key, needsShift: false) } }
        let shifted: [(Character, Character)] = [
            ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"), ("^", "6"), ("&", "7"), ("*", "8"), ("(", "9"), (")", "0"),
            ("_", "-"), ("+", "="), ("{", "["), ("}", "]"), ("|", "\\"), (":", ";"), ("\"", "'"), ("<", ","), (">", "."),
            ("?", "/"), ("~", "`"),
        ]
        for (c, base) in shifted { t[c] = .init(key: .char(base), needsShift: true) }
        return table(t)
    }()

    /// The layout the Mac is typing with now (German, French, Dvorak ...); characters it cannot type fall back to `us`.
    public static func currentLayout() -> KeyCharacterResolver {
        #if !canImport(Carbon)
        // shortcut: US layout off the Mac (no Text Input Sources), upgrade with the Windows keyboard layout (ToUnicodeEx).
        return .us
        #else
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return .us }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return .us }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let kbdType = UInt32(LMGetKbdType())
        var t: [Character: KeyCharacterResolution] = [:]
        // Unshifted first so a character that exists both ways keeps the plain key.
        for shift in [false, true] {
            for (code, key) in PhysicalKeys.codes.sorted(by: { $0.key < $1.key }) {
                guard case .char = key else { continue }
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let modifierState = UInt32(shift ? (shiftKey >> 8) & 0xFF : 0)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifierState, kbdType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
                guard status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]), !scalar.properties.isWhitespace,
                      scalar.value >= 0x20 else { continue }
                let c = Character(String(scalar).lowercased())
                if t[c] == nil { t[c] = .init(key: key, needsShift: shift) }
            }
        }
        let own = table(t)
        let us = KeyCharacterResolver.us
        return KeyCharacterResolver { c in own.resolve(c) ?? us.resolve(c) }
        #endif
    }
}
