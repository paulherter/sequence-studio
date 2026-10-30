import Foundation
import SQCore

/// The "what came over" list shown after an import: one row for what arrived as is, then what was approximated,
/// what was left out and which files are missing. Built from the importer's report; rows with `locations` can jump to clips.
public struct PRImportChecklist: Sendable, Equatable {
    public enum Kind: Int, Sendable, Comparable {
        case cameOver, approximated, leftOut, missingFiles
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public var id: String
        public var kind: Kind
        public var title: String
        public var detail: String
        public var count: Int
        public var locations: [PRImportReport.Location]
    }

    public static let offlineFeature = "Offline media"

    public private(set) var items: [Item] = []

    /// True when something was approximated, left out or is missing.
    public var needsAttention: Bool { items.contains { $0.kind != .cameOver } }

    public init(report: PRImportReport, project: Project) {
        let clips = project.timelines.flatMap(\.tracks).reduce(0) { $0 + $1.clips.count }
        let sequences = project.timelines.count
        func plural(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
        items.append(Item(id: "came-over", kind: .cameOver, title: "\(plural(clips, "clip")), \(plural(sequences, "sequence"))",
                          detail: "Imported", count: clips, locations: []))
        var rest = [Item]()
        var offline = (count: 0, locations: [PRImportReport.Location]())
        for e in report.entries where e.status != .mapped {
            if e.feature == Self.offlineFeature {
                offline.count += e.count; offline.locations += e.locations
                continue
            }
            rest.append(Item(id: "\(e.status.label)-\(e.feature)", kind: e.status == .dropped ? .leftOut : .approximated,
                             title: Self.displayName(e.feature), detail: e.note, count: e.count, locations: e.locations))
        }
        // Approximated before left out, bigger counts first, then by name.
        rest.sort { ($0.kind.rawValue, -$0.count, $0.title) < ($1.kind.rawValue, -$1.count, $1.title) }
        items += rest
        if offline.count > 0 {
            items.append(Item(id: "missing-files", kind: .missingFiles, title: "\(plural(offline.count, "file")) missing",
                              detail: "Placeholders until reconnected", count: offline.count, locations: offline.locations))
        }
    }

    /// Internal match names ("AE.ADBE Motion") become plain names.
    static func displayName(_ feature: String) -> String {
        for prefix in ["AE.ADBE ", "ADBE "] where feature.hasPrefix(prefix) { return String(feature.dropFirst(prefix.count)) }
        return feature
    }
}
