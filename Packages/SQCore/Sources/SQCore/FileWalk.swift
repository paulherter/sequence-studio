import Foundation

/// Depth-first walk below a folder, in place of `FileManager.enumerator` + `skipDescendants()`: on Windows
/// (swift-corelibs-foundation, Swift 6.3.3) the enumerator stops descending into every later folder once
/// `skipDescendants()` was called, and it does not treat dot files as hidden. One walk, same result on every system.
/// On Windows the same Foundation traps (0xC000001D) in `URL.resourceValues` for any key on a file whose size has bit
/// 31 set in its low 32 bits (2-4 GiB, 6-8 GiB, ...: camera clips), so `Values` there come from `attributesOfItem`.
public enum FileWalk {
    /// What the walk knows of an item: the `URLResourceValues` fields its callers read.
    public struct Values: Sendable, Equatable {
        public var isDirectory: Bool?
        public var isRegularFile: Bool?
        public var isPackage: Bool?
        public var isSymbolicLink: Bool?
        public var fileSize: Int?
        public var contentModificationDate: Date?

        public init(isDirectory: Bool? = nil, isRegularFile: Bool? = nil, isPackage: Bool? = nil,
                    isSymbolicLink: Bool? = nil, fileSize: Int? = nil, contentModificationDate: Date? = nil) {
            self.isDirectory = isDirectory; self.isRegularFile = isRegularFile; self.isPackage = isPackage
            self.isSymbolicLink = isSymbolicLink; self.fileSize = fileSize; self.contentModificationDate = contentModificationDate
        }

        public init(_ v: URLResourceValues) {
            self.init(isDirectory: v.isDirectory, isRegularFile: v.isRegularFile, isPackage: v.isPackage,
                      isSymbolicLink: v.isSymbolicLink, fileSize: v.fileSize, contentModificationDate: v.contentModificationDate)
        }

        /// The item's values (`keys` where the system reads per key); nil when it cannot be read. Safe for every file
        /// size on Windows, unlike `URL.resourceValues` there.
        public static func read(_ url: URL, keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey,
                                .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) -> Values? {
            #if os(Windows)
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            let type = a[.type] as? FileAttributeType
            var size: Int?
            if let n = a[.size] as? NSNumber { size = n.intValue } else if let u = a[.size] as? UInt64 { size = Int(u) }
            else if let i = a[.size] as? Int { size = i }
            return Values(isDirectory: type == .typeDirectory, isRegularFile: type == .typeRegular, isPackage: false,
                          isSymbolicLink: type == .typeSymbolicLink, fileSize: type == .typeRegular ? size : nil,
                          contentModificationDate: a[.modificationDate] as? Date)
            #else
            return (try? url.resourceValues(forKeys: keys)).map(Values.init)
            #endif
        }
    }

    public enum Step: Sendable, Equatable {
        /// Walk into this folder (ignored for files).
        case descend
        /// Do not walk into this folder.
        case skip
        /// End the whole walk.
        case stop
    }

    /// Calls `visit(url, values, level)` for every item below `root` (level 1 = a direct child), a folder before its
    /// contents. Hidden items (dot names everywhere, the hidden flag where the system has one) are left out; the
    /// contents of packages (macOS bundles) are never visited. `values` holds `keys` plus `.isDirectoryKey` (on Windows
    /// always all `Values` fields). Returns false when `visit` stopped the walk.
    @discardableResult
    public static func walk(_ root: URL, keys: [URLResourceKey] = [],
                            visit: (URL, Values?, Int) -> Step) -> Bool {
        let all = Array(Set(keys + [.isDirectoryKey, .isPackageKey]))
        return walk(root, level: 1, keys: all, visit: visit)
    }

    private static func walk(_ folder: URL, level: Int, keys: [URLResourceKey],
                             visit: (URL, Values?, Int) -> Step) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return true }
        let keySet = Set(keys)
        for url in items where !url.lastPathComponent.hasPrefix(".") {
            let values = Values.read(url, keys: keySet)
            let step = visit(url, values, level)
            if step == .stop { return false }
            guard step == .descend, values?.isDirectory == true, values?.isPackage != true else { continue }
            if !walk(url, level: level + 1, keys: keys, visit: visit) { return false }
        }
        return true
    }
}

/// Path spelling checks that hold on macOS, Linux and Windows.
public enum LocalPath {
    /// An absolute path of this system: `/...` everywhere; on Windows also `C:/`, `C:\` and UNC `\\server\share`.
    /// A Windows-style path read on the Mac (from a Premiere project) is not absolute here: it cannot name a local file.
    public static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        #if os(Windows)
        if path.hasPrefix("\\\\") { return true }
        let c = Array(path.utf8.prefix(3))
        if c.count == 3, (c[0] | 0x20) >= UInt8(ascii: "a"), (c[0] | 0x20) <= UInt8(ascii: "z"), c[1] == UInt8(ascii: ":"),
           c[2] == UInt8(ascii: "/") || c[2] == UInt8(ascii: "\\") { return true }
        #endif
        return false
    }
}
