#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
import Foundation
import SQMedia
import Synchronization

/// Color interpretation of a proxy. There is exactly one rule: always the ORIGINAL source's.
public enum ProxyColorInterpretation: Sendable, Hashable {
    /// Interpret color (log curve, primaries, matrix, sidecar metadata such as Sony S-Log3) from the original
    /// source file. Never read color tags from the proxy: its BT.709 tag is an encoder default, not information.
    case fromSource
}

public struct ProxyLookup: Sendable, Hashable {
    /// Always `.fromSource`: see `ProxyColorInterpretation`.
    public var colorInterpretation: ProxyColorInterpretation = .fromSource
    public var url: URL
    public var kind: ProxyKind
    public var dimensions: ProxyDimensions
    /// Width/height divisor relative to the source (1, 2 or 4).
    public var scaleDivisor: Int
    /// The cache record handed out (to protect it from eviction while in use).
    public var record: ProxyRecordID? = nil
}

/// Read-only lookup API for the playback engine. Never starts work; only reports proxies that are ready.
public final class ProxyProvider: Sendable {
    private struct Memo { var size: Int64; var modifiedMillis: Int64; var fingerprint: SourceFingerprint }
    private let cache: ProxyCache
    private let memo = Mutex<[String: Memo]>([:])

    private let interlaced: @Sendable (URL) async -> Bool

    /// `interlaced`: whether a source has fields (tests replace the file read).
    public init(cache: ProxyCache, interlaced: @escaping @Sendable (URL) async -> Bool = ProxyProvider.hasFields) {
        self.cache = cache; self.interlaced = interlaced
    }

    /// The first video track of `source` is tagged interlaced. False for a file AVFoundation cannot open.
    /// Off the Mac: false (shortcut: no field probe without AVFoundation, upgrade with an FFmpeg field-order probe).
    public static func hasFields(_ source: URL) async -> Bool {
        #if !canImport(AVFoundation)
        return false
        #else
        let asset = AVURLAsset(url: source)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return false }
        return Deinterlacer.fieldOrder(of: format) != nil
        #endif
    }

    /// Proxies made before interlaced sources were deinterlaced (`ProxyRecord.build`) are woven when the source has
    /// fields: those are deleted (the automatic proxy flow makes them again), the others are marked current. Until this
    /// ran for a source, no lookup hands out its old proxies. Costs one track read per old proxy, once.
    private func settleOutdated(_ source: URL, _ fp: SourceFingerprint) async {
        let kinds = cache.outdatedKinds(for: fp)
        guard !kinds.isEmpty else { return }
        let woven = await interlaced(source)
        for kind in kinds {
            // The track read took time: both look at the record again and leave one that is current by now.
            if woven { cache.removeOutdated(fingerprint: fp, kind: kind) } else { cache.markCurrent(fingerprint: fp, kind: kind) }
        }
    }

    /// First ready proxy in `preferring` order. Computes (and memoizes) the source fingerprint if needed,
    /// which reads 128 KB of the source.
    public func optimizedFile(for source: URL, preferring: [ProxyKind]) async -> ProxyLookup? {
        guard let fp = fingerprint(source, compute: true) else { return nil }
        await settleOutdated(source, fp)
        return resolve(fp, preferring)
    }

    /// Stat-only variant for hot paths (e.g. building a decoder on the main thread): never reads file content.
    /// Returns nil until `optimizedFile` (or `warm`) has computed the fingerprint for the current file state.
    public func cachedLookup(for source: URL, preferring: [ProxyKind]) -> ProxyLookup? {
        guard let fp = fingerprint(source, compute: false) else { return nil }
        return resolve(fp, preferring)
    }

    /// Precomputes the fingerprint so `cachedLookup` works afterwards.
    public func warm(_ source: URL) async {
        if let fp = fingerprint(source, compute: true) { await settleOutdated(source, fp) }
    }

    /// Decoder file choice for the playhead state. Stat-only (see `cachedLookup`), so warm the source first.
    /// Returns a proxy only for `.scrubbing`, or also for `.playback` when `settings.useProxiesForPlayback` is on.
    /// `.paused` always returns nil (exact frames come from the original).
    public func file(for source: URL, context: ProxyUseContext, settings: ProxySettings) -> ProxyLookup? {
        guard Self.usesProxy(context: context, settings: settings) else { return nil }
        return cachedLookup(for: source, preferring: Self.scrubPreference)
    }

    public static func usesProxy(context: ProxyUseContext, settings: ProxySettings) -> Bool {
        switch context {
        case .scrubbing: true
        case .playback: settings.useProxiesForPlayback
        case .paused: false
        }
    }

    /// Half first (what auto-generation produces), then quarter, then full-res optimized.
    public static let scrubPreference: [ProxyKind] = [.proxyHalf, .proxyQuarter, .optimized]

    /// Fires when any proxy becomes ready (the record's fingerprint identifies the source).
    public func readyEvents() -> AsyncStream<ProxyRecord> { cache.readyRecords() }

    private func resolve(_ fp: SourceFingerprint, _ preferring: [ProxyKind]) -> ProxyLookup? {
        for kind in preferring {
            if let r = cache.currentLookup(fingerprint: fp, kind: kind) {
                return ProxyLookup(url: cache.fileURL(for: r), kind: kind, dimensions: r.dimensions,
                                   scaleDivisor: kind.scaleDivisor, record: ProxyRecordID(r))
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
