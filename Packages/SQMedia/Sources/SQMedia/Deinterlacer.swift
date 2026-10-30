import CoreMedia
import CoreVideo
import Foundation
import Metal
import SQCore
import VideoToolbox

/// Turns a woven interlaced picture (both fields in one frame) into a progressive one, one output frame per source
/// frame. The one deinterlace pass of the app: the decoder runs it on the source frame right after decode, at native
/// size, before scaling, color conversion and effects (`VTVideoDecoder(deinterlace:)`); the proxy transcoder bakes it.
///
/// Comb-adaptive, one frame at a time (no neighbor frames: a frame looks the same whatever was decoded before it,
/// so scrub, playback and export agree, and an intra-only stream needs no second decode). The field that comes first
/// in time is kept as stored. A sample of the other field stays as stored (weave, full vertical detail) unless it
/// combs: it lies beyond both vertical neighbors in the same direction and its own field's next line does too, which
/// is what motion between the two fields looks like and what a still picture (a one-line rule, a gradient, an edge)
/// does not. Combing samples are rebuilt from the kept field along the local edge direction. Chroma planes get the
/// same treatment in their own rows (interlaced 4:2:0 stores chroma per field).
///
/// The first and the last row of the picture have one vertical neighbor only, which cannot tell a comb from a still
/// edge line: they always stay as stored.
///
/// Works on bi-planar Y'CbCr (4:2:0, 4:2:2, 4:4:4; 8 bit and 10-in-16 bit) and on packed 'y416' (alpha video), which
/// is what the decoder asks VideoToolbox for. Anything else (RGB) is returned unchanged: callers that must not hand
/// on a woven picture check `isDeinterlaced`.
public enum Deinterlacer {
    /// Comb size (normalized code values) where interpolation starts and where it is complete.
    static let low: Float = 5.0 / 255.0, high: Float = 13.0 / 255.0
    /// A diagonal must beat the vertical by this much: equal candidates resolve the same way on CPU and GPU.
    static let directionBias: Float = 1.5 / 1024.0

    /// `packed`: one plane of four 16-bit channels ('y416') instead of a luma and a two-channel chroma plane.
    struct Layout: Equatable {
        var wide: Bool
        var packed = false
        var planes: Int { packed ? 1 : 2 }
        func channels(_ plane: Int) -> Int { packed ? 4 : plane + 1 }
    }

    /// Set on every picture the pass made (not propagated to copies).
    static var doneKey: CFString { "sq.deinterlaced" as CFString }

    /// Whether `pb` came out of the pass (also true for the reduced copy of such a picture).
    public static func isDeinterlaced(_ pb: CVPixelBuffer) -> Bool {
        CVBufferCopyAttachment(pb, doneKey, nil) != nil
    }

    static func layout(of format: OSType) -> Layout? {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            return Layout(wide: false)
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return Layout(wide: true)
        case kCVPixelFormatType_4444AYpCbCr16:
            return Layout(wide: true, packed: true)
        default:
            return nil
        }
    }

    public static func isSupported(_ format: OSType) -> Bool { layout(of: format) != nil }

    /// Field order a format description is tagged with (FieldCount 2 + FieldDetail); nil = progressive.
    public static func fieldOrder(of format: CMFormatDescription) -> FieldOrder? {
        MediaImporter.fieldOrder(extensions: CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:])
    }

    /// The progressive picture of `source`. On the GPU when there is one, else the CPU reference. A format the pass
    /// does not know, or a failure, returns `source` itself.
    public static func deinterlace(_ source: CVPixelBuffer, fieldOrder: FieldOrder) -> CVPixelBuffer {
        guard isSupported(CVPixelBufferGetPixelFormatType(source)) else { return source }
        if let out = MetalDeinterlacer.shared?.run(source, fieldOrder: fieldOrder) { return out }
        return deinterlaceCPU(source, fieldOrder: fieldOrder) ?? source
    }

    /// GPU path alone (tests); nil without a Metal device or for an unknown format.
    static func deinterlaceMetal(_ source: CVPixelBuffer, fieldOrder: FieldOrder) -> CVPixelBuffer? {
        guard isSupported(CVPixelBufferGetPixelFormatType(source)) else { return nil }
        return MetalDeinterlacer.shared?.run(source, fieldOrder: fieldOrder)
    }

    /// CPU reference (the definition the GPU kernel is tested against, and the fallback without a Metal device).
    public static func deinterlaceCPU(_ source: CVPixelBuffer, fieldOrder: FieldOrder) -> CVPixelBuffer? {
        guard let layout = layout(of: CVPixelBufferGetPixelFormatType(source)),
              CVPixelBufferGetPlaneCount(source) == (layout.packed ? 0 : 2),
              let out = DeinterlaceBuffers.shared.make(like: source) else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(out, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let keep = fieldOrder == .topFirst ? 0 : 1
        for plane in 0..<layout.planes {
            let p = layout.packed
            guard let s = p ? CVPixelBufferGetBaseAddress(source) : CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let d = p ? CVPixelBufferGetBaseAddress(out) : CVPixelBufferGetBaseAddressOfPlane(out, plane) else { return nil }
            let w = p ? CVPixelBufferGetWidth(source) : CVPixelBufferGetWidthOfPlane(source, plane)
            let h = p ? CVPixelBufferGetHeight(source) : CVPixelBufferGetHeightOfPlane(source, plane)
            let ss = p ? CVPixelBufferGetBytesPerRow(source) : CVPixelBufferGetBytesPerRowOfPlane(source, plane)
            let ds = p ? CVPixelBufferGetBytesPerRow(out) : CVPixelBufferGetBytesPerRowOfPlane(out, plane)
            let n = layout.channels(plane)
            if layout.wide {
                cpuPlane(UInt16.self, src: s, srcStride: ss, dst: d, dstStride: ds, width: w, height: h, channels: n, keep: keep)
            } else {
                cpuPlane(UInt8.self, src: s, srcStride: ss, dst: d, dstStride: ds, width: w, height: h, channels: n, keep: keep)
            }
        }
        propagateAttachments(from: source, to: out)
        return out
    }

    /// Color tags and the like move to the output; the field tags do not (the output is progressive).
    static func propagateAttachments(from source: CVPixelBuffer, to out: CVPixelBuffer) {
        copyTags(from: source, to: out)
        CVBufferSetAttachment(out, doneKey, kCFBooleanTrue, .shouldNotPropagate)
    }

    static func copyTags(from source: CVPixelBuffer, to out: CVPixelBuffer) {
        if let a = CVBufferCopyAttachments(source, .shouldPropagate) { CVBufferSetAttachments(out, a, .shouldPropagate) }
        CVBufferRemoveAttachment(out, kCVImageBufferFieldCountKey)
        CVBufferRemoveAttachment(out, kCVImageBufferFieldDetailKey)
    }

    private static func cpuPlane<T: FixedWidthInteger & UnsignedInteger>(
        _: T.Type, src: UnsafeRawPointer, srcStride: Int, dst: UnsafeMutableRawPointer, dstStride: Int,
        width w: Int, height h: Int, channels n: Int, keep: Int) {
        let scale = Float(T.max)
        let rowBytes = w * n * MemoryLayout<T>.stride
        func row(_ y: Int) -> UnsafePointer<T> { (src + y * srcStride).assumingMemoryBound(to: T.self) }
        @inline(__always) func f(_ p: UnsafePointer<T>, _ i: Int) -> Float { Float(p[i]) / scale }
        @inline(__always) func diff(_ a: UnsafePointer<T>, _ i: Int, _ b: UnsafePointer<T>, _ j: Int) -> Float {
            var s: Float = 0
            for ch in 0..<n { s += abs(f(a, i * n + ch) - f(b, j * n + ch)) }
            return s
        }
        var comb = [Float](repeating: 0, count: w)
        for y in 0..<h {
            memcpy(dst + y * dstStride, src + y * srcStride, rowBytes)
            // An edge row has one neighbor: it stays as stored (a still edge line is not a comb).
            if (y & 1) == keep || y == 0 || y == h - 1 || w < 1 { continue }
            let out = (dst + y * dstStride).assumingMemoryBound(to: T.self)
            let c = row(y), a = row(y - 1), b = row(y + 1)
            let cu = y - 2 >= 0 ? row(y - 2) : c, cd = y + 2 < h ? row(y + 2) : c
            for x in 0..<w {
                var m: Float = 0
                for ch in 0..<n {
                    let i = x * n + ch
                    let fc = f(c, i), fa = f(a, i), fb = f(b, i)
                    let d1 = fc - fa, d2 = fc - fb
                    if d1 * d2 > 0 {
                        let s: Float = d1 > 0 ? 1 : -1
                        m = max(m, min(min(abs(d1), abs(d2)), max(max(s * (f(cu, i) - fa), s * (f(cd, i) - fb)), 0)))
                    }
                }
                comb[x] = m
            }
            for x in 0..<w {
                let xm = max(x - 1, 0), xp = min(x + 1, w - 1), xm2 = max(x - 2, 0), xp2 = min(x + 2, w - 1)
                let m = max(comb[xm], max(comb[x], comb[xp]))
                let weight = min(max((m - low) / (high - low), 0), 1)
                if weight <= 0 { continue }
                var best = diff(a, xm, b, xm) + diff(a, x, b, x) + diff(a, xp, b, xp)
                var ia = x, ib = x
                var d = diff(a, xm2, b, x) + diff(a, xm, b, xp) + diff(a, x, b, xp2)
                if d + directionBias < best { best = d; ia = xm; ib = xp }
                d = diff(a, x, b, xm2) + diff(a, xp, b, xm) + diff(a, xp2, b, x)
                if d + directionBias < best { ia = xp; ib = xm }
                for ch in 0..<n {
                    let fa = f(a, x * n + ch), fb = f(b, x * n + ch), fc = f(c, x * n + ch)
                    var r = (f(a, ia * n + ch) + f(b, ib * n + ch)) * 0.5
                    r = min(max(r, min(fa, fb)), max(fa, fb))
                    let v = fc + (r - fc) * weight
                    out[x * n + ch] = T(min(max(v * scale + 0.5, 0), scale))
                }
            }
        }
    }
}

/// Output buffers (IOSurface, Metal compatible), one pool per format and size. At most `capacity` pools: a new size
/// drops the pool used longest ago (the size of media no longer decoded), never the ones in use, so more sizes at
/// once than `capacity` cost one pool per change instead of all of them.
final class DeinterlaceBuffers: @unchecked Sendable {
    static let shared = DeinterlaceBuffers()
    struct Key: Hashable { var format: OSType, width: Int, height: Int }
    private struct Entry { var pool: CVPixelBufferPool, used: UInt64 }
    let capacity: Int
    private let lock = NSLock()
    private var pools: [Key: Entry] = [:]
    private var clock: UInt64 = 0

    init(capacity: Int = 8) { self.capacity = max(capacity, 1) }

    /// The sizes that have a pool right now (tests).
    var keys: Set<Key> { lock.withLock { Set(pools.keys) } }

    func make(like source: CVPixelBuffer) -> CVPixelBuffer? {
        make(format: CVPixelBufferGetPixelFormatType(source), width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
    }

    func make(format: OSType, width: Int, height: Int) -> CVPixelBuffer? {
        let key = Key(format: format, width: width, height: height)
        let pool: CVPixelBufferPool? = lock.withLock {
            clock += 1
            if let e = pools[key] {
                pools[key]?.used = clock
                return e.pool
            }
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: key.format, kCVPixelBufferWidthKey: key.width,
                                          kCVPixelBufferHeightKey: key.height, kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            guard let p else { return nil }
            while pools.count >= capacity, let oldest = pools.min(by: { $0.value.used < $1.value.used })?.key {
                pools[oldest] = nil
            }
            pools[key] = Entry(pool: p, used: clock)
            return p
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }
}

/// The GPU kernel: the same arithmetic as `Deinterlacer.cpuPlane`, once per plane. Built on the first interlaced
/// frame, so progressive media never pays for it.
final class MetalDeinterlacer: @unchecked Sendable {
    static let shared: MetalDeinterlacer? = MetalDeinterlacer()

    private struct Params { var keep: Int32, low: Float, high: Float, bias: Float }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private let lock = NSLock()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let fn = library.makeFunction(name: "sq_deinterlace"),
              let pipeline = try? device.makeComputePipelineState(function: fn) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.device = device; self.queue = queue; self.pipeline = pipeline; self.cache = cache
        queue.label = "sq.deinterlace"
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, layout: Deinterlacer.Layout, write: Bool) -> CVMetalTexture? {
        let wide = layout.wide
        let format: MTLPixelFormat = layout.packed ? .rgba16Unorm
            : plane == 0 ? (wide ? .r16Unorm : .r8Unorm) : (wide ? .rg16Unorm : .rg8Unorm)
        let usage: MTLTextureUsage = write ? [.shaderRead, .shaderWrite] : [.shaderRead]
        let attrs = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        let w = layout.packed ? CVPixelBufferGetWidth(pb) : CVPixelBufferGetWidthOfPlane(pb, plane)
        let h = layout.packed ? CVPixelBufferGetHeight(pb) : CVPixelBufferGetHeightOfPlane(pb, plane)
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, attrs, format, w, h, plane, &t)
        return t
    }

    func run(_ source: CVPixelBuffer, fieldOrder: FieldOrder) -> CVPixelBuffer? {
        guard let layout = Deinterlacer.layout(of: CVPixelBufferGetPixelFormatType(source)),
              CVPixelBufferGetPlaneCount(source) == (layout.packed ? 0 : 2),
              CVPixelBufferGetIOSurface(source) != nil, let out = DeinterlaceBuffers.shared.make(like: source) else { return nil }
        // The texture cache is not safe to use from two threads at once (decoders of several media run in parallel).
        let textures: [CVMetalTexture]? = lock.withLock {
            var all: [CVMetalTexture] = []
            for plane in 0..<layout.planes {
                guard let s = texture(source, plane: plane, layout: layout, write: false),
                      let d = texture(out, plane: plane, layout: layout, write: true) else { return nil }
                all += [s, d]
            }
            return all
        }
        guard let textures, let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return nil }
        var params = Params(keep: fieldOrder == .topFirst ? 0 : 1, low: Deinterlacer.low, high: Deinterlacer.high,
                            bias: Deinterlacer.directionBias)
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        let tw = pipeline.threadExecutionWidth, th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        for plane in 0..<layout.planes {
            guard let s = CVMetalTextureGetTexture(textures[plane * 2]), let d = CVMetalTextureGetTexture(textures[plane * 2 + 1]) else {
                encoder.endEncoding(); return nil
            }
            encoder.setTexture(s, index: 0)
            encoder.setTexture(d, index: 1)
            encoder.dispatchThreadgroups(MTLSize(width: (s.width + tw - 1) / tw, height: (s.height + th - 1) / th, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let failed = commands.status != .completed
        withExtendedLifetime(textures) {}
        lock.withLock { CVMetalTextureCacheFlush(cache, 0) }
        if failed { return nil }
        Deinterlacer.propagateAttachments(from: source, to: out)
        return out
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { int keep; float low; float high; float bias; };

    static inline float4 px(texture2d<float, access::read> t, int x, int y, int w) {
        return t.read(uint2(clamp(x, 0, w - 1), y));
    }
    static inline float total(float4 v) { return v.x + v.y + v.z + v.w; }

    static float comb(texture2d<float, access::read> t, int x, int y, int ya, int yb, int w, int h) {
        float4 c = px(t, x, y, w), a = px(t, x, ya, w), b = px(t, x, yb, w);
        float4 cu = c, cd = c;
        if (y - 2 >= 0) { cu = px(t, x, y - 2, w); }
        if (y + 2 < h) { cd = px(t, x, y + 2, w); }
        float4 d1 = c - a, d2 = c - b;
        float4 s = sign(d1);
        float4 m = min(min(abs(d1), abs(d2)), max(max(s * (cu - a), s * (cd - b)), float4(0.0)));
        m = select(float4(0.0), m, d1 * d2 > float4(0.0));
        return max(max(m.x, m.y), max(m.z, m.w));
    }

    kernel void sq_deinterlace(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant Params &p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        int w = src.get_width(), h = src.get_height();
        if (int(gid.x) >= w || int(gid.y) >= h) { return; }
        int x = gid.x, y = gid.y;
        float4 c = src.read(gid);
        if ((y & 1) == p.keep || y == 0 || y == h - 1) { dst.write(c, gid); return; }
        int ya = y > 0 ? y - 1 : y + 1;
        int yb = y + 1 < h ? y + 1 : y - 1;
        float m = max(comb(src, x - 1, y, ya, yb, w, h), max(comb(src, x, y, ya, yb, w, h), comb(src, x + 1, y, ya, yb, w, h)));
        float weight = clamp((m - p.low) / (p.high - p.low), 0.0f, 1.0f);
        if (weight <= 0.0f) { dst.write(c, gid); return; }
        float4 a0 = px(src, x, ya, w), am = px(src, x - 1, ya, w), ap = px(src, x + 1, ya, w);
        float4 am2 = px(src, x - 2, ya, w), ap2 = px(src, x + 2, ya, w);
        float4 b0 = px(src, x, yb, w), bm = px(src, x - 1, yb, w), bp = px(src, x + 1, yb, w);
        float4 bm2 = px(src, x - 2, yb, w), bp2 = px(src, x + 2, yb, w);
        float best = total(abs(am - bm)) + total(abs(a0 - b0)) + total(abs(ap - bp));
        float4 r = (a0 + b0) * 0.5f;
        float d = total(abs(am2 - b0)) + total(abs(am - bp)) + total(abs(a0 - bp2));
        if (d + p.bias < best) { best = d; r = (am + bp) * 0.5f; }
        d = total(abs(a0 - bm2)) + total(abs(ap - bm)) + total(abs(ap2 - b0));
        if (d + p.bias < best) { r = (ap + bm) * 0.5f; }
        r = clamp(r, min(a0, b0), max(a0, b0));
        dst.write(c + (r - c) * weight, gid);
    }
    """
}

/// Brings a deinterlaced picture (the pass works at the stored size) down to the size a reduced decode is keyed at, so a
/// frame has the size its cache key names. One per decoder.
final class DeinterlacedFrameScaler: @unchecked Sendable {
    private let divisor: Int
    private let lock = NSLock()
    private var session: VTPixelTransferSession?

    init(divisor: Int) { self.divisor = divisor }
    deinit { if let session { VTPixelTransferSessionInvalidate(session) } }

    /// The reduced copy of `pb`; `pb` itself when there is nothing to reduce or the transfer fails.
    func run(_ pb: CVPixelBuffer) -> CVPixelBuffer {
        let (fw, fh) = (CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb))
        let w = max(2, (fw / divisor) & ~1), h = max(2, (fh / divisor) & ~1)
        guard divisor > 1, w < fw || h < fh,
              let out = DeinterlaceBuffers.shared.make(format: CVPixelBufferGetPixelFormatType(pb), width: w, height: h) else { return pb }
        Deinterlacer.copyTags(from: pb, to: out)
        CVBufferRemoveAttachment(out, kCVImageBufferCleanApertureKey)       // names the full-size picture
        let ok = lock.withLock { () -> Bool in
            if session == nil { VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session) }
            guard let session else { return false }
            return VTPixelTransferSessionTransferImage(session, from: pb, to: out) == noErr
        }
        guard ok else { return pb }
        if Deinterlacer.isDeinterlaced(pb) { CVBufferSetAttachment(out, Deinterlacer.doneKey, kCFBooleanTrue, .shouldNotPropagate) }
        return out
    }
}
