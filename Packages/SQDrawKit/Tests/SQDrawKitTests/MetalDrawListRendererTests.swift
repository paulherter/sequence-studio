#if canImport(Metal)
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import SQDrawKit

/// The Mac GPU backend (the shared DrawQuads.slang shader as MSL) against the reference rasterizer: shapes, strokes,
/// segments, triangles, glyphs, image slots and clips give the reference picture; the picture punch leaves the quad
/// transparent under what is drawn after it.
@Suite struct MetalDrawListRendererTests {
    static func diff(_ a: RGBAImage, _ b: RGBAImage) -> (mean: Double, over: Double) {
        var sum = 0, over = 0, n = 0
        for i in 0..<a.pixels.count where i % 4 != 3 {
            let d = abs(Int(a.pixels[i]) - Int(b.pixels[i]))
            sum += d; n += 1
            if d > 8 { over += 1 }
        }
        return (Double(sum) / Double(n), Double(over) / Double(n))
    }

    @Test func everyQuadKindMatchesTheReference() throws {
        guard let metal = MetalDrawListRenderer() else { return }       // no Metal device (CI VM)
        let atlas = try #require(GlyphAtlas())
        var c = Canvas(width: 320, height: 160, atlas: atlas, scale: 2)
        c.fill(CGRect(x: 4, y: 4, width: 50, height: 24), DrawColor(hex: 0x3D7EFF))
        c.fill(roundedRect: CGRect(x: 60, y: 4, width: 50, height: 24), radius: 8, DrawColor(hex: 0xE5484D).alpha(0.6))
        c.stroke(roundedRect: CGRect(x: 4, y: 34, width: 50, height: 30), radius: 6, width: 2, .white)
        c.strokeLine(from: CGPoint(x: 70, y: 36), to: CGPoint(x: 150, y: 70), width: 3, DrawColor(hex: 0x30A46C))
        c.list.triangle(DrawRect(x: 240, y: 10, w: 20, h: 30), .white)
        c.list.triangle(DrawRect(x: 270, y: 10, w: 20, h: 30), .white, pointingLeft: true)
        c.draw("Sequence Studio", at: CGPoint(x: 4, y: 40), fontSize: 12, .white)
        c.list.pushClip(DrawRect(x: 200, y: 100, w: 30, h: 30))
        c.list.fill(DrawRect(x: 180, y: 90, w: 80, h: 60), DrawColor(hex: 0xFFB224))
        c.list.popClip()
        var img = RGBAImage(width: 4, height: 4, fill: .white)
        for i in 0..<16 { img.pixels[i * 4] = UInt8(i * 16); img.pixels[i * 4 + 3] = i % 2 == 0 ? 255 : 128 }
        c.list.image(DrawRect(x: 250, y: 100, w: 60, h: 50), slot: 5, tint: DrawColor(1, 1, 1, 0.9))
        metal.setAtlas(atlas)
        metal.setImage(slot: 5, img, generation: 1)
        let clear = DrawColor(hex: 0x1E1E1E)
        let (gpu, _) = try #require(metal.render(c.list, width: 320, height: 160, clear: clear))
        let sw = SoftwareRenderer.render(c.list, width: 320, height: 160, clear: clear, atlas: atlas, images: [5: img])
        let d = Self.diff(gpu, sw)
        #expect(d.mean < 0.5)
        #expect(d.over < 0.002)
        // Inside the clip the fill shows, outside it the background stays.
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(gpu.pixels[((y * 320 + x) * 4)..<((y * 320 + x) * 4 + 3)]) }
        #expect(px(210, 110) == [0xFF, 0xB2, 0x24])
        #expect(px(195, 128) == [0x1E, 0x1E, 0x1E])
    }

    /// A frame shown reduced (a window on a display with a smaller scale): the shader's `viewScale` scales the quads and
    /// supersamples shapes, strokes and glyphs, so the result matches the full-size picture averaged down 2 x 2, with the
    /// text still readable (not the nearest-pixel alias a plain scale gives).
    @Test func aReducedViewMatchesTheFullSizePictureAveragedDown() throws {
        guard let metal = MetalDrawListRenderer() else { return }
        let atlas = try #require(GlyphAtlas())
        var c = Canvas(width: 320, height: 160, atlas: atlas, scale: 2)
        c.fill(roundedRect: CGRect(x: 4, y: 4, width: 50, height: 24), radius: 8, DrawColor(hex: 0xE5484D))
        c.stroke(roundedRect: CGRect(x: 4, y: 34, width: 50, height: 30), radius: 6, width: 2, .white)
        c.strokeLine(from: CGPoint(x: 70, y: 36), to: CGPoint(x: 150, y: 70), width: 3, DrawColor(hex: 0x30A46C))
        c.draw("Sequence Studio", at: CGPoint(x: 4, y: 40), fontSize: 12, .white)
        metal.setAtlas(atlas)
        let clear = DrawColor(hex: 0x1E1E1E)
        let (full, _) = try #require(metal.render(c.list, width: 320, height: 160, clear: clear))
        let (half, _) = try #require(metal.render(c.list, width: 160, height: 80, clear: clear, viewScale: 0.5))
        var down = RGBAImage(width: 160, height: 80, fill: .black)
        for y in 0..<80 { for x in 0..<160 { for ch in 0..<4 {
            var s = 0
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] { s += Int(full.pixels[(((y * 2 + dy) * 320) + x * 2 + dx) * 4 + ch]) }
            down.pixels[(y * 160 + x) * 4 + ch] = UInt8(s / 4)
        } } }
        let d = Self.diff(half, down)
        #expect(d.mean < 2.5)
        #expect(d.over < 0.03)
        // Unchanged for viewScale 1 (the default every other caller uses).
        let (again, _) = try #require(metal.render(c.list, width: 320, height: 160, clear: clear, viewScale: 1))
        #expect(again.pixels == full.pixels)
    }

    /// A picture quad is cleared to transparent (the picture layer under the view shows), a menu drawn after it covers
    /// it opaquely, and a translucent overlay over the hole keeps premultiplied color (alpha = its own alpha).
    @Test func thePictureQuadIsPunchedAndLaterQuadsStayOnTop() throws {
        guard let metal = MetalDrawListRenderer() else { return }
        var list = DrawList(width: 64, height: 32)
        list.fill(DrawRect(x: 0, y: 0, w: 64, h: 32), DrawColor(hex: 0x333333))
        list.video(DrawRect(x: 8, y: 4, w: 40, h: 24))
        list.fill(DrawRect(x: 40, y: 0, w: 20, h: 12), DrawColor(hex: 0xFF0000))
        list.fill(DrawRect(x: 10, y: 20, w: 8, h: 6), DrawColor(1, 1, 1, 0.5))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 32, mipmapped: false)
        d.usage = [.renderTarget]; d.storageMode = .managed
        let target = try #require(metal.device.makeTexture(descriptor: d))
        let cb = try #require(metal.encode(list, into: target, clear: .black, punchesVideo: true))
        if let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: target); blit.endEncoding() }
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: 64 * 32 * 4)
        px.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0) }
        func at(_ x: Int, _ y: Int) -> [UInt8] { Array(px[((y * 64 + x) * 4)..<((y * 64 + x) * 4 + 4)]) }   // BGRA
        #expect(at(20, 10) == [0, 0, 0, 0])                 // the hole
        #expect(at(44, 6) == [0, 0, 255, 255])              // the red quad after the picture covers it
        #expect(at(2, 2) == [0x33, 0x33, 0x33, 255])        // outside the picture
        let o = at(12, 22)                                  // white at half alpha over the hole: premultiplied
        #expect(abs(Int(o[3]) - 128) <= 1 && abs(Int(o[0]) - 128) <= 1)
    }
}
#endif
