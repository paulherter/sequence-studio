import Foundation
import SQCore
import SQGPU
import SQGPUKernels

/// The compute passes of a layer's effect chain on the portable GPU protocol, written once for the Metal `Compositor` and the
/// `GPUCompositor` (D3D12): blur, Drop Shadow, the whole-picture filters (ImageFilters, StyleFilters, Outline, Long Shadow),
/// the effect mask scope and the film look kernel. Every texture is premultiplied working-linear rgba16Float; the clip's own
/// frame sits centered in the padded intermediate. `acquire` hands out a scratch texture of that size (kept alive until the
/// frame completed), nil when none is available.
struct EffectPasses<D: GPUDevice> {
    typealias Acquire = (Int, Int) -> D.Texture?

    /// Mirrors `ShadowU` (Shaders/DropShadow.slang).
    struct ShadowUniforms { var offset: SIMD2<Float>; var color: SIMD4<Float>; var shadowOnly: Int32; var spread: Float }

    let kernels: GPUKernels<D>
    let shadowExtract: D.Pipeline, shadowComposite: D.Pipeline

    init(device: D, kernels: GPUKernels<D>) throws {
        self.kernels = kernels
        shadowExtract = try device.makePipeline(GPUKernel(GeneratedShaders.dropShadow, "shadowExtract"))
        shadowComposite = try device.makePipeline(GPUKernel(GeneratedShaders.dropShadow, "shadowComposite"))
    }

    /// Separable Gaussian in place: `a` is read, blurred horizontally into `b`, then vertically back into `a`.
    /// `repeatEdges`: reads clamp into that texture px rectangle (Repeat Edge Pixels) instead of zero outside the texture.
    func blur(_ plan: GaussianBlur.Plan, from a: D.Texture, via b: D.Texture, _ cb: D.CommandBuffer,
              repeatEdges: (lo: SIMD2<Int32>, hi: SIMD2<Int32>)? = nil) {
        kernels.blur(cb, a, via: b, weights: GaussianBlur.weights(sigma: plan.sigma, radius: plan.radius), repeatEdges: repeatEdges)
    }

    /// Drop Shadow on `image` (premultiplied, full size, picture centered in the padded texture) into `result` (same size).
    /// The shadow's alpha plane is made at 1/`reduction` size (reduction grows with softness so the kernel stays short) and
    /// upsampled bilinearly when composited; the picture itself is never reduced. false when no texture was available.
    func shadow(_ sh: DropShadow, plan: GaussianBlur.Plan, image: D.Texture, result: D.Texture, _ cb: D.CommandBuffer,
                acquire: Acquire) -> Bool {
        let pf = Double(plan.factor)                                   // picture reduction (1 unless the texture would be huge)
        let sigma = sh.sigma / pf
        let red = max(1, Int((sigma / GaussianBlur.maxDirectSigma).rounded(.up)))
        let sw = max(1, (image.width + red - 1) / red), shh = max(1, (image.height + red - 1) / red)
        guard let s1 = acquire(sw, shh), let s2 = acquire(sw, shh) else { return false }
        let blurPlan = GaussianBlur.Plan(layerWidth: Double(sw), layerHeight: Double(shh), sigma: sigma / Double(red))
        // Offset in texture px of the full-size picture (uv shift), shared by both kernels; color is working-linear.
        let u = ShadowUniforms(offset: SIMD2(Float(sh.dx / pf), Float(sh.dy / pf)),
                               color: SIMD4(Compositor.lin(Float(sh.color.x)), Compositor.lin(Float(sh.color.y)),
                                            Compositor.lin(Float(sh.color.z)), Float(sh.opacity)),
                               shadowOnly: sh.shadowOnly ? 1 : 0, spread: Float(min(sh.spread, 0.99)))
        if let enc = cb.makeComputeEncoder() {
            enc.setPipeline(shadowExtract)
            enc.setInput(image, at: 0); enc.setOutput(s1)
            enc.setConstants(u)
            enc.dispatch(width: sw, height: shh)
            enc.end()
        }
        blur(blurPlan, from: s1, via: s2, cb)      // result stays in s1
        if let enc = cb.makeComputeEncoder() {
            enc.setPipeline(shadowComposite)
            enc.setInput(image, at: 0); enc.setInput(s1, at: 1); enc.setOutput(result)
            enc.setConstants(u)
            enc.dispatch(width: image.width, height: image.height)
            enc.end()
        }
        return true
    }

    /// Runs `filter` on `image` (premultiplied, picture centered) into `out` (same size). false when it could not run.
    /// `frame`: the clip's own frame in texture px; `pf`: clip px per texture px.
    func filter(_ filter: ImageFilter, image: D.Texture, into out: D.Texture, frame: ImageFilters.Frame, pf: Double,
                _ cb: D.CommandBuffer, acquire: Acquire) -> Bool {
        var u = ImageFilters.Uniforms(center: frame.center, frame: frame.size)
        func run(_ e: GPUKernels<D>.Entry, _ inputs: [D.Texture], _ output: D.Texture) {
            kernels.run(e, cb, inputs: inputs, output: output, constants: u)
        }
        func lin3(_ c: SIMD3<Double>) -> SIMD3<Float> {
            SIMD3(Compositor.lin(Float(c.x)), Compositor.lin(Float(c.y)), Compositor.lin(Float(c.z)))
        }
        switch filter {
        case .sharpen(let amount):
            kernels.sharpen(cb, image, into: out, amount: Float(amount),
                            rect: ImageFilters.pixelRect(frame, width: image.width, height: image.height))
        case .unsharpMask(let sigma, let amount, let threshold):
            // Blur of a copy at texture scale. shortcut: sigma is capped at GaussianBlur.maxDirectSigma texture px (radius
            // 12 px shown at 1:1 stays exact; a picture upscaled past that gets a slightly smaller radius), upgrade with a
            // reduced-size blur like Glow when a larger radius is needed.
            let s = min(sigma / pf, GaussianBlur.maxDirectSigma)
            guard let g1 = acquire(image.width, image.height), let g2 = acquire(image.width, image.height),
                  cb.copy(image, to: g1) else { return false }
            let r = ImageFilters.pixelRect(frame, width: image.width, height: image.height)
            let plan = GaussianBlur.Plan(layerWidth: Double(image.width), layerHeight: Double(image.height), sigma: s)
            blur(plan, from: g1, via: g2, cb, repeatEdges: (SIMD2(Int32(r.minX), Int32(r.minY)), SIMD2(Int32(r.maxX), Int32(r.maxY))))
            u.a = SIMD4(Float(amount), Float(threshold), 0, 0)
            u.i = SIMD4(Int32(r.minX), Int32(r.minY), Int32(r.maxX), Int32(r.maxY))
            run(.filterUnsharp, [image, g1], out)
        case .directionalBlur(let dx, let dy):
            return kernels.directionalBlur(cb, image, into: out, d: SIMD2(Float(dx / pf), Float(dy / pf)), acquire: acquire)
        case .mirror(let c, let angle):
            kernels.mirror(cb, image, into: out, normal: ImageFilters.mirrorNormal(angle),
                           center: frame.center + SIMD2(Float(c.x / pf), Float(c.y / pf)))
        case .noise(let amount, let color, let clip, let seed):
            kernels.noise(cb, image, into: out, amount: Float(amount), color: color, clip: clip, seed: seed)
        case .glow(let threshold, let sigma, let intensity, let tint):
            // Bright pass at 1/red size so the kernel stays short (as Drop Shadow does), blurred, added back upsampled.
            let s = sigma / pf
            let red = max(1, Int((s / GaussianBlur.maxDirectSigma).rounded(.up)))
            let sw = max(1, (image.width + red - 1) / red), sh = max(1, (image.height + red - 1) / red)
            guard let g1 = acquire(sw, sh), let g2 = acquire(sw, sh) else { return false }
            u.a = SIMD4(Float(threshold), Float(intensity), 0, 0)
            if let tint {
                u.b = SIMD4(lin3(tint), 1)
                u.i.x = 1
            }
            u.i.y = Int32(red)
            run(.filterGlowBright, [image], g1)
            if s > 0 {
                blur(GaussianBlur.Plan(layerWidth: Double(sw), layerHeight: Double(sh), sigma: s / Double(red)), from: g1, via: g2, cb)
            }
            run(.filterGlowAdd, [image, g1], out)
        case .mosaic(let columns, let rows, let sharp):
            return kernels.mosaic(cb, image, into: out, frameCenter: frame.center, frameSize: frame.size, columns: columns,
                                  rows: rows, sharp: sharp, acquire: acquire)
        case .outline(let width, let color, let softness, let position):
            let w = width / pf, soft = softness / pf
            let reach = (position == .centre ? w / 2 : w) + max(soft, 1) + 2
            return kernels.outline(cb, image, into: out, jumpSteps: OutlineFilters.jumpSteps(reach: reach), width: Float(w),
                                   softness: Float(soft), color: lin3(color), position: Int32(position.rawValue), acquire: acquire)
        case .longShadow(let angle, let length, let color, let fade, let opacity):
            // The shadow plane is held to `maxShapePassPixels` (the picture itself stays full size); `sx`, `sy` canvas px per
            // plane px. Steps are planned in plane px along the longer scale so a full-size plane keeps whole-pixel steps.
            let (pw, ph) = OutlineFilters.shadowPlaneSize(width: image.width, height: image.height)
            let sx = Double(image.width) / Double(pw), sy = Double(image.height) / Double(ph), sc = max(sx, sy)
            let len = length / pf / sc
            let dir = ImageFilter.longShadowDirection(degrees: angle)
            let steps = OutlineFilters.shadowSteps(length: len).map {
                SIMD3(Float(dir.x * $0 * sc / sx), Float(dir.y * $0 * sc / sy), Float(fade * $0 / len))
            }
            return kernels.longShadow(cb, image, into: out, planeWidth: pw, planeHeight: ph, steps: steps, color: lin3(color),
                                      opacity: Float(min(max(opacity, 0), 1)), acquire: acquire)
        default:
            // FB-T2 style filters: one pass each (StyleFilters).
            guard let (family, su) = StyleFilters.plan(filter, frame: frame, pf: pf) else { return false }
            u = su
            switch family {
            case .pixel: run(.filterStylePixel, [image], out)
            case .warp: run(.filterStyleWarp, [image], out)
            case .rgbSplit: run(.filterRGBSplit, [image], out)
            case .radialBlur: run(.filterRadialBlur, [image], out)
            case .lens: run(.filterLens, [image], out)
            case .glitch: run(.filterGlitch, [image], out)
            }
        }
        return true
    }
}
