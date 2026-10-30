#if canImport(Metal)
import Metal
import Testing
import simd
@testable import SQRender

@Suite struct DisplayViewTests {
    @Test func sdrIsTheBT709Path() {
        let v = SIMD3<Float>(0.18, 0.4, 0.05)
        let e = DisplayView.sdr.encode(v)
        #expect(abs(e.x - TransferFunctions.bt709OETF(SIMD3<Float>(repeating: 0.18)).x) < 1e-5)
        #expect(DisplayView.allCases.allSatisfy { !$0.title.isEmpty && !$0.tooltip.isEmpty })
    }

    @Test func p3KeepsGrayAndMovesSaturatedPrimaries() {
        let gray = DisplayView.displayP3.encode(SIMD3<Float>(repeating: 0.3))
        #expect(abs(gray.x - gray.y) < 1e-3 && abs(gray.y - gray.z) < 1e-3)
        // Rec.709 red is inside P3: its P3 red channel is below 1 and green/blue stay near 0 (small positive).
        let red = DisplayView.displayP3.encode(SIMD3<Float>(1, 0, 0))
        #expect(red.x < 1 && red.x > 0.9 && red.y > 0.1)
    }

    @Test func hdrKeepsSceneValuesAndRollsOffOnlyInTheHDRView() {
        let scene = SIMD3<Float>(4, 2, 1)
        let raw = DisplayView.unToneMapped.encode(scene)
        #expect(raw.x > 3.5)                                   // above SDR white, unchanged by a curve
        let low = DisplayView.hdr1000.encode(SIMD3<Float>(repeating: 0.5))
        #expect(abs(low.x - 0.5) < 1e-4)                       // below the knee (8x white) nothing changes
        let big = DisplayView.hdr1000.encode(SIMD3<Float>(repeating: 40))
        #expect(big.x <= DisplayView.hdrPeak + 1e-3 && big.x > 9)
        let hue = DisplayView.hdr1000.encode(SIMD3<Float>(40, 20, 10))
        let rawHue = DisplayView.unToneMapped.encode(SIMD3<Float>(40, 20, 10))
        #expect(abs(hue.x / hue.y - rawHue.x / rawHue.y) < 1e-3)   // hue (channel ratios) preserved
    }

    /// The shader matches the CPU reference for every view.
    @Test func presenterMatchesTheReference() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        let scene = SIMD3<Float>(0.6, 0.3, 0.1)
        for view in DisplayView.allCases {
            let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2, height: 2, mipmapped: false)
            let src = try #require(device.makeTexture(descriptor: sd))
            let px: [Float16] = (0..<4).flatMap { _ in [Float16(scene.x), Float16(scene.y), Float16(scene.z), Float16(1)] }
            px.withUnsafeBytes { src.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.pixelFormat, width: 2, height: 2, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
            let dst = try #require(device.makeTexture(descriptor: td))
            let cb = try #require(queue.makeCommandBuffer())
            let presenter = Presenter(device: device)
            presenter.displayViewOverride = view
            presenter.viewGammaOverride = .mac
            presenter.encode(src, zoom: .fit, target: dst, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            let want = view.encode(scene)
            let got: SIMD3<Float>
            if view.isExtendedRange {
                var out = [Float16](repeating: 0, count: 16)
                dst.getBytes(&out, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
                got = SIMD3(Float(out[0]), Float(out[1]), Float(out[2]))
            } else {
                var out = [UInt8](repeating: 0, count: 16)
                dst.getBytes(&out, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
                got = SIMD3(Float(out[2]), Float(out[1]), Float(out[0])) / 255     // BGRA
            }
            #expect(simd_length(got - want) < 0.02, "\(view)")
        }
    }
}
#endif
