import Foundation

// MARK: Stable names (what `sq.keymap` stores)

public extension EditorCommand {
    /// Stable identifier of a command in saved keymaps ("razor" tool = "tool.razor", panels = "focusPanel.timeline").
    var id: String {
        switch self {
        case .tool(let t): "tool.\(t.rawValue)"
        case .focusPanel(let p): "focusPanel.\(p.rawValue)"
        case .switchAngle(let n): "switchAngle.\(n)"
        case .toggleTrackTarget(let k, let n): "toggleTrackTarget.\(k.rawValue).\(n)"
        case .thumbnailMode(let m): "thumbnailMode.\(m.rawValue)"
        case .replaceMode(let m): "replaceMode.\(m.rawValue)"
        case .viewGamma(let g): "viewGamma.\(g.rawValue)"
        default: "\(self)"
        }
    }

    /// nil for ids this build does not know (a keymap saved by a newer build): such overrides are skipped.
    init?(id: String) {
        guard let c = KeymapNames.commands[id] else { return nil }
        self = c
    }
}

extension Key {
    /// "c", "space", "left", "f9": one character is a key cap, longer names are the special keys.
    var code: String {
        switch self {
        case .char(let c): String(c)
        case .space: "space"
        case .left: "left"
        case .right: "right"
        case .up: "up"
        case .down: "down"
        case .home: "home"
        case .end: "end"
        case .pageUp: "pageup"
        case .pageDown: "pagedown"
        case .delete: "delete"
        case .returnKey: "return"
        case .forwardDelete: "fdelete"
        case .function(let n): "f\(n)"
        }
    }

    init?(code: String) {
        if code.count == 1, let c = code.first { self = .char(c); return }
        switch code {
        case "space": self = .space
        case "left": self = .left
        case "right": self = .right
        case "up": self = .up
        case "down": self = .down
        case "home": self = .home
        case "end": self = .end
        case "pageup": self = .pageUp
        case "pagedown": self = .pageDown
        case "delete": self = .delete
        case "return": self = .returnKey
        case "fdelete": self = .forwardDelete
        default:
            guard code.hasPrefix("f"), let n = Int(code.dropFirst()), n > 0 else { return nil }
            self = .function(n)
        }
    }
}

public extension CommandScope {
    var name: String {
        switch self {
        case .global: "global"
        case .timeline: "timeline"
        case .program: "program"
        case .source: "source"
        case .project: "project"
        case .effectControls: "effectControls"
        }
    }

    init?(name: String) {
        guard let s = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = s
    }
}

private enum KeymapNames {
    static let commands: [String: EditorCommand] = {
        var d: [String: EditorCommand] = [:]
        for c in CommandCatalog.audited(.premiereDefault) + [.removeSilences, .removeFillerWords, .voiceover, .recordVoiceOver] { d[c.id] = c }
        return d
    }()
}

// MARK: Diff model

/// One difference from the preset: in `scope`, `key` + `modifiers` now runs `command`, or nothing when `command` is nil.
public struct KeymapOverride: Codable, Hashable, Sendable {
    public var scope: String
    public var key: String
    public var modifiers: Int
    public var command: String?

    public init(scope: String, key: String, modifiers: Int, command: String?) {
        self.scope = scope; self.key = key; self.modifiers = modifiers; self.command = command
    }

    public init(_ scope: CommandScope, _ binding: KeyBinding, _ command: EditorCommand?) {
        self.init(scope: scope.name, key: binding.key.code, modifiers: binding.modifiers.rawValue, command: command?.id)
    }

    fileprivate var slot: Keymap.Slot? {
        guard let s = CommandScope(name: scope), let k = Key(code: key) else { return nil }
        return Keymap.Slot(scope: s, binding: KeyBinding(k, KeyModifiers(rawValue: modifiers)))
    }
}

public enum KeymapPreset: String, Codable, Sendable, CaseIterable {
    case sq, premiere, finalCut
    public var title: String {
        switch self {
        case .sq: "Sequence Studio"
        case .premiere: "Classic NLE"
        case .finalCut: "Final Cut style"
        }
    }
    public var map: CommandMap {
        switch self {
        case .sq: .sqDefault
        case .premiere: .premiereDefault
        case .finalCut: .finalCutDefault
        }
    }
}

/// A key set the user saved or imported: every binding, by name. Lives in `KeymapConfig.customSets`.
public struct KeymapSet: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Every binding of the set (all `command` values are set).
    public var entries: [KeymapOverride]

    public init(id: String = UUID().uuidString, name: String, map: CommandMap) {
        self.id = id
        self.name = name
        entries = map.entries.map { KeymapOverride($0.scope, $0.binding, $0.command) }
    }

    public var map: CommandMap { Keymap.apply(entries, to: CommandMap(entries: [])) }

    /// Our own exchange format (`.sqkeys`): JSON with a format tag so other files are refused.
    private struct Exchange: Codable { var format: String; var version: Int; var name: String; var entries: [KeymapOverride] }
    public static let fileExtension = "sqkeys"

    public func exportData() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? enc.encode(Exchange(format: "sq.keymapset", version: 1, name: name, entries: entries))) ?? Data()
    }

    /// nil when the data is not a key set of ours. Unknown commands inside are dropped when the set is used (`Keymap.apply`).
    public init?(exported data: Data) {
        guard let x = try? JSONDecoder().decode(Exchange.self, from: data), x.format == "sq.keymapset", x.version == 1 else { return nil }
        id = UUID().uuidString
        name = x.name
        entries = x.entries
    }
}

/// What `sq.keymap` holds: the chosen template (built-in set, or one of the user's own sets) plus the user's changes over it.
public struct KeymapConfig: Codable, Equatable, Sendable {
    public var preset: KeymapPreset
    /// The user's own sets (imported or saved). When `activeSetID` names one, it replaces `preset` as the base.
    public var customSets: [KeymapSet]
    public var activeSetID: String?
    public var overrides: [KeymapOverride]

    public init(preset: KeymapPreset = .sq, overrides: [KeymapOverride] = [], customSets: [KeymapSet] = [], activeSetID: String? = nil) {
        self.preset = preset; self.overrides = overrides; self.customSets = customSets; self.activeSetID = activeSetID
    }

    private enum CodingKeys: String, CodingKey { case preset, overrides, customSets, activeSetID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(KeymapPreset.self, forKey: .preset) ?? .sq
        overrides = try c.decodeIfPresent([KeymapOverride].self, forKey: .overrides) ?? []
        customSets = try c.decodeIfPresent([KeymapSet].self, forKey: .customSets) ?? []
        activeSetID = try c.decodeIfPresent(String.self, forKey: .activeSetID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preset, forKey: .preset)
        try c.encode(overrides, forKey: .overrides)
        if !customSets.isEmpty { try c.encode(customSets, forKey: .customSets) }
        try c.encodeIfPresent(activeSetID, forKey: .activeSetID)
    }

    public static let standard = KeymapConfig()

    /// Something differs from the plain default set (own changes, another template, or saved sets that must not be lost).
    public var isModified: Bool { !overrides.isEmpty }

    /// The own set in use, if any (an id of a deleted set counts as none).
    public var activeSet: KeymapSet? { activeSetID.flatMap { id in customSets.first { $0.id == id } } }

    /// Name of the template in use, for the switcher.
    public var baseTitle: String { activeSet?.name ?? preset.title }

    /// The template the overrides sit on.
    public var baseMap: CommandMap { activeSet?.map ?? preset.map }

    /// Template with the overrides applied.
    public var map: CommandMap { Keymap.apply(overrides, to: baseMap) }

    /// Stores `edited` as the diff over the current template.
    public mutating func set(map edited: CommandMap) { overrides = Keymap.diff(base: baseMap, edited: edited) }

    /// A different template starts clean: overrides made against another base would not mean the same.
    public mutating func switchPreset(_ p: KeymapPreset) { preset = p; activeSetID = nil; overrides = [] }

    public mutating func switchToSet(_ id: String) {
        guard customSets.contains(where: { $0.id == id }) else { return }
        activeSetID = id; overrides = []
    }

    public mutating func resetOverrides() { overrides = [] }

    // MARK: Own sets

    /// Names stay unique ("Name 2"), so the switcher never shows two equal rows.
    public func uniqueName(_ wanted: String, ignoring id: String? = nil) -> String {
        let trimmed = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "My Shortcuts" : trimmed
        let taken = Set(customSets.filter { $0.id != id }.map(\.name) + KeymapPreset.allCases.map(\.title))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Adds the set and makes it the template in use (no overrides).
    @discardableResult
    public mutating func addSet(name: String, map: CommandMap) -> KeymapSet {
        let set = KeymapSet(name: uniqueName(name), map: map)
        customSets.append(set)
        activeSetID = set.id
        overrides = []
        return set
    }

    /// Adds a set read from a file (name made unique) and makes it the template in use.
    public mutating func addSet(_ set: KeymapSet) {
        var s = set
        s.name = uniqueName(set.name)
        customSets.append(s)
        activeSetID = s.id
        overrides = []
    }

    public mutating func renameSet(_ id: String, to name: String) {
        guard let i = customSets.firstIndex(where: { $0.id == id }) else { return }
        customSets[i].name = uniqueName(name, ignoring: id)
    }

    /// Deleting the set in use goes back to our default set.
    public mutating func deleteSet(_ id: String) {
        customSets.removeAll { $0.id == id }
        if activeSetID == id { switchPreset(.sq) }
    }

    /// The template in use as a set (overrides included), for "Export…" and "Save as My Set".
    public func currentAsSet(name: String? = nil) -> KeymapSet {
        KeymapSet(id: activeSetID ?? UUID().uuidString, name: name ?? baseTitle, map: map)
    }
}

public struct KeymapStore {
    public static let defaultsKey = "sq.keymap"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The saved config; a missing or unreadable value gives the standard set.
    public func load() -> KeymapConfig {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let c = try? JSONDecoder().decode(KeymapConfig.self, from: data) else { return .standard }
        return c
    }

    public func save(_ config: KeymapConfig) {
        if config == .standard { defaults.removeObject(forKey: Self.defaultsKey); return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(config) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    public func reset() { defaults.removeObject(forKey: Self.defaultsKey) }
}

// MARK: Apply, diff, conflicts, edits

public enum Keymap {
    /// A binding position: what a key press resolves in one scope.
    struct Slot: Hashable {
        var scope: CommandScope
        var binding: KeyBinding
    }

    /// Keys macOS or the app menu owns; a shortcut may not take them.
    public static let reserved: Set<KeyBinding> = [
        KeyBinding(.char("h"), .command), KeyBinding(.char("h"), [.command, .option]), KeyBinding(.char("q"), .command),
        KeyBinding(.char("w"), .command), KeyBinding(.char("h"), [.command, .shift]),
    ]

    private static func slot(_ e: CommandMap.Entry) -> Slot { Slot(scope: e.scope, binding: e.binding) }

    private static func table(_ m: CommandMap) -> [Slot: EditorCommand] {
        var t: [Slot: EditorCommand] = [:]
        for e in m.entries where t[slot(e)] == nil { t[slot(e)] = e.command }
        return t
    }

    /// Base entries with the overrides applied in place; overrides for slots the base lacks are appended.
    /// Overrides that name an unknown scope, key or command are skipped (a newer build wrote them).
    public static func apply(_ overrides: [KeymapOverride], to base: CommandMap) -> CommandMap {
        var ov: [Slot: EditorCommand?] = [:]
        var order: [Slot] = []
        for o in overrides {
            guard let s = o.slot else { continue }
            if let id = o.command {
                guard let c = EditorCommand(id: id) else { continue }
                ov[s] = .some(c)
            } else {
                ov[s] = .some(nil)
            }
            order.append(s)
        }
        var out: [CommandMap.Entry] = []
        var used = Set<Slot>()
        for e in base.entries {
            let s = slot(e)
            if let o = ov[s] {
                if let c = o, used.insert(s).inserted { out.append(.init(scope: s.scope, binding: s.binding, command: c)) }
                used.insert(s)
            } else {
                out.append(e)
            }
        }
        for s in order where !used.contains(s) {
            used.insert(s)
            if let c = ov[s] ?? nil { out.append(.init(scope: s.scope, binding: s.binding, command: c)) }
        }
        return CommandMap(entries: out)
    }

    /// The overrides that turn `base` into `edited`. `apply(diff(base, edited), to: base)` binds the same keys as `edited`.
    public static func diff(base: CommandMap, edited: CommandMap) -> [KeymapOverride] {
        let b = table(base), e = table(edited)
        var out: [KeymapOverride] = []
        var seen = Set<Slot>()
        for entry in base.entries + edited.entries {
            let s = slot(entry)
            guard seen.insert(s).inserted, b[s] != e[s] else { continue }
            out.append(KeymapOverride(s.scope, s.binding, e[s]))
        }
        return out
    }

    // MARK: Conflicts

    public struct Conflict: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// The key already runs another command in this scope: assigning replaces it.
            case sameScope
            /// A panel scope binds the key to another command, so a global binding does not work in that panel.
            case shadowedInPanel
            /// A global binding of another command exists, which the panel scope hides while that panel has focus.
            case shadowsGlobal
            /// macOS or the app menu owns the key.
            case reserved
        }
        public var kind: Kind
        /// The other binding (nil for `reserved`).
        public var entry: CommandMap.Entry?

        /// Plain-words warning for the assign alert; `platform` names the keys and the system (Ctrl+K, Windows).
        public func message(for binding: KeyBinding, platform: KeyPlatform = .mac) -> String {
            let key = KeyBindingText.text(binding, platform: platform)
            let system = platform == .mac ? "macOS" : "Windows"
            guard let e = entry else { return "\(key) is reserved by \(system) or the app menu." }
            let other = e.command.title, scope = KeyboardListing.scopeName(e.scope)
            switch kind {
            case .sameScope: return "\(key) already runs \(other) (\(scope))."
            case .shadowedInPanel: return "\(key) runs \(other) in the \(scope), so the new shortcut does not work there."
            case .shadowsGlobal: return "\(key) also runs \(other) everywhere, which this panel shortcut hides while the panel has focus."
            case .reserved: return "\(key) is reserved by \(system) or the app menu."
            }
        }
    }

    /// Everything that disagrees with binding `command` to `binding` in `scope`. Empty means free.
    public static func conflicts(of command: EditorCommand, binding: KeyBinding, scope: CommandScope, in map: CommandMap) -> [Conflict] {
        if reserved.contains(binding) { return [Conflict(kind: .reserved, entry: nil)] }
        var out: [Conflict] = []
        for e in map.entries where e.binding == binding && e.command != command {
            if e.scope == scope {
                out.append(Conflict(kind: .sameScope, entry: e))
            } else if scope == .global {
                out.append(Conflict(kind: .shadowedInPanel, entry: e))
            } else if e.scope == .global {
                out.append(Conflict(kind: .shadowsGlobal, entry: e))
            }
        }
        return out
    }

    /// Binds `command` to `binding` in `scope`. `moving` is the entry being moved (removed, the new one takes its place).
    /// The command it displaced in the same scope loses the key. Returns nil for a reserved key.
    public static func assign(_ command: EditorCommand, to binding: KeyBinding, scope: CommandScope, in map: CommandMap,
                              moving old: CommandMap.Entry? = nil) -> CommandMap? {
        guard !reserved.contains(binding) else { return nil }
        var out: [CommandMap.Entry] = []
        var placed = false
        let new = CommandMap.Entry(scope: scope, binding: binding, command: command)
        for e in map.entries {
            if e == old {
                if !placed { out.append(new); placed = true }
                continue
            }
            if e.scope == scope && e.binding == binding {
                if e.command == command { if !placed { out.append(e); placed = true } }
                continue   // another command in the same slot: displaced
            }
            out.append(e)
        }
        if !placed { out.append(new) }
        return CommandMap(entries: out)
    }

    /// Removes one binding.
    public static func unbind(_ entry: CommandMap.Entry, in map: CommandMap) -> CommandMap {
        CommandMap(entries: map.entries.filter { $0 != entry })
    }
}

// MARK: List rows (Keyboard Shortcuts window)

public struct KeymapRow: Equatable, Sendable {
    public var command: EditorCommand
    /// nil for a command without a key (menu only).
    public var entry: CommandMap.Entry?
    public var listing: KeyboardListing.Row

    /// Every binding, then every wired command without a key, sorted by command name.
    public static func build(_ map: CommandMap) -> [KeymapRow] {
        let keyed = Set(map.entries.map(\.command))
        var rows = map.entries.map {
            KeymapRow(command: $0.command, entry: $0,
                      listing: .init(command: $0.command.title, shortcut: KeyboardListing.text(for: $0.binding),
                                     scope: KeyboardListing.scopeName($0.scope)))
        }
        rows += CommandCatalog.audited(map).filter { !keyed.contains($0) && CommandSupport.isSupported($0) }
            .map { KeymapRow(command: $0, entry: nil, listing: .init(command: $0.title, shortcut: "", scope: "Menu only")) }
        return rows.sorted { ($0.listing.command, $0.listing.shortcut) < ($1.listing.command, $1.listing.shortcut) }
    }

    public static func filter(_ rows: [KeymapRow], query: String) -> [KeymapRow] {
        rows.filter { !KeyboardListing.filter([$0.listing], query: query).isEmpty }
    }
}
