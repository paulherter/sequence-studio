#if canImport(Metal)
import CoreVideo
import Foundation
import Metal
import SQCore
import SQFrame
import SQFrameCoreVideo
import SQGPU
import SQGPUKernels
import SQGPUMetal
import Testing
@testable import SQRender

// The portable GPUCompositor (the Windows engine path) against the Metal Compositor on the same render trees: both run
// the same Slang draws on Metal here, so every pixel must agree within 1/255 (blend modes go through the destination copy
// on the portable path, through framebuffer fetch on the Metal one).

private let W = 96, H = 64
private let fmt = SequenceFormat(width: W, height: H, frameDuration: Time(1, 25))

private func bgra(_ w: Int, _ h: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CVPixelBuffer {
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

private func hint(_ w: Int, _ h: Int) -> VideoTrackInfo {
    VideoTrackInfo(width: w, height: h, codec: "hvc1", bitDepth: 8, chroma: "4:2:0",
                   nominalFrameDuration: Time(1, 25), isVariableFrameRate: false)
}

private func picture(_ w: Int, _ h: Int, seed: Int) -> RenderLayer {
    let pb = bgra(w, h) { x, y in
        (UInt8((x * 7 + seed * 40) % 256), UInt8((y * 11 + seed * 13) % 256), UInt8((x * y + seed) % 256), 255)
    }
    return RenderLayer(content: .frame(pb, colorHint: hint(w, h)))
}

private func target(_ d: MTLDevice) -> MTLTexture {
    let t = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: W, height: H, mipmapped: false)
    t.usage = [.renderTarget, .shaderRead]; t.storageMode = .shared
    return d.makeTexture(descriptor: t)!
}

private func readAll(_ t: MTLTexture) -> [Float] {
    var px = [Float16](repeating: 0, count: t.width * t.height * 4)
    t.getBytes(&px, bytesPerRow: t.width * 8, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
    return px.map { Float($0) }
}

/// A BGRA CVPixelBuffer as a bgra8Unorm texture (what the Metal compositor samples), for the portable path.
private func planes(_ d: MTLDevice, _ frame: SQFrame) -> GPUCompositor<MetalGPUDevice>.Picture? {
    let pb = frame.pixelBuffer
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    td.usage = .shaderRead
    guard let t = d.makeTexture(descriptor: td) else { return nil }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: CVPixelBufferGetBaseAddress(pb)!,
              bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
    return .init(rgba: MetalGPUTexture(t), alphaMode: 0)
}

private func compare(_ name: String, _ nodes: [RenderNode]) throws {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { return }
    let metal = try Compositor(device: d)
    let a = target(d), b = target(d)
    let cb = q.makeCommandBuffer()!
    try metal.render(nodes: nodes, format: fmt, into: a, commandBuffer: cb)
    cb.commit(); cb.waitUntilCompleted()

    let gpu = try MetalGPUDevice(device: d)
    let portable = try GPUCompositor(device: gpu)
    let pcb = try #require(gpu.makeCommandBuffer())
    try portable.render(nodes: nodes, format: fmt, into: MetalGPUTexture(b), commandBuffer: pcb) { planes(d, $0) }
    gpu.commitAndWait(pcb)
    #expect(portable.unsupportedFrameCount == 0)

    let x = readAll(a), y = readAll(b)
    var worst: Float = 0, at = 0
    for i in x.indices where abs(x[i] - y[i]) > worst { worst = abs(x[i] - y[i]); at = i }
    let lit = stride(from: 3, to: y.count, by: 4).filter { y[$0] > 0 }.count
    #expect(worst <= 1 / 255, "\(name): max difference \(worst) at pixel \(at / 4) channel \(at % 4)")
    #expect(lit > 0, "\(name): nothing drawn")
}

@Suite struct GPUCompositorParityTests {
    @Test func transformedPicturesAndSolidsMatchTheMetalCompositor() throws {
        var a = picture(80, 48, seed: 1)
        a.transform.scale = Vec2(1.1, 0.9); a.transform.rotation = 12; a.transform.position = Vec2(50, 30)
        a.transform.opacity = 0.85; a.cornerRadius = 6
        var s = RenderLayer(content: .solid(red: 0.8, green: 0.3, blue: 0.1))
        s.transform.scale = Vec2(0.4, 0.5); s.transform.position = Vec2(30, 40); s.transform.opacity = 0.6
        try compare("pictures", [.layer(picture(96, 64, seed: 2)), .layer(a), .layer(s)])
    }

    /// Parity sweep: every blend mode the Mac offers.
    @Test(arguments: BlendMode.allCases)
    func blendModesThroughTheDestinationCopyMatchFramebufferFetch(mode: BlendMode) throws {
        var top = picture(64, 40, seed: 3)
        top.transform.position = Vec2(52, 30); top.transform.rotation = -8
        top.blendMode = mode
        var s = RenderLayer(content: .solid(red: 0.2, green: 0.7, blue: 0.9), blendMode: mode)
        s.transform.scale = Vec2(0.3, 0.3); s.transform.position = Vec2(20, 20)
        try compare("blend \(mode)", [.layer(picture(96, 64, seed: 4)), .layer(top), .layer(s)])
    }

    @Test func nestedGroupsStencilsAndPairsMatchTheMetalCompositor() throws {
        let inner = SequenceFormat(width: 48, height: 32, frameDuration: Time(1, 25))
        var t = ClipTransform.identity
        t.position = Vec2(60, 26); t.scale = Vec2(1.2, 1.2); t.rotation = 20
        var solid = RenderLayer(content: .solid(red: 1, green: 1, blue: 1))
        solid.transform.scale = Vec2(0.5, 0.5)
        try compare("tree", [
            .layer(picture(96, 64, seed: 5)),
            .group(format: inner, transform: t, opacity: 0.7, cornerRadius: 4, children: [.layer(picture(48, 32, seed: 6))]),
            .styledGroup(format: inner, transform: .identity, opacity: 1, cornerRadius: 0,
                         children: [.layer(picture(40, 30, seed: 7))], effects: .none, blendMode: .screen),
            .pair(format: fmt, first: [.layer(solid)], second: [.layer(picture(30, 20, seed: 8))]),
            .stencil(opacity: 0.8, children: [.layer(solid)]),
        ])
    }

    @Test func fusedAndBlendedTransitionsMatchTheMetalCompositor() throws {
        let push = TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.4, 0)), incoming: TransitionSide(offset: Vec2(0.6, 0)),
                                    compose: .sum)
        let over = TransitionRender(incoming: TransitionSide(offset: Vec2(0.3, 0)), compose: .incomingOver)
        try compare("transition", [
            .layer(picture(96, 64, seed: 9)),
            .transition(format: fmt, render: push, first: [.layer(picture(96, 64, seed: 10))], second: [.layer(picture(96, 64, seed: 11))]),
            .blended(.transition(format: fmt, render: over, first: [.layer(picture(60, 40, seed: 12))],
                                 second: [.layer(picture(96, 64, seed: 13))]), .multiply),
        ])
    }

    /// Parity sweep: every transition kind the Mac offers, a third and two thirds in, as the timeline plans it.
    @Test(arguments: TransitionKind.allCases)
    func everyTransitionKindMatchesTheMetalCompositor(kind: TransitionKind) throws {
        for i in [3, 6] {
            let r = TransitionRender.evaluate(kind: kind, direction: .left, softness: 0.2, motionBlur: 1, easing: .linear,
                                              frameIndex: i, frames: 9)
            try compare("transition \(kind) frame \(i)", [
                .layer(picture(96, 64, seed: 20)),
                .transition(format: fmt, render: r, first: [.layer(picture(96, 64, seed: 21))],
                            second: [.layer(picture(96, 64, seed: 22))]),
            ])
        }
    }

    /// Clip grades (basic correction and curves through the shared chain) and an adjustment layer's grade.
    @Test func gradedPicturesAndAdjustmentGradesMatchTheMetalCompositor() throws {
        var basic = BasicCorrection(); basic.exposure = 0.7; basic.saturation = 160; basic.contrast = 30
        let grade = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)])
        var warm = BasicCorrection(); warm.temperature = 30; warm.exposure = -0.4
        let adjust = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(warm)])
        var top = picture(96, 64, seed: 14)
        top.colorPipeline = grade; top.transform.opacity = 0.7
        let a = AdjustmentNode(transform: .identity, opacity: 1, cornerRadius: 0, effects: .none, blendMode: .normal,
                               colorPipeline: adjust, motionSamples: [], drawsBase: false)
        try compare("grade", [.layer(picture(96, 64, seed: 15)), .layer(top)])
        try compare("adjustment grade", [.adjustment(a, below: [.layer(picture(96, 64, seed: 16))])])
    }

    /// A graded solid runs the picture path on a flat 2 x 2 frame, as in the Metal compositor.
    @Test func gradedSolidMatchesTheMetalCompositor() throws {
        var basic = BasicCorrection(); basic.exposure = 0.6; basic.saturation = 140; basic.temperature = -20
        var s = RenderLayer(content: .solid(red: 0.8, green: 0.3, blue: 0.1))
        s.colorPipeline = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)])
        s.transform.scale = Vec2(0.5, 0.6); s.transform.position = Vec2(40, 30); s.transform.opacity = 0.8
        try compare("graded solid", [.layer(picture(96, 64, seed: 17)), .layer(s)])
    }

    // MARK: Clip effects (`GPUCompositor+Effects`)

    private func fx(_ effects: ClipEffects, seed: Int, scale: Double = 0.7, rotation: Double = 0) -> RenderNode {
        var l = picture(80, 56, seed: seed)
        l.effects = effects
        l.transform.scale = Vec2(scale, scale); l.transform.position = Vec2(48, 32); l.transform.rotation = rotation
        return .layer(l)
    }

    /// Every offered clip effect at its catalog defaults, through the model's own evaluation (`Clip.effects(at:)`).
    @Test(arguments: EffectCatalog.all.map(\.kind))
    func everyClipEffectAtDefaultsMatchesTheMetalCompositor(kind: String) throws {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let added = c.addEffect(kind: kind)
        #expect(added != nil, "\(kind) not addable")
        try compare("effect \(kind)", [.layer(picture(96, 64, seed: 29)), fx(c.effects(at: Time(1, 1)), seed: 30)])
    }

    /// Every offered clip effect with every parameter off its default and every keyframable one animated (two keys,
    /// evaluated between them), through `Clip.effects(at:)`. Checkboxes flip, choices take the next entry.
    @Test(arguments: EffectCatalog.all.map(\.kind))
    func everyClipEffectAtAnimatedNonDefaultsMatchesTheMetalCompositor(kind: String) throws {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        guard let id = c.addEffect(kind: kind), let i = c.effects.firstIndex(where: { $0.id == id }),
              let spec = EffectCatalog.spec(for: kind) else { Issue.record("\(kind) not addable"); return }
        // Motion moves too (keyed position), so a Motion Blur effect has something to smear.
        c.animation.position = AnimatedProperty(Vec2(40, 30), track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(40, 30)), Keyframe(time: Time(2, 1), value: Vec2(58, 35))]))
        c.animation.scale = AnimatedProperty(Vec2(0.7, 0.7))
        let t = Time(1, 1)
        func requests(_ c: Clip) -> [LayerRequest] {
            Timeline(name: "S", format: fmt, tracks: [Track(kind: .video, clips: [c])]).videoLayers(at: t)
        }
        let atDefaults = requests(c)
        Self.animateOffDefaults(&c.effects[i], spec)
        let reqs = requests(c)
        // The rest act outside the layer's picture: the grade (Color page parity), the generator's text, time (which
        // frame is decoded) and the matte of another track.
        let offPicture: Set<String> = [ClipEffect.colorKind, ClipEffect.dateStampKind, ClipEffect.posterizeTimeKind,
                                       ClipEffect.trackMaskKind]
        #expect(spec.params.isEmpty || offPicture.contains(kind) || reqs != atDefaults, "\(kind): the parameters changed nothing")
        let layers = reqs.map { r -> RenderLayer in
            var l = picture(80, 56, seed: 34).applying(r)
            l.transform = r.transform
            return l
        }
        try compare("effect \(kind) animated", [.layer(picture(96, 64, seed: 33))] + RenderNode.tree(requests: reqs, layers: layers))
    }

    /// Off-default values: sliders move by a third of a bounded span (huge ranges such as Blur 0...3000 stay picture
    /// sized), keyed from that value at 0 s to a second one at 2 s.
    static func animateOffDefaults(_ e: inout ClipEffect, _ spec: EffectSpec) {
        func keyed<V>(_ a: V, _ b: V) -> AnimatedProperty<V> {
            AnimatedProperty(a, track: KeyframeTrack(keys: [Keyframe(time: .zero, value: a), Keyframe(time: Time(2, 1), value: b)]))
        }
        for (n, p) in spec.params.enumerated() {
            switch p.kind {
            case .slider:
                let lo = p.range.lowerBound, hi = p.range.upperBound
                let span = min(hi - lo, max(abs(p.defaultValue) * 2, 24))
                func off(_ f: Double) -> Double {
                    let up = min(max(p.defaultValue + f * span, lo), hi)
                    return up != p.defaultValue ? up : min(max(p.defaultValue - f * span, lo), hi)
                }
                e.parameters[p.key] = keyed(off(0.25), off(0.45))
            case .checkbox:
                e.parameters[p.key] = AnimatedProperty(p.defaultValue >= 0.5 ? 0 : 1)
            case .choice(let titles):
                e.parameters[p.key] = AnimatedProperty(titles.count > 1 ? Double((Int(p.defaultValue) + 1) % titles.count) : p.defaultValue)
            case .color(let d):
                let a = EffectColor(red: 1 - d.red * 0.6, green: 0.3 + 0.1 * Double(n % 3), blue: d.blue * 0.5 + 0.4, alpha: d.alpha)
                let b = EffectColor(red: a.blue, green: a.red, blue: a.green, alpha: d.alpha)
                e.colors[p.key] = keyed(a, b)
            case .point(let d):
                e.points[p.key] = keyed(Vec2(d.x + 9, d.y - 5), Vec2(d.x - 4, d.y + 7))
            }
        }
    }

    @Test func cropCornersAndKeysMatchTheMetalCompositor() throws {
        let one = ClipEffects(segments: [EffectSegment(masks: EffectMasks(crop: CropInsets(left: 0.1, top: 0.2), cornerRadius: 8,
                                                                         feather: 3),
                                                       keys: [ChromaKey(hue: 120, halfWidth: 36, soft: 13, spill: 0.5)])])
        try compare("crop corners keys", [.layer(picture(96, 64, seed: 20)), fx(one, seed: 21, rotation: 9)])
    }

    @Test func blurShadowAndRepeatEdgesMatchTheMetalCompositor() throws {
        let blur = ClipEffects(segments: [EffectSegment(masks: EffectMasks(crop: CropInsets(right: 0.2)), blurAfter: 3),
                                          EffectSegment(masks: EffectMasks(cornerRadius: 6))])
        let edges = ClipEffects(segments: [EffectSegment(blurAfter: 4, blurRepeatsEdges: true), EffectSegment()])
        let shadow = ClipEffects(segments: [EffectSegment(shadow: DropShadow(color: SIMD3(0.1, 0.9, 0.2), opacity: 0.8, dx: 5,
                                                                             dy: 3, sigma: 2)),
                                            EffectSegment()])
        try compare("blur", [.layer(picture(96, 64, seed: 22)), fx(blur, seed: 23, rotation: -7)])
        try compare("repeat edges", [fx(edges, seed: 24)])
        try compare("drop shadow", [.layer(picture(96, 64, seed: 25)), fx(shadow, seed: 26, scale: 0.6)])
    }

    @Test(arguments: [ImageFilter.sharpen(amount: 0.8), .unsharpMask(sigma: 1.5, amount: 0.6, threshold: 0),
                      .noise(amount: 0.2, color: true, clip: true, seed: 11), .directionalBlur(dx: 6, dy: 2),
                      .glow(threshold: 0.4, sigma: 3, intensity: 0.8, color: SIMD3(1, 0.6, 0.2)),
                      .mosaic(columns: 8, rows: 6, sharp: true), .rgbSplit(dx: 3, dy: 0, radial: false, mix: 1),
                      .outline(width: 3, color: SIMD3(1, 1, 0), softness: 1, position: .outside),
                      .longShadow(angle: 135, length: 12, color: SIMD3(0, 0, 0.3), fade: 0.5, opacity: 0.8)])
    func imageFiltersMatchTheMetalCompositor(filter: ImageFilter) throws {
        let f = ClipEffects(segments: [EffectSegment(masks: EffectMasks(crop: CropInsets(bottom: 0.1)), filter: filter),
                                       EffectSegment()])
        try compare("filter \(filter)", [.layer(picture(96, 64, seed: 27)), fx(f, seed: 28)])
    }

    @Test func clipMasksMattesAndMaskScopesMatchTheMetalCompositor() throws {
        let path = MaskShape(polygon: [Vec2(0.1, 0.1), Vec2(0.8, 0.2), Vec2(0.6, 0.9), Vec2(0.2, 0.7)], feather: 4)
        let subject = MaskShape(polygon: [], source: .subject)
        var l = picture(80, 56, seed: 29)
        l.effects = ClipEffects(segments: [EffectSegment()], masks: [path, subject])
        l.subjectMatte = SubjectMatte(width: 20, height: 14, values: (0..<(20 * 14)).map { Float($0 % 20) / 19 })
        l.transform.position = Vec2(50, 30); l.transform.rotation = 6
        let scoped = ClipEffects(segments: [EffectSegment(blurAfter: 3, scope: [path]), EffectSegment()])
        try compare("masks", [.layer(picture(96, 64, seed: 30)), .layer(l)])
        try compare("mask scope", [.layer(picture(96, 64, seed: 31)), fx(scoped, seed: 32, scale: 0.9)])
    }

    @Test func aStillMatteUploadsOnce() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { return }
        var l = picture(80, 56, seed: 33)
        l.effects = ClipEffects(segments: [EffectSegment()], masks: [MaskShape(polygon: [], source: .subject)])
        l.subjectMatte = SubjectMatte(width: 20, height: 14, values: (0..<(20 * 14)).map { Float($0 % 14) / 13 })
        let gpu = try MetalGPUDevice(device: d)
        let portable = try GPUCompositor(device: gpu)
        var frames: [[Float]] = []
        for _ in 0..<3 {
            let t = target(d)
            let cb = try #require(gpu.makeCommandBuffer())
            try portable.render(nodes: [.layer(l)], format: fmt, into: MetalGPUTexture(t), commandBuffer: cb) { planes(d, $0) }
            gpu.commitAndWait(cb)
            frames.append(readAll(t))
        }
        #expect(portable.matteUploads == 1)
        #expect(frames[0] == frames[1] && frames[1] == frames[2])
    }

    @Test func filmLookAndAntiFlickerMatchTheMetalCompositor() throws {
        let look = ClipEffects(segments: [EffectSegment()],
                               look: FilmLook(chromaBleed: .init(bleed: 6, shift: 1)))
        var flicker = ClipEffects(segments: [EffectSegment()])
        flicker.antiFlicker = 1
        try compare("film look", [.layer(picture(96, 64, seed: 33)), fx(look, seed: 34)])
        try compare("anti-flicker", [fx(flicker, seed: 35, scale: 1)])
    }

    @Test func nestedEffectsFrameBlendAndMotionBlurredAdjustmentMatchTheMetalCompositor() throws {
        let inner = SequenceFormat(width: 48, height: 32, frameDuration: Time(1, 25))
        let blur = ClipEffects(segments: [EffectSegment(blurAfter: 2), EffectSegment(masks: EffectMasks(cornerRadius: 4))])
        try compare("styled group", [
            .layer(picture(96, 64, seed: 36)),
            .styledGroup(format: inner, transform: .identity, opacity: 0.9, cornerRadius: 3,
                         children: [.layer(picture(48, 32, seed: 37))], effects: blur, blendMode: .normal),
        ])
        var blended = picture(96, 64, seed: 38)
        if case .frame(let next, _) = picture(96, 64, seed: 39).content { blended.blend = FrameBlend(next: next, weight: 0.35) }
        try compare("frame blend", [.layer(blended)])
        var t1 = ClipTransform.identity, t2 = ClipTransform.identity
        t1.position = Vec2(44, 32); t2.position = Vec2(52, 32)
        let a = AdjustmentNode(transform: .identity, opacity: 0.8, cornerRadius: 0, effects: blur, blendMode: .normal,
                               colorPipeline: nil, motionSamples: [t1, t2], drawsBase: false)
        try compare("motion-blurred adjustment", [.adjustment(a, below: [.layer(picture(96, 64, seed: 40))])])
    }

    /// A smooth blob pattern moved by `dx` px (optical flow tests).
    private func moved(_ dx: Int) -> CVPixelBuffer {
        bgra(96, 64) { x, y in
            let fx = Float(x - dx), fy = Float(y)
            let v = 0.5 + 0.25 * sin(fx * 0.21) + 0.25 * cos(fy * 0.17 + fx * 0.05)
            let c = UInt8(max(0, min(255, v * 255)))
            return (c, UInt8((Int(c) + y * 2) % 256), UInt8(255 - Int(c) / 2), 255)
        }
    }

    @Test(arguments: [false, true])
    func opticalFlowMatchesTheMetalCompositor(graded: Bool) throws {
        var layer = RenderLayer(content: .frame(moved(0), colorHint: hint(96, 64)))
        layer.blend = FrameBlend(next: moved(4), weight: 0.4, flow: OpticalFlowRequest(key: nil))
        if graded {
            var basic = BasicCorrection(); basic.exposure = 0.4; basic.saturation = 130
            layer.colorPipeline = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)])
        }
        layer.transform = ClipTransform(scale: Vec2(0.9, 0.9), rotation: 5)
        try compare("optical flow graded \(graded)", [.layer(layer)])
    }

    @Test func opticalFlowFieldsAreCachedPerFramePair() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { return }
        let gpu = try MetalGPUDevice(device: d)
        let portable = try GPUCompositor(device: gpu)
        let key = FlowPairKey(media: UUID(), from: .zero, to: Time(1, 25))
        let out = target(d)
        for w: Float in [0.25, 0.5, 0.75] {
            var layer = RenderLayer(content: .frame(moved(0), colorHint: hint(96, 64)))
            layer.blend = FrameBlend(next: moved(4), weight: w, flow: OpticalFlowRequest(key: key))
            let cb = try #require(gpu.makeCommandBuffer())
            try portable.render(nodes: [.layer(layer)], format: fmt, into: MetalGPUTexture(out), commandBuffer: cb) { planes(d, $0) }
            gpu.commitAndWait(cb)
        }
        #expect(portable.flowMeasureCount == 1)
    }

    @Test func deflickerDenoiseAndTrailsMatchTheMetalCompositor() throws {
        func frame(_ seed: Int) -> SQFrame {
            guard case .frame(let f, _) = picture(96, 64, seed: seed).content else { fatalError() }
            return f
        }
        func temporal(_ name: String, _ filter: TemporalFilter, grade: Bool = false) throws {
            var l = picture(96, 64, seed: 50)
            l.transform.scale = Vec2(0.8, 0.8); l.transform.rotation = 5
            l.temporal = TemporalFrames(filter: filter, before: [frame(51), frame(52), frame(53)], after: [frame(54), frame(55)])
            var basic = BasicCorrection(); basic.exposure = 0.4; basic.saturation = 130
            if grade { l.colorPipeline = ColorPipeline(source: .rec709, ops: [.conversion(nil), .basic(basic)]) }
            try compare(name, [.layer(picture(96, 64, seed: 49)), .layer(l)])
        }
        try temporal("deflicker", TemporalFilter(deflicker: .init(framesEachSide: 2, local: true)))
        try temporal("denoise", TemporalFilter(denoise: .init(framesEachSide: 2, best: true, motionSearch: 2, detailSize: 2,
                                                              spatialLuma: 0.5, spatialColor: 0.4)))
        try temporal("trails", TemporalFilter(trails: .init(count: 3, spacing: 1, decay: 0.4, blend: .screen)), grade: true)
        try temporal("all", TemporalFilter(denoise: .init(framesEachSide: 1), deflicker: .init(framesEachSide: 1),
                                           trails: .init(count: 2, spacing: 1, decay: 0.5, blend: .add)), grade: true)
    }

    @Test func pictureMasksMirroredEdgesAndLongBlurMatchTheMetalCompositor() throws {
        let track = UUID()
        var white = RenderLayer(content: .solid(red: 1, green: 1, blue: 1))
        white.transform.scale = Vec2(0.5, 0.6); white.transform.position = Vec2(40, 30)
        var m = MaskShape(polygon: [], source: .picture)
        m.pictureTrack = track
        var masked = picture(80, 56, seed: 41)
        masked.effects = ClipEffects(segments: [EffectSegment()], masks: [m])
        masked.transform.position = Vec2(50, 34); masked.transform.rotation = 5
        try compare("picture mask", [.layer(picture(96, 64, seed: 42)), .pictureMatte(track: track, children: [.layer(white)]),
                                     .layer(masked)])
        var out = TransitionSide(offset: Vec2(-0.3, 0)); out.mirrorEdges = true
        var inc = TransitionSide(offset: Vec2(0.7, 0)); inc.mirrorEdges = true
        let mirrored = TransitionRender(outgoing: out, incoming: inc, compose: .sum)
        var small = picture(60, 40, seed: 43)
        small.transform.position = Vec2(40, 30)
        try compare("mirrored edges", [
            .transition(format: fmt, render: mirrored, first: [.layer(picture(96, 64, seed: 44))], second: [.layer(small)]),
        ])
        let whip = TransitionRender(outgoing: TransitionSide(offset: Vec2(-0.2, 0), blur: Vec2(-1.5, 0)),
                                    incoming: TransitionSide(offset: Vec2(0.8, 0), blur: Vec2(-1.5, 0)), compose: .sum)
        try compare("long blur", [
            .transition(format: fmt, render: whip, first: [.layer(picture(96, 64, seed: 45))], second: [.layer(picture(96, 64, seed: 46))]),
        ])
    }

    /// The cross-backend tree on Metal. SQ_COMPOSITOR_PNG_OUT=<path> writes the PNG; scripts/win-compositor-check.sh compares
    /// it with the D3D12 render (SQGPUD3D12Tests.compositorReferenceRunsOnD3D12).
    @Test func referenceTreeRunsOnMetal() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { return }
        let rgba = try GPUCompositorReference.render(on: try MetalGPUDevice(device: d))
        #expect(rgba.count == GPUCompositorReference.width * GPUCompositorReference.height * 4)
        #expect(Set(rgba).count > 64)
        if let path = ProcessInfo.processInfo.environment["SQ_COMPOSITOR_PNG_OUT"] {
            try Data(GPUPNG.encode(rgba: rgba, width: GPUCompositorReference.width, height: GPUCompositorReference.height))
                .write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
