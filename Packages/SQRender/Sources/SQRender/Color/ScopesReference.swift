import Foundation
#if canImport(simd)
import simd
#endif
import SQGPUKernels

public typealias ScopeLayout = SQGPUKernels.ScopeLayout
public typealias ScopeCounts = SQGPUKernels.ScopeCounts

/// CPU reference for the GPU scopes (same per-pixel functions and binning): the Mac's working-linear pixels through
/// `Rec709Output.encode`, then the shared `ScopeBinning` (SQGPUKernels, also used by the Windows app).
public enum ScopesReference {
    public static let lumaCoefficients = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// Output signal R'G'B' (clamped 0…1, BT.709 OETF) and Y'.
    public static func signal(_ workingLinear: SIMD3<Float>) -> (rgb: SIMD3<Float>, y: Float) {
        let s = Rec709Output.encode(workingLinear)
        return (s, s.x * 0.2126 + s.y * 0.7152 + s.z * 0.0722)
    }

    public static func cbcr(_ rgb: SIMD3<Float>) -> SIMD2<Float> { ScopeBinning.cbcr(rgb) }
    public static func level(_ v: Float, levels: Int) -> Int { ScopeBinning.level(v, levels: levels) }
    public static func vectorscopeBin(cb: Float, cr: Float, size n: Int) -> (col: Int, row: Int) {
        ScopeBinning.vectorscopeBin(cb: cb, cr: cr, size: n)
    }

    /// `pixels` row-major, working-linear. `pixelStride` N: only pixels with x % N == 0 and y % N == 0.
    public static func compute(pixels: [SIMD3<Float>], width: Int, height: Int, layout: ScopeLayout,
                               pixelStride: Int = 1) -> ScopeCounts {
        var out = ScopeCounts(layout: layout)
        let step = max(1, pixelStride)
        for y in Swift.stride(from: 0, to: height, by: step) {
            for x in Swift.stride(from: 0, to: width, by: step) {
                let (rgb, luma) = signal(pixels[y * width + x])
                ScopeBinning.add(rgb, luma: luma, x: x, width: width, to: &out)
            }
        }
        ScopeBinning.finish(&out)
        return out
    }
}
