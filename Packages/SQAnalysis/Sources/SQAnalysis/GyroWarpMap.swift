import CoreVideo
import Foundation
import Metal
import Synchronization

// Gyroflow warp on the GPU (DECISIONS "Gyroflow warp on the GPU"). Warping a 4K frame through libsqgyro's CPU buffers
// costs 55-90 ms (wgpu uploads, warps and reads back every plane). Instead libsqgyro warps two small probe planes
// (a quarter of the frame per side): an (x, y) ramp and a constant. What comes back says, for every coarse output
// texel, which source position it samples (ramps) and whether the filter stayed inside the picture (constant):
// whatever gyroflow_core does (lens model, rolling shutter, adaptive zoom, horizon lock) is in the map, and libsqgyro's
// C API stays as it is. Near the picture's border the ramps are mixed with background; those texels are refilled by
// extrapolating the smooth map from the clean texels next to them. `GyroMetalWarp` then resamples the full frame with
// the map in one Metal compute pass per plane, with gyroflow_core's Lanczos-4 filter and background. The map is
// normalized, so one map serves every decode size (proxy, reduced-quality decode, full): playback and export get the
// same pixels.

/// A decoded map on the CPU side (tests, synthetic maps). Texel j of a map n wide stands for the output position
/// (j + 0.5) / n (gyroflow_core renders output pixel centers) and holds (u, v, ok, 0): u, v the source position it
/// samples, normalized to the picture with source pixel k of a plane m wide at k / m (gyroflow_core reads source pixels
/// at integer positions); ok = 1 when known.
struct GyroWarpMap: Sendable {
    let width: Int
    let height: Int
    let texels: [SIMD4<Float>]

    init(width: Int, height: Int, texels: [SIMD4<Float>]) {
        precondition(texels.count == width * height)
        self.width = width; self.height = height; self.texels = texels
    }

    /// Full scale of the probe planes (16-bit). Below 65535 so that filter overshoot never clips.
    static let encodeScale: Float = 60000

    /// Divisor so that the map's long side stays near 480 (a quarter up to 1920 wide; 4K gets 480x270). Building the map
    /// costs two libsqgyro probe warps, which scale with the map's pixels.
    static func divisor(frameWidth: Int, frameHeight: Int) -> Int {
        max(4, (max(frameWidth, frameHeight) + 479) / 480)
    }

    /// Map size for a clip's frame size: a quarter per side (lens distortion and rolling shutter are smooth at that
    /// scale; 960x540 probes for 4K), at least 16 so gyroflow_core's filter has room.
    static func size(frameWidth: Int, frameHeight: Int, divisor: Int = 4) -> (width: Int, height: Int) {
        (max(16, (frameWidth + divisor - 1) / divisor), max(16, (frameHeight + divisor - 1) / divisor))
    }

    /// The probe planes (16-bit, full range): `xy` interleaved x and y ramps (gyroflow_core's 2-channel CbCr layout),
    /// `coverage` a constant at full scale (1-channel luma layout; its background is 0).
    static func probePlanes(width: Int, height: Int) -> (xy: [UInt16], coverage: [UInt16]) {
        let sx = encodeScale / Float(max(1, width - 1)), sy = encodeScale / Float(max(1, height - 1))
        var xy = [UInt16](repeating: 0, count: width * height * 2)
        for j in 0..<height {
            let vy = UInt16((Float(j) * sy).rounded())
            for i in 0..<width {
                xy[2 * (j * width + i)] = UInt16((Float(i) * sx).rounded())
                xy[2 * (j * width + i) + 1] = vy
            }
        }
        return (xy, [UInt16](repeating: UInt16(encodeScale), count: width * height))
    }
}

/// A map on the GPU: `width` x `height` float4 texels as in `GyroWarpMap`.
struct GyroWarpMapGPU: @unchecked Sendable {
    let width: Int
    let height: Int
    let buffer: MTLBuffer

    /// Reads the texels back (tests).
    var texels: [SIMD4<Float>] {
        Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: width * height))
    }
}

/// Probe planes of one size, allocated once (libsqgyro reads them on every map).
final class GyroProbes: @unchecked Sendable {
    let width: Int, height: Int
    let xy: UnsafeMutableBufferPointer<UInt16>
    let coverage: UnsafeMutableBufferPointer<UInt16>

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        let p = GyroWarpMap.probePlanes(width: width, height: height)
        xy = .allocate(capacity: p.xy.count); _ = xy.initialize(from: p.xy)
        coverage = .allocate(capacity: p.coverage.count); _ = coverage.initialize(from: p.coverage)
    }
    deinit { xy.deallocate(); coverage.deallocate() }

    private static let cache = Mutex<[Int: GyroProbes]>([:])
    static func shared(width: Int, height: Int) -> GyroProbes {
        cache.withLock { c in
            if let p = c[width << 20 | height] { return p }
            if c.count > 4 { c.removeAll() }
            let p = GyroProbes(width: width, height: height)
            c[width << 20 | height] = p
            return p
        }
    }
}

/// The Metal passes. Safe from any thread (one command buffer per call).
final class GyroMetalWarp: @unchecked Sendable {
    static let shared: GyroMetalWarp? = GyroMetalWarp()

    /// Refill passes: each extends the clean map by one texel. The probe filter spoils 4 texels on each side of the
    /// picture border; 10 reach past it, and anything further out is background anyway.
    static let fillPasses = 10

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let warpPipeline: MTLComputePipelineState
    private let decodePipeline: MTLComputePipelineState
    private let fillPipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        guard let lib = try? device.makeLibrary(source: Self.msl, options: options),
              let w = lib.makeFunction(name: "sq_gyro_warp").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let d = lib.makeFunction(name: "sq_gyro_map_decode").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let f = lib.makeFunction(name: "sq_gyro_map_fill").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else { return nil }
        var cache: CVMetalTextureCache?
        let attrs = [kCVMetalTextureUsage as String: NSNumber(value: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue)]
        guard CVMetalTextureCacheCreate(nil, nil, device, attrs as CFDictionary, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.device = device; self.queue = queue; self.cache = cache
        warpPipeline = w; decodePipeline = d; fillPipeline = f
        queue.label = "sq.gyroflow.warp"
    }

    /// A decoded map as is (tests, synthetic maps).
    func upload(_ map: GyroWarpMap) -> GyroWarpMapGPU? {
        guard let b = map.texels.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        else { return nil }
        return GyroWarpMapGPU(width: map.width, height: map.height, buffer: b)
    }

    /// Builds a map: `warpProbes` writes the warped probes (xy interleaved, then coverage; 16-bit, rows of width
    /// samples) straight into GPU-visible memory; the GPU decodes them and refills the border. nil = probes failed.
    func makeMap(width: Int, height: Int,
                 warpProbes: (_ xy: UnsafeMutableRawPointer, _ coverage: UnsafeMutableRawPointer) -> Bool) -> GyroWarpMapGPU? {
        let n = width * height
        guard let raw = device.makeBuffer(length: n * 6, options: .storageModeShared),
              let a = device.makeBuffer(length: n * 16, options: .storageModeShared),
              let b = device.makeBuffer(length: n * 16, options: .storageModeShared) else { return nil }
        guard warpProbes(raw.contents(), raw.contents() + n * 4) else { return nil }
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return nil }
        var p = MapParams(size: SIMD2(UInt32(width), UInt32(height)), scale: GyroWarpMap.encodeScale)
        let grid = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1), tg = MTLSize(width: 16, height: 16, depth: 1)
        enc.setComputePipelineState(decodePipeline)
        enc.setBuffer(raw, offset: 0, index: 0)
        enc.setBuffer(a, offset: 0, index: 1)
        enc.setBytes(&p, length: MemoryLayout<MapParams>.stride, index: 2)
        enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
        enc.setComputePipelineState(fillPipeline)
        var (src, dst) = (a, b)
        for _ in 0..<Self.fillPasses {
            enc.setBuffer(src, offset: 0, index: 0)
            enc.setBuffer(dst, offset: 0, index: 1)
            enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
            swap(&src, &dst)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        guard cb.status == .completed else { return nil }
        return GyroWarpMapGPU(width: width, height: height, buffer: src)
    }

    /// Plane textures and their background for a pixel format. nil = not supported.
    private static func planes(_ format: OSType, fullRange: Bool) -> [(MTLPixelFormat, SIMD4<Float>)]? {
        let y: Float = fullRange ? 0 : 16.0 / 255.0, c: Float = 128.0 / 255.0
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            return [(.r8Unorm, SIMD4(y, 0, 0, 1)), (.rg8Unorm, SIMD4(c, c, 0, 1))]
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return [(.r16Unorm, SIMD4(y, 0, 0, 1)), (.rg16Unorm, SIMD4(0.5, 0.5, 0, 1))]
        case kCVPixelFormatType_32BGRA:
            return [(.bgra8Unorm, SIMD4(0, 0, 0, 1))]
        default:
            return nil
        }
    }

    static func supports(_ format: OSType) -> Bool { planes(format, fullRange: false) != nil }

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        let planar = CVPixelBufferIsPlanar(pb)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pb, plane) : CVPixelBufferGetWidth(pb)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pb, plane) : CVPixelBufferGetHeight(pb)
        var t: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &t) == kCVReturnSuccess,
              let t, let tex = CVMetalTextureGetTexture(t) else { return nil }
        return (tex, t)
    }

    /// Resamples `src` into `dst` (same pixel format; sizes may differ from the map's frame, the map is normalized).
    /// Blocks until the GPU is done (the render paths hand the buffer on at once). false = unsupported / failed.
    func warp(_ src: CVPixelBuffer, into dst: CVPixelBuffer, map: GyroWarpMapGPU, fullRange: Bool) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(src)
        guard format == CVPixelBufferGetPixelFormatType(dst), let planes = Self.planes(format, fullRange: fullRange),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
        var keep: [CVMetalTexture] = []
        enc.setComputePipelineState(warpPipeline)
        enc.setBuffer(map.buffer, offset: 0, index: 0)
        for (i, (pf, bg)) in planes.enumerated() {
            guard let (s, sRef) = texture(src, plane: i, format: pf), let (d, dRef) = texture(dst, plane: i, format: pf) else {
                enc.endEncoding(); return false
            }
            keep += [sRef, dRef]
            var p = WarpParams(dstSize: SIMD2(UInt32(d.width), UInt32(d.height)), srcSize: SIMD2(UInt32(s.width), UInt32(s.height)),
                               mapSize: SIMD2(UInt32(map.width), UInt32(map.height)), background: bg)
            enc.setTexture(s, index: 0)
            enc.setTexture(d, index: 1)
            enc.setBytes(&p, length: MemoryLayout<WarpParams>.stride, index: 1)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            enc.dispatchThreadgroups(MTLSize(width: (d.width + 15) / 16, height: (d.height + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime(keep) {}
        return cb.status == .completed
    }

    private struct MapParams {
        var size: SIMD2<UInt32>
        var scale: Float
    }

    private struct WarpParams {
        var dstSize: SIMD2<UInt32>
        var srcSize: SIMD2<UInt32>
        var mapSize: SIMD2<UInt32>
        var background: SIMD4<Float>
    }

    /// Decode: ramps -> normalized source position; a texel is clean when the probe filter's weights all fell inside
    /// the picture (coverage at full scale). Fill: a texel that is not clean takes the mean of the straight-line
    /// extrapolations (2·p1 - p2) along the 8 directions with two clean texels. Warp: output pixel -> map
    /// (pixel centers, like the map texels; a map built at the frame's own size reproduces libsqgyro to the bit), bilinear between map texels (linear extrapolation past the
    /// last one; background when a corner is unknown), then Lanczos-4 over 8x8 source pixels with the background
    /// outside the picture, positions rounded to 1/32 pixel and weights normalized like gyroflow_core's
    /// `sample_input_at` (wgpu_undistort.wgsl).
    static let msl = """
    #include <metal_stdlib>
    using namespace metal;
    struct MapParams { uint2 size; float scale; };
    struct WarpParams { uint2 dstSize; uint2 srcSize; uint2 mapSize; float4 background; };

    kernel void sq_gyro_map_decode(const device ushort *raw [[buffer(0)]], device float4 *map [[buffer(1)]],
                                   constant MapParams &p [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.size.x || gid.y >= p.size.y) return;
        uint n = p.size.x * p.size.y, i = gid.y * p.size.x + gid.x;
        float cov = float(raw[2 * n + i]);
        bool clean = fabs(cov - p.scale) <= 2.0f;
        float2 k = float2(p.size - 1) / float2(p.size) / p.scale;
        float2 uv = float2(raw[2 * i], raw[2 * i + 1]) * k;
        map[i] = clean ? float4(uv, 1.0f, 0.0f) : float4(0.0f);
    }

    kernel void sq_gyro_map_fill(const device float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]],
                                 constant MapParams &p [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.size.x || gid.y >= p.size.y) return;
        int2 size = int2(p.size), g = int2(gid);
        float4 here = src[gid.y * p.size.x + gid.x];
        if (here.z > 0.5f) { dst[gid.y * p.size.x + gid.x] = here; return; }
        const int2 dirs[8] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1), int2(1, 1), int2(-1, -1), int2(1, -1), int2(-1, 1) };
        float2 sum = float2(0.0f);
        float count = 0.0f;
        for (int d = 0; d < 8; d++) {
            int2 a = g + dirs[d], b = g + 2 * dirs[d];
            if (any(a < 0) || any(b < 0) || any(a >= size) || any(b >= size)) continue;
            float4 pa = src[a.y * size.x + a.x], pb = src[b.y * size.x + b.x];
            if (pa.z > 0.5f && pb.z > 0.5f) { sum += 2.0f * pa.xy - pb.xy; count += 1.0f; }
        }
        dst[gid.y * p.size.x + gid.x] = count > 0.0f ? float4(sum / count, 1.0f, 0.0f) : here;
    }

    static inline void lanczos4(float x, thread float *c) {
        if (x < 1.19209290e-07f) {
            for (int i = 0; i < 8; i++) c[i] = 0.0f;
            c[3] = 1.0f;
            return;
        }
        const float S45 = 0.70710678118654752f;
        const float2 cs[8] = { float2(1, 0), float2(-S45, -S45), float2(0, 1), float2(S45, -S45),
                               float2(-1, 0), float2(S45, S45), float2(0, -1), float2(-S45, S45) };
        float y0 = -(x + 3.0f) * M_PI_4_F;
        float s0 = sin(y0), c0 = cos(y0), sum = 0.0f;
        for (int i = 0; i < 8; i++) {
            float y = -(x + 3.0f - float(i)) * M_PI_4_F;
            c[i] = (cs[i].x * s0 + cs[i].y * c0) / (y * y);
            sum += c[i];
        }
        float k = 1.0f / sum;
        for (int i = 0; i < 8; i++) c[i] *= k;
    }

    kernel void sq_gyro_warp(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             const device float4 *map [[buffer(0)]],
                             constant WarpParams &p [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.dstSize.x || gid.y >= p.dstSize.y) return;
        float2 m = (float2(gid) + 0.5f) * float2(p.mapSize) / float2(p.dstSize) - 0.5f;
        int2 i0 = clamp(int2(floor(m)), int2(0), max(int2(p.mapSize) - 2, int2(0)));
        int2 i1 = min(i0 + 1, int2(p.mapSize) - 1);
        float2 t = m - float2(i0);
        uint w = p.mapSize.x;
        float4 a = map[i0.y * w + i0.x], b = map[i0.y * w + i1.x], c = map[i1.y * w + i0.x], d = map[i1.y * w + i1.x];
        if (min(min(a.z, b.z), min(c.z, d.z)) < 0.5f) { dst.write(p.background, gid); return; }
        float2 s = mix(mix(a.xy, b.xy, t.x), mix(c.xy, d.xy, t.x), t.y);
        float2 uv = s * float2(p.srcSize) - 3.0f;
        int2 q = int2(round(uv * 32.0f));
        int2 base = q >> 5;
        float2 f = float2(q & 31) / 32.0f;
        float cx[8], cy[8];
        lanczos4(f.x, cx);
        lanczos4(f.y, cy);
        int2 size = int2(p.srcSize);
        float4 sum = float4(0.0f);
        for (int yp = 0; yp < 8; yp++) {
            int sy = base.y + yp;
            if (sy < 0 || sy >= size.y) { sum += p.background * cy[yp]; continue; }
            float4 row = float4(0.0f);
            for (int xp = 0; xp < 8; xp++) {
                int sx = base.x + xp;
                float4 px = (sx >= 0 && sx < size.x) ? src.read(uint2(sx, sy)) : p.background;
                row += px * cx[xp];
            }
            sum += row * cy[yp];
        }
        dst.write(clamp(sum, 0.0f, 1.0f), gid);
    }
    """
}
