import Foundation
import simd
import SSCore

/// The parameter type lives in SSCore (`Clip.color.correction`); the math stays here.
public typealias ColorCorrection = SSCore.ColorCorrection

extension SSCore.ColorCorrection {
    /// Precompute gamut-dependent constants once per clip/frame.
    public func prepared(for gamut: Gamut) -> PreparedCorrection { PreparedCorrection(self, gamut: gamut) }

    /// Convenience (prepares on every call; use `prepared(for:)` in loops).
    public func apply(_ rgb: SIMD3<Float>, gamut: Gamut) -> SIMD3<Float> { prepared(for: gamut).apply(rgb) }
}

public struct PreparedCorrection: Sendable {
    let wb: simd_float3x3
    let hasWB: Bool
    let exposureScale: Float
    let hasExposure: Bool
    let contrastScale: Float
    let highlights: Float
    let shadows: Float
    let hasTone: Bool
    let luma: SIMD3<Float>
    let saturation: Float
    let hasSaturation: Bool

    static let cctReference = 1e6 / 6504.0
    static let minLuma: Float = 1.0 / 65536

    init(_ c: ColorCorrection, gamut: Gamut) {
        func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }
        let temp = clamp(c.temperature, -100, 100), tint = clamp(c.tint, -100, 100)
        hasWB = temp != 0 || tint != 0
        if hasWB {
            let mired = Self.cctReference - Double(temp)
            // Positive tint -> magenta image: the assumed scene white is greenish (Duv > 0).
            let scene = WhitePoint.xy(cct: 1e6 / mired, duv: Double(tint) * 0.0002)
            let ref = WhitePoint.xy(cct: 1e6 / Self.cctReference, duv: 0)
            let a = WhitePoint.bradford(from: WhitePoint.xyz(scene), to: WhitePoint.xyz(ref))
            wb = (gamut.rgbToXYZDouble.inverse * a * gamut.rgbToXYZDouble).toFloat
        } else {
            wb = matrix_identity_float3x3
        }
        let ev = clamp(c.exposure, -4, 4)
        hasExposure = ev != 0
        exposureScale = exp2f(ev)
        contrastScale = 1 + 0.5 * clamp(c.contrast, -100, 100) / 100
        highlights = 1.5 * clamp(c.highlights, -100, 100) / 100
        shadows = 1.5 * clamp(c.shadows, -100, 100) / 100
        hasTone = c.contrast != 0 || c.highlights != 0 || c.shadows != 0
        luma = gamut.lumaRow
        saturation = clamp(c.saturation, 0, 200) / 100
        hasSaturation = saturation != 1
    }

    @inline(__always) static func smoothstep(_ x: Float) -> Float {  // edges 0…3
        let t = min(max(x / 3, 0), 1)
        return t * t * (3 - 2 * t)
    }

    public func apply(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        var c = rgb
        if hasWB { c = wb * c }
        if hasExposure { c *= exposureScale }
        if hasTone {
            // Gain curve G = 0.18·2^f(l) / Y on l = log2(max(Y, floor)/0.18). Below the floor (incl. Y <= 0) the gain is
            // constant (linear extension): continuous and monotonic through black.
            let y = simd_dot(luma, c)
            let yc = max(y, Self.minLuma)
            var l = log2f(yc / 0.18)
            l *= contrastScale
            l += highlights * Self.smoothstep(l)
            l += shadows * Self.smoothstep(-l)
            c *= 0.18 * exp2f(l) / yc
        }
        if hasSaturation {
            // Perceptual (log2 ratio to luminance): Y * (max(rgb, 2^-16) / Y)^s. Never negative.
            let y = simd_dot(luma, c)
            if y > Self.minLuma {
                let r = simd_max(c, SIMD3<Float>(repeating: Self.minLuma)) / y
                c = y * SIMD3(powf(r.x, saturation), powf(r.y, saturation), powf(r.z, saturation))
            }
        }
        return c
    }
}
