import Foundation
import Metal
import SQCore
import SQText
import SQTranscribe
import Testing
@testable import SQExport

// Captions on a non-square sequence are laid out in the display canvas (1920x1080 for 1440x1080 at 4:3) and squeezed
// into the stored pixels with the picture, so their box sits where the monitor and the hit test put it.
@Suite struct PixelShapeCaptionBurnInTests {
    private func bounds(width w: Int, height h: Int, par: PixelAspect) throws -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let c = Caption(lines: ["Pixel Shape"], range: TimeRange(start: .zero, end: Time(2, 1)), styleRef: "", animationRef: "")
        let burn = CaptionBurnIn(captions: [c], library: .builtIn)
        burn.pixelAspect = par
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
        let tex = try #require(device.makeTexture(descriptor: d))
        let cb = try #require(queue.makeCommandBuffer())
        let clear = MTLRenderPassDescriptor()
        clear.colorAttachments[0].texture = tex; clear.colorAttachments[0].loadAction = .clear
        clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        cb.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
        try burn.encode(at: Time(1, 1), into: tex, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var r = (minX: Int.max, maxX: -1, minY: Int.max, maxY: -1)
        for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 0.05 {
            r.minX = min(r.minX, x); r.maxX = max(r.maxX, x); r.minY = min(r.minY, y); r.maxY = max(r.maxY, y)
        } }
        return r.maxX >= 0 ? r : nil
    }

    @Test func burnInOn4x3PixelsIsTheDisplayPictureSqueezed() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let wide = try #require(try bounds(width: 1920, height: 1080, par: .square))
        let shaped = try #require(try bounds(width: 1440, height: 1080, par: PixelAspect(4, 3)!))
        // Same rows, columns scaled by stored / display = 0.75.
        #expect(abs(shaped.minY - wide.minY) <= 1 && abs(shaped.maxY - wide.maxY) <= 1)
        #expect(abs(Double(shaped.minX) - Double(wide.minX) * 0.75) <= 3)
        #expect(abs(Double(shaped.maxX) - Double(wide.maxX) * 0.75) <= 3)
    }
}
