import Foundation

/// What an import did with each Premiere feature: mapped 1:1, approximated (reason in `note`) or dropped.
public struct PRImportReport: Sendable, Codable, Equatable {
    public enum Status: Int, Sendable, Codable, Comparable {
        case mapped, approximated, dropped
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
        public var label: String { switch self { case .mapped: "mapped"; case .approximated: "approximated"; case .dropped: "dropped" } }
    }

    /// Where an affected clip sits: the timeline it is on and its id (for "Show" in the checklist).
    public struct Location: Sendable, Equatable, Hashable {
        public var timeline: UUID
        public var clip: UUID
        public init(timeline: UUID, clip: UUID) { self.timeline = timeline; self.clip = clip }
    }

    public struct Entry: Sendable, Codable, Equatable {
        public var feature: String
        public var status: Status
        public var count: Int
        public var note: String
        /// Clips this entry touched, in import order (approximated and dropped only). Not encoded: ids change per import.
        public var locations: [Location] = []
        private enum CodingKeys: String, CodingKey { case feature, status, count, note }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case entries }
    private var collecting = false
    private var touched: [Int] = []

    /// Starts recording which entries `note` touches, until `endCollect`.
    public mutating func beginCollect() { collecting = true; touched = [] }

    /// Ends the recording and ties every approximated or dropped entry touched since `beginCollect` to `location`.
    public mutating func endCollect(attachingTo location: Location?) {
        defer { collecting = false; touched = [] }
        guard let location else { return }
        for i in Set(touched).sorted() where entries[i].status != .mapped && !entries[i].locations.contains(location) {
            entries[i].locations.append(location)
        }
    }

    /// Ties an already counted entry to one more clip (offline media is counted once per file, shown per clip).
    public mutating func attach(_ feature: String, _ status: Status, to location: Location) {
        if let i = entries.firstIndex(where: { $0.feature == feature && $0.status == status }), !entries[i].locations.contains(location) {
            entries[i].locations.append(location)
        }
    }

    /// Counts one occurrence of `feature` with `status`; the first non-empty note is kept.
    public mutating func note(_ feature: String, _ status: Status, _ note: String = "") {
        if let i = entries.firstIndex(where: { $0.feature == feature && $0.status == status }) {
            entries[i].count += 1
            if entries[i].note.isEmpty { entries[i].note = note }
            if collecting { touched.append(i) }
        } else {
            entries.append(Entry(feature: feature, status: status, count: 1, note: note))
            if collecting { touched.append(entries.count - 1) }
        }
    }

    /// The worst status recorded for `feature`; nil if it never occurred.
    public func status(of feature: String) -> Status? { entries.filter { $0.feature == feature }.map(\.status).max() }
    public func count(of feature: String) -> Int { entries.filter { $0.feature == feature }.reduce(0) { $0 + $1.count } }

    /// One line per feature and status, worst first.
    public var summary: String {
        entries.sorted { ($0.status, $1.count, $0.feature) > ($1.status, $0.count, $1.feature) }
            .map { "\($0.status.label.padding(toLength: 13, withPad: " ", startingAt: 0)) \($0.count)x \($0.feature)"
                + ($0.note.isEmpty ? "" : " - \($0.note)") }
            .joined(separator: "\n")
    }
}
