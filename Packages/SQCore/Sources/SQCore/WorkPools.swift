import Foundation

/// The three worker pools of the engine and their caps (GAPS 4): decode/prefetch (media engine and VideoToolbox
/// sessions), GPU render (frames in flight on the Metal queue) and CPU fallback (software decode, analysis and other
/// work that is not on the media engine or the GPU). Each pool is capped on its own, so a flood of one kind (a
/// prefetch window after a seek) never starves another (a paused frame that needs the GPU).
public struct WorkPools: Sendable, Hashable {
    public var decode: Int
    public var gpu: Int
    public var cpu: Int

    public init(decode: Int, gpu: Int, cpu: Int) {
        self.decode = max(1, decode); self.gpu = max(1, gpu); self.cpu = max(1, cpu)
    }

    /// UserDefaults key of the debug preference that logs the caps at launch.
    public static let debugDefaultsKey = "sq.debug.workPools"

    /// One line for the log: `work pools: decode 4, gpu 2, cpu 3`.
    public var summary: String { "work pools: decode \(decode), gpu \(gpu), cpu \(cpu)" }

    /// The summary when the debug preference is on, else nil.
    public static func debugLine(for pools: WorkPools, defaults: UserDefaults = .standard) -> String? {
        defaults.bool(forKey: debugDefaultsKey) ? pools.summary : nil
    }
}

public extension WorkLimits {
    /// The caps per pool for this Mac: decode = preview decode jobs, gpu = frames in flight (render-ahead doubles it),
    /// cpu = software-path jobs (half the cores, one on weak Macs).
    var pools: WorkPools {
        WorkPools(decode: previewDecodeJobs, gpu: exportRenderAhead ? 2 : 1, cpu: cpuFallbackJobs)
    }
}
