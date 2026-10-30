#if canImport(Metal)
import Metal
import Testing
@testable import SQRender

@Suite struct ViewGammaTests {
    @Test func exponentsFollowTheLayerDecode() {
        #expect(ViewGamma.mac.exponent == 1)
        #expect(abs(ViewGamma.web.exponent - 2.2 / 1.96) < 1e-6)
        #expect(abs(ViewGamma.broadcast.exponent - 2.4 / 1.96) < 1e-6)
        #expect(ViewGamma.allCases.allSatisfy { !$0.tooltip.isEmpty && !$0.title.isEmpty })
    }

    /// The code value after the preview is the original code value raised to gamma/1.96; Mac is the plain BT.709 code.
    @Test func presenterAppliesTheChosenGamma() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        func shownCode(_ gamma: ViewGamma) throws -> Double {
            let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 2, height: 2, mipmapped: false)
            let src = try #require(device.makeTexture(descriptor: sd))
            let px = [Float16](repeating: 0.18, count: 16).enumerated().map { $0.offset % 4 == 3 ? Float16(1) : Float16(0.18) }
            px.withUnsafeBytes { src.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
            let dst = try #require(device.makeTexture(descriptor: td))
            let cb = try #require(queue.makeCommandBuffer())
            let presenter = Presenter(device: device)
            presenter.viewGammaOverride = gamma
            presenter.encode(src, zoom: .fit, target: dst, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            var out = [UInt8](repeating: 0, count: 16)
            dst.getBytes(&out, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
            return Double(out[2]) / 255
        }
        let mac = try shownCode(.mac), web = try shownCode(.web), broadcast = try shownCode(.broadcast)
        let oetf = 1.09929682680944 * pow(0.18, 0.45) - 0.09929682680944
        #expect(abs(mac - oetf) < 0.01)
        #expect(abs(web - pow(oetf, Double(ViewGamma.web.exponent))) < 0.01)
        #expect(abs(broadcast - pow(oetf, Double(ViewGamma.broadcast.exponent))) < 0.01)
        #expect(mac > web && web > broadcast)
    }
}
#endif
