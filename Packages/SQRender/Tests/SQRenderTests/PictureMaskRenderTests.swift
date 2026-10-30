#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import Testing
@testable import SQRender

// C6 T4 Picture masks in the compositor: matte layers (`LayerRequest.matteFor`) become `.pictureMatte` nodes, rendered once
// per level into a canvas-sized image that is never drawn, and the Picture masks of that level sample it fixed to the
// screen. Pixels against the CPU reference `MaskCoverage` (with the matte's coverage), within one 8-bit step.

private func makeBGRA(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h {
        for x in 0..<w {
            let px = (base + y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
            let c = f(x, y)
            px[0] = c.0; px[1] = c.1; px[2] = c.2; px[3] = c.3
        }
    }
    return b
}

private func info(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func fmt(_ w: Int, _ h: Int) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)) }

private func setup() -> (MTLDevice, MTLCommandQueue, Compositor)? {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue(), let c = try? Compositor(device: d) else { return nil }
    return (d, q, c)
}

private func render(_ comp: Compositor, _ dev: MTLDevice, _ q: MTLCommandQueue, _ nodes: [RenderNode],
                    _ w: Int, _ h: Int) throws -> [SIMD4<Float>] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: nodes, format: fmt(w, h), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    var px = [Float16](repeating: 0, count: w * h * 4)
    t.getBytes(&px, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    var out: [SIMD4<Float>] = []
    out.reserveCapacity(w * h)
    for i in 0..<(w * h) {
        let r = Float(px[i * 4]), g = Float(px[i * 4 + 1]), b = Float(px[i * 4 + 2]), a = Float(px[i * 4 + 3])
        out.append(SIMD4<Float>(r, g, b, a))
    }
    return out
}

private func lin709(_ e: Float) -> Float {
    e < 0.081242858 ? e / 4.5 : powf((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45)
}

private let tolerance: Float = 1.0 / 255 + 0.001

/// The consumer color (display-encoded) and its working-linear value.
private let colour: (Float, Float, Float) = (0.8, 0.5, 0.3)
private let colourLinear = SIMD3<Float>(lin709(0.8), lin709(0.5), lin709(0.3))

private func picture(_ track: UUID, channel: MatteChannel = .shape, opacity: Double = 1, inverted: Bool = false,
                     mode: MaskMode = .add) -> MaskShape {
    var m = MaskShape(polygon: [], opacity: opacity, inverted: inverted, mode: mode, source: .picture)
    m.pictureTrack = track
    m.pictureChannel = channel
    return m
}

private func scaled(_ s: Double, _ sy: Double? = nil, x: Double = 0, rotation: Double = 0) -> ClipTransform {
    var t = ClipTransform.identity
    t.scale = Vec2(s, sy ?? s)
    t.position = Vec2(x, 0)
    t.rotation = rotation
    return t
}

/// A drawn request on `track` with `masks` (and the same masks on its layer, as the playback / export layer builders do).
private func drawn(_ track: UUID, _ layer: RenderLayer, masks: [MaskShape] = [], segments: [EffectSegment] = [],
                   groups: [LayerGroup] = []) -> (LayerRequest, RenderLayer) {
    let fx = ClipEffects(segments: segments, masks: masks)
    let r = LayerRequest(clip: UUID(), media: UUID(), track: track, sourceTime: .zero, groups: groups, effects: fx)
    var l = layer
    l.effects = fx
    return (r, l)
}

/// A matte request of `track`, read by the Picture masks of level `groups.count`.
private func matte(_ track: UUID, _ layer: RenderLayer, groups: [LayerGroup] = []) -> (LayerRequest, RenderLayer) {
    var r = LayerRequest(clip: UUID(), media: UUID(), track: track, sourceTime: .zero, groups: groups)
    r.matteFor = track
    r.matteDepth = groups.count
    return (r, layer)
}

private func tree(_ items: [(LayerRequest, RenderLayer)]) -> [RenderNode] {
    RenderNode.tree(requests: items.map(\.0), layers: items.map(\.1))
}

private func solid(_ c: (Float, Float, Float), _ t: ClipTransform = .identity) -> RenderLayer {
    RenderLayer(content: .solid(red: c.0, green: c.1, blue: c.2), transform: t)
}

/// Worst channel error of `got` against the consumer color times `coverage(x, y)` over black.
private func worst(_ got: [SIMD4<Float>], _ w: Int, _ h: Int, _ coverage: (Int, Int) -> Double) -> Float {
    var e: Float = 0
    for y in 0..<h {
        for x in 0..<w {
            let c = Float(coverage(x, y)), g = got[y * w + x]
            for i in 0..<3 { e = max(e, abs(g[i] - colourLinear[i] * c)) }
        }
    }
    return e
}

@Suite struct PictureMaskRenderTests {
    let w = 64, h = 36
    let v1 = UUID(), v2 = UUID()

    /// The white square (half the canvas, centered) of the matte track: x 16..<48, y 9..<27.
    func inSquare(_ x: Int, _ y: Int) -> Bool { x >= 16 && x < 48 && y >= 9 && y < 27 }

    func cpu(_ masks: [MaskShape], _ value: @escaping (Int, Int) -> Double) -> (Int, Int) -> Double {
        { x, y in
            MaskCoverage.coverage(at: Vec2(Double(x) + 0.5, Double(y) + 0.5), masks: masks, frame: Vec2(Double(self.w), Double(self.h)),
                                  pixel: 1, picture: { _, _ in value(x, y) })
        }
    }

    @Test func whiteSquareOnV2MattesV1AndIsNeverDrawn() throws {
        let (dev, q, comp) = try #require(setup())
        let masks = [picture(v2)]
        let got = try render(comp, dev, q, tree([drawn(v1, solid(colour), masks: masks), matte(v2, solid((1, 1, 1), scaled(0.5)))]), w, h)
        let e = worst(got, w, h, cpu(masks) { x, y in self.inSquare(x, y) ? 1 : 0 })
        #expect(e <= tolerance, "worst \(e)")
        // Inside the square: the consumer's color, not the white matte.
        #expect(abs(got[18 * w + 32][1] - colourLinear.y) < tolerance)
        #expect(got[2 * w + 2][3] < 0.002 || got[2 * w + 2][1] < 0.002)
    }

    @Test func brightnessReadsTheLumaOfAGradient() throws {
        let (dev, q, comp) = try #require(setup())
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let r = UInt8(x * 4), g = UInt8(255 - x * 3), b = UInt8(y * 7)
            return (b, g, r, 255)
        }
        let pb = makeBGRA(w, h, px)
        let masks = [picture(v2, channel: .brightness)]
        let got = try render(comp, dev, q, tree([drawn(v1, solid(colour), masks: masks),
                                                 matte(v2, RenderLayer(content: .frame(pb, colorHint: info(w, h))))]), w, h)
        let e = worst(got, w, h, cpu(masks) { x, y in
            let c = px(x, y)
            return (0.2126 * Double(c.2) + 0.7152 * Double(c.1) + 0.0722 * Double(c.0)) / 255
        })
        #expect(e <= 2 * tolerance, "worst \(e)")
    }

    @Test func invertedWithOpacityMatchesCPU() throws {
        let (dev, q, comp) = try #require(setup())
        let masks = [picture(v2, opacity: 0.6, inverted: true)]
        let got = try render(comp, dev, q, tree([drawn(v1, solid(colour), masks: masks), matte(v2, solid((1, 1, 1), scaled(0.5)))]), w, h)
        let e = worst(got, w, h, cpu(masks) { x, y in self.inSquare(x, y) ? 1 : 0 })
        #expect(e <= tolerance, "worst \(e)")
        #expect(got[2 * w + 2][1] > 0.1)          // outside the square the inverted matte shows the picture
    }

    @Test func subtractFromAPathMaskMatchesCPU() throws {
        let (dev, q, comp) = try #require(setup())
        let rect = MaskShape(polygon: MaskPath.rectangle(Vec2(0.1, 0.1), Vec2(0.9, 0.9)).polygon(), feather: 4, expansion: 0,
                             opacity: 1, inverted: false, mode: .add)
        let masks = [rect, picture(v2, opacity: 0.8, mode: .subtract)]
        let got = try render(comp, dev, q, tree([drawn(v1, solid(colour), masks: masks), matte(v2, solid((1, 1, 1), scaled(0.5)))]), w, h)
        let e = worst(got, w, h, cpu(masks) { x, y in self.inSquare(x, y) ? 1 : 0 })
        #expect(e <= tolerance, "worst \(e)")
    }

    @Test func maskedBlurFollowsTheScreenOnAScaledRotatedClip() throws {
        // A striped clip at 50 %, turned 180 degrees, blurred where the matte (the left half of the screen) covers. Turned,
        // the clip's own right half lies on the screen's left: the matte is fixed to the screen, so the screen's left blurs.
        let (dev, q, comp) = try #require(setup())
        let cw = 128, ch = 72
        let pb = makeBGRA(cw, ch) { x, _ in (x / 4) % 2 == 0 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        let leftHalf = makeBGRA(cw, ch) { x, _ in x < cw / 2 ? (255, 255, 255, 255) : (0, 0, 0, 0) }
        var clip = RenderLayer(content: .frame(pb, colorHint: info(cw, ch)), transform: scaled(0.5, rotation: 180))
        clip.effects = .none
        let segs = [EffectSegment(blurAfter: 3, scope: [picture(v2)]), EffectSegment()]
        let got = try render(comp, dev, q, tree([drawn(v1, clip, segments: segs),
                                                 matte(v2, RenderLayer(content: .frame(leftHalf, colorHint: info(cw, ch))))]), cw, ch)
        let row = ch / 2
        func spread(_ xs: Range<Int>) -> Float {
            let v = xs.map { got[row * cw + $0][1] }
            return v.max()! - v.min()!
        }
        #expect(spread(38..<58) < 0.1, "left (matte) not blurred: \(spread(38..<58))")
        #expect(spread(70..<90) > 0.5, "right (no matte) blurred: \(spread(70..<90))")
    }

    @Test func nestedGroupReadsItsOwnLevelsMatte() throws {
        // Inside a nested clip shown at 50 %: the inner matte covers the inner canvas' left half, so the parent shows the
        // consumer on x 16..<32 only (the group's left half).
        let (dev, q, comp) = try #require(setup())
        let g = LayerGroup(clip: UUID(), track: UUID(), sequence: UUID(), format: fmt(w, h), transform: scaled(0.5))
        let inner = solid((1, 1, 1), scaled(0.5, 1, x: -16))
        let got = try render(comp, dev, q, tree([drawn(v1, solid(colour), masks: [picture(v2)], groups: [g]),
                                                 matte(v2, inner, groups: [g])]), w, h)
        let row = 18
        #expect(abs(got[row * w + 20][1] - colourLinear.y) < tolerance)
        #expect(abs(got[row * w + 30][1] - colourLinear.y) < tolerance)
        #expect(got[row * w + 36][1] < 0.002)
        #expect(got[row * w + 44][1] < 0.002)
        #expect(got[row * w + 8][3] < 0.002 || got[row * w + 8][1] < 0.002)
    }

    /// Re-review #1: V3 consumer masked by V1, transition layer on V4, a title on V1 starting exactly at the cut. From the
    /// cut the outgoing side is held on the frame before it, where V1 is empty: that side covers nothing, even though the
    /// level's live matte (the title) is full frame. A live side keeps reading the level's matte.
    @Test func aHeldSideWithoutItsOwnMatteCoversNothing() throws {
        let (dev, q, comp) = try #require(setup())
        let id = UUID(), v3 = UUID()
        let shown = TransitionRender(outgoing: TransitionSide(opacity: 1), incoming: TransitionSide(opacity: 0), compose: .sum)
        func items(held: Bool) -> [(LayerRequest, RenderLayer)] {
            var c = drawn(v3, solid(colour), masks: [picture(v1)])
            c.0.stackTransitions = [StackTransition(id: id, role: .first, format: fmt(w, h), depth: 0, render: shown, held: held)]
            return [c, matte(v1, solid((1, 1, 1)))]
        }
        let heldGot = try render(comp, dev, q, tree(items(held: true)), w, h)
        #expect(heldGot.allSatisfy { $0[1] < 0.002 }, "held side read the level's live matte")
        let liveGot = try render(comp, dev, q, tree(items(held: false)), w, h)
        #expect(abs(liveGot[18 * w + 32][1] - colourLinear.y) < tolerance)
    }

    /// Re-review #2: Gate Weave moves the clip after its masks; the Picture matte stays fixed to the screen anyway.
    @Test func gateWeaveKeepsThePictureMatteFixedToTheScreen() throws {
        let (dev, q, comp) = try #require(setup())
        // 240 px at 1080 = 8 px on this 36 px high canvas.
        let weave = GateWeave(offsetX: 240, offsetY: 0, rotation: 0, maxOffset: 240, maxRotation: 0)
        let fx = ClipEffects(masks: [picture(v2)], look: FilmLook(weave: weave))
        let r = LayerRequest(clip: UUID(), media: UUID(), track: v1, sourceTime: .zero, effects: fx)
        var l = solid(colour)
        l.effects = fx
        let got = try render(comp, dev, q, tree([(r, l), matte(v2, solid((1, 1, 1), scaled(0.5)))]), w, h)
        let row = 18
        for x in [17, 20, 30, 46] { #expect(abs(got[row * w + x][1] - colourLinear.y) < tolerance, "x \(x) not covered") }
        for x in [8, 14, 50, 54] { #expect(got[row * w + x][1] < 0.002, "x \(x) covered") }
    }

    @Test func aHiddenMatteTrackDrawsNothingAndCostsNoPass() throws {
        let (dev, q, comp) = try #require(setup())
        // No consumer reads V2 (its consumer was culled, say): the matte layer is neither drawn nor rendered.
        let plain = try render(comp, dev, q, tree([drawn(v1, solid(colour))]), w, h)
        let before = comp.intermediateAllocations
        let got = try render(comp, dev, q, tree([drawn(v1, solid(colour)), matte(v2, solid((1, 1, 1), scaled(0.5)))]), w, h)
        #expect(got == plain)
        #expect(comp.intermediateAllocations == before)
    }

    @Test func aVisibleMatteTrackIsDrawnExactlyOnce() throws {
        // V2 shown at 50 % opacity and also the matte (its alpha = 0.5 inside the square). Inside: the consumer at 0.5, then
        // the white once at 0.5 over it.
        let (dev, q, comp) = try #require(setup())
        var t = scaled(0.5)
        t.opacity = 0.5
        let white = solid((1, 1, 1), t)
        let got = try render(comp, dev, q, tree([drawn(v1, solid(colour), masks: [picture(v2)]), drawn(v2, white),
                                                 matte(v2, white)]), w, h)
        let inside = got[18 * w + 32], outside = got[2 * w + 2]
        for i in 0..<3 { #expect(abs(inside[i] - (0.25 * colourLinear[i] + 0.5)) < tolerance, "channel \(i): \(inside[i])") }
        #expect(outside[1] < 0.002)
    }

    @Test func twoConsumersShareOnePassAndThePoolReturnsToBaseline() throws {
        let (dev, q, comp) = try #require(setup())
        let one = tree([drawn(v1, solid(colour), masks: [picture(v2)]), matte(v2, solid((1, 1, 1), scaled(0.5)))])
        _ = try render(comp, dev, q, one, w, h)
        let single = comp.intermediateAllocations
        let free = comp.freeIntermediateBytes
        let v3 = UUID()
        let two = tree([drawn(v1, solid(colour), masks: [picture(v2)]),
                        drawn(v3, solid(colour, scaled(0.5)), masks: [picture(v2, inverted: true)]),
                        matte(v2, solid((1, 1, 1), scaled(0.5)))])
        for _ in 0..<100 { _ = try render(comp, dev, q, two, w, h) }
        #expect(comp.intermediateAllocations == single, "\(comp.intermediateAllocations) vs \(single)")
        #expect(comp.freeIntermediateBytes == free)
        #expect(comp.matteTexturesMade == 0)
    }

    @Test func treeKeepsMatteLayersOutOfThePicture() {
        // Safety: a matte request is never a drawn leaf, whatever level it sits on.
        let nodes = tree([drawn(v1, solid(colour), masks: [picture(v2)]), matte(v2, solid((1, 1, 1)))])
        var leaves = 0, mattes = 0
        for n in nodes {
            switch n {
            case .layer: leaves += 1
            case .pictureMatte(let id, let kids): mattes += 1; #expect(id == v2 && kids.count == 1)
            default: break
            }
        }
        #expect(leaves == 1 && mattes == 1)
        var stray = matte(v2, solid((1, 1, 1)))
        stray.0.matteDepth = 3                       // a level that does not exist here
        let only = tree([drawn(v1, solid(colour)), stray])
        #expect(only.count == 1)
    }
}

/// 4K, one matte, two consumers. Run: `SQ_PICTURE_BENCH=1 SQ_TEST_RELEASE=1 SQ_TEST_FILTER=PictureMaskBench scripts/test.sh SQRender`.
@Suite(.serialized) struct PictureMaskBench {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SQ_PICTURE_BENCH"] != nil))
    func fourKOneMatteTwoConsumers() throws {
        let (dev, q, comp) = try #require(setup())
        let w = 3840, h = 2160
        let v1 = UUID(), v2 = UUID(), v3 = UUID()
        let pb = makeBGRA(w, h) { x, y in (UInt8(x % 256), UInt8(y % 256), 128, 255) }
        let frame = RenderLayer(content: .frame(pb, colorHint: info(w, h)))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let t = dev.makeTexture(descriptor: d)!
        func ms(_ nodes: [RenderNode]) throws -> Double {
            var best = Double.infinity
            for _ in 0..<12 {
                let cb = q.makeCommandBuffer()!
                try comp.render(nodes: nodes, format: fmt(w, h), into: t, commandBuffer: cb)
                cb.commit(); cb.waitUntilCompleted()
                best = min(best, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            return best
        }
        let plain = try ms(tree([drawn(v1, frame), drawn(v3, solid(colour, scaled(0.5)))]))
        let masked = try ms(tree([drawn(v1, frame, masks: [picture(v2, channel: .brightness)]),
                                  drawn(v3, solid(colour, scaled(0.5)), masks: [picture(v2)]),
                                  matte(v2, solid((1, 1, 1), scaled(0.5)))]))
        let line = String(format: "PictureMaskBench 4K: plain %.2f ms, one matte + two consumers %.2f ms (+%.2f)\n", plain, masked, masked - plain)
        print(line)
        let out = ProcessInfo.processInfo.environment["SQ_PERF_OUT"] ?? NSTemporaryDirectory() + "sqpicturemask.txt"
        try? line.write(toFile: out, atomically: true, encoding: .utf8)
    }
}
#endif
