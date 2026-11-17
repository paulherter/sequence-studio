import Foundation

/// The fields of `Compositor.Uniforms` the plan files touch (the real struct is the Metal layer's).
enum Compositor {}

extension Compositor {
    struct Uniforms {
        var canvas = SIMD2<Float>.zero, size = SIMD2<Float>.zero, position = SIMD2<Float>.zero, anchor = SIMD2<Float>.zero
        var scale = SIMD2<Float>(1, 1)
        var rotCos: Float = 1, rotSin: Float = 0
        var tilt = SIMD3<Float>.zero
        var crop = SIMD4<Float>.zero
        var roundFirst: UInt32 = 0
        var cropFeather: Float = 0, cornerRadius: Float = 0
        var keyCount: UInt32 = 0
        var key0 = SIMD4<Float>.zero, key1 = SIMD4<Float>.zero, matte0 = SIMD4<Float>.zero, matte1 = SIMD4<Float>.zero
        var shape0 = SIMD4<Float>.zero, shape1 = SIMD4<Float>.zero, cc0 = SIMD4<Float>.zero, cc1 = SIMD4<Float>.zero
    }
}
