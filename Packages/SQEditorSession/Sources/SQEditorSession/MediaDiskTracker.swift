import Foundation

/// What a media file looked like on disk at one check: present or not, and its size and modification date.
public struct MediaDiskState: Equatable, Sendable {
    public var exists: Bool
    public var size: Int64?
    public var modified: Date?

    public init(exists: Bool, size: Int64? = nil, modified: Date? = nil) {
        self.exists = exists; self.size = size; self.modified = modified
    }

    /// Reads the file's state (one `stat`; a missing path is `exists == false`).
    public static func read(_ path: String) -> MediaDiskState {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return MediaDiskState(exists: false) }
        return MediaDiskState(exists: true, size: (a[.size] as? NSNumber)?.int64Value, modified: a[.modificationDate] as? Date)
    }
}

/// Notices project media files that changed behind the app's back: re-exported or overwritten (size or date), gone
/// (volume unmounted, file moved) or back (volume mounted again). The first look at an item only records its state.
public struct MediaDiskTracker: Sendable {
    public struct Changes: Equatable, Sendable {
        /// Still there, but another size or modification date than at the last look.
        public var modified: Set<UUID> = []
        /// Was missing at the last look, present now.
        public var appeared: Set<UUID> = []
        /// Was present at the last look, missing now.
        public var vanished: Set<UUID> = []
        public var isEmpty: Bool { modified.isEmpty && appeared.isEmpty && vanished.isEmpty }
        /// Items whose open decoders, thumbnails and waveforms must be dropped.
        public var all: Set<UUID> { modified.union(appeared).union(vanished) }
    }

    private var known: [UUID: MediaDiskState] = [:]

    public init() {}

    /// Stats `paths` (call off the main thread: a dead network volume can block a `stat`).
    public static func snapshot(_ paths: [UUID: String]) -> [UUID: MediaDiskState] {
        paths.mapValues { MediaDiskState.read($0) }
    }

    /// Compares `snapshot` with the last one and remembers it. Items not in `snapshot` are forgotten.
    public mutating func update(_ snapshot: [UUID: MediaDiskState]) -> Changes {
        var out = Changes()
        for (id, now) in snapshot {
            if let before = known[id] {
                if before.exists, !now.exists { out.vanished.insert(id) }
                else if !before.exists, now.exists { out.appeared.insert(id) }
                else if before.exists, now.exists, before.size != now.size || before.modified != now.modified { out.modified.insert(id) }
            }
        }
        known = snapshot
        return out
    }

    /// Items looked at so far (0 until the first `update`).
    public var knownCount: Int { known.count }

    /// Present at the last look; false for an item never looked at.
    public func isOnline(_ id: UUID) -> Bool { known[id]?.exists == true }

    /// Records one item's state without reporting (a relink or replace the app did itself).
    public mutating func accept(_ id: UUID, _ state: MediaDiskState) { known[id] = state }
}
