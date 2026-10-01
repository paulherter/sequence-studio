import Foundation

/// A file found while searching a folder for offline media.
public struct RelinkCandidate: Sendable, Hashable {
    public var path: String
    public var size: Int64
    public init(path: String, size: Int64) { self.path = path; self.size = size }
}

/// Matches offline media to files found in a folder: same file name (case-insensitive); with several of that name,
/// the one with the recorded size wins.
public enum RelinkPlanner {
    public static func plan(missing: [MediaRef], candidates: [RelinkCandidate]) -> [MediaRef.ID: String] {
        var byName: [String: [RelinkCandidate]] = [:]
        for c in candidates { byName[(c.path as NSString).lastPathComponent.lowercased(), default: []].append(c) }
        var out: [MediaRef.ID: String] = [:]
        for m in missing {
            let name = (m.path as NSString).lastPathComponent.lowercased()
            guard let list = byName[name], !list.isEmpty else { continue }
            out[m.id] = (list.first { $0.size == m.fingerprint.size } ?? list[0]).path
        }
        return out
    }
}

extension Project {
    /// Media whose file is not at its path.
    public func missingMedia(fileManager: FileManager = .default) -> [MediaRef] {
        media.filter { $0.status(fileManager: fileManager) == .missing }
    }

    /// Points media at new files (unknown IDs ignored). The stale bookmark is dropped; clips are untouched.
    public mutating func relink(_ paths: [MediaRef.ID: String]) {
        for i in media.indices {
            guard let p = paths[media[i].id] else { continue }
            media[i].path = p
            media[i].bookmark = nil
        }
    }
}
