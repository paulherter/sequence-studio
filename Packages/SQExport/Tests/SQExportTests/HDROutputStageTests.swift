import Foundation
import Metal
import simd
import Testing
@testable import SQExport

/// The export output stage really converts: the HLG / PQ kernels agree with the CPU reference `HDRDelivery.encode`, and
/// the SDR kernel is unchanged.
@Suite struct HDROutputStageTests {
    private func run(_ hdr: HDRDelivery.Transfer?, _ pixels: [SIMD3<Float>]) throws -> [SIMD3<Float>]? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let lib = try device.makeLibrary(source: ExportShaderSource.msl(hdr: hdr), options: nil)
        let pipe = try device.makeComputePipelineState(function: lib.makeFunction(name: "encodeBGRA")!)
        let n = pixels.count
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: n, height: 1, mipmapped: false)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: n, height: 1, mipmapped: false)
        sd.usage = [.shaderRead]; dd.usage = [.shaderWrite]
        dd.storageMode = .shared
        // The kernel writes whatever the destination holds; a half-float destination keeps full precision for the compare.
        guard let src = device.makeTexture(descriptor: sd), let dst = device.makeTexture(descriptor: dd) else { return nil }
        var half: [Float16] = []
        for p in pixels { half.append(Float16(p.x)); half.append(Float16(p.y)); half.append(Float16(p.z)); half.append(1) }
        src.replace(region: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0, withBytes: half, bytesPerRow: n * 8)
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pipe)
        enc.setTexture(src, index: 0); enc.setTexture(dst, index: 1)
        enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: n, height: 1, depth: 1))
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var out = [Float16](repeating: 0, count: n * 4)
        dst.getBytes(&out, bytesPerRow: n * 8, from: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0)
        var result: [SIMD3<Float>] = []
        for i in 0..<n { result.append(SIMD3<Float>(Float(out[i * 4]), Float(out[i * 4 + 1]), Float(out[i * 4 + 2]))) }
        return result
    }

    private let samples: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0.18, 0.18, 0.18), SIMD3(1, 1, 1), SIMD3(2.5, 2.5, 2.5),
                                           SIMD3(0.8, 0.2, 0.1), SIMD3(0.05, 0.4, 0.9)]

    @Test(arguments: [HDRDelivery.Transfer.hlg, .pq])
    func gpuMatchesTheCPUReference(_ t: HDRDelivery.Transfer) throws {
        guard let gpu = try run(t, samples) else { return }
        let ref = HDRDelivery(transfer: t)
        for (g, s) in zip(gpu, samples) {
            let e = ref.encode(s)
            #expect(simd_length(g - e) < 0.01, "\(t) \(s): gpu \(g) cpu \(e)")
        }
    }

    @Test func referenceWhiteLandsOnTheStandardCodes() {
        #expect(abs(HDRDelivery(transfer: .pq).encode(SIMD3(repeating: 1)).x - 0.5806) < 0.002)   // 203 nit in PQ
        #expect(abs(HDRDelivery(transfer: .hlg).encode(SIMD3(repeating: 1)).x - 0.75) < 0.002)    // reference white in HLG
    }

    @Test func sdrKernelStaysRec709() throws {
        guard let gpu = try run(nil, samples) else { return }
        for (g, s) in zip(gpu, samples) {
            let c = simd_clamp(s, .zero, .one)
            func oetf(_ v: Float) -> Float { v < 0.018053968 ? 4.5 * v : 1.0992968 * powf(v, 0.45) - 0.0992968 }
            let e = SIMD3<Float>(oetf(c.x), oetf(c.y), oetf(c.z))
            #expect(simd_length(g - e) < 0.01)
        }
    }
}
