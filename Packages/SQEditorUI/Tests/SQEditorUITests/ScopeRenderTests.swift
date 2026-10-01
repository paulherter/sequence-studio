import Metal
import Testing
import SQRender
@testable import SQEditorUI

@Suite struct ScopeRenderTests {
    private func solid(_ device: MTLDevice, rgb: SIMD3<Float>) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 512, height: 8, mipmapped: false)
        d.usage = .shaderRead
        let t = device.makeTexture(descriptor: d)!
        var px = [Float16](repeating: 1, count: 512 * 8 * 4)
        for i in 0..<(512 * 8) {
            px[i * 4] = Float16(rgb.x); px[i * 4 + 1] = Float16(rgb.y); px[i * 4 + 2] = Float16(rgb.z)
        }
        t.replace(region: MTLRegionMake2D(0, 0, 512, 8), mipmapLevel: 0, withBytes: px, bytesPerRow: 512 * 8)
        return t
    }

    /// Renders `kind` for a solid frame into a 128x128 target and returns a pixel reader (b, g, r, a).
    private func render(_ kind: ScopeKind, rgb: SIMD3<Float>) throws -> (Int, Int) -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let gpu = try ScopesGPU(device: device)
        let renderer = try ScopeRenderer(device: device)
        let res = try #require(gpu.makeResources())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ScopeRenderer.colorFormat, width: 128, height: 128, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try #require(device.makeTexture(descriptor: d))
        let cb = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        gpu.encode(source: solid(device, rgb: rgb), into: res, commandBuffer: cb)
        renderer.encode(kind: kind, resources: res, target: target, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: 128 * 128 * 4)
        target.getBytes(&bytes, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0)
        return { x, y in Array(bytes[(y * 128 + x) * 4 ..< (y * 128 + x) * 4 + 4]) }
    }

    @Test func whiteWaveformIsALineAtTop() throws {
        let px = try render(.waveform, rgb: SIMD3(repeating: 1))
        let top = px(64, 0), bottom = px(64, 127)
        #expect(top[1] > 150)                 // green channel lit at 100 IRE
        #expect(bottom[1] == 12 && bottom[2] == 12)   // background
    }

    @Test func greyVectorscopeIsADotInTheCentre() throws {
        let px = try render(.vectorscope, rgb: SIMD3(repeating: 0.18))
        let centre = px(64, 64), corner = px(4, 4)
        #expect(centre[1] > 150)
        #expect(corner[1] == 12)
    }

    @Test func redParadeLightsOnlyTheRedPanel() throws {
        let px = try render(.parade, rgb: SIMD3(1, 0, 0))
        let redTop = px(20, 0), greenTop = px(64, 0), greenBottom = px(64, 127)
        #expect(redTop[2] > 150 && redTop[0] < 100)       // R' = 1 -> top of the red panel, tinted red (bgra)
        #expect(greenTop[1] == 12)                         // G' = 0 -> top of green panel dark
        #expect(greenBottom[1] > 100)                      // G' = 0 -> bottom of green panel lit
    }

    @Test func histogramShowsSpikeAtRightForWhite() throws {
        let px = try render(.histogram, rgb: SIMD3(repeating: 1))
        #expect(px(127, 100)[1] > 100)       // white spike at the last bins, filled from the bottom
        #expect(px(10, 100)[1] == 12)
    }
}
