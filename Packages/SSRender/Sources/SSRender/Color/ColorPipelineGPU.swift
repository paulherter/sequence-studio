import Foundation
import Metal
import simd

public enum ColorPipelineGPUError: Error, Sendable {
    case shaderCompilation(String)
    case missingFunction(String)
    case textureAllocation
    case unsupportedTextureFormat(MTLPixelFormat)
    case textureSizeMismatch
    case missingTextureUsage(String)
    case invalidLUT
    case encoderUnavailable
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

    // MARK: Uniforms (layout mirrors MSL `ColorHeader` / `Sec`)

    struct Header {
        var ints: SIMD4<UInt32>   // count, start domain, end domain, source
    }

    struct Sec {
        var head: SIMD4<UInt32> = .zero   // kind, pre, flags, extra
        var a = SIMD4<Float>.zero, b = SIMD4<Float>.zero, c = SIMD4<Float>.zero, d = SIMD4<Float>.zero
        var m = matrix_identity_float3x3
    }

    /// One compute dispatch: up to `maxSections` blocks with at most one LUT and `maxCurves` curve tables.
    struct Pass {
        var header: Header
        var sections: [Sec] = []
        var curves: [SIMD4<Float>] = []
        var lut: CubeLUT?
    }

    static let maxSections = 8
    static let maxCurves = 3   // 3 x 64 x 16 B stays below the 4 KB setBytes limit

    static let kindConversion: UInt32 = 0, kindBasic: UInt32 = 1, kindCreative: UInt32 = 2, kindLook: UInt32 = 3,
               kindCurves: UInt32 = 4, kindWheels: UInt32 = 5, kindVignette: UInt32 = 6
    static let lutPresent: UInt32 = 1, lut1D: UInt32 = 2, lutIn: UInt32 = 4, lutOut: UInt32 = 8

    private static func lutFields(_ s: inout Sec, _ l: CubeLUT) {
        var f = lutPresent | (l.kind == .lut1D ? lut1D : 0)
        if l.inVideoRange { f |= lutIn }
        if l.outVideoRange { f |= lutOut }
        s.head.z = f
        s.head.w = UInt32(l.size)
        s.a = SIMD4(l.domainMin, 0); s.b = SIMD4(l.domainMax, 1)
    }

    /// Splits the compiled chain into passes. Between passes the texture holds the running signal: source-linear light
    /// before the conversion, the display tone signal after it; the last pass ends in working-linear.
    static func passes(for p: ColorPipeline) -> [Pass] {
        let source: UInt32 = switch p.source { case .sLog3SGamut3Cine: 0; case .hlgBT2020: 1; case .rec709: 2 }
        var passes: [Pass] = []
        var domain: UInt32 = 0   // 0 source-encoded, 1 source-linear, 2 display
        var cur = Pass(header: Header(ints: SIMD4(0, domain, 0, source)))
        func close(last: Bool) {
            cur.header.ints.x = UInt32(cur.sections.count)
            cur.header.ints.z = last ? 3 : domain == 0 ? 1 : domain
            passes.append(cur)
            let next: UInt32 = domain == 0 ? 1 : domain
            cur = Pass(header: Header(ints: SIMD4(0, next, 0, source)))
            domain = next
        }
        for st in p.stages {
            var sec = Sec()
            sec.head.y = st.pre ? 1 : 0
            var needsLUT: CubeLUT?
            var curvesRows: [SIMD4<Float>] = []
            switch st.kind {
            case .conversion(let lut):
                sec.head.x = kindConversion
                sec.m = p.toRec709
                sec.c = SIMD4(p.toneMapping.knee, 0, 0, 0)
                if let lut { lutFields(&sec, lut); needsLUT = lut }
            case .basic(let b):
                sec.head.x = kindBasic
                var f: UInt32 = 0
                if b.hasWB { f |= 1 }
                if b.hasExposure { f |= 2 }
                if b.hasContrast { f |= 4 }
                if b.hasShadows { f |= 8 }
                if b.hasHighlights { f |= 64 }
                if b.hasLevels { f |= 16 }
                if b.saturation != 1 || b.vibrance != 0 { f |= 32 }
                sec.head.z = f
                sec.a = SIMD4(b.exposureScale, b.contrastK, b.highlights, b.shadows)
                sec.b = SIMD4(b.blackPoint, b.whitePoint, b.saturation, b.vibrance)
                sec.c = SIMD4(b.luma, 0)
                sec.m = b.wb
            case .creative(let c):
                sec.head.x = kindCreative
                sec.head.z = c.hasTint ? 1 : 0
                sec.a = SIMD4(c.fade, c.saturation, c.vibrance, c.balance)
                sec.b = SIMD4(c.shadowTint, 0); sec.c = SIMD4(c.highlightTint, 0); sec.d = SIMD4(c.luma, 0)
            case .look(let lut, let k):
                sec.head.x = kindLook
                lutFields(&sec, lut)
                sec.c = SIMD4(k, 0, 0, 0)
                needsLUT = lut
            case .curves(let t):
                sec.head.x = kindCurves
                curvesRows = t.table.map { SIMD4($0, 0) }
            case .wheels(let w):
                sec.head.x = kindWheels
                sec.head.z = w.hasGamma ? 1 : 0
                sec.a = SIMD4(w.lift, w.saturation); sec.b = SIMD4(w.gammaExponent, 0); sec.c = SIMD4(w.gain, 0)
                sec.d = SIMD4(w.luma, 0)
            case .vignette(let v):
                sec.head.x = kindVignette
                sec.a = SIMD4(v.amount, v.start, v.feather, v.exponent); sec.b = SIMD4(v.aspectMix, 0, 0, 0)
            }
            let curveCount = cur.curves.count / CurveTable.count
            if cur.sections.count >= maxSections || (needsLUT != nil && cur.lut != nil)
                || (!curvesRows.isEmpty && curveCount >= maxCurves) {
                close(last: false)
            }
            if !curvesRows.isEmpty { sec.head.w = UInt32(cur.curves.count / CurveTable.count); cur.curves += curvesRows }
            if let needsLUT { cur.lut = needsLUT }
            cur.sections.append(sec)
            if case .conversion = st.kind { domain = 2 }
        }
        close(last: true)
        return passes
    }

    // MARK: LUT textures

    /// Number of LUT textures currently cached (for tests).
    var cachedLUTCount: Int { lock.lock(); defer { lock.unlock() }; return lutCache.count }

    /// Whether the LUT currently has a cached texture (for tests).
    func isCached(_ lut: CubeLUT) -> Bool {
        let key = Self.key(lut)
        lock.lock(); defer { lock.unlock() }
        return lutCache[key] != nil
    }

    private static func key(_ lut: CubeLUT) -> LUTKey {
        lut.table.withUnsafeBufferPointer {
            LUTKey(base: UInt(bitPattern: $0.baseAddress), count: $0.count, size: lut.size, is3D: lut.kind == .lut3D)
        }
    }

    private func texture(for lut: CubeLUT) throws -> MTLTexture {
        let expected = lut.kind == .lut3D ? lut.size * lut.size * lut.size : lut.size
        guard lut.size >= 2, lut.table.count == expected else { throw ColorPipelineGPUError.invalidLUT }
        let key = Self.key(lut)
        lock.lock(); defer { lock.unlock() }
        if let e = lutCache[key] {
            // LRU: move to the end (<= 16 entries, so the linear remove is cheap).
            if lutOrder.last != key, let i = lutOrder.firstIndex(of: key) { lutOrder.remove(at: i); lutOrder.append(key) }
            return e.texture
        }
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
        guard let tex else { throw ColorPipelineGPUError.textureAllocation }
        if lutOrder.count >= Self.maxCachedLUTs, let old = lutOrder.first {
            lutOrder.removeFirst(); lutCache[old] = nil
        }
        lutCache[key] = LUTEntry(texture: tex, table: lut.table)
        lutOrder.append(key)
        return tex
    }

    // MARK: Encode

    /// Encodes one compute pass: `source` (source-encoded, range-expanded 0…1) -> `destination` (working-linear).
    /// Alpha is passed through unchanged. `source === destination` is supported (in place).
    ///
    /// Throws on caller mistakes (checked every call; all checks are O(1) property reads):
    /// size mismatch, pixel format other than rgba16Float/rgba32Float, `destination` without `.shaderWrite`,
    /// `source` without `.shaderRead` (in place: the texture needs both), LUT with a wrong entry count, no encoder.
    public func encode(_ pipeline: ColorPipeline, source: MTLTexture, destination: MTLTexture,
                       commandBuffer: MTLCommandBuffer) throws {
        guard source.width == destination.width, source.height == destination.height else {
            throw ColorPipelineGPUError.textureSizeMismatch
        }
        for t in [source, destination] where t.pixelFormat != .rgba16Float && t.pixelFormat != .rgba32Float {
            throw ColorPipelineGPUError.unsupportedTextureFormat(t.pixelFormat)
        }
        let inPlace = source === destination
        guard source.usage.contains(.shaderRead) else { throw ColorPipelineGPUError.missingTextureUsage("source needs .shaderRead") }
        guard destination.usage.contains(.shaderWrite) else {
            throw ColorPipelineGPUError.missingTextureUsage("destination needs .shaderWrite")
        }
        let passes = Self.passes(for: pipeline)
        // Resolve LUT textures before creating any encoder so a throw leaves the command buffer untouched.
        var lutTextures: [(MTLTexture, MTLTexture)] = []
        for pass in passes {
            var t3: MTLTexture = dummy3D, t1: MTLTexture = dummy2D
            if let lut = pass.lut {
                let tex = try texture(for: lut)
                if lut.kind == .lut3D { t3 = tex } else { t1 = tex }
            }
            lutTextures.append((t3, t1))
        }
        for (i, pass) in passes.enumerated() {
            // The first pass reads `source`; later passes work in place on `destination`.
            let inPlacePass = i > 0 || inPlace
            guard let enc = commandBuffer.makeComputeCommandEncoder() else { throw ColorPipelineGPUError.encoderUnavailable }
            let state = inPlacePass ? pipelineInPlace : self.pipeline
            enc.setComputePipelineState(state)
            if inPlacePass { enc.setTexture(destination, index: 0) } else { enc.setTexture(source, index: 0); enc.setTexture(destination, index: 1) }
            enc.setTexture(lutTextures[i].0, index: 2)
            enc.setTexture(lutTextures[i].1, index: 3)
            var h = pass.header
            enc.setBytes(&h, length: MemoryLayout<Header>.stride, index: 0)
            var secs = pass.sections
            enc.setBytes(&secs, length: MemoryLayout<Sec>.stride * secs.count, index: 1)
            var curves = pass.curves.isEmpty ? [SIMD4<Float>.zero] : pass.curves
            enc.setBytes(&curves, length: MemoryLayout<SIMD4<Float>>.stride * curves.count, index: 2)
            let w = state.threadExecutionWidth
            let hh = max(1, min(8, state.maxTotalThreadsPerThreadgroup / w))
            enc.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: hh, depth: 1))
            enc.endEncoding()
        }
    }
}
