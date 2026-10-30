#if canImport(Metal)
import Foundation
import Metal
import SQGPU
import SQGPUKernels
import SQGPUMetal
import Testing
@testable import SQRender

/// `GPUCompositor.resampleLinear` (image sequences at another size than the sequence) against the Mac `encodeRGBAHalf`
/// sampling: one bilinear tap at the output pixel's center, clamped to the edge, premultiplied alpha kept.
@Suite struct GPUCompositorResampleTests {
    private func bilinear(_ px: [Float], _ w: Int, _ h: Int, _ u: Float, _ v: Float, _ c: Int) -> Float {
        let x = u * Float(w) - 0.5, y = v * Float(h) - 0.5
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down)), fx = x - Float(x0), fy = y - Float(y0)
        func at(_ i: Int, _ j: Int) -> Float { px[(min(max(j, 0), h - 1) * w + min(max(i, 0), w - 1)) * 4 + c] }
        let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx, bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    @Test(arguments: [(25, 17), (64, 50), (40, 12)])
    func resampledLinearFramesMatchTheMacImageSequenceTap(size: (Int, Int)) throws {
        guard let d = MTLCreateSystemDefaultDevice() else { return }
        let gpu = try MetalGPUDevice(device: d)
        let kernels = try GPUKernels(device: gpu)
        let compositor = try GPUCompositor(device: gpu)
        let w = 40, h = 30
        var px = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let a: Float = x < 8 ? 0 : min(1, Float(y) / 20 + 0.2), i = (y * w + x) * 4
            px[i] = Float(x) / Float(w) * a; px[i + 1] = Float((x * 7 + y * 3) % 17) / 16 * a
            px[i + 2] = (x / 5 + y / 5) % 2 == 0 ? 0.9 * a : 0.1 * a; px[i + 3] = a
        } }
        let staging = try #require(gpu.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba32Float, cpuAccessible: true)))
        let source = try #require(gpu.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba16Float)))
        px.withUnsafeBytes { gpu.upload($0, bytesPerRow: w * 16, to: staging) }
        let (ow, oh) = size
        let target = try #require(gpu.makeTexture(GPUTextureDescriptor(width: ow, height: oh, format: .rgba16Float)))
        let out = try #require(gpu.makeTexture(GPUTextureDescriptor(width: ow, height: oh, format: .rgba32Float, cpuAccessible: true)))
        let cb = try #require(gpu.makeCommandBuffer())
        kernels.blendFrames(cb, staging, staging, into: source, weight: 0, encoded: false)
        try compositor.resampleLinear(source, into: target, commandBuffer: cb)
        kernels.blendFrames(cb, target, target, into: out, weight: 0, encoded: false)
        gpu.commitAndWait(cb)
        let got = gpu.download(out).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var worst: Float = 0
        for y in 0..<oh { for x in 0..<ow { for c in 0..<4 {
            let u = (Float(x) + 0.5) / Float(ow), v = (Float(y) + 0.5) / Float(oh)
            worst = max(worst, abs(got[(y * ow + x) * 4 + c] - bilinear(px, w, h, u, v, c)))
        } } }
        #expect(worst <= 2 / 255, "\(ow)x\(oh): max difference \(worst)")
    }
}
#endif
