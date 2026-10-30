import Foundation
import SQProxy
import SQMedia
import SQAnalysis
import SQLibrary

/// The one place that decides where Sequence Studio keeps cache, proxies, scratch files and new projects.
/// Everything else asks this resolver; nothing builds a cache path by hand. Pure value, no I/O except in
/// `validate` and `migrate`.
public struct StorageLocations: Equatable, Sendable {
    /// User-picked roots; nil means the default.
    public var cacheFolder: URL?
    public var scratchFolder: URL?
    public var projectsFolder: URL?

    public init(cacheFolder: URL? = nil, scratchFolder: URL? = nil, projectsFolder: URL? = nil) {
        self.cacheFolder = cacheFolder; self.scratchFolder = scratchFolder; self.projectsFolder = projectsFolder
    }

    public enum Key {
        /// Same key `AppSettings` has always written (`settings.cacheFolder`): one value, two readers.
        public static let cache = AppSettings.Key.cache
        public static let scratch = "sq.storage.scratchFolder"
        public static let projects = "sq.storage.projectsFolder"
    }

    public var cacheRoot: URL { cacheFolder ?? AppSettings.defaultCacheFolder }

    /// Proxies stay at their historic default until a cache folder is picked, then live in `<cache>/Proxies`.
    public var proxyDirectory: URL {
        guard let cacheFolder else { return ProxyCache.defaultDirectory }
        return cacheFolder.appendingPathComponent("Proxies", isDirectory: true)
    }

    /// Preview render cache files (`RenderCacheStore`).
    public var renderCacheDirectory: URL { cacheRoot.appendingPathComponent("RenderCache", isDirectory: true) }
    public var waveformDirectory: URL { cacheRoot.appendingPathComponent("Waveforms", isDirectory: true) }

    /// Temporary working files (renders in progress, extracted audio): `<cache>/Scratch` unless picked.
    public var scratchRoot: URL { scratchFolder ?? cacheRoot.appendingPathComponent("Scratch", isDirectory: true) }

    /// Where new projects are suggested: ~/Movies/Sequence Studio unless picked.
    public var projectsRoot: URL {
        if let projectsFolder { return projectsFolder }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent("Sequence Studio", isDirectory: true)
    }

    /// Points the waveform disk cache at `waveformDirectory`. Called at launch and on a cache folder change.
    public func applyWaveformDirectory() {
        #if os(macOS)
        WaveformDiskCache.configureShared(directory: waveformDirectory)
        #endif
    }

    /// Points the analysis caches (stabilization, subject masks, mattes) and the library preview cache at `<cache>/<Name>`.
    /// A default cache folder keeps every cache where it always was. Matte stores follow at the next launch.
    public func applyAnalysisAndPreviewRoots() {
        AnalysisCacheLocation.configure(root: cacheFolder)
        PreviewCache.configureCacheRoot(cacheFolder)
    }

    /// Where Quick Export writes when there is no project folder and no earlier export: the projects root, created.
    public var exportFallbackDirectory: URL? { ensuredProjectsRoot() }

    /// A scratch subfolder (`<scratchRoot>/<name>`), created on demand. nil when it cannot be created.
    public func scratchDirectory(_ name: String) -> URL? {
        let u = scratchRoot.appendingPathComponent(name, isDirectory: true)
        do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) } catch { return nil }
        return u
    }

    /// The projects root, created on demand (nil when its disk is gone or read-only).
    public func ensuredProjectsRoot() -> URL? {
        let u = projectsRoot
        do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) } catch { return nil }
        return u
    }

    public static func load(from d: UserDefaults = .standard) -> StorageLocations {
        func url(_ key: String) -> URL? {
            guard let p = d.string(forKey: key), isAbsolutePath(p) else { return nil }
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return StorageLocations(cacheFolder: url(Key.cache), scratchFolder: url(Key.scratch), projectsFolder: url(Key.projects))
    }

    public func save(to d: UserDefaults = .standard) {
        func put(_ u: URL?, _ key: String) { if let u { d.set(u.path, forKey: key) } else { d.removeObject(forKey: key) } }
        put(cacheFolder, Key.cache); put(scratchFolder, Key.scratch); put(projectsFolder, Key.projects)
    }

    // MARK: Validation

    /// An absolute folder path on macOS ("/…") or Windows ("C:/…", "C:\…", "/C:/…" from a file URL, "\\server\share").
    public static func isAbsolutePath(_ p: String) -> Bool {
        if p.hasPrefix("/") || p.hasPrefix("\\\\") { return true }
        let c = Array(p.utf8)
        guard c.count >= 3, (65...90).contains(c[0]) || (97...122).contains(c[0]), c[1] == UInt8(ascii: ":") else { return false }
        return c[2] == UInt8(ascii: "/") || c[2] == UInt8(ascii: "\\")
    }

    public enum Problem: Equatable, Sendable {
        case notAbsolute, notAFolder, notWritable
        case notEnoughSpace(free: Int64, needed: Int64)

        public var message: String {
            switch self {
            case .notAbsolute: return "Choose a folder on a disk."
            case .notAFolder: return "That is a file, not a folder."
            case .notWritable: return "Sequence Studio cannot write to that folder."
            case .notEnoughSpace(let free, let needed):
                let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                return "Only \(f) free, \(n) needed."
            }
        }
    }

    /// Free bytes on the volume holding `url`, or nil when unknown.
    public static func freeBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        #if os(macOS)
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
        #else
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        #endif
    }

    /// nil when `url` can serve as a storage root: absolute, a folder (or creatable), writable, enough space.
    /// An unknown free size passes. Creates a missing folder (a pick must be usable at once).
    public static func validate(_ url: URL, requiredBytes: Int64 = 0,
                                freeBytes: (URL) -> Int64? = StorageLocations.freeBytes(at:)) -> Problem? {
        guard url.isFileURL || url.scheme == nil, isAbsolutePath(url.path) else { return .notAbsolute }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { return .notAFolder }
        } else {
            do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch { return .notWritable }
        }
        guard fm.isWritableFile(atPath: url.path) else { return .notWritable }
        if requiredBytes > 0, let free = freeBytes(url), free < requiredBytes {
            return .notEnoughSpace(free: free, needed: requiredBytes)
        }
        return nil
    }

    // MARK: Migration

    public struct MigrationReport: Equatable, Sendable { public var copied = 0, skipped = 0, failed = 0 }

    /// Copies everything under `old` into `new`, keeping relative paths. Never deletes the old data and never
    /// overwrites a file already in `new`. Refuses identical or nested folders (a copy into itself would recurse).
    @discardableResult
    public static func migrate(from old: URL, to new: URL) -> MigrationReport {
        var report = MigrationReport()
        let fm = FileManager.default
        let src = old.standardizedFileURL.resolvingSymlinksInPath().path
        let dst = new.standardizedFileURL.resolvingSymlinksInPath().path
        guard src != dst, !dst.hasPrefix(src + "/"), !src.hasPrefix(dst + "/"),
              let e = fm.enumerator(atPath: src) else { return report }
        do { try fm.createDirectory(atPath: dst, withIntermediateDirectories: true) } catch { report.failed += 1; return report }
        for case let rel as String in e {
            let item = URL(fileURLWithPath: src).appendingPathComponent(rel)
            let target = URL(fileURLWithPath: dst).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            if fm.fileExists(atPath: target.path) { report.skipped += 1; continue }
            do { try fm.copyItem(at: item, to: target); report.copied += 1 } catch { report.failed += 1 }
        }
        return report
    }
}
