import Foundation
import Metal
import simd

public enum ColorPipelineGPUError: Error, Sendable {
    case shaderCompilation(String)
    case missingFunction(String)
    case textureAllocation
    case unsupportedTextureFormat
}

/// GPU colour chain: one compute pass per layer, source-encoded -> working-linear.
/// Device-bound. Holds the compiled library/pipelines and an LUT texture cache; create one per device and reuse.
public final class ColorPipelineGPU: @unchecked Sendable {
    public let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let pipelineInPlace: MTLComputePipelineState
    private let dummy3D: MTLTexture
    private let dummy2D: MTLTexture

    private struct LUTKey: Hashable {
        let base: UInt
        let count: Int
        let size: Int
        let is3D: Bool
    }
    private struct LUTEntry {
        let texture: MTLTexture
        let table: [SIMD3<Float>]  // keeps the buffer alive so its address identifies the LUT
    }
    private var lutCache: [LUTKey: LUTEntry] = [:]
    private var lutOrder: [LUTKey] = []
    private let lock = NSLock()
    static let maxCachedLUTs = 16
    static let lut1DRowWidth = 4096

    public init(device: MTLDevice) throws {
        self.device = device
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.languageVersion = .version3_1
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: ColorShaderSource.msl, options: options) }
        catch { throw ColorPipelineGPUError.shaderCompilation("\(error)") }
        func state(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw ColorPipelineGPUError.missingFunction(name) }
            return try device.makeComputePipelineState(function: f)
        }
        pipeline = try state("colorChain")
        pipelineInPlace = try state("colorChainInPlace")
        let d3 = MTLTextureDescriptor()
        d3.textureType = .type3D; d3.pixelFormat = .rgba32Float; d3.width = 2; d3.height = 2; d3.depth = 2
        d3.usage = .shaderRead; d3.storageMode = .shared
        let d2 = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 2, height: 1, mipmapped: false)
        d2.usage = .shaderRead; d2.storageMode = .shared
        guard let t3 = device.makeTexture(descriptor: d3), let t2 = device.makeTexture(descriptor: d2) else {
            throw ColorPipelineGPUError.textureAllocation
        }
        dummy3D = t3; dummy2D = t2
    }

    // MARK: Uniforms (layout mirrors MSL `ColorUniforms`)

    struct Uniforms {
        var wb: simd_float3x3
        var toRec709: simd_float3x3
        var luma: SIMD4<Float>
        var convMin: SIMD4<Float>, convMax: SIMD4<Float>, creMin: SIMD4<Float>, creMax: SIMD4<Float>
        var tone: SIMD4<Float>
        var misc: SIMD4<Float>
        var ints: SIMD4<UInt32>
    }

    static let flagWB: UInt32 = 1, flagExposure: UInt32 = 2, flagTone: UInt32 = 4, flagSat: UInt32 = 8,
               flagConv: UInt32 = 16, flagConv1D: UInt32 = 32, flagCreative: UInt32 = 64,
               flagCreative1D: UInt32 = 128, flagHDR: UInt32 = 256

    static func uniforms(for p: ColorPipeline) -> Uniforms {
        let c = p.prepared
        var flags: UInt32 = 0
        if c.hasWB { flags |= flagWB }
        if c.hasExposure { flags |= flagExposure }
        if c.hasTone { flags |= flagTone }
        if c.hasSaturation { flags |= flagSat }
        if p.source.isHDR { flags |= flagHDR }
        var convMin = SIMD4<Float>.zero, convMax = SIMD4<Float>.one, creMin = SIMD4<Float>.zero, creMax = SIMD4<Float>.one
        var convSize: UInt32 = 0, creSize: UInt32 = 0
        if let l = p.conversionLUT {
            flags |= flagConv | (l.kind == .lut1D ? flagConv1D : 0)
            convMin = SIMD4(l.domainMin, 0); convMax = SIMD4(l.domainMax, 1); convSize = UInt32(l.size)
        }
        if let l = p.creativeLUT, p.creativeIntensity > 0 {
            flags |= flagCreative | (l.kind == .lut1D ? flagCreative1D : 0)
            creMin = SIMD4(l.domainMin, 0); creMax = SIMD4(l.domainMax, 1); creSize = UInt32(l.size)
        }
        let source: UInt32 = switch p.source { case .sLog3SGamut3Cine: 0; case .hlgBT2020: 1; case .rec709: 2 }
        return Uniforms(
            wb: c.wb, toRec709: p.toRec709, luma: SIMD4(c.luma, 0),
            convMin: convMin, convMax: convMax, creMin: creMin, creMax: creMax,
            tone: SIMD4(c.exposureScale, c.contrastScale, c.highlights, c.shadows),
            misc: SIMD4(c.saturation, p.toneMapping.knee, p.creativeIntensity, 0),
            ints: SIMD4(flags, source, convSize, creSize))
    }

    // MARK: LUT textures

    /// Number of LUT textures currently cached (for tests).
    var cachedLUTCount: Int { lock.lock(); defer { lock.unlock() }; return lutCache.count }

    private func texture(for lut: CubeLUT) -> MTLTexture? {
        let key = lut.table.withUnsafeBufferPointer {
            LUTKey(base: UInt(bitPattern: $0.baseAddress), count: $0.count, size: lut.size, is3D: lut.kind == .lut3D)
        }
        lock.lock(); defer { lock.unlock() }
        if let e = lutCache[key] { return e.texture }
        let rgba = lut.table.map { SIMD4<Float>($0, 1) }
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .rgba32Float
        desc.usage = .shaderRead
        desc.storageMode = .shared
        let tex: MTLTexture?
        if lut.kind == .lut3D {
            desc.textureType = .type3D
            desc.width = lut.size; desc.height = lut.size; desc.depth = lut.size
            tex = device.makeTexture(descriptor: desc)
            rgba.withUnsafeBytes {
                tex?.replace(region: MTLRegionMake3D(0, 0, 0, lut.size, lut.size, lut.size), mipmapLevel: 0, slice: 0,
                             withBytes: $0.baseAddress!, bytesPerRow: lut.size * 16, bytesPerImage: lut.size * lut.size * 16)
            }
        } else {
            let w = Self.lut1DRowWidth, h = (lut.size + w - 1) / w
            desc.textureType = .type2D
            desc.width = w; desc.height = h
            tex = device.makeTexture(descriptor: desc)
            var padded = rgba
            padded.append(contentsOf: [SIMD4<Float>](repeating: .zero, count: w * h - rgba.count))
            padded.withUnsafeBytes {
                tex?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 16)
            }
        }
        guard let tex else { return nil }
        if lutOrder.count >= Self.maxCachedLUTs, let old = lutOrder.first {
            lutOrder.removeFirst(); lutCache[old] = nil
        }
        lutCache[key] = LUTEntry(texture: tex, table: lut.table)
        lutOrder.append(key)
        return tex
    }

    // MARK: Encode

    /// Encodes one compute pass: `source` (source-encoded, rgba16Float/32Float, range-expanded 0…1) -> `destination`
    /// (working-linear). Both must be the same size; destination needs `.shaderWrite`, source `.shaderRead`.
    /// `source === destination` is supported (in place; the texture then needs `.shaderRead | .shaderWrite`).
    /// Alpha is passed through unchanged.
    public func encode(_ pipeline: ColorPipeline, source: MTLTexture, destination: MTLTexture,
                       commandBuffer: MTLCommandBuffer) {
        guard source.width == destination.width, source.height == destination.height,
              let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        var u = Self.uniforms(for: pipeline)
        let inPlace = source === destination
        enc.setComputePipelineState(inPlace ? pipelineInPlace : self.pipeline)
        if inPlace {
            enc.setTexture(source, index: 0)
        } else {
            enc.setTexture(source, index: 0)
            enc.setTexture(destination, index: 1)
        }
        let luts = [(pipeline.conversionLUT, u.ints.x & Self.flagConv != 0, 2),
                    (pipeline.creativeLUT, u.ints.x & Self.flagCreative != 0, 4)]
        for (lut, active, index) in luts {
            var t3: MTLTexture = dummy3D, t1: MTLTexture = dummy2D
            if active, let lut, let tex = texture(for: lut) {
                if lut.kind == .lut3D { t3 = tex } else { t1 = tex }
            }
            enc.setTexture(t3, index: index)
            enc.setTexture(t1, index: index + 1)
        }
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        let w = self.pipeline.threadExecutionWidth
        let h = max(1, self.pipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: min(h, 8), depth: 1))
        enc.endEncoding()
    }
}
