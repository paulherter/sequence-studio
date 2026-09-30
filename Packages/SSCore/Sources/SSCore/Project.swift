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

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil,
                fingerprint: MediaFingerprint, duration: Time? = nil) {
        self.id = id; self.name = name; self.path = path; self.bookmark = bookmark
        self.fingerprint = fingerprint; self.duration = duration
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

    public init(id: UUID = UUID(), name: String, media: [MediaRef] = [],
                timelines: [Timeline] = [], activeTimeline: UUID? = nil) {
        self.id = id; self.name = name; self.media = media
        self.timelines = timelines; self.activeTimeline = activeTimeline ?? timelines.first?.id
    }

    public func media(_ id: UUID) -> MediaRef? { media.first { $0.id == id } }

    /// Adds `ref`, or replaces the entry with the same ID.
    public mutating func add(_ ref: MediaRef) {
        if let i = media.firstIndex(where: { $0.id == ref.id }) { media[i] = ref } else { media.append(ref) }
    }
}
