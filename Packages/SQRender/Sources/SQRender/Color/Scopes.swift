#if canImport(Metal)
import Foundation
import Metal
import SQGPU
import SQGPUKernels
import SQGPUMetal

/// Buffers and textures of one scope view. Reuse across frames; one in-flight encode at a time per instance.
///
/// After `ScopesGPU.encode` completes: `counts` holds raw `UInt32` counts (see `ScopeLayout`/`ScopeCounts` for layout),
/// the r32Float textures hold `count / max` (0…1, linear; log-ish mapping is up to the UI, `readCounts()` has the maxima):
/// `waveformLuma` W×L, `waveformParade` 3W×L, `vectorscope` N×N, `histogram` 256×4 (rows R, G, B, Y; normalized by the overall max).
public final class ScopeResources: @unchecked Sendable {
    public let layout: ScopeLayout
    public let counts: MTLBuffer
    public let waveformLuma: MTLTexture
    public let waveformParade: MTLTexture
    public let vectorscope: MTLTexture
    public let histogram: MTLTexture

    init(layout: ScopeLayout, counts: MTLBuffer, textures: [MTLTexture]) {
        self.layout = layout; self.counts = counts
        waveformLuma = textures[0]; waveformParade = textures[1]; vectorscope = textures[2]; histogram = textures[3]
    }

    /// Reads the counts buffer (call after the command buffer completed).
    public func readCounts() -> ScopeCounts {
        let p = counts.contents().bindMemory(to: UInt32.self, capacity: layout.totalCount)
        func slice(_ off: Int, _ n: Int) -> [UInt32] { Array(UnsafeBufferPointer(start: p + off, count: n)) }
        var c = ScopeCounts(layout: layout)
        c.waveformLuma = slice(layout.offsetWaveformLuma, layout.waveformLumaCount)
        c.waveformParade = slice(layout.offsetParade, layout.paradeCount)
        c.vectorscope = slice(layout.offsetVector, layout.vectorCount)
        c.histogram = slice(layout.offsetHistogram, layout.histogramCount)
        c.maxWaveformLuma = p[layout.offsetMaxima]; c.maxWaveformParade = p[layout.offsetMaxima + 1]
        c.maxVectorscope = p[layout.offsetMaxima + 2]; c.maxHistogram = p[layout.offsetMaxima + 3]
        return c
    }
}

/// GPU scopes on the Rec.709 output signal of a working-linear texture. Device-bound; holds pipelines only
/// (the shared `ScopePasses` on SQGPU's Metal backend; the Windows monitor runs the same passes on D3D12).
public final class ScopesGPU: @unchecked Sendable {
    public let device: MTLDevice
    private let gpu: MetalGPUDevice
    private let passes: ScopePasses<MetalGPUDevice>

    public init(device: MTLDevice) throws {
        self.device = device
        do {
            gpu = try MetalGPUDevice(device: device)
            passes = try ScopePasses(device: gpu)
        } catch { throw ColorPipelineGPUError.shaderCompilation("\(error)") }
    }

    public func makeResources(layout: ScopeLayout = ScopeLayout()) -> ScopeResources? {
        guard let buffer = device.makeBuffer(length: layout.totalCount * 4, options: .storageModeShared) else { return nil }
        func tex(_ w: Int, _ h: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let a = tex(layout.waveformWidth, layout.waveformLevels), let b = tex(3 * layout.waveformWidth, layout.waveformLevels),
              let c = tex(layout.vectorscopeSize, layout.vectorscopeSize), let d = tex(ScopeLayout.histogramBins, 4) else { return nil }
        return ScopeResources(layout: layout, counts: buffer, textures: [a, b, c, d])
    }

    /// Clears, accumulates (every `pixelStride`-th pixel in x and y), finds maxima and resolves the textures.
    /// `source` = working-linear (rgba16Float/32Float, `.shaderRead`).
    public func encode(source: MTLTexture, into r: ScopeResources, scopes: ScopeSelection = .all,
                       pixelStride: Int = 1, commandBuffer: MTLCommandBuffer) {
        let planes = ScopePasses<MetalGPUDevice>.Planes(
            waveformLuma: MetalGPUTexture(r.waveformLuma), waveformParade: MetalGPUTexture(r.waveformParade),
            vectorscope: MetalGPUTexture(r.vectorscope), histogram: MetalGPUTexture(r.histogram))
        passes.encode(source: MetalGPUTexture(source), counts: MetalGPUBuffer(r.counts), layout: r.layout, planes: planes,
                      scopes: scopes, pixelStride: pixelStride, gpu.wrap(commandBuffer))
    }
}
#endif
