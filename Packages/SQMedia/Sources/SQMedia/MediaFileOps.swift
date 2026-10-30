import Foundation
import SQCore

/// Copies or moves media into the project's `Files/` folder. Data safety rules:
/// - a copy is written under a temporary name and renamed only after it verified identical (size + sampled hash);
/// - an original is removed only after that verification, and by moving it to the Trash (recoverable);
/// - an existing file is never overwritten: a name clash gets a new name, or reuses the file if it is identical.
/// Portable (Mac and Windows): the few system calls that differ (Trash, file identity, aliases) sit behind `#if canImport(Darwin)`.
public enum MediaFileOps {
    public enum Failure: Error, Equatable, LocalizedError {
        case sourceMissing(String)
        case verificationFailed(String)
        case noTrash
        public var errorDescription: String? {
            switch self {
            case .sourceMissing(let n): "“\(n)” was not found."
            case .verificationFailed(let n): "The copy of “\(n)” did not match the original. The original was kept."
            case .noTrash: "This system has no Trash that Sequence Studio can use. The original was kept."
            }
        }
    }

    public struct Result: Sendable, Equatable {
        /// Where the media is now (the source for `.leave` or a file already in the folder).
        public var url: URL
        /// An identical file was already in the folder and is used instead of a new copy.
        public var reused = false
        /// The original was removed (moved to the Trash) after a verified copy.
        public var originalRemoved = false
        /// A new file was written into the folder (not reused, not the source itself).
        public var created = false
    }

    public typealias Remover = @Sendable (URL) throws -> Void
    /// Default original remover: Trash, never a hard delete.
    #if canImport(Darwin)
    public static let trash: Remover = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    #else
    // shortcut: no Recycle Bin call off the Mac, so Move keeps the original (`removeOriginal` reports false); upgrade with
    // SHFileOperation / IFileOperation behind this closure when Windows should clean up originals.
    public static let trash: Remover = { _ in throw Failure.noTrash }
    #endif

    /// Ingests run one at a time: two files with the same name in one batch must not both see a free name.
    private static let lock = NSLock()
    /// Paths a later ingest reused (or found identical) since they were created; guarded by `marksLock`. A pending
    /// `discardUnlinked` of such a file is dropped: somebody else's clip may point at it now.
    nonisolated(unsafe) private static var reusedPaths: Set<String> = []

    /// Brings `source` into `folder` according to `mode`. `.leave` and files already inside `folder` (by any spelling,
    /// symlinks included) return the source untouched. A symlink source is resolved to the real file first.
    public static func ingest(_ source: URL, into folder: URL, mode: ImportMode,
                              removeOriginal: Remover = MediaFileOps.trash) throws -> Result {
        guard mode != .leave else { return Result(url: source) }
        let real = source.resolvingSymlinksInPath()
        guard !MediaManagement.isInside(real.path, folder: folder) else { return Result(url: source) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: real.path) else { throw Failure.sourceMissing(source.lastPathComponent) }
        lock.lock(); defer { lock.unlock() }
        return try ingestLocked(real, source: source, into: folder, mode: mode, removeOriginal: removeOriginal)
    }

    /// Body of `ingest`; the caller holds `lock` and has checked that `real` exists and is outside `folder`.
    private static func ingestLocked(_ real: URL, source: URL, into folder: URL, mode: ImportMode,
                                     removeOriginal: Remover) throws -> Result {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        // A folder is no media file: copying it whole would differ per platform (Windows copies it, the Mac fails verification).
        if fm.fileExists(atPath: real.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw Failure.verificationFailed(real.lastPathComponent)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = real.lastPathComponent
        var final = folder.appendingPathComponent(name)
        var reused = false
        var copied = false
        for _ in 0..<50 where !copied && !reused {
            if fm.fileExists(atPath: final.path) {
                if sameFile(real, final) { return Result(url: source) }          // the file itself, reached another way
                if (try? fullyIdentical(real, final)) == true { reused = true; break }
                let free = MediaManagement.uniqueName(name) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                final = folder.appendingPathComponent(free)
                continue
            }
            do { try verifiedCopy(from: real, to: final); copied = true } catch let e as CocoaError where e.code == .fileWriteFileExists {
                continue                                                          // taken meanwhile: look again
            }
        }
        guard copied || reused else { throw Failure.verificationFailed(name) }
        if reused { noteReused(final) } else { _ = takeMark(final) }

        var removed = false
        if mode == .move, !isLinkOrAlias(source) {                  // a link is copied, never trashed
            // Full content comparison right before the original goes away; never on the sampled hash alone.
            guard (try? fullyIdentical(real, final)) == true, !sameFile(real, final) else { throw Failure.verificationFailed(name) }
            do { try removeOriginal(real); removed = true } catch { removed = false }   // keep the original on any failure
        }
        return Result(url: final, reused: reused, originalRemoved: removed, created: copied)
    }

    /// What `collect` did: `done` is every planned clip's final copy (clips of one source share it), `failed` the file
    /// names that could not be copied (they stay where they are).
    public struct CollectOutcome: Sendable, Equatable {
        public var done: [CollectItem] = []
        public var failed: [String] = []
    }

    /// Collect Files into Project Folder: copies the media outside `folder` into it (`MediaManagement.collectPlan` names
    /// the copies, `ingest` verifies each one). Originals stay. Blocking: call it off the main actor.
    public static func collect(media: [MediaRef], into folder: URL) -> CollectOutcome {
        let fm = FileManager.default
        let existing = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        let plan = MediaManagement.collectPlan(media: media, into: folder, existing: existing, exists: { fm.fileExists(atPath: $0) })
        var out = CollectOutcome()
        var copied: [String: String] = [:]
        for item in plan {
            if let d = copied[item.source] { var i = item; i.destination = d; out.done.append(i); continue }
            do {
                let r = try ingest(URL(fileURLWithPath: item.source), into: folder, mode: .copy)
                var i = item; i.destination = r.url.path; out.done.append(i); copied[item.source] = r.url.path
            } catch { out.failed.append((item.source as NSString).lastPathComponent) }
        }
        return out
    }

    /// Brings a library item into `folder` (`Files/Library/`), deduplicated by content: if any file there already has the
    /// same content (same size and SHA-256 over the whole file) that file is used, whatever its name; otherwise the item
    /// is copied (name clash = " 2"). The source is never touched.
    public static func ingestLibraryItem(_ source: URL, into folder: URL) throws -> Result {
        let real = source.resolvingSymlinksInPath()
        guard !MediaManagement.isInside(real.path, folder: folder) else { return Result(url: source) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: real.path) else { throw Failure.sourceMissing(source.lastPathComponent) }
        lock.lock(); defer { lock.unlock() }
        if let same = try identicalFile(to: real, in: folder) { noteReused(same); return Result(url: same, reused: true) }
        return try ingestLocked(real, source: source, into: folder, mode: .copy, removeOriginal: trash)
    }

    /// A file directly in `folder` with exactly the content of `file`, if there is one.
    public static func identicalFile(to file: URL, in folder: URL) throws -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return nil }
        let want = try size(file)
        var hash: String?
        for n in names.sorted() where !n.hasPrefix(".") {
            let c = folder.appendingPathComponent(n)
            guard (try? size(c)) == want else { continue }
            if hash == nil { hash = try contentHash(file) }
            if try contentHash(c) == hash { return c }
        }
        return nil
    }

    /// SHA-256 of the whole file, streamed.
    public static func contentHash(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256Digest.Stream()
        while let d = try h.read(upToCount: 4 << 20), !d.isEmpty { hasher.update(d) }
        return hasher.finalizeHex()
    }

    /// The "Move" half after the clips already point at `copy`: removes `original` only when `copy` is a different file
    /// with byte-identical content. Returns true when the original was removed (to the Trash by default).
    @discardableResult
    public static func removeOriginal(_ original: URL, afterCopy copy: URL, remover: Remover = MediaFileOps.trash) -> Bool {
        guard !isLinkOrAlias(original) else { return false }       // a link's target is somebody else's file: never trashed
        let real = original.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: real.path), !sameFile(real, copy),
              (try? fullyIdentical(real, copy)) == true else { return false }
        do { try remover(real); return true } catch { return false }
    }

    /// True when `url` itself is a symbolic link or a Finder alias.
    public static func isLinkOrAlias(_ url: URL) -> Bool {
        #if canImport(Darwin)
        let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        return v?.isSymbolicLink == true || v?.isAliasFile == true
        #else
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        #endif
    }

    /// Deletes copies that a canceled batch created but never linked a clip to. Reused and untouched files stay.
    /// Runs under the ingest lock: a file that a later ingest reused meanwhile (a re-drop after a Revert) is kept.
    public static func discardUnlinked(_ results: [Result]) {
        lock.lock(); defer { lock.unlock() }
        for r in results where r.created {
            if takeMark(r.url) { continue }      // entry resolved: kept
            try? FileManager.default.removeItem(at: r.url)
        }
    }

    /// Own small lock for `reusedPaths`, so a LUT collect can mark a reused file without waiting for a media ingest.
    private static let marksLock = NSLock()
    private static func noteReused(_ url: URL) {
        let k = identityKey(url)
        marksLock.lock(); reusedPaths.insert(k); marksLock.unlock()
    }
    private static func takeMark(_ url: URL) -> Bool {
        let k = identityKey(url)
        marksLock.lock(); defer { marksLock.unlock() }
        return reusedPaths.remove(k) != nil
    }

    /// A key for "this very file on disk": the canonical path with the case the volume stores (so `IMG.MOV` and
    /// `img.mov` on a case-insensitive volume agree), symlinks resolved. A file that does not exist keeps its path.
    public static func identityKey(_ url: URL) -> String {
        #if canImport(Darwin)
        if let c = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath { return c }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
        #else
        // shortcut: Windows paths are case-insensitive on the usual volumes, so the key is lowercased; a case-sensitive
        // NTFS folder would merge two names; upgrade with GetFinalPathNameByHandle when that matters.
        return url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        #endif
    }
    public static func identityKey(path: String) -> String { identityKey(URL(fileURLWithPath: path)) }

    /// Own lock for LUT collection: a long media ingest never delays it, and it is never taken on the main actor.
    private static let lutLock = NSLock()

    /// Copies a LUT file into `folder` (`Files/Library/`) unless a file with the same content is already there; returns
    /// the file to use. Small files only (hashes the candidates of equal size). The source is never touched.
    public static func collectLUT(_ source: URL, into folder: URL) throws -> Result {
        let real = source.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: real.path) else { throw Failure.sourceMissing(source.lastPathComponent) }
        lutLock.lock(); defer { lutLock.unlock() }       // not `lock`: a long media ingest must not stall a save
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let same = try identicalFile(to: real, in: folder) {
            noteReused(same)
            // A discard may have removed the file between the match and the mark: then copy it again below.
            if fm.fileExists(atPath: same.path) { return Result(url: same, reused: true) }
        }
        let name = real.lastPathComponent
        var final = folder.appendingPathComponent(name)
        for _ in 0..<50 {
            if fm.fileExists(atPath: final.path) {      // other content under that name: next free name
                let free = MediaManagement.uniqueName(name) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
                final = folder.appendingPathComponent(free)
                continue
            }
            do { try verifiedCopy(from: real, to: final); return Result(url: final, created: true) }
            catch let e as CocoaError where e.code == .fileWriteFileExists { continue }
        }
        throw Failure.verificationFailed(name)
    }

    /// True when both paths are the very same file (hard link, symlink, other spelling, case).
    public static func sameFile(_ a: URL, _ b: URL) -> Bool {
        #if canImport(Darwin)
        guard let x = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let y = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return x.isEqual(y)
        #else
        return identityKey(a) == identityKey(b)
        #endif
    }

    /// What names the file itself (volume and file number): equal for a hard link, a symlink, another spelling of the
    /// path or a different letter case on a case-insensitive volume. Nil when the file cannot be reached.
    public static func fileIdentity(_ url: URL) -> AnyHashable? {
        #if canImport(Darwin)
        guard let id = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let o = id as? NSObject else { return nil }
        return AnyHashable(o)
        #else
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return AnyHashable(identityKey(url))
        #endif
    }

    /// Byte-for-byte comparison, streamed.
    public static func fullyIdentical(_ a: URL, _ b: URL) throws -> Bool {
        guard try size(a) == size(b) else { return false }
        let ha = try FileHandle(forReadingFrom: a), hb = try FileHandle(forReadingFrom: b)
        defer { try? ha.close(); try? hb.close() }
        while true {
            let da = try ha.read(upToCount: 4 << 20) ?? Data(), db = try hb.read(upToCount: 4 << 20) ?? Data()
            if da != db { return false }
            if da.isEmpty { return true }
        }
    }

    /// Removes copy leftovers (`.name.sqpart-…`, from a crash or a quit during a copy) in `folder` that are older than
    /// `age` seconds. Newer ones may belong to a copy that is still running. Returns how many were removed.
    @discardableResult
    public static func removeStaleTemporaries(in folder: URL, olderThan age: TimeInterval, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(".") && name.contains(".sqpart-") {
            let url = folder.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) > age else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Copies via a temporary sibling and renames it into place after verification. `destination` must not exist.
    public static func verifiedCopy(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let tmp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).sqpart-\(UUID().uuidString)")
        do {
            try Task.checkCancellation()
            try fm.copyItem(at: source, to: tmp)
            try Task.checkCancellation()
            guard try identical(source, tmp) else { throw Failure.verificationFailed(source.lastPathComponent) }
            try fm.moveItem(at: tmp, to: destination)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Same size and same hash over the first and last megabyte plus samples spread through the file.
    public static func identical(_ a: URL, _ b: URL) throws -> Bool {
        let sizeA = try size(a), sizeB = try size(b)
        guard sizeA == sizeB else { return false }
        return try sampleHash(a, size: sizeA) == sampleHash(b, size: sizeB)
    }

    private static func size(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? -1
    }

    static func sampleHash(_ url: URL, size: Int64) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256Digest.Stream()
        let head: Int64 = 1 << 20, chunk: Int64 = 64 << 10
        func read(at offset: Int64, _ count: Int64) throws {
            try h.seek(toOffset: UInt64(max(0, offset)))
            if let d = try h.read(upToCount: Int(count)) { hasher.update(d) }
        }
        if size <= head * 2 + chunk * 8 {
            // Small file: hash everything.
            try read(at: 0, size)
        } else {
            try read(at: 0, head)
            try read(at: size - head, head)
            for i in 1...6 { try read(at: size * Int64(i) / 7, chunk) }
        }
        return hasher.finalizeHex()
    }
}
