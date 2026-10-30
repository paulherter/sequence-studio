import SQGPU
import SQGPUKernels

/// Optical flow for `TimeInterpolation.opticalFlow` on the GPU protocol (OpticalFlow.slang): the measuring and
/// interpolation passes the Metal `OpticalFlowEngine` and `GPUCompositor` (D3D12 on Windows) both run, so playback and
/// export on either backend move the same pixels. Portable: no Metal; the owner keeps the textures (pool, field cache).
///
/// Motion: dense pyramidal Lucas-Kanade on luma at a working size (long side 960, `.faster` 480), coarse to fine, a few
/// Gauss-weighted window iterations per level and a 3 x 3 median per level against outliers, measured both ways (A to B
/// and B to A), then a trust value per field (patch agreement along the vector times forward-backward consistency).
/// Picture: two candidates per output pixel moved to the instant `t`, weighted by how well their samples agree; where
/// neither agrees the plain frame blend shows (a failed estimate never looks worse than Blend frames).
final class OpticalFlowPasses<D: GPUDevice> {
    let kernels: GPUKernels<D>

    /// Forward and backward field with trust (rgba32Float, working size).
    struct Field { var forward: D.Texture; var backward: D.Texture }

    init(kernels: GPUKernels<D>) { self.kernels = kernels }

    /// Working size of the motion estimate for a `width` x `height` frame.
    static func workingSize(width: Int, height: Int, quality: FlowQuality) -> (Int, Int) {
        // Never above 3/4 of the frame: the box prefilter of the reduction steadies the gradients (measured: at full
        // size 8-bit gradients made large motions converge worse, 1.5 vs 0.3 steps error on the 32 px test).
        let long = max(width, height), cap = min(quality.workingLongSide, long * 3 / 4)
        guard long > cap, cap > 0 else { return (width, height) }
        let s = Double(cap) / Double(long)
        return (max(1, Int((Double(width) * s).rounded())), max(1, Int((Double(height) * s).rounded())))
    }

    /// Bytes of a flow pair kept for `width` x `height` frames (both rgba32Float fields).
    static func fieldBytes(width: Int, height: Int, quality: FlowQuality) -> Int {
        let (w, h) = workingSize(width: width, height: height, quality: quality)
        return 2 * w * h * GPUPixelFormat.rgba32Float.bytesPerPixel
    }

    /// Measures the flow pair of `a` and `b` (source-encoded RGB, full size) into `cb`. `scratch` hands out textures
    /// that are free again once `cb` finished; `field` makes the two kept rgba32Float fields. nil when a texture is
    /// missing (the caller then mixes plainly).
    func measure(a: D.Texture, b: D.Texture, quality: FlowQuality, _ cb: D.CommandBuffer,
                 scratch: (Int, Int, GPUPixelFormat) -> D.Texture?, field: (Int, Int) -> D.Texture?) -> Field? {
        let (w, h) = Self.workingSize(width: a.width, height: a.height, quality: quality)
        var sizes = [(w, h)]
        while let l = sizes.last, min(l.0, l.1) >= 16 { sizes.append(((l.0 + 1) / 2, (l.1 + 1) / 2)) }
        // Luma pyramids and gradients of both frames.
        var l0: [D.Texture] = [], l1: [D.Texture] = [], g0: [D.Texture] = [], g1: [D.Texture] = []
        for s in sizes {
            guard let x = scratch(s.0, s.1, .r32Float), let y = scratch(s.0, s.1, .r32Float),
                  let gx = scratch(s.0, s.1, .rg32Float), let gy = scratch(s.0, s.1, .rg32Float) else { return nil }
            l0.append(x); l1.append(y); g0.append(gx); g1.append(gy)
        }
        // The two fields at full working size are kept (cache); every other level is scratch.
        guard let outF = field(w, h), let outB = field(w, h),
              let finalF = scratch(w, h, .rg32Float), let finalB = scratch(w, h, .rg32Float) else { return nil }
        var levels: [[(D.Texture, D.Texture)]] = [[], []]
        for dir in 0..<2 {
            for s in sizes {
                guard let ping = scratch(s.0, s.1, .rg32Float), let pong = scratch(s.0, s.1, .rg32Float) else { return nil }
                levels[dir].append((ping, pong))
            }
        }
        guard let enc = cb.makeComputeEncoder() else { return nil }
        let none = GPUFlowUniforms()
        func run(_ e: GPUKernels<D>.Entry, _ inputs: [D.Texture], _ out: D.Texture, _ u: GPUFlowUniforms) {
            kernels.dispatch(enc, e, inputs: inputs, output: out, constants: u)
        }
        for (src, dst) in [(a, l0[0]), (b, l1[0])] { run(.ofLuma, [src], dst, none) }
        for i in 1..<sizes.count {
            for p in [l0, l1] { run(.ofDown, [p[i - 1]], p[i], none) }
        }
        for i in sizes.indices {
            for (l, g) in [(l0[i], g0[i]), (l1[i], g1[i])] { run(.ofGrad, [l], g, none) }
        }
        // Coarse to fine, both directions.
        let r = quality.radius, sigma = Float(r) * 0.75 + 0.5
        var lkp = GPUFlowUniforms()
        lkp.radius = r; lkp.lambda = 1e-4; lkp.invTwoSigma2 = 1 / (2 * sigma * sigma); lkp.maxStep = 2
        for dir in 0..<2 {
            let (i0, i1, gi0, gi1) = dir == 0 ? (l0, l1, g0, g1) : (l1, l0, g1, g0)
            var prev: D.Texture?
            for level in sizes.indices.reversed() {
                let s = sizes[level]
                let (ping, pong) = levels[dir][level]
                // Start: the coarser level's field scaled up (zero on the coarsest).
                var upU = GPUFlowUniforms()
                upU.hasPrev = prev == nil ? 0 : 1
                run(.ofUp, [prev ?? l0[level]], ping, upU)
                var cur = ping, other = pong
                for _ in 0..<(quality.iterations + (s.0 * s.1 <= 160 * 90 ? 2 : 0)) {
                    run(.ofLK, [i0[level], gi0[level], i1[level], gi1[level], cur], other, lkp)
                    swap(&cur, &other)
                }
                let dst = level == 0 ? (dir == 0 ? finalF : finalB) : other
                run(.ofMedian, [cur], dst, none)
                prev = dst
            }
        }
        // Trust of each field: patch agreement along the vector times forward-backward consistency.
        for (i0, i1, f, back, out) in [(l0[0], l1[0], finalF, finalB, outF), (l1[0], l0[0], finalB, finalF, outB)] {
            run(.ofConfidence, [i0, i1, f, back], out, none)
        }
        enc.end()
        return Field(forward: outF, backward: outB)
    }

    /// Writes the picture at `t` (0 = `a`, 1 = `b`) into `out`. `linearize`: `a`/`b` are source-encoded BT.709 (the mix
    /// runs in light, like Frame Blending); false: already working-linear.
    func interpolate(a: D.Texture, b: D.Texture, field: Field, t: Float, linearize: Bool, into out: D.Texture,
                     _ cb: D.CommandBuffer) {
        var p = GPUFlowUniforms()
        p.t = t; p.linearize = linearize ? 1 : 0; p.sigma = 0.1
        p.flowScale = SIMD2(Float(out.width) / Float(field.forward.width), Float(out.height) / Float(field.forward.height))
        kernels.run(.ofInterpolate, cb, inputs: [a, b, field.forward, field.backward], output: out, constants: p)
    }
}
