import Foundation
import simd

/// HDR -> SDR highlight roll-off on maxRGB (hue-preserving). Identity below `knee`, C¹ at the knee, asymptote 1.0.
public struct ToneMapping: Sendable, Equatable {
    /// Clamped to 0…0.99 so the roll-off range (1 − knee) stays positive.
    public var knee: Float { didSet { knee = min(max(knee, 0), 0.99) } }

    public init(knee: Float = 0.8) { self.knee = min(max(knee, 0), 0.99) }

    /// Mapped value of the channel maximum.
    @inline(__always) public func mapMax(_ m: Float) -> Float {
        if m <= knee { return m }
        let r = 1 - knee
        return knee + r * (1 - expf(-(m - knee) / r))
    }

    public func apply(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let m = max(rgb.x, max(rgb.y, rgb.z))
        if m <= knee { return rgb }
        return rgb * (mapMax(m) / m)
    }
}
