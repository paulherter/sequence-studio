import Foundation
import Synchronization

public struct ProxyLookup: Sendable, Hashable {
    public var url: URL
    public var kind: ProxyKind
    public var dimensions: ProxyDimensions
    /// Width/height divisor relative to the source (1, 2 or 4).
    public var scaleDivisor: Int
}

/// Read-only lookup API for the playback engine. Never starts work; only reports proxies that are ready.
public final class ProxyProvider: Sendable {
    private struct Memo { var size: Int64; var modifiedMillis: Int64; var fingerprint: SourceFingerprint }
    private let cache: ProxyCache
    private let memo = Mutex<[String: Memo]>([:])

    public init(cache: ProxyCache) { self.cache = cache }

    /// First ready proxy in `preferring` order. Computes (and memoizes) the source fingerprint if needed,
    /// which reads 128 KB of the source.
    public func optimizedFile(for source: URL, preferring: [ProxyKind]) async -> ProxyLookup? {
        guard let fp = fingerprint(source, compute: true) else { return nil }
        return resolve(fp, preferring)
    }

    /// Stat-only variant for hot paths (e.g. building a decoder on the main thread): never reads file content.
    /// Returns nil until `optimizedFile` (or `warm`) has computed the fingerprint for the current file state.
    public func cachedLookup(for source: URL, preferring: [ProxyKind]) -> ProxyLookup? {
        guard let fp = fingerprint(source, compute: false) else { return nil }
        return resolve(fp, preferring)
    }

    /// Precomputes the fingerprint so `cachedLookup` works afterwards.
    public func warm(_ source: URL) async { _ = fingerprint(source, compute: true) }

    /// Fires when any proxy becomes ready (the record's fingerprint identifies the source).
    public func readyEvents() -> AsyncStream<ProxyRecord> { cache.readyRecords() }

    private func resolve(_ fp: SourceFingerprint, _ preferring: [ProxyKind]) -> ProxyLookup? {
        for kind in preferring {
            if let r = cache.lookup(fingerprint: fp, kind: kind) {
                return ProxyLookup(url: cache.fileURL(for: r), kind: kind, dimensions: r.dimensions,
                                   scaleDivisor: kind.scaleDivisor)
            }
        }
        return nil
    }

    private func fingerprint(_ url: URL, compute: Bool) -> SourceFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let millis = Int64((((attrs[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970 * 1000).rounded())
        let key = url.standardizedFileURL.path
        if let m = memo.withLock({ $0[key] }), m.size == size, m.modifiedMillis == millis { return m.fingerprint }
        guard compute, let fp = try? SourceFingerprint.compute(for: url) else { return nil }
        memo.withLock { $0[key] = Memo(size: size, modifiedMillis: millis, fingerprint: fp) }
        return fp
    }
}
