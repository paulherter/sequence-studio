import Foundation

public enum FolderScanResult: Sendable, Equatable {
    case online([LibraryEntry])
    /// Folder missing, unmounted or not a directory. Not an error.
    case offline
}

public struct FolderScanner: Sendable {
    public init() {}

    /// Recursive scan; hidden and system files are skipped.
    public func scan(_ folder: WatchedFolder) -> FolderScanResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.url.path, isDirectory: &isDir), isDir.boolValue else { return .offline }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(
            at: folder.url, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return .offline }
        let base = folder.url.resolvingSymlinksInPath().standardizedFileURL.path
        var entries: [LibraryEntry] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let kind = LibraryItemKind.classifyIfVisible(url) else { continue }
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            entries.append(LibraryEntry(
                folderID: folder.id, relativePath: String(full.dropFirst(base.count + 1)), kind: kind,
                size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
        }
        entries.sort { $0.relativePath < $1.relativePath }
        return .online(entries)
    }
}
