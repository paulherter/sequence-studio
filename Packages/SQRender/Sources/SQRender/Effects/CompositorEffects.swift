#if canImport(Metal)
import Foundation
import Metal
import SQCore
import SQGPU
import SQGPUKernels
import SQGPUMetal
import simd

extension Compositor {
    /// Turns the plain draw of a layer (`prepareLayer`) into the draw(s) with its effects, in effect-list order.
    ///
    /// The evaluated effects are a list of segments cut at every blur (see `ClipEffects`). A layer with one segment (no blur)
    /// rides along in the one draw: Crop and Rounded Corners are a coverage mask, Ultra Key a color/alpha step, both inside the
    /// fragment shader. With more segments each one but the last is a pass into a padded intermediate: the previous image is
    /// drawn upright with that segment's masks and keys, then blurred in two compute passes (or not blurred, for an extra pass
    /// that exists only because two masks could not be merged). The last segment is drawn into the composite with the layer's
    /// transform, opacity and blend mode. A layer without effects goes through untouched: no effect maths runs.
    func finishLayer(_ p0: Prepared, layer: RenderLayer, format: SequenceFormat, commandBuffer: MTLCommandBuffer,
                     retainer: Retainer, into prepared: inout [Prepared]) {
        let fx = layer.effects.isIdentity && layer.effects.segments.isEmpty
            ? ClipEffects(cornerRadius: layer.cornerRadius) : layer.effects
        if fx.isEmpty { return }
        var p = p0
        p.blend = layer.blendMode
        // Motion's Anti-flicker Filter: softens the clip's picture vertically before its effects (0 = no pass).
        if fx.antiFlicker > 0, let soft = applyAntiFlicker(fx.antiFlicker, to: p, commandBuffer: commandBuffer, retainer: retainer) {
            let blend = p.blend
            p = soft; p.blend = blend
        }
        let segs = fx.segments
        /// Queues the layer's final draw: through the film look pass when it has one, moved by Gate Weave when it has that.
        func emit(_ draw: Prepared) {
            var q = draw
            // The Picture matte stays fixed to the screen: map with the place the layer is finally drawn (after Gate Weave).
            var placed = q.u
            if let weave = fx.look.weave { Self.applyWeave(weave, to: &placed) }
            applyMasks(Self.opacityMasks(fx.masks, mattes: layer.mattes), matte: layer.subjectMatte, mattes: layer.mattes,
                       screen: Self.screenFromLocal(placed), retainer: retainer, to: &q)
            if fx.look.needsPass, let looked = applyLook(fx.look, to: q, commandBuffer: commandBuffer, retainer: retainer) { q = looked }
            if let weave = fx.look.weave { Self.applyWeave(weave, to: &q.u) }
            prepared.append(q)
        }

        guard segs.count > 1 else {
            // One pass: everything rides along in the plain draw.
            if let seg = segs.first {
                Self.configure(&p.u, seg, radiusFactor: p.radiusFactor, reduction: 1, legacyRadius: layer.cornerRadius)
            }
            emit(p)
            return
        }

        let layerSize = p.u.size
        var cur = p                                  // what the next pass reads: the layer itself, then each blurred image
        var curSize = layerSize                      // its size in layer px
        var first = true
        var cutToFrame = false                       // the image is a Repeat Edge Pixels blur: the next draw cuts it to the frame
        // Playback perf: a layer shown at half size or less runs its passes at half size when every pass softens or moves
        // the picture (no per-pixel detail such as Sharpen or Noise would change its look). Export follows the same rule.
        // A strong blur may halve at any scale only when the picture it reads is working-linear (graded, nested, solid):
        // halving an encoded source would average encoded values (darker fine detail).
        let linearSource = p.u.mode == 2 || p.u.mode == 3 || (p.u.mode == 1 && p.u.linearize == 0)
        let minFactor = limitsColorWork && min(layerSize.x, layerSize.y) >= 128
            ? Self.effectChainFactor(segs, display: Self.effectWorkFactor(transform: layer.transform, size: layerSize),
                                     strongBlurHalves: linearSource) : 1
        // The final draw's camera distance comes from the last pass's padded size; the Picture mask of an effect scope
        // must project with that same distance, so the chain's sizes are planned ahead (the plans are pure).
        var scopeFocal: Float = 0
        if p.u.tilt.z > 0 {
            var size = layerSize
            for seg in segs.dropLast() {
                let plan = GaussianBlur.Plan(layerWidth: Double(size.x), layerHeight: Double(size.y),
                                             sigma: seg.shadow == nil && seg.filter == nil ? seg.blurAfter : 0,
                                             extraMargin: seg.shadow.map { $0.distance + 3 * $0.sigma } ?? seg.filter?.axisMargin.x ?? 0,
                                             extraMarginY: seg.shadow == nil ? seg.filter?.axisMargin.y : nil,
                                             minFactor: minFactor, maxPixels: Self.pixelBudget(seg))
                size = SIMD2(plan.outputWidth, plan.outputHeight)
            }
            var fu = p.u
            fu.size = size
            scopeFocal = Self.tiltFocal(fu)
        }
        for seg in segs.dropLast() {
            let plan = GaussianBlur.Plan(layerWidth: Double(curSize.x), layerHeight: Double(curSize.y),
                                         sigma: seg.shadow == nil && seg.filter == nil ? seg.blurAfter : 0,
                                         extraMargin: seg.shadow.map { $0.distance + 3 * $0.sigma } ?? seg.filter?.axisMargin.x ?? 0,
                                         extraMarginY: seg.shadow == nil ? seg.filter?.axisMargin.y : nil,
                                         minFactor: minFactor, maxPixels: Self.pixelBudget(seg))
            guard var a = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight) else { break }
            var b: MTLTexture?
            if seg.blurAfter > 0, seg.shadow == nil, seg.filter == nil {
                b = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight)
                if b == nil { retainer.pooled.append(a); break }
            }
            retainer.pooled.append(a)
            if let b { retainer.pooled.append(b) }

            var u1 = cur.u
            u1.canvas = SIMD2(Float(plan.textureWidth), Float(plan.textureHeight))
            u1.size = SIMD2(curSize.x / Float(plan.factor), curSize.y / Float(plan.factor))
            u1.position = .zero; u1.anchor = .zero; u1.scale = SIMD2(1, 1)
            u1.rotCos = 1; u1.rotSin = 0; u1.opacity = 1; u1.blend = 0; u1.tilt = .zero
            u1.maskSize = first ? .zero : SIMD2(layerSize.x / Float(plan.factor), layerSize.y / Float(plan.factor))
            u1.keyCount = 0; u1.crop = .zero; u1.roundFirst = 0; u1.maskCount = 0; u1.cropFeather = 0
            Self.configure(&u1, seg, radiusFactor: p.radiusFactor, reduction: Float(plan.factor), legacyRadius: nil)
            if cutToFrame { Self.cutToMaskRect(&u1) }
            func draw(_ uniforms: Uniforms, into target: MTLTexture) {
                var uu = uniforms
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                guard let enc = layerEncoder(commandBuffer, pass) else { return }
                enc.setRenderPipelineState(renderPipeline)
                bindLayer(enc, &uu, cur.tex0, cur.tex1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
            // Effect mask input: keep the picture the effect reads, mix its result back over it by the masks' coverage.
            // A masked key: the same draw without the keys is that picture.
            var pre: MTLTexture?
            if seg.scopesKeys, let t = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight) {
                retainer.pooled.append(t)
                var u0 = u1
                u0.keyCount = 0
                draw(u0, into: t)
                pre = t
            }
            draw(u1, into: a)
            if pre == nil, !seg.scope.isEmpty, seg.shadow == nil, seg.filter != nil || b != nil,
               let t = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight) {
                retainer.pooled.append(t)
                if let blit = commandBuffer.makeBlitCommandEncoder() {
                    blit.copy(from: a, to: t)
                    blit.endEncoding()
                    pre = t
                }
            }
            if let sh = seg.shadow {
                // Shadow: the picture `a` stays at full size; only its alpha plane is shifted and blurred, at reduced size when
                // the softness is large, then composited under the picture (upsampled) into `c`.
                guard let c = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight),
                      encodeShadow(sh, plan: plan, image: a, result: c, retainer: retainer, commandBuffer: commandBuffer)
                else { break }
                retainer.pooled.append(c)
                a = c
            } else if let f = seg.filter {
                // Whole-picture effect on the segment's picture; the clip's own frame sits centered in the texture.
                let pf = Float(plan.factor)
                let frame = ImageFilters.Frame(center: SIMD2(Float(plan.textureWidth), Float(plan.textureHeight)) / 2,
                                               size: layerSize / pf)
                guard let c = encodeFilter(f, image: a, frame: frame, pf: Double(plan.factor), retainer: retainer,
                                           commandBuffer: commandBuffer) else { break }
                a = c
            } else if let g = seg.grade {
                // Masked Color effect: graded into a new texture, so the drawn picture is already the scope's "before".
                if let c = gradeSegment(g, a, commandBuffer: commandBuffer, retainer: retainer) {
                    if !seg.scope.isEmpty { pre = a }
                    a = c
                }
            } else if let b {
                let edges = seg.blurRepeatsEdges
                    ? Self.repeatEdgeRect(frame: layerSize / Float(plan.factor), texture: SIMD2(plan.textureWidth, plan.textureHeight))
                    : nil
                encodeBlur(plan, from: a, via: b, commandBuffer: commandBuffer, repeatEdges: edges)
            }
            if let pre, let out = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight) {
                retainer.pooled.append(out)
                var scopeMap = Self.screenFromLocal(p.u)
                if scopeFocal > 0 { scopeMap.tilt.z = scopeFocal }
                if encodeMaskScope(seg.scope, layer: layer, pre: pre, post: a, out: out, frame: layerSize / Float(plan.factor),
                                   pf: Float(plan.factor), screen: scopeMap, commandBuffer: commandBuffer,
                                   retainer: retainer) {
                    a = out
                }
            }
            cutToFrame = seg.blurAfter > 0 && seg.blurRepeatsEdges && seg.shadow == nil && seg.filter == nil

            // The result is an image like a nested sequence's (mode 3), centered where the layer was.
            var next = p
            next.tex0 = a; next.tex1 = dummy
            next.u.mode = 3; next.u.linearize = 0; next.u.quarter = 0; next.u.part = .zero
            curSize = SIMD2(plan.outputWidth, plan.outputHeight)
            next.u.size = curSize
            cur = next
            first = false
        }

        // Last pass: into the composite with the layer's transform. After the first pass the mask rectangle is still the layer's
        // own picture, not the (larger) blurred image.
        var fin = cur
        fin.u = p.u
        fin.tex0 = cur.tex0; fin.tex1 = cur.tex1
        fin.blend = p.blend
        if !first {
            fin.u.mode = 3; fin.u.linearize = 0; fin.u.quarter = 0; fin.u.part = .zero
            fin.u.size = curSize
            fin.u.maskSize = layerSize
        }
        if fin.u.tilt.z > 0 { fin.u.tilt.z = Self.tiltFocal(fin.u) }   // the padded size sets the camera distance
        fin.u.keyCount = 0; fin.u.crop = .zero; fin.u.roundFirst = 0; fin.u.cropFeather = 0
        if let last = segs.last {
            Self.configure(&fin.u, last, radiusFactor: p.radiusFactor, reduction: 1, legacyRadius: nil)
        }
        if cutToFrame { Self.cutToMaskRect(&fin.u) }
        emit(fin)
    }

    /// Drop Shadow through the shared pass (`EffectPasses.shadow`). false when no texture was available.
    func encodeShadow(_ sh: DropShadow, plan: GaussianBlur.Plan, image: MTLTexture, result: MTLTexture,
                      retainer: Retainer, commandBuffer: MTLCommandBuffer) -> Bool {
        passes.shadow(sh, plan: plan, image: MetalGPUTexture(image), result: MetalGPUTexture(result), gpu.wrap(commandBuffer),
                      acquire: pooledScratch(retainer))
    }

    /// Runs `filter` on `image` (premultiplied, picture centered) into a new pooled texture of the same size and returns it;
    /// nil when it could not run. `frame`: the clip's own frame in texture px; `pf`: clip px per texture px.
    func encodeFilter(_ filter: ImageFilter, image: MTLTexture, frame: ImageFilters.Frame, pf: Double,
                      retainer: Retainer, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let out = acquireIntermediate(width: image.width, height: image.height) else { return nil }
        retainer.pooled.append(out)
        return passes.filter(filter, image: MetalGPUTexture(image), into: MetalGPUTexture(out), frame: frame, pf: pf,
                             gpu.wrap(commandBuffer), acquire: pooledScratch(retainer)) ? out : nil
    }

    /// Pooled scratch for the SQGPU passes, kept alive with the frame like every other pooled texture.
    func pooledScratch(_ retainer: Retainer) -> (Int, Int) -> MetalGPUTexture? {
        { [self] w, h in
            guard let t = acquireIntermediate(width: w, height: h) else { return nil }
            retainer.pooled.append(t)
            return MetalGPUTexture(t)
        }
    }

    /// Separable Gaussian in place: `a` is read, blurred horizontally into `b`, then vertically back into `a`.
    /// `repeatEdges`: reads clamp into that texture px rectangle (Repeat Edge Pixels) instead of zero outside the texture.
    func encodeBlur(_ plan: GaussianBlur.Plan, from a: MTLTexture, via b: MTLTexture, commandBuffer: MTLCommandBuffer,
                    repeatEdges: (lo: SIMD2<Int32>, hi: SIMD2<Int32>)? = nil) {
        kernels.blur(gpu.wrap(commandBuffer), MetalGPUTexture(a), via: MetalGPUTexture(b),
                     weights: GaussianBlur.weights(sigma: plan.sigma, radius: plan.radius), repeatEdges: repeatEdges)
    }
}
#endif
