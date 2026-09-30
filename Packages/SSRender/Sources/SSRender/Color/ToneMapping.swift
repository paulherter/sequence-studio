import Foundation
import simd

/// HDR -> SDR highlight roll-off on maxRGB (hue-preserving). Identity below `knee`, C¹ at the knee, asymptote 1.0.
public struct ToneMapping: Sendable, Equatable {
    public var knee: Float

    public init(knee: Float = 0.8) { self.knee = knee }

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
