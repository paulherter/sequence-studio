#if os(macOS)
import Metal
import simd
import Testing
@testable import SQEditorSession

@MainActor @Suite struct FrameSamplerTests {
    /// 64x32 rgba16Float: left half (0.5, 0.25, 0.125), right half (1, 1, 1), as half-float bits.
    func texture() throws -> MTLTexture {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 32, mipmapped: false)
        d.usage = [.shaderRead]
        let t = try #require(device.makeTexture(descriptor: d))
        let left: [Float16] = [0.5, 0.25, 0.125, 1], right: [Float16] = [1, 1, 1, 1]
        var px: [Float16] = []
        for _ in 0..<32 { for x in 0..<64 { px += x < 32 ? left : right } }
        t.replace(region: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0, withBytes: px, bytesPerRow: 64 * 8)
        return t
    }

    @Test func meanColorReadsThePatchUnderThePosition() throws {
        let t = try texture()
        let l = try #require(FrameSampler.meanColorNow(of: t, at: SIMD2(0.25, 0.5)))
        #expect(abs(l.x - 0.5) < 1e-3 && abs(l.y - 0.25) < 1e-3 && abs(l.z - 0.125) < 1e-3)
        let r = try #require(FrameSampler.meanColorNow(of: t, at: SIMD2(0.9, 0.5)))
        #expect(abs(r.x - 1) < 1e-3)
        // Edges clamp instead of reading outside the texture.
        #expect(FrameSampler.meanColorNow(of: t, at: SIMD2(0, 0)) != nil && FrameSampler.meanColorNow(of: t, at: SIMD2(1, 1)) != nil)
    }

    @Test func scaledReadbackKeepsAspectAndImageAndLumaAreDisplayEncoded() throws {
        let t = try texture()
        let (w, h, lin) = try #require(FrameSampler.scaledNow(of: t, width: 32))
        #expect(w == 32 && h == 16 && lin.count == 32 * 16)
        let img = try #require(FrameSampler.image(width: w, height: h, linear: lin))
        #expect(img.width == 32 && img.height == 16)
        let l = FrameSampler.displayLuma(lin)
        #expect(l.allSatisfy { $0.isFinite } && l.max()! > 0.95 && l.min()! < 0.6, "right half white, left half darker")
    }

    @Test func patchRectangleClampsToTheTexture() {
        #expect(FrameSampler.patch(width: 64, height: 32, at: SIMD2(0, 0), radius: 2)! == (0, 0, 3, 3))
        #expect(FrameSampler.patch(width: 64, height: 32, at: SIMD2(1, 1), radius: 2)! == (61, 29, 3, 3))
        #expect(FrameSampler.patch(width: 64, height: 32, at: SIMD2(0.5, 0.5), radius: 2)! == (30, 14, 5, 5))
        #expect(FrameSampler.patch(width: 64, height: 32, at: SIMD2(.nan, 0.5), radius: 2) == nil)
    }

    @Test func halfConversionMatchesFloat16() {
        for v: Float16 in [0, 1, -2, 0.333, 65504, 6e-8] {
            #expect(abs(FrameSampler.halfToFloat(v.bitPattern) - Float(v)) <= abs(Float(v)) * 1e-6)
        }
    }

    @Test func magnifierGridReadsTheCenterAndCutsAtTheEdge() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 16, height: 8, mipmapped: false)
        let t = try #require(device.makeTexture(descriptor: d))
        var px: [Float16] = []
        for _ in 0..<8 { for x in 0..<16 { px += x == 5 ? [1, 0, 0, 1] : [0.5, 0.5, 0.5, 1] } }
        t.replace(region: MTLRegionMake2D(0, 0, 16, 8), mipmapLevel: 0, withBytes: px, bytesPerRow: 16 * 8)
        // Pointer on the red column: 5 x 5 patch, center cell red.
        let g = try #require(FrameSampler.gridNow(of: t, at: SIMD2((5.5) / 16, 0.5), radius: 2))
        #expect(g.width == 5 && g.height == 5 && g.centerX == 2 && g.centerY == 2)
        #expect(g.center.x == 1 && g.center.y == 0)
        #expect(g.readout == "R 255  G 0  B 0")
        // Corner: the patch is cut and the center cell is the corner pixel.
        let c = try #require(FrameSampler.gridNow(of: t, at: SIMD2(0, 0), radius: 2))
        #expect(c.width == 3 && c.height == 3 && c.centerX == 0 && c.centerY == 0)
    }

    // NaN pixels trapped in the 8-bit conversion.
    @Test func nanPixelsConvertToZero() {
        #expect(FrameSampler.display8(SIMD3<Float>(.nan, 0, 1)).x == 0)
        #expect(FrameSampler.byte(.nan) == 0)
        #expect(FrameSampler.byte(2) == 255)
    }
}
#endif
