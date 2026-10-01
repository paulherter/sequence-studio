import Foundation
import Metal
import SQCore
import simd

extension Compositor {
    /// Turns the plain draw of a layer (`prepareLayer`) into the draw(s) with its effects, in effect-list order.
    ///
    /// The evaluated effects are a list of segments cut at every blur (see `ClipEffects`). A layer with one segment (no blur)
    /// rides along in the one draw: Crop and Rounded Corners are a coverage mask, Ultra Key a colour/alpha step, both inside the
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
        let segs = fx.segments

        guard segs.count > 1 else {
            // One pass: everything rides along in the plain draw.
            if let seg = segs.first {
                configure(&p.u, seg, radiusFactor: p.radiusFactor, reduction: 1, legacyRadius: layer.cornerRadius)
            }
            prepared.append(p)
            return
        }

        let layerSize = p.u.size
        var cur = p                                  // what the next pass reads: the layer itself, then each blurred image
        var curSize = layerSize                      // its size in layer px
        var first = true
        for seg in segs.dropLast() {
            let plan = GaussianBlur.Plan(layerWidth: Double(curSize.x), layerHeight: Double(curSize.y), sigma: seg.blurAfter)
            guard let a = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight) else { break }
            var b: MTLTexture?
            if seg.blurAfter > 0 {
                b = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight)
                if b == nil { retainer.pooled.append(a); break }
            }
            retainer.pooled.append(a)
            if let b { retainer.pooled.append(b) }

            var u1 = cur.u
            u1.canvas = SIMD2(Float(plan.textureWidth), Float(plan.textureHeight))
            u1.size = SIMD2(curSize.x / Float(plan.factor), curSize.y / Float(plan.factor))
            u1.position = .zero; u1.anchor = .zero; u1.scale = SIMD2(1, 1)
            u1.rotCos = 1; u1.rotSin = 0; u1.opacity = 1; u1.blend = 0
            u1.maskSize = first ? .zero : SIMD2(layerSize.x / Float(plan.factor), layerSize.y / Float(plan.factor))
            u1.keyCount = 0; u1.crop = .zero; u1.roundFirst = 0
            configure(&u1, seg, radiusFactor: p.radiusFactor, reduction: Float(plan.factor), legacyRadius: nil)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = a
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                enc.setRenderPipelineState(renderPipeline)
                enc.setCullMode(.none)
                enc.setVertexBytes(&u1, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setFragmentBytes(&u1, length: MemoryLayout<Uniforms>.stride, index: 0)
                enc.setFragmentTexture(cur.tex0, index: 0)
                enc.setFragmentTexture(cur.tex1, index: 1)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                enc.endEncoding()
            }
            if let b { encodeBlur(plan, from: a, via: b, commandBuffer: commandBuffer) }

            // The result is an image like a nested sequence's (mode 3), centred where the layer was.
            var next = p
            next.tex0 = a; next.tex1 = dummy
            next.u.mode = 3; next.u.linearize = 0; next.u.quarter = 0
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
            fin.u.mode = 3; fin.u.linearize = 0; fin.u.quarter = 0
            fin.u.size = curSize
            fin.u.maskSize = layerSize
        }
        fin.u.keyCount = 0; fin.u.crop = .zero; fin.u.roundFirst = 0
        if let last = segs.last {
            configure(&fin.u, last, radiusFactor: p.radiusFactor, reduction: 1, legacyRadius: nil)
        }
        prepared.append(fin)
    }

    /// Writes one segment's masks and keys into the uniforms. `reduction` > 1: the pass draws at 1/reduction size.
    /// `legacyRadius`: the layer's own `cornerRadius`; when the segment says the same, the radius written by `prepareLayer` stays
    /// as it is (bit-identical to before effects existed).
    private func configure(_ u: inout Uniforms, _ seg: EffectSegment, radiusFactor: Double, reduction: Float, legacyRadius: Double?) {
        let m = seg.masks
        if !m.crop.isIdentity { u.crop = Self.cropVector(m.crop) }
        u.roundFirst = m.roundFirst && !m.crop.isIdentity && m.cornerRadius > 0 ? 1 : 0
        if let legacy = legacyRadius, m.cornerRadius == legacy {
            // keep prepareLayer's value
        } else {
            u.cornerRadius = Float(m.cornerRadius) * Float(radiusFactor) / reduction
        }
        u.keyCount = UInt32(min(seg.keys.count, ChromaKey.maxPerLayer))
        if seg.keys.count > 0 { u.key0 = UltraKey.vector(seg.keys[0]) }
        if seg.keys.count > 1 { u.key1 = UltraKey.vector(seg.keys[1]) }
    }

    static func cropVector(_ c: CropInsets) -> SIMD4<Float> {
        SIMD4(Float(c.left), Float(c.top), Float(c.right), Float(c.bottom))
    }

    /// Separable Gaussian in place: `a` is read, blurred horizontally into `b`, then vertically back into `a`.
    func encodeBlur(_ plan: GaussianBlur.Plan, from a: MTLTexture, via b: MTLTexture, commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let weights = GaussianBlur.weights(sigma: plan.sigma, radius: plan.radius)
        enc.setComputePipelineState(blurPipeline)
        weights.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        struct BlurUniforms { var axis: SIMD2<Int32>; var radius: Int32 }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: a.width, height: a.height, depth: 1)
        var h = BlurUniforms(axis: SIMD2(1, 0), radius: Int32(plan.radius))
        enc.setTexture(a, index: 0); enc.setTexture(b, index: 1)
        enc.setBytes(&h, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        var v = BlurUniforms(axis: SIMD2(0, 1), radius: Int32(plan.radius))
        enc.setTexture(b, index: 0); enc.setTexture(a, index: 1)
        enc.setBytes(&v, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }
}
