import Foundation
import SQGPU
import SQGPUKernels

/// A backend check of `ScopePasses`, shared by the Metal test and the D3D12 test on the PC: a gradient picture with
/// saturated patches (every scope and most bins hit), measured on the GPU and by `ScopesReference` on the CPU.
public enum ScopePassesCheck {
    public struct Result {
        public var gpu: ScopeCounts, cpu: ScopeCounts
        /// Bins whose counts differ (all four scopes); pixels on a bin edge may land one bin over (pow on another GPU).
        public var differingBins: Int
        /// Sum of |GPU - CPU| over every bin, halved: samples that landed in a neighbor bin.
        public var movedSamples: Int
        /// Samples per scope (pixels measured).
        public var samples: Int
        /// Median GPU time of one measurement at `width` x `height` (encode, wait, read the counts back), milliseconds.
        public var gpuMilliseconds: Double
    }

    /// The test picture, working-linear RGB, row-major.
    public static func picture(width w: Int, height h: Int) -> [SIMD3<Float>] {
        var px = [SIMD3<Float>](repeating: .zero, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let u = Float(x) / Float(max(w - 1, 1)), v = Float(y) / Float(max(h - 1, 1))
                var c = SIMD3<Float>(u, v * u, 1 - u) * 0.9
                if (x / 37 + y / 23) % 5 == 0 { c = SIMD3(1, 0.05, 0.02) }        // saturated red patches
                if (x / 41 + y / 29) % 7 == 0 { c = SIMD3(0.02, 0.4 * v, 0.95) }   // blue patches
                px[y * w + x] = c
            }
        }
        return px
    }

    /// Runs the check on `device` (`runs` timed measurements after one warm-up).
    public static func run<D: GPUDevice>(on device: D, width: Int = 1920, height: Int = 1080, pixelStride: Int = 1,
                                         runs: Int = 5) throws -> Result? {
        let px = picture(width: width, height: height)
        var bytes = [Float](repeating: 1, count: width * height * 4)
        for (i, p) in px.enumerated() { bytes[i * 4] = p.x; bytes[i * 4 + 1] = p.y; bytes[i * 4 + 2] = p.z }
        let passes = try ScopePasses(device: device)
        let layout = ScopeLayout()
        guard let tex = device.makeTexture(GPUTextureDescriptor(width: width, height: height, format: .rgba32Float,
                                                                cpuAccessible: true)),
              let counts = passes.makeCounts(layout) else { return nil }
        bytes.withUnsafeBytes { device.upload($0, bytesPerRow: width * 16, to: tex) }
        guard var gpu = passes.measure(tex, counts: counts, layout: layout, pixelStride: pixelStride) else { return nil }
        var times: [Double] = []
        for _ in 0..<max(runs, 1) {
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let c = passes.measure(tex, counts: counts, layout: layout, pixelStride: pixelStride) else { return nil }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            gpu = c
        }
        let cpu = ScopesReference.compute(pixels: px, width: width, height: height, layout: layout, pixelStride: pixelStride)
        var d = 0, moved = 0
        for (a, b) in [(gpu.waveformLuma, cpu.waveformLuma), (gpu.waveformParade, cpu.waveformParade),
                       (gpu.vectorscope, cpu.vectorscope), (gpu.histogram, cpu.histogram)] {
            for (x, y) in zip(a, b) where x != y { d += 1; moved += Int(x > y ? x - y : y - x) }
        }
        let step = max(1, pixelStride)
        let samples = ((width + step - 1) / step) * ((height + step - 1) / step)
        return Result(gpu: gpu, cpu: cpu, differingBins: d, movedSamples: moved / 2, samples: samples,
                      gpuMilliseconds: times.sorted()[times.count / 2])
    }
}
