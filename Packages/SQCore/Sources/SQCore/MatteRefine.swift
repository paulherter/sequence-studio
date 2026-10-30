#if canImport(Accelerate)
import Accelerate
#endif
import Foundation

/// Shared matte clean-up: shrink / grow, contrast around a midpoint, and (spatial) edge feather. Value maths (the spatial
/// filters run on vImage, a maths library, no image/media framework), so keyers, masks and any other coverage source can use the same controls and the same numbers.
///
/// Convention: a matte value is coverage, 1 = kept, 0 = gone (a mask's inside is 1; a key's kept share is 1 - K).
///
/// Two halves:
/// - `tone(_:)` is per pixel and needs no neighbors (shrink / grow as a curve, contrast, midpoint). The compositor shader
///   mirrors it, so it costs nothing extra per pixel.
/// - `refine(_:width:height:)` is spatial on a matte grid (true erode / dilate and a box feather): the CPU reference and
///   the path for masks rasterized to a grid.
public struct MatteRefine: Sendable, Hashable {
    /// -1...1. Positive pushes the matte towards "gone" (the kept picture shrinks), negative towards "kept" (it grows).
    /// 1 removes everything below 0.9 coverage; 0 = unchanged.
    public var shrink: Double
    /// 0...1: steepens the edge ramp around `midpoint`. 0 = unchanged.
    public var contrast: Double
    /// 0...1: the coverage the contrast pivots on (0.5 = neutral). Only matters when `contrast` > 0.
    public var midpoint: Double
    /// Spatial feather radius in matte px (box blur), used by `refine` only. 0 = none.
    public var feather: Double
    /// Spatial shrink (+) / grow (-) in matte px (erode / dilate with a square kernel), used by `refine` only.
    public var shrinkPx: Double

    public init(shrink: Double = 0, contrast: Double = 0, midpoint: Double = 0.5, feather: Double = 0, shrinkPx: Double = 0) {
        self.shrink = shrink; self.contrast = contrast; self.midpoint = midpoint
        self.feather = feather; self.shrinkPx = shrinkPx
    }

    public static let identity = MatteRefine()

    /// True when `tone` leaves every value alone.
    public var isToneIdentity: Bool { shrink == 0 && contrast == 0 }
    /// True when `refine` leaves a matte alone.
    public var isSpatialIdentity: Bool { shrinkPx == 0 && feather == 0 }

    /// Contrast slope at `contrast` 1 is 1 + 9 = 10x.
    public static let contrastGain = 9.0
    /// How much of the 0...1 range one full unit of `shrink` covers.
    public static let shrinkReach = 0.9

    /// Per-pixel refinement of coverage `c` (0...1).
    public func tone(_ c: Double) -> Double {
        var m = min(max(c, 0), 1)
        if shrink > 0 {
            let s = Self.shrinkReach * min(shrink, 1)
            m = min(max((m - s) / max(1 - s, 1e-4), 0), 1)
        } else if shrink < 0 {
            let g = Self.shrinkReach * min(-shrink, 1)
            m = min(m / max(1 - g, 1e-4), 1)
        }
        if contrast > 0 {
            m = min(max((m - midpoint) * (1 + Self.contrastGain * min(contrast, 1)) + midpoint, 0), 1)
        }
        return m
    }

    /// Float variant for the pixel loops and the shader reference.
    public func toneF(_ c: Float) -> Float { Float(tone(Double(c))) }

    // MARK: Spatial

    /// Refines a `width` x `height` coverage grid (row major): erode / dilate by `shrinkPx` (rounded to whole px), then box
    /// feather of radius `feather`, then `tone`. Edges clamp. Returns the input for an identity refine.
    public func refine(_ matte: [Float], width: Int, height: Int) -> [Float] {
        precondition(matte.count == width * height, "matte size")
        var m = matte
        let r = Int(abs(shrinkPx).rounded())
        if r > 0 { m = Self.morph(m, width: width, height: height, radius: r, erode: shrinkPx > 0) }
        let f = Int(feather.rounded())
        if f > 0 { m = Self.boxBlur(m, width: width, height: height, radius: f) }
        if !isToneIdentity { m = m.map { toneF($0) } }
        return m
    }

#if canImport(Accelerate)
    /// Min (erode) or max (dilate) filter with a (2r+1) square kernel, edges clamped. vImage (Accelerate is precompiled,
    /// so this stays ~ms even in a debug build: a Magic mask refines a 512 px matte per played frame).
    static func morph(_ src: [Float], width: Int, height: Int, radius r: Int, erode: Bool) -> [Float] {
        let k = vImagePixelCount(2 * r + 1)
        return run(src, width: width, height: height) { s, d in
            erode ? vImageMin_PlanarF(&s, &d, nil, 0, 0, k, k, vImage_Flags(kvImageEdgeExtend))
                  : vImageMax_PlanarF(&s, &d, nil, 0, 0, k, k, vImage_Flags(kvImageEdgeExtend))
        }
    }

    /// Separable box blur, (2r+1) wide, edges clamped (a horizontal then a vertical vImage convolution).
    static func boxBlur(_ src: [Float], width: Int, height: Int, radius r: Int) -> [Float] {
        let n = 2 * r + 1
        let kernel = [Float](repeating: 1 / Float(n), count: n)
        let h = run(src, width: width, height: height) { s, d in
            vImageConvolve_PlanarF(&s, &d, nil, 0, 0, kernel, 1, UInt32(n), 0, vImage_Flags(kvImageEdgeExtend))
        }
        return run(h, width: width, height: height) { s, d in
            vImageConvolve_PlanarF(&s, &d, nil, 0, 0, kernel, UInt32(n), 1, 0, vImage_Flags(kvImageEdgeExtend))
        }
    }

    private static func run(_ src: [Float], width w: Int, height h: Int,
                            _ body: (inout vImage_Buffer, inout vImage_Buffer) -> vImage_Error) -> [Float] {
        var input = src
        var out = [Float](repeating: 0, count: w * h)
        input.withUnsafeMutableBytes { a in
            out.withUnsafeMutableBytes { b in
                var s = vImage_Buffer(data: a.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var d = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                _ = body(&s, &d)
            }
        }
        return out
    }
#else
    // Plain-Swift path for platforms without Accelerate (Linux): separable, edges clamped, same results as vImage.
    static func morph(_ src: [Float], width: Int, height: Int, radius r: Int, erode: Bool) -> [Float] {
        let h = pass(src, width: width, height: height, radius: r, horizontal: true) { erode ? min($0, $1) : max($0, $1) }
        return pass(h, width: width, height: height, radius: r, horizontal: false) { erode ? min($0, $1) : max($0, $1) }
    }

    static func boxBlur(_ src: [Float], width: Int, height: Int, radius r: Int) -> [Float] {
        let w = 1 / Float(2 * r + 1)
        func blur(_ a: [Float], _ horizontal: Bool) -> [Float] {
            var out = pass(a, width: width, height: height, radius: r, horizontal: horizontal, initial: 0) { $0 + $1 }
            for i in out.indices { out[i] *= w }
            return out
        }
        return blur(blur(src, true), false)
    }

    private static func pass(_ src: [Float], width w: Int, height h: Int, radius r: Int, horizontal: Bool,
                             initial: Float? = nil, _ combine: (Float, Float) -> Float) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        let lines = horizontal ? h : w, len = horizontal ? w : h
        for l in 0..<lines {
            for i in 0..<len {
                var acc = initial
                for o in -r...r {
                    let j = min(max(i + o, 0), len - 1)
                    let v = horizontal ? src[l * w + j] : src[j * w + l]
                    acc = acc.map { combine($0, v) } ?? v
                }
                let dst = horizontal ? l * w + i : i * w + l
                out[dst] = acc ?? 0
            }
        }
        return out
    }
#endif
}
