import Foundation
import SQCore

/// Turns a foreign key set (SQCore `ForeignCommand`s, e.g. from a Final Cut `.commandset`) into one of our key maps.
///
/// Rules (docs/KEYMAP.md "Templates and import"):
/// - The result starts from `base` (our default) so commands the other program does not know keep their keys.
/// - Every command the import binds loses its base keys first: the file defines it.
/// - The imported binding wins: a base command that held the key in the same scope loses it, and a global import also takes
///   the key from base commands bound to it in a panel scope (otherwise the panel would hide the import there).
/// - Two imported commands that claim the same key in the same scope: the first in file order (sorted by Final Cut id) keeps it.
/// - A command is bound in the scopes it has in our default set (Timeline for edit commands), else everywhere.
public struct KeymapImport: Sendable {
    public struct Note: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A base command lost a key the import took.
            case displaced
            /// Two imported commands wanted the same key in the same scope; the later one lost it.
            case sharedKey
            /// An imported panel binding hides an imported Everywhere binding of the same key inside that panel.
            case overlap
            /// A key we cannot bind (Return, Tab, Esc, forward delete, a reserved key).
            case skippedKey
        }
        public var kind: Kind
        public var message: String
    }

    public var map: CommandMap
    /// Distinct commands of ours that received at least one key.
    public var importedCommands: Int
    public var importedBindings: Int
    /// Commands with a key in the file and no counterpart here (includes system and not-yet-built ones, see `reason`).
    public var unmapped: [ForeignKeymap.Unmapped]
    public var notes: [Note]
    /// Commands in the file that have no key at all.
    public var unassigned: Int

    public var skippedKeys: [Note] { notes.filter { $0.kind == .skippedKey } }
    public var conflicts: [Note] { notes.filter { $0.kind != .skippedKey } }

    /// "42 imported, 17 have no equivalent in Sequence Studio, 13 unassigned in the file".
    public var summary: String {
        "\(importedCommands) imported, \(unmapped.count) have no equivalent in Sequence Studio, \(unassigned) unassigned in the file"
    }

    /// Plain-words name of an unmapped row for the result list.
    public static func title(of u: ForeignKeymap.Unmapped) -> String {
        switch u.reason {
        case .noEquivalent: u.title
        case .system: u.title + " (macOS handles it)"
        case .plannedFeature: u.title + " (comes with Fast Cut mode)"
        }
    }

    public static func build(_ commands: [ForeignCommand], base: CommandMap = .sqDefault,
                             table: [String: ForeignKeymap.Target] = FCPCommandTable.rows,
                             resolver: KeyCharacterResolver = .us) -> KeymapImport {
        let translated = ForeignKeymap.translate(commands, table: table)
        var unmapped = translated.unmapped
        var notes: [Note] = []

        struct Claim { var source: String; var command: EditorCommand; var scope: CommandScope; var binding: KeyBinding }
        var claims: [Claim] = []
        for b in translated.mapped {
            guard let command = EditorCommand(id: b.commandID) else {
                unmapped.append(.init(sourceID: b.sourceID, title: ForeignKeymap.humanize(b.sourceID),
                                      reason: b.planned ? .plannedFeature : .noEquivalent, chords: b.chords))
                continue
            }
            let scopes = scopes(of: command)
            for text in b.unreadable {
                notes.append(.init(kind: .skippedKey, message: SQL10n.format("%@: the key %@ in the file could not be read.", ForeignKeymap.humanize(b.sourceID), text)))
            }
            for chord in b.chords {
                guard let binding = KeyBinding(chord, resolver: resolver) else {
                    notes.append(.init(kind: .skippedKey, message: SQL10n.format("%@: %@ cannot be used as a shortcut here.", ForeignKeymap.humanize(b.sourceID), describe(chord))))
                    continue
                }
                if Keymap.reserved.contains(binding) {
                    notes.append(.init(kind: .skippedKey, message: SQL10n.format("%@: %@ is reserved by macOS or the app menu.", ForeignKeymap.humanize(b.sourceID), KeyboardListing.text(for: binding))))
                    continue
                }
                for s in scopes { claims.append(Claim(source: b.sourceID, command: command, scope: s, binding: binding)) }
            }
        }

        let imported = Set(claims.map(\.command))
        var entries = base.entries.filter { !imported.contains($0.command) }
        var bound = Set<CommandMap.Entry>()
        for c in claims {
            let e = CommandMap.Entry(scope: c.scope, binding: c.binding, command: c.command)
            if bound.contains(e) { continue }   // same command, same slot, two source ids (Up and Previous Edit)
            if let other = entries.first(where: { bound.contains($0) && $0.scope == c.scope && $0.binding == c.binding }) {
                notes.append(.init(kind: .sharedKey, message: SQL10n.format("%@ goes to %@; %@ did not get it.", KeyboardListing.text(for: c.binding), other.command.title, c.command.title)))
                continue
            }
            for old in entries where old.binding == c.binding && !bound.contains(old) && (old.scope == c.scope || c.scope == .global) {
                notes.append(.init(kind: .displaced, message: SQL10n.format("%@ moved from %@ to %@.", KeyboardListing.text(for: c.binding), old.command.title, c.command.title)))
            }
            entries.removeAll { $0.binding == c.binding && !bound.contains($0) && ($0.scope == c.scope || c.scope == .global) }
            entries.append(e)
            bound.insert(e)
        }
        // Imported panel binding over an imported Everywhere binding of the same key.
        for e in bound where e.scope != .global {
            if let g = bound.first(where: { $0.scope == .global && $0.binding == e.binding && $0.command != e.command }) {
                notes.append(.init(kind: .overlap, message: SQL10n.format("%@ runs %@ in the %@ and %@ everywhere else.", KeyboardListing.text(for: e.binding), e.command.title, KeyboardListing.scopeName(e.scope), g.command.title)))
            }
        }
        var seenNotes = Set<String>()
        notes = notes.filter { seenNotes.insert($0.message).inserted }   // one row per scope pair says the same
        notes.sort { ($0.kind == .skippedKey ? 1 : 0, $0.message) < ($1.kind == .skippedKey ? 1 : 0, $1.message) }
        return KeymapImport(map: CommandMap(entries: entries), importedCommands: Set(bound.map(\.command)).count,
                            importedBindings: bound.count, unmapped: unmapped.sorted { $0.title < $1.title },
                            notes: notes, unassigned: translated.unassigned)
    }

    /// Scopes a command is bound in by our default set; everywhere when it has no key there.
    static func scopes(of command: EditorCommand) -> [CommandScope] {
        var out: [CommandScope] = []
        for e in CommandMap.sqDefault.entries where e.command == command && !out.contains(e.scope) { out.append(e.scope) }
        return out.isEmpty ? [.global] : out
    }

    static func describe(_ c: ForeignChord) -> String {
        let key: String
        switch c.key {
        case .returnKey: key = "Return"
        case .tab: key = "Tab"
        case .escape: key = "Esc"
        case .forwardDelete: key = "Forward Delete"
        case .char(let ch): key = String(ch).uppercased()
        default: key = "\(c.key)"
        }
        return key
    }
}

extension KeyBinding {
    /// nil for a key our key model does not have (Tab, Escape).
    init?(_ chord: ForeignChord, resolver: KeyCharacterResolver = .us) {
        let key: Key
        var needsShift = false
        switch chord.key {
        case .char(let c):
            guard let r = resolver.resolve(c) else { return nil }
            key = r.key
            needsShift = r.needsShift
        case .space: key = .space
        case .left: key = .left
        case .right: key = .right
        case .up: key = .up
        case .down: key = .down
        case .home: key = .home
        case .end: key = .end
        case .pageUp: key = .pageUp
        case .pageDown: key = .pageDown
        case .backspace: key = .delete
        case .returnKey: key = .returnKey
        case .forwardDelete: key = .forwardDelete
        case .function(let n): key = .function(n)
        case .tab, .escape: return nil
        }
        var m: KeyModifiers = []
        if chord.modifiers.contains(.command) { m.insert(.command) }
        if chord.modifiers.contains(.shift) || needsShift { m.insert(.shift) }
        if chord.modifiers.contains(.option) { m.insert(.option) }
        if chord.modifiers.contains(.control) { m.insert(.control) }
        self.init(key, m)
    }
}

public extension CommandMap {
    /// Final Cut style: Final Cut Pro's default key set (approximate, docs/KEYMAP.md) laid over our default set.
    static let finalCutDefault: CommandMap = KeymapImport.build(FCPDefaultSet.commands, base: .sqDefault).map
}
