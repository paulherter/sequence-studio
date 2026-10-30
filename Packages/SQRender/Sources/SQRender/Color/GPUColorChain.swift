import Foundation
#if canImport(simd)
import simd
#endif
import SQGPU
import SQGPUKernels

/// The color chain of `ColorPipelineGPU.encode` on any GPU backend (D3D12 on Windows, Metal for the parity tests): the
/// same pass plan (`ColorPipeline.gpuPasses`) run by the generic Slang kernels `colorChain` / `colorChainInPlace`
/// (Packages/SQGPU/Shaders), in place on an rgba16Float picture.
/// shortcut: always the generic interpreter kernels (the Metal class compiles specialised kernels per chain layout in the
/// background, same pixels); add them when grade cost shows up in Windows profiles.
public final class GPUColorChain<D: GPUDevice>: @unchecked Sendable {
    typealias Header = ColorPipelineGPU.Header
    typealias Sec = ColorPipelineGPU.Sec

    public let device: D
    private let inPlace: D.Pipeline
    private let dummy3D: D.Texture, dummy2D: D.Texture
    private struct LUTKey: Hashable { let base: UInt, count: Int, size: Int, is3D: Bool }
    private var luts: [LUTKey: D.Texture] = [:]
    private var lutOrder: [LUTKey] = []
    static var maxCachedLUTs: Int { 16 }   // as ColorPipelineGPU
    static var lut1DRowWidth: Int { 4096 }
    /// Slang `ColorChainU`: the header and `kMaxColorSections` blocks; `CurveRows`: `maxCurves` tables of 64 rows.
    static var chainBytes: Int { MemoryLayout<Header>.stride + 24 * MemoryLayout<Sec>.stride }
    static var curveBytes: Int { ColorPipelineGPU.maxCurves * 64 * MemoryLayout<SIMD4<Float>>.stride }

    public init(device: D) throws {
        self.device = device
        inPlace = try device.makePipeline(GPUKernel(GeneratedShaders.colorChainInPlace, "colorChainInPlace"))
        guard let t3 = device.makeTexture3D(width: 2, height: 2, depth: 2, format: .rgba32Float),
              let t2 = device.makeTexture(GPUTextureDescriptor(width: 2, height: 1, format: .rgba32Float, cpuAccessible: true)) else {
            throw CompositorError.resourceAllocation
        }
        dummy3D = t3; dummy2D = t2
        let zeros = [Float](repeating: 0, count: 32)
        zeros.withUnsafeBytes { device.upload($0, bytesPerRow: 32, to: t3); device.upload($0, bytesPerRow: 32, to: t2) }
    }

    /// Grades `texture` (rgba16Float, source-encoded R'G'B' as the compositor's conversion writes it, or BT.709-encoded for
    /// an adjustment layer) in place. `quarterTurned`: the vignette follows the upright picture.
    func encode(_ pipeline: ColorPipeline, texture: D.Texture, commandBuffer cb: D.CommandBuffer,
                quarterTurned: Bool = false) throws {
        for pass in pipeline.gpuPasses {
            var (t3, t1) = (dummy3D, dummy2D)
            if let lut = pass.lut {
                let t = try lutTexture(lut)
                if lut.kind == .lut3D { t3 = t } else { t1 = t }
            }
            var h = pass.header
            h.extra.x = quarterTurned ? 1 : 0
            var block = [UInt8](repeating: 0, count: Self.chainBytes)
            var curves = [UInt8](repeating: 0, count: Self.curveBytes)
            block.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: h, as: Header.self)
                for (i, s) in pass.sections.prefix(24).enumerated() {
                    raw.storeBytes(of: s, toByteOffset: MemoryLayout<Header>.stride + i * MemoryLayout<Sec>.stride, as: Sec.self)
                }
            }
            curves.withUnsafeMutableBytes { raw in
                for (i, r) in pass.curves.prefix(Self.curveBytes / 16).enumerated() {
                    raw.storeBytes(of: r, toByteOffset: i * 16, as: SIMD4<Float>.self)
                }
            }
            guard let enc = cb.makeComputeEncoder() else { throw CompositorError.resourceAllocation }
            enc.setPipeline(inPlace)
            enc.setInput(t3, at: GPUBinding.tableSlot)
            enc.setInput(t1, at: 3)
            block.withUnsafeBytes { enc.setConstantBytes($0, slot: 0) }
            curves.withUnsafeBytes { enc.setConstantBytes($0, slot: 1) }
            enc.setOutput(texture)
            enc.dispatch(width: texture.width, height: texture.height)
            enc.end()
        }
    }

    /// The LUT as an rgba32Float texture (3D cube, or 1D rows of `Self.lut1DRowWidth`); the last 16 are kept.
    private func lutTexture(_ lut: CubeLUT) throws -> D.Texture {
        let expected = lut.kind == .lut3D ? lut.size * lut.size * lut.size : lut.size
        guard lut.size >= 2, lut.table.count == expected else { throw CompositorError.invalidTarget("LUT: \(lut.table.count) entries for size \(lut.size)") }
        let key = lut.table.withUnsafeBufferPointer {
            LUTKey(base: UInt(bitPattern: $0.baseAddress), count: $0.count, size: lut.size, is3D: lut.kind == .lut3D)
        }
        if let t = luts[key] { return t }
        var rgba = lut.table.map { SIMD4<Float>($0, 1) }
        let tex: D.Texture?
        if lut.kind == .lut3D {
            tex = device.makeTexture3D(width: lut.size, height: lut.size, depth: lut.size, format: .rgba32Float)
            if let tex { rgba.withUnsafeBytes { device.upload($0, bytesPerRow: lut.size * 16, to: tex) } }
        } else {
            let w = Self.lut1DRowWidth, h = (lut.size + w - 1) / w
            rgba.append(contentsOf: [SIMD4<Float>](repeating: .zero, count: w * h - rgba.count))
            tex = device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba32Float, cpuAccessible: true))
            if let tex { rgba.withUnsafeBytes { device.upload($0, bytesPerRow: w * 16, to: tex) } }
        }
        guard let tex else { throw CompositorError.resourceAllocation }
        if lutOrder.count >= Self.maxCachedLUTs, let old = lutOrder.first { lutOrder.removeFirst(); luts[old] = nil }
        luts[key] = tex
        lutOrder.append(key)
        return tex
    }
}
