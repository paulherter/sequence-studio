#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Sequence pixel shape: layers live in display space and are squeezed into the stored pixels at the draw.

@Suite struct PixelShapeRenderTests {
    private static func disc(_ n: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
        precondition(CVPixelBufferCreate(nil, n, n, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
        let r = Double(n) / 2
        for y in 0..<n { for x in 0..<n {
            let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            let inside = hypot(Double(x) + 0.5 - r, Double(y) + 0.5 - r) < r
            let v: UInt8 = inside ? 255 : 0
            p[0] = v; p[1] = v; p[2] = v; p[3] = 255
        } }
        return b
    }

    private static func render(_ pb: CVPixelBuffer, format f: SequenceFormat, transform: ClipTransform = .identity) throws -> [[Bool]]? {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let comp = try? Compositor(device: d) else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: f.width, height: f.height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let t = d.makeTexture(descriptor: td)!
        let hint = VideoTrackInfo(width: 100, height: 100, codec: "bgra", bitDepth: 8, chroma: "4:4:4",
                                  nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
        let cb = q.makeCommandBuffer()!
        try comp.render([RenderLayer(content: .frame(pb, colorHint: hint), transform: transform)], format: f, into: t, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: f.width * f.height * 4)
        t.getBytes(&px, bytesPerRow: f.width * 8, from: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0)
        return (0..<f.height).map { y in (0..<f.width).map { x in Float(px[(y * f.width + x) * 4]) > 0.5 } }
    }

    private static func extent(_ lit: [[Bool]]) -> (w: Int, h: Int) {
        let h = lit.indices.filter { y in lit[y].contains(true) }
        let w = (0..<lit[0].count).filter { x in lit.indices.contains { lit[$0][x] } }
        return (w.count, h.count)
    }

    @Test func squarePictureOnAnamorphicSequenceStaysRound() throws {
        // 100 x 100 stored at 2:1 shows 200 x 100. A 100 x 100 disc at Scale 1 is a disc of diameter 100 in display
        // space, which the squeeze lands as an ellipse 50 stored px wide and 100 high (aspect 2 : 1 when shown).
        var f = SequenceFormat(width: 100, height: 100, frameDuration: Time(1, 25))
        f.pixelAspect = PixelAspect(2, 1)!
        guard let lit = try Self.render(Self.disc(100), format: f) else { return }
        let e = Self.extent(lit)
        #expect(abs(e.w - 50) <= 2 && abs(e.h - 100) <= 2, "extent \(e)")
        // Shown aspect (stored width x shape / height) is 1: the circle stays a circle.
        #expect(abs(Double(e.w) * 2 / Double(e.h) - 1) < 0.05)
        #expect(lit[50][50] && !lit[50][5] && !lit[50][95])
    }

    @Test func squareSequenceDrawsAsBefore() throws {
        let f = SequenceFormat(width: 100, height: 100, frameDuration: Time(1, 25))
        guard let lit = try Self.render(Self.disc(100), format: f) else { return }
        let e = Self.extent(lit)
        #expect(abs(e.w - 100) <= 2 && abs(e.h - 100) <= 2, "extent \(e)")
    }

    @Test func positionIsInDisplayPixels() throws {
        // Moving the disc 50 display px right is 25 stored px.
        var f = SequenceFormat(width: 100, height: 100, frameDuration: Time(1, 25))
        f.pixelAspect = PixelAspect(2, 1)!
        guard let lit = try Self.render(Self.disc(100), format: f, transform: ClipTransform(position: Vec2(50, 0))) else { return }
        let xs = (0..<100).filter { x in lit.indices.contains { lit[$0][x] } }
        let center = Double(xs.first! + xs.last!) / 2
        #expect(abs(center - 75) <= 2, "center \(center)")
    }
}

// The monitor layer keeps its Pixel Shape when Core Animation copies it (presentation layer).
struct ShapedMetalLayerTests {
    @Test func copyKeepsTheShape() {
        let a = ShapedMetalLayer()
        a.pixelAspect = PixelAspect(4, 3)!
        #expect(ShapedMetalLayer(layer: a).pixelAspect == PixelAspect(4, 3)!)
        #expect(ShapedMetalLayer(layer: ShapedMetalLayer()).pixelAspect == .square)
        a.pixelAspect = .square
        #expect(ShapedMetalLayer(layer: a).pixelAspect == .square)
    }
}
#endif
