import Foundation
import Synchronization

/// On-disk proxy store keyed by (fingerprint, kind). Thread-safe; all methods are synchronous and cheap.
public final class ProxyCache: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/SequenceStudio/Proxies", isDirectory: true)
    }

    private struct Key: Hashable { var id: String; var kind: ProxyKind }
    private struct State {
        var records: [Key: ProxyRecord] = [:]
        var listeners: [UUID: AsyncStream<ProxyRecord>.Continuation] = [:]
        var settings = ProxySettings()
    }

    public let directory: URL
    private let state = Mutex(State())
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var settingsURL: URL { directory.appendingPathComponent("settings.json") }

    public init(directory: URL = ProxyCache.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let list = try? JSONDecoder.proxy.decode([ProxyRecord].self, from: data) {
            state.withLock { s in
                for r in list { s.records[Key(id: r.fingerprint.id, kind: r.kind)] = r }
            }
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
           let s = try? JSONDecoder.proxy.decode(ProxySettings.self, from: data) {
            state.withLock { $0.settings = s }
        }
    }

    public var settings: ProxySettings { state.withLock { $0.settings } }

    public func updateSettings(_ change: (inout ProxySettings) -> Void) throws {
        let s = state.withLock { st -> ProxySettings in change(&st.settings); return st.settings }
        try JSONEncoder.proxy.encode(s).write(to: settingsURL, options: .atomic)
    }

    public static func fileName(for fingerprint: SourceFingerprint, kind: ProxyKind) -> String {
        "\(fingerprint.id).\(kind.rawValue).mov"
    }

    public func fileURL(for record: ProxyRecord) -> URL { directory.appendingPathComponent(record.fileName) }

    /// Staging location for an in-progress transcode. Never reported as ready.
    public func partialURL(fingerprint: SourceFingerprint, kind: ProxyKind) -> URL {
        directory.appendingPathComponent(Self.fileName(for: fingerprint, kind: kind) + ".partial")
    }

    /// Returns the record only if its file still exists; otherwise drops the stale entry.
    /// A hit refreshes `lastAccess` (in memory; persisted with the next index write or `flushIndex()`).
    public func lookup(fingerprint: SourceFingerprint, kind: ProxyKind, now: Date = Date()) -> ProxyRecord? {
        let key = Key(id: fingerprint.id, kind: kind)
        guard var r = state.withLock({ $0.records[key] }) else { return nil }
        if FileManager.default.fileExists(atPath: fileURL(for: r).path) {
            r.lastAccess = now
            state.withLock { if $0.records[key] != nil { $0.records[key] = r } }
            return r
        }
        state.withLock { $0.records[key] = nil }
        try? writeIndex()
        return nil
    }

    public func allRecords() -> [ProxyRecord] {
        let all = state.withLock { Array($0.records.values) }
        return all.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
            .sorted { ($0.createdAt, $0.fileName) < ($1.createdAt, $1.fileName) }
    }

    /// Persists pending `lastAccess` updates.
    public func flushIndex() { try? writeIndex() }

    /// Moves the finished partial file into place and indexes it. Atomic for readers: the final name only ever
    /// refers to a complete file.
    public func commit(partial: URL, record: ProxyRecord) throws {
        let dest = fileURL(for: record)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: partial, to: dest)
        let listeners = state.withLock { s -> [AsyncStream<ProxyRecord>.Continuation] in
            s.records[Key(id: record.fingerprint.id, kind: record.kind)] = record
            return Array(s.listeners.values)
        }
        try writeIndex()
        for l in listeners { l.yield(record) }
    }

    public func remove(fingerprint: SourceFingerprint, kind: ProxyKind) {
        let key = Key(id: fingerprint.id, kind: kind)
        if let r = state.withLock({ s -> ProxyRecord? in s.records.removeValue(forKey: key) }) {
            try? FileManager.default.removeItem(at: fileURL(for: r))
            try? writeIndex()
        }
    }

    public func removeAll(for fingerprint: SourceFingerprint) {
        for k in ProxyKind.allCases { remove(fingerprint: fingerprint, kind: k) }
    }

    /// Total bytes of indexed proxy files.
    public func totalSize() -> Int64 {
        allRecords().reduce(0) { $0 + fileSize(fileURL(for: $1)) }
    }

    /// Deletes least-recently-used records until the total is at most `maxBytes`, never touching `protecting`
    /// (e.g. the proxy that just finished). Returns what was removed.
    @discardableResult
    public func evict(toFit maxBytes: Int64, protecting: Set<ProxyRecordID> = []) -> [ProxyRecord] {
        var total = totalSize()
        var removed: [ProxyRecord] = []
        let lru = allRecords().sorted { ($0.lastAccess, $0.fileName) < ($1.lastAccess, $1.fileName) }
        for r in lru where total > maxBytes {
            if protecting.contains(ProxyRecordID(r)) { continue }
            total -= fileSize(fileURL(for: r))
            remove(fingerprint: r.fingerprint, kind: r.kind)
            removed.append(r)
        }
        return removed
    }

    /// LRU eviction down to `settings.cacheCapBytes`. Call after each finished job and once at launch.
    @discardableResult
    public func enforceCap(protecting: Set<ProxyRecordID> = []) -> [ProxyRecord] {
        let removed = evict(toFit: settings.cacheCapBytes, protecting: protecting)
        if removed.isEmpty { flushIndex() }
        return removed
    }

    /// Deletes leftover `.partial` files (call at launch, when no job can be running). Returns the count.
    @discardableResult
    public func purgePartials() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var n = 0
        for f in files where f.pathExtension == "partial" {
            if (try? FileManager.default.removeItem(at: f)) != nil { n += 1 }
        }
        return n
    }

    /// Stream of records that became ready after subscribing.
    public func readyRecords() -> AsyncStream<ProxyRecord> {
        let (stream, cont) = AsyncStream.makeStream(of: ProxyRecord.self)
        let id = UUID()
        state.withLock { $0.listeners[id] = cont }
        cont.onTermination = { [weak self] _ in self?.state.withLock { $0.listeners[id] = nil } }
        return stream
    }

    private func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private func writeIndex() throws {
        let list = state.withLock { Array($0.records.values) }.sorted { $0.fileName < $1.fileName }
        let data = try JSONEncoder.proxy.encode(list)
        try data.write(to: indexURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var proxy: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }
}
extension JSONDecoder {
    static var proxy: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// Identity of a cached proxy (source fingerprint + kind).
public struct ProxyRecordID: Sendable, Hashable {
    public var fingerprintID: String
    public var kind: ProxyKind
    public init(_ r: ProxyRecord) { fingerprintID = r.fingerprint.id; kind = r.kind }
    public init(fingerprint: SourceFingerprint, kind: ProxyKind) { fingerprintID = fingerprint.id; self.kind = kind }
}
