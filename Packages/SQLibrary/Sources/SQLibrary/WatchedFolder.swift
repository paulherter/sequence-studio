import Foundation

/// A folder the user added to the library.
public struct WatchedFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var url: URL
    public var displayName: String
    /// Security-scoped bookmark (set by the app layer; opaque here).
    public var bookmark: Data?

    public init(id: UUID = UUID(), url: URL, displayName: String? = nil, bookmark: Data? = nil) {
        self.id = id
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.bookmark = bookmark
    }
}

/// Stable entry id: folder id + path relative to the folder.
public struct LibraryEntryID: Codable, Sendable, Hashable {
    public var folderID: UUID
    public var relativePath: String
    public init(folderID: UUID, relativePath: String) {
        self.folderID = folderID
        self.relativePath = relativePath
    }
}

public struct LibraryEntry: Codable, Sendable, Hashable, Identifiable {
    public var folderID: UUID
    public var relativePath: String
    public var kind: LibraryItemKind
    public var size: Int64
    public var modified: Date

    public var id: LibraryEntryID { LibraryEntryID(folderID: folderID, relativePath: relativePath) }
    public var name: String { (relativePath as NSString).lastPathComponent }

    public init(folderID: UUID, relativePath: String, kind: LibraryItemKind, size: Int64, modified: Date) {
        self.folderID = folderID
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    public func url(in folder: WatchedFolder) -> URL {
        folder.url.appendingPathComponent(relativePath)
    }
}

/// Difference between two snapshots of one folder.
public struct LibraryDiff: Sendable, Equatable {
    public var added: [LibraryEntry]
    public var removed: [LibraryEntry]
    public var changed: [LibraryEntry]
    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

    public static func between(old: [LibraryEntry], new: [LibraryEntry]) -> LibraryDiff {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let added = new.filter { oldByID[$0.id] == nil }
        let removed = old.filter { newByID[$0.id] == nil }
        let changed = new.filter { entry in oldByID[entry.id].map { $0 != entry } ?? false }
        return LibraryDiff(added: added, removed: removed, changed: changed)
    }
}
