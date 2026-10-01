import Foundation
import Metal

public struct ScopeSelection: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let waveformLuma = ScopeSelection(rawValue: 1)
    public static let waveformParade = ScopeSelection(rawValue: 2)
    public static let vectorscope = ScopeSelection(rawValue: 4)
    public static let histogram = ScopeSelection(rawValue: 8)
    public static let all: ScopeSelection = [.waveformLuma, .waveformParade, .vectorscope, .histogram]
}

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

/// GPU scopes on the Rec.709 output signal of a working-linear texture. Device-bound; holds pipelines only.
public final class ScopesGPU: @unchecked Sendable {
    public let device: MTLDevice
    private let clear, accumulate, findMax, resolve: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        self.device = device
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.languageVersion = .version3_1
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: ScopeShaderSource.msl, options: options) }
        catch { throw ColorPipelineGPUError.shaderCompilation("\(error)") }
        func state(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw ColorPipelineGPUError.missingFunction(name) }
            return try device.makeComputePipelineState(function: f)
        }
        clear = try state("scopeClear"); accumulate = try state("scopeAccumulate")
        findMax = try state("scopeFindMax"); resolve = try state("scopeResolve")
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

    private struct Uniforms {
        var width, height, stride, flags: UInt32
        var waveW, waveL, vecN, pad: UInt32
        var offWaveLuma, offParade, offVector, offHist: UInt32
        var offMax, pad1, pad2, pad3: UInt32
    }
    private struct MaxParams { var offset, count, maxIndex, pad: UInt32 }
    private struct ResolveParams { var offset, maxIndex, width, height: UInt32 }

    /// Clears, accumulates (every `pixelStride`-th pixel in x and y), finds maxima and resolves the textures.
    /// `source` = working-linear (rgba16Float/32Float, `.shaderRead`).
    public func encode(source: MTLTexture, into r: ScopeResources, scopes: ScopeSelection = .all,
                       pixelStride: Int = 1, commandBuffer: MTLCommandBuffer) {
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let l = r.layout
        let step = max(1, pixelStride)
        // Clear everything.
        var total = UInt32(l.totalCount)
        enc.setComputePipelineState(clear)
        enc.setBuffer(r.counts, offset: 0, index: 0)
        enc.setBytes(&total, length: 4, index: 1)
        enc.dispatchThreads(MTLSize(width: l.totalCount, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(256, clear.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        // Accumulate.
        var u = Uniforms(width: UInt32(source.width), height: UInt32(source.height), stride: UInt32(step), flags: scopes.rawValue,
                         waveW: UInt32(l.waveformWidth), waveL: UInt32(l.waveformLevels), vecN: UInt32(l.vectorscopeSize), pad: 0,
                         offWaveLuma: UInt32(l.offsetWaveformLuma), offParade: UInt32(l.offsetParade),
                         offVector: UInt32(l.offsetVector), offHist: UInt32(l.offsetHistogram),
                         offMax: UInt32(l.offsetMaxima), pad1: 0, pad2: 0, pad3: 0)
        enc.setComputePipelineState(accumulate)
        enc.setTexture(source, index: 0)
        enc.setBuffer(r.counts, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        let gw = (source.width + step - 1) / step, gh = (source.height + step - 1) / step
        enc.dispatchThreads(MTLSize(width: gw, height: gh, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        // Maxima.
        let regions: [(off: Int, count: Int, index: Int)] = [
            (l.offsetWaveformLuma, l.waveformLumaCount, 0), (l.offsetParade, l.paradeCount, 1),
            (l.offsetVector, l.vectorCount, 2), (l.offsetHistogram, l.histogramCount, 3),
        ]
        enc.setComputePipelineState(findMax)
        for g in regions {
            var p = MaxParams(offset: UInt32(g.off), count: UInt32(g.count), maxIndex: UInt32(l.offsetMaxima + g.index), pad: 0)
            enc.setBuffer(r.counts, offset: 0, index: 0)
            enc.setBytes(&p, length: MemoryLayout<MaxParams>.stride, index: 1)
            enc.dispatchThreads(MTLSize(width: g.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, findMax.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        // Resolve to textures.
        enc.setComputePipelineState(resolve)
        let outs: [(MTLTexture, Int, Int)] = [
            (r.waveformLuma, l.offsetWaveformLuma, 0), (r.waveformParade, l.offsetParade, 1),
            (r.vectorscope, l.offsetVector, 2), (r.histogram, l.offsetHistogram, 3),
        ]
        for (tex, off, idx) in outs {
            var p = ResolveParams(offset: UInt32(off), maxIndex: UInt32(l.offsetMaxima + idx), width: UInt32(tex.width), height: UInt32(tex.height))
            enc.setBuffer(r.counts, offset: 0, index: 0)
            enc.setBytes(&p, length: MemoryLayout<ResolveParams>.stride, index: 1)
            enc.setTexture(tex, index: 0)
            enc.dispatchThreads(MTLSize(width: tex.width, height: tex.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        }
        enc.endEncoding()
    }
}
