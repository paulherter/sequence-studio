import Foundation

/// C5 Outline and Long Shadow (Slang kernels in Packages/SQGPU/Shaders/Parts/Outline.slang). Both work on the premultiplied working-linear padded
/// intermediate like every `ImageFilter`, in texture px, so they run at reduced size unchanged (`pf` converts the widths).
///
/// Outline: a jump-flood distance field to the alpha edge. Seeds are the 0.5 crossings between a pixel and its 4 neighbors
/// (linear in alpha: sub-pixel exact for straight edges); each texel then holds the nearest seed as an integer pixel offset
/// (exact in half floats up to 2048) plus the seed's sub-pixel part. log2(reach) + 1 jump passes, then one apply pass.
///
/// Long Shadow: about log2(length) passes over the alpha, s_k(p) = max(s_k-1(p), s_k-1(p - dir h_k) - fade h_k / L), which is
/// exactly the max over every whole step back along the direction of (alpha - its linear fade); then laid under the picture.
enum OutlineFilters {
    /// Seed texels whose x is beyond this are empty.
    static let emptySeed: Float = 30_000

    /// Jump steps for a distance field that must reach `reach` texture px: powers of two from the first one >= reach / 2
    /// down to 1, then 1 again (the extra pass fixes most jump-flood misses).
    static func jumpSteps(reach: Double) -> [Int] {
        var top = 1
        while Double(top * 2) < reach { top *= 2 }
        var steps: [Int] = []
        var s = top
        while s >= 1 { steps.append(s); s /= 2 }
        return steps + [1]
    }

    /// Size of the Long Shadow plane for a `width x height` working canvas: the same, or reduced (aspect kept) to hold
    /// `GaussianBlur.maxShapePassPixels`.
    static func shadowPlaneSize(width: Int, height: Int) -> (Int, Int) {
        guard width * height > GaussianBlur.maxShapePassPixels else { return (width, height) }
        let r = (Double(width * height) / Double(GaussianBlur.maxShapePassPixels)).squareRoot()
        var w = Int((Double(width) / r).rounded(.down)), h = Int((Double(height) / r).rounded(.down))
        while w * h > GaussianBlur.maxShapePassPixels { w -= 1; h = max(1, h - 1) }
        return (max(1, w), max(1, h))
    }

    /// Step lengths (texture px) of the Long Shadow passes for `length`: 1, 2, 4 ... while their sum stays below the length,
    /// then the rest. The sums of any subset then reach every whole px 0...length (and the length itself), never beyond, so
    /// a straight shadow ends exactly at its length and an axis-aligned one samples whole pixels only.
    static func shadowSteps(length: Double) -> [Double] {
        guard length > 0 else { return [] }
        var steps: [Double] = [], sum = 0.0, h = 1.0
        while sum + h < length { steps.append(h); sum += h; h *= 2 }
        steps.append(length - sum)
        return steps
    }
}
