import SQGPU

// Compositor core and effect passes written once against the SQGPU protocol (portable). The Mac renderer (SQRender) calls
// them through SQGPUMetal; Windows through SQGPUD3D12. Planning that both sides need (taps, rects) lives here too.

/// Mirrors `FilterU` in Shaders/Filters.slang (96 bytes, HLSL packing identical).
public struct GPUFilterUniforms: BitwiseCopyable, Sendable, Equatable {
    public var a = SIMD4<Float>.zero, b = SIMD4<Float>.zero
    public var center = SIMD2<Float>.zero, frame = SIMD2<Float>.zero
    public var i = SIMD4<Int32>.zero
    /// Extra rows (the Stabilizer warp's perspective map); zero for every other kernel.
    public var c = SIMD4<Float>.zero, d = SIMD4<Float>.zero
    public init(center: SIMD2<Float> = .zero, frame: SIMD2<Float> = .zero) { self.center = center; self.frame = frame }
}

/// Mirrors `BlurU` in Shaders/Blur.slang (32 bytes).
/// Constant block of OpticalFlow.slang (FlowU): Lucas-Kanade step, interpolation and upscale parameters.
public struct GPUFlowUniforms: BitwiseCopyable, Sendable, Equatable {
    public var radius: Int32 = 0, lambda: Float = 0, invTwoSigma2: Float = 0, maxStep: Float = 0
    public var t: Float = 0, linearize: UInt32 = 0, flowScale = SIMD2<Float>(1, 1)
    public var sigma: Float = 0, hasPrev: UInt32 = 0, pad = SIMD2<Float>(0, 0)
    public init() {}
}

public struct GPUBlurUniforms: BitwiseCopyable, Sendable, Equatable {
    public var axis: SIMD2<Int32>; public var radius: Int32; public var clampEdges: Int32 = 0
    public var lo: SIMD2<Int32> = .zero, hi: SIMD2<Int32> = .zero
    public init(axis: SIMD2<Int32>, radius: Int32, clampEdges: Int32 = 0, lo: SIMD2<Int32> = .zero, hi: SIMD2<Int32> = .zero) {
        self.axis = axis; self.radius = radius; self.clampEdges = clampEdges; self.lo = lo; self.hi = hi
    }
}

/// Planning shared by the GPU passes and the CPU references.
public enum GPUFilterPlan {
    /// Pixels whose centers lie inside the frame (`origin`, `size` in texture px; inclusive bounds), kept in the image.
    public static func pixelRect(origin o: SIMD2<Float>, size: SIMD2<Float>, width: Int, height: Int)
        -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let e = o + size
        return (max(0, Int((o.x - 0.5).rounded(.up))), max(0, Int((o.y - 0.5).rounded(.up))),
                min(width - 1, Int((e.x - 0.5).rounded(.up)) - 1), min(height - 1, Int((e.y - 0.5).rounded(.up)) - 1))
    }

    public static let onePassTaps = 32

    /// Taps along the smear: about one per px, at least 2, at most 512. Above `onePassTaps` rounded up to a product a x b
    /// (a = ceil(sqrt n)), so the GPU runs it as two comb passes with exactly the same taps (`smearPasses`).
    public static func smearTaps(_ d: SIMD2<Float>) -> Int {
        let n = min(512, max(2, Int((d.x * d.x + d.y * d.y).squareRoot().rounded(.up)) + 1))
        guard n > onePassTaps else { return n }
        let a = Int(Double(n).squareRoot().rounded(.up))
        return a * ((n + a - 1) / a)
    }

    /// Two comb passes for `n` taps (fine: a taps one spacing apart; coarse: b taps a spacings apart), or nil for one pass.
    public static func smearPasses(_ n: Int) -> (fine: Int, coarse: Int)? {
        guard n > onePassTaps else { return nil }
        let a = Int(Double(n).squareRoot().rounded(.up))
        return n % a == 0 ? (a, n / a) : nil
    }

    /// Largest Gaussian kernel the blur pass takes (2 * radius + 1 weights; Shaders/Blur.slang `BlurW`).
    public static let maxBlurWeights = 128
}

/// The compute pipelines of the converted kernels on one device, built once.
public final class GPUKernels<Device: GPUDevice> {
    /// Every converted kernel; the case name is the shader entry name, the raw value the pipeline index.
    public enum Entry: Int, CaseIterable, Sendable {
        case gaussianBlur1D
        case premultipliedLinearToEncoded709, straightToPremultiplied, blendFrames
        case filterSharpen, filterDirectionalBlur, filterSmearComb, filterMirror, filterNoise
        case filterMosaicRows, filterMosaicBlocks, filterMosaicApply
        case filterUnsharp, filterGlowBright, filterGlowAdd
        case filterStylePixel, filterStyleWarp, filterLens, filterGlitch, filterRGBSplit, filterRadialBlur
        case filterOutlineSeed, filterOutlineJump, filterOutlineApply, filterLongShadowStep, filterLongShadowApply
        case antiFlickerVertical
        case ofLuma, ofDown, ofGrad, ofUp, ofLK, ofMedian, ofConfidence, ofInterpolate

        public var name: String { String(describing: self) }

        public var module: GPUShaderModule {
            switch self {
            case .gaussianBlur1D: GeneratedShaders.blur
            case .premultipliedLinearToEncoded709, .straightToPremultiplied, .blendFrames, .antiFlickerVertical: GeneratedShaders.pointwise
            case .filterSharpen, .filterDirectionalBlur, .filterSmearComb, .filterMirror, .filterNoise, .filterMosaicRows,
                 .filterMosaicBlocks, .filterMosaicApply, .filterUnsharp, .filterGlowBright, .filterGlowAdd, .filterStylePixel,
                 .filterStyleWarp, .filterLens, .filterGlitch, .filterRGBSplit, .filterRadialBlur, .filterOutlineSeed,
                 .filterOutlineJump, .filterOutlineApply, .filterLongShadowStep, .filterLongShadowApply: GeneratedShaders.filters
            case .ofLuma, .ofDown, .ofGrad, .ofUp, .ofLK, .ofMedian, .ofConfidence, .ofInterpolate: GeneratedShaders.opticalFlow
            }
        }
    }

    public let device: Device
    /// Indexed by Entry.rawValue: an array index, not a dictionary lookup, on every dispatch.
    private let pipelines: [Device.Pipeline]

    public init(device: Device) throws {
        self.device = device
        pipelines = try Entry.allCases.map { try device.makePipeline(GPUKernel($0.module, $0.name)) }
    }

    public func pipeline(_ e: Entry) -> Device.Pipeline { pipelines[e.rawValue] }

    /// One dispatch in its own encoder: `inputs` to in0..., `output` to out0, `constants` to block 0.
    public func run<U: BitwiseCopyable>(_ e: Entry, _ cb: Device.CommandBuffer, inputs: [Device.Texture], output: Device.Texture,
                                        constants: U, grid: (Int, Int)? = nil) {
        guard let enc = cb.makeComputeEncoder() else { return }
        enc.setPipeline(pipeline(e))
        for (i, t) in inputs.enumerated() { enc.setInput(t, at: i) }
        enc.setOutput(output)
        enc.setConstants(constants)
        let g = grid ?? (output.width, output.height)
        enc.dispatch(width: g.0, height: g.1)
        enc.end()
    }

    /// One dispatch into an open encoder (several passes share one encoder): grid = the output's size unless given.
    public func dispatch<U: BitwiseCopyable>(_ enc: Device.CommandBuffer.Encoder, _ e: Entry, inputs: [Device.Texture],
                                             output: Device.Texture, constants: U, grid: (Int, Int)? = nil) {
        enc.setPipeline(pipeline(e))
        for (i, t) in inputs.enumerated() { enc.setInput(t, at: i) }
        enc.setOutput(output)
        enc.setConstants(constants)
        let g = grid ?? (output.width, output.height)
        enc.dispatch(width: g.0, height: g.1)
    }

    // MARK: Compositor core

    /// Separable Gaussian in place: `a` is read, blurred horizontally into `b`, then vertically back into `a` (one encoder).
    /// `weights`: 2 * radius + 1 normalized taps (at most GPUFilterPlan.maxBlurWeights). `repeatEdges`: reads clamp into
    /// that texture px rectangle instead of zero outside the texture.
    public func blur(_ cb: Device.CommandBuffer, _ a: Device.Texture, via b: Device.Texture, weights: [Float],
                     repeatEdges: (lo: SIMD2<Int32>, hi: SIMD2<Int32>)? = nil) {
        guard weights.count <= GPUFilterPlan.maxBlurWeights, let enc = cb.makeComputeEncoder() else { return }
        let radius = Int32((weights.count - 1) / 2)
        enc.setPipeline(pipeline(.gaussianBlur1D))
        // The whole BlurW block (a shorter buffer than the declared struct trips Metal's validation and D3D12 bounds).
        var block = [Float](repeating: 0, count: GPUFilterPlan.maxBlurWeights)
        block.replaceSubrange(0..<weights.count, with: weights)
        block.withUnsafeBytes { enc.setConstantBytes($0, slot: 1) }
        let ce: Int32 = repeatEdges == nil ? 0 : 1, lo = repeatEdges?.lo ?? .zero, hi = repeatEdges?.hi ?? .zero
        enc.setInput(a, at: 0); enc.setOutput(b)
        enc.setConstants(GPUBlurUniforms(axis: SIMD2(1, 0), radius: radius, clampEdges: ce, lo: lo, hi: hi))
        enc.dispatch(width: a.width, height: a.height)
        enc.setInput(b, at: 0); enc.setOutput(a)
        enc.setConstants(GPUBlurUniforms(axis: SIMD2(0, 1), radius: radius, clampEdges: ce, lo: lo, hi: hi))
        enc.dispatch(width: a.width, height: a.height)
        enc.end()
    }

    /// Anti-flicker: vertical [k, 1 - 2k, k] softening, `k` = the neighbor weight (SQRender AntiFlickerFilter).
    public func antiFlicker(_ cb: Device.CommandBuffer, _ src: Device.Texture, into dst: Device.Texture, k: Float) {
        run(.antiFlickerVertical, cb, inputs: [src], output: dst, constants: SIMD4<Float>(k, 0, 0, 0), grid: (src.width, src.height))
    }

    /// Premultiplied working-linear -> straight BT.709-encoded, alpha kept (Adjustment Layer grade input).
    public func encode709(_ cb: Device.CommandBuffer, _ src: Device.Texture, into dst: Device.Texture) {
        run(.premultipliedLinearToEncoded709, cb, inputs: [src], output: dst, constants: SIMD4<Float>.zero, grid: (src.width, src.height))
    }

    /// Straight working-linear -> premultiplied.
    public func premultiply(_ cb: Device.CommandBuffer, _ src: Device.Texture, into dst: Device.Texture) {
        run(.straightToPremultiplied, cb, inputs: [src], output: dst, constants: SIMD4<Float>.zero, grid: (src.width, src.height))
    }

    /// Frame Blending in light-linear space: mix(lin(a), lin(b), weight); `encoded`: inputs are BT.709-encoded.
    public func blendFrames(_ cb: Device.CommandBuffer, _ a: Device.Texture, _ b: Device.Texture, into out: Device.Texture,
                            weight: Float, encoded: Bool) {
        run(.blendFrames, cb, inputs: [a, b], output: out, constants: SIMD4<Float>(weight, encoded ? 1 : 0, 0, 0))
    }

    // MARK: Effects (CPU references: SQRender ImageFilters)

    /// `rect`: the picture's pixel rect (GPUFilterPlan.pixelRect).
    public func sharpen(_ cb: Device.CommandBuffer, _ image: Device.Texture, into out: Device.Texture, amount: Float,
                        rect: (minX: Int, minY: Int, maxX: Int, maxY: Int)) {
        var u = GPUFilterUniforms()
        u.a.x = amount
        u.i = SIMD4(Int32(rect.minX), Int32(rect.minY), Int32(rect.maxX), Int32(rect.maxY))
        run(.filterSharpen, cb, inputs: [image], output: out, constants: u)
    }

    /// `normal`: unit normal of the reflection line; `center` in texture px.
    public func mirror(_ cb: Device.CommandBuffer, _ image: Device.Texture, into out: Device.Texture,
                       normal: SIMD2<Float>, center: SIMD2<Float>) {
        var u = GPUFilterUniforms(center: center)
        u.a = SIMD4(normal.x, normal.y, 0, 0)
        run(.filterMirror, cb, inputs: [image], output: out, constants: u)
    }

    public func noise(_ cb: Device.CommandBuffer, _ image: Device.Texture, into out: Device.Texture, amount: Float,
                      color: Bool, clip: Bool, seed: UInt32) {
        var u = GPUFilterUniforms()
        u.a.x = amount; u.i = SIMD4(color ? 1 : 0, clip ? 1 : 0, Int32(bitPattern: seed), 0)
        run(.filterNoise, cb, inputs: [image], output: out, constants: u)
    }

    /// `d`: smear vector in texture px. `acquire` hands out a scratch texture (rgba16Float, GPU-only) for the long-smear
    /// comb; false when none was available.
    @discardableResult
    public func directionalBlur(_ cb: Device.CommandBuffer, _ image: Device.Texture, into out: Device.Texture, d: SIMD2<Float>,
                                acquire: (Int, Int) -> Device.Texture?) -> Bool {
        let n = GPUFilterPlan.smearTaps(d)
        var u = GPUFilterUniforms()
        if let (fine, coarse) = GPUFilterPlan.smearPasses(n) {
            // Two comb passes (about 2 sqrt n taps instead of n). The fine pass writes a padded intermediate: the coarse
            // pass reaches half the smear beyond each edge, where the fine pass still sees the picture.
            let step = d / Float(n - 1)
            let r = step * Float(fine * (coarse - 1)) / 2
            let reach = SIMD2(abs(r.x), abs(r.y))
            // Rounded up to 16 px so an animated length reuses pooled textures.
            let px = (Int(reach.x.rounded(.up)) + 16) / 16 * 16, py = (Int(reach.y.rounded(.up)) + 16) / 16 * 16
            guard let mid = acquire(image.width + 2 * px, image.height + 2 * py) else { return false }
            u.a = SIMD4(step.x, step.y, 0, 0); u.b = SIMD4(Float(-px), Float(-py), 0, 0); u.i.x = Int32(fine)
            run(.filterSmearComb, cb, inputs: [image], output: mid, constants: u)
            let coarseStep = step * Float(fine)
            u.a = SIMD4(coarseStep.x, coarseStep.y, 0, 0); u.b = SIMD4(Float(px), Float(py), 0, 0); u.i.x = Int32(coarse)
            run(.filterSmearComb, cb, inputs: [mid], output: out, constants: u, grid: (image.width, image.height))
        } else {
            u.a = SIMD4(d.x, d.y, 0, 0); u.i.x = Int32(n)
            run(.filterDirectionalBlur, cb, inputs: [image], output: out, constants: u)
        }
        return true
    }

    /// Exact block means in two short passes (row means, then their mean): no thread ever loops over a whole block.
    /// `frameCenter`/`frameSize`: the clip's frame in texture px.
    @discardableResult
    public func mosaic(_ cb: Device.CommandBuffer, _ image: Device.Texture, into out: Device.Texture,
                       frameCenter: SIMD2<Float>, frameSize: SIMD2<Float>, columns: Int, rows: Int, sharp: Bool,
                       acquire: (Int, Int) -> Device.Texture?) -> Bool {
        let pr = GPUFilterPlan.pixelRect(origin: frameCenter - frameSize / 2, size: frameSize, width: image.width, height: image.height)
        let nRows = max(1, pr.maxY - pr.minY + 1)
        guard let blocks = acquire(columns, rows), let rowMeans = acquire(columns, nRows) else { return false }
        var u = GPUFilterUniforms(center: frameCenter, frame: frameSize)
        u.i = SIMD4(Int32(columns), Int32(rows), sharp ? 1 : 0, Int32(pr.minY))
        u.a = SIMD4(frameSize.x / Float(columns), frameSize.y / Float(rows), 0, 0)  // block size, see Filters.slang
        if !sharp { run(.filterMosaicRows, cb, inputs: [image], output: rowMeans, constants: u, grid: (columns, nRows)) }
        run(.filterMosaicBlocks, cb, inputs: [image, rowMeans], output: blocks, constants: u, grid: (columns, rows))
        run(.filterMosaicApply, cb, inputs: [image, blocks], output: out, constants: u)
        return true
    }

    /// Outline (CPU notes: SQRender OutlineFilters): alpha 0.5 crossings as seeds, jump-flood passes of `jumpSteps` px, then
    /// the band laid on/under the picture. `width`, `softness` in texture px, `color` linear, `position` 0 outside, 1 inside,
    /// 2 center. One encoder; two scratch textures of the image's size.
    @discardableResult
    public func outline(_ cb: Device.CommandBuffer, _ image: Device.Texture, into out: Device.Texture, jumpSteps: [Int],
                        width: Float, softness: Float, color: SIMD3<Float>, position: Int32,
                        acquire: (Int, Int) -> Device.Texture?) -> Bool {
        guard let s1 = acquire(image.width, image.height), let s2 = acquire(image.width, image.height),
              let enc = cb.makeComputeEncoder() else { return false }
        var u = GPUFilterUniforms()
        dispatch(enc, .filterOutlineSeed, inputs: [image], output: s1, constants: u)
        var a = s1, b = s2
        for step in jumpSteps {
            u.i.x = Int32(step)
            dispatch(enc, .filterOutlineJump, inputs: [a], output: b, constants: u)
            swap(&a, &b)
        }
        u.a = SIMD4(width, softness, 0, 0)
        u.b = SIMD4(color, 1)
        u.i.x = position
        dispatch(enc, .filterOutlineApply, inputs: [image, a], output: out, constants: u)
        enc.end()
        return true
    }

    /// Long Shadow: one doubling pass per step over the alpha into a `planeWidth x planeHeight` plane, then laid under the
    /// picture. `steps`: (step back x, y in plane px, fade over the step) each. `color` linear, `opacity` 0...1.
    @discardableResult
    public func longShadow(_ cb: Device.CommandBuffer, _ image: Device.Texture, into out: Device.Texture, planeWidth: Int,
                           planeHeight: Int, steps: [SIMD3<Float>], color: SIMD3<Float>, opacity: Float,
                           acquire: (Int, Int) -> Device.Texture?) -> Bool {
        guard !steps.isEmpty, let p1 = acquire(planeWidth, planeHeight), let p2 = acquire(planeWidth, planeHeight),
              let enc = cb.makeComputeEncoder() else { return false }
        var u = GPUFilterUniforms()
        var src = image, dst = p1, spare = p2
        for (i, h) in steps.enumerated() {
            u.a = SIMD4(h, 0)
            u.i.x = i == 0 ? 1 : 0
            dispatch(enc, .filterLongShadowStep, inputs: [src], output: dst, constants: u)
            src = dst
            swap(&dst, &spare)
        }
        u.a = SIMD4(0, 0, 0, opacity)
        u.b = SIMD4(color, 1)
        dispatch(enc, .filterLongShadowApply, inputs: [image, src], output: out, constants: u)
        enc.end()
        return true
    }
}
