#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
import simd
@testable import SQRender

// Stabilizer v2: the residual perspective rides in the Rolling Shutter warp pass. Zero perspective leaves the output
// bit-identical, a point lands where the correction maps it, and the GPU kernel matches the reference.

private func ref(_ f: ImageFilter, _ img: ImageFilters.Image) -> ImageFilters.Image {
    let size = SIMD2(Float(img.width), Float(img.height))
    return StyleFilters.reference(f, img, frame: ImageFilters.Frame(center: size / 2, size: size))!
}

private func smooth(_ x: Int, _ y: Int) -> SIMD4<Float> {
    let fx = Float(x), fy = Float(y)
    return SIMD4(0.5 + 0.4 * sin(fx / 17 + fy / 29), 0.5 + 0.4 * cos(fx / 23 - fy / 19), 0.5 + 0.4 * sin(fx / 31) * cos(fy / 13), 1)
}

private let zeros = [Double](repeating: 0, count: 8)

private func bytePixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
    func c(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (128 + 100 * v).rounded()))) }
    return (c(sin(Double(x) / 17 + Double(y) / 29)), c(cos(Double(x) / 23 - Double(y) / 19)), c(sin(Double(x) / 31) * cos(Double(y) / 13)))
}

private func linearPixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
    let p = bytePixel(x, y)
    return SIMD4(StyleFilters.dec(Float(p.0) / 255), StyleFilters.dec(Float(p.1) / 255), StyleFilters.dec(Float(p.2) / 255), 1)
}

private func makeBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h {
        for x in 0..<w {
            let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            let c = bytePixel(x, y)
            px[0] = c.2; px[1] = c.1; px[2] = c.0; px[3] = 255
        }
    }
    return b
}

@Suite struct StabilizerPerspectiveWarpTests {
    @Test func zeroPerspectiveIsBitIdenticalToTheRollingShutterPass() {
        let img = ImageFilters.Image(width: 64, height: 48, smooth)
        for (shear, alongX) in [(Vec2(0.2, 0.05), false), (Vec2(-0.1, 0.2), true)] {
            let a = ref(.rollingShutter(shear: shear, alongX: alongX), img)
            let b = ref(.stabilizeWarp(shear: shear, alongX: alongX, perspective: zeros), img)
            #expect(a.px == b.px)
        }
        // The uniforms are the same, too: no perspective flag, no extra terms.
        let frame = ImageFilters.Frame(center: SIMD2(32, 24), size: SIMD2(64, 48))
        let u1 = StyleFilters.plan(.rollingShutter(shear: Vec2(0.2, 0.05), alongX: false), frame: frame, pf: 1)?.1
        let u2 = StyleFilters.plan(.stabilizeWarp(shear: Vec2(0.2, 0.05), alongX: false, perspective: zeros), frame: frame, pf: 1)?.1
        #expect(u1 != nil && u1?.i == u2?.i && u1?.c == u2?.c && u1?.d == u2?.d)
    }

    @Test func aPointLandsWhereTheCorrectionMapsIt() {
        let w = 128, h = 96
        let v = [0.01, 0.004, 2.0, -0.006, -0.008, -1.5, 3e-4, -2e-4]
        let k = PerspectiveResidual(v)
        for p in [Vec2(-30, -20), Vec2(0, 0), Vec2(35, 22)] {
            let dot = ImageFilters.Image(width: w, height: h) { x, y in
                let d = max(0, 1 - hypot(Float(x) + 0.5 - 64 - Float(p.x), Float(y) + 0.5 - 48 - Float(p.y)) / 4)
                return SIMD4(d, d, d, 1)
            }
            let out = ref(.stabilizeWarp(shear: .zero, alongX: false, perspective: v), dot)
            var sx: Float = 0, sy: Float = 0, sw: Float = 0
            for y in 0..<h { for x in 0..<w { let g = out[x, y].x; sx += g * (Float(x) + 0.5); sy += g * (Float(y) + 0.5); sw += g } }
            let want = k.map(p)
            #expect(sw > 0 && abs(Double(sx / sw) - 64 - want.x) < 0.3 && abs(Double(sy / sw) - 48 - want.y) < 0.3,
                    "p \(p): got (\(sx / sw - 64), \(sy / sw - 48)) want \(want)")
        }
    }

    @Test func theKernelMatchesTheReference() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return }
        let w = 64, h = 48
        let pb = makeBuffer(w, h)
        for f in [ImageFilter.stabilizeWarp(shear: .zero, alongX: false, perspective: [0.01, 0.004, 1.5, -0.006, -0.008, -1, 3e-4, -2e-4]),
                  .stabilizeWarp(shear: Vec2(0.1, 0.05), alongX: true, perspective: [0, 0.01, 0, -0.01, 0, 0, 0, 5e-4])] {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
            let t = dev.makeTexture(descriptor: td)!
            let hint = VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                                      nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
            let cb = queue.makeCommandBuffer()!
            try comp.render([RenderLayer(content: .frame(pb, colorHint: hint), effects: ClipEffects(segments: [EffectSegment(filter: f), EffectSegment()]))],
                            format: SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)), into: t, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            #expect(cb.error == nil)
            var half = [Float16](repeating: 0, count: w * h * 4)
            t.getBytes(&half, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let want = ref(f, ImageFilters.Image(width: w, height: h) { x, y in linearPixel(x, y) })
            var worst: Float = 0, at = 0
            for i in 0..<(w * h) { for c in 0..<3 where abs(Float(half[i * 4 + c]) - want.px[i][c]) > worst { worst = abs(Float(half[i * 4 + c]) - want.px[i][c]); at = i } }
            #expect(worst <= 0.01, "\(f): worst \(worst) at (\(at % w), \(at / w)) got \(half[at * 4]) want \(want.px[at])")
        }
    }
}
#endif
