import Metal
import simd
import Testing
@testable import SSEditorUI

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
        let l = try #require(FrameSampler.meanColor(of: t, at: SIMD2(0.25, 0.5)))
        #expect(abs(l.x - 0.5) < 1e-3 && abs(l.y - 0.25) < 1e-3 && abs(l.z - 0.125) < 1e-3)
        let r = try #require(FrameSampler.meanColor(of: t, at: SIMD2(0.9, 0.5)))
        #expect(abs(r.x - 1) < 1e-3)
        // Edges clamp instead of reading outside the texture.
        #expect(FrameSampler.meanColor(of: t, at: SIMD2(0, 0)) != nil && FrameSampler.meanColor(of: t, at: SIMD2(1, 1)) != nil)
    }

    @Test func thumbnailKeepsAspectAndTone() throws {
        let t = try texture()
        let img = try #require(FrameSampler.thumbnail(of: t, width: 32))
        #expect(img.width == 32 && img.height == 16)
    }

    @Test func lumaSamplesAreDisplayEncodedAndCoverTheFrame() throws {
        let t = try texture()
        let l = try #require(FrameSampler.lumaSamples(of: t, width: 32))
        #expect(l.count == 32 * 16 && l.allSatisfy { $0.isFinite })
        #expect(l.max()! > 0.95 && l.min()! < 0.6, "right half white, left half darker")
    }

    @Test func halfConversionMatchesFloat16() {
        for v: Float16 in [0, 1, -2, 0.333, 65504, 6e-8] {
            #expect(abs(FrameSampler.halfToFloat(v.bitPattern) - Float(v)) <= abs(Float(v)) * 1e-6)
        }
    }

    @Test func pickHubCompletesOnceAndCancelsOutside() {
        let hub = ColorPickHub()
        var got: [SIMD2<Double>?] = []
        hub.begin { got.append($0) }
        #expect(hub.isPicking)
        hub.complete(at: SIMD2(0.3, 0.6))
        hub.complete(at: SIMD2(0.5, 0.5))   // no pick pending: ignored
        #expect(got == [SIMD2(0.3, 0.6)] && !hub.isPicking)
        hub.begin { got.append($0) }
        hub.complete(at: SIMD2(1.4, 0.5))
        #expect(got.count == 2 && got[1] == nil)
        hub.begin { got.append($0) }
        hub.begin { got.append($0) }   // a new pick cancels the old one
        #expect(got.count == 3 && got[2] == nil)
        hub.cancel()
    }
}
