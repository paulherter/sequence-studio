import Foundation
import SQCore

public enum FolderScanResult: Sendable, Equatable {
    case online([LibraryEntry])
    /// Folder missing, unmounted or not a directory. Not an error.
    case offline
}

public struct FolderScanner: Sendable {
    /// Guards for huge or odd trees: directories deeper than `maxDepth` are not entered, the scan stops at `maxEntries`.
    /// The walk never follows links to directories, so link loops cannot recurse.
    public var maxDepth = 24
    public var maxEntries = 100_000

    public init() {}

    /// Recursive scan; hidden and system files are skipped.
    public func scan(_ folder: WatchedFolder) -> FolderScanResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.url.path, isDirectory: &isDir), isDir.boolValue else { return .offline }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let base = folder.url.standardizedFileURL.path
        let resolvedBase = folder.url.resolvingSymlinksInPath().standardizedFileURL.path
        var entries: [LibraryEntry] = []
        // FileWalk, not FileManager.enumerator: on Windows its skipDescendants() stops every later folder too.
        // Dot names are hidden on every system there.
        FileWalk.walk(folder.url, keys: keys + [.isSymbolicLinkKey]) { url, v, level in
            if entries.count >= maxEntries || Task.isCancelled { return .stop }
            // level 1 = direct children of the folder; a directory at level maxDepth is not entered.
            let next: FileWalk.Step = level >= maxDepth ? .skip : .descend
            guard var values = v, let kind = LibraryItemKind.classifyIfVisible(url) else { return next }
            if values.isSymbolicLink == true {
                // A link to a file inside the folder is listed under its own (unresolved) path; the file
                // attributes come from the target. Links pointing outside the folder are skipped.
                let target = url.resolvingSymlinksInPath()
                guard target.standardizedFileURL.path.hasPrefix(resolvedBase + "/"),
                      let tv = FileWalk.Values.read(target, keys: Set(keys)) else { return next }
                values = tv
            }
            guard values.isRegularFile == true else { return next }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { return next }
            entries.append(LibraryEntry(
                folderID: folder.id, relativePath: String(full.dropFirst(base.count + 1)), kind: kind,
                size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            return next
        }
        entries.sort { $0.relativePath < $1.relativePath }
        return .online(entries)
    }
}
