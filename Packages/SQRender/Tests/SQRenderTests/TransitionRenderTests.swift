#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// Motion transitions (push, slide, wipe, zoom): the compositor's transition node. Edges must be subpixel (no stepping).

private func bgra(_ w: Int, _ h: Int, _ c: (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h { for x in 0..<w {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        p[0] = c.0; p[1] = c.1; p[2] = c.2; p[3] = c.3
    } }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}

private let W = 64, H = 16
private let fmt = SequenceFormat(width: W, height: H, frameDuration: Time(1, 30))
private let info = VideoTrackInfo(width: W, height: H, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                                  nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, matrix: nil)
private func full(_ c: (UInt8, UInt8, UInt8, UInt8)) -> RenderNode { .layer(RenderLayer(content: .frame(bgra(W, H, c), colorHint: info))) }
private let red = full((0, 0, 255, 255)), green = full((0, 255, 0, 255)), blue = full((255, 0, 0, 255))

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

private func draw(_ nodes: [RenderNode], format: SequenceFormat = fmt) throws -> MTLTexture? {
    guard let (dev, q, comp) = setup() else { return nil }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: format.width, height: format.height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: nodes, format: format, into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    return t
}

private func pixel(_ t: MTLTexture, _ x: Int, _ y: Int = H / 2) -> [Double] {
    var px = [Float16](repeating: 0, count: 4)
    t.getBytes(&px, bytesPerRow: 8, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return px.map { Double($0) }
}

private func near(_ a: [Double], _ e: [Double], _ tol: Double = 0.01, _ note: String = "") {
    for i in 0..<3 { #expect(abs(a[i] - e[i]) <= tol, "\(note) ch\(i): got \(a[i]) want \(e[i])") }
}

/// Push left with the seam at `seam` px from the left edge.
private func push(seam: Double, blur: Double = 0) -> TransitionRender {
    let o = 1 - seam / Double(W)
    return TransitionRender(outgoing: TransitionSide(offset: Vec2(-o, 0), blur: Vec2(-blur, 0)),
                            incoming: TransitionSide(offset: Vec2(1 - o, 0), blur: Vec2(-blur, 0)), compose: .sum)
}

private func node(_ r: TransitionRender, _ a: [RenderNode] = [red], _ b: [RenderNode] = [green]) -> RenderNode {
    .transition(format: fmt, render: r, first: a, second: b)
}

@Test func pushSeamIsSubpixelAndFullyCovered() throws {
    guard let t = try draw([blue, node(push(seam: 40.25))]) else { return }
    near(pixel(t, 39), [1, 0, 0], 0.01, "left of the seam: A")
    near(pixel(t, 41), [0, 1, 0], 0.01, "right of the seam: B")
    // The seam pixel (center 40.5) is 1/4 A and 3/4 B, and nothing of the blue below shows through.
    near(pixel(t, 40), [0.25, 0.75, 0], 0.02, "seam pixel")
    #expect(abs(pixel(t, 40)[3] - 1) < 0.01)
}

@Test func pushEdgeMovesSmoothlyBetweenWholePixels() throws {
    // The seam pixel's share of A grows in step with the fractional seam position: no stepping between frames.
    var reds: [Double] = []
    for s in [40.5, 40.75, 41.0, 41.25, 41.5] {
        guard let t = try draw([blue, node(push(seam: s))]) else { return }
        reds.append(pixel(t, 40)[0])
    }
    for (r, e) in zip(reds, [0.5, 0.75, 1.0, 1.0, 1.0]) { #expect(abs(r - e) < 0.02, "\(reds)") }
    guard let t = try draw([blue, node(push(seam: 41.25))]) else { return }
    #expect(abs(pixel(t, 41)[0] - 0.25) < 0.02)
}

@Test func motionBlurSmearsTheSeamAlongTheMotion() throws {
    guard let t = try draw([blue, node(push(seam: 32, blur: 8.0 / Double(W)))]) else { return }
    var ramp = 0
    for x in 0..<W { let r = pixel(t, x)[0]; if r > 0.05 && r < 0.95 { ramp += 1 } }
    #expect(ramp >= 6, "an 8 px smear makes a ramp several pixels wide, got \(ramp)")
    near(pixel(t, 2), [1, 0, 0], 0.01, "far from the seam: sharp A")
    // Still opaque everywhere: smearing the two pictures keeps the sum whole.
    #expect(abs(pixel(t, 32)[3] - 1) < 0.01)
}

@Test func longWhipSmearIsSmoothWithoutGhostCopies() throws {
    // A whip at 4K mid-transition smears ~1400 px; at 1024 px wide a 600 px smear has the same tap problem: too few taps
    // leave ghost copies (a staircase ramp). A true box smear rises by 1/600 per pixel; allow a few times that.
    let ww = 1024, wh = 4
    let wf = SequenceFormat(width: ww, height: wh, frameDuration: Time(1, 30))
    let wi = VideoTrackInfo(width: ww, height: wh, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                            nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, matrix: nil)
    func pic(_ c: (UInt8, UInt8, UInt8, UInt8)) -> RenderNode { .layer(RenderLayer(content: .frame(bgra(ww, wh, c), colorHint: wi))) }
    let blur = Vec2(-600.0 / Double(ww), 0)
    let r = TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.5, 0), blur: blur),
                             incoming: TransitionSide(offset: Vec2(0.5, 0), blur: blur), compose: .sum)
    guard let t = try draw([.transition(format: wf, render: r, first: [pic((0, 0, 255, 255))], second: [pic((0, 255, 0, 255))])],
                           format: wf) else { return }
    var row = [Float16](repeating: 0, count: ww * 4)
    t.getBytes(&row, bytesPerRow: ww * 8, from: MTLRegionMake2D(0, wh / 2, ww, 1), mipmapLevel: 0)
    let reds = (0..<ww).map { Double(row[$0 * 4]) }
    let worst = zip(reds, reds.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    #expect(worst < 0.006, "largest step between neighboring pixels \(worst) (ghost copies)")
    // A ends at x 512; the 600 px smear ramps from x 212 to 812.
    #expect(reds[150] > 0.99 && abs(reds[512] - 0.5) < 0.02 && abs(reds[362] - 0.75) < 0.02 && reds[870] < 0.01, "\(reds[512])")
}

@Test func slideDrawsTheIncomingPictureOverTheStillOutgoingOne() throws {
    let r = TransitionRender(incoming: TransitionSide(offset: Vec2(0.5, 0)), compose: .incomingOver)
    guard let t = try draw([blue, node(r)]) else { return }
    near(pixel(t, 10), [1, 0, 0], 0.01, "A stays put")
    near(pixel(t, 50), [0, 1, 0], 0.01, "B covers the right half")
}

@Test func softWipeBlendsAcrossTheBand() throws {
    let r = TransitionRender(compose: .wipe, wipe: .init(direction: Vec2(-1, 0), front: 0.5, softness: 0.1))
    guard let t = try draw([blue, node(r)]) else { return }
    near(pixel(t, 2), [1, 0, 0], 0.01, "far left: A")
    near(pixel(t, 61), [0, 1, 0], 0.01, "far right: B (the edge moves left)")
    let mid = pixel(t, 32)
    #expect(mid[0] > 0.3 && mid[0] < 0.7 && abs(mid[0] + mid[1] - 1) < 0.02, "\(mid)")
}

@Test func missingSideShowsWhatIsBelow() throws {
    // Tail push-out: only the outgoing picture, moved half out; the track below shows where it left.
    let r = TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.5, 0)), compose: .sum)
    guard let t = try draw([blue, node(r, [red], [])]) else { return }
    near(pixel(t, 10), [1, 0, 0])
    near(pixel(t, 50), [0, 0, 1], 0.01, "below")
}

@Test func zoomScalesAboutTheCentre() throws {
    // A at 2x with a soft fade-out (opacity 0.5) over B: the center stays A's center color, mixed half with B.
    let r = TransitionRender(outgoing: TransitionSide(scale: 2, opacity: 0.5), compose: .outgoingOver)
    guard let t = try draw([node(r)]) else { return }
    near(pixel(t, 32), [0.5, 0.5, 0], 0.02)
}

@Test func zoomSideBelowFullSizeFillsTheFrameWithMirroredEdges() throws {
    // A: left quarter red, rest green, shrunk to 50 % (it covers x 16..48). Mirrored edges: at x = 2 the sample point lies
    // 0.42 of the width left of A's edge, mirrored back to 0.42 inside it = green (clamping would give red, no mirror blue).
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<H { for x in 0..<W {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        let red = x < W / 4
        p[0] = 0; p[1] = red ? 0 : 255; p[2] = red ? 255 : 0; p[3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(b, [])
    let quarter = RenderNode.layer(RenderLayer(content: .frame(b, colorHint: info)))
    let mirrored = TransitionRender(outgoing: TransitionSide(scale: 0.5, mirrorEdges: true), incoming: TransitionSide(opacity: 0),
                                    compose: .outgoingOver)
    guard let t = try draw([blue, node(mirrored, [quarter], [])]) else { return }
    near(pixel(t, 2), [0, 1, 0], 0.02, "mirrored copy")
    near(pixel(t, 20), [1, 0, 0], 0.02, "the picture itself (left quarter of it)")
    near(pixel(t, 2, 0), [0, 1, 0], 0.02, "corner row too")
    // Without the flag the same side leaves the edges to what is below.
    let plain = TransitionRender(outgoing: TransitionSide(scale: 0.5), incoming: TransitionSide(opacity: 0), compose: .outgoingOver)
    guard let p = try draw([blue, node(plain, [quarter], [])]) else { return }
    near(pixel(p, 2), [0, 0, 1], 0.02, "below")
}

@Test func mirroredEdgesOnlyForAnOpaquePictureThatFillsTheFrame() throws {
    // Amount 200: the side below full size is at 50 %. A full-frame clip fills the frame (no blue from below anywhere).
    let shrunk = TransitionRender(outgoing: TransitionSide(opacity: 0), incoming: TransitionSide(scale: 0.5, mirrorEdges: true),
                                  compose: .outgoingOver)
    guard let t = try draw([blue, node(shrunk, [], [green])]) else { return }
    for x in [0, 2, 15, 32, 50, 63] { for y in [0, H / 2, H - 1] { near(pixel(t, x, y), [0, 1, 0], 0.02, "full frame \(x),\(y)") } }
    // A half-size clip (x 16..48 of its canvas): shrunk it covers x 24..40 and nothing else, no reflected copy beside it.
    var small = RenderLayer(content: .frame(bgra(W, H, (0, 255, 0, 255)), colorHint: info))
    small.transform.scale = Vec2(0.5, 0.5)
    guard let s = try draw([blue, node(shrunk, [], [.layer(small)])]) else { return }
    near(pixel(s, 32), [0, 1, 0], 0.02, "the clip")
    for x in [0, 4, 12, 20, 44, 52, 60] { near(pixel(s, x), [0, 0, 1], 0.02, "beside the clip at \(x)") }
    // A see-through full-frame clip is not mirrored either.
    var half = RenderLayer(content: .frame(bgra(W, H, (0, 255, 0, 255)), colorHint: info))
    half.transform.opacity = 0.5
    guard let h = try draw([blue, node(shrunk, [], [.layer(half)])]) else { return }
    near(pixel(h, 2), [0, 0, 1], 0.02, "outside a see-through side")
}

@Test func aFullFrameClipWithASmallHoleIsNotMirrored() throws {
    // One transparent pixel that no 5 x 5 grid point hits (x 5, y 3 of 64 x 16): the exact test sees it, so the side shrunk
    // to 50 % leaves the edges to what is below (blue) instead of a reflected copy. Without the hole it still mirrors.
    let shrunk = TransitionRender(outgoing: TransitionSide(opacity: 0), incoming: TransitionSide(scale: 0.5, mirrorEdges: true),
                                  compose: .outgoingOver)
    func holed(_ hole: Bool) -> RenderNode {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
        for y in 0..<H { for x in 0..<W {
            let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            let clear = hole && x == 5 && y == 3
            p[0] = 0; p[1] = clear ? 0 : 255; p[2] = 0; p[3] = clear ? 0 : 255
        } }
        CVPixelBufferUnlockBaseAddress(b, [])
        return .layer(RenderLayer(content: .frame(b, colorHint: info)))
    }
    guard let t = try draw([blue, node(shrunk, [], [holed(true)])]) else { return }
    near(pixel(t, 2), [0, 0, 1], 0.02, "hole: no reflected copy")
    guard let m = try draw([blue, node(shrunk, [], [holed(false)])]) else { return }
    near(pixel(m, 2), [0, 1, 0], 0.02, "no hole: mirrored")
}

@Test func transitionUniformsMatchTheShaderLayout() {
    #expect(MemoryLayout<Compositor.TransitionSideUniforms>.stride == 40)
    #expect(MemoryLayout<Compositor.TransitionUniforms>.stride == 120)
}

@Test func glitchCutsFromAToBAtTheMiddleAndKeepsTheCentreIntact() throws {
    for (mix, want) in [(0.3, [1.0, 0, 0]), (0.7, [0.0, 1, 0])] {
        var g = TransitionRender(compose: .glitch)
        g.glitch = .init(mix: mix, intensity: 1, seed: 99)
        guard let t = try draw([node(g)]) else { return }
        for y in [2, 8, 13] { near(pixel(t, 32, y), want, 0.01, "mix \(mix) row \(y)") }
    }
}

@Test func glitchAtZeroIntensityIsThePlainPicture() throws {
    var g = TransitionRender(compose: .glitch)
    g.glitch = .init(mix: 0.2, intensity: 0, seed: 5)
    guard let t = try draw([node(g)]) else { return }
    for x in [1, 20, 62] { near(pixel(t, x), [1, 0, 0], 0.01, "x \(x)") }
}

@Test func treeBuildsATransitionNodeFromTaggedRequests() {
    let r = TransitionRender(compose: .sum)
    func req(_ role: LayerRequest.PairRole?, _ pid: UUID) -> LayerRequest {
        var q = LayerRequest(clip: UUID(), media: UUID(), track: UUID(), sourceTime: .zero)
        q.pair = role.map { LayerRequest.PairInfo(id: pid, role: $0, format: fmt, depth: 0, render: r) }
        return q
    }
    let pid = UUID()
    let layer = RenderLayer(content: .solid(red: 1, green: 0, blue: 0))
    let reqs = [req(nil, pid), req(.first, pid), req(.second, pid)]
    let tree = RenderNode.tree(requests: reqs, layers: reqs.map { _ in layer })
    #expect(tree.count == 2)
    guard case .transition(_, let got, let first, let second) = tree[1] else { Issue.record("expected a transition"); return }
    #expect(got == r && first.count == 1 && second.count == 1)
    // Single-sided (head): only the second side.
    let head = [req(.second, pid)]
    guard case .transition(_, _, let f2, let s2) = RenderNode.tree(requests: head, layers: [layer])[0] else {
        Issue.record("expected a transition"); return
    }
    #expect(f2.isEmpty && s2.count == 1)
}

// Review #4: long-blur pre-pass textures. Their size followed the animated blur (a new texture every frame), the pool
// was capped by count (a few 3x-canvas textures are gigabytes), and frames wider than 16384 / 3 failed outright.

@Test func longBlurPadIsQuantisedSoAnAnimatedBlurReusesTextures() {
    let a = Compositor.longBlurTarget(width: 3840, height: 2160, pad: 0.101, maxSide: 16384)
    let b = Compositor.longBlurTarget(width: 3840, height: 2160, pad: 0.118, maxSide: 16384)
    #expect(a.width == b.width && a.height == b.height && a.pad == b.pad)
    #expect(a.pad >= 0.118)                                                // never less than the picture needs
    #expect(a.width == Int((3840 * (1 + 2 * a.pad)).rounded(.up)))
    #expect(Compositor.longBlurTarget(width: 3840, height: 2160, pad: 1, maxSide: 16384).pad == 1)
}

@Test func longBlurTargetOnWideFramesIsDownscaledToTheDeviceLimit() {
    let t = Compositor.longBlurTarget(width: 8192, height: 4320, pad: 1, maxSide: 16384)
    #expect(t.pad == 1)
    #expect(t.width == 16384 && t.height <= 16384)
    #expect(abs(Double(t.width) / Double(t.height) - 8192.0 / 4320.0) < 0.001)   // same aspect: normalized coords hold
}

@Test func longWhipOnAFrameTooWideForThePrePassStillRenders() throws {
    // The pre-pass canvas (1024 x ~1.6 wide) is over this compositor's limit: it is drawn smaller, not refused.
    guard let (dev, q, comp) = setup() else { return }
    comp.maxIntermediateSide = 1024
    let ww = 1024, wh = 4
    let wf = SequenceFormat(width: ww, height: wh, frameDuration: Time(1, 30))
    let wi = VideoTrackInfo(width: ww, height: wh, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                            nominalFrameDuration: Time(1, 30), isVariableFrameRate: false, matrix: nil)
    func pic(_ c: (UInt8, UInt8, UInt8, UInt8)) -> RenderNode { .layer(RenderLayer(content: .frame(bgra(ww, wh, c), colorHint: wi))) }
    let blur = Vec2(-600.0 / Double(ww), 0)
    let r = TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.5, 0), blur: blur),
                             incoming: TransitionSide(offset: Vec2(0.5, 0), blur: blur), compose: .sum)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: ww, height: wh, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: [.transition(format: wf, render: r, first: [pic((0, 0, 255, 255))], second: [pic((0, 255, 0, 255))])],
                    format: wf, into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    var row = [Float16](repeating: 0, count: ww * 4)
    t.getBytes(&row, bytesPerRow: ww * 8, from: MTLRegionMake2D(0, wh / 2, ww, 1), mipmapLevel: 0)
    let reds = (0..<ww).map { Double(row[$0 * 4]) }
    let worst = zip(reds, reds.dropFirst()).map { abs($1 - $0) }.max() ?? 0
    #expect(worst < 0.006, "largest step \(worst)")
    #expect(reds[150] > 0.99 && abs(reds[512] - 0.5) < 0.02 && abs(reds[362] - 0.75) < 0.03 && reds[870] < 0.01)
}

@Test func freeIntermediatePoolIsCappedByBytes() throws {
    guard let (_, _, comp) = setup() else { return }
    comp.intermediatePoolByteLimit = 3 * 256 * 256 * 8                    // three 256 px textures
    let texs = (0..<6).compactMap { _ in comp.acquireIntermediate(width: 256, height: 256) }
    let big = try #require(comp.acquireIntermediate(width: 1024, height: 1024))   // alone over the limit: never kept
    comp.releaseIntermediates(texs + [big])
    #expect(comp.freeIntermediateBytes == 3 * 256 * 256 * 8)
    let before = comp.intermediateAllocations
    _ = comp.acquireIntermediate(width: 256, height: 256)                  // reused from the pool
    #expect(comp.intermediateAllocations == before)
}

// Iris and Light Leak: the shader must equal the CPU reference (`TransitionRender.Iris` / `.LightLeak`).

@Test func irisShaderMatchesTheCPUMask() throws {
    let front = 0.55, soft = 0.1
    let r = TransitionRender(compose: .iris, wipe: .init(direction: .zero, front: front, softness: soft))
    guard let t = try draw([blue, node(r)]) else { return }
    for (x, y) in [(32, 8), (10, 8), (2, 1), (62, 14), (20, 3), (50, 12)] {
        let m = TransitionRender.Iris.mask(u: (Double(x) + 0.5) / Double(W), v: (Double(y) + 0.5) / Double(H), front: front, softness: soft)
        near(pixel(t, x, y), [1 - m, m, 0], 0.01, "iris \(x),\(y)")
    }
}

@Test func lightLeakShaderMatchesTheCPUReference() throws {
    for p in [0.2, 0.5, 0.8] {
        let d = Vec2(-1, 0), soft = 0.1
        let r = TransitionRender(compose: .lightLeak, wipe: .init(direction: d, front: p, softness: soft))
        guard let t = try draw([blue, node(r)]) else { return }
        let w = TransitionRender.LightLeak.mixWeight(progress: p)
        for x in [4, 20, 32, 44, 60] {
            let l = TransitionRender.LightLeak.leak(u: (Double(x) + 0.5) / Double(W), v: 0.5 + 0.5 / Double(H), progress: p, direction: d, softness: soft)
            let e = TransitionRender.LightLeak.screen(base: (1 - w, w, 0), alpha: 1, leak: l)
            near(pixel(t, x), [e.r, e.g, e.b], 0.012, "leak p\(p) x\(x)")
        }
    }
}

// Round 4 set: Blur Dissolve, Static, Light Noise, Spin (rotation). Uniform pictures keep the checks exact.

@Test func blurDissolveOfUniformPicturesIsThePlainMixWithNoDarkRim() throws {
    for soft in [0.0, 0.3] {   // 0.3 of the 16 px height = 4.8 px radius
        let r = TransitionRender(compose: .blurDissolve, wipe: .init(direction: .zero, front: 0.25, softness: soft))
        guard let t = try draw([blue, node(r)]) else { return }
        for (x, y) in [(0, 0), (1, 8), (32, 8), (63, 15), (62, 0)] {
            near(pixel(t, x, y), [0.75, 0.25, 0], 0.01, "blur dissolve soft \(soft) \(x),\(y)")
            #expect(abs(pixel(t, x, y)[3] - 1) < 0.01)
        }
    }
}

@Test func blurDissolveSmearsAnEdgeOfTheOutgoingPicture() throws {
    // A is a hard red | green split; B is blue. With front 0 only A shows: a blurred seam mixes red and green over a few px.
    guard let split = splitBuffer() else { return }
    let a = RenderNode.layer(RenderLayer(content: .frame(split, colorHint: info)))
    let sharp = TransitionRender(compose: .blurDissolve, wipe: .init(direction: .zero, front: 0, softness: 0))
    let soft = TransitionRender(compose: .blurDissolve, wipe: .init(direction: .zero, front: 0, softness: 0.4))
    guard let t0 = try draw([node(sharp, [a], [blue])]), let t1 = try draw([node(soft, [a], [blue])]) else { return }
    near(pixel(t0, W / 2 - 2), [1, 0, 0]); near(pixel(t0, W / 2 + 1), [0, 1, 0])
    let m = pixel(t1, W / 2 - 1)
    #expect(m[1] > 0.05 && m[0] < 0.95 && m[0] > 0.3, "seam is softened: \(m)")
    near(pixel(t1, 1), [1, 0, 0], 0.01, "far from the seam")
}

@Test func staticIsThePlainPictureAtZeroIntensityAndNoisyAtFullIntensity() throws {
    for (mix, want) in [(0.3, [1.0, 0, 0]), (0.7, [0.0, 1, 0])] {
        var rr = TransitionRender(compose: .staticNoise)
        rr.glitch = .init(mix: mix, intensity: 0, seed: 5)
        guard let t = try draw([node(rr)]) else { return }
        for x in [0, 17, 40, 63] { near(pixel(t, x), want, 0.01, "static 0 mix \(mix) x\(x)") }
    }
    var full = TransitionRender(compose: .staticNoise); full.glitch = .init(mix: 0.3, intensity: 1, seed: 5)
    guard let t = try draw([node(full)]), let t2 = try draw([node(full)]) else { return }
    var differing = 0
    for x in 1..<W where abs(pixel(t, x)[1] - pixel(t, x - 1)[1]) > 0.02 { differing += 1 }
    #expect(differing > W / 2, "noise varies from pixel to pixel")
    for x in [3, 30, 60] { #expect(pixel(t, x) == pixel(t2, x), "same seed = same frame (export equals playback)") }
    var other = full; other.glitch.seed = 6
    if let t3 = try draw([node(other)]) { #expect((0..<W).contains { pixel(t, $0) != pixel(t3, $0) }) }
}

@Test func lightNoiseKeepsTheEndsPureAndBrightensTheMiddle() throws {
    func at(_ p: Double) throws -> MTLTexture? {
        try draw([node(TransitionRender(compose: .lightNoise, wipe: .init(direction: .zero, front: p, softness: 0)))])
    }
    if let t = try at(0) { near(pixel(t, 20), [1, 0, 0], 0.01, "start is A") }
    if let t = try at(1) { near(pixel(t, 20), [0, 1, 0], 0.01, "end is B") }
    guard let t = try at(0.5) else { return }
    var brighter = false
    for x in 0..<W {
        let p = pixel(t, x)
        if p[2] > 0.05 { brighter = true }
        #expect(p[0] >= 0.49 && p[1] >= 0.49)
    }
    #expect(brighter, "the glow screens over the middle of the dissolve")
}

@Test func rotationTurnsThePictureAboutTheCentre() throws {
    guard let split = splitBuffer() else { return }
    let a = RenderNode.layer(RenderLayer(content: .frame(split, colorHint: info)))
    let none = TransitionRender(outgoing: TransitionSide(), compose: .sum)
    let half = TransitionRender(outgoing: TransitionSide(rotation: .pi), compose: .sum)
    guard let t0 = try draw([node(none, [a], [])]), let t1 = try draw([node(half, [a], [])]) else { return }
    near(pixel(t0, 10), [1, 0, 0]); near(pixel(t0, 54), [0, 1, 0])
    near(pixel(t1, 10), [0, 1, 0], 0.01, "turned half way round: green on the left"); near(pixel(t1, 54), [1, 0, 0], 0.01)
}

@Test func newTransitionsCostOnA4KFrame() throws {
    let w = 3840, h = 2160, f4k = SequenceFormat(width: w, height: h, frameDuration: Time(1, 30))
    let info4k = VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: Time(1, 30),
                                isVariableFrameRate: false, matrix: nil)
    func plain(_ c: (UInt8, UInt8, UInt8, UInt8)) -> RenderNode { .layer(RenderLayer(content: .frame(bgra(w, h, c), colorHint: info4k))) }
    guard let (dev, q, comp) = setup() else { return }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
    guard let out = dev.makeTexture(descriptor: d) else { return }
    let a = plain((0, 0, 255, 255)), b = plain((0, 255, 0, 255))
    var cases: [(String, TransitionRender)] = [
        ("blurDissolve", TransitionRender(compose: .blurDissolve, wipe: .init(direction: .zero, front: 0.5, softness: TransitionRender.BlurDissolve.maxRadius))),
        ("lightNoise", TransitionRender(compose: .lightNoise, wipe: .init(direction: .zero, front: 0.5, softness: 0))),
        ("spin", TransitionRender(outgoing: TransitionSide(scale: 1.4, opacity: 0.5, zoomBlur: 0.12, rotation: 0.8),
                                  incoming: TransitionSide(scale: 1.4, opacity: 0.5, zoomBlur: 0.12, rotation: -0.8), compose: .sum)),
        ("crossZoom", TransitionRender(outgoing: TransitionSide(scale: 1.2, opacity: 0.5, zoomBlur: 0.35),
                                       incoming: TransitionSide(scale: 1.2, opacity: 0.5, zoomBlur: 0.35), compose: .sum)),
    ]
    var st = TransitionRender(compose: .staticNoise); st.glitch = .init(mix: 0.3, intensity: 1, seed: 9)
    cases.append(("static", st))
    for (name, r) in cases {
        var best = Double.infinity
        for _ in 0..<4 {
            let cb = q.makeCommandBuffer()!
            try comp.render(nodes: [.transition(format: f4k, render: r, first: [a], second: [b])], format: f4k, into: out, commandBuffer: cb)
            cb.commit(); cb.waitUntilCompleted()
            #expect(cb.error == nil)
            best = min(best, cb.gpuEndTime - cb.gpuStartTime)
        }
        NSLog("transition 4K GPU cost %@: %.2f ms", name, best * 1000)
        if let path = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] {   // test.sh prints errors only; this keeps the numbers
            let line = String(format: "transition 4K GPU cost %@: %.2f ms\n", name, best * 1000)
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
        }
        #expect(best * 1000 < 16, "\(name) must stay under half a 30 fps frame at 4K")
    }
}

private func splitBuffer() -> CVPixelBuffer? {
    let b = bgra(W, H, (0, 0, 255, 255))   // red
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    guard let base = CVPixelBufferGetBaseAddress(b) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<H { for x in W / 2..<W {
        let p = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
        p[0] = 0; p[1] = 255; p[2] = 0; p[3] = 255   // green on the right half
    } }
    return b
}

@Test func borderBandFollowsTheSeamAndMatchesTheCPUCoverage() throws {
    // Push left, seam at 32 px; border 10 % of the frame (6.4 px) of pure white centered on it.
    var r = push(seam: 32)
    r.border = TransitionRender.Border(width: 0.1, color: [255, 255, 255])
    r.wipe = .init(direction: Vec2(-1, 0), front: 0.5)
    guard let t = try draw([node(r)]), let plainT = try draw([node(push(seam: 32))]) else { return }
    near(pixel(t, 10), pixel(plainT, 10), 0.01, "left of the band: unchanged")
    near(pixel(t, 54), pixel(plainT, 54), 0.01, "right of the band: unchanged")
    near(pixel(t, 32), [1, 1, 1], 0.01, "band center")
    near(pixel(t, 30), [1, 1, 1], 0.01, "inside the band")
    // Band edges at 0.5 +- 0.05 -> px 28.8 / 35.2: pixels around them follow the CPU coverage.
    for px in [27, 28, 29, 35, 36] {
        let x = (Double(px) + 0.5) / Double(W)   // wipe.direction is (-1, 0): position along it is 1 - x
        let c = TransitionRender.Border.coverage(x: 1 - x, front: 0.5, width: 0.1, aa: 0.5 / Double(W))
        let base = pixel(plainT, px)
        near(pixel(t, px), base.map { $0 * (1 - c) + c }, 0.02, "px \(px)")
    }
}

@Test func aWipeWithoutBorderIsThePlainPictureBitForBit() throws {
    var a = push(seam: 20)
    a.wipe = .init(direction: Vec2(-1, 0), front: 0.3)   // set without a border: changes nothing
    guard let t = try draw([node(a)]), let p = try draw([node(push(seam: 20))]) else { return }
    for x in [0, 5, 19, 20, 21, 40, 63] { #expect(pixel(t, x) == pixel(p, x)) }
}

/// The second wipe set: the shader's distance fields must pick A / B per pixel like `ShapeWipe.mask` (Random Blocks also
/// proves the integer hash matches bit for bit).
@Test func secondWipeSetShaderMatchesTheCPUMask() throws {
    let kinds: [TransitionKind] = [.radialWipe, .wedgeWipe, .pinwheel, .checkerWipe, .zigZagBlocks, .insetWipe, .randomBlocks, .sliceWipe]
    for k in kinds {
        let r = TransitionRender.evaluate(kind: k, direction: .left, softness: 0, motionBlur: 0, easing: .linear, frameIndex: 5, frames: 11)
        guard let t = try draw([node(r)]) else { return }
        let shape = TransitionRender.ShapeWipe.Shape(rawValue: Int(r.wipe.direction.x))!
        var checked = 0
        for y in 0..<H { for x in 0..<W {
            let m = TransitionRender.ShapeWipe.mask(shape, u: (Double(x) + 0.5) / Double(W), v: (Double(y) + 0.5) / Double(H),
                                                    front: r.wipe.front, softness: 0)
            let p = pixel(t, x, y)
            // Skip pixels within a hair of a field edge (the shader keeps a half-pixel soft edge).
            let d = TransitionRender.ShapeWipe.distance(shape, u: (Double(x) + 0.5) / Double(W), v: (Double(y) + 0.5) / Double(H))
            if abs(d - r.wipe.front) < 0.04 { continue }
            checked += 1
            near(p, m > 0.5 ? [0, 1, 0] : [1, 0, 0], 0.02, "\(k) x\(x) y\(y)")
        } }
        #expect(checked > W * H / 2, "\(k)")
    }
}

@Test func mosaicDissolveIsCleanAtTheEndsAndHalfAndHalfInTheMiddle() throws {
    func at(_ i: Int) -> TransitionRender {
        TransitionRender.evaluate(kind: .mosaicDissolve, direction: .left, softness: 0, motionBlur: 0, easing: .linear, frameIndex: i, frames: 11)
    }
    guard let first = try draw([node(at(0))]) else { return }
    near(pixel(first, 5), [1, 0, 0], 0.1, "start: A")
    guard let mid = try draw([node(at(5), [red], [green])]) else { return }
    let p = pixel(mid, 20)
    #expect(abs(p[0] - 0.5) < 0.05 && abs(p[1] - 0.5) < 0.05, "mid-way is the half-and-half dissolve \(p)")
    guard let last = try draw([node(at(10))]) else { return }
    near(pixel(last, 5), [0, 1, 0], 0.1, "end: B")
}

/// Film Dissolve (linear-light mix) is the plain Dissolve: the compositor sums the two pictures in working-linear light, so
/// black and white at the middle land at 0.5 in the linear target, not the 0.21 a sum of encoded values would give.
@Test func dissolveMixesInLinearLight() throws {
    func layer(_ c: UInt8, _ o: Double) -> RenderNode {
        .layer(RenderLayer(content: .frame(bgra(W, H, (c, c, c, 255)), colorHint: info), transform: ClipTransform(opacity: o)))
    }
    guard let t = try draw([.pair(format: fmt, first: [layer(0, 0.5)], second: [layer(255, 0.5)])]) else { return }
    near(pixel(t, 20), [0.5, 0.5, 0.5], 0.01, "linear-light mid-point")
}

// MARK: Third set (Flip 3D, Burn, Flare, Warp, Shake)

private func third(_ k: TransitionKind, _ i: Int) -> TransitionRender {
    TransitionRender.evaluate(kind: k, direction: .left, softness: 0, motionBlur: 0, easing: .linear, frameIndex: i, frames: 11)
}

@Test func thirdSetStartsOnAAndEndsOnB() throws {
    for k in [TransitionKind.flip3D, .burn, .warp, .shake] {
        guard let first = try draw([node(third(k, 0))]), let last = try draw([node(third(k, 10))]) else { return }
        near(pixel(first, 32), [1, 0, 0], 0.15, "\(k) start")
        near(pixel(last, 32), [0, 1, 0], 0.15, "\(k) end")
    }
}

@Test func flip3DIsEdgeOnInTheMiddleAndShowsTheCardBesideIt() throws {
    guard let mid = try draw([blue, node(third(.flip3D, 5))]) else { return }
    // The card is a thin sliver at the middle: the corner shows what is below (blue), not A or B.
    near(pixel(mid, 2), [0, 0, 1], 0.02, "empty beside the edge-on card")
    guard let quarter = try draw([blue, node(third(.flip3D, 2))]) else { return }
    near(pixel(quarter, 32), [1, 0, 0], 0.02, "A still in the middle of the first quarter")
}

@Test func flareBrightensTheMiddleOfTheDissolve() throws {
    guard let mid = try draw([node(third(.flare, 5))]), let first = try draw([node(third(.flare, 0))]) else { return }
    let m = pixel(mid, 32), f = pixel(first, 32)
    #expect(m[0] + m[1] + m[2] > 1.15 && f[0] + f[1] + f[2] < 1.4, "mid \(m) first \(f)")
}

@Test func burnShowsAGlowingEdgeInTheMiddle() throws {
    guard let mid = try draw([node(third(.burn, 5))]) else { return }
    var glow = false
    for x in 0..<W { let p = pixel(mid, x); if p[0] > 1.05 || (p[0] > 0.5 && p[1] > 0.3 && p[2] < 0.2 && p[1] < 0.9) { glow = true } }
    #expect(glow)
}
#endif
