import SQGPU
import SQGPUKernels

/// Optical flow of `GPUCompositor` (`FrameBlend.flow`): the shared `OpticalFlowPasses` on the compositor's device with a
/// field cache per source frame pair, as the Metal `OpticalFlowEngine` keeps one (a 25 % slow motion measures once per
/// four output frames). Scratch textures go back to the pool at the next `render`, like the compositor's intermediates.
final class GPUFlowStore<D: GPUDevice> {
    struct Key: Hashable { var pair: FlowPairKey; var quality: FlowQuality; var width: Int; var height: Int }
    let passes: OpticalFlowPasses<D>
    private let device: D
    private var cache: [Key: OpticalFlowPasses<D>.Field] = [:]
    private var order: [Key] = []
    private var free: [D.Texture] = []
    private var inFlight: [D.Texture] = []
    /// Cap of cached fields in bytes (as `OpticalFlowEngine.cacheByteLimit`).
    var cacheByteLimit = 128 << 20
    /// Fields measured so far (tests).
    private(set) var measureCount = 0

    init(device: D, kernels: GPUKernels<D>) {
        self.device = device
        passes = OpticalFlowPasses(kernels: kernels)
    }

    /// The previous render finished (the compositor's pool rule): its scratch is free again; at most about two working
    /// sizes stay pooled.
    func beginRender() {
        free += inFlight; inFlight.removeAll()
        var total = free.reduce(0) { $0 + Self.bytes($1) }
        while total > 64 << 20, !free.isEmpty { total -= Self.bytes(free.removeFirst()) }
    }

    func trim() { cache.removeAll(); order.removeAll(); free.removeAll() }

    var cachedPairs: Int { cache.count }

    /// The field pair of `a` and `b` (source-encoded RGB, full size): cached or measured into `cb`.
    func field(a: D.Texture, b: D.Texture, request: OpticalFlowRequest, _ cb: D.CommandBuffer) -> OpticalFlowPasses<D>.Field? {
        let key = request.key.map { Key(pair: $0, quality: request.quality, width: a.width, height: a.height) }
        if let key, let f = cache[key] {
            if let i = order.firstIndex(of: key) { order.remove(at: i); order.append(key) }
            return f
        }
        var taken: [D.Texture] = []
        let f = passes.measure(a: a, b: b, quality: request.quality, cb,
                               scratch: { w, h, format in
                                   let t = self.acquire(w, h, format)
                                   if let t { taken.append(t) }
                                   return t
                               },
                               field: { w, h in self.device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba32Float)) })
        inFlight += taken
        guard let f else { return nil }
        measureCount += 1
        if let key {
            if cache[key] == nil { order.append(key) }
            cache[key] = f
            var total = cache.values.reduce(0) { $0 + Self.bytes($1.forward) + Self.bytes($1.backward) }
            while total > cacheByteLimit, order.count > 1 {
                let k = order.removeFirst()
                if let e = cache.removeValue(forKey: k) { total -= Self.bytes(e.forward) + Self.bytes(e.backward) }
            }
        }
        return f
    }

    private func acquire(_ w: Int, _ h: Int, _ format: GPUPixelFormat) -> D.Texture? {
        if let i = free.firstIndex(where: { $0.width == w && $0.height == h && $0.format == format }) { return free.remove(at: i) }
        return device.makeTexture(GPUTextureDescriptor(width: w, height: h, format: format))
    }

    private static func bytes(_ t: D.Texture) -> Int { t.width * t.height * t.format.bytesPerPixel }
}

extension GPUCompositor {
    /// Optical flow, built on first use.
    func flowPasses() -> GPUFlowStore<D> {
        if let s = flowStore { return s }
        let s = GPUFlowStore(device: device, kernels: kernels)
        flowStore = s
        return s
    }

    /// Optical-flow fields measured so far (tests: a cached pair measures once).
    public var flowMeasureCount: Int { flowStore?.measureCount ?? 0 }
}
