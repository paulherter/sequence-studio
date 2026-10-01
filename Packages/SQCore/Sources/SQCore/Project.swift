import Foundation

public struct MediaFingerprint: Codable, Hashable, Sendable {
    public var size: Int64
    public var modified: Date?
    /// Hash of the first bytes of the file (computed by the media layer).
    public var headHash: String?

    public init(size: Int64, modified: Date? = nil, headHash: String? = nil) {
        self.size = size; self.modified = modified; self.headHash = headHash
    }
}

public enum MediaStatus: Sendable, Equatable { case ok, missing, changed }

public struct MediaRef: Codable, Hashable, Sendable, Identifiable {
    /// Equals `Clip.media`.
    public var id: UUID
    public var name: String
    public var path: String
    /// Security-scoped bookmark, resolved by the app layer.
    public var bookmark: Data?
    public var fingerprint: MediaFingerprint
    public var duration: Time?
    /// Probed media properties; nil for projects saved before probing existed.
    public var info: MediaInfo?
    /// Label colour; nil = default for the media type.
    public var label: LabelColor?
    /// Poster frame (Cmd+P in the Project panel): the time shown as the thumbnail; nil = automatic.
    public var posterTime: Time?
    /// Markers on the media itself (M in the Source monitor), sorted by time; nil = none.
    public var sourceMarkers: [Marker]?

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil,
                fingerprint: MediaFingerprint, duration: Time? = nil, info: MediaInfo? = nil, label: LabelColor? = nil,
                posterTime: Time? = nil, sourceMarkers: [Marker]? = nil) {
        self.posterTime = posterTime; self.sourceMarkers = sourceMarkers
        self.label = label
        self.id = id; self.name = name; self.path = path; self.bookmark = bookmark
        self.fingerprint = fingerprint; self.duration = duration; self.info = info
    }

    /// `.missing` if nothing is at `path`, `.changed` if size or modification date differ, else `.ok`.
    public func status(fileManager: FileManager = .default) -> MediaStatus {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return .missing }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        if size != fingerprint.size { return .changed }
        if let expected = fingerprint.modified, let actual = attrs[.modificationDate] as? Date,
           abs(actual.timeIntervalSince(expected)) > 1 { return .changed }
        return .ok
    }
}

public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var media: [MediaRef]
    public var timelines: [Timeline]
    public var activeTimeline: UUID?
    /// Project panel tree. Every media item and timeline is in exactly one bin.
    public var rootBin: Bin
    /// Source-monitor In/Out per media item. Empty entries are never stored.
    public var sourceMarks: [MediaRef.ID: SourceMarks]

    public init(id: UUID = UUID(), name: String, media: [MediaRef] = [],
                timelines: [Timeline] = [], activeTimeline: UUID? = nil,
                rootBin: Bin? = nil, sourceMarks: [MediaRef.ID: SourceMarks] = [:]) {
        self.id = id; self.name = name; self.media = media
        self.timelines = timelines; self.activeTimeline = activeTimeline ?? timelines.first?.id
        self.rootBin = rootBin ?? Bin(id: id, name: "Root")
        self.sourceMarks = sourceMarks
        normalizeBins()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, media, timelines, activeTimeline, rootBin, sourceMarks
    }

    /// `rootBin` and `sourceMarks` are absent in files before version 4: everything lands in the root bin, no marks.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        media = try c.decode([MediaRef].self, forKey: .media)
        timelines = try c.decode([Timeline].self, forKey: .timelines)
        activeTimeline = try c.decodeIfPresent(UUID.self, forKey: .activeTimeline)
        rootBin = try c.decodeIfPresent(Bin.self, forKey: .rootBin) ?? Bin(id: id, name: "Root")
        let marks = try c.decodeIfPresent([String: SourceMarks].self, forKey: .sourceMarks) ?? [:]
        var parsed: [MediaRef.ID: SourceMarks] = [:]
        for (k, v) in marks { if let u = UUID(uuidString: k), !v.isEmpty { parsed[u] = v } }
        sourceMarks = parsed
        normalizeBins()
    }

    /// Marks are keyed by the media UUID string so the file stays a plain JSON object.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(media, forKey: .media)
        try c.encode(timelines, forKey: .timelines)
        try c.encodeIfPresent(activeTimeline, forKey: .activeTimeline)
        try c.encode(rootBin, forKey: .rootBin)
        var marks: [String: SourceMarks] = [:]
        for (k, v) in sourceMarks { marks[k.uuidString] = v }
        try c.encode(marks, forKey: .sourceMarks)
    }

    public func media(_ id: UUID) -> MediaRef? { media.first { $0.id == id } }

    /// Adds `ref`, or replaces the entry with the same ID. New media is filed in the root bin.
    public mutating func add(_ ref: MediaRef) {
        if let i = media.firstIndex(where: { $0.id == ref.id }) { media[i] = ref } else {
            media.append(ref)
            rootBin.children.append(.media(ref.id))
        }
    }
}
