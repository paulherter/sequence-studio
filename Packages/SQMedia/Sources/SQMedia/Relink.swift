import CryptoKit
import Foundation
import SQCore

/// Finds offline media (Premiere "Link Media" behavior). No UI; returns value types.
public struct RelinkCandidate: Sendable, Hashable {
    /// Higher is better.
    public enum Score: Int, Sendable, Comparable {
        case nameOnly = 1, nameSize = 2, fingerprint = 3
        public static func < (a: Score, b: Score) -> Bool { a.rawValue < b.rawValue }
    }
    public var url: URL
    public var score: Score
}

public enum LocateMethod: Sendable, Equatable {
    case bookmark, originalPath, projectNeighbour, fingerprint
}

public struct LocateResult: Sendable {
    public struct Resolved: Sendable { public var url: URL; public var method: LocateMethod }
    /// Set only when the answer is certain (bookmark, original path, or a unique fingerprint match).
    public var resolved: Resolved?
    /// Ranked best first; empty when `resolved` came from bookmark/original path.
    public var candidates: [RelinkCandidate]
}

public struct RelinkReport: Sendable, Equatable {
    public var relinked: [UUID: URL] = [:]
    /// Mapped file exists but its fingerprint differs.
    public var fingerprintMismatch: [UUID] = []
    /// Nothing at the mapped path (or ref outside the moved folder).
    public var missing: [UUID] = []
}

public struct MediaLocator: Sendable {
    public var projectFolder: URL?
    public var searchFolders: [URL]
    public var maxDepth: Int
    /// Optional duration probe (AVFoundation lives elsewhere); used to demote name matches whose duration differs.
    public var durationProbe: (@Sendable (URL) -> Time?)?

    public init(projectFolder: URL? = nil, searchFolders: [URL] = [], maxDepth: Int = 6,
                durationProbe: (@Sendable (URL) -> Time?)? = nil) {
        self.projectFolder = projectFolder; self.searchFolders = searchFolders
        self.maxDepth = maxDepth; self.durationProbe = durationProbe
    }

    // MARK: Fingerprint (same scheme as MediaImporter: size + SHA-256 of the first 64 KB)

    public static func fingerprint(of url: URL) -> MediaFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return MediaFingerprint(size: size, modified: attrs[.modificationDate] as? Date, headHash: headHash(url))
    }

    static func headHash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: 64 * 1024) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ fp: MediaFingerprint, _ url: URL) -> Bool {
        guard let n = fingerprint(of: url), n.size == fp.size, let h = fp.headHash else { return false }
        return n.headHash == h
    }

    // MARK: Locate

    /// Synchronous and I/O heavy: hashes the head of every plausible file it meets and walks the search folders.
    /// Never call it on the main thread; run it from a background task.
    ///
    /// A bookmark or original-path hit is only `resolved` when it still matches the stored fingerprint (if one with a
    /// head hash is stored); a file that exists but differs is demoted to a candidate.
    public func locate(_ ref: MediaRef) -> LocateResult {
        let fm = FileManager.default
        let verifies = ref.fingerprint.headHash != nil
        var demoted: [URL] = []
        if let data = ref.bookmark, let u = Self.resolveBookmark(data), fm.fileExists(atPath: u.path) {
            if !verifies || Self.matches(ref.fingerprint, u) {
                return LocateResult(resolved: .init(url: u, method: .bookmark), candidates: [])
            }
            demoted.append(u)
        }
        if fm.fileExists(atPath: ref.path) {
            let u = URL(fileURLWithPath: ref.path)
            if !verifies || Self.matches(ref.fingerprint, u) {
                return LocateResult(resolved: .init(url: u, method: .originalPath), candidates: [])
            }
            demoted.append(u)
        }

        let originalDir = URL(fileURLWithPath: ref.path).deletingLastPathComponent().path
        var seen = Set<String>()
        var found: [RelinkCandidate] = []
        var neighbourHits = Set<String>()

        func consider(_ url: URL, neighbour: Bool, force: Bool = false) {
            let key = url.resolvingSymlinksInPath().path
            guard seen.insert(key).inserted else { return }
            guard let c = score(url, for: ref) ?? (force ? RelinkCandidate(url: url, score: .nameOnly) : nil) else { return }
            found.append(c)
            if neighbour { neighbourHits.insert(key) }
        }

        for u in demoted { consider(u, neighbour: false, force: true) }
        if let pf = projectFolder {
            for (root, depth) in [(pf, 3), (pf.deletingLastPathComponent(), 2)] {
                walk(root, depth: min(depth, maxDepth)) { consider($0, neighbour: true) }
            }
        }
        for f in searchFolders { walk(f, depth: maxDepth) { consider($0, neighbour: false) } }

        let ranked = found.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let pa = Self.commonPrefix(a.url.deletingLastPathComponent().path, originalDir)
            let pb = Self.commonPrefix(b.url.deletingLastPathComponent().path, originalDir)
            if pa != pb { return pa > pb }
            return a.url.path < b.url.path
        }
        let exact = ranked.filter { $0.score == .fingerprint }
        if exact.count == 1, let e = exact.first {
            let sameName = e.url.lastPathComponent.caseInsensitiveCompare(ref.name) == .orderedSame
            let isNeighbour = neighbourHits.contains(e.url.resolvingSymlinksInPath().path)
            return LocateResult(resolved: .init(url: e.url, method: (sameName && isNeighbour) ? .projectNeighbour : .fingerprint),
                                candidates: ranked)
        }
        return LocateResult(resolved: nil, candidates: ranked)
    }

    private func score(_ url: URL, for ref: MediaRef) -> RelinkCandidate? {
        let fp = ref.fingerprint
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        let sameName = url.lastPathComponent.caseInsensitiveCompare(ref.name) == .orderedSame
        let sameSize = size == fp.size
        if sameSize, Self.matches(fp, url) { return RelinkCandidate(url: url, score: .fingerprint) }
        guard sameName else { return nil }
        var durationEqual: Bool?
        if let want = ref.duration, let probe = durationProbe, let got = probe(url) { durationEqual = (got == want) }
        if durationEqual == false { return RelinkCandidate(url: url, score: .nameOnly) }
        if sameSize || durationEqual == true { return RelinkCandidate(url: url, score: .nameSize) }
        return RelinkCandidate(url: url, score: .nameOnly)
    }

    /// Visits regular files below `root`, at most `depth` directory levels deep; skips hidden files and packages.
    /// Directories at the depth limit are not descended into. Symlinks to regular files are visited by their resolved
    /// URL, only when the target lies inside `root`.
    private func walk(_ root: URL, depth: Int, _ visit: (URL) -> Void) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let rootPath = root.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        // FileWalk, not FileManager.enumerator: on Windows its skipDescendants() stops every later folder too.
        FileWalk.walk(root, keys: Array(keys)) { u, v, level in
            if v?.isDirectory == true {
                return level >= depth + 1 ? .skip : .descend   // its children would be deeper than `depth`
            } else if v?.isSymbolicLink == true {
                let target = u.resolvingSymlinksInPath()
                if target.path.hasPrefix(prefix),
                   FileWalk.Values.read(target, keys: [.isRegularFileKey])?.isRegularFile == true { visit(target) }
            } else if v?.isRegularFile == true {
                visit(u)
            }
            return .descend
        }
    }

    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        for opts: URL.BookmarkResolutionOptions in [[.withSecurityScope, .withoutUI], [.withoutUI]] {
            if let u = try? URL(resolvingBookmarkData: data, options: opts, relativeTo: nil, bookmarkDataIsStale: &stale) { return u }
        }
        return nil
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a.split(separator: "/"), b.split(separator: "/")).prefix { $0 == $1 }.count
    }

    // MARK: Apply

    /// Returns `ref` pointing at `url` (name, path, fresh bookmark, refreshed fingerprint); id and duration are kept.
    public static func applying(_ url: URL, to ref: MediaRef) -> MediaRef {
        var r = ref
        r.name = url.lastPathComponent
        r.path = url.path
        r.bookmark = MediaBookmark.make(for: url)
        if let fp = fingerprint(of: url) { r.fingerprint = fp }
        return r
    }

    // MARK: Relink others

    /// After the user picked `newURL` for `chosen`, applies the same directory move to `others` (Premiere behavior).
    /// The move is the old/new directory with their common trailing components removed; each mapped file is
    /// verified by fingerprint before its ref is updated. Returns chosen + others, in that order.
    public static func relinkOthers(chosen: MediaRef, to newURL: URL, others: [MediaRef])
        -> (refs: [MediaRef], report: RelinkReport) {
        var report = RelinkReport()
        var out: [MediaRef] = [applying(newURL, to: chosen)]
        report.relinked[chosen.id] = newURL

        // Case-insensitive volumes (APFS default) treat "Footage" and "footage" as one folder.
        let caseSensitive = (try? newURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? true
        func same(_ a: String, _ b: String) -> Bool {
            caseSensitive ? a == b : a.compare(b, options: [.caseInsensitive]) == .orderedSame
        }
        let old = URL(fileURLWithPath: chosen.path).deletingLastPathComponent().pathComponents
        let new = newURL.deletingLastPathComponent().pathComponents
        var k = 0
        while k < old.count, k < new.count, same(old[old.count - 1 - k], new[new.count - 1 - k]) { k += 1 }
        let oldPrefix = Array(old.dropLast(k)), newPrefix = Array(new.dropLast(k))

        for ref in others {
            let comps = URL(fileURLWithPath: ref.path).pathComponents
            guard comps.count > oldPrefix.count, zip(comps, oldPrefix).allSatisfy({ same($0, $1) }) else {
                report.missing.append(ref.id); out.append(ref); continue
            }
            let mapped = URL(fileURLWithPath: NSString.path(withComponents: newPrefix + Array(comps.dropFirst(oldPrefix.count))))
            guard FileManager.default.fileExists(atPath: mapped.path) else {
                report.missing.append(ref.id); out.append(ref); continue
            }
            guard matches(ref.fingerprint, mapped) else {
                report.fingerprintMismatch.append(ref.id); out.append(ref); continue
            }
            report.relinked[ref.id] = mapped
            out.append(applying(mapped, to: ref))
        }
        return (out, report)
    }
}
