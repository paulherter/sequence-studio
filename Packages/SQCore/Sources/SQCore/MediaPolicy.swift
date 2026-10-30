import Foundation

/// What happens to media that comes from outside the project folder (Downloads, a card, another drive).
/// `ask` shows the small prompt at the drop; the others apply without asking.
public enum OutsideMediaMode: String, Codable, Sendable, CaseIterable {
    case ask, copy, move, leave

    /// The file operation this mode stands for; nil for `ask` (decided per drop).
    public var importMode: ImportMode? {
        switch self {
        case .ask: nil
        case .copy: .copy
        case .move: .move
        case .leave: .leave
        }
    }

    public init(_ mode: ImportMode) {
        switch mode {
        case .copy: self = .copy
        case .move: self = .move
        case .leave: self = .leave
        }
    }

    public var title: String {
        switch self {
        case .ask: "Ask"
        case .copy: "Copy into project"
        case .move: "Move into project"
        case .leave: "Leave where it is"
        }
    }
}

/// Per-project media management choices. Every field is optional: nil follows the app default. Stored as one optional
/// key of the project that older readers ignore.
public struct MediaPolicy: Codable, Hashable, Sendable {
    public var outside: OutsideMediaMode?
    /// Copy library items used in a sequence into `Files/Library/`.
    public var copyLibraryItems: Bool?
    /// Watch the project folder: new files appear in the bin.
    public var watchFolder: Bool?
    /// Project-relative paths of files that were removed from the bin but stay in the project folder: the folder
    /// watcher and the open scan do not add them again. Importing the file by hand removes it from the list.
    public var ignored: [String]?

    public init(outside: OutsideMediaMode? = nil, copyLibraryItems: Bool? = nil, watchFolder: Bool? = nil, ignored: [String]? = nil) {
        self.outside = outside; self.copyLibraryItems = copyLibraryItems; self.watchFolder = watchFolder; self.ignored = ignored
    }

    public var isEmpty: Bool { outside == nil && copyLibraryItems == nil && watchFolder == nil && ignored == nil }
}

/// App-wide defaults (Settings > Media) that a project's `MediaPolicy` overrides.
public struct MediaPolicyDefaults: Sendable, Equatable {
    public var outside: OutsideMediaMode
    public var copyLibraryItems: Bool
    public var watchFolder: Bool
    public init(outside: OutsideMediaMode = .ask, copyLibraryItems: Bool = true, watchFolder: Bool = true) {
        self.outside = outside; self.copyLibraryItems = copyLibraryItems; self.watchFolder = watchFolder
    }
}

/// One new file found in the project folder, with the bin path that mirrors its folder.
public struct FolderSyncAdd: Sendable, Equatable {
    public var path: String
    public var bin: [String]
    public init(path: String, bin: [String]) { self.path = path; self.bin = bin }
}

extension MediaManagement {
    public static let importedFolderName = "Imported"
    public static let libraryFolderName = "Library"

    /// `Files/Imported/`: copies of outside media (flat). Created on the first copy, not with the project.
    public static func importedFolder(forProjectAt url: URL) -> URL {
        filesFolder(forProjectAt: url).appendingPathComponent(importedFolderName, isDirectory: true)
    }

    /// `Files/Library/`: library items used in a sequence. Created on the first copy.
    public static func libraryFolder(forProjectAt url: URL) -> URL {
        filesFolder(forProjectAt: url).appendingPathComponent(libraryFolderName, isDirectory: true)
    }

    /// The project folder (`<Name>/`) of a project in a project folder; nil for a loose project file.
    public static func projectFolder(forProjectAt url: URL?) -> URL? {
        guard let url, isProjectFolderLayout(url) else { return nil }
        return url.deletingLastPathComponent()
    }

    public enum Disposition: Sendable, Equatable {
        /// Use the file where it is: it is inside the project folder, or the choice is "leave".
        case link
        /// Outside the project folder and the project asks.
        case ask
        /// Outside the project folder: copy or move it into `Files/Imported/` without asking.
        case apply(ImportMode)
    }

    /// The effective outside-media mode of a project: its own choice, else an explicit older import mode, else the app default.
    public static func outsideMode(of project: Project, defaults: MediaPolicyDefaults) -> OutsideMediaMode {
        project.mediaPolicy?.outside ?? project.importMode.map(OutsideMediaMode.init) ?? defaults.outside
    }

    public static func copiesLibraryItems(_ project: Project, projectURL: URL?, defaults: MediaPolicyDefaults) -> Bool {
        projectFolder(forProjectAt: projectURL) != nil && (project.mediaPolicy?.copyLibraryItems ?? defaults.copyLibraryItems)
    }

    public static func watchesFolder(_ project: Project, projectURL: URL?, defaults: MediaPolicyDefaults) -> Bool {
        guard let folder = projectFolder(forProjectAt: projectURL), project.mediaPolicy?.watchFolder == true else { return false }
        return isWatchableFolder(folder)
    }

    /// A folder that can be a project's own home: not the home folder, one of its standard top-level folders, a volume
    /// root or the system root (watching and scanning those would pull in the user's whole library).
    public static func isWatchableFolder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        var forbidden: Set<String> = ["/", "/Users", "/Volumes", home]
        for name in ["Movies", "Documents", "Desktop", "Downloads", "Music", "Pictures"] { forbidden.insert(home + "/" + name) }
        if forbidden.contains(path) { return false }
        let comps = URL(fileURLWithPath: path).pathComponents
        return !(comps.count == 3 && comps[1] == "Volumes")
    }

    /// Rule by location: inside the project folder is linked in place, never asked, never copied. Outside follows the
    /// project's mode. Loose project files (no project folder) and unsaved projects never ask: only an explicit older
    /// import mode applies there.
    public static func disposition(forPath path: String, project: Project, projectURL: URL?,
                                   defaults: MediaPolicyDefaults) -> Disposition {
        guard let url = projectURL else { return .link }
        guard let folder = projectFolder(forProjectAt: url) else {
            return project.importMode.map { $0 == .leave ? .link : .apply($0) } ?? .link
        }
        if isInside(path, folder: folder) { return .link }
        switch outsideMode(of: project, defaults: defaults) {
        case .ask: return .ask
        case .leave: return .link
        case .copy: return .apply(.copy)
        case .move: return .apply(.move)
        }
    }

    /// Media files used by the project that sit outside the project folder (distinct paths, existing files only;
    /// `ignore` skips app-owned paths such as rendered strips in the cache). Empty for loose project files.
    public static func outsideMedia(_ media: [MediaRef], projectURL: URL?, exists: (String) -> Bool,
                                    ignore: (String) -> Bool = { _ in false }) -> [MediaRef] {
        guard let folder = projectFolder(forProjectAt: projectURL) else { return [] }
        var seen = Set<String>()
        return media.filter { m in
            !isInside(m.path, folder: folder) && !ignore(m.path) && exists(m.path) && seen.insert(m.path).inserted
        }
    }

    /// Status-bar text for `count` outside files; nil for none.
    public static func outsideHint(count: Int) -> String? {
        count == 0 ? nil : "\(count) \(count == 1 ? "file" : "files") outside the project folder"
    }

    // MARK: Watching the project folder

    /// New files in the project folder: `files` (absolute paths found by a scan) that the project does not know yet.
    /// Skips hidden items, project packages, `Exports/` and copy leftovers; paths in `ignoring` (copies still being
    /// written by this app) are skipped. The bin path mirrors the folder below the project folder; files sitting directly
    /// in the project folder land in the root bin. Sorted by path.
    public static func folderSyncPlan(files: [String], projectFolder: URL, known: Set<String>, ignoring: Set<String> = [],
                                      ignoredRelative: [String] = []) -> [FolderSyncAdd] {
        let ignoredRel = Set(ignoredRelative.map { $0.lowercased() })
        let root = projectFolder.standardizedFileURL.pathComponents
        func key(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path.lowercased() }
        let skip = Set(known.map(key)).union(ignoring.map(key))
        var out: [FolderSyncAdd] = []
        for f in files {
            let url = URL(fileURLWithPath: f).standardizedFileURL
            let comps = url.pathComponents
            guard comps.count > root.count, Array(comps.prefix(root.count)) == root else { continue }
            let rel = Array(comps.dropFirst(root.count))
            if rel.contains(where: { $0.hasPrefix(".") || $0.hasSuffix("." + ProjectFile.fileExtension) || $0.hasSuffix(".ssproj") }) { continue }
            if rel.first == exportsFolderName, rel.count > 1 { continue }
            if skip.contains(key(f)) { continue }
            if !ignoredRel.isEmpty, ignoredRel.contains(rel.joined(separator: "/").lowercased()) { continue }
            out.append(FolderSyncAdd(path: url.path, bin: Array(rel.dropLast())))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// A file seen by a scan: where it is, how big and when it was last written.
    public struct SeenFile: Sendable, Equatable {
        public var path: String
        public var size: Int64
        public var modified: Date
        public init(path: String, size: Int64, modified: Date) { self.path = path; self.size = size; self.modified = modified }
    }

    /// Files that are not being written: unchanged for `quiet` seconds and the same size as at the previous scan
    /// (`previous`, path to size). `unsettled` says that some file was held back, so another scan is due soon.
    public static func settled(_ seen: [SeenFile], previous: [String: SeenFile], now: Date = Date(),
                               quiet: TimeInterval = 2) -> (stable: [String], unsettled: Bool) {
        var stable: [String] = [], unsettled = false
        for f in seen {
            // Two scans with the same size and modification time, and untouched for `quiet` seconds.
            if now.timeIntervalSince(f.modified) < quiet || previous[f.path] != f {
                unsettled = true
            } else {
                stable.append(f.path)
            }
        }
        return (stable, unsettled)
    }

    /// Size and modification date of each path (file system; call off the main thread). Missing files are left out.
    public static func stat(_ paths: [String]) -> [SeenFile] {
        paths.compactMap { p in
            guard let a = try? FileManager.default.attributesOfItem(atPath: p),
                  let size = (a[.size] as? NSNumber)?.int64Value, let date = a[.modificationDate] as? Date else { return nil }
            return SeenFile(path: p, size: size, modified: date)
        }
    }

    /// `path` below `folder` as a "/"-joined relative path; nil when it is not below.
    public static func relativePath(of path: String, in folder: URL) -> String? {
        let root = folder.standardizedFileURL.pathComponents
        let comps = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard comps.count > root.count, Array(comps.prefix(root.count)).map({ $0.lowercased() }) == root.map({ $0.lowercased() }) else { return nil }
        return comps.dropFirst(root.count).joined(separator: "/")
    }

    /// A stored LUT path as a file path. An absolute path loads as stored; when that file is gone the copy with the same
    /// name in `<project>/Files/Library/` stands in. A relative path (`Files/Library/x.cube`, the form older builds
    /// wrote) resolves below the project folder; nil when there is no project folder or it points outside it (`../`).
    public static func resolveStoredPath(_ stored: String, projectFolder: URL?) -> String? {
        guard !stored.isEmpty else { return nil }
        let fm = FileManager.default
        if LocalPath.isAbsolute(stored) {
            if fm.fileExists(atPath: stored) { return stored }
            guard let projectFolder else { return stored }
            // Limit: a missing file is replaced by any same-named LUT in Files/Library; we cannot tell it from another one.
            let copy = libraryFolder(in: projectFolder).appendingPathComponent(URL(fileURLWithPath: stored).lastPathComponent)
            return fm.fileExists(atPath: copy.path) ? copy.path : stored
        }
        guard let projectFolder else { return nil }
        let root = projectFolder.standardizedFileURL
        let url = root.appendingPathComponent(stored).standardizedFileURL
        return relativePath(of: url.path, in: root) == nil ? nil : url.path
    }

    /// `<project>/Files/Library/`, where collected library items (LUTs) live.
    public static func libraryFolder(in projectFolder: URL) -> URL {
        projectFolder.appendingPathComponent("Files", isDirectory: true).appendingPathComponent("Library", isDirectory: true)
    }

    /// Every regular file below `folder` accepted by `isMedia` (lowercased extension), skipping hidden files and
    /// packages. File system only; call off the main thread.
    static let skippedTopLevelFolders: Set<String> = [exportsFolderName.lowercased(), "proxies", "proxy", "cache", "caches"]

    public static func scanFiles(in folder: URL, isMedia: (String) -> Bool) -> [String] {
        var out: [String] = []
        FileWalk.walk(folder, keys: [.isRegularFileKey]) { u, v, level in
            // Our own output folders are never walked: exports and proxies are not footage.
            // Linux and Windows have no package bit: our own project bundles are skipped by extension there.
            if u.pathExtension.lowercased() == "sqproj" || u.pathExtension.lowercased() == "ssproj" { return .skip }
            if level == 1, skippedTopLevelFolders.contains(u.lastPathComponent.lowercased()) { return .skip }
            if v?.isRegularFile == true, isMedia(u.pathExtension.lowercased()) { out.append(u.path) }
            return .descend
        }
        return out
    }
}

/// A Move whose original is trashed only after a save that contains the copy's path.
public struct PendingMove: Sendable, Equatable {
    public var id: MediaRef.ID
    public var original: String
    public var copy: String
    public init(id: MediaRef.ID, original: String, copy: String) { self.id = id; self.original = original; self.copy = copy }

    /// The moves whose item the saved project still points at the copy for. An item that was removed or undone before
    /// the save never trashes its original.
    /// An original that any media item of the saved project still uses (same path, or the same file through standardized
    /// paths and symlinks) is never ready: another bin item needs it.
    public static func ready(_ pending: [PendingMove], savedMedia: [MediaRef],
                             resolve: (String) -> String = PendingMove.resolved) -> [PendingMove] {
        let byID = Dictionary(savedMedia.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        let used = Set(savedMedia.map { resolve($0.path).lowercased() })
        return pending.filter { byID[$0.id] == $0.copy && !used.contains(resolve($0.original).lowercased()) }
    }

    public static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension Project {
    /// Remembers that the user removed this file from the bin although it stays in the project folder.
    public mutating func ignoreFolderFile(_ path: String, projectFolder: URL) {
        guard let rel = MediaManagement.relativePath(of: path, in: projectFolder) else { return }
        var policy = mediaPolicy ?? MediaPolicy()
        var list = policy.ignored ?? []
        guard !list.contains(where: { $0.caseInsensitiveCompare(rel) == .orderedSame }) else { return }
        list.append(rel)
        policy.ignored = list
        mediaPolicy = policy
    }

    /// The file is wanted again (imported by hand): it leaves the ignored list.
    public mutating func unignoreFolderFile(_ path: String, projectFolder: URL) {
        guard var policy = mediaPolicy, var list = policy.ignored, let rel = MediaManagement.relativePath(of: path, in: projectFolder) else { return }
        list.removeAll { $0.caseInsensitiveCompare(rel) == .orderedSame }
        policy.ignored = list.isEmpty ? nil : list
        mediaPolicy = policy.isEmpty ? nil : policy
    }

    /// The bin reached by `path` below the root (`["Day 1", "A-cam"]`), created when missing. `[]` is the root bin.
    @discardableResult
    public mutating func binID(path: [String], create: Bool = true, newIDs: [String: Bin.ID] = [:]) -> Bin.ID? {
        var current = rootBin.id
        for (depth, name) in path.enumerated() {
            let existing = rootBin.bin(current)?.children.compactMap { item -> Bin? in
                if case .bin(let b) = item, b.name.caseInsensitiveCompare(name) == .orderedSame { return b }
                return nil
            }.first
            if let existing { current = existing.id; continue }
            guard create else { return nil }
            if let fixed = newIDs[Project.binKey(Array(path[...depth]))] {
                let made = Bin(id: fixed, name: name)              // the same id in every history state
                guard rootBin.modify(current, { $0.children.append(.bin(made)) }) else { return nil }
                current = made.id
            } else {
                guard let made = newBin(name: name, in: current) else { return nil }
                current = made
            }
        }
        return current
    }

    /// Key of a bin path in the `newIDs` of `binID` and `addSynced`.
    public static func binKey(_ path: [String]) -> String { path.map { $0.lowercased() }.joined(separator: "/") }

    /// One fresh id per bin path (and each of its parents) that `items` may need. Make it once, outside an `amend` closure.
    public static func newBinIDs(for items: [(ref: MediaRef, bin: [String])]) -> [String: Bin.ID] {
        var out: [String: Bin.ID] = [:]
        for item in items {
            for depth in item.bin.indices {
                let key = binKey(Array(item.bin[...depth]))
                if out[key] == nil { out[key] = UUID() }
            }
        }
        return out
    }

    /// Files probed items into the bins that mirror their folders. Items already in the project (same path) are skipped.
    /// Returns how many were added.
    @discardableResult
    public mutating func addSynced(_ items: [(ref: MediaRef, bin: [String])], newBinIDs: [String: Bin.ID] = [:]) -> Int {
        var known = Set(media.map(\.path))
        var added = 0
        for (ref, bin) in items where known.insert(ref.path).inserted {
            add(ref)
            if !bin.isEmpty, let dest = binID(path: bin, newIDs: newBinIDs) { _ = move([.media(ref.id)], to: dest) }
            added += 1
        }
        return added
    }
}
