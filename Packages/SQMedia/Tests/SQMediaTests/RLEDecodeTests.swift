import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

// FB-D2: QuickTime Animation ('rle ') transparent MOV decodes with alpha, delta frames included.

private let w = 64, h = 32

/// Straight RGBA test frames: (0) opaque red | half-transparent green | transparent | blue;
/// (1) delta: a 10 x 4 box turned white; (2) delta: another box on top of that.
private func frames() -> [[UInt8]] {
    var f0 = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let o = (y * w + x) * 4
        let c: [UInt8] = x < 16 ? [255, 0, 0, 255] : x < 32 ? [0, 255, 0, 132] : x < 48 ? [0, 0, 0, 0] : [0, 0, 255, 255]
        f0[o] = c[0]; f0[o + 1] = c[1]; f0[o + 2] = c[2]; f0[o + 3] = c[3]
    } }
    func box(_ f: [UInt8], x0: Int, y0: Int, bw: Int, bh: Int, _ c: [UInt8]) -> [UInt8] {
        var f = f
        for y in y0..<(y0 + bh) { for x in x0..<(x0 + bw) { let o = (y * w + x) * 4; for k in 0..<4 { f[o + k] = c[k] } } }
        return f
    }
    let f1 = box(f0, x0: 10, y0: 4, bw: 10, bh: 4, [255, 255, 255, 255])
    let f2 = box(f1, x0: 40, y0: 20, bw: 5, bh: 3, [0, 255, 255, 255])
    return [f0, f1, f2]
}

private func bgra(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pb)! + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return (0..<4).map { Int(p.load(fromByteOffset: $0, as: UInt8.self)) }
}

private func check(_ pb: CVPixelBuffer, _ expected: [UInt8]) {
    for (x, y) in [(2, 2), (12, 5), (25, 10), (40, 10), (60, 10), (42, 21), (50, 30)] {
        let o = (y * w + x) * 4
        let e = (0..<4).map { Int(expected[o + $0]) }
        let a = e[3]
        let want = [e[2] * a / 255, e[1] * a / 255, e[0] * a / 255, a]
        let got = bgra(pb, x, y)
        #expect(zip(got, want).allSatisfy { abs($0 - $1) <= 2 }, "pixel \(x),\(y): \(got) vs \(want)")
    }
}

@Test func rleMovDecodesKeyAndDeltaFrames() async throws {
    let fr = frames()
    let url = try await RLEMovWriter.write(frames: fr, width: w, height: h)
    let demux = try await AVDemuxer(url: url)
    let dec = try RLEDecoder(demuxer: demux, media: UUID())
    let out = try await dec.decode(0...2)
    #expect(out.count == 3)
    #expect(CVPixelBufferGetPixelFormatType(out[0].pixelBuffer) == kCVPixelFormatType_32BGRA)
    for i in 0..<3 { check(out[i].pixelBuffer, fr[i]) }
    #expect(out[2].pts == demux.index.entries[2].pts)
    // Seek to the last frame from scratch, then back to the first (restarts at the key frame).
    dec.invalidate()
    check(try await dec.decode(2...2)[0].pixelBuffer, fr[2])
    check(try await dec.decode(0...0)[0].pixelBuffer, fr[0])
    // Forward continuation: frame 1 then 2 one call each.
    check(try await dec.decode(1...1)[0].pixelBuffer, fr[1])
    check(try await dec.decode(2...2)[0].pixelBuffer, fr[2])
}

@Test func rle24And16BitDecode() async throws {
    let fr = frames().map { f -> [UInt8] in   // opaque, 5-bit-exact colors only (0 / 255)
        var f = f; for i in stride(from: 0, to: f.count, by: 4) { f[i + 3] = 255 }
        return f
    }
    for depth in [24, 16] {
        let url = try await RLEMovWriter.write(frames: fr, width: w, height: h, depth: depth)
        let dec = try RLEDecoder(demuxer: try await AVDemuxer(url: url), media: UUID())
        let out = try await dec.decode(0...2)
        for i in 0..<3 { check(out[i].pixelBuffer, fr[i]) }
    }
}

@Test func rleHalfScaleHalvesTheBuffer() async throws {
    let url = try await RLEMovWriter.write(frames: frames(), width: w, height: h)
    let dec = try RLEDecoder(demuxer: try await AVDemuxer(url: url), media: UUID(), scale: .half)
    let pb = try await dec.decode(0...0)[0].pixelBuffer
    #expect(CVPixelBufferGetWidth(pb) == w / 2 && CVPixelBufferGetHeight(pb) == h / 2)
    #expect(bgra(pb, 3, 3) == [0, 0, 255, 255])   // inside the opaque red column
}

@Test func pngMovQuarterScaleShrinksTheBuffer() async throws {
    let url = try await PNGMovWriter.write(width: 64, height: 32, frames: 2)
    let dec = try makeVideoDecoder(demuxer: try await AVDemuxer(url: url), media: UUID(), scale: .quarter)
    let pb = try await dec.decode(0...1)[1].pixelBuffer
    #expect(CVPixelBufferGetWidth(pb) == 16 && CVPixelBufferGetHeight(pb) == 8)
}

@Test func makeVideoDecoderPicksTheRLEPath() async throws {
    let fr = frames()
    let url = try await RLEMovWriter.write(frames: fr, width: w, height: h)
    let dec = try makeVideoDecoder(demuxer: try await AVDemuxer(url: url), media: UUID())
    // VideoToolbox first; where it cannot decode 'rle ' the own decoder takes over.
    #expect(dec is RLEDecoder || dec is VTVideoDecoder)
    let out = try await dec.decode(0...2)
    #expect(out.count == 3)
    if dec is RLEDecoder { check(out[2].pixelBuffer, fr[2]) }
}
