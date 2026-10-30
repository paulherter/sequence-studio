#if canImport(simd)
import simd
#endif

/// SDR output gamut: Rec.709 (default), P3-D65 or Rec.2020. Working-linear is converted to the target primaries, colors
/// outside the target are compressed softly (`SoftGamutCompression`) instead of being clipped, then encoded.
/// shortcut: CPU reference only; the GPU export and monitor path still use `Rec709Output` (ColorGraph files are held by
/// another task). Wire this in with the output-space picker.
public enum OutputTarget: String, Sendable, Equatable, Codable, CaseIterable {
    case rec709, displayP3, rec2020

    public var gamut: Gamut {
        switch self {
        case .rec709: .rec709
        case .displayP3: .displayP3
        case .rec2020: .bt2020
        }
    }

    /// `workingLinear` in `working` primaries -> encoded 0...1 in this target (BT.709 OETF; the Rec.2020 SDR curve is the same).
    public func encode(_ workingLinear: SIMD3<Float>, working: Gamut) -> SIMD3<Float> {
        let inTarget = working.matrix(to: gamut) * workingLinear
        let compressed = SoftGamutCompression.compress(inTarget)
        return TransferFunctions.bt709OETF(simd_clamp(compressed, SIMD3<Float>.zero, SIMD3<Float>.one))
    }
}

/// Pulls negative (out-of-gamut) channels back toward the gamut along the distance from the brightest channel, which
/// keeps that channel and so the brightness and, to first order, the hue. Distances below `threshold` pass unchanged
/// (most of the gamut is untouched; the last 10 percent toward a pure primary is eased in so there is no step at the edge); beyond it an extended-Reinhard shoulder maps distance `limit` onto the
/// gamut edge (distance 1) and stays monotonic, so there is no clip edge.
public enum SoftGamutCompression {
    public static let threshold: Float = 0.9
    public static let limit: Float = 1.5

    public static func compress(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let m = max(rgb.x, rgb.y, rgb.z)
        guard m > 0 else { return rgb }
        var out = rgb
        for i in 0..<3 where rgb[i] < m {
            let d = (m - rgb[i]) / m
            out[i] = m - compressDistance(d) * m
        }
        return out
    }

    static func compressDistance(_ d: Float) -> Float {
        guard d > threshold else { return d }
        let room = 1 - threshold
        let x = (d - threshold) / room
        let l = (limit - threshold) / room
        let y = x * (1 + x / (l * l)) / (1 + x)
        return threshold + room * y
    }
}
