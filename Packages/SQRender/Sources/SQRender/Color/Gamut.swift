import Foundation
import simd

/// RGB gamut defined by xy primaries and white point. Matrices are built in Double, exposed as Float.
public struct Gamut: Sendable, Equatable {
    public let red: SIMD2<Double>
    public let green: SIMD2<Double>
    public let blue: SIMD2<Double>
    public let white: SIMD2<Double>
    public let rgbToXYZDouble: simd_double3x3
    public let rgbToXYZ: simd_float3x3
    public let xyzToRGB: simd_float3x3
    /// Y row of `rgbToXYZ`.
    public let lumaRow: SIMD3<Float>

    public init(red: SIMD2<Double>, green: SIMD2<Double>, blue: SIMD2<Double>, white: SIMD2<Double>) {
        self.red = red; self.green = green; self.blue = blue; self.white = white
        let p = simd_double3x3(columns: (WhitePoint.xyz(red), WhitePoint.xyz(green), WhitePoint.xyz(blue)))
        let s = p.inverse * WhitePoint.xyz(white)
        let m = p * simd_double3x3(diagonal: s)
        rgbToXYZDouble = m
        rgbToXYZ = m.toFloat
        xyzToRGB = m.inverse.toFloat
        lumaRow = SIMD3<Float>(Float(m[0][1]), Float(m[1][1]), Float(m[2][1]))
    }

    static let d65 = SIMD2<Double>(0.3127, 0.3290)
    public static let rec709 = Gamut(red: [0.64, 0.33], green: [0.30, 0.60], blue: [0.15, 0.06], white: d65)
    public static let bt2020 = Gamut(red: [0.708, 0.292], green: [0.170, 0.797], blue: [0.131, 0.046], white: d65)
    public static let sGamut3Cine = Gamut(red: [0.766, 0.275], green: [0.225, 0.800], blue: [0.089, -0.087], white: d65)

    /// Linear RGB(self) -> linear RGB(target), Bradford-adapted when the white points differ.
    public func matrix(to target: Gamut) -> simd_float3x3 {
        var m = target.rgbToXYZDouble.inverse
        if white != target.white {
            m = m * WhitePoint.bradford(from: WhitePoint.xyz(white), to: WhitePoint.xyz(target.white))
        }
        return (m * rgbToXYZDouble).toFloat
    }
}

public enum WhitePoint {
    /// xy (Y = 1) -> XYZ.
    public static func xyz(_ xy: SIMD2<Double>) -> SIMD3<Double> {
        SIMD3<Double>(xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y)
    }

    static let bradfordM = simd_double3x3(rows: [
        SIMD3<Double>(0.8951, 0.2664, -0.1614),
        SIMD3<Double>(-0.7502, 1.7135, 0.0367),
        SIMD3<Double>(0.0389, -0.0685, 1.0296),
    ])

    /// XYZ -> XYZ adaptation matrix (Bradford) from source white to destination white.
    public static func bradford(from src: SIMD3<Double>, to dst: SIMD3<Double>) -> simd_double3x3 {
        let cs = bradfordM * src, cd = bradfordM * dst
        return bradfordM.inverse * simd_double3x3(diagonal: cd / cs) * bradfordM
    }

    /// CIE 1960 uv of the Planckian locus (Krystek 1985), T in kelvin (≈1000…15000, extrapolates smoothly).
    static func planckUV(_ t: Double) -> SIMD2<Double> {
        let t2 = t * t
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t2) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t2)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t2) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t2)
        return SIMD2(u, v)
    }

    /// Chromaticity for correlated colour temperature and Duv (positive = above the locus = greenish).
    public static func xy(cct: Double, duv: Double) -> SIMD2<Double> {
        var uv = planckUV(cct)
        if duv != 0 {
            let a = planckUV(cct - 10), b = planckUV(cct + 10)
            let d = b - a
            var n = SIMD2(-d.y, d.x)
            n /= (n.x * n.x + n.y * n.y).squareRoot()
            if n.y < 0 { n = -n }
            uv += duv * n
        }
        let k = 2 * uv.x - 8 * uv.y + 4
        return SIMD2(3 * uv.x / k, 2 * uv.y / k)
    }
}

extension simd_double3x3 {
    var toFloat: simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(columns.0), SIMD3<Float>(columns.1), SIMD3<Float>(columns.2)))
    }
}
