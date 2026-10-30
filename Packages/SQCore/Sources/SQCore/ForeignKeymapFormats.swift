import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Premiere Pro `.kys` and DaVinci Resolve keyboard layout readers (docs/KEYMAP.md "Premiere and Resolve import").
// Both produce `ForeignCommand`s for the same translate / import pipeline as the Final Cut `.commandset`.
//
// UNVERIFIED: written from published descriptions of the formats, never run against a real file of either app.
// Premiere: XML, `<PremiereData><shortcuts>` with context elements holding `item.N` (virtualkey, modifier.*, commandname).
// Resolve: plain text, one `commandId := chord | chord` per line (a gist of a real export was the source).

// MARK: Premiere Pro .kys

public enum PremiereKysReader {
    public enum ReadError: Error, Equatable { case notAKeyboardLayout }

    private final class Node {
        let name: String
        var text = ""
        var children: [Node] = []
        init(_ name: String) { self.name = name }
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = Node("")
        private var stack: [Node] = []
        override init() { super.init(); stack = [root] }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let n = Node(name)
            stack.last?.children.append(n)
            stack.append(n)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if stack.count > 1 { stack.removeLast() }
        }
    }

    /// Sorted by command name so results are stable. A command bound in several contexts keeps each distinct chord once.
    public static func read(_ data: Data) throws -> [ForeignCommand] {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { throw ReadError.notAKeyboardLayout }
        var order: [String] = []
        var chords: [String: [ForeignChord]] = [:]
        var unreadable: [String: [String]] = [:]
        var sawShortcuts = false
        func walk(_ n: Node) {
            if n.name == "shortcuts" { sawShortcuts = true }
            if n.name.hasPrefix("item."),
               let cmd = n.children.first(where: { $0.name == "commandname" })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
               !cmd.isEmpty {
                if chords[cmd] == nil { order.append(cmd); chords[cmd] = [] }
                if let raw = n.children.first(where: { $0.name == "virtualkey" })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                   let code = Int64(raw) {
                    if let key = key(virtualKey: code) {
                        let c = ForeignChord(key, modifiers(of: n))
                        if !chords[cmd]!.contains(c) { chords[cmd]!.append(c) }
                    } else {
                        let u = "key code \(code)"
                        if !(unreadable[cmd] ?? []).contains(u) { unreadable[cmd, default: []].append(u) }
                    }
                }
            }
            n.children.forEach(walk)
        }
        walk(builder.root)
        guard sawShortcuts || !order.isEmpty else { throw ReadError.notAKeyboardLayout }
        return order.sorted().map { ForeignCommand(sourceID: $0, chords: chords[$0] ?? [], unreadable: unreadable[$0] ?? []) }
    }

    /// Modifier child elements: `modifier.ctrl` is Command on a Mac, `modifier.alt` Option. The control-key tag name on
    /// a Mac is unverified (control / macctrl accepted). A modifier element counts unless its text says false.
    private static func modifiers(of item: Node) -> ForeignModifiers {
        var m: ForeignModifiers = []
        for c in item.children where c.name.hasPrefix("modifier.") {
            let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if t == "false" || t == "0" { continue }
            switch c.name.dropFirst("modifier.".count).lowercased() {
            case "ctrl", "cmd", "command": m.insert(.command)
            case "alt", "option": m.insert(.option)
            case "shift": m.insert(.shift)
            case "control", "macctrl", "macctl": m.insert(.control)
            default: break
            }
        }
        return m
    }

    /// Printable keys are `0x80000000 | ASCII` (G = 2147483719; verified for letters). Small numbers are special keys:
    /// F5 = 11 and F6 = 12 are verified, F1..F12 = 7..18 is extrapolated; arrows, Home, End and the rest are NOT
    /// decoded because no source for their numbers was found: they are reported as unreadable.
    static func key(virtualKey v: Int64) -> ForeignKey? {
        if v & 0x8000_0000 != 0 {
            let a = v & 0x7FFF_FFFF
            switch a {
            case 32: return .space
            case 9: return .tab
            case 13: return .returnKey
            case 27: return .escape
            case 8: return .backspace
            case 127: return .forwardDelete
            case 33...126:
                let s = String(UnicodeScalar(UInt8(a))).lowercased()
                return s.first.map { .char($0) }
            default: return nil
            }
        }
        if (7...18).contains(v) { return .function(Int(v) - 6) }
        return nil
    }
}

// MARK: DaVinci Resolve keyboard layout

public enum ResolveKeymapReader {
    public enum ReadError: Error, Equatable { case notAKeyboardLayout }

    public static func read(_ data: Data) throws -> [ForeignCommand] {
        guard let text = String(data: data, encoding: .utf8) else { throw ReadError.notAKeyboardLayout }
        var out: [ForeignCommand] = []
        var seen: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: ":=") else { continue }
            let id = line[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            guard isIdentifier(id) else { continue }
            var chords: [ForeignChord] = []
            var unreadable: [String] = []
            for part in line[r.upperBound...].split(separator: "|") {
                let spec = part.trimmingCharacters(in: .whitespaces)
                if spec.isEmpty { continue }
                if let c = chord(spec) { if !chords.contains(c) { chords.append(c) } } else { unreadable.append(spec) }
            }
            if let i = seen[id] {   // a repeated id adds to the first
                for c in chords where !out[i].chords.contains(c) { out[i].chords.append(c) }
                out[i].unreadable += unreadable
            } else {
                seen[id] = out.count
                out.append(ForeignCommand(sourceID: id, chords: chords, unreadable: unreadable))
            }
        }
        guard !out.isEmpty else { throw ReadError.notAKeyboardLayout }
        return out.sorted { $0.sourceID < $1.sourceID }
    }

    private static func isIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
    }

    /// "Ctrl+Shift+Z", "Alt+Backspace", "Num+6", "Ctrl++". Qt-style names; Ctrl is Command on a Mac, Meta is Control
    /// (unverified), Num is the keypad (dropped: a keypad twin is the same chord).
    static func chord(_ spec: String) -> ForeignChord? {
        var modPart = Substring("")
        let keyName: String
        if spec == "+" { keyName = "+" }
        else if spec.hasSuffix("++") { keyName = "+"; modPart = spec.dropLast(2) }
        else if let i = spec.lastIndex(of: "+") { keyName = String(spec[spec.index(after: i)...]); modPart = spec[..<i] }
        else { keyName = spec }
        var m: ForeignModifiers = []
        for tok in modPart.split(separator: "+") {
            switch tok.lowercased() {
            case "ctrl", "cmd": m.insert(.command)
            case "alt", "opt": m.insert(.option)
            case "shift": m.insert(.shift)
            case "meta": m.insert(.control)
            case "num": break
            default: return nil
            }
        }
        guard let key = key(keyName) else { return nil }
        return ForeignChord(key, m)
    }

    private static func key(_ name: String) -> ForeignKey? {
        let n = name.lowercased()
        switch n {
        case "space": return .space
        case "left": return .left
        case "right": return .right
        case "up": return .up
        case "down": return .down
        case "home": return .home
        case "end": return .end
        case "pgup", "pageup": return .pageUp
        case "pgdown", "pagedown", "pgdn": return .pageDown
        case "backspace": return .backspace
        case "del", "delete": return .forwardDelete
        case "return", "enter": return .returnKey
        case "tab": return .tab
        case "esc", "escape": return .escape
        default:
            if n.count > 1, n.hasPrefix("f"), let f = Int(n.dropFirst()), f > 0 { return .function(f) }
            if n.count == 1, let c = n.first { return .char(c) }
            return nil
        }
    }
}

// MARK: Detection

public enum ForeignKeymapFormat: Sendable, Equatable {
    case finalCut, premiere, resolve

    /// The command table of that program.
    public var table: [String: ForeignKeymap.Target] {
        switch self {
        case .finalCut: FCPCommandTable.rows
        case .premiere: PremiereCommandTable.rows
        case .resolve: ResolveCommandTable.rows
        }
    }

    public var programName: String {
        switch self {
        case .finalCut: "Final Cut Pro"
        case .premiere: "Premiere Pro"
        case .resolve: "DaVinci Resolve"
        }
    }
}

public enum ForeignKeymapFile {
    public struct Contents: Sendable {
        public var format: ForeignKeymapFormat
        public var commands: [ForeignCommand]
    }
    public enum ReadError: Error, Equatable { case unknownFormat }

    /// Picks the reader by content: a property list is Final Cut, XML with `PremiereData` / `shortcuts` is Premiere,
    /// text with `id := keys` lines is Resolve.
    public static func read(_ data: Data) throws -> Contents {
        if let cmds = try? FCPCommandSetReader.read(data) { return Contents(format: .finalCut, commands: cmds) }
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if head.contains("<PremiereData") || head.contains("<shortcuts"), let cmds = try? PremiereKysReader.read(data) {
            return Contents(format: .premiere, commands: cmds)
        }
        if let cmds = try? ResolveKeymapReader.read(data) { return Contents(format: .resolve, commands: cmds) }
        throw ReadError.unknownFormat
    }
}
