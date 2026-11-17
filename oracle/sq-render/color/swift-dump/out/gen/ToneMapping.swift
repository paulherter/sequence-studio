import Foundation
#if canImport(simd)
import simd
#endif

/// HDR -> SDR highlight roll-off on maxRGB (hue-preserving). Identity below `knee`, C¹ at the knee.
/// Without a peak (Log sources, scene light without a fixed top) the roll-off is exponential with asymptote 1.0.
/// With a peak (display-referred HLG / PQ, see `SourceColorSpace.toneMapPeak`) it is an extended Reinhard that reaches
/// exactly 1.0 at the peak, so the whole HDR highlight range keeps its steps instead of saturating at ~2x reference white.
/// The Metal `toneMap` in `ColorShaderSource` is the same function (playback = export).
public struct ToneMapping: Sendable, Equatable {
    /// Clamped to 0…0.99 so the roll-off range (1 − knee) stays positive.
    public var knee: Float { didSet { knee = min(max(knee, 0), 0.99) } }

    /// Export-time HDR to SDR trim: gain in stops applied to the light before the roll-off (clamped to -4…4; 0 = none).
    public var exposureStops: Float { didSet { exposureStops = min(max(exposureStops, -4), 4) } }
    /// Soft gamut compression (`SoftGamutCompression`) of colors outside Rec.709 before the roll-off, instead of clipping them.
    public var compressesGamut: Bool

    public init(knee: Float = 0.8, exposureStops: Float = 0, compressesGamut: Bool = false) {
        self.knee = min(max(knee, 0), 0.99)
        self.exposureStops = min(max(exposureStops, -4), 4)
        self.compressesGamut = compressesGamut
    }

    /// Linear gain of `exposureStops`.
    public var exposureGain: Float { exposureStops == 0 ? 1 : exp2f(exposureStops) }

    /// Rec.709-primaries linear light of an HDR source -> after gamut compression and exposure gain, ready for `apply`.
    public func trim(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        var c = rgb
        if compressesGamut { c = SoftGamutCompression.compress(c) }
        return exposureStops == 0 ? c : c * exposureGain
    }

    /// Mapped value of the channel maximum, exponential roll-off (no peak).
    @inline(__always) public func mapMax(_ m: Float) -> Float {
        if m <= knee { return m }
        let r = 1 - knee
        return knee + r * (1 - expf(-(m - knee) / r))
    }

    /// Mapped value of the channel maximum; with a peak above the knee, `peak` lands on 1.0 and above it clips.
    /// h(x) = x (1 + x / w²) / (1 + x) on x = (m − knee) / r, w = (peak − knee) / r: h(0) = 0, h'(0) = 1, h(w) = 1.
    @inline(__always) public func mapMax(_ m: Float, peak: Float?) -> Float {
        guard let peak, peak > knee + 1e-4 else { return mapMax(m) }
        if m <= knee { return m }
        if m >= peak { return 1 }
        let r = 1 - knee
        let w = (peak - knee) / r
        let x = (m - knee) / r
        return knee + r * (x * (1 + x / (w * w)) / (1 + x))
    }

    public func apply(_ rgb: SIMD3<Float>) -> SIMD3<Float> { apply(rgb, peak: nil) }

    public func apply(_ rgb: SIMD3<Float>, peak: Float?) -> SIMD3<Float> {
        let m = max(rgb.x, max(rgb.y, rgb.z))
        if m <= knee { return rgb }
        return rgb * (mapMax(m, peak: peak) / m)
    }
}

extension SourceColorSpace {
    /// Display-referred peak (1.0 = 203 nit reference white) the tone map rolls off to: HLG's nominal 1000 nit display
    /// (signal 1.0 decodes to it) and PQ graded for 1000 nits (iPhone Dolby Vision 8.1 / HDR10; brighter PQ clips).
    /// nil for Rec.709 (no tone map) and Log (scene light, open-ended roll-off).
    public var toneMapPeak: Float? {
        switch self {
        case .hlgBT2020: TransferFunctions.hlgDecode(SIMD3(repeating: 1)).x
        case .pqBT2020: 1000 / TransferFunctions.pqReferenceWhite
        case .rec709, .sLog3SGamut3Cine, .vLogVGamut, .appleLog, .dLogDGamut: nil
        case .canonLogCinemaGamut, .canonLogBT2020, .canonLogBT709, .canonLog2CinemaGamut, .canonLog2BT2020, .canonLog2BT709,
             .canonLog3CinemaGamut, .canonLog3BT2020, .canonLog3BT709: nil
        case .logC3WideGamut3, .logC4WideGamut4, .log3G10RedWideGamut, .bmdFilmGen5WideGamut, .nLogBT2020, .fLog2FGamutC,
             .acesCCTAP1: nil
        }
    }
}
