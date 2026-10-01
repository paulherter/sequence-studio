import CoreGraphics
import Metal
import Testing
@testable import SSRender

@Suite struct PresenterTests {
    private func rect(_ t: (Double, Double), _ d: (Double, Double), _ z: ViewerZoom) -> CGRect {
        Presenter.destinationRect(textureSize: CGSize(width: t.0, height: t.1), drawableSize: CGSize(width: d.0, height: d.1), zoom: z)
    }

    @Test func destinationRectTable() {
        #expect(rect((1920, 1080), (960, 720), .fit) == CGRect(x: 0, y: 90, width: 960, height: 540))      // letterbox
        #expect(rect((1920, 1080), (1920, 540), .fit) == CGRect(x: 480, y: 0, width: 960, height: 540))    // pillarbox
        #expect(rect((100, 50), (400, 400), .fit) == CGRect(x: 0, y: 100, width: 400, height: 200))        // upscale
        #expect(rect((400, 200), (1000, 800), .percent(100)) == CGRect(x: 300, y: 300, width: 400, height: 200))
        #expect(rect((400, 200), (1000, 800), .percent(200)) == CGRect(x: 100, y: 200, width: 800, height: 400))
        #expect(rect((1920, 1080), (800, 600), .percent(100)) == CGRect(x: -560, y: -240, width: 1920, height: 1080))
        // Free view: scale in drawable px per texture px, centre = texture offset shown at the drawable centre.
        #expect(rect((400, 200), (1000, 800), .view(scale: 1, centerX: 0, centerY: 0)) == CGRect(x: 300, y: 300, width: 400, height: 200))
        #expect(rect((400, 200), (1000, 800), .view(scale: 2, centerX: 100, centerY: -50)) == CGRect(x: -100, y: 300, width: 800, height: 400))
    }

    @Test func offscreenQuadrantsAndSurround() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return }
        // 4x4 source, quadrants of linear values; output 12x8 with fit -> 8x8 centred (x 2..10).
        let lin: [[Float]] = [[0.0, 0, 0], [1, 1, 1], [0.18, 0.18, 0.18], [0.5, 0.0, 0.0]]   // TL TR BL BR
        var px = [Float16](repeating: 1, count: 4 * 4 * 4)
        for y in 0..<4 { for x in 0..<4 {
            let q = (y / 2) * 2 + (x / 2), i = (y * 4 + x) * 4
            px[i] = Float16(lin[q][0]); px[i + 1] = Float16(lin[q][1]); px[i + 2] = Float16(lin[q][2])
        } }
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 4, height: 4, mipmapped: false)
        let src = try #require(device.makeTexture(descriptor: sd))
        px.withUnsafeBytes { src.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 32) }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 12, height: 8, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let dst = try #require(device.makeTexture(descriptor: td))
        let cb = try #require(queue.makeCommandBuffer())
        Presenter(device: device).encode(src, zoom: .fit, target: dst, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: 12 * 8 * 4)
        dst.getBytes(&out, bytesPerRow: 48, from: MTLRegionMake2D(0, 0, 12, 8), mipmapLevel: 0)
        func bgr(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * 12 + x) * 4; return (Int(out[i + 2]), Int(out[i + 1]), Int(out[i])) }
        func oetf(_ l: Double) -> Double { l < 0.018053968510807 ? 4.5 * l : 1.09929682680944 * pow(l, 0.45) - 0.09929682680944 }
        func expect(_ p: (Int, Int, Int), _ l: [Float]) {
            let e = l.map { Int((oetf(Double($0)) * 255).rounded()) }
            #expect(abs(p.0 - e[0]) <= 2 && abs(p.1 - e[1]) <= 2 && abs(p.2 - e[2]) <= 2, "got \(p) want \(e)")
        }
        expect(bgr(3, 1), lin[0]); expect(bgr(8, 1), lin[1]); expect(bgr(3, 6), lin[2]); expect(bgr(8, 6), lin[3])
        for (x, y) in [(0, 0), (1, 4), (11, 7), (10, 3)] {
            let p = bgr(x, y)
            #expect(p.0 == 12 && p.1 == 12 && p.2 == 12, "surround at \(x),\(y) = \(p)")
        }
    }
}
