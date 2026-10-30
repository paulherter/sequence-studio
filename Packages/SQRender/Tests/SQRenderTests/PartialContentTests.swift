#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import SQFrameCoreVideo
import Testing
@testable import SQRender

// `RenderLayer.contentPart` (ENGINE-NOTES "Animated captions"): a linear raster cut to what is painted, drawn as the
// whole picture. The composite is bit for bit the one of the whole buffer, whatever reads the layer's rectangle
// (corner radius, blur, crop, masks, blend mode, scale and rotation), both when the part is sampled in place (the
// default, `drawsContentPartsDirectly`) and when the whole picture is made first (the switch off: the reference).

private let (cw, ch) = (96, 64)          // canvas
private let (bw, bh) = (80, 48)          // whole raster
private let (px, py, pw, ph) = (22, 9, 31, 17)   // the painted part

private func half(_ w: Int, _ h: Int, _ value: (Int, Int) -> SIMD4<Float>) -> CVPixelBuffer {
    let attrs = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as [CFString: Any]
    var pb: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &pb) == kCVReturnSuccess)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    defer { CVPixelBufferUnlockBaseAddress(b, []) }
    let base = CVPixelBufferGetBaseAddress(b)!, stride = CVPixelBufferGetBytesPerRow(b)
    for y in 0..<h {
        let row = (base + y * stride).assumingMemoryBound(to: Float16.self)
        for x in 0..<w {
            let v = value(x, y)
            for c in 0..<4 { row[x * 4 + c] = Float16(v[c]) }
        }
    }
    return b
}

/// Premultiplied picture inside the rectangle (soft alpha, different in every texel), transparent elsewhere.
private func texel(_ x: Int, _ y: Int, in r: (x: Int, y: Int, w: Int, h: Int)) -> SIMD4<Float> {
    guard x >= r.x, y >= r.y, x < r.x + r.w, y < r.y + r.h else { return .zero }
    let a = 0.25 + 0.75 * Float((x * 7 + y * 13) % 17) / 16
    return SIMD4(a * Float(x - r.x) / Float(r.w), a * Float(y - r.y) / Float(r.h), a * 0.6, a)
}

private func fmt(_ w: Int = cw, _ h: Int = ch) -> SequenceFormat { SequenceFormat(width: w, height: h, frameDuration: Time(1, 25)) }

private func render(_ comp: Compositor, _ dev: MTLDevice, _ q: MTLCommandQueue, _ nodes: [RenderNode],
                    width: Int = cw, height: Int = ch) throws -> [Float16] {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let t = dev.makeTexture(descriptor: d)!
    let cb = q.makeCommandBuffer()!
    try comp.render(nodes: nodes, format: fmt(width, height), into: t, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()
    #expect(cb.error == nil)
    var out = [Float16](repeating: 0, count: width * height * 4)
    t.getBytes(&out, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return out
}

@Suite struct PartialContentTests {
    typealias Rect = (x: Int, y: Int, w: Int, h: Int)
    static let inner: Rect = (px, py, pw, ph)

    /// The same layer with the whole buffer and with the part of it at `r`.
    private func layers(part r: Rect = PartialContentTests.inner, whole: (w: Int, h: Int) = (bw, bh),
                        _ change: (inout RenderLayer) -> Void) -> (whole: RenderLayer, part: RenderLayer) {
        var a = RenderLayer(content: .linearPremultiplied(half(whole.w, whole.h) { texel($0, $1, in: r) },
                                                          width: Double(whole.w), height: Double(whole.h)))
        change(&a)
        var b = a
        b.content = .linearPremultiplied(half(r.w, r.h) { texel($0 + r.x, $1 + r.y, in: r) }, width: Double(whole.w), height: Double(whole.h))
        b.contentPart = RenderLayer.ContentPart(x: r.x, y: r.y, wholeWidth: whole.w, wholeHeight: whole.h)
        return (a, b)
    }

    private static let background = RenderNode.layer(RenderLayer.solid(payload: Data([40, 90, 160])))

    private static var cases: [(String, (inout RenderLayer) -> Void)] {
        var blur = ClipEffects(); blur.blur = 5
        var crop = ClipEffects(); crop.pre = EffectMasks(crop: CropInsets(left: 0.35, top: 0.1, right: 0.2, bottom: 0.3))
        var masked = ClipEffects()
        masked.masks = [MaskShape(polygon: [Vec2(0.2, 0.1), Vec2(0.7, 0), Vec2(0.65, 0.9), Vec2(0.25, 1)], feather: 4)]
        var look = ClipEffects(); look.look.grain = FilmLook.Grain(amount: 0.4, size: 2, softness: 0.3, lumaWeight: 0.5, seed: 7)
        return [
            ("plain", { _ in }),
            ("opacity on whole pixels", { l in l.transform.position = Vec2(5, -3); l.transform.opacity = 0.35 }),
            ("moved, scaled, rotated", { l in
                l.transform.position = Vec2(3.5, -2.25); l.transform.scale = Vec2(1.3, 0.85)
                l.transform.rotation = 19; l.transform.anchor = Vec2(7, -4); l.transform.opacity = 0.8
            }),
            ("scaled down", { l in l.transform.scale = Vec2(0.37, 0.61); l.transform.rotation = -41 }),
            ("corner radius", { l in l.cornerRadius = 14; l.transform.scale = Vec2(1.1, 1.1) }),
            ("blur", { l in l.effects = blur; l.transform.rotation = -8 }),
            ("crop", { l in l.effects = crop }),
            ("mask", { l in l.effects = masked; l.transform.rotation = 11; l.transform.scale = Vec2(1.2, 1.2) }),
            ("film look", { l in l.effects = look; l.transform.scale = Vec2(1.15, 0.9) }),
            ("blend mode", { l in l.blendMode = .screen; l.transform.position = Vec2(-4, 3) }),
            ("blend mode, opacity, scaled and rotated", { l in
                l.blendMode = .overlay; l.transform.opacity = 0.6; l.transform.scale = Vec2(1.4, 1.25); l.transform.rotation = 33
            }),
            ("blur, radius and blend mode", { l in l.effects = blur; l.cornerRadius = 9; l.blendMode = .multiply }),
        ]
    }

    /// Where the part lies in the whole picture: inside, in a corner, along an edge (clamp to edge of the whole picture
    /// under magnification), and the whole of it.
    private static let places: [(String, Rect)] = [
        ("inside", inner), ("top-left corner", (0, 0, pw, ph)), ("bottom-right corner", (bw - pw, bh - ph, pw, ph)),
        ("full width", (0, 20, bw, 11)), ("everything", (0, 0, bw, bh)),
    ]

    @Test func aPartDrawnAsTheWholeIsTheSamePictureBitForBit() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        for (place, r) in Self.places {
            for (name, change) in Self.cases {
                let comp = try Compositor(device: dev)
                #expect(comp.drawsContentPartsDirectly, "parts are read in place by default")
                let l = layers(part: r, change)
                let a = try render(comp, dev, q, [Self.background, .layer(l.whole)])
                #expect(comp.partialContentFills == 0 && comp.partialContentDraws == 0)
                // The reference: the whole picture made first.
                comp.drawsContentPartsDirectly = false
                let c = try render(comp, dev, q, [Self.background, .layer(l.part)])
                #expect(comp.partialContentFills == 1 && comp.partialContentDraws == 0, "\(name), \(place)")
                #expect(a == c, "\(name), \(place): a part copied into the whole picture differs from the whole buffer")
                // The default, in place: no whole picture is made (no clear, no copy), no texture is taken for one.
                comp.drawsContentPartsDirectly = true
                let allocations = comp.intermediateAllocations
                let b = try render(comp, dev, q, [Self.background, .layer(l.part)])
                #expect(comp.partialContentFills == 1 && comp.partialContentDraws == 1, "\(name), \(place)")
                #expect(comp.intermediateAllocations == allocations, "\(name), \(place): the part took a texture of its own")
                #expect(a == b, "\(name), \(place): a part sampled in place differs from the whole buffer")
                // The picture is there at all (not two equal empty frames).
                #expect(a != (try render(comp, dev, q, [Self.background])), "\(name) draws nothing")
            }
        }
    }

    /// A 4K box (texel coordinates in the thousands, where single precision has the fewest bits left for the filter
    /// weights) scaled and rotated off the pixel grid: still the whole buffer's picture bit for bit.
    @Test func aPartOfA4KBoxIsTheSamePictureBitForBit() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let (w, h) = (3840, 2160)
        let r: Rect = (2903, 1711, 613, 291)
        let comp = try Compositor(device: dev)
        for (name, change) in [
            ("scaled and rotated", { (l: inout RenderLayer) in
                l.transform.position = Vec2(-611.3, -402.7); l.transform.scale = Vec2(1.31, 0.87); l.transform.rotation = 17
            }),
            ("blend mode, sub-pixel", { (l: inout RenderLayer) in
                l.blendMode = .screen; l.transform.position = Vec2(0.37, -0.61); l.transform.opacity = 0.7
            }),
        ] {
            let l = layers(part: r, whole: (w, h), change)
            let a = try render(comp, dev, q, [Self.background, .layer(l.whole)], width: w, height: h)
            let fills = comp.partialContentFills
            let b = try render(comp, dev, q, [Self.background, .layer(l.part)], width: w, height: h)
            #expect(comp.partialContentFills == fills)
            var worst: Float = 0, differing = 0
            for i in a.indices where a[i] != b[i] { worst = max(worst, abs(Float(a[i]) - Float(b[i]))); differing += 1 }
            print("PERF part in place vs whole buffer, 4K box, \(name): \(differing) values differ, max \(worst)")
            #expect(differing == 0, "\(name): \(differing) values differ, by up to \(worst)")
            #expect(a != (try render(comp, dev, q, [Self.background], width: w, height: h)), "\(name) draws nothing")
        }
    }

    /// With whole pictures made first: a pooled texture comes back with the last picture in it, every fill starts from
    /// a cleared one.
    @Test func theWholePictureIsClearedBeforeEveryFill() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        comp.drawsContentPartsDirectly = false
        let l = layers { _ in }
        let reference = try render(comp, dev, q, [Self.background, .layer(l.whole)])
        // Another part of the same whole size first, elsewhere in the picture: its texture goes back to the pool.
        var other = l.part
        other.content = .linearPremultiplied(half(pw, ph) { _, _ in SIMD4(1, 1, 1, 1) }, width: Double(bw), height: Double(bh))
        other.contentPart = RenderLayer.ContentPart(x: 0, y: bh - ph, wholeWidth: bw, wholeHeight: bh)
        _ = try render(comp, dev, q, [Self.background, .layer(other)])
        let allocations = comp.intermediateAllocations
        #expect(try render(comp, dev, q, [Self.background, .layer(l.part)]) == reference)
        #expect(comp.intermediateAllocations == allocations, "the whole picture was not taken from the pool")
    }

    /// The copies of a motion-blurred layer (the same buffer several times in one render): the same picture, and with
    /// whole pictures made first they share one.
    @Test func copiesOfOneBufferShareOneWholePicture() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        comp.drawsContentPartsDirectly = false
        func copies(_ l: RenderLayer) -> [RenderNode] {
            [Self.background] + (0..<4).map { k in
                var c = l
                c.transform.position = Vec2(Double(k) * 2.5, 0); c.transform.opacity = 0.25
                return .layer(c)
            }
        }
        let l = layers { _ in }
        let a = try render(comp, dev, q, copies(l.whole))
        #expect(a == (try render(comp, dev, q, copies(l.part))))
        #expect(comp.partialContentFills == 1 && comp.partialContentDraws == 0)
        comp.drawsContentPartsDirectly = true   // read in place: no whole picture at all
        #expect(a == (try render(comp, dev, q, copies(l.part))))
        #expect(comp.partialContentFills == 1 && comp.partialContentDraws == 4)
    }

    /// A plain part is drawn only where it can show (`Compositor.partBounds`): the layers after it still cover the
    /// whole canvas, and a part moved off the canvas (partly or all of it) is the whole buffer's picture too.
    @Test func aPlainPartLimitsOnlyItsOwnDraw() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        var veil = RenderLayer.solid(payload: Data([200, 30, 60])); veil.transform.opacity = 0.4
        for (name, position) in [("inside", Vec2(2.5, 1.25)), ("over the left edge", Vec2(-38.5, 3)), ("off the canvas", Vec2(400, -300))] {
            let l = layers { $0.transform.position = position; $0.transform.rotation = 23; $0.transform.scale = Vec2(1.2, 0.9) }
            let a = try render(comp, dev, q, [Self.background, .layer(l.whole), .layer(veil), .layer(l.whole)])
            let draws = comp.partialContentDraws
            let b = try render(comp, dev, q, [Self.background, .layer(l.part), .layer(veil), .layer(l.part)])
            #expect(comp.partialContentDraws == draws + 2 && comp.partialContentFills == 0)
            #expect(a == b, "\(name): differs from the whole buffer")
        }
        // The bounds hold the part and nothing like the whole box: an unscaled layer in the canvas center.
        let cp = RenderLayer.ContentPart(x: px, y: py, wholeWidth: bw, wholeHeight: bh)
        let bounds = try #require(Compositor.partBounds(cp, width: pw, height: ph, size: SIMD2(Double(bw), Double(bh)),
                                                        transform: .identity, canvas: fmt()))
        let x0 = Double((cw - bw) / 2 + px), y0 = Double((ch - bh) / 2 + py)
        #expect(bounds.minX * Double(cw) == x0 - 1 && bounds.maxX * Double(cw) == x0 + Double(pw) + 1)
        #expect(bounds.minY * Double(ch) == y0 - 1 && bounds.maxY * Double(ch) == y0 + Double(ph) + 1)
    }

    /// A part that does not lie inside the whole picture is drawn as damaged, never read out of bounds.
    @Test(arguments: [true, false]) func aPartOutsideTheWholeIsRefused(_ direct: Bool) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        comp.drawsContentPartsDirectly = direct
        var l = layers { _ in }.part
        l.contentPart = RenderLayer.ContentPart(x: bw - 4, y: 0, wholeWidth: bw, wholeHeight: bh)
        _ = try render(comp, dev, q, [.layer(l)])
        #expect(comp.partialContentFills == 0 && comp.partialContentDraws == 0)
        #expect(comp.unsupportedFrameCount == 1)
    }

    /// A turned plain part is drawn in strips that follow it (`Compositor.partScissors`): they hold every point of the
    /// part, never overlap (a pixel in two of them would be blended twice) and are far fewer pixels than the bounding
    /// box. An upright part stays one rectangle, its bounding box.
    @Test func aTurnedPartIsDrawnInStripsThatNeverOverlap() throws {
        let (w, h) = (3840, 2160)
        let cp = RenderLayer.ContentPart(x: 1200, y: 900, wholeWidth: w, wholeHeight: h)
        func corners(_ rotation: Double, _ scale: Vec2 = Vec2(1.3, 0.85)) throws -> [SIMD2<Double>] {
            var t = ClipTransform.identity
            t.scale = scale; t.rotation = rotation
            return try #require(Compositor.partCorners(cp, width: 1400, height: 420, size: SIMD2(Double(w), Double(h)),
                                                       transform: t, canvas: fmt(w, h)))
        }
        func area(_ r: [MTLScissorRect]) -> Int { r.reduce(0) { $0 + $1.width * $1.height } }
        for rotation in [19.0, -41, 90, 133, 3, 71, -88.5] {
            let q = try corners(rotation)
            let box = Compositor.partScissors(q, width: w, height: h, bands: 1)
            let rects = Compositor.partScissors(q, width: w, height: h)
            #expect(box.count == 1 && rects.count <= Compositor.partBandLimit)
            for (i, a) in rects.enumerated() {
                #expect(a.x >= 0 && a.y >= 0 && a.x + a.width <= w && a.y + a.height <= h, "\(rotation): outside the target")
                for b in rects[(i + 1)...] {
                    let apart = a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y
                    #expect(apart, "\(rotation): two strips overlap")
                }
            }
            // Every point of the quad that is on the target lies in a strip, with the pixel around it.
            var missed = 0
            for i in 0...200 {
                for j in 0...60 {
                    let (u, v) = (Double(i) / 200, Double(j) / 60)
                    let top = q[0] + (q[1] - q[0]) * u, bottom = q[3] + (q[2] - q[3]) * u
                    let pt = (top + (bottom - top) * v) * SIMD2(Double(w), Double(h))
                    guard pt.x >= 0, pt.y >= 0, pt.x < Double(w), pt.y < Double(h) else { continue }
                    let (x, y) = (Int(pt.x), Int(pt.y))
                    if !rects.contains(where: { x >= $0.x && y >= $0.y && x < $0.x + $0.width && y < $0.y + $0.height }) { missed += 1 }
                }
            }
            #expect(missed == 0, "\(rotation): \(missed) points of the part are in no strip")
            #expect(area(rects) <= area(box))
            if rotation == 19 {
                let part = 1402.0 * 1.3 * 422 * 0.85
                print("PERF 4K plain text part turned by 19 degrees, pixels the draw is limited to: bounding box \(area(box)) "
                    + "(\(String(format: "%.2f", Double(area(box)) / part))x the part) | \(rects.count) strips \(area(rects)) "
                    + "(\(String(format: "%.2f", Double(area(rects)) / part))x)")
                #expect(Double(area(rects)) < part * 1.25 && area(rects) * 2 < area(box))
            }
        }
        let upright = try corners(0)
        #expect(Compositor.partScissors(upright, width: w, height: h).count == 1)
        #expect(area(Compositor.partScissors(upright, width: w, height: h)) == area(Compositor.partScissors(upright, width: w, height: h, bands: 1)))
        // Off the target: nothing to draw.
        #expect(Compositor.partScissors(upright.map { $0 + SIMD2(3, 0) }, width: w, height: h).isEmpty)
    }

    /// Strips and the bounding box give the same picture (the same quad, fewer fragments outside the part).
    @Test func stripsAndTheBoundingBoxAreTheSamePicture() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let (w, h) = (1920, 1080)
        let comp = try Compositor(device: dev)
        for rotation in [19.0, -63, 90] {
            let l = layers(part: (700, 420, 700, 210), whole: (w, h)) {
                $0.transform.scale = Vec2(1.3, 0.85); $0.transform.rotation = rotation; $0.transform.opacity = 0.7
            }
            let a = try render(comp, dev, q, [Self.background, .layer(l.whole)], width: w, height: h)
            comp.partBands = 1
            let b = try render(comp, dev, q, [Self.background, .layer(l.part)], width: w, height: h)
            comp.partBands = Compositor.partBandLimit
            let c = try render(comp, dev, q, [Self.background, .layer(l.part)], width: w, height: h)
            #expect(a == b, "\(rotation): the bounding box differs from the whole buffer")
            #expect(a == c, "\(rotation): strips differ from the whole buffer")
        }
    }

    /// The check a GPU other than Apple's has to pass before parts are read in place (`CompositorPartCheck`): it
    /// passes here, with a shared target and with a managed one (what a GPU with memory of its own gets), and finds a
    /// read that is a quarter texel off.
    @Test func thePartReadCheckPassesAndFindsAShiftedRead() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { return }
        for managed in [false, true] {
            let start = Date()
            #expect(Compositor.partReadMatchesCopy(device: dev, managed: managed) == true,
                    "this GPU does not read a part in place with the bits of the whole picture (managed target: \(managed))")
            print("PERF part read check, \(managed ? "managed" : "shared") target, a compositor of its own and 20 small frames: "
                + String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000))
        }
        for skew in [SIMD2<Float>(0.25, 0), SIMD2<Float>(0, -0.25), SIMD2<Float>(1, 0)] {
            #expect(Compositor.partReadMatchesCopy(device: dev, skew: skew) == false, "a read off by \(skew) texels passes the check")
        }
    }

    /// The check draws on a compositor of its own: the one that asks keeps its remembered plane textures, its render
    /// count (what the plane memo ages by), its pools and its counters, and the next frame finds its textures made.
    @Test func theCheckLeavesTheAskingCompositorAsItWas() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        comp.remembersPlaneTextures = true
        comp.partReadLedger = PartReadLedger()
        comp.partRead = .unchecked
        let l = layers { $0.transform.scale = Vec2(1.3, 0.85); $0.transform.rotation = 19 }
        guard case .linearPremultiplied(let pb, _, _) = l.part.content else { return }
        let whole = try render(comp, dev, q, [Self.background, .layer(l.whole)])
        #expect(try render(comp, dev, q, [Self.background, .layer(l.part)]) == whole)
        #expect(comp.partCheckWanted && comp.remembersPlanes(of: pb.pixelBuffer))
        func state() -> [UInt64] {
            comp.planeCountersForTests + [comp.rememberedPlaneCount, comp.planeTextureCreates, comp.intermediateAllocations,
                                          comp.partialContentFills, comp.partialContentDraws, comp.unsupportedFrameCount].map { UInt64($0) }
        }
        let before = state()
        comp.settlePartRead()
        #expect(comp.partRead == .trusted && !comp.partCheckWanted, "the check did not run or did not pass")
        #expect(state() == before, "the check moved the asking compositor's plane memo or counters")
        #expect(comp.remembersPlanes(of: pb.pixelBuffer) && comp.drawsContentPartsDirectly && comp.partReadSkew == .zero)
        // The next frame: one render later for the memo, the part's texture is the remembered one, read in place.
        #expect(try render(comp, dev, q, [Self.background, .layer(l.part)]) == whole)
        let after = comp.planeCountersForTests
        #expect(after[0] == before[0] + 1 && after[1] == before[1], "the frame after the check made its plane textures again")
        #expect(comp.partialContentFills == 1 && comp.partialContentDraws == 1)
    }

    /// A GPU that has not been asked yet: the first frame with a part is drawn by copy, the check runs before the
    /// next one, and from then on parts are read in place. A GPU that fails it keeps copying. Always the whole buffer's
    /// picture.
    @Test(arguments: [false, true]) func anUncheckedGPUCopiesUntilTheCheckPassed(_ fails: Bool) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        let l = layers { $0.transform.scale = Vec2(1.3, 0.85); $0.transform.rotation = 19 }
        let whole = try render(comp, dev, q, [Self.background, .layer(l.whole)])
        comp.partReadLedger = PartReadLedger()
        comp.partRead = .unchecked
        if fails { comp.partReadSkew = SIMD2(0.25, 0) }
        #expect(try render(comp, dev, q, [Self.background, .layer(l.whole)]) == whole)
        #expect(comp.partRead == .unchecked && !comp.partCheckWanted, "a frame without a part asks for the check")
        #expect(try render(comp, dev, q, [Self.background, .layer(l.part)]) == whole)
        #expect(comp.partialContentFills == 1 && comp.partialContentDraws == 0, "the first part was not copied")
        #expect(comp.partRead == .unchecked && comp.partCheckWanted)
        #expect(try render(comp, dev, q, [Self.background, .layer(l.part)]) == whole)
        #expect(comp.partRead == (fails ? .refused : .trusted) && !comp.partCheckWanted)
        #expect(comp.partialContentFills == (fails ? 2 : 1) && comp.partialContentDraws == (fails ? 0 : 1))
        #expect(try render(comp, dev, q, [Self.background, .layer(l.part)]) == whole)
        #expect(comp.partialContentFills == (fails ? 3 : 1) && comp.partialContentDraws == (fails ? 0 : 2))
        #expect(comp.partReadLedger.answer(dev.registryID) == !fails)
        #expect(comp.partReadLedger !== Compositor.sharedPartReadLedger)
    }

    /// A check that could not be made (no queue, no texture, a failed command buffer) is no answer: parts stay copied,
    /// the check is tried again `partCheckRetryRenders` part frames later, and the third such run in all is a no. The
    /// answer, once there, holds for every compositor on that GPU without another run.
    @Test(arguments: [1, 2, 3]) func aCheckThatCouldNotBeMadeIsTriedAgain(_ failures: Int) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let comp = try Compositor(device: dev)
        let ledger = PartReadLedger()
        comp.partReadLedger = ledger
        let l = layers { $0.transform.scale = Vec2(1.3, 0.85); $0.transform.rotation = 19 }
        let whole = try render(comp, dev, q, [Self.background, .layer(l.whole)])
        comp.partRead = .unchecked
        var runs = 0
        comp.partCheckRunner = { runs += 1; return runs <= failures ? nil : true }
        // Frame 0 is copied and asks; run k is made before frame 1 + (k - 1) * (partCheckRetryRenders + 1).
        let step = Compositor.partCheckRetryRenders + 1
        let passes = failures < Compositor.partCheckAttempts
        let settled = 1 + step * (passes ? failures : Compositor.partCheckAttempts - 1)
        let frames = 1 + step * Compositor.partCheckAttempts + 4
        for frame in 0..<frames {
            #expect(try render(comp, dev, q, [Self.background, .layer(l.part)]) == whole, "frame \(frame)")
            if frame == settled - 1 { #expect(comp.partRead == .unchecked && ledger.answer(dev.registryID) == nil) }
        }
        #expect(runs == min(failures + 1, Compositor.partCheckAttempts), "\(runs) runs of the check")
        #expect(comp.partRead == (passes ? .trusted : .refused) && ledger.answer(dev.registryID) == passes)
        #expect(comp.partialContentFills == (passes ? settled : frames) && comp.partialContentDraws == (passes ? frames - settled : 0))
        let other = try Compositor(device: dev)
        other.partReadLedger = ledger
        other.partRead = .unchecked
        other.partCheckRunner = { runs += 100; return nil }
        for _ in 0..<2 { #expect(try render(other, dev, q, [Self.background, .layer(l.part)]) == whole) }
        #expect(other.partRead == comp.partRead && runs < 100, "a second compositor ran the check again")
    }

    /// The counts of a compositor that drew `frames` frames with one part each: all read in place where the GPU reads
    /// a part with the whole picture's bits (asked here first, so no frame is copied while waiting for the answer),
    /// all copied where it does not.
    private func expectParts(_ comp: Compositor, frames: Int, _ name: String) {
        let inPlace = comp.partRead == .trusted
        #expect(comp.partialContentDraws == (inPlace ? frames : 0) && comp.partialContentFills == (inPlace ? 0 : frames),
                "\(name): \(comp.partialContentDraws) in place, \(comp.partialContentFills) copied of \(frames), in place \(inPlace)")
    }

    /// What the in-place draw saves on a 4K box: one clear and one copy of the whole box per frame. GPU time of the
    /// command buffer, printed; the ways take turns frame by frame on warm compositors (`turns`), so a load that comes
    /// and goes hits them alike. Asserted: the counts only. No time is asserted: the GPU's clock swings by more than the
    /// difference while other GPU tests run (read the PERF lines of a run on a quiet machine).
    @Test func partInPlaceCostOnA4KBox() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let (w, h) = (3840, 2160)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let target = dev.makeTexture(descriptor: d)!
        var blur = ClipEffects(); blur.blur = 12
        let cases: [(String, (inout RenderLayer) -> Void)] = [
            ("blend mode", { $0.blendMode = .screen }), ("blur", { $0.effects = blur }), ("corner radius", { $0.cornerRadius = 120 }),
        ]
        for (name, change) in cases {
            let l = layers(part: (1200, 900, 1400, 420), whole: (w, h), change)
            let nodes = [Self.background, RenderNode.layer(l.part)]
            let comps = [try Compositor(device: dev), try Compositor(device: dev)]   // 0: whole picture first, 1: in place
            comps[0].drawsContentPartsDirectly = false
            comps[1].settlePartRead()
            let t = try turns(q, target, [(comps[0], nodes), (comps[1], nodes)])
            print("PERF 4K text part with a \(name), GPU ms per frame, \(t.pairs) frames in turn: whole picture first median "
                + "\(t.text[0]) | in place median \(t.text[1]) | in place faster in \(t.wins(1, 0))/\(t.pairs)")
            #expect(comps[0].partialContentFills == t.frames && comps[0].partialContentDraws == 0, "\(name)")
            expectParts(comps[1], frames: t.frames, name)
        }
    }

    /// A plain part (nothing reads its rectangle) is drawn with the whole box's quad, limited to where the part can
    /// show: the GPU time against a layer of the part's own size (how it was drawn before parts) and, turned, against
    /// the limit being the part's bounding box (2.6 times the part at 19 degrees) instead of strips along it. Printed,
    /// not asserted (see `partInPlaceCostOnA4KBox`); that strips are fewer pixels is `aTurnedPartIsDrawnInStripsThatNeverOverlap`.
    @Test func aPlainPartCostsLikeALayerOfItsOwnSize() throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return }
        let (w, h) = (3840, 2160)
        let r: Rect = (1200, 900, 1400, 420)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        let target = dev.makeTexture(descriptor: d)!
        for (name, rotation) in [("scaled", 0.0), ("scaled and rotated", 19.0)] {
            let l = layers(part: r, whole: (w, h)) { $0.transform.scale = Vec2(1.3, 0.85); $0.transform.rotation = rotation }
            // The part as a layer of its own size, its center where it lies in the box (anchor: the box center).
            var own = l.part
            own.contentPart = nil
            if case .linearPremultiplied(let pb, _, _) = own.content {
                own.content = .linearPremultiplied(pb, width: Double(r.w), height: Double(r.h))
            }
            own.transform.anchor = Vec2(Double(w) / 2 - Double(r.x) - Double(r.w) / 2, Double(h) / 2 - Double(r.y) - Double(r.h) / 2)
            let comps = [try Compositor(device: dev), try Compositor(device: dev), try Compositor(device: dev)]
            comps[1].partBands = 1
            for c in comps { c.settlePartRead() }
            let part = [Self.background, RenderNode.layer(l.part)]
            let t = try turns(q, target, [(comps[0], [Self.background, .layer(own)]), (comps[1], part), (comps[2], part)])
            print("PERF 4K plain part, \(name), GPU ms: own-size layer \(t.text[0]) | bounding box \(t.text[1]) | strips \(t.text[2])")
            print("PERF 4K plain part, \(name), of \(t.pairs) turns: strips faster than the own-size layer in \(t.wins(2, 0)), "
                + "than the bounding box in \(t.wins(2, 1))")
            #expect(comps[0].partialContentDraws == 0 && comps[0].partialContentFills == 0)
            expectParts(comps[1], frames: t.frames, name + ", bounding box")
            expectParts(comps[2], frames: t.frames, name + ", strips")
        }
    }
}

/// GPU time of several ways to draw a 4K frame, taking turns frame by frame on warm compositors (the order turns
/// round every frame, so no way always follows the same one): per way "median (fastest)" in ms and, with `wins(a, b)`,
/// in how many of the turns way a was faster than way b (the GPU changes its clock under load: both frames of a turn
/// see the same one, two medians or two fastest frames need not). `frames`: frames drawn per way. 36 frames per way:
/// the ways are compared with each other inside one turn, which needs far fewer frames than a steady median does.
private func turns(_ q: MTLCommandQueue, _ target: MTLTexture, _ ways: [(Compositor, [RenderNode])])
    throws -> (text: [String], wins: (Int, Int) -> Int, pairs: Int, frames: Int) {
    let (warm, pairs) = (4, 32)
    func frame(_ k: Int) throws -> Double {
        let cb = q.makeCommandBuffer()!
        try ways[k].0.render(nodes: ways[k].1, format: fmt(target.width, target.height), into: target, commandBuffer: cb)
        cb.commit(); cb.waitUntilCompleted()
        return (cb.gpuEndTime - cb.gpuStartTime) * 1000
    }
    for k in ways.indices { for _ in 0..<warm { _ = try frame(k) } }   // pools, pipelines and the plane memo warm
    var all = [[Double]](repeating: [], count: ways.count)
    for turn in 0..<pairs {
        for i in ways.indices {
            let k = (i + turn) % ways.count
            all[k].append(try frame(k))
        }
    }
    func text(_ v: [Double]) -> String { String(format: "%.2f (fastest %.2f)", v.sorted()[v.count / 2], v.min() ?? 0) }
    let times = all
    return (all.map(text), { a, b in (0..<pairs).count { times[a][$0] < times[b][$0] } }, pairs, warm + pairs)
}
#endif
