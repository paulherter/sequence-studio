import Metal
import simd
import Testing
@testable import SQMonitorUI

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

    @Test func clickPositionFollowsMonitorZoomAndPan() {
        let seq = CGSize(width: 1920, height: 1080)
        let fit = MonitorViewMapping(viewSize: CGSize(width: 960, height: 540), backingScale: 2, sequenceSize: seq, zoom: .fit)
        let c = ColorPickHub.position(forClick: CGPoint(x: 480, y: 270), mapping: fit)
        #expect(abs(c.x - 0.5) < 1e-6 && abs(c.y - 0.5) < 1e-6, "center of a fitted picture")
        // 200 % zoom centered on the sequence center: the picture is 2x the view size and its center sits at the view center.
        let zoomed = MonitorViewMapping(viewSize: CGSize(width: 800, height: 450), backingScale: 2, sequenceSize: seq, zoom: .view(scale: 1, centerX: 0, centerY: 0))
        let r = zoomed.canvasRect
        #expect(r.width > 800, "zoomed picture is larger than the view")
        let mid = ColorPickHub.position(forClick: CGPoint(x: 400, y: 225), mapping: zoomed)
        #expect(abs(mid.x - 0.5) < 1e-6 && abs(mid.y - 0.5) < 1e-6)
        // Panned to the picture's right edge: the view center now shows a point far right of the picture center.
        let panned = MonitorViewMapping(viewSize: CGSize(width: 800, height: 450), backingScale: 2, sequenceSize: seq, zoom: .view(scale: 1, centerX: 800, centerY: 0))
        let edge = ColorPickHub.position(forClick: CGPoint(x: 400, y: 225), mapping: panned)
        #expect(edge.x > 0.8 && edge.x < 1 && abs(edge.y - 0.5) < 1e-6, "got \(edge)")
        // A click on the letterbox of a fitted picture lies outside 0...1 (the pick is canceled).
        let outside = ColorPickHub.position(forClick: CGPoint(x: 5, y: 5), mapping: MonitorViewMapping(viewSize: CGSize(width: 960, height: 900), backingScale: 2, sequenceSize: seq, zoom: .fit))
        #expect(outside.y < 0 || outside.y > 1)
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
