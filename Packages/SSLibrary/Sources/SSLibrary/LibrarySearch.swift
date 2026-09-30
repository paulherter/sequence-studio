import Foundation

public enum LibrarySortKey: String, Sendable, CaseIterable {
    case name, date, size
}

public enum LibrarySearch {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Filters by kind set (empty/nil = all) and by name tokens (all tokens must occur in the file name), then sorts.
    public static func filter(
        _ entries: [LibraryEntry], query: String = "", kinds: Set<LibraryItemKind>? = nil,
        sort: LibrarySortKey = .name, ascending: Bool = true
    ) -> [LibraryEntry] {
        let tokens = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let kindFilter = (kinds?.isEmpty ?? true) ? nil : kinds
        let matched = entries.filter { entry in
            if let kindFilter, !kindFilter.contains(entry.kind) { return false }
            if tokens.isEmpty { return true }
            let name = fold(entry.name)
            return tokens.allSatisfy { name.contains($0) }
        }
        return matched.sorted { a, b in
            let order = compare(a, b, by: sort)
            if order == .orderedSame { return a.relativePath < b.relativePath }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private static func compare(_ a: LibraryEntry, _ b: LibraryEntry, by key: LibrarySortKey) -> ComparisonResult {
        switch key {
        case .name: return fold(a.name).compare(fold(b.name), options: .numeric)
        case .date: return a.modified < b.modified ? .orderedAscending : (a.modified > b.modified ? .orderedDescending : .orderedSame)
        case .size: return a.size < b.size ? .orderedAscending : (a.size > b.size ? .orderedDescending : .orderedSame)
        }
    }
}
