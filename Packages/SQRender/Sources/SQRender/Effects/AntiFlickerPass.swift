import Foundation
import SQCore
#if canImport(Metal)
import Metal
import SQGPUKernels
import SQGPUMetal
import simd
#endif

/// Motion's Anti-flicker Filter: a vertical-only 3-tap softening ([k, 1 - 2k, k], k = strength / 4, so 1 = [1/4, 1/2, 1/4]) that
/// calms thin horizontal detail shimmering on interlaced displays. Strength 0 runs nothing. Slang kernel
/// antiFlickerVertical (Packages/SQGPU/Shaders/Pointwise.slang).
public enum AntiFlickerFilter {
    /// Weight of each neighbor row for a strength (clamped to 0...1).
    public static func neighborWeight(strength: Double) -> Float { Float(min(max(strength, 0), 1) / 4) }

    /// CPU reference of one column (rows top to bottom, edge rows repeat). The GPU kernel computes the same sum.
    public static func filtered(column: [Float], strength: Double) -> [Float] {
        let k = neighborWeight(strength: strength)
        guard k > 0, column.count > 1 else { return column }
        return column.indices.map { i in
            let up = column[max(i - 1, 0)], down = column[min(i + 1, column.count - 1)]
            return k * up + (1 - 2 * k) * column[i] + k * down
        }
    }
}

#if canImport(Metal)
extension Compositor {
    /// The layer drawn upright into an intermediate, softened vertically, handed on as an image like a nested sequence's
    /// (mode 3). nil = could not run (too large, no texture): the layer is drawn unfiltered. Crop, corners and keys are left
    /// to the segments' own draws.
    func applyAntiFlicker(_ strength: Double, to p: Prepared, commandBuffer: MTLCommandBuffer, retainer: Retainer) -> Prepared? {
        guard strength > 0 else { return nil }
        let w = max(1, Int(p.u.size.x.rounded())), h = max(1, Int(p.u.size.y.rounded()))
        guard max(w, h) <= GaussianBlur.maxTextureSize,
              let a = acquireIntermediate(width: w, height: h) else { return nil }
        retainer.pooled.append(a)
        guard let b = acquireIntermediate(width: w, height: h) else { return nil }
        retainer.pooled.append(b)

        var u1 = p.u
        u1.canvas = SIMD2(Float(w), Float(h)); u1.size = u1.canvas
        u1.position = .zero; u1.anchor = .zero; u1.scale = SIMD2(1, 1)
        u1.rotCos = 1; u1.rotSin = 0; u1.opacity = 1; u1.blend = 0; u1.tilt = .zero
        u1.maskCount = 0; u1.crop = .zero; u1.roundFirst = 0; u1.cropFeather = 0; u1.cornerRadius = 0; u1.keyCount = 0
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = a
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = layerEncoder(commandBuffer, pass) else { return nil }
        enc.setRenderPipelineState(renderPipeline)
        bindLayer(enc, &u1, p.tex0, p.tex1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        kernels.antiFlicker(gpu.wrap(commandBuffer), MetalGPUTexture(a), into: MetalGPUTexture(b),
                            k: AntiFlickerFilter.neighborWeight(strength: strength))

        var out = p
        out.tex0 = b; out.tex1 = dummy
        out.u.mode = 3; out.u.linearize = 0; out.u.quarter = 0; out.u.part = .zero
        out.u.size = SIMD2(Float(w), Float(h))
        out.u.maskSize = .zero
        return out
    }
}
#endif
