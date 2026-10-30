#if canImport(Metal)
import Foundation
import Metal
import SQGPUKernels
import SQGPUMetal
import Testing
@testable import SQRender

/// The shared scope passes (`ScopePasses`, also the Windows monitor's) on the Metal backend against the CPU reference.
@Suite(.enabled(if: GPUTest.device != nil, "no Metal device")) struct ScopePassesTests {
    @Test func sharedPassesMatchTheCPUReference() throws {
        let gpu = try MetalGPUDevice(device: GPUTest.device!)
        guard let r = try ScopePassesCheck.run(on: gpu, width: 640, height: 360, runs: 1) else { Issue.record("no GPU resources"); return }
        // Smooth gradients put pixels on bin edges, where the GPU pow may round into the neighbor bin.
        #expect(r.movedSamples * 10_000 < r.samples * 5, "moved \(r.movedSamples) of \(r.samples), \(r.differingBins) bins")
        #expect(r.gpu.vectorscope.reduce(0, +) == UInt32(r.samples))
        #expect(r.gpu.histogram.reduce(0, +) == r.cpu.histogram.reduce(0, +))
        #expect(r.gpu.maxWaveformParade > 0 && r.gpu.maxHistogram > 0)
    }

    /// 1080p, every second pixel (the Scopes panel's stride): GPU measurement vs the CPU binning of the 8-bit readback the
    /// Windows panel used before. Prints both times (debug builds: the CPU number is unoptimized).
    @Test func gpuMeasurementIsTimedAgainstTheCPUBinning() throws {
        let gpu = try MetalGPUDevice(device: GPUTest.device!)
        guard let r = try ScopePassesCheck.run(on: gpu, pixelStride: 2) else { Issue.record("no GPU resources"); return }
        #expect(r.movedSamples * 10_000 < r.samples * 5)
        print("SQ scopes moved \(r.movedSamples) of \(r.samples) samples, \(r.differingBins) bins")
        let rgba = [UInt8](repeating: 90, count: 1920 * 1080 * 4)
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = ScopeBinning.compute(rgba: rgba, width: 1920, height: 1080, layout: ScopeLayout(), pixelStride: 2)
        let cpu = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        print("SQ scopes 1080p stride 2: GPU \(String(format: "%.2f", r.gpuMilliseconds)) ms, CPU binning \(String(format: "%.2f", cpu)) ms")
    }
}
#endif
