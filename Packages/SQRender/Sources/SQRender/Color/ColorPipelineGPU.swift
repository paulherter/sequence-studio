#if canImport(Metal)
import Foundation
import Metal
import simd
import SQCore

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

/// GPU color chain: one compute pass per layer, source-encoded -> working-linear.
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

    // MARK: Specialised kernels

    /// How the chain picks its kernels. `.async` (default): the first use of a chain layout starts compiling its
    /// specialised library in the background and runs the generic kernel meanwhile (same pixels). `.sync`: compile on
    /// first use (tests). `.off`: always the generic interpreter (`SQ_GRADE_KERNELS=0`).
    public enum Specialization: Sendable { case off, async, sync }

    /// Compiled kernels of one chain layout (`ColorKernelSource.library`).
    final class Kernels: @unchecked Sendable {
        let pass: [MTLComputePipelineState]
        let inPlace: [MTLComputePipelineState]
        let fused: MTLComputePipelineState
        let fusedScaled: MTLComputePipelineState
        /// `sqFusedScaledTone`: only when pass 0 holds the conversion (`ColorKernelSource.conversionIndex`). Nil too when
        /// its pipeline state cannot be made: the other kernels stay usable and the preview grades that chain at full size.
        let fusedScaledTone: MTLComputePipelineState?
        init(library: MTLLibrary, passes: Int, device: MTLDevice) throws {
            func state(_ name: String) throws -> MTLComputePipelineState {
                guard let f = library.makeFunction(name: name) else { throw ColorPipelineGPUError.missingFunction(name) }
                return try device.makeComputePipelineState(function: f)
            }
            pass = try (0..<passes).map { try state("sqPass\($0)") }
            inPlace = try (0..<passes).map { try state("sqPass\($0)InPlace") }
            fused = try state("sqFused")
            fusedScaled = try state("sqFusedScaled")
            fusedScaledTone = library.functionNames.contains("sqFusedScaledTone") ? try? state("sqFusedScaledTone") : nil
        }
    }

    private enum KernelSlot { case compiling, ready(Kernels), failed }

    /// Compiled kernels shared by every ColorPipelineGPU of a device (each export makes a new compositor; the app has
    /// several), keyed by device and chain layout.
    private final class KernelStore: @unchecked Sendable {
        struct Key: Hashable { let device: UInt64; let layouts: [ColorKernelSource.PassLayout] }
        let lock = NSLock()
        var slots: [Key: KernelSlot] = [:]
    }
    private static let kernelStore = KernelStore()
    static let maxCachedKernels = 64

    /// Drops the compiled kernels of devices that are gone (an unplugged eGPU, a display moved to another GPU): their
    /// pipeline states would otherwise stay in the store, and keep the device alive, for the life of the process.
    /// Entries still compiling are kept (their completion writes the slot). `present` nil = the devices Metal lists now.
    @discardableResult
    static func evictKernels(keepingDevices present: Set<UInt64>? = nil) -> Int {
        let alive = present ?? Set(MTLCopyAllDevices().map(\.registryID))
        let store = kernelStore
        store.lock.lock(); defer { store.lock.unlock() }
        return evictLocked(store, alive: alive)
    }

    @discardableResult
    private static func evictLocked(_ store: KernelStore, alive: Set<UInt64>) -> Int {
        let before = store.slots.count
        store.slots = store.slots.filter { entry in
            if alive.contains(entry.key.device) { return true }
            if case .compiling = entry.value { return true }
            return false
        }
        return before - store.slots.count
    }

    /// Cached kernel slots (tests).
    static var cachedKernelCount: Int { kernelStore.lock.lock(); defer { kernelStore.lock.unlock() }; return kernelStore.slots.count }
    private var _specialization: Specialization =
        ProcessInfo.processInfo.environment["SQ_GRADE_KERNELS"] == "0" ? .off : .async
    private var _specialisedPasses = 0

    public var specialization: Specialization {
        get { lock.lock(); defer { lock.unlock() }; return _specialization }
        set { lock.lock(); _specialization = newValue; lock.unlock() }
    }

    /// Passes this instance encoded with specialised kernels (tests).
    var specialisedPasses: Int { lock.lock(); defer { lock.unlock() }; return _specialisedPasses }

    private static func compileOptions() -> MTLCompileOptions {
        let o = MTLCompileOptions()
        o.mathMode = .safe
        o.languageVersion = .version3_1
        return o
    }

    /// The specialised kernels for these passes, or nil while they compile (or when specialisation is off or failed).
    func kernels(for passes: [Pass]) -> Kernels? {
        let mode = specialization
        if mode == .off { return nil }
        let key = KernelStore.Key(device: device.registryID, layouts: passes.map(\.layout))
        let store = Self.kernelStore
        store.lock.lock()
        switch store.slots[key] {
        case .ready(let k):
            store.lock.unlock()
            countSpecialised(passes.count)
            return k
        case .failed:
            store.lock.unlock(); return nil
        case .compiling where mode == .async:
            store.lock.unlock(); return nil
        case .compiling, nil:
            break
        }
        Self.evictLocked(store, alive: Set(MTLCopyAllDevices().map(\.registryID)))   // new layout: cheap moment to forget gone devices
        if store.slots.count >= Self.maxCachedKernels {
            // Rare (many different grade structures): start over rather than track use.
            store.slots = store.slots.filter { if case .compiling = $0.value { true } else { false } }
        }
        store.slots[key] = .compiling
        store.lock.unlock()
        let source = ColorKernelSource.library(for: key.layouts)
        let count = passes.count, device = self.device
        @Sendable func finish(_ k: Kernels?) {
            store.lock.lock(); store.slots[key] = k.map { .ready($0) } ?? .failed; store.lock.unlock()
        }
        if mode == .sync {
            let k = try? Kernels(library: device.makeLibrary(source: source, options: Self.compileOptions()), passes: count, device: device)
            finish(k)
            if k != nil { countSpecialised(count) }
            return k
        }
        // The completion runs on Metal's compiler connection queue; synchronous pipeline creation there dispatch_syncs
        // onto that same queue and libdispatch traps (deadlock). Build the pipeline states on a global queue instead.
        device.makeLibrary(source: source, options: Self.compileOptions()) { @Sendable library, _ in
            guard let library else { finish(nil); return }
            DispatchQueue.global(qos: .userInitiated).async {
                finish(try? Kernels(library: library, passes: count, device: device))
            }
        }
        return nil
    }

    /// Preview: the kernels for the display-size grade of a source that must not be averaged before its tone map, when
    /// that grade can run now (`sqFusedScaledTone` is compiled for this chain). Nil while the kernels still compile, when
    /// specialisation is off, when the chain's first pass ends before its conversion, or when no step follows the
    /// conversion (nothing would move behind the scaling, and the n x n samples alone cost more than the full-size
    /// conversion: 3.29 vs 3.09 ms for three 4K layers at 52 %): the caller then grades at full size.
    /// The caller hands the result to `encodeFused`: the shared store may forget the slot in between (another
    /// compositor registers a layout and trips the wipe or the device eviction), and the work size is already chosen.
    func toneFirstKernels(for pipeline: ColorPipeline) -> Kernels? {
        defer { afterToneFirstCheck?() }
        let passes = pipeline.gpuPasses
        guard let first = passes.first, let k = ColorKernelSource.conversionIndex(first.layout),
              k + 1 < first.layout.blocks.count || passes.dropFirst().contains(where: { !$0.layout.blocks.isEmpty })
        else { return nil }
        let mode = specialization
        if mode == .off { return nil }
        let key = KernelStore.Key(device: device.registryID, layouts: passes.map(\.layout))
        let store = Self.kernelStore
        store.lock.lock()
        let slot = store.slots[key]
        store.lock.unlock()
        var found: Kernels?
        switch slot {
        case .ready(let k): found = k
        case .failed: found = nil
        // Not compiled yet: `.sync` (tests) compiles here; `.async` starts with the full-size grade of this frame.
        case .compiling, nil: found = mode == .sync ? kernels(for: passes) : nil
        }
        return found?.fusedScaledTone != nil ? found : nil
    }

    /// Tests: runs after every `toneFirstKernels(for:)` (stands in for another compositor touching the store there).
    var afterToneFirstCheck: (() -> Void)?

    /// Tests: forgets this chain's compiled kernels, as the store's wipe or eviction would.
    func forgetKernels(for pipeline: ColorPipeline) {
        let key = KernelStore.Key(device: device.registryID, layouts: pipeline.gpuPasses.map(\.layout))
        let store = Self.kernelStore
        store.lock.lock(); store.slots[key] = nil; store.lock.unlock()
    }

    private func countSpecialised(_ n: Int) { lock.lock(); _specialisedPasses += n; lock.unlock() }

    // MARK: Encode

    /// Encodes one compute pass: `source` (source-encoded, range-expanded 0…1) -> `destination` (working-linear).
    /// Alpha is passed through unchanged. `source === destination` is supported (in place).
    ///
    /// Throws on caller mistakes (checked every call; all checks are O(1) property reads):
    /// size mismatch, pixel format other than rgba16Float/rgba32Float, `destination` without `.shaderWrite`,
    /// `source` without `.shaderRead` (in place: the texture needs both), LUT with a wrong entry count, no encoder.
    ///
    /// `quarterTurned`: the texture holds a picture that is shown turned by 90 or 270 degrees (phone clips): the vignette is
    /// the only stage that depends on position, and it must follow the shown (upright) picture, not the buffer.
    /// `region`: process only this rectangle of the texture (the rest is left as it is); positions stay those of the whole
    /// texture, so the vignette is unchanged.
    public func encode(_ pipeline: ColorPipeline, source: MTLTexture, destination: MTLTexture,
                       commandBuffer: MTLCommandBuffer, quarterTurned: Bool = false,
                       region: Compositor.SourceRegion? = nil) throws {
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
        let passes = pipeline.gpuPasses
        if passes.count > 1 || inPlace {
            // Later passes (and in-place) read and write the destination.
            guard destination.usage.contains(.shaderRead) else {
                throw ColorPipelineGPUError.missingTextureUsage("destination needs .shaderRead for in-place passes")
            }
        }
        // Resolve LUT textures before creating any encoder so a throw leaves the command buffer untouched.
        let lutTextures = try luts(passes)
        try encodePasses(passes, from: 0, kernels: kernels(for: passes), luts: lutTextures, source: source,
                         destination: destination, inPlace: inPlace, commandBuffer: commandBuffer,
                         quarterTurned: quarterTurned, region: region)
    }

    func luts(_ passes: [Pass]) throws -> [(MTLTexture, MTLTexture)] {
        try passes.map { pass in
            var t3: MTLTexture = dummy3D, t1: MTLTexture = dummy2D
            if let lut = pass.lut {
                let tex = try texture(for: lut)
                if lut.kind == .lut3D { t3 = tex } else { t1 = tex }
            }
            return (t3, t1)
        }
    }

    private func header(_ pass: Pass, quarterTurned: Bool, region: Compositor.SourceRegion?) -> Header {
        var h = pass.header
        h.extra.x = quarterTurned ? 1 : 0
        h.extra.y = UInt32(region?.x ?? 0); h.extra.z = UInt32(region?.y ?? 0)
        return h
    }

    /// Header, sections and curve tables at buffer indices `base`, `base + 1`, `base + 2`.
    private func setChainBytes(_ enc: MTLComputeCommandEncoder, _ pass: Pass, header h: Header, base: Int) {
        var h = h
        enc.setBytes(&h, length: MemoryLayout<Header>.stride, index: base)
        var secs = pass.sections.isEmpty ? [Sec()] : pass.sections
        enc.setBytes(&secs, length: MemoryLayout<Sec>.stride * secs.count, index: base + 1)
        var curves = pass.curves.isEmpty ? [SIMD4<Float>.zero] : pass.curves
        enc.setBytes(&curves, length: MemoryLayout<SIMD4<Float>>.stride * curves.count, index: base + 2)
    }

    private func encodePasses(_ passes: [Pass], from first: Int, kernels: Kernels?, luts: [(MTLTexture, MTLTexture)],
                              source: MTLTexture, destination: MTLTexture, inPlace: Bool, commandBuffer: MTLCommandBuffer,
                              quarterTurned: Bool, region: Compositor.SourceRegion?) throws {
        for i in first..<passes.count {
            let pass = passes[i]
            // The first pass reads `source`; later passes work in place on `destination`.
            let inPlacePass = i > 0 || inPlace
            guard let enc = commandBuffer.makeComputeCommandEncoder() else { throw ColorPipelineGPUError.encoderUnavailable }
            let state = kernels.map { inPlacePass ? $0.inPlace[i] : $0.pass[i] } ?? (inPlacePass ? pipelineInPlace : self.pipeline)
            enc.setComputePipelineState(state)
            if inPlacePass { enc.setTexture(destination, index: 0) } else { enc.setTexture(source, index: 0); enc.setTexture(destination, index: 1) }
            enc.setTexture(luts[i].0, index: 2)
            enc.setTexture(luts[i].1, index: 3)
            setChainBytes(enc, pass, header: header(pass, quarterTurned: quarterTurned, region: region), base: 0)
            let w = state.threadExecutionWidth
            let hh = max(1, min(8, state.maxTotalThreadsPerThreadgroup / w))
            enc.dispatchThreads(MTLSize(width: region?.width ?? destination.width, height: region?.height ?? destination.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: hh, depth: 1))
            enc.endEncoding()
        }
    }

    /// The compositor's source conversion (`convertToRGB`, or `convertToRGBScaled` when `scaled`) fused into the first
    /// pass, then the remaining passes in place on `destination` (an `rgba16Float` intermediate). `bindConvert` sets
    /// the conversion's own textures 0-2 (2 = `destination`) and buffers 0-2. Same pixels as conversion into
    /// `destination` followed by `encode(pipeline, source: destination, destination: destination, ...)`.
    /// Returns false, having encoded nothing, when the specialised kernels are not ready (or a LUT is invalid): the
    /// caller then runs the two steps.
    /// `toneFirst` (with `scaled`; the result of `toneFirstKernels(for:)`, used as is, without another look into the
    /// store): `sqFusedScaledTone`, the scaling after the conversion block (log and PQ sources).
    func encodeFused(_ pipeline: ColorPipeline, scaled: Bool, toneFirst: Kernels? = nil, destination: MTLTexture,
                     region: Compositor.SourceRegion, quarterTurned: Bool, commandBuffer: MTLCommandBuffer,
                     bindConvert: (MTLComputeCommandEncoder) -> Void) -> Bool {
        let passes = pipeline.gpuPasses
        guard destination.pixelFormat == .rgba16Float, !passes.isEmpty, let k = toneFirst ?? kernels(for: passes),
              toneFirst == nil || (scaled && k.fusedScaledTone != nil && k.pass.count == passes.count),
              let lutTextures = try? luts(passes),
              let enc = commandBuffer.makeComputeCommandEncoder() else { return false }
        if toneFirst != nil { countSpecialised(passes.count) }
        let state = toneFirst != nil ? k.fusedScaledTone! : scaled ? k.fusedScaled : k.fused
        enc.setComputePipelineState(state)
        bindConvert(enc)
        enc.setTexture(lutTextures[0].0, index: 3)
        enc.setTexture(lutTextures[0].1, index: 4)
        setChainBytes(enc, passes[0], header: header(passes[0], quarterTurned: quarterTurned, region: region), base: 3)
        let w = state.threadExecutionWidth
        let hh = max(1, min(8, state.maxTotalThreadsPerThreadgroup / w))
        enc.dispatchThreads(MTLSize(width: region.width, height: region.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: hh, depth: 1))
        enc.endEncoding()
        do {
            try encodePasses(passes, from: 1, kernels: k, luts: lutTextures, source: destination, destination: destination,
                             inPlace: true, commandBuffer: commandBuffer, quarterTurned: quarterTurned, region: region)
        } catch { return true }   // no encoder for a later pass: the command buffer is unusable anyway
        return true
    }
}
#endif
