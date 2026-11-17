import Foundation
#if canImport(simd)
import simd
#endif

/// C3 (filmcraft follow-up, idea only): look thumbnails rendered on one fixed procedural test picture, so every look is
/// comparable at a glance and the thumbnail never needs user footage. The picture (display-encoded Rec.709): a vertical
/// sky gradient on top, a skin patch and six saturated chips in the middle, an 11-step gray ramp at the bottom.
///
/// Rendering runs the CPU reference of the color pipeline (`ColorPipeline`, kept equal to the GPU grade by its tests), so
/// thumbnails cost no GPU time and can never stall playback; callers run it off the main thread and cache the result.
public enum LookThumbnail {
    public static let width = 256
    public static let height = 144

    static let skin = SIMD3<Float>(0.85, 0.63, 0.50)
    static let chips: [SIMD3<Float>] = [
        SIMD3(0.85, 0.10, 0.10), SIMD3(0.90, 0.85, 0.10), SIMD3(0.08, 0.72, 0.12),
        SIMD3(0.10, 0.75, 0.85), SIMD3(0.12, 0.15, 0.85), SIMD3(0.80, 0.12, 0.75),
    ]
    static let skyTop = SIMD3<Float>(0.10, 0.25, 0.62)
    static let skyHorizon = SIMD3<Float>(0.72, 0.84, 0.95)

    /// The test picture as display-encoded Rec.709 colors, row by row from the top.
    public static func testPicture(width: Int = width, height: Int = height) -> [SIMD3<Float>] {
        var out = [SIMD3<Float>](repeating: .zero, count: max(width, 1) * max(height, 1))
        for y in 0..<height {
            let v = height > 1 ? Float(y) / Float(height - 1) : 0
            for x in 0..<width {
                let c: SIMD3<Float>
                if v < 0.45 {
                    c = simd_mix(skyTop, skyHorizon, SIMD3(repeating: v / 0.45))
                } else if v < 0.8 {
                    let cell = min(x * 7 / width, 6)
                    c = cell == 0 ? skin : chips[cell - 1]
                } else {
                    c = SIMD3(repeating: Float(min(x * 11 / width, 10)) / 10)
                }
                out[y * width + x] = c
            }
        }
        return out
    }

    @inline(__always) public static func byte(_ v: Float) -> UInt8 { v.isNaN ? 0 : UInt8(min(max(v, 0), 1) * 255 + 0.5) }

    /// RGBA8 (alpha 255) of the test picture through `lut` at `intensity` (nil = the picture unchanged).
    public static func render(lut: CubeLUT?, intensity: Float = 1, width: Int = width, height: Int = height) -> [UInt8] {
        let pic = testPicture(width: width, height: height)
        let pipe = lut.map { ColorPipeline(source: .rec709, ops: [.conversion(nil), .look($0, intensity: intensity)]) }
        var bytes = [UInt8](repeating: 255, count: pic.count * 4)
        for (i, p) in pic.enumerated() {
            var rgb = p
            if let pipe { rgb = TransferFunctions.bt709OETF(simd_clamp(pipe.process(p), .zero, SIMD3(repeating: 1))) }
            bytes[i * 4] = byte(rgb.x)
            bytes[i * 4 + 1] = byte(rgb.y)
            bytes[i * 4 + 2] = byte(rgb.z)
        }
        return bytes
    }
}
