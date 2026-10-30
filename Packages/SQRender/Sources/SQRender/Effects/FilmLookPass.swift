#if canImport(Metal)
import Foundation
import Metal
import SQCore
import SQGPU
import simd

/// The film / tape look as one extra pass at the end of a layer's effect chain (see `FilmLook`).
///
/// 1. The layer's final draw (masks, keys and blurs already applied) is drawn upright into a pooled texture `a`.
/// 2. One compute kernel reads `a` and writes tracking noise, chroma bleed, grain and scanlines into texture `b` (a few
///    dependent texture reads per pixel, one write).
/// 3. The layer is composited from `b` like a nested sequence image, with its own transform, opacity and blend mode.
/// Grain and scanlines alone (no neighbor reads) run steps 1 and 2 as one draw straight into `b`, same bits.
extension Compositor {
    /// Draws `p` (the layer's final draw) through the look pass. Returns the draw to queue instead: same transform, opacity and
    /// blend, but sourcing the processed image. nil when the textures cannot be allocated (the caller then draws `p` plain).
    func applyLook(_ look: FilmLook, to p: Prepared, commandBuffer: MTLCommandBuffer, retainer: Retainer) -> Prepared? {
        guard look.needsPass else { return nil }
        let w = max(1, Int(p.u.size.x.rounded())), h = max(1, Int(p.u.size.y.rounded()))
        guard max(w, h) <= GaussianBlur.maxTextureSize else { return nil }
        // Grain and scanlines read only their own pixel: steps 1 and 2 run as one draw into `b` (no `a`, no kernel pass).
        let fused = fusesPointwiseLook && look.chromaBleed == nil && look.tracking == nil
        var a: MTLTexture?
        if !fused {
            guard let t = acquireIntermediate(width: w, height: h) else { return nil }
            retainer.pooled.append(t)
            a = t
        }
        guard let b = acquireIntermediate(width: w, height: h) else { return nil }
        retainer.pooled.append(b)
        var lu = Self.lookUniforms(look, width: w, height: h)

        // 1. The layer upright, no transform, full opacity; crop, corners and keys stay (they are in layer px). Clip masks are
        // left to the final draw (step 3, same layer px): applied here as well they would cut twice (a soft edge squared).
        var u1 = p.u
        u1.canvas = SIMD2(Float(w), Float(h)); u1.size = u1.canvas
        u1.position = .zero; u1.anchor = .zero; u1.scale = SIMD2(1, 1)
        u1.rotCos = 1; u1.rotSin = 0; u1.opacity = 1; u1.blend = 0; u1.tilt = .zero
        u1.maskCount = 0
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = a ?? b
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = layerEncoder(commandBuffer, pass) else { return nil }
        enc.setRenderPipelineState(fused ? lookFusedPipeline : renderPipeline)
        bindLayer(enc, &u1, p.tex0, p.tex1)
        if fused { enc.setFragmentBytes(&lu, length: MemoryLayout<LookUniforms>.stride, index: 1) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        // 2. The look kernel (neighbor reads: chroma bleed, tracking).
        if let a {
            guard let cenc = computeEncoder(commandBuffer) else { return nil }
            cenc.setComputePipelineState(lookPipeline)
            cenc.setTexture(a, index: 0); cenc.setTexture(b, index: GPUBinding.metalOutputIndex)
            cenc.setBytes(&lu, length: MemoryLayout<LookUniforms>.stride, index: 0)
            cenc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            cenc.endEncoding()
        } else {
            fusedLookDraws += 1
        }

        // 3. Composite from the processed image.
        var out = p
        out.tex0 = b; out.tex1 = dummy
        out.u.mode = 3; out.u.linearize = 0; out.u.quarter = 0; out.u.part = .zero
        out.u.size = SIMD2(Float(w), Float(h))
        out.u.maskSize = .zero; out.u.crop = .zero; out.u.roundFirst = 0; out.u.cropFeather = 0; out.u.cornerRadius = 0; out.u.keyCount = 0
        return out
    }
}
#endif
