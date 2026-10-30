import Testing
import SQGPU
import SQGPUKernels
#if canImport(Metal)
import Metal
import SQGPUMetal
import Foundation
#endif

@Suite struct SQGPUPortableTests {
    @Test func uniformLayoutsMirrorTheShaders() {
        #expect(MemoryLayout<GPUFilterUniforms>.size == 96)
        #expect(MemoryLayout<GPUBlurUniforms>.size == 32)
        #expect(MemoryLayout<GPUFlowUniforms>.size == 48)
    }

    @Test func everyKernelHasMSLAndHLSL() {
        for e in GPUKernels<NoDevice>.Entry.allCases {
            #expect(e.module.entries.contains(e.name), "\(e.name) missing in \(e.module.name)")
            #expect(e.module.msl.contains("void \(e.name)("))
            #expect(e.module.hlsl[e.name]?.contains("void \(e.name)(") == true)
        }
        // Modules whose engines build their own pipelines (scopes, temporal) too.
        for m in GeneratedShaders.all {
            #expect(!m.entries.isEmpty, "\(m.name) has no entries")
            for name in m.entries {
                // Compute entries return void; vertex / fragment entries return their stage output.
                let sig = m.stage(of: name) == .compute ? "void \(name)(" : " \(name)("
                #expect(m.msl.contains(sig), "\(name) missing in \(m.name) MSL")
                #expect(m.hlsl[name]?.contains(sig) == true, "\(name) missing in \(m.name) HLSL")
            }
        }
    }

    @Test func smearPlanSplitsLongSmears() {
        #expect(GPUFilterPlan.smearTaps(SIMD2(10, 0)) == 11)
        let n = GPUFilterPlan.smearTaps(SIMD2(60, 20))
        let p = GPUFilterPlan.smearPasses(n)
        #expect(p != nil && p!.fine * p!.coarse == n)
    }

    @Test func pngHasSignatureAndChunks() {
        let png = GPUPNG.encode(rgba: [UInt8](repeating: 128, count: 4 * 4 * 4), width: 4, height: 4)
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        #expect(png.count > 8 + 25 + 12 + 64)
    }

    @Test func gaussianWeightsAreNormalized() {
        let w = GPUReferenceGraph.gaussianWeights(sigma: 3)
        #expect(w.count == 19)
        #expect(abs(w.reduce(0, +) - 1) < 1e-5)
    }
}

/// Placeholder device so the portable test can name `GPUKernels.Entry` without a backend.
final class NoDevice: GPUDevice {
    struct T: GPUTexture { var width = 0, height = 0, depth = 1, format = GPUPixelFormat.rgba16Float }
    struct B: GPUBuffer { var length = 0 }
    struct E: GPUComputeEncoder {
        func setBuffer(_ buffer: B, at slot: Int) {}
        func setPipeline(_ pipeline: Int) {}
        func setInput(_ texture: T, at slot: Int) {}
        func setOutput(_ texture: T) {}
        func setConstantBytes(_ bytes: UnsafeRawBufferPointer, slot: Int) {}
        func dispatch(width: Int, height: Int) {}
        func end() {}
    }
    struct R: GPURenderEncoder {
        func setPipeline(_ pipeline: Int) {}
        func setInput(_ texture: T, at slot: Int) {}
        func setBuffer(_ buffer: B, at slot: Int) {}
        func setConstantBytes(_ bytes: UnsafeRawBufferPointer, slot: Int) {}
        func setViewport(x: Double, y: Double, width: Double, height: Double) {}
        func setScissor(x: Int, y: Int, width: Int, height: Int) {}
        func draw(_ primitive: GPUPrimitive, vertexCount: Int) {}
        func end() {}
    }
    struct C: GPUCommandBuffer {
        func makeComputeEncoder() -> E? { nil }
        func makeRenderEncoder(target: T, clear: SIMD4<Float>?) -> R? { nil }
        func copy(_ source: T, to destination: T) -> Bool { false }
    }
    var name: String { "none" }
    func makePipeline(_ kernel: GPUKernel) throws -> Int { 0 }
    func makeRenderPipeline(_ kernel: GPURenderKernel, format: GPUPixelFormat, blend: GPUBlend) throws -> Int { 0 }
    func makeTexture(_ descriptor: GPUTextureDescriptor) -> T? { nil }
    func makeTexture3D(width: Int, height: Int, depth: Int, format: GPUPixelFormat) -> T? { nil }
    func makeBuffer(length: Int) -> B? { nil }
    func upload(_ bytes: UnsafeRawBufferPointer, to buffer: B) {}
    func download(_ buffer: B) -> [UInt8] { [] }
    func makeCommandBuffer() -> C? { nil }
    func commitAndWait(_ commandBuffer: C) {}
    func upload(_ bytes: UnsafeRawBufferPointer, bytesPerRow: Int, to texture: T) {}
    func download(_ texture: T) -> [UInt8] { [] }
}

#if canImport(Metal)
@Suite struct SQGPUMetalTests {
    /// The cross-backend graph on Metal. SQ_GPU_PNG_OUT=<path> writes the PNG (scripts/win-gpu-check.sh compares it with D3D12).
    @Test func referenceGraphRunsOnMetal() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { return }
        let gpu = try MetalGPUDevice(device: dev)
        let rgba = try GPUReferenceGraph.render(on: gpu, kernels: try GPUKernels(device: gpu))
        #expect(rgba.count == GPUReferenceGraph.width * GPUReferenceGraph.height * 4)
        #expect(Set(rgba).count > 64)
        if let path = ProcessInfo.processInfo.environment["SQ_GPU_PNG_OUT"] {
            try Data(GPUPNG.encode(rgba: rgba, width: GPUReferenceGraph.width, height: GPUReferenceGraph.height))
                .write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
