#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Plane texture memo (PLAYBACK-PERF "Playback: render-thread tick CPU"): a pixel buffer drawn again, or warmed ahead off the render
// thread, is not wrapped in a new Metal texture by the draw. Same pixels as a fresh compositor.

private func attrs() -> CFDictionary {
    [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as [CFString: Any] as CFDictionary
}

private func make420(_ w: Int, _ h: Int, luma: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs(), &pb) == kCVReturnSuccess)
    fill(pb!, luma: luma)
    return pb!
}

private func fill(_ b: CVPixelBuffer, luma: UInt8) {
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b)
    let yp = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self), ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    for y in 0..<h { for x in 0..<w { yp[y * ys + x] = luma } }
    let cp = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self), cs = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
    for y in 0..<(h / 2) { for x in 0..<w { cp[y * cs + x] = 128 } }
}

private func makeBGRA(_ w: Int, _ h: Int, _ v: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs(), &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        px[0] = v; px[1] = v; px[2] = v; px[3] = 255
    } }
    return b
}

private let (w, h) = (32, 16)
private func fmt() -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)) }
private func hint() -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func frame(_ pb: CVPixelBuffer, _ temporal: TemporalFrames? = nil) -> RenderNode {
    var l = RenderLayer(content: .frame(pb, colorHint: hint()))
    l.temporal = temporal
    return .layer(l)
}

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    c.remembersPlaneTextures = true
    return (d, q, c)
}

/// The composite's rgba16Float bytes.
private func render(_ comp: Compositor, _ dev: MTLDevice, _ q: MTLCommandQueue, _ nodes: [RenderNode]) throws -> [Float16] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: nodes, format: fmt(), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    var px = [Float16](repeating: 0, count: w * h * 4)
    t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return px
}

@Suite struct PlaneTextureMemoTests {
    @Test func aBufferDrawnAgainIsNotWrappedAgain() throws {
        guard let (dev, q, comp) = setup() else { return }
        let pb = make420(w, h, luma: 120)
        let first = try render(comp, dev, q, [frame(pb)])
        let made = comp.planeTextureCreates
        #expect(made == 2)                                  // luma + chroma
        let again = try render(comp, dev, q, [frame(pb)])
        #expect(comp.planeTextureCreates == made)
        #expect(again == first)
    }

    @Test func aRememberedTextureShowsWhatTheBufferHoldsNow() throws {
        // The texture is a view of the buffer's IOSurface: a buffer written in place draws its new content.
        guard let (dev, q, comp) = setup(), let (_, _, fresh) = setup() else { return }
        let pb = make420(w, h, luma: 60)
        _ = try render(comp, dev, q, [frame(pb)])
        fill(pb, luma: 200)
        let memo = try render(comp, dev, q, [frame(pb)])
        #expect(comp.planeTextureCreates == 2)
        #expect(memo == (try render(fresh, dev, q, [frame(pb)])))
    }

    @Test func warmedBuffersAreDrawnWithoutWrappingOnTheRenderThread() throws {
        guard let (dev, q, comp) = setup(), let (_, _, fresh) = setup() else { return }
        let a = make420(w, h, luma: 90), b = makeBGRA(w, h, 170)
        comp.warmPlaneTextures([a, b])
        #expect(comp.warmedPlaneTextures == 3)
        comp.warmPlaneTextures([a])                       // already made: nothing new
        #expect(comp.warmedPlaneTextures == 3)
        var top = RenderLayer(content: .frame(b, colorHint: hint()))
        top.transform.opacity = 0.5
        let nodes: [RenderNode] = [frame(a), .layer(top)]
        let warmed = try render(comp, dev, q, nodes)
        #expect(comp.planeTextureCreates == 0)
        #expect(warmed == (try render(fresh, dev, q, nodes)))
    }

    @Test func buffersNotDrawnForTwoRendersAreLetGo() throws {
        guard let (dev, q, comp) = setup() else { return }
        let a = make420(w, h, luma: 90), b = make420(w, h, luma: 30)
        _ = try render(comp, dev, q, [frame(a)])
        #expect(comp.remembersPlanes(of: a))
        _ = try render(comp, dev, q, [frame(b)])
        _ = try render(comp, dev, q, [frame(b)])
        #expect(comp.remembersPlanes(of: a))                // drawn two renders ago
        _ = try render(comp, dev, q, [frame(b)])
        #expect(!comp.remembersPlanes(of: a))
        #expect(comp.remembersPlanes(of: b))
        // A warmed buffer that is never drawn goes the same way.
        let c = make420(w, h, luma: 10)
        comp.warmPlaneTextures([c])
        for _ in 0..<3 { _ = try render(comp, dev, q, [frame(b)]) }
        #expect(!comp.remembersPlanes(of: c))
    }

    @Test func offByDefaultNothingIsKept() throws {
        guard let (dev, q, _) = setup() else { return }
        let comp = try Compositor(device: dev)              // export's compositor: buffers are not held
        let pb = make420(w, h, luma: 120)
        _ = try render(comp, dev, q, [frame(pb)])
        comp.warmPlaneTextures([make420(w, h, luma: 1)])
        _ = try render(comp, dev, q, [frame(pb)])
        #expect(comp.rememberedPlaneCount == 0)
        #expect(comp.planeTextureCreates == 4 && comp.warmedPlaneTextures == 0)
    }

    @Test func trimmingThePoolForgetsEveryBuffer() throws {
        guard let (dev, q, comp) = setup() else { return }
        let a = make420(w, h, luma: 90)
        _ = try render(comp, dev, q, [frame(a)])
        comp.warmPlaneTextures([make420(w, h, luma: 1)])
        comp.trimIntermediatePool(toBytes: 0)
        #expect(comp.rememberedPlaneCount == 0)
    }

    @Test func aWarmRunningDuringATrimDoesNotFillTheMemoAgain() throws {
        // Critical memory pressure trims while a warm is making textures: what the warm made is not remembered.
        guard let (dev, q, comp) = setup() else { return }
        let a = make420(w, h, luma: 90), b = make420(w, h, luma: 40)
        let before = comp.planeTrimEpochForTests
        let trimmer = Thread { comp.trimIntermediatePool(toBytes: 0) }   // waits for the warm's lock after the bump
        comp.warmMadeHook = {
            guard comp.planeTrimEpochForTests == before else { return }
            trimmer.start()
            while comp.planeTrimEpochForTests == before { usleep(100) }
        }
        comp.warmPlaneTextures([a, b])
        comp.warmMadeHook = nil
        while !trimmer.isFinished { usleep(100) }
        #expect(comp.rememberedPlaneCount == 0)
        #expect(comp.warmedPlaneTextures == 0)
        // Afterwards everything works as before.
        let px = try render(comp, dev, q, [frame(a)])
        #expect(comp.planeTextureCreates == 2 && comp.remembersPlanes(of: a))
        #expect(px == (try render(comp, dev, q, [frame(a)])))
    }

    @Test func trailsWrapOnlyTheNewFrameOfTheirSlidingWindow() throws {
        guard let (dev, q, comp) = setup(), let (_, _, fresh) = setup() else { return }
        let frames = (0..<6).map { makeBGRA(w, h, UInt8(20 + 30 * $0)) }
        let filter = TemporalFilter(trails: .init(count: 3, spacing: 1, decay: 0.5, blend: .add))
        func node(_ k: Int) -> RenderNode {
            frame(frames[k], TemporalFrames(filter: filter, before: (1...3).map { frames[k - $0] }))
        }
        _ = try render(comp, dev, q, [node(3)])
        let made = comp.planeTextureCreates
        #expect(made == 4)
        let next = try render(comp, dev, q, [node(4)])
        #expect(comp.planeTextureCreates == made + 1)
        #expect(next == (try render(fresh, dev, q, [node(4)])))
    }
}
#endif
