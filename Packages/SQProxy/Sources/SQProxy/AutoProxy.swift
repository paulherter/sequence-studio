import Foundation
import SQCore

/// Automatic proxy generation (W9.9). Default `.auto`: heavy long-GOP sources (and, on a weak Mac, any long-GOP source
/// above 1440p) get a background proxy that the monitor uses while scrubbing. Export never reads proxies.
public enum ProxyMode: String, Sendable, Hashable, CaseIterable {
    case auto, always, off
}

/// Whether playback (not only scrubbing) uses ready proxies. `.auto`: only on a weak Mac.
public enum ProxyPlaybackMode: String, Sendable, Hashable, CaseIterable {
    case auto, on, off
}

/// What the rule needs to know about this Mac.
public struct MachineProfile: Sendable, Hashable {
    public var memoryBytes: UInt64
    public var cores: Int
    public var isAppleSilicon: Bool

    public init(memoryBytes: UInt64, cores: Int, isAppleSilicon: Bool) {
        self.memoryBytes = memoryBytes; self.cores = cores; self.isAppleSilicon = isAppleSilicon
    }

    /// This Mac; `SQ_RAM_GB` / `SQ_CORES` simulate a smaller one (as for `MemoryBudget` and `WorkLimits`).
    public static var current: MachineProfile {
        #if arch(arm64)
        let silicon = true
        #else
        let silicon = false
        #endif
        let p = ProcessInfo.processInfo
        return current(environment: p.environment, physicalMemory: p.physicalMemory, cores: p.activeProcessorCount,
                       isAppleSilicon: silicon)
    }

    public static func current(environment: [String: String], physicalMemory: UInt64, cores: Int,
                               isAppleSilicon: Bool) -> MachineProfile {
        let r = MachineResources.current(environment: environment, physicalMemory: physicalMemory, cores: cores)
        return MachineProfile(memoryBytes: r.memoryBytes, cores: r.cores, isAppleSilicon: isAppleSilicon)
    }

    /// Intel, under 16 GB or under 8 cores: 4K long-GOP decoding is slow here.
    public var isWeak: Bool { !isAppleSilicon || memoryBytes < 16 << 30 || cores < 8 }

    /// 8 GB or less: the frame cache is 1/6 of RAM (`MemoryBudget`), so 10-bit / 4:2:2 GOPs from 1440p up do not fit.
    public var isLowMemory: Bool { memoryBytes <= 8 << 30 }
}

public enum AutoProxyRule {
    static let uhdPixels = 3840 * 2160
    static let qhdPixels = 2560 * 1440

    /// Long-GOP decides whether seeking is slow at all (`ProxyPolicy`); size, bit depth and chroma decide whether it is
    /// slow enough to be worth a background transcode.
    /// `softwareDecode`: this Mac has no hardware decoder for the source (VT session not on the media engine). Software
    /// decode costs ~28 ms per 4K H.264 frame on one core (PLAYBACK-PERF "Hardware decode"), so a long-GOP source from
    /// 1080p up gets a proxy on every Mac.
    public static func decide(seek: SourceSeekInfo, video: VideoTrackInfo?, mode: ProxyMode,
                              machine: MachineProfile, softwareDecode: Bool = false,
                              policy: ProxyPolicy = ProxyPolicy()) -> ProxyDecision {
        if mode == .off { return .skip(.disabled) }
        // A proxy of an interlaced source is progressive; with Deinterlace off the fields are wanted and playback reads
        // the original, so the proxy would never be used.
        if let v = video, v.isInterlaced, v.deinterlaceOff { return .skip(.keepsFields) }
        let gop = policy.decide(seek)
        guard gop.needsProxy else { return gop }
        let pixels = video.map { $0.width * $0.height } ?? 0
        let kind: ProxyKind = pixels >= 2 * uhdPixels ? .proxyQuarter : .proxyHalf
        if mode == .always { return .needsProxy(kind) }
        guard let v = video else { return .skip(.unknown) }
        let rich = v.bitDepth > 8 || v.chroma != "4:2:0"
        let heavy = pixels >= 2 * uhdPixels || (pixels * 10 >= uhdPixels * 9 && rich)
        let weakNeeds = machine.isWeak && pixels > qhdPixels
        let lowMemoryNeeds = machine.isLowMemory && rich && pixels >= qhdPixels
        let softwareNeeds = softwareDecode && pixels * 10 >= hdPixels * 9
        return heavy || weakNeeds || lowMemoryNeeds || softwareNeeds ? .needsProxy(kind) : .skip(.lightSource)
    }

    static let hdPixels = 1920 * 1080

    /// Queue rank (lower runs first) of a media at timeline rank `rank`: software-decoded media move ahead of all others
    /// (`mediaCount` = number of ranked media) and keep their order among themselves; unranked (`.max`) stays last.
    public static func rank(_ rank: Int, softwareDecode: Bool, mediaCount: Int) -> Int {
        softwareDecode && rank != .max ? rank - mediaCount : rank
    }

    public static func usesProxiesForPlayback(_ mode: ProxyPlaybackMode, machine: MachineProfile) -> Bool {
        switch mode {
        case .auto: machine.isWeak
        case .on: true
        case .off: false
        }
    }
}

/// Background proxies never fill the disk: after the estimated proxy the volume keeps max(15 GB, 10 % of its size, at most 30 GB) free.
/// (8 GB Macs mostly ship with 256 GB disks; the cache cap alone is 50 GB.) Unknown sizes allow the job.
public enum ProxyDiskGuard {
    public static let floorBytes: Int64 = 15 << 30

    public static func allows(estimatedBytes: Int64, freeBytes: Int64?, volumeBytes: Int64?) -> Bool {
        guard let free = freeBytes else { return true }
        let reserve = max(floorBytes, min((volumeBytes ?? 0) / 10, 30 << 30))
        return free - max(0, estimatedBytes) >= reserve
    }

    /// Free and total bytes of the volume holding `url` (nil when unknown).
    public static func volume(of url: URL) -> (free: Int64?, total: Int64?) {
        #if os(Windows)
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacity.map(Int64.init), v?.volumeTotalCapacity.map(Int64.init))
        #else
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return (v?.volumeAvailableCapacityForImportantUsage, v?.volumeTotalCapacity.map(Int64.init))
        #endif
    }
}

/// Rough size of a proxy: ProRes 422 Proxy is about 45 Mbit/s at 1920x1080, 29.97 fps; scales with pixels and rate.
public enum ProxySizeEstimate {
    static let bitsPerSecond1080p30 = 45e6

    public static func bytes(kind: ProxyKind, width: Int, height: Int, frameDuration: Time, duration: Time) -> Int64 {
        let d = kind.scaleDivisor
        let pixels = Double(max(1, width / d) * max(1, height / d))
        let fps = frameDuration > .zero ? Double(frameDuration.timescale) / Double(frameDuration.value) : 30
        let seconds = Double(duration.value) / Double(max(1, duration.timescale))
        let rate = kind == .optimized ? bitsPerSecond1080p30 * 3.3 : bitsPerSecond1080p30   // ProRes 422 ~147 Mbit/s
        return Int64(rate / 8 * pixels / (1920 * 1080) * fps / 30 * max(0, seconds))
    }
}

/// The proxy settings in UserDefaults (`sq.proxy.*`): an app-wide mode, an optional per-project override (keyed by the
/// project's ID, so the project file stays unchanged) and the playback mode. Unknown values read as `.auto`.
public struct ProxySettingsStore: @unchecked Sendable {
    public static let modeKey = "sq.proxy.mode"
    public static let playbackKey = "sq.proxy.playback"
    public static func projectModeKey(_ project: UUID) -> String { "\(modeKey).\(project.uuidString)" }

    private let defaults: UserDefaults   // thread-safe

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The project's override if set, else the app setting.
    public func mode(project: UUID?) -> ProxyMode {
        if let project, let m = defaults.string(forKey: Self.projectModeKey(project)).flatMap(ProxyMode.init(rawValue:)) { return m }
        return defaults.string(forKey: Self.modeKey).flatMap(ProxyMode.init(rawValue:)) ?? .auto
    }

    /// `project` nil = the app setting; with a project, nil removes its override.
    public func setMode(_ mode: ProxyMode?, project: UUID?) {
        let key = project.map(Self.projectModeKey) ?? Self.modeKey
        if let mode { defaults.set(mode.rawValue, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    public static let exportKey = "sq.proxy.export"

    /// Global "use proxies for export": the render reads ready proxies instead of the originals (fast drafts, lower
    /// quality). Off by default; the export dialog and presets are unchanged.
    public var useProxiesForExport: Bool {
        get { defaults.bool(forKey: Self.exportKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.exportKey) }
    }

    public var playback: ProxyPlaybackMode {
        get { defaults.string(forKey: Self.playbackKey).flatMap(ProxyPlaybackMode.init(rawValue:)) ?? .auto }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.playbackKey) }
    }
}
