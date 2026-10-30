import CoreVideo
import Foundation
import SQMediaTestSupport
import Testing
@testable import SQAnalysis

// Gyroflow GPU warp (DECISIONS "Gyroflow warp on the GPU"): libsqgyro warps three small probe planes (x ramp, y ramp,
// coverage) into a coarse map of where every output pixel samples the source; a Metal pass then resamples the full
// frame with it. These tests need no gyro library: they drive the map decode and the Metal pass with synthetic maps.

private func plane(_ pb: CVPixelBuffer, _ i: Int) -> [Int] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let planar = CVPixelBufferIsPlanar(pb)
    let h = planar ? CVPixelBufferGetHeightOfPlane(pb, i) : CVPixelBufferGetHeight(pb)
    let w = planar ? CVPixelBufferGetWidthOfPlane(pb, i) : CVPixelBufferGetWidth(pb)
    let bpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, i) : CVPixelBufferGetBytesPerRow(pb)
    let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(pb, i) : CVPixelBufferGetBaseAddress(pb))!
    let fmt = CVPixelBufferGetPixelFormatType(pb)
    let wide = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    let channels = !planar ? 4 : (i == 0 ? 1 : 2)
    var out: [Int] = []
    for y in 0..<h {
        for x in 0..<(w * channels) {
            if wide { out.append(Int((base + y * bpr).assumingMemoryBound(to: UInt16.self)[x])) }
            else { out.append(Int((base + y * bpr).assumingMemoryBound(to: UInt8.self)[x])) }
        }
    }
    return out
}

private func blank(like pb: CVPixelBuffer) -> CVPixelBuffer {
    var out: CVPixelBuffer?
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
    CVPixelBufferCreate(nil, CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), CVPixelBufferGetPixelFormatType(pb), attrs as CFDictionary, &out)
    return out!
}

/// A map from a closure: output pixel center (normalized) -> source position (normalized, source pixel k of n at k/n),
/// nil = outside the picture. Output pixel x of a plane n wide has its center at (x + 0.5) / n.
private func map(_ w: Int, _ h: Int, _ f: (Double, Double) -> (Double, Double)?) -> GyroWarpMap {
    var t: [SIMD4<Float>] = []
    for y in 0..<h { for x in 0..<w {
        if let (u, v) = f((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h)) { t.append(SIMD4(Float(u), Float(v), 1, 0)) }
        else { t.append(.zero) }
    } }
    return GyroWarpMap(width: w, height: h, texels: t)
}

@Suite struct GyroWarpMapTests {
    @Test func mapSizeIsAQuarterOfTheFrameAndNeverTiny() {
        #expect(GyroWarpMap.size(frameWidth: 3840, frameHeight: 2160) == (960, 540))
        #expect(GyroWarpMap.size(frameWidth: 320, frameHeight: 180) == (80, 45))
        #expect(GyroWarpMap.size(frameWidth: 40, frameHeight: 20) == (16, 16))
    }

    @Test func mapLongSideStaysNear480ForLargeFrames() {
        #expect(GyroWarpMap.divisor(frameWidth: 1280, frameHeight: 720) == 4)
        #expect(GyroWarpMap.divisor(frameWidth: 1920, frameHeight: 1080) == 4)
        #expect(GyroWarpMap.divisor(frameWidth: 3840, frameHeight: 2160) == 8)
        #expect(GyroWarpMap.divisor(frameWidth: 2160, frameHeight: 3840) == 8)
        #expect(GyroWarpMap.size(frameWidth: 3840, frameHeight: 2160, divisor: 8) == (480, 270))
    }

    @Test func probePlanesPassedThroughDecodeToTheIdentity() throws {
        let gpu = try #require(GyroMetalWarp.shared)
        let (w, h) = (24, 16)
        let p = GyroWarpMap.probePlanes(width: w, height: h)
        #expect(p.xy.count == 2 * w * h && p.coverage.count == w * h)
        // The engine leaves the picture where it is: every texel samples itself.
        let m = try #require(gpu.makeMap(width: w, height: h) { xy, cov in
            p.xy.withUnsafeBytes { xy.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            p.coverage.withUnsafeBytes { cov.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            return true
        })
        let t = m.texels
        for (y, x) in [(0, 0), (3, 7), (15, 23), (8, 12)] {
            #expect(abs(Double(t[y * w + x].x) - Double(x) / Double(w)) < 1e-4)
            #expect(abs(Double(t[y * w + x].y) - Double(y) / Double(h)) < 1e-4)
            #expect(t[y * w + x].z == 1)
        }
    }

    @Test func borderTexelsSpoiledByTheProbeFilterAreRefilled() throws {
        // A shifted, scaled map whose outer 3 texels came back mixed with background (coverage below full scale,
        // ramps pulled toward 0): they are rebuilt by extrapolation and match the true map.
        let gpu = try #require(GyroMetalWarp.shared)
        let (w, h) = (40, 30)
        func truth(_ i: Int, _ j: Int) -> (Double, Double) { (0.1 + 0.8 * Double(i) / Double(w), 0.05 + 0.9 * Double(j) / Double(h)) }
        let s = Double(GyroWarpMap.encodeScale)
        let m = try #require(gpu.makeMap(width: w, height: h) { xy, cov in
            let pxy = xy.assumingMemoryBound(to: UInt16.self), pc = cov.assumingMemoryBound(to: UInt16.self)
            for j in 0..<h { for i in 0..<w {
                let border = i < 3 || j < 3 || i >= w - 3 || j >= h - 3
                let (u, v) = truth(i, j)
                // Inverse of the decode: ramp value for normalized position u is u·w/(w-1)·scale.
                pxy[2 * (j * w + i)] = border ? 100 : UInt16((u * Double(w) / Double(w - 1) * s).rounded())
                pxy[2 * (j * w + i) + 1] = border ? 100 : UInt16((v * Double(h) / Double(h - 1) * s).rounded())
                pc[j * w + i] = border ? UInt16(s * 0.7) : UInt16(s)
            } }
            return true
        })
        let t = m.texels
        for (i, j) in [(0, 0), (1, 15), (39, 29), (20, 0), (38, 2), (20, 15)] {
            let (u, v) = truth(i, j)
            #expect(t[j * w + i].z == 1, "texel \(i),\(j) refilled")
            #expect(abs(Double(t[j * w + i].x) - u) < 1e-3 && abs(Double(t[j * w + i].y) - v) < 1e-3, "texel \(i),\(j): \(t[j * w + i])")
        }
    }

    @Test func probesThatFailGiveNoMap() throws {
        let gpu = try #require(GyroMetalWarp.shared)
        #expect(gpu.makeMap(width: 16, height: 16) { _, _ in false } == nil)
    }

    @Test(arguments: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                      kCVPixelFormatType_32BGRA])
    func theIdentityMapLeavesTheFrameAsItIs(format: OSType) throws {
        let gpu = try #require(GyroMetalWarp.shared)
        let src = try #require(FrameStamp.makePixelBuffer(width: 320, height: 180, format: format, frame: 3))
        let dst = blank(like: src)
        // Luma pixel x samples luma pixel x (its center minus half a pixel); chroma, half the size, lands a quarter
        // chroma pixel off, as in gyroflow_core.
        let m = map(80, 45) { ($0 - 0.5 / 320, $1 - 0.5 / 180) }
        #expect(gpu.warp(src, into: dst, map: try #require(gpu.upload(m)), fullRange: false))
        for i in 0..<(CVPixelBufferIsPlanar(src) ? 2 : 1) {
            let a = plane(src, i), b = plane(dst, i)
            let maxDiff = zip(a, b).map { abs($0 - $1) }.max() ?? 0
            let level = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 64 : 1
            #expect(maxDiff <= (i == 0 ? 1 : 2) * level, "plane \(i) max diff \(maxDiff)")
        }
    }

    @Test func aShiftMapMovesThePictureAndFillsTheRestWithBlack() throws {
        let gpu = try #require(GyroMetalWarp.shared)
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let src = try #require(FrameStamp.makePixelBuffer(width: 320, height: 180, format: format, frame: 0))
        let dst = blank(like: src)
        // Output pixel x samples source pixel x + 16 (a whole multiple of the map step: exact); right edge outside.
        let m = map(80, 45) { u, v in u + 15.5 / 320 < 1 ? (u + 15.5 / 320, v - 0.5 / 180) : nil }
        #expect(gpu.warp(src, into: dst, map: try #require(gpu.upload(m)), fullRange: false))
        let a = plane(src, 0), b = plane(dst, 0)
        for y in [20, 90, 170] {
            for x in [0, 50, 200, 280] { #expect(abs(b[y * 320 + x] - a[y * 320 + x + 16]) <= 1, "x \(x) y \(y)") }
            #expect(b[y * 320 + 315] == 16, "outside the picture is video-range black")
        }
        let c = plane(dst, 1)
        #expect(c[90 * 160 + 2 * 158] == 128 && c[90 * 160 + 2 * 158 + 1] == 128, "outside chroma is neutral")
    }

    @Test func aHalfSizeFrameUsesTheSameMap() throws {
        // A proxy / reduced decode is warped with the same normalized map (the engine scales smaller buffers).
        let gpu = try #require(GyroMetalWarp.shared)
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let full = try #require(FrameStamp.makePixelBuffer(width: 640, height: 360, format: format, frame: 0))
        let half = try #require(FrameStamp.makePixelBuffer(width: 320, height: 180, format: format, frame: 0))
        // Exact for the full frame (x -> x + 64); the half frame lands a quarter pixel off (x -> x + 32.25).
        let m = try #require(gpu.upload(map(160, 90) { u, v in u + 0.1 < 1 ? (u + 0.1 - 0.5 / 640, v - 0.5 / 360) : nil }))
        let dFull = blank(like: full), dHalf = blank(like: half)
        #expect(gpu.warp(full, into: dFull, map: m, fullRange: false))
        #expect(gpu.warp(half, into: dHalf, map: m, fullRange: false))
        let a = plane(half, 0), b = plane(dHalf, 0), af = plane(full, 0), bf = plane(dFull, 0)
        #expect(abs(b[90 * 320 + 80] - a[90 * 320 + 112]) <= 2)
        #expect(abs(bf[180 * 640 + 160] - af[180 * 640 + 224]) <= 1)
        #expect(b[90 * 320 + 316] == 16)
    }
}
