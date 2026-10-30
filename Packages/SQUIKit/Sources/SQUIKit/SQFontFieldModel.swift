import Foundation

/// Logic of the font field (Panels board "Font field"): which fonts match what was typed, the sections under the field
/// ("Matches", "Recent", "Included", "Show All Fonts…"), the keyboard highlight and the recents in UserDefaults `sq.font.recents`.
/// No AppKit: the view feeds in the installed families.
public struct SQFontFieldModel: Sendable, Equatable {
    public static let recentsKey = "sq.font.recents"
    public static let maxRecents = 5
    public static let maxMatches = 8

    public enum Row: Equatable, Sendable {
        case header(String)
        case separator
        /// A selectable font: `name` goes to the callbacks (family or PostScript name), `title` is shown in that face.
        case font(name: String, title: String, indented: Bool)
        case showAll

        public var isSelectable: Bool {
            switch self { case .font, .showAll: true; case .header, .separator: false }
        }
    }

    public private(set) var families: [String]
    public private(set) var recents: [String]
    /// Fonts that ship with the app, listed under "Included" while nothing is typed (each row is drawn in its own face = preview).
    public let bundled: [String]
    public private(set) var query: String = ""
    /// Rows of the full list while "Show All Fonts…" is open; nil in the match/recent list.
    public private(set) var allRows: [Row]?
    /// Index into `rows` of the highlighted row (follows arrows and the pointer).
    public private(set) var highlight: Int?

    public init(families: [String], recents: [String] = [], bundled: [String] = []) {
        self.families = families
        self.recents = recents
        self.bundled = bundled
        rebuildHighlight()
    }

    // MARK: Matching

    /// Matches of `query` among `families`: prefix first, then word prefix, then substring; each group A to Z. Empty query: none.
    public static func matches(query: String, in families: [String], limit: Int = maxMatches) -> [String] {
        let q = fold(query).trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var ranked: [(rank: Int, name: String)] = []
        for f in families {
            let n = fold(f)
            if n == q { ranked.append((-1, f)) }
            else if n.hasPrefix(q) { ranked.append((0, f)) }
            else if n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { ranked.append((1, f)) }
            else if n.contains(q) { ranked.append((2, f)) }
        }
        ranked.sort { a, b in a.rank != b.rank ? a.rank < b.rank : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        return ranked.prefix(limit).map(\.name)
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    // MARK: Rows

    public var matches: [String] { Self.matches(query: query, in: families) }

    /// Matches, a separator, recents (minus the matches already listed), a separator, "Show All Fonts…".
    public var rows: [Row] {
        if let allRows { return allRows }
        var out: [Row] = []
        let m = matches
        if !m.isEmpty {
            out.append(.header("Matches"))
            out += m.map { .font(name: $0, title: $0, indented: false) }
        }
        let rec = recents.filter { r in !m.contains(r) }
        if !rec.isEmpty {
            if !out.isEmpty { out.append(.separator) }
            out.append(.header("Recent"))
            out += rec.map { .font(name: $0, title: $0, indented: false) }
        }
        if m.isEmpty {
            let inc = bundled.filter { b in !rec.contains(b) }
            if !inc.isEmpty {
                if !out.isEmpty { out.append(.separator) }
                out.append(.header("Included"))
                out += inc.map { .font(name: $0, title: $0, indented: false) }
            }
        }
        if !out.isEmpty { out.append(.separator) }
        out.append(.showAll)
        return out
    }

    public mutating func setQuery(_ text: String) {
        query = text
        allRows = nil
        rebuildHighlight()
    }

    /// Switches to the full list (`rows` supplied by the view from the installed families and their faces).
    public mutating func showAll(rows: [Row], current: String? = nil) {
        allRows = rows
        highlight = rows.firstIndex(where: { if case .font(let n, _, _) = $0 { n == current } else { false } })
            ?? rows.firstIndex(where: \.isSelectable)
    }

    /// First match highlighted while typing, else nothing.
    private mutating func rebuildHighlight() {
        let r = rows
        highlight = matches.isEmpty ? nil : r.firstIndex(where: \.isSelectable)
    }

    // MARK: Highlight

    public mutating func moveHighlight(by delta: Int) {
        let r = rows
        let sel = r.indices.filter { r[$0].isSelectable }
        guard !sel.isEmpty else { highlight = nil; return }
        guard let cur = highlight, let pos = sel.firstIndex(of: cur) else {
            highlight = delta >= 0 ? sel.first : sel.last
            return
        }
        highlight = sel[min(max(pos + delta, 0), sel.count - 1)]
    }

    public mutating func setHighlight(_ index: Int?) {
        let r = rows
        if let index, r.indices.contains(index), r[index].isSelectable { highlight = index } else if index == nil { highlight = nil }
    }

    public var highlightedRow: Row? {
        guard let h = highlight, rows.indices.contains(h) else { return nil }
        return rows[h]
    }

    /// Font name to apply for Return: the highlighted font, else the typed text when it names an installed family exactly.
    public var returnTarget: String? {
        if case .font(let name, _, _)? = highlightedRow { return name }
        let q = Self.fold(query).trimmingCharacters(in: .whitespaces)
        return families.first { Self.fold($0) == q && !q.isEmpty }
    }

    // MARK: Recents

    public static func addingRecent(_ name: String, to list: [String], max: Int = maxRecents) -> [String] {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return list }
        var out = [n] + list.filter { $0 != n }
        if out.count > max { out.removeLast(out.count - max) }
        return out
    }

    public static func loadRecents(_ defaults: UserDefaults = .standard) -> [String] {
        Array((defaults.stringArray(forKey: recentsKey) ?? []).prefix(maxRecents))
    }

    public static func remember(_ name: String, in defaults: UserDefaults = .standard) {
        defaults.set(addingRecent(name, to: loadRecents(defaults)), forKey: recentsKey)
    }

    public mutating func noteUsed(_ name: String) { recents = Self.addingRecent(name, to: recents) }
}

/// Guards a deferred step of the font search against a newer keystroke: take a token before scheduling, and apply the
/// result only while the token is still current. Any later `begin()` (the next keystroke) retires older tokens.
public struct SQSearchGuard: Sendable, Equatable {
    private var generation = 0
    public init() {}
    @discardableResult public mutating func begin() -> Int { generation += 1; return generation }
    public func isCurrent(_ token: Int) -> Bool { token == generation }
}
