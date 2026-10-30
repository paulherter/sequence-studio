import Foundation

/// Finds media files whose recorded path is stale (imported projects: Premiere stores absolute paths from another
/// machine or volume, Windows drive paths, sometimes a relative path). Order: the path as stored; the relative path
/// against the project folder; the same file name in the project folder (and subfolders) and its parent; then the
/// same name in folders the user chose with Locate. Names compare case-insensitively; a known size must match; when
/// several files share the name, the one whose folders match the stored path's trailing folders wins, else none
/// (camera names like C0001.MP4 repeat across cards: never guess). File system only, no media probing.
public struct MediaPathResolver: Sendable {
    public enum Method: Sendable, Equatable { case storedPath, relativePath, projectFolder, searchFolder }

    public struct Hit: Sendable, Equatable {
        public var path: String
        public var method: Method
        public init(path: String, method: Method) { self.path = path; self.method = method }
    }

    public struct Request: Sendable, Equatable {
        public var storedPath: String
        public var relativePath: String?
        /// Recorded file size; nil or 0 = unknown.
        public var size: Int64?
        public init(storedPath: String, relativePath: String? = nil, size: Int64? = nil) {
            self.storedPath = storedPath; self.relativePath = relativePath; self.size = size
        }
    }

    public var projectFolder: URL?
    public var searchFolders: [URL]
    /// Folder levels searched below the project folder / its parent / a Locate folder.
    public var projectDepth = 5, parentDepth = 1, searchDepth = 12

    public init(projectFolder: URL? = nil, searchFolders: [URL] = []) {
        self.projectFolder = projectFolder; self.searchFolders = searchFolders
    }

    /// The last component of a POSIX or Windows path.
    public static func fileName(of path: String) -> String {
        String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path))
    }

    /// Folder components of a POSIX or Windows path (without the file name and drive letter).
    static func folders(of path: String) -> [String] {
        Array(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().map(String.init))
    }

    /// Hits keyed by `storedPath`; unresolved requests are absent. Synchronous file I/O: call off the main thread.
    public func resolve(_ requests: [Request]) -> [String: Hit] {
        var hits: [String: Hit] = [:]
        var open: [Request] = []
        for r in requests where hits[r.storedPath] == nil {
            if LocalPath.isAbsolute(r.storedPath), Self.isFile(r.storedPath, size: r.size) {
                hits[r.storedPath] = Hit(path: r.storedPath, method: .storedPath)
            } else if let rel = r.relativePath, !rel.isEmpty, let pf = projectFolder {
                let p = pf.appendingPathComponent(rel.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL.path
                if Self.isFile(p, size: r.size) { hits[r.storedPath] = Hit(path: p, method: .relativePath) } else { open.append(r) }
            } else {
                open.append(r)
            }
        }
        guard !open.isEmpty else { return hits }

        let wanted = Set(open.map { Self.fileName(of: $0.storedPath).lowercased() })
        var roots: [(URL, Int)] = []
        if let pf = projectFolder { roots = [(pf, projectDepth), (pf.deletingLastPathComponent(), parentDepth)] }
        let near = RelinkScanner.scan(roots: roots, named: wanted)
        for r in open {
            if let p = Self.pick(near, for: r.storedPath, size: r.size) { hits[r.storedPath] = Hit(path: p, method: .projectFolder) }
        }
        let rest = open.filter { hits[$0.storedPath] == nil }
        guard !rest.isEmpty, !searchFolders.isEmpty else { return hits }
        let far = RelinkScanner.scan(roots: searchFolders.map { ($0, searchDepth) },
                                     named: Set(rest.map { Self.fileName(of: $0.storedPath).lowercased() }))
        for r in rest {
            if let p = Self.pick(far, for: r.storedPath, size: r.size) { hits[r.storedPath] = Hit(path: p, method: .searchFolder) }
        }
        return hits
    }

    /// The one candidate for `storedPath`: same name (case-insensitive), same size when `size` is known; among several,
    /// the strictly best match of trailing folder names; nil when none or a tie.
    public static func pick(_ candidates: [RelinkCandidate], for storedPath: String, size: Int64?) -> String? {
        let name = fileName(of: storedPath).lowercased()
        var list = candidates.filter { fileName(of: $0.path).lowercased() == name }
        if let s = size, s > 0 { list = list.filter { $0.size == s } }
        if list.count <= 1 { return list.first?.path }
        let want = folders(of: storedPath).map { $0.lowercased() }
        let scored = list.map { c -> (String, Int) in
            let have = folders(of: c.path).map { $0.lowercased() }
            return (c.path, zip(have.reversed(), want.reversed()).prefix { $0 == $1 }.count)
        }.sorted { $0.1 > $1.1 }
        return scored[0].1 > scored[1].1 ? scored[0].0 : nil
    }

    private static func isFile(_ path: String, size: Int64?) -> Bool {
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &dir), !dir.boolValue else { return false }
        guard let s = size, s > 0 else { return true }
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value == s
    }
}

/// Walks folders for files with wanted names (Locate and the import resolver).
public enum RelinkScanner {
    /// Files below each folder (any depth) whose lower-cased name is in `named`.
    public static func scan(folders: [URL], named: Set<String>) -> [RelinkCandidate] {
        scan(roots: folders.map { ($0, Int.max) }, named: named)
    }

    /// `roots`: folder and the number of folder levels to descend (0 = only its own files). Hidden files and package
    /// contents are skipped; a file met twice (overlapping roots) is listed once.
    public static func scan(roots: [(URL, Int)], named: Set<String>) -> [RelinkCandidate] {
        guard !named.isEmpty else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        var seen = Set<String>()
        var out: [RelinkCandidate] = []
        for (root, depth) in roots {
            FileWalk.walk(root, keys: keys) { url, v, level in
                if v?.isDirectory == true { return level > depth ? .skip : .descend }
                guard v?.isRegularFile == true, named.contains(url.lastPathComponent.lowercased()) else { return .descend }
                let path = url.standardizedFileURL.path
                if seen.insert(path).inserted {
                    out.append(RelinkCandidate(path: path, size: Int64(v?.fileSize ?? -1), modified: v?.contentModificationDate))
                }
                return .descend
            }
        }
        return out
    }
}
