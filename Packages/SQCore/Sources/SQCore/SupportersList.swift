import Foundation

/// The Supporters list: one name per line in the bundled `SUPPORTERS.md`. Blank lines and lines starting with `#` are ignored.
public enum SupportersList {
    public static let fileName = "SUPPORTERS"
    public static let fileExtension = "md"

    /// Names in file order, trimmed, duplicates (case-insensitive) removed keeping the first.
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if seen.insert(line.lowercased()).inserted { names.append(line) }
        }
        return names
    }
}
