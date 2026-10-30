#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// W7.1: a layer whose request carries motion-blur samples becomes a summed pair of copies, one per sub-frame transform.

private func format(_ w: Int, _ h: Int) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)) }

private func redBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        p[0] = 0; p[1] = 0; p[2] = 255; p[3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

private func hint() -> VideoTrackInfo {
    VideoTrackInfo(width: 64, height: 64, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func request(_ transforms: [ClipTransform], blend: BlendMode = .normal) -> LayerRequest {
    var r = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero, transform: transforms[transforms.count / 2],
                         blendMode: blend)
    r.motionBlur = MotionBlurSamples(format: format(64, 64), transforms: transforms)
    return r
}

@Test func treeTurnsMotionBlurIntoASummedPairOfCopies() {
    let ts = [-4.0, 0, 4].map { ClipTransform(position: Vec2($0, 0), scale: Vec2(0.25, 0.25), opacity: 0.9) }
    let r = request(ts)
    let layer = RenderLayer(content: .placeholder(.offline), transform: r.transform)
    let tree = RenderNode.tree(requests: [r], layers: [layer])
    #expect(tree.count == 1)
    guard case .pair(let f, let first, let second) = tree[0] else { Issue.record("expected a pair"); return }
    #expect(f.width == 64 && first.count == 1 && second.count == 2)
    var xs: [Double] = []
    for n in first + second {
        guard case .layer(let l) = n else { Issue.record("expected layers"); return }
        #expect(abs(l.transform.opacity - 0.3) < 1e-12)
        xs.append(l.transform.position.x)
    }
    #expect(xs == [-4, 0, 4])
}

@Test func motionBlurKeepsTheBlendModeAndTheCallersOffset() {
    let ts = [0.0, 10].map { ClipTransform(position: Vec2($0, 0)) }
    let r = request(ts, blend: .screen)
    var layer = RenderLayer(content: .placeholder(.offline), transform: r.transform, blendMode: .screen)
    layer.transform.position = r.transform.position + Vec2(3, 7)        // e.g. a text box offset added by the caller
    let tree = RenderNode.tree(requests: [r], layers: [layer])
    guard case .blended(.pair(_, let first, let second), let mode) = tree[0] else { Issue.record("expected a blended pair"); return }
    #expect(mode == .screen)
    guard case .layer(let a) = first[0], case .layer(let b) = second[0] else { Issue.record("expected layers"); return }
    #expect(a.transform.position == Vec2(3, 7) && b.transform.position == Vec2(13, 7))
    #expect(a.blendMode == .normal && b.blendMode == .normal)
}

@Test func motionBlurredLayerAveragesItsCopiesOnTheGPU() throws {
    guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue(), let comp = try? Compositor(device: dev) else { return }
    let f = format(64, 64)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 64, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let target = dev.makeTexture(descriptor: d)!
    // A 16 x 16 red square seen at x - 4 and x + 4: covered by both copies in the middle, by one copy at the sides.
    let ts = [-4.0, 4].map { ClipTransform(position: Vec2($0, 0), scale: Vec2(0.25, 0.25)) }
    let r = request(ts)
    let layer = RenderLayer(content: .frame(redBuffer(64, 64), colorHint: hint()), transform: r.transform)
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: RenderNode.tree(requests: [r], layers: [layer]), format: f, into: target, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    func red(_ x: Int) -> Double {
        var px = [Float16](repeating: 0, count: 4)
        target.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, 32, 1, 1), mipmapLevel: 0)
        return Double(px[0])
    }
    #expect(abs(red(32) - 1) < 0.01, "both copies")
    #expect(abs(red(22) - 0.5) < 0.01, "left copy only")
    #expect(abs(red(41) - 0.5) < 0.01, "right copy only")
    #expect(red(10) < 0.01, "outside")
}

@Test func aStencilLayerSkipsMotionBlur() {
    let ts = [-4.0, 0, 4].map { ClipTransform(position: Vec2($0, 0), scale: Vec2(0.25, 0.25), opacity: 0.9) }
    let r = request(ts)
    var layer = RenderLayer(content: .placeholder(.offline), transform: r.transform)
    layer.footageFill = .stencil
    let tree = RenderNode.tree(requests: [r], layers: [layer])
    #expect(tree.count == 1)
    guard case .layer(let l) = tree[0] else { Issue.record("expected one plain layer"); return }
    #expect(l.footageFill == .stencil)
}
#endif
