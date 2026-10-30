import Foundation
import Testing
#if os(Windows)
import SQGPUD3D12
import SQRender

/// The shared scope passes (`ScopePasses`, the Mac ScopesGPU passes) on D3D12 against the CPU reference, timed at 1080p.
@Suite struct ScopePassesD3D12Tests {
    @Test func scopesOnD3D12MatchTheCPUReference() throws {
        let gpu = try D3D12GPUDevice()
        for stride in [1, 2] {
            guard let r = try ScopePassesCheck.run(on: gpu, pixelStride: stride) else { Issue.record("no GPU resources"); return }
            #expect(gpu.lastCommitSucceeded)
            #expect(r.gpu.vectorscope.reduce(0, +) == UInt32(r.samples))
            #expect(r.gpu.histogram.reduce(0, +) == r.cpu.histogram.reduce(0, +))
            #expect(r.movedSamples * 10_000 < r.samples * 5, "moved \(r.movedSamples) of \(r.samples)")
            print("SQGPU D3D12 \(gpu.name): scopes 1080p stride \(stride) \(String(format: "%.2f", r.gpuMilliseconds)) ms, "
                  + "moved \(r.movedSamples) of \(r.samples) samples, \(r.differingBins) bins")
        }
    }
}
#endif
