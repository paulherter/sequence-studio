import Foundation

/// What we know about how a source seeks. Produced by a `SourceSeekProbing` implementation.
public struct SourceSeekInfo: Sendable, Hashable {
    /// Video codec FourCC, e.g. "avc1", "hvc1", "apcn".
    public var codecFourCC: String
    /// Largest distance (in frames, decode order) between two sync samples in the scanned window.
    /// nil if unknown (then only the codec decides).
    public var maxSyncDistance: Int?
    public var scannedFrames: Int

    public init(codecFourCC: String, maxSyncDistance: Int?, scannedFrames: Int = 0) {
        self.codecFourCC = codecFourCC; self.maxSyncDistance = maxSyncDistance; self.scannedFrames = scannedFrames
    }
}

/// Small injectable input of the policy, so it is testable without media.
extension SourceSeekInfo {
    /// The facts of a demuxer's sample index: `syncFlags` are the samples' sync flags in order; the first `maxSamples`
    /// are read, as the Mac sample-cursor walk. Without a second sync sample the gap is the samples after the last one.
    public init(codecFourCC: String, syncFlags: some Sequence<Bool>, maxSamples: Int = 600) {
        var count = 0, lastSync: Int?, maxGap = 0
        for isSync in syncFlags.prefix(maxSamples) {
            if isSync {
                if let l = lastSync { maxGap = max(maxGap, count - l) }
                lastSync = count
            }
            count += 1
        }
        if maxGap == 0, count > 1 { maxGap = count - (lastSync ?? 0) }
        self.init(codecFourCC: codecFourCC, maxSyncDistance: count > 1 ? maxGap : nil, scannedFrames: count)
    }

    /// The QuickTime FourCC `ProxyPolicy` knows for an FFmpeg codec name (any ProRes counts as 422: all are intra);
    /// unknown names pass through.
    public static func fourCC(ffmpegCodec name: String) -> String {
        switch name {
        case "h264": "avc1"
        case "hevc": "hvc1"
        case "av1": "av01"
        case "vp9": "vp09"
        case "vp8": "vp08"
        case "mpeg2video": "mp2v"
        case "mpeg4": "mp4v"
        case "prores": "apcn"
        case "dnxhd": "AVdn"
        case "mjpeg": "jpeg"
        case "cfhd": "CFHD"
        case "v210": "v210"
        case "rawvideo": "raw "
        default: name
        }
    }
}

public protocol SourceSeekProbing: Sendable {
    func probe(_ url: URL) async throws -> SourceSeekInfo
}

/// Stand-in where no probe exists (Windows until an FFmpeg prober lands): every probe fails, so the policy skips
/// with `.unknown` and import is never blocked.
public struct UnavailableSeekProber: SourceSeekProbing {
    public init() {}
    public func probe(_ url: URL) async throws -> SourceSeekInfo { throw ProxyTranscodeError.readerFailed("no seek prober on this system") }
}

/// The system's prober: `AVSourceSeekProber` on the Mac.
public func platformSeekProber() -> any SourceSeekProbing {
    #if canImport(AVFoundation)
    AVSourceSeekProber()
    #else
    UnavailableSeekProber()
    #endif
}

public enum ProxyDecision: Sendable, Hashable {
    case needsProxy(ProxyKind)
    case skip(Reason)

    public enum Reason: Sendable, Hashable {
        case intraOnlyCodec
        case shortGOP(maxDistance: Int)
        case unknown
        /// Proxy mode off (W9.9).
        case disabled
        /// Long-GOP but light enough to scrub on this Mac (W9.9 Auto).
        case lightSource
        /// Interlaced with Deinterlace off: playback shows the stored fields, and a proxy has none.
        case keepsFields
    }
    public var needsProxy: Bool { if case .needsProxy = self { true } else { false } }
}

/// Decides whether a source needs an automatic proxy: only sources that seek slowly (long-GOP).
public struct ProxyPolicy: Sendable {
    /// Sources whose largest sync-sample distance exceeds this many frames are long-GOP.
    public var maxSyncDistance: Int
    /// Kind produced automatically.
    public var autoKind: ProxyKind

    public init(maxSyncDistance: Int = 8, autoKind: ProxyKind = .proxyHalf) {
        self.maxSyncDistance = maxSyncDistance; self.autoKind = autoKind
    }

    /// Intra-only codecs: ProRes (all), DNxHD/HR, MJPEG, Cineform, Apple Intermediate, uncompressed.
    public static let intraCodecs: Set<String> = [
        "apcn", "apch", "apcs", "apco", "ap4h", "ap4x", "aprn", "aprh",
        "AVdn", "AVdh", "mjpa", "mjpb", "jpeg", "CFHD", "icod", "v210", "2vuy", "yuv2", "raw ",
    ]

    public func decide(_ info: SourceSeekInfo) -> ProxyDecision {
        if Self.intraCodecs.contains(info.codecFourCC) { return .skip(.intraOnlyCodec) }
        guard let d = info.maxSyncDistance else { return .skip(.unknown) }
        return d > maxSyncDistance ? .needsProxy(autoKind) : .skip(.shortGOP(maxDistance: d))
    }
}

/// Connects import to the queue: evaluates the policy and enqueues a low-priority proxy job if needed.
public final class ProxyAutoGenerator: Sendable {
    private let queue: ProxyQueue
    private let prober: any SourceSeekProbing
    private let policy: ProxyPolicy

    public init(queue: ProxyQueue, prober: any SourceSeekProbing = platformSeekProber(), policy: ProxyPolicy = ProxyPolicy()) {
        self.queue = queue; self.prober = prober; self.policy = policy
    }

    /// Call when a source has been imported. Returns the decision; a job is enqueued (background priority) on
    /// `.needsProxy`. Probe failures mean no proxy (never blocks import).
    @discardableResult
    public func sourceImported(_ url: URL) async -> ProxyDecision {
        guard let info = try? await prober.probe(url) else { return .skip(.unknown) }
        let decision = policy.decide(info)
        if case .needsProxy(let kind) = decision {
            _ = try? await queue.enqueue(url, kind: kind, priority: .background)
        }
        return decision
    }
}
