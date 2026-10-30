import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure geometry of the 4-band strip: log frequency axis 20 Hz...20 kHz across `width`.
public struct CompressorBandsGeometry: Sendable, Equatable {
    public var width: CGFloat
    public var handleHitRadius: CGFloat = 6
    /// Height of the strip with its frequency labels (`Theme.Inspector.bandsHeight`).
    public static let stripHeight: CGFloat = 84
    /// Gain reduction that fills a bar completely.
    public static let fullScaleGainReductionDB: Double = 24

    public init(width: CGFloat) { self.width = width }

    private static var logMin: Double { log(CrossoverRules.minHz) }
    private static var logSpan: Double { log(CrossoverRules.maxHz) - log(CrossoverRules.minHz) }

    public func x(forHz hz: Double) -> CGFloat {
        let h = min(max(hz, CrossoverRules.minHz), CrossoverRules.maxHz)
        return CGFloat((log(h) - Self.logMin) / Self.logSpan) * width
    }

    public func hz(forX x: CGFloat) -> Double {
        guard width > 0 else { return CrossoverRules.minHz }
        let f = min(max(Double(x / width), 0), 1)
        return exp(Self.logMin + f * Self.logSpan)
    }

    /// x ranges of the 4 bands, low to high, tiling 0...width.
    public func bandRanges(crossoversHz: [Double]) -> [ClosedRange<CGFloat>] {
        let edges = [0] + crossoversHz.map { x(forHz: $0) } + [width]
        return (0..<(edges.count - 1)).map { edges[$0]...edges[$0 + 1] }
    }

    /// Index of the crossover handle within `handleHitRadius` of `x`, nearest first.
    public func handleIndex(at x: CGFloat, crossoversHz: [Double]) -> Int? {
        let hits = crossoversHz.enumerated()
            .map { ($0.offset, abs(self.x(forHz: $0.element) - x)) }
            .filter { $0.1 <= handleHitRadius }
        return hits.min { $0.1 < $1.1 }?.0
    }

    /// Frequency for dragging crossover `index` to `x`, clamped so the order is kept.
    public func draggedHz(index: Int, toX x: CGFloat, crossoversHz: [Double]) -> Double {
        CrossoverRules.clamp(hz(forX: x), index: index, in: crossoversHz)
    }

    /// 0...1 bar fill for a gain reduction in dB (positive = reduction).
    public static func barFraction(gainReductionDB: Double) -> Double {
        min(max(gainReductionDB / fullScaleGainReductionDB, 0), 1)
    }

    /// Crossover label: "120", "4.5k".
    public static func hzText(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1fk", hz / 1000) : String(format: "%.0f", hz)
    }
}
