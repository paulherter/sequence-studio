import Foundation
import Metal
import SQCore
import simd

extension Compositor {
    /// Turns the plain draw of a layer (`prepareLayer`) into the draw(s) with its effects:
    /// - Crop and Rounded Corners ride along as a coverage mask in the one draw (no extra pass);
    /// - Gaussian Blur renders the layer upright into a padded intermediate, blurs it in two compute passes and draws that
    ///   image with the layer's transform; masks that come after the blur in the effect list are applied on that draw;
    /// - the blend mode only selects the pipeline.
    /// A layer without effects goes through untouched: no effect maths runs.
    func finishLayer(_ p0: Prepared, layer: RenderLayer, format: SequenceFormat, commandBuffer: MTLCommandBuffer,
                     retainer: Retainer, into prepared: inout [Prepared]) {
        let fx = layer.effects.isIdentity ? ClipEffects(cornerRadius: layer.cornerRadius) : layer.effects
        if fx.isEmpty { return }
        var p = p0
        p.blend = layer.blendMode
        // Ultra Keys work on the picture itself, so they ride along in whichever draw samples it (the blur pre-pass or the plain draw).
        p.u.keyCount = UInt32(min(fx.keys.count, ChromaKey.maxPerLayer))
        if fx.keys.count > 0 { p.u.key0 = UltraKey.vector(fx.keys[0]) }
        if fx.keys.count > 1 { p.u.key1 = UltraKey.vector(fx.keys[1]) }

        if fx.blur <= 0 {
            let m = fx.pre.merged(with: fx.post)
            if !m.crop.isIdentity { p.u.crop = Self.cropVector(m.crop) }
            if m.cornerRadius != layer.cornerRadius { p.u.cornerRadius = Float(m.cornerRadius) * Float(p.radiusFactor) }
            prepared.append(p)
            return
        }

        let plan = GaussianBlur.Plan(layerWidth: Double(p.u.size.x), layerHeight: Double(p.u.size.y), sigma: fx.blur)
        guard let a = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight),
              let b = acquireIntermediate(width: plan.textureWidth, height: plan.textureHeight) else {
            prepared.append(p)          // no memory for the blur: show the picture rather than nothing
            return
        }
        retainer.pooled.append(a); retainer.pooled.append(b)

        // Pass 1: the layer, upright and untransformed, with the masks that come before the blur, into `a`.
        var u1 = p.u
        u1.canvas = SIMD2(Float(plan.textureWidth), Float(plan.textureHeight))
        u1.size = SIMD2(plan.contentWidth, plan.contentHeight)
        u1.position = .zero; u1.anchor = .zero; u1.scale = SIMD2(1, 1)
        u1.rotCos = 1; u1.rotSin = 0; u1.opacity = 1
        u1.blend = 0; u1.maskSize = .zero
        u1.crop = Self.cropVector(fx.pre.crop)
        u1.cornerRadius = Float(fx.pre.cornerRadius) * Float(p.radiusFactor) / Float(plan.factor)
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
            enc.setFragmentTexture(p.tex0, index: 0)
            enc.setFragmentTexture(p.tex1, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }

        // Passes 2 and 3: horizontal then vertical, a -> b -> a.
        encodeBlur(plan, from: a, via: b, commandBuffer: commandBuffer)

        // The blurred image is drawn like a nested-sequence image (mode 3) with the layer's own transform; its size is the
        // padded one, the mask rectangle stays the layer's picture.
        var fin = p
        fin.tex0 = a; fin.tex1 = dummy
        fin.u.mode = 3; fin.u.linearize = 0; fin.u.quarter = 0; fin.u.keyCount = 0      // keyed already in the pre-pass
        fin.u.maskSize = p.u.size
        fin.u.size = SIMD2(plan.outputWidth, plan.outputHeight)
        fin.u.crop = Self.cropVector(fx.post.crop)
        fin.u.cornerRadius = Float(fx.post.cornerRadius) * Float(p.radiusFactor)
        prepared.append(fin)
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
