import Foundation
#if canImport(simd)
import simd
#endif
import SQCore
import SQFrame
import SQGPU
import SQGPUKernels

/// The Metal compositor's effect chain (`Compositor.finishLayer`, CompositorEffects / CompositorMasks / FilmLookPass /
/// AntiFlickerPass) on the portable GPU protocol: the same plans (`EffectChainPlan`, `MaskData`, `FilmLookPlan`), the same
/// passes (`EffectPasses`) and the same Slang draws, so both backends give the same pixels.
extension GPUCompositor {
    typealias Transparent = SIMD4<Float>

    /// An intermediate, nil when none could be made (the chain then stops where Metal's would).
    func scratch(_ w: Int, _ h: Int) -> D.Texture? { try? acquire(w, h) }

    /// `p` drawn upright (no transform, full opacity, no masks) into a new `w` x `h` texture, cleared transparent first.
    private func drawUpright(_ p: Draw, _ u: Compositor.Uniforms, into target: D.Texture, _ cb: D.CommandBuffer) throws {
        var d = p
        d.u = u; d.blend = .normal; d.stencil = false; d.mix = nil; d.maskData = nil; d.matte = nil
        try drawAll([d], into: target, cb, clear: Transparent(0, 0, 0, 0), additive: false)
    }

    private static func upright(_ u: Compositor.Uniforms, width w: Int, height h: Int) -> Compositor.Uniforms {
        var u1 = u
        u1.canvas = SIMD2(Float(w), Float(h)); u1.size = u1.canvas
        u1.position = .zero; u1.anchor = .zero; u1.scale = SIMD2(1, 1)
        u1.rotCos = 1; u1.rotSin = 0; u1.opacity = 1; u1.blend = 0; u1.tilt = .zero
        u1.maskCount = 0
        return u1
    }

    /// `Compositor.finishLayer`: the plain draw of a layer turned into the draw(s) with its effects, in effect-list order.
    func finishLayer(_ p0: Draw, layer: RenderLayer, format: SequenceFormat, _ cb: D.CommandBuffer,
                     into draws: inout [Draw]) throws {
        let fx = layer.effects.isIdentity && layer.effects.segments.isEmpty
            ? ClipEffects(cornerRadius: layer.cornerRadius) : layer.effects
        if fx.isEmpty { return }
        var p = p0
        p.blend = layer.blendMode
        if fx.antiFlicker > 0, let soft = try applyAntiFlicker(fx.antiFlicker, to: p, cb) {
            let blend = p.blend
            p = soft; p.blend = blend
        }
        let segs = fx.segments
        func emit(_ draw: Draw) throws {
            var q = draw
            var placed = q.u
            if let weave = fx.look.weave { Compositor.applyWeave(weave, to: &placed) }
            applyMasks(Compositor.opacityMasks(fx.masks, mattes: layer.mattes), matte: layer.subjectMatte, mattes: layer.mattes,
                       screen: Compositor.screenFromLocal(placed), to: &q)
            if fx.look.needsPass, let looked = try applyLook(fx.look, to: q, cb) { q = looked }
            if let weave = fx.look.weave { Compositor.applyWeave(weave, to: &q.u) }
            draws.append(q)
        }

        guard segs.count > 1 else {
            if let seg = segs.first {
                Compositor.configure(&p.u, seg, radiusFactor: p.radiusFactor, reduction: 1, legacyRadius: layer.cornerRadius)
            }
            try emit(p)
            return
        }

        let layerSize = p.u.size
        var cur = p
        var curSize = layerSize
        var first = true
        var cutToFrame = false
        let linearSource = p.u.mode == 2 || p.u.mode == 3 || (p.u.mode == 1 && p.u.linearize == 0)
        let minFactor = limitsColorWork && min(layerSize.x, layerSize.y) >= 128
            ? Compositor.effectChainFactor(segs, display: Compositor.effectWorkFactor(transform: layer.transform, size: layerSize),
                                           strongBlurHalves: linearSource) : 1
        func plan(_ seg: EffectSegment, _ size: SIMD2<Float>) -> GaussianBlur.Plan {
            GaussianBlur.Plan(layerWidth: Double(size.x), layerHeight: Double(size.y),
                              sigma: seg.shadow == nil && seg.filter == nil ? seg.blurAfter : 0,
                              extraMargin: seg.shadow.map { $0.distance + 3 * $0.sigma } ?? seg.filter?.axisMargin.x ?? 0,
                              extraMarginY: seg.shadow == nil ? seg.filter?.axisMargin.y : nil,
                              minFactor: minFactor, maxPixels: Compositor.pixelBudget(seg))
        }
        var scopeFocal: Float = 0
        if p.u.tilt.z > 0 {
            var size = layerSize
            for seg in segs.dropLast() {
                let pl = plan(seg, size)
                size = SIMD2(pl.outputWidth, pl.outputHeight)
            }
            var fu = p.u
            fu.size = size
            scopeFocal = Compositor.tiltFocal(fu)
        }
        let acquireScratch: EffectPasses<D>.Acquire = { [unowned self] w, h in self.scratch(w, h) }
        for seg in segs.dropLast() {
            let pl = plan(seg, curSize)
            let tw = pl.textureWidth, th = pl.textureHeight
            guard var a = scratch(tw, th) else { break }
            var b: D.Texture?
            if seg.blurAfter > 0, seg.shadow == nil, seg.filter == nil {
                b = scratch(tw, th)
                if b == nil { break }
            }
            var u1 = cur.u
            u1.canvas = SIMD2(Float(tw), Float(th))
            u1.size = SIMD2(curSize.x / Float(pl.factor), curSize.y / Float(pl.factor))
            u1.position = .zero; u1.anchor = .zero; u1.scale = SIMD2(1, 1)
            u1.rotCos = 1; u1.rotSin = 0; u1.opacity = 1; u1.blend = 0; u1.tilt = .zero
            u1.maskSize = first ? .zero : SIMD2(layerSize.x / Float(pl.factor), layerSize.y / Float(pl.factor))
            u1.keyCount = 0; u1.crop = .zero; u1.roundFirst = 0; u1.maskCount = 0; u1.cropFeather = 0
            Compositor.configure(&u1, seg, radiusFactor: p.radiusFactor, reduction: Float(pl.factor), legacyRadius: nil)
            if cutToFrame { Compositor.cutToMaskRect(&u1) }
            var pre: D.Texture?
            if seg.scopesKeys, let t = scratch(tw, th) {
                var u0 = u1
                u0.keyCount = 0
                try drawUpright(cur, u0, into: t, cb)
                pre = t
            }
            try drawUpright(cur, u1, into: a, cb)
            if pre == nil, !seg.scope.isEmpty, seg.shadow == nil, seg.filter != nil || b != nil, let t = scratch(tw, th),
               cb.copy(a, to: t) {
                pre = t
            }
            if let sh = seg.shadow {
                guard let c = scratch(tw, th),
                      passes.shadow(sh, plan: pl, image: a, result: c, cb, acquire: acquireScratch) else { break }
                a = c
            } else if let f = seg.filter {
                let pf = Float(pl.factor)
                let frame = ImageFilters.Frame(center: SIMD2(Float(tw), Float(th)) / 2, size: layerSize / pf)
                guard let c = scratch(tw, th),
                      passes.filter(f, image: a, into: c, frame: frame, pf: Double(pl.factor), cb, acquire: acquireScratch)
                else { break }
                a = c
            } else if let g = seg.grade {
                if let c = try gradeSegment(g, a, cb) {
                    if !seg.scope.isEmpty { pre = a }
                    a = c
                }
            } else if let b {
                let edges = seg.blurRepeatsEdges
                    ? Compositor.repeatEdgeRect(frame: layerSize / Float(pl.factor), texture: SIMD2(tw, th))
                    : nil
                passes.blur(pl, from: a, via: b, cb, repeatEdges: edges)
            }
            if let pre, let out = scratch(tw, th) {
                var scopeMap = Compositor.screenFromLocal(p.u)
                if scopeFocal > 0 { scopeMap.tilt.z = scopeFocal }
                if maskScope(seg.scope, layer: layer, pre: pre, post: a, out: out, frame: layerSize / Float(pl.factor),
                             pf: Float(pl.factor), screen: scopeMap, cb) {
                    a = out
                }
            }
            cutToFrame = seg.blurAfter > 0 && seg.blurRepeatsEdges && seg.shadow == nil && seg.filter == nil

            var next = p
            next.tex0 = a; next.tex1 = dummy
            next.u.mode = 3; next.u.linearize = 0; next.u.quarter = 0; next.u.part = .zero
            curSize = SIMD2(pl.outputWidth, pl.outputHeight)
            next.u.size = curSize
            cur = next
            first = false
        }

        var fin = cur
        fin.u = p.u
        fin.blend = p.blend
        if !first {
            fin.u.mode = 3; fin.u.linearize = 0; fin.u.quarter = 0; fin.u.part = .zero
            fin.u.size = curSize
            fin.u.maskSize = layerSize
        }
        if fin.u.tilt.z > 0 { fin.u.tilt.z = Compositor.tiltFocal(fin.u) }
        fin.u.keyCount = 0; fin.u.crop = .zero; fin.u.roundFirst = 0; fin.u.cropFeather = 0
        if let last = segs.last {
            Compositor.configure(&fin.u, last, radiusFactor: p.radiusFactor, reduction: 1, legacyRadius: nil)
        }
        if cutToFrame { Compositor.cutToMaskRect(&fin.u) }
        try emit(fin)
    }

    // MARK: Masks

    /// `Compositor.applyMasks`: the clip masks on a draw (mask entries in a data buffer, subject / Magic mattes in one texture).
    /// Picture masks read the current level's matte images (at most two distinct ones per draw, inputs 4 / 5).
    func applyMasks(_ masks: [MaskShape], matte: SubjectMatte?, mattes: [UUID: SubjectMatte], edgeScale: Float = 1,
                    screen: Compositor.ScreenMap?, to p: inout Draw) {
        guard !masks.isEmpty else { return }
        let scope = pictureScopes.last ?? [:]
        var images: [D.Texture] = [], ids: [Track.ID] = []
        var pictureSlot: [Int] = []
        for m in masks {
            guard m.source == .picture, screen != nil, let track = m.pictureTrack, let t = scope[track] else {
                pictureSlot.append(-1); continue
            }
            if let i = ids.firstIndex(of: track) { pictureSlot.append(i) }
            else if images.count < 2 { images.append(t); ids.append(track); pictureSlot.append(images.count - 1) }
            else { pictureSlot.append(-1) }
        }
        let (distinct, slot) = Compositor.matteSlots(masks, matte: matte, mattes: mattes)
        let matteTex = distinct.isEmpty ? nil : matteTexture(distinct)
        let all = Compositor.maskEntries(masks, frame: p.u.maskSize.x > 0 ? p.u.maskSize : p.u.size, edgeScale: edgeScale,
                                         screen: screen, pictureSlot: pictureSlot, matteSlot: slot, hasMatte: matteTex != nil)
        guard let buf = maskBuffer(all.count * MemoryLayout<SIMD2<Float>>.stride) else { return }
        all.withUnsafeBytes { device.upload($0, to: buf) }
        p.maskData = buf
        p.u.maskCount = UInt32(masks.count)
        p.matte = matteTex
        p.picture0 = images.first
        p.picture1 = images.count > 1 ? images[1] : nil
    }

    /// Up to 4 mattes in the r/g/b/a channels of one rgba16Float texture at the largest one's size (one matte: r only), as
    /// `Compositor.matteTexture` / `packedMatteTexture` give the shader.
    /// Cached by matte storage like `Compositor.matteTexture`: a still matte (or one held by the matte cache across frames)
    /// uploads once. A cached texture is never rewritten; an evicted one goes back to the pool at the next `render`.
    private func matteTexture(_ ms: [SubjectMatte]) -> D.Texture? {
        guard let big = ms.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let used = Array(ms.prefix(4))
        if let i = matteCache.firstIndex(where: { Self.sameStorage($0.mattes, used) }) { return matteCache[i].texture }
        let w = big.width, h = big.height
        let fitted = ms.prefix(4).map { $0.width == w && $0.height == h ? $0 : $0.resampled(width: w, height: h) }
        let t: D.Texture
        if let i = freeMattes.firstIndex(where: { $0.width == w && $0.height == h }) { t = freeMattes.remove(at: i) }
        else if let made = device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba16Float, cpuAccessible: true)) {
            t = made
        } else { return nil }
        var px = [UInt16](repeating: 0, count: w * h * 4)
        for (c, m) in fitted.enumerated() {
            m.values.withUnsafeBufferPointer { v in
                for i in 0..<(w * h) { px[i * 4 + c] = Self.half(v[i]) }
            }
        }
        px.withUnsafeBytes { device.upload($0, bytesPerRow: w * 8, to: t) }
        matteUploads += 1
        // The entry keeps the mattes alive, so their storage address cannot be reused by another matte.
        matteCache.append((used, t))
        if matteCache.count > 8 {
            matteTextures += matteCache.prefix(matteCache.count - 8).map(\.texture)
            matteCache.removeFirst(matteCache.count - 8)
        }
        return t
    }

    private static func sameStorage(_ a: [SubjectMatte], _ b: [SubjectMatte]) -> Bool {
        func storage(_ x: SubjectMatte) -> UnsafeRawPointer? { x.values.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) } }
        return a.count == b.count && zip(a, b).allSatisfy { storage($0) == storage($1) && $0.width == $1.width && $0.height == $1.height }
    }

    /// IEEE half bits of `f`, rounded to nearest even (what vImage's Planar16F conversion writes).
    static func half(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exp = Int((bits >> 23) & 0xFF), mant = bits & 0x7F_FFFF
        if exp == 0xFF { return sign | 0x7C00 | (mant != 0 ? 0x200 : 0) }
        let e = exp - 127 + 15
        if e >= 0x1F { return sign | 0x7C00 }
        if e <= 0 {
            if e < -10 { return sign }
            let m = mant | 0x80_0000
            let shift = UInt32(14 - e)
            var r = m >> shift
            let rem = m & ((1 << shift) - 1), halfway = UInt32(1) << (shift - 1)
            if rem > halfway || (rem == halfway && r & 1 == 1) { r += 1 }
            return sign | UInt16(r)
        }
        var r = UInt32(e) << 10 | (mant >> 13)
        let rem = mant & 0x1FFF
        if rem > 0x1000 || (rem == 0x1000 && r & 1 == 1) { r += 1 }
        return sign | UInt16(r)
    }

    /// A mask data buffer of at least `length` bytes (power-of-two size class), free again at the next `render`.
    func maskBuffer(_ length: Int) -> D.Buffer? {
        var size = 256
        while size < length { size *= 2 }
        let b: D.Buffer
        if let i = freeBuffers.firstIndex(where: { $0.length == size }) { b = freeBuffers.remove(at: i) }
        else if let made = device.makeBuffer(length: size) { b = made }
        else { return nil }
        inFlightBuffers.append(b)
        return b
    }

    /// `Compositor.encodeMaskScope`: `out` = `pre` where `masks` do not cover, `post` where they do.
    func maskScope(_ masks: [MaskShape], layer: RenderLayer, pre: D.Texture, post: D.Texture, out: D.Texture,
                   frame: SIMD2<Float>, pf: Float, screen: Compositor.ScreenMap?, _ cb: D.CommandBuffer) -> Bool {
        var u = Compositor.Uniforms()
        u.size = frame; u.maskSize = frame; u.scale = SIMD2(1, 1)
        var q = Draw(u: u, tex0: pre, tex1: dummy)
        applyMasks(masks, matte: layer.subjectMatte, mattes: layer.mattes, edgeScale: 1 / max(pf, 1),
                   screen: screen?.scaled(pf), to: &q)
        guard let md = q.maskData, let enc = cb.makeComputeEncoder() else { return false }
        enc.setPipeline(maskScopePipeline)
        enc.setInput(pre, at: 0); enc.setInput(post, at: 1)
        enc.setInput(q.matte ?? dummy, at: 3)
        enc.setInput(q.picture0 ?? dummy, at: 4); enc.setInput(q.picture1 ?? dummy, at: 5)
        enc.setOutput(out)
        withUnsafeBytes(of: &q.u) { enc.setConstantBytes($0, slot: 0) }
        enc.setBuffer(md, at: 2)
        enc.dispatch(width: out.width, height: out.height)
        enc.end()
        return true
    }

    // MARK: Picture mattes, transitions

    /// `Compositor.encodePictureMattes`: this list's `.pictureMatte` nodes, each rendered into a transparent image of
    /// `format`, pushed as the current Picture scope (alone for a list headed by `.pictureScope`). true = pushed.
    func encodePictureMattes(_ nodes: [RenderNode], format: SequenceFormat, _ cb: D.CommandBuffer,
                             pictures: PictureSource) throws -> Bool {
        let isolated = nodes.contains { if case .pictureScope = $0 { true } else { false } }
        let base = isolated ? [:] : (pictureScopes.last ?? [:])
        var scope: [Track.ID: D.Texture]? = isolated ? [:] : nil
        for node in nodes {
            guard case .pictureMatte(let track, let children) = node else { continue }
            let tex = try acquire(format.width, format.height)
            pictureScopes.append([:])
            defer { pictureScopes.removeLast() }
            try encode(children, format: format, into: tex, cb, clear: Transparent(0, 0, 0, 0), pictures: pictures)
            if scope == nil { scope = base }
            scope?[track] = tex
        }
        guard let scope else { return false }
        pictureScopes.append(scope)
        return true
    }

    /// `Compositor`'s transition sides: a side with mirrored edges is measured first (any pixel below full alpha turns its
    /// mirror off), a side with a long blur runs the pre-pass onto a grown canvas. Returns the sides to mix, the uniforms
    /// (scales of pre-blurred sides) and the coverage buffer (nil = both cover).
    func transitionSides(_ render: TransitionRender, _ a: D.Texture, _ b: D.Texture, _ pf: SequenceFormat,
                         _ cb: D.CommandBuffer) throws -> ((D.Texture, D.Texture), Compositor.TransitionUniforms, D.Buffer?) {
        var tu = Compositor.TransitionUniforms(render)
        let canvas = SIMD2(Float(pf.width), Float(pf.height))
        var sides = [a, b]
        var cover: D.Buffer?
        let mirrored = [tu.a.mirror > 0.5 && tu.a.opacity > 0, tu.b.mirror > 0.5 && tu.b.opacity > 0]
        if mirrored[0] || mirrored[1] {
            var ones = [UInt32](repeating: 0, count: 64)
            ones[0] = Float(1).bitPattern; ones[1] = Float(1).bitPattern
            guard let buf = maskBuffer(256) else { throw CompositorError.resourceAllocation }
            ones.withUnsafeBytes { device.upload($0, to: buf) }
            guard let ce = cb.makeComputeEncoder() else { throw CompositorError.resourceAllocation }
            ce.setPipeline(coverPipeline)
            ce.setBuffer(buf, at: 2)
            for (i, on) in mirrored.enumerated() where on {
                ce.setInput(sides[i], at: 0)
                ce.setConstants(SIMD4<UInt32>(UInt32(i), 0, 0, 0))
                // Whole 16 x 16 groups: the kernel's group minimum needs every thread (extra ones count as opaque).
                ce.dispatch(width: (pf.width + 15) / 16 * 16, height: (pf.height + 15) / 16 * 16)
            }
            ce.end()
            cover = buf
        }
        for (i, pre) in [tu.a.splitLongBlur(canvas: canvas), tu.b.splitLongBlur(canvas: canvas)].enumerated() {
            guard var (side, needed) = pre else { continue }
            let target = Compositor.longBlurTarget(width: pf.width, height: pf.height, pad: needed, maxSide: maxIntermediateSide)
            needed = target.pad
            if i == 0 { tu.a.scale = 1 + 2 * needed } else { tu.b.scale = 1 + 2 * needed }
            let t = try acquire(target.width, target.height)
            guard let enc = cb.makeComputeEncoder() else { throw CompositorError.resourceAllocation }
            var preU = Compositor.PreBlurUniforms(canvas: canvas, pad: needed, slot: UInt32(i))
            enc.setPipeline(preBlurPipeline)
            enc.setInput(sides[i], at: 0); enc.setOutput(t)
            withUnsafeBytes(of: &side) { enc.setConstantBytes($0, slot: 0) }
            withUnsafeBytes(of: &preU) { enc.setConstantBytes($0, slot: 1) }
            enc.setBuffer(cover ?? coverNeutral, at: 2)
            enc.dispatch(width: target.width, height: target.height)
            enc.end()
            sides[i] = t
        }
        return ((sides[0], sides[1]), tu, cover)
    }

    // MARK: Look, anti-flicker, grade

    /// `Compositor.applyLook` (the two-step path: upright draw, then the look kernel; the fused Metal draw gives the same bits).
    func applyLook(_ look: FilmLook, to p: Draw, _ cb: D.CommandBuffer) throws -> Draw? {
        guard look.needsPass else { return nil }
        let w = max(1, Int(p.u.size.x.rounded())), h = max(1, Int(p.u.size.y.rounded()))
        guard max(w, h) <= GaussianBlur.maxTextureSize, let a = scratch(w, h), let b = scratch(w, h) else { return nil }
        var lu = Compositor.lookUniforms(look, width: w, height: h)
        try drawUpright(p, Self.upright(p.u, width: w, height: h), into: a, cb)
        guard let enc = cb.makeComputeEncoder() else { return nil }
        enc.setPipeline(lookPipeline)
        enc.setInput(a, at: 0); enc.setOutput(b)
        withUnsafeBytes(of: &lu) { enc.setConstantBytes($0, slot: 0) }
        enc.dispatch(width: w, height: h)
        enc.end()
        var out = p
        out.tex0 = b; out.tex1 = dummy
        out.u.mode = 3; out.u.linearize = 0; out.u.quarter = 0; out.u.part = .zero
        out.u.size = SIMD2(Float(w), Float(h))
        out.u.maskSize = .zero; out.u.crop = .zero; out.u.roundFirst = 0; out.u.cropFeather = 0; out.u.cornerRadius = 0
        out.u.keyCount = 0
        return out
    }

    /// `Compositor.applyAntiFlicker`.
    func applyAntiFlicker(_ strength: Double, to p: Draw, _ cb: D.CommandBuffer) throws -> Draw? {
        guard strength > 0 else { return nil }
        let w = max(1, Int(p.u.size.x.rounded())), h = max(1, Int(p.u.size.y.rounded()))
        guard max(w, h) <= GaussianBlur.maxTextureSize, let a = scratch(w, h), let b = scratch(w, h) else { return nil }
        var u1 = Self.upright(p.u, width: w, height: h)
        u1.crop = .zero; u1.roundFirst = 0; u1.cropFeather = 0; u1.cornerRadius = 0; u1.keyCount = 0
        try drawUpright(p, u1, into: a, cb)
        kernels.antiFlicker(cb, a, into: b, k: AntiFlickerFilter.neighborWeight(strength: strength))
        var out = p
        out.tex0 = b; out.tex1 = dummy
        out.u.mode = 3; out.u.linearize = 0; out.u.quarter = 0; out.u.part = .zero
        out.u.size = SIMD2(Float(w), Float(h))
        out.u.maskSize = .zero
        return out
    }

    /// `Compositor.gradeSegment`: a masked Color effect on an effect-chain image, into a new premultiplied texture.
    func gradeSegment(_ grade: ColorEffect, _ tex: D.Texture, _ cb: D.CommandBuffer) throws -> D.Texture? {
        let color = Compositor.maskedGradeColor(grade)
        let resolved: ColorPipeline?
        if let colorResolver {
            let owner = Compositor.maskedGradeOwner(grade)
            resolved = colorResolverBlocks
                ? colorResolver.pipelineBlocking(for: color, media: Compositor.maskedGradeMedia, owner: owner)
                : colorResolver.pipeline(for: color, media: Compositor.maskedGradeMedia, owner: owner)
        } else {
            let p = ColorPipeline.from(clipColor: color, mediaID: Compositor.maskedGradeMedia, mediaInfo: nil, lutProvider: nil)
            resolved = p.isIdentity ? nil : p
        }
        guard let pipeline = resolved, !pipeline.isIdentity, let mid = scratch(tex.width, tex.height),
              let out = scratch(tex.width, tex.height) else { return nil }
        kernels.encode709(cb, tex, into: mid)
        try chain.encode(pipeline, texture: mid, commandBuffer: cb)
        kernels.premultiply(cb, mid, into: out)
        return out
    }

    // MARK: Adjustment layers, frame blending

    /// `Compositor.encodeAdjustment` after its input: the effects, Motion (or the mean of its sub-frame copies), opacity
    /// and blend mode. `src` reads the composite below (or its graded copy).
    func adjustment(_ a: AdjustmentNode, src: Draw, size: SIMD2<Float>, format: SequenceFormat, _ cb: D.CommandBuffer,
                    into draws: inout [Draw]) throws {
        let factor = Compositor.radiusFactor(format.displayWidth, format.height, canvas: format)
        let styled = RenderLayer(content: .placeholder(.loading), cornerRadius: a.cornerRadius, effects: a.effects,
                                 blendMode: a.blendMode)
        func adjusted(_ t: ClipTransform, opacity: Double) -> Draw {
            var p = src
            Compositor.layerGeometry(&p.u, transform: t, canvas: format, size: size, cornerRadius: a.cornerRadius * factor)
            p.u.opacity = Float(opacity)
            p.radiusFactor = factor
            return p
        }
        guard a.motionSamples.count > 1 else {
            try finishLayer(adjusted(a.transform, opacity: a.opacity), layer: styled, format: format, cb, into: &draws)
            return
        }
        let sum = try acquire(format.width, format.height)
        var normal = styled
        normal.blendMode = .normal
        let n = Double(a.motionSamples.count)
        for (k, t) in a.motionSamples.enumerated() {
            var copy: [Draw] = []
            try finishLayer(adjusted(t, opacity: 1 / n), layer: normal, format: format, cb, into: &copy)
            try drawAll(copy, into: sum, cb, clear: k > 0 ? nil : Transparent(0, 0, 0, 0), additive: k > 0)
        }
        var p = plain(sum, canvas: format, size: size)
        p.u.opacity = Float(a.opacity)
        p.blend = a.blendMode
        draws.append(p)
    }

    /// `Compositor.blendIntermediate`: both frames converted to RGB, graded or left BT.709-encoded, mixed light-linear
    /// (or moved along their optical flow when `flow` is set) into one intermediate (working-linear: draw it with
    /// `linearize = 0`). nil when the second frame has another size or kind; the layer then shows its first frame.
    func blendIntermediate(_ a: Picture, _ b: Picture, weight: Float, flow: OpticalFlowRequest? = nil, u: Compositor.Uniforms,
                           pipeline: ColorPipeline?, _ cb: D.CommandBuffer) throws -> D.Texture? {
        let w = a.planes.0.width, h = a.planes.0.height
        guard b.planes.0.width == w, b.planes.0.height == h else { return nil }
        var alphaB = u.alphaMode
        switch (a.kind, b.kind) {
        case (.ycbcr, .ycbcr): guard b.planes.1 != nil else { return nil }
        case (.rgba, .rgba(let m)): alphaB = m
        default: return nil
        }
        guard let ma = scratch(w, h), let mb = scratch(w, h), let mc = scratch(w, h),
              let enc = cb.makeComputeEncoder() else { return nil }
        var cu = u
        var cv = Compositor.ConvertUniforms(origin: .zero, transfer: UInt32.max)
        enc.setPipeline(convert)
        withUnsafeBytes(of: &cv) { enc.setConstantBytes($0, slot: 1) }
        for (pic, out, alpha) in [(a, ma, u.alphaMode), (b, mb, alphaB)] {
            cu.alphaMode = alpha
            withUnsafeBytes(of: &cu) { enc.setConstantBytes($0, slot: 0) }
            enc.setInput(pic.planes.0, at: 0)
            enc.setInput(pic.planes.1 ?? dummy, at: 1)
            enc.setOutput(out)
            enc.dispatch(width: w, height: h)
        }
        enc.end()
        // Optical flow: the motion is measured on the source pictures, before any grade changes them (cached per pair).
        let field = flow.flatMap { self.flowPasses().field(a: ma, b: mb, request: $0, cb) }
        var encoded = true
        if let pipeline {
            let turned = u.quarter & 1 == 1
            try chain.encode(pipeline, texture: ma, commandBuffer: cb, quarterTurned: turned)
            try chain.encode(pipeline, texture: mb, commandBuffer: cb, quarterTurned: turned)
            encoded = false
        }
        if let field {
            flowPasses().passes.interpolate(a: ma, b: mb, field: field, t: weight, linearize: encoded, into: mc, cb)
            return mc
        }
        kernels.blendFrames(cb, ma, mb, into: mc, weight: weight, encoded: encoded)
        return mc
    }

    /// `Compositor.temporalIntermediate`: Deflicker, Video Denoise and Trails on the center frame with its neighbors (same
    /// size and kind only, nearest first), then the grade. nil when nothing runs; the layer then draws its plain frame.
    func temporalIntermediate(_ center: Picture, frames tf: TemporalFrames, u: Compositor.Uniforms, pipeline: ColorPipeline?,
                              _ cb: D.CommandBuffer, pictures: PictureSource) -> D.Texture? {
        if temporalStore == nil { temporalStore = try? TemporalPasses(device: device) }
        guard let tp = temporalStore else { return nil }
        let w = center.planes.0.width, h = center.planes.0.height
        func sameKind(_ p: Picture) -> Bool {
            switch (center.kind, p.kind) {
            case (.ycbcr(let a, let fa), .ycbcr(let b, let fb)): a == b && fa == fb && p.planes.1 != nil
            case (.rgba(let a), .rgba(let b)): a == b
            default: false
            }
        }
        func planes(_ list: [SQFrame], limit: Int) -> [TemporalPasses<D>.Planes] {
            var out: [TemporalPasses<D>.Planes] = []
            for frame in list where out.count < limit {
                guard let p = pictures(frame), p.planes.0.width == w, p.planes.0.height == h, sameKind(p) else { break }
                out.append((p.planes.0, p.planes.1 ?? dummy))
            }
            return out
        }
        let limits = TemporalPasses<D>.neighborLimits(tf.filter)
        let grade: ((D.Texture) -> Bool)? = pipeline.map { pipeline in
            { out in
                (try? self.chain.encode(pipeline, texture: out, commandBuffer: cb, quarterTurned: u.quarter & 1 == 1)) != nil
            }
        }
        return tp.run(tf.filter, center: (center.planes.0, center.planes.1 ?? dummy),
                      before: planes(tf.before, limit: limits.before), after: planes(tf.after, limit: limits.after), u: u,
                      width: w, height: h, cb, dummy: dummy, dummyBuffer: dummyBuffer,
                      acquire: { self.scratch($0, $1) }, buffer: { self.maskBuffer($0) }, grade: grade)
    }
}
