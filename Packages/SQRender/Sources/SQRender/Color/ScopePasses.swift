import Foundation
import SQGPU
import SQGPUKernels

public struct ScopeSelection: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let waveformLuma = ScopeSelection(rawValue: 1)
    public static let waveformParade = ScopeSelection(rawValue: 2)
    public static let vectorscope = ScopeSelection(rawValue: 4)
    public static let histogram = ScopeSelection(rawValue: 8)
    public static let all: ScopeSelection = [.waveformLuma, .waveformParade, .vectorscope, .histogram]
}

/// The scope compute passes (Scopes.slang: clear, accumulate, maxima, resolve) on the portable GPU protocol, written once
/// for the Mac `ScopesGPU` (Metal) and the Windows Program monitor (D3D12). The source is a working-linear texture
/// (rgba16Float / rgba32Float); the counts buffer has `ScopeLayout.totalCount` UInt32 slots.
public struct ScopePasses<D: GPUDevice> {
    /// ScopeU of Scopes.slang.
    struct Uniforms: BitwiseCopyable {
        var width: UInt32 = 0, height: UInt32 = 0, stride: UInt32 = 1, flags: UInt32 = 0
        var waveW: UInt32 = 0, waveL: UInt32 = 0, vecN: UInt32 = 0, rowWidth: UInt32 = 1024
        var offWaveLuma: UInt32 = 0, offParade: UInt32 = 0, offVector: UInt32 = 0, offHist: UInt32 = 0
        var offset: UInt32 = 0, count: UInt32 = 0, maxIndex: UInt32 = 0, pad0: UInt32 = 0
        var outW: UInt32 = 0, outH: UInt32 = 0, pad1: UInt32 = 0, pad2: UInt32 = 0
    }

    /// The r32Float planes `encode` resolves into (`count / max`): waveform W x L, parade 3W x L, vectorscope N x N,
    /// histogram 256 x 4.
    public struct Planes {
        public var waveformLuma, waveformParade, vectorscope, histogram: D.Texture
        public init(waveformLuma: D.Texture, waveformParade: D.Texture, vectorscope: D.Texture, histogram: D.Texture) {
            self.waveformLuma = waveformLuma; self.waveformParade = waveformParade
            self.vectorscope = vectorscope; self.histogram = histogram
        }
    }

    public let device: D
    let clear, accumulate, findMax, resolve: D.Pipeline

    public init(device: D) throws {
        self.device = device
        let p = try ["scopeClear", "scopeAccumulate", "scopeFindMax", "scopeResolve"].map {
            try device.makePipeline(GPUKernel(GeneratedShaders.scopes, $0))
        }
        clear = p[0]; accumulate = p[1]; findMax = p[2]; resolve = p[3]
    }

    /// A counts buffer for `layout`.
    public func makeCounts(_ layout: ScopeLayout = ScopeLayout()) -> D.Buffer? {
        device.makeBuffer(length: layout.totalCount * 4)
    }

    /// The four resolve planes for `layout`.
    public func makePlanes(_ layout: ScopeLayout = ScopeLayout()) -> Planes? {
        func tex(_ w: Int, _ h: Int) -> D.Texture? {
            device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .r32Float))
        }
        guard let a = tex(layout.waveformWidth, layout.waveformLevels), let b = tex(3 * layout.waveformWidth, layout.waveformLevels),
              let c = tex(layout.vectorscopeSize, layout.vectorscopeSize), let d = tex(ScopeLayout.histogramBins, 4) else { return nil }
        return Planes(waveformLuma: a, waveformParade: b, vectorscope: c, histogram: d)
    }

    /// Clears, accumulates (every `pixelStride`-th pixel in x and y), finds the maxima and, with `planes`, resolves them.
    public func encode(source: D.Texture, counts: D.Buffer, layout l: ScopeLayout, planes: Planes? = nil,
                       scopes: ScopeSelection = .all, pixelStride: Int = 1, _ cb: D.CommandBuffer) {
        guard let enc = cb.makeComputeEncoder() else { return }
        let step = max(1, pixelStride)
        var u = Uniforms(width: UInt32(source.width), height: UInt32(source.height), stride: UInt32(step), flags: scopes.rawValue,
                         waveW: UInt32(l.waveformWidth), waveL: UInt32(l.waveformLevels), vecN: UInt32(l.vectorscopeSize),
                         offWaveLuma: UInt32(l.offsetWaveformLuma), offParade: UInt32(l.offsetParade),
                         offVector: UInt32(l.offsetVector), offHist: UInt32(l.offsetHistogram))
        let row = Int(u.rowWidth)
        /// Linear kernels: index y * rowWidth + x, in whole 16 x 16 groups (Metal shrinks edge groups, and scopeFindMax
        /// reduces over a full group).
        func linear(_ n: Int) {
            let side = GPUBinding.groupSide
            enc.dispatch(width: row, height: ((n + row - 1) / row + side - 1) / side * side)
        }
        enc.setBuffer(counts, at: 2)
        u.offset = 0; u.count = UInt32(l.totalCount)
        enc.setPipeline(clear)
        enc.setConstants(u)
        linear(l.totalCount)
        enc.setPipeline(accumulate)
        enc.setInput(source, at: 0)
        enc.setConstants(u)
        enc.dispatch(width: (source.width + step - 1) / step, height: (source.height + step - 1) / step)
        let regions: [(off: Int, count: Int, index: Int)] = [
            (l.offsetWaveformLuma, l.waveformLumaCount, 0), (l.offsetParade, l.paradeCount, 1),
            (l.offsetVector, l.vectorCount, 2), (l.offsetHistogram, l.histogramCount, 3),
        ]
        enc.setPipeline(findMax)
        for g in regions {
            u.offset = UInt32(g.off); u.count = UInt32(g.count); u.maxIndex = UInt32(l.offsetMaxima + g.index)
            enc.setConstants(u)
            linear(g.count)
        }
        if let planes {
            enc.setPipeline(resolve)
            let outs: [(D.Texture, Int, Int)] = [
                (planes.waveformLuma, l.offsetWaveformLuma, 0), (planes.waveformParade, l.offsetParade, 1),
                (planes.vectorscope, l.offsetVector, 2), (planes.histogram, l.offsetHistogram, 3),
            ]
            for (tex, off, idx) in outs {
                u.offset = UInt32(off); u.maxIndex = UInt32(l.offsetMaxima + idx)
                u.outW = UInt32(tex.width); u.outH = UInt32(tex.height)
                enc.setConstants(u)
                enc.setOutput(tex)
                enc.dispatch(width: tex.width, height: tex.height)
            }
        }
        enc.end()
    }

    /// The counts buffer as `ScopeCounts` (after the command buffer completed).
    public func read(_ counts: D.Buffer, layout: ScopeLayout) -> ScopeCounts {
        let bytes = device.download(counts)
        return bytes.withUnsafeBytes { raw in
            Self.counts(raw.bindMemory(to: UInt32.self), layout: layout)
        }
    }

    static func counts(_ p: UnsafeBufferPointer<UInt32>, layout: ScopeLayout) -> ScopeCounts {
        var c = ScopeCounts(layout: layout)
        guard p.count >= layout.totalCount else { return c }
        func slice(_ off: Int, _ n: Int) -> [UInt32] { Array(p[off..<(off + n)]) }
        c.waveformLuma = slice(layout.offsetWaveformLuma, layout.waveformLumaCount)
        c.waveformParade = slice(layout.offsetParade, layout.paradeCount)
        c.vectorscope = slice(layout.offsetVector, layout.vectorCount)
        c.histogram = slice(layout.offsetHistogram, layout.histogramCount)
        c.maxWaveformLuma = p[layout.offsetMaxima]; c.maxWaveformParade = p[layout.offsetMaxima + 1]
        c.maxVectorscope = p[layout.offsetMaxima + 2]; c.maxHistogram = p[layout.offsetMaxima + 3]
        return c
    }

    /// One measurement in its own command buffer: encode, wait, read. nil when the device has no buffer or command buffer.
    public func measure(_ source: D.Texture, counts: D.Buffer, layout: ScopeLayout = ScopeLayout(),
                        scopes: ScopeSelection = .all, pixelStride: Int = 1) -> ScopeCounts? {
        guard let cb = device.makeCommandBuffer() else { return nil }
        encode(source: source, counts: counts, layout: layout, scopes: scopes, pixelStride: pixelStride, cb)
        device.commitAndWait(cb)
        return read(counts, layout: layout)
    }
}
