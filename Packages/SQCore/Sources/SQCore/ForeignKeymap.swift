import Foundation

// Foreign keyboard sets (docs/KEYMAP.md "Templates and import"). Pure: no AppKit, no editor types. A foreign file is read into
// neutral chords (`ForeignChord`) plus the other program's command ids; `ForeignKeymap.translate` maps those ids to our
// stable command ids (`EditorCommand.id` strings) with a table. SQEditorUI turns the result into a key map.

/// A key as another program names it. Wider than ours: Return, Tab, Escape and forward delete exist here, and the
/// importer reports a chord with such a key as skipped when our key model has no such key.
public enum ForeignKey: Hashable, Sendable {
    case char(Character)
    case space, left, right, up, down, home, end, pageUp, pageDown
    /// The Mac "delete" key (backspace).
    case backspace
    case forwardDelete, returnKey, tab, escape
    case function(Int)
}

public struct ForeignModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = ForeignModifiers(rawValue: 1)
    public static let shift = ForeignModifiers(rawValue: 2)
    public static let option = ForeignModifiers(rawValue: 4)
    public static let control = ForeignModifiers(rawValue: 8)
}

/// One key press. The keypad and fn flags of the source are dropped: a keypad twin of a chord is the same chord here.
public struct ForeignChord: Hashable, Sendable {
    public var key: ForeignKey
    public var modifiers: ForeignModifiers
    public init(_ key: ForeignKey, _ modifiers: ForeignModifiers = []) { self.key = key; self.modifiers = modifiers }

    /// Compact spelling used by the built-in tables: "cmd+shift+b", "option+left", "control+=", "delete", "space".
    /// The key is the last `+`-separated part; a literal plus is not spellable (use "=").
    public init?(spec: String) {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var m: ForeignModifiers = []
        for p in parts {
            switch p {
            case "cmd", "command": m.insert(.command)
            case "shift": m.insert(.shift)
            case "option", "opt": m.insert(.option)
            case "control", "ctrl": m.insert(.control)
            default: return nil
            }
        }
        let key: ForeignKey
        switch last {
        case "space": key = .space
        case "left": key = .left
        case "right": key = .right
        case "up": key = .up
        case "down": key = .down
        case "home": key = .home
        case "end": key = .end
        case "pageup": key = .pageUp
        case "pagedown": key = .pageDown
        case "delete": key = .backspace
        case "fdelete": key = .forwardDelete
        case "return": key = .returnKey
        case "tab": key = .tab
        case "esc": key = .escape
        default:
            if last.count == 1, let c = last.first { key = .char(c) }
            else if last.hasPrefix("f"), let n = Int(last.dropFirst()), n > 0 { key = .function(n) }
            else { return nil }
        }
        self.init(key, m)
    }
}

/// One command of the foreign file with every chord that triggers it.
public struct ForeignCommand: Equatable, Sendable {
    public var sourceID: String
    public var chords: [ForeignChord]
    /// Key descriptions that name no key we understand (kept for the report).
    public var unreadable: [String]
    public init(sourceID: String, chords: [ForeignChord], unreadable: [String] = []) {
        self.sourceID = sourceID; self.chords = chords; self.unreadable = unreadable
    }
}

// MARK: Final Cut Pro .commandset reader

/// Reads Final Cut Pro's `.commandset` (a property list). Shape: a dictionary from command identifier ("BladeAtPlayhead")
/// to one key description or an array of them. A key description has `characterString` (the key: a character or a Cocoa name
/// such as `NSLeftArrowFunctionKey`), `modifiers` (words: command, option, control, shift, keypad, function) and
/// `modifierMask` (the same as NSEvent flag bits; read only when the words are missing). An empty `characterString` means
/// the command has no key.
public enum FCPCommandSetReader {
    public enum ReadError: Error, Equatable { case notAPropertyList, notACommandSet }

    public static func read(_ data: Data) throws -> [ForeignCommand] {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { throw ReadError.notAPropertyList }
        guard let dict = obj as? [String: Any], dict.values.contains(where: { describes($0) }) else { throw ReadError.notACommandSet }
        return read(dictionary: dict)
    }

    private static func describes(_ v: Any) -> Bool {
        if let d = v as? [String: Any] { return d["characterString"] != nil }
        if let a = v as? [Any] { return a.contains { describes($0) } }
        return false
    }

    /// Sorted by identifier so results are stable. Commands without any key are returned with no chords.
    public static func read(dictionary: [String: Any]) -> [ForeignCommand] {
        dictionary.keys.sorted().map { id in
            let raw = dictionary[id]
            let descriptions: [[String: Any]] = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
            var chords: [ForeignChord] = []
            var unreadable: [String] = []
            for d in descriptions {
                switch chord(from: d) {
                case .chord(let c): if !chords.contains(c) { chords.append(c) }   // keypad twins collapse here
                case .none: break
                case .unreadable(let s): unreadable.append(s)
                }
            }
            return ForeignCommand(sourceID: id, chords: chords, unreadable: unreadable)
        }
    }

    enum ChordResult: Equatable { case chord(ForeignChord), none, unreadable(String) }

    static func chord(from d: [String: Any]) -> ChordResult {
        guard let raw = d["characterString"] as? String ?? d["character"] as? String, !raw.isEmpty else { return .none }
        guard let key = key(from: raw) else { return .unreadable(raw) }
        return .chord(ForeignChord(key, modifiers(words: d["modifiers"] as? String, mask: d["modifierMask"] as? Int)))
    }

    static func modifiers(words: String?, mask: Int?) -> ForeignModifiers {
        var m: ForeignModifiers = []
        // The words win when they name something; an empty or missing list falls back to the flag bits (some entries only carry those).
        if let words, !words.trimmingCharacters(in: .whitespaces).isEmpty || (mask ?? 0) == 0 {
            for w in words.split(whereSeparator: { $0 == " " }) {
                switch w {
                case "command": m.insert(.command)
                case "shift": m.insert(.shift)
                case "option": m.insert(.option)
                case "control": m.insert(.control)
                default: break   // keypad, function: not part of the chord
                }
            }
            return m
        }
        if let mask {
            if mask & (1 << 17) != 0 { m.insert(.shift) }
            if mask & (1 << 18) != 0 { m.insert(.control) }
            if mask & (1 << 19) != 0 { m.insert(.option) }
            if mask & (1 << 20) != 0 { m.insert(.command) }
        }
        return m
    }

    static func key(from s: String) -> ForeignKey? {
        switch s {
        case "NSLeftArrowFunctionKey": return .left
        case "NSRightArrowFunctionKey": return .right
        case "NSUpArrowFunctionKey": return .up
        case "NSDownArrowFunctionKey": return .down
        case "NSHomeFunctionKey": return .home
        case "NSEndFunctionKey": return .end
        case "NSPageUpFunctionKey": return .pageUp
        case "NSPageDownFunctionKey": return .pageDown
        case "NSDeleteCharacter", "NSBackspaceCharacter": return .backspace
        case "NSDeleteFunctionKey": return .forwardDelete
        case "NSCarriageReturnCharacter", "NSNewlineCharacter", "NSEnterCharacter": return .returnKey
        case "NSTabCharacter", "NSBackTabCharacter": return .tab
        case "NSProEscapeCharacter", "NSEscapeCharacter": return .escape
        default: break
        }
        if s.hasPrefix("NSF"), s.hasSuffix("FunctionKey"), let n = Int(s.dropFirst(3).dropLast(11)) { return .function(n) }
        if s.hasPrefix("NS") && s.count > 4 { return nil }   // another Cocoa name we do not know
        guard s.count == 1, let c = s.first, let u = c.unicodeScalars.first else { return nil }
        switch u.value {
        case 0x20: return .space
        case 0x7F: return .backspace
        case 0x0D, 0x03: return .returnKey
        case 0x09: return .tab
        case 0x1B: return .escape
        case 0xF700: return .up
        case 0xF701: return .down
        case 0xF702: return .left
        case 0xF703: return .right
        case 0xF728: return .forwardDelete
        case 0xF729: return .home
        case 0xF72B: return .end
        case 0xF72C: return .pageUp
        case 0xF72D: return .pageDown
        case 0xF704...0xF726: return .function(Int(u.value - 0xF704) + 1)
        case 0xF700...0xF8FF: return nil
        default: break
        }
        return .char(Character(String(c).lowercased()))
    }
}

// MARK: Translation to our commands

public enum ForeignKeymap {
    public enum Reason: Equatable, Sendable {
        /// We have nothing like it.
        case noEquivalent
        /// macOS or the app menu owns it (Quit, Hide, Minimize).
        case system
        /// We will have it (the Fast Cut commands) but this build does not yet: binds by itself once the command exists.
        case plannedFeature
    }

    /// What a foreign command id maps to.
    public enum Target: Equatable, Sendable {
        case command(String)
        /// A command of ours that is being built (Fast Cut mode): the id is reserved, the importer binds it as soon as it exists.
        case planned(String)
        case system
        case none
    }

    public struct Binding: Equatable, Sendable {
        public var sourceID: String
        public var commandID: String
        /// True for a `planned` row: the importer reports it as unmapped when this build has no such command.
        public var planned: Bool
        public var chords: [ForeignChord]
        /// Key descriptions of this command that name no key we understand.
        public var unreadable: [String] = []
    }

    public struct Unmapped: Equatable, Sendable {
        public var sourceID: String
        /// "Blade At Playhead" for "BladeAtPlayhead".
        public var title: String
        public var reason: Reason
        public var chords: [ForeignChord]
        public init(sourceID: String, title: String, reason: Reason, chords: [ForeignChord]) {
            self.sourceID = sourceID; self.title = title; self.reason = reason; self.chords = chords
        }
    }

    public struct Result: Equatable, Sendable {
        /// Commands with a known equivalent (the id may still be unknown to this build when `planned`).
        public var mapped: [Binding] = []
        /// Commands with a key in the file and no equivalent.
        public var unmapped: [Unmapped] = []
        /// Commands in the file without any key.
        public var unassigned = 0
    }

    /// Splits the foreign commands into those we have an equivalent for and the rest. Commands without a key are only counted.
    public static func translate(_ commands: [ForeignCommand], table: [String: Target] = FCPCommandTable.rows) -> Result {
        var r = Result()
        for c in commands {
            guard !c.chords.isEmpty || !c.unreadable.isEmpty else { r.unassigned += 1; continue }
            switch table[c.sourceID] ?? .none {
            case .command(let id):
                r.mapped.append(Binding(sourceID: c.sourceID, commandID: id, planned: false, chords: c.chords, unreadable: c.unreadable))
            case .planned(let id):
                r.mapped.append(Binding(sourceID: c.sourceID, commandID: id, planned: true, chords: c.chords, unreadable: c.unreadable))
            case .system:
                r.unmapped.append(Unmapped(sourceID: c.sourceID, title: humanize(c.sourceID), reason: .system, chords: c.chords))
            case .none:
                r.unmapped.append(Unmapped(sourceID: c.sourceID, title: humanize(c.sourceID), reason: .noEquivalent, chords: c.chords))
            }
        }
        return r
    }

    /// "BladeAtPlayhead" -> "Blade At Playhead", "ColorBoard-NudgePuckUp" -> "Color Board: Nudge Puck Up",
    /// "cmd.sequence.lift" -> "Sequence Lift", "MediaPool.Context_setPosterFrame" -> "Media Pool: Context Set Poster Frame".
    public static func humanize(_ id: String) -> String {
        var source = Substring(id)
        let dotsAreSpaces = source.hasPrefix("cmd.")
        if dotsAreSpaces { source = source.dropFirst(4) }
        var out = ""
        var prev: Character?
        for ch in source {
            if ch == "-" || (ch == "." && !dotsAreSpaces) { out += ": "; prev = nil; continue }
            if ch == "." || ch == "_" { if prev != nil { out.append(" ") }; prev = nil; continue }
            if let p = prev, ch.isUppercase, p.isLowercase || p.isNumber { out.append(" ") }
            out.append(ch)
            prev = ch
        }
        return out.split(separator: " ", omittingEmptySubsequences: true).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
