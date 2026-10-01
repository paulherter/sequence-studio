import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

private func solid(_ w: Int, _ h: Int, _ v: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    CVPixelBufferLockBaseAddress(pb!, [])
    defer { CVPixelBufferUnlockBaseAddress(pb!, []) }
    let base = CVPixelBufferGetBaseAddress(pb!)!, stride = CVPixelBufferGetBytesPerRow(pb!)
    for y in 0..<h { for x in 0..<w {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        p[0] = v; p[1] = v; p[2] = v; p[3] = 255
    } }
    return pb!
}

private func lin709(_ e: Double) -> Double {
    e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

private func hint() -> VideoTrackInfo {
    VideoTrackInfo(width: 16, height: 16, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, matrix: nil)
}

@Suite struct FrameBlendTests {
    @Test func weightIsTheFractionalSourcePosition() {
        let fd = Time(1, 30)
        // 50 % speed: timeline frame 1 shows source 0.5 frames in: halfway between A (frame 0) and B (frame 1).
        #expect(FrameBlend.weight(sourceTime: Time(1, 60), frameStart: .zero, frameDuration: fd) == 0.5)
        #expect(FrameBlend.weight(sourceTime: .zero, frameStart: .zero, frameDuration: fd) == 0)
        #expect(FrameBlend.weight(sourceTime: Time(1, 120), frameStart: .zero, frameDuration: fd) == 0.25)
        #expect(FrameBlend.weight(sourceTime: Time(7, 30) + Time(1, 90), frameStart: Time(7, 30), frameDuration: fd) > 0.33)
    }

    @Test func outputIsTheMixByTheWeight() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return }
        let fmt = SequenceFormat(width: 16, height: 16, frameDuration: Time(1, 30))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let target = dev.makeTexture(descriptor: d)!
        for w: Float in [0.25, 0.5, 0.75] {
            let a = solid(16, 16, 0), b = solid(16, 16, 255)
            let layer = RenderLayer(content: .frame(a, colorHint: hint()), blend: FrameBlend(next: b, weight: w))
            let cb = q.makeCommandBuffer()!
            try comp.render([layer], format: fmt, into: target, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            var px = [Float16](repeating: 0, count: 4)
            target.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(8, 8, 1, 1), mipmapLevel: 0)
            let encoded = Double(w)                                      // mix of black (0) and white (1) in encoded space
            #expect(abs(Double(px[0]) - lin709(encoded)) < 2.0 / 255, "weight \(w): got \(px[0]) want \(lin709(encoded))")
        }
        // No blend object, or weight 0: the first frame alone.
        let a = solid(16, 16, 255)
        let layer = RenderLayer(content: .frame(a, colorHint: hint()), blend: FrameBlend(next: solid(16, 16, 0), weight: 0))
        let cb = q.makeCommandBuffer()!
        try comp.render([layer], format: fmt, into: target, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: 4)
        target.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(8, 8, 1, 1), mipmapLevel: 0)
        #expect(abs(Double(px[0]) - 1) < 2.0 / 255)
    }
}
