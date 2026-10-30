#if canImport(Metal)
import Foundation
import Metal
import SQCore
import SQGPU
import SQGPUKernels
import SQGPUMetal

/// GPU optical flow for `TimeInterpolation.opticalFlow` (own Metal, deterministic: playback and export run the same
/// kernels on the same inputs).
///
/// Motion: dense pyramidal Lucas-Kanade on luma at a working size (long side 960, `.faster` 480), coarse to fine, a few
/// Gauss-weighted window iterations per level and a 3 x 3 median per level against outliers. Measured both ways (A to B
/// and B to A); the pair is cached per source frame pair (bounded by bytes, oldest out), so a 25 % slow motion measures
/// once per four output frames.
///
/// Picture: for each output pixel two candidates move A and B to the instant `t` (the forward field, and the reversed
/// backward one); each is weighted by how well its two samples agree. Where neither agrees (occlusion, a cut, noise) the
/// output falls back to the plain frame blend, so a failed estimate never shows worse than Blend frames.
final class OpticalFlowEngine: @unchecked Sendable {
    let device: MTLDevice
    private let gpu: MetalGPUDevice
    private let passes: OpticalFlowPasses<MetalGPUDevice>

    private let lock = NSLock()
    private struct CacheKey: Hashable { var pair: FlowPairKey; var quality: FlowQuality; var width: Int; var height: Int }
    private struct Entry { var forward: MTLTexture; var backward: MTLTexture; var ready: Bool; weak var queue: MTLCommandQueue? }
    private var cache: [CacheKey: Entry] = [:]
    private var order: [CacheKey] = []
    private var free: [MTLTexture] = []
    /// Cap of cached flow fields in bytes (a 1024-wide pair is about 19 MB: flow and trust, both directions).
    var cacheByteLimit = 128 << 20
    /// Fields measured so far (tests, diagnostics).
    private(set) var measureCount = 0

    struct Field { var forward: MTLTexture; var backward: MTLTexture }

    /// The kernels are the renderer's (OpticalFlow.slang in SQGPUKernels); nothing compiles here.
    init(gpu: MetalGPUDevice, kernels: GPUKernels<MetalGPUDevice>) {
        self.device = gpu.device
        self.gpu = gpu
        self.passes = OpticalFlowPasses(kernels: kernels)
    }

    /// Working size of the motion estimate for a `width` x `height` frame (`OpticalFlowPasses.workingSize`).
    static func workingSize(width: Int, height: Int, quality: FlowQuality) -> (Int, Int) {
        OpticalFlowPasses<MetalGPUDevice>.workingSize(width: width, height: height, quality: quality)
    }

    /// The flow pair of frames `a` and `b` (source-encoded RGB, full size): from the cache, or measured into
    /// `commandBuffer`. Encode this before anything changes `a`/`b` in place (the color pipeline).
    func field(a: MTLTexture, b: MTLTexture, request: OpticalFlowRequest, commandBuffer: MTLCommandBuffer) -> Field? {
        let key = request.key.map { CacheKey(pair: $0, quality: request.quality, width: a.width, height: a.height) }
        if let key {
            lock.lock()
            // A field still being written is safe to read from the same queue (Metal orders tracked resources there).
            if let e = cache[key], e.ready || e.queue === commandBuffer.commandQueue {
                if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
                lock.unlock()
                return Field(forward: e.forward, backward: e.backward)
            }
            lock.unlock()
        }
        guard let f = measure(a: a, b: b, quality: request.quality, commandBuffer: commandBuffer) else { return nil }
        if let key {
            lock.lock()
            if cache[key] == nil { order.append(key) }
            cache[key] = Entry(forward: f.forward, backward: f.backward, ready: false, queue: commandBuffer.commandQueue)
            evictLocked()
            lock.unlock()
            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.cache[key]?.ready = true; self.lock.unlock()
            }
        }
        return f
    }

    /// Writes the picture at `t` (0 = `a`, 1 = `b`) into `out`. `linearize`: `a`/`b` are source-encoded BT.709 (the mix
    /// runs in light, like Frame Blending); false: already working-linear.
    func encodeInterpolation(a: MTLTexture, b: MTLTexture, field: Field, t: Float, linearize: Bool, into out: MTLTexture,
                             commandBuffer: MTLCommandBuffer) {
        passes.interpolate(a: MetalGPUTexture(a), b: MetalGPUTexture(b),
                           field: .init(forward: MetalGPUTexture(field.forward), backward: MetalGPUTexture(field.backward)),
                           t: t, linearize: linearize, into: MetalGPUTexture(out), gpu.wrap(commandBuffer))
    }

    /// Drops every cached field (memory pressure).
    func trim() {
        lock.lock(); cache.removeAll(); order.removeAll(); free.removeAll(); lock.unlock()
    }

    var cachedPairs: Int { lock.lock(); defer { lock.unlock() }; return cache.count }

    // MARK: Measuring

    /// The shared passes (`OpticalFlowPasses`) on this engine's pool.
    private func measure(a: MTLTexture, b: MTLTexture, quality: FlowQuality, commandBuffer cb: MTLCommandBuffer) -> Field? {
        var scratch: [MTLTexture] = []
        let f = passes.measure(a: MetalGPUTexture(a), b: MetalGPUTexture(b), quality: quality, gpu.wrap(cb),
                               scratch: { w, h, format in
                                   let t = self.acquire(w, h, format == .r32Float ? .r32Float : .rg32Float)
                                   if let t { scratch.append(t) }
                                   return t.map(MetalGPUTexture.init)
                               },
                               field: { w, h in self.makeTexture(w, h, .rgba32Float).map(MetalGPUTexture.init) })
        guard let f else { release(scratch); return nil }
        lock.lock(); measureCount += 1; lock.unlock()
        cb.addCompletedHandler { [weak self] _ in self?.release(scratch) }
        return Field(forward: f.forward.texture, backward: f.backward.texture)
    }

    private func makeTexture(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    private func acquire(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture? {
        lock.lock()
        if let i = free.firstIndex(where: { $0.width == w && $0.height == h && $0.pixelFormat == f }) {
            let t = free.remove(at: i); lock.unlock(); return t
        }
        lock.unlock()
        return makeTexture(w, h, f)
    }

    private func release(_ textures: [MTLTexture]) {
        lock.lock()
        free.append(contentsOf: textures)
        // Scratch for about two working sizes at once; older sets go.
        var total = free.reduce(0) { $0 + Self.bytes($1) }
        while total > 64 << 20, !free.isEmpty { total -= Self.bytes(free.removeFirst()) }
        lock.unlock()
    }

    private static func bytes(_ t: MTLTexture) -> Int {
        t.width * t.height * (t.pixelFormat == .r32Float ? 4 : t.pixelFormat == .rgba32Float ? 16 : 8)
    }

    private func evictLocked() {
        var total = cache.values.reduce(0) { $0 + Self.bytes($1.forward) + Self.bytes($1.backward) }
        while total > cacheByteLimit, order.count > 1 {
            let k = order.removeFirst()
            if let e = cache.removeValue(forKey: k) { total -= Self.bytes(e.forward) + Self.bytes(e.backward) }
        }
    }
}
#endif
