import Foundation

/// "Sorted by" view of the Project panel: the same media grouped by shooting day, camera or kind. Display only.
public enum MediaGrouping: String, Sendable, Hashable, CaseIterable {
    case folders, day, camera, kind

    public var title: String {
        switch self { case .folders: "Folders"; case .day: "Day"; case .camera: "Camera"; case .kind: "Kind" }
    }

    public struct Group: Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var items: [MediaRef.ID]
        public var duration: Time
    }

    /// Groups in display order, items inside by shooting time (then name). Empty for `.folders`.
    public func groups(of media: [MediaRef], calendar: Calendar = .current) -> [Group] {
        guard self != .folders else { return [] }
        var order: [String] = [], titles: [String: String] = [:], buckets: [String: [MediaRef]] = [:]
        for m in media {
            let (key, title) = bucket(m, calendar)
            if buckets[key] == nil { order.append(key); titles[key] = title }
            buckets[key, default: []].append(m)
        }
        // Keys sort as text (yyyy-MM-dd, camera name, kind rank); the "unknown" bucket (prefix "~") goes last.
        let sorted = order.sorted { a, b in
            if a.hasPrefix("~") != b.hasPrefix("~") { return b.hasPrefix("~") }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        return sorted.map { key in
            let items = (buckets[key] ?? []).sorted { a, b in
                switch (a.shootDate, b.shootDate) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            }
            var total = Time.zero
            for m in items { if let d = m.duration { total = total + d } }
            return Group(id: key, title: titles[key] ?? key, items: items.map(\.id), duration: total)
        }
    }

    private func bucket(_ m: MediaRef, _ cal: Calendar) -> (String, String) {
        switch self {
        case .folders: return ("", "")
        case .day:
            guard let d = m.shootDate else { return ("~", "No Date") }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let key = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone
            f.setLocalizedDateFormatFromTemplate("EEEMMMd")
            return (key, f.string(from: d))
        case .camera:
            guard let c = m.info?.cameraModel?.trimmingCharacters(in: .whitespaces), !c.isEmpty else { return ("~", "Unknown Camera") }
            return (c.lowercased(), c)
        case .kind:
            switch m.kind {
            case .video, .videoAudio: return ("1", "Video")
            case .audio: return ("2", "Audio")
            case .image: return ("3", "Photo")
            case .unknown: return ("4", "Other")
            }
        }
    }
}
