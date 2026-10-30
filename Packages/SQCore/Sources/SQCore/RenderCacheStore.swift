import Foundation

/// Preview render cache, model part 4: files and index in one folder (`<cache root>/RenderCache`). One file per
/// segment key (`<key>.mov`), `index.json` beside them. Writes obey the shared disk floor (`CacheDiskPolicy`); the byte
/// cap and age purge delete files through `RenderCacheIndex`.
public struct RenderCacheStore: Sendable {
    public static let defaultByteCap: Int64 = 20 << 30
    public static let defaultMaxAge: TimeInterval = 14 * 86400

    public let directory: URL
    public let byteCap: Int64
    public let disk: CacheDiskPolicy
    public init(directory: URL, byteCap: Int64 = defaultByteCap, disk: CacheDiskPolicy = .standard) {
        self.directory = directory; self.byteCap = byteCap; self.disk = disk
    }

    public func fileURL(for key: String) -> URL { directory.appendingPathComponent(key + ".mov") }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private static func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }

    /// Missing or unreadable index = empty cache; entries whose file is gone are dropped.
    public func load() -> RenderCacheIndex {
        guard let d = try? Data(contentsOf: indexURL),
              var i = try? Self.decoder().decode(RenderCacheIndex.self, from: d) else { return RenderCacheIndex() }
        for k in Array(i.entries.keys) where !FileManager.default.fileExists(atPath: fileURL(for: k).path) { i.remove(k) }
        return i
    }

    public func save(_ index: RenderCacheIndex) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder().encode(index).write(to: indexURL, options: .atomic)
    }

    /// False when writing `bytes` would drop the volume below the free-space floor.
    public func mayWrite(bytes: Int64) -> Bool { disk.allowsWrite(bytes: bytes, at: directory) }

    /// Registers a finished segment file, then applies age purge and the byte cap; deletes the freed files.
    public func commit(key: String, duration: Time, to index: inout RenderCacheIndex, protecting: Set<String>, now: Date) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: fileURL(for: key).path)[.size] as? NSNumber)?.int64Value ?? 0
        index.record(key: key, bytes: size, duration: duration, now: now)
        let gone = index.purge(olderThan: Self.defaultMaxAge, now: now, protecting: protecting.union([key]))
            + index.evict(limitBytes: byteCap, protecting: protecting.union([key]))
        for k in gone { try? FileManager.default.removeItem(at: fileURL(for: k)) }
        try save(index)
    }
}
