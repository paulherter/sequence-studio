import Foundation
import SQCore
import SQMedia

/// Memory caps scaled to the Mac's physical RAM (PERF STREAM (4), weak Macs). Pure: the RAM size is injected, so tests and
/// the bench simulate a MacBook Air 8 GB on any machine (`SQ_RAM_GB=8`, `EngineBench --ram-gb 8`).
///
/// - Frame cache: ONE budget for both monitors together (Program 3/4, Source 1/4). 8 GB Macs and smaller: 1/6 of RAM
///   (1.33 GB on 8 GB); larger: 1/4, at most 8 GB. Before, each engine took 1/4 (two engines = half the RAM).
/// - Compositor free-texture pool: RAM / 32, between 128 MB and 1 GB (was a fixed 1 GB).
/// - Auto preview quality: half on low-memory Macs (Final Cut's "Better Performance", CapCut's performance preview), full
///   elsewhere. Memory pressure lowers it further (`PowerPolicy.underMemoryPressure`).
public struct MemoryBudget: Sendable, Equatable {
    public static let gib: UInt64 = 1 << 30
    public var physicalMemory: UInt64

    public init(physicalMemory: UInt64) { self.physicalMemory = physicalMemory }

    /// This Mac, or a smaller one simulated with `SQ_RAM_GB` (never larger than the real RAM).
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment,
                               physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> MemoryBudget {
        if let v = environment["SQ_RAM_GB"].flatMap(Double.init), v.isFinite, v > 0 {
            return MemoryBudget(physicalMemory: min(physicalMemory, UInt64(v * Double(gib))))
        }
        return MemoryBudget(physicalMemory: physicalMemory)
    }

    /// 8 GB or less (MacBook Air base models).
    public var isLowMemory: Bool { physicalMemory <= 8 * Self.gib }

    /// Frame cache of both monitors together when the setting is Auto.
    public var autoFrameCacheBytes: Int { limits.frameCacheBytes }

    /// The `WorkLimits` of a Mac with this RAM (cache sizes depend on RAM only).
    private var limits: WorkLimits { MachineResources(memoryBytes: physicalMemory, cores: 8).limits }

    /// Largest frame cache a user may choose: half the RAM.
    public var maxFrameCacheBytes: Int { Int(physicalMemory / 2) }

    /// The frame cache in force: `userGB` nil or 0 = Auto; otherwise the choice, at most half the RAM.
    public func frameCacheBytes(userGB: Int?) -> Int {
        guard let g = userGB, g > 0 else { return autoFrameCacheBytes }
        return min(Int(UInt64(g) * Self.gib), maxFrameCacheBytes)
    }

    /// Fixed sizes offered in Settings next to Auto: powers of two from 1 GB up to half the RAM.
    public static func cacheChoicesGB(for b: MemoryBudget) -> [Int] {
        var out: [Int] = []
        var g = 1
        while UInt64(g) * gib <= UInt64(b.maxFrameCacheBytes) { out.append(g); g *= 2 }
        return out
    }

    /// Program monitor 3/4, Source monitor the rest.
    public static func split(_ total: Int) -> (program: Int, source: Int) {
        let p = max(0, total) / 4 * 3
        return (p, max(0, total) - p)
    }

    /// The monitor whose engine plays (only one plays at a time: starting one stops the other).
    public enum Monitor: Sendable { case program, source }

    /// 8 GB Macs and smaller: the playing monitor gets the 3/4 (bench: the Source monitor at 1/4 = 341 MB dropped 103 of
    /// 1574 frames of a 4K 10-bit 4:2:2 Long-GOP clip at half quality). Larger Macs keep the fixed 3:1.
    public var followsPlayingMonitor: Bool { isLowMemory }

    /// The split while `playing` plays (`split(_:)` when the split is fixed).
    public func split(_ total: Int, playing: Monitor) -> (program: Int, source: Int) {
        let s = Self.split(total)
        return followsPlayingMonitor && playing == .source ? (s.source, s.program) : s
    }

    /// Byte cap of the compositor's free intermediate textures.
    public var intermediatePoolBytes: Int { limits.intermediatePoolBytes }

    /// Decoder sessions the playback engine keeps for media it does not need right now (MRU; `DecodeScheduler`). Each
    /// holds its reference frames in VTDecoderXPCService: 1 on low-memory Macs, 2 elsewhere.
    public var idleDecoders: Int { isLowMemory ? 1 : 2 }

    /// Viewer decode size when the preview quality setting is Auto.
    public var autoPreviewQuality: DecodeScale { isLowMemory ? .half : .full }
}

extension PowerPolicy {
    /// The policy while the system reports memory pressure: warning = viewer at most half size, half the prefetch
    /// look-ahead, no new background jobs; critical = quarter size. Never raises a cap that is already lower.
    public func underMemoryPressure(_ level: MemoryPressure) -> PowerPolicy {
        let cap: DecodeScale
        switch level {
        case .normal: return self
        case .warning: cap = .half
        case .critical: cap = .quarter
        }
        return PowerPolicy(pausesBackgroundJobs: true, decodeScaleCap: viewerScale(cap), halvesPrefetch: true)
    }

    /// What the monitors run with: the thermal/Low Power policy, the Background Work setting, and memory pressure. With
    /// Auto preview quality pressure lowers the picture size; with a fixed quality it only pauses background work.
    public static func combined(power: PowerPolicy, memory: MemoryPressure, autoQuality: Bool, backgroundWork: Bool) -> PowerPolicy {
        let p = power.withBackgroundWork(backgroundWork)
        if autoQuality { return p.underMemoryPressure(memory) }
        return memory == .normal ? p : p.withBackgroundWork(false)
    }

    /// Settings > Playback "Background Work" off: background jobs (proxy generation) start nothing new.
    public func withBackgroundWork(_ on: Bool) -> PowerPolicy {
        on ? self : PowerPolicy(pausesBackgroundJobs: true, decodeScaleCap: decodeScaleCap, halvesPrefetch: halvesPrefetch)
    }
}

/// System memory-pressure level on the main actor (`DispatchSource` memory-pressure events via `SystemMemoryPressureSource`),
/// reported on change only. The frame caches and the compositor pool trim themselves from their own sources; this one
/// drives the preview quality (`PowerPolicy.underMemoryPressure`).
@MainActor public final class MemoryPressureMonitor {
    public private(set) var level: MemoryPressure = .normal
    public var onChange: ((MemoryPressure) -> Void)?
    private let source: any MemoryPressureSource

    public init(source: any MemoryPressureSource = SystemMemoryPressureSource(name: "preview quality")) {
        self.source = source
        source.start { [weak self] l in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.set(l) } }
        }
    }

    isolated deinit { source.cancel() }

    /// Applies a level (tests call it directly).
    public func set(_ l: MemoryPressure) {
        guard l != level else { return }
        level = l
        onChange?(l)
    }
}
