import Foundation

/// Rows of the read-only Keyboard tab, built from the command map.
public enum KeyboardListing {
    public struct Row: Equatable, Sendable {
        public var command: String
        public var shortcut: String
        public var scope: String
    }

    /// Display text of a binding, e.g. "⇧⌘Z" or "Space".
    public static func text(for b: KeyBinding) -> String {
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

    public static func rows(_ map: CommandMap) -> [Row] {
        map.entries.map {
            Row(command: $0.command.title, shortcut: text(for: $0.binding), scope: "\($0.scope)".capitalized)
        }
        .sorted { ($0.command, $0.shortcut) < ($1.command, $1.shortcut) }
    }

    /// Human name of the scope a binding is active in.
    public static func scopeName(_ s: CommandScope) -> String {
        switch s {
        case .global: "Everywhere"
        case .timeline: "Timeline"
        case .program: "Program"
        case .source: "Source"
        case .project: "Project"
        case .effectControls: "Controls"
        }
    }

    /// Rows of the Keyboard Shortcuts window: every binding, then every wired command that has no key (menu only),
    /// sorted by command name, scopes in plain words.
    public static func windowRows(_ map: CommandMap) -> [Row] {
        let keyed = Set(map.entries.map(\.command))
        var rows = map.entries.map { Row(command: $0.command.title, shortcut: text(for: $0.binding), scope: scopeName($0.scope)) }
        rows += CommandCatalog.audited(map).filter { !keyed.contains($0) && CommandSupport.isSupported($0) }
            .map { Row(command: $0.title, shortcut: "", scope: "Menu only") }
        return rows.sorted { ($0.command, $0.shortcut) < ($1.command, $1.shortcut) }
    }

    /// Case-insensitive search over command, scope and shortcut; modifier symbols also match their names
    /// ("cmd shift z" finds ⇧⌘Z). Every word of the query must match.
    public static func filter(_ rows: [Row], query: String) -> [Row] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { r in
            let keys = r.shortcut.replacingOccurrences(of: "⌃", with: " control ").replacingOccurrences(of: "⌥", with: " option alt ")
                .replacingOccurrences(of: "⇧", with: " shift ").replacingOccurrences(of: "⌘", with: " command cmd ")
                .replacingOccurrences(of: "←", with: " left ").replacingOccurrences(of: "→", with: " right ")
                .replacingOccurrences(of: "↑", with: " up ").replacingOccurrences(of: "↓", with: " down ")
                .replacingOccurrences(of: "⌫", with: " delete backspace ")
            let hay = (r.command + " " + r.scope + " " + r.shortcut + " " + keys).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
}
