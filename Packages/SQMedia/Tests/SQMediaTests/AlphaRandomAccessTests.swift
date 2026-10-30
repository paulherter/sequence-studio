import CoreGraphics
import CoreMedia
import ImageIO
import CoreVideo
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

// FB-L: transparent MOV performance. QuickTime Animation tracks often have one key frame for the whole clip; the
// engine plans whole GOPs, so the demuxer exposes every rle frame as random access (the decoder restores from its
// canvas, a checkpoint or the true key itself). PNG decodes ahead in parallel and must hand out the right frame.

private let w = 48, h = 24

/// Straight RGBA frames: a semi-transparent background, then a moving 6 x 4 box per frame (delta frames change little).
private func movingBox(_ n: Int) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var f = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w { let o = (y * w + x) * 4; f[o] = 20; f[o + 1] = 40; f[o + 2] = 200; f[o + 3] = x < w / 2 ? 128 : 255 } }
    for i in 0..<n {
        let x0 = (i * 3) % (w - 6), y0 = (i * 2) % (h - 4)
        for y in y0..<(y0 + 4) { for x in x0..<(x0 + 6) {
            let o = (y * w + x) * 4; f[o] = UInt8(i * 5 % 256); f[o + 1] = 255; f[o + 2] = UInt8(255 - i); f[o + 3] = 255
        } }
        out.append(f)
    }
    return out
}

private func bytes(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pb)
    var out: [UInt8] = []
    for y in 0..<CVPixelBufferGetHeight(pb) { out += UnsafeBufferPointer(start: base + y * stride, count: CVPixelBufferGetWidth(pb) * 4) }
    return out
}

/// Wraps a demuxer but hands out the true (coded) sync flags as `index`, and samples from the true key frame:
/// the decoder must not rely on the random-access view (other demuxers, test fakes).
private struct CodedDemuxer: Demuxing {
    let base: AVDemuxer
    var index: SampleIndex { base.codedIndex }
    var formatDescription: CMFormatDescription { base.formatDescription }
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] {
        let key = index.entries[range.lowerBound].isSync ? range.lowerBound : index.previousSync(before: range.lowerBound)
        return try await base.samples(for: key...range.upperBound)
    }
}

@Test func rleDemuxerExposesEveryFrameAsRandomAccess() async throws {
    let url = try await RLEMovWriter.write(frames: movingBox(30), width: w, height: h)
    let demux = try await AVDemuxer(url: url)
    #expect(demux.index.entries.allSatisfy { $0.isSync })
    #expect(demux.index.gop(containing: 20) == 20...20)
    #expect(demux.codedIndex.entries[0].isSync)
    #expect(demux.codedIndex.entries.dropFirst().allSatisfy { !$0.isSync })
    let samples = try await demux.samples(for: 20...22)
    #expect(samples.count == 3)
}

@Test(arguments: [Int.max, 12])
func rleRandomAccessMatchesSequentialDecode(keyEvery: Int) async throws {
    let fr = movingBox(60)
    let url = try await RLEMovWriter.write(frames: fr, width: w, height: h, keyEvery: keyEvery)
    let demux = try await AVDemuxer(url: url)
    let reference = try await RLEDecoder(demuxer: demux, media: UUID()).decode(0...59).map { bytes($0.pixelBuffer) }
    #expect(reference.count == 60)
    let order = [45, 3, 59, 58, 57, 20, 21, 22, 10, 0, 33, 31, 59, 1, 40, 39, 38, 12, 11, 50]
    for demuxer in [demux as any Demuxing, CodedDemuxer(base: demux)] {
        let dec = try RLEDecoder(demuxer: demuxer, media: UUID())
        for (k, i) in order.enumerated() {
            if k == 9 { dec.invalidate() }
            let out = try await dec.decode(i...i)
            #expect(out.count == 1 && out[0].pts == demux.index.entries[i].pts)
            #expect(bytes(out[0].pixelBuffer) == reference[i], "frame \(i) (\(type(of: demuxer)))")
        }
        let run = try await dec.decode(27...30)
        #expect(run.map { bytes($0.pixelBuffer) } == Array(reference[27...30]))
    }
}

@Test func makeVideoDecoderAlwaysUsesTheRLEDecoder() async throws {
    let url = try await RLEMovWriter.write(frames: movingBox(3), width: w, height: h)
    let demux = try await AVDemuxer(url: url)
    let dec = try makeVideoDecoder(demuxer: demux, media: UUID())
    #expect(dec is RLEDecoder)
}

@Test func pngDecodeAheadHandsOutTheRequestedFrames() async throws {
    let url = try await PNGMovWriter.write(width: 64, height: 32, frames: 40)
    let demux = try await AVDemuxer(url: url)
    let dec = try ImageSampleDecoder(demuxer: demux, media: UUID())
    let reference = bytes(try await ImageSampleDecoder(demuxer: demux, media: UUID()).decode(0...0)[0].pixelBuffer)
    // Forward play, a drag at 3 frames per move, backwards, random jumps.
    let order = Array(0..<12) + Array(stride(from: 12, to: 39, by: 3)) + Array((20...30).reversed()) + [5, 37, 2, 39]
    for i in order {
        let out = try await dec.decode(i...i)
        #expect(out.count == 1 && out[0].pts == demux.index.entries[i].pts, "frame \(i)")
        #expect(bytes(out[0].pixelBuffer) == reference)
    }
    let run = try await dec.decode(4...9)
    #expect(run.map(\.pts) == (4...9).map { demux.index.entries[$0].pts })
}

/// The own PNG decoder (8-bit RGBA) matches ImageIO + CGContext on a picture that uses every filter type.
@Test func pngFastDecoderMatchesImageIO() throws {
    let w = 97, h = 61
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    var s: UInt32 = 1
    for y in 0..<h { for x in 0..<w {
        let o = (y * w + x) * 4
        s = s &* 1_664_525 &+ 1_013_904_223
        let noise = UInt8(truncatingIfNeeded: s >> 24)
        rgba[o] = y < 20 ? UInt8(x * 2) : noise
        rgba[o + 1] = UInt8((x + y) % 256)
        rgba[o + 2] = x < 50 ? 200 : noise / 2
        rgba[o + 3] = x % 3 == 0 ? 255 : (y % 4 == 0 ? 0 : UInt8(40 + x))
    } }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let png = NSMutableData()
    let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    let src = CGImageSourceCreateWithData(png as CFData, nil)!
    let reference = bytes(try StillImage.pixelBuffer(from: CGImageSourceCreateImageAtIndex(src, 0, nil)!))
    var mine = [UInt8](repeating: 0, count: w * h * 4)
    let ok = (png as Data).withUnsafeBytes { p in mine.withUnsafeMutableBytes { PNGFastDecoder.decode(p, width: w, height: h, into: $0.baseAddress!, rowBytes: w * 4) } }
    #expect(ok)
    let worst = zip(mine, reference).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(worst <= 1, "max channel difference \(worst)")
    // Wrong size or a 16-bit / gray picture is left to ImageIO.
    #expect(!(png as Data).withUnsafeBytes { p in mine.withUnsafeMutableBytes { PNGFastDecoder.decode(p, width: w + 1, height: h, into: $0.baseAddress!, rowBytes: w * 4) } })
}

/// 8-bit RGBA PNG of a small gradient in `space` (ImageIO embeds the profile).
private func encodedPNG(w: Int, h: Int, space: CGColorSpace) -> Data {
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w { let o = (y * w + x) * 4; rgba[o] = UInt8(x * 4); rgba[o + 1] = UInt8(y * 4); rgba[o + 2] = 90; rgba[o + 3] = 200 } }
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: CGDataProvider(data: Data(rgba) as CFData)!,
                        decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let png = NSMutableData()
    let dest = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    _ = CGImageDestinationFinalize(dest)
    return png as Data
}

/// `png` with a chunk inserted right after IHDR (CRC left zero: the own decoder does not check it).
private func inserting(_ type: String, _ body: [UInt8], into png: Data) -> Data {
    let n = body.count
    var chunk = Data([UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)])
    chunk += Data(type.utf8) + body + [0, 0, 0, 0]
    var out = png
    out.insert(contentsOf: chunk, at: 8 + 25)
    return out
}

private func fastDecodes(_ png: Data, w: Int, h: Int) -> Bool {
    var mine = [UInt8](repeating: 0, count: w * h * 4)
    return png.withUnsafeBytes { p in mine.withUnsafeMutableBytes { PNGFastDecoder.decode(p, width: w, height: h, into: $0.baseAddress!, rowBytes: w * 4) } }
}

/// Review FB-L: a gAMA chunk other than the sRGB value without an sRGB chunk needs ImageIO's color handling.
@Test func pngFastDecoderLeavesNonSRGBGammaToImageIO() throws {
    let png = encodedPNG(w: 16, h: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!)
    // The plain encode may already carry sRGB / iCCP chunks: strip to a bare IHDR + IDAT + IEND for a clean baseline.
    let bare = strippedPNG(png)
    #expect(fastDecodes(bare, w: 16, h: 8))
    func gama(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    #expect(!fastDecodes(inserting("gAMA", gama(100_000), into: bare), w: 16, h: 8))
    #expect(fastDecodes(inserting("gAMA", gama(45_455), into: bare), w: 16, h: 8))
    #expect(fastDecodes(inserting("sRGB", [0], into: inserting("gAMA", gama(100_000), into: bare)), w: 16, h: 8))
}

/// IHDR, IDAT and IEND only.
private func strippedPNG(_ png: Data) -> Data {
    let b = [UInt8](png)
    var out = Data(b[0..<8]), p = 8
    while p + 8 <= b.count {
        let n = Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        let type = String(decoding: b[(p + 4)..<(p + 8)], as: UTF8.self)
        if ["IHDR", "IDAT", "IEND"].contains(type) { out += b[p..<(p + 12 + n)] }
        p += 12 + n
    }
    return out
}

/// Review FB-L: ImageIO's byte fast path is sRGB only; a color-managed PNG (Adobe RGB profile) goes to the
/// converting CGContext path.
@Test func imageFastPathRejectsColourManagedPictures() throws {
    let pool = BGRAPool(width: 16, height: 8)
    func decoded(_ png: Data) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
    }
    let adobe = decoded(encodedPNG(w: 16, h: 8, space: CGColorSpace(name: CGColorSpace.adobeRGB1998)!))
    #expect(try ImageSampleDecoder.fastPath(adobe, pool: pool) == nil)
    let srgb = decoded(encodedPNG(w: 16, h: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!))
    #expect(try ImageSampleDecoder.fastPath(srgb, pool: pool) != nil)
}

/// Review FB-L: Lanczos on premultiplied data rings; the scaled picture must stay premultiplied (color <= alpha).
@Test(arguments: [DecodeScale.half, .quarter])
func scaledBufferKeepsColourWithinAlpha(scale: DecodeScale) throws {
    let w = 64, h = 16
    let pb = try BGRABuffer.make(width: w, height: h)
    CVPixelBufferLockBaseAddress(pb, [])
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(pb)
    // Stripes of opaque black and half-transparent white (premultiplied 128 / 128): color - alpha steps from -255 to 0.
    for y in 0..<h { for x in 0..<w {
        let o = base + y * rb + x * 4
        if x % 6 < 3 { o[0] = 0; o[1] = 0; o[2] = 0; o[3] = 255 } else { o[0] = 128; o[1] = 128; o[2] = 128; o[3] = 128 }
    } }
    CVPixelBufferUnlockBaseAddress(pb, [])
    let out = bytes(try BGRABuffer.scaled(pb, by: scale))
    var bad = 0
    for i in stride(from: 0, to: out.count, by: 4) where max(out[i], out[i + 1], out[i + 2]) > out[i + 3] { bad += 1 }
    #expect(bad == 0)
}

/// Fake rle stream that starts on a delta frame (truncated file): the base clip without its key frame, every frame
/// coded as non-sync.
private struct HeadlessDemuxer: Demuxing {
    let base: AVDemuxer
    let index: SampleIndex
    init(base: AVDemuxer) {
        self.base = base
        index = SampleIndex(entries: base.codedIndex.entries.dropFirst().map {
            var e = $0; e.isSync = false; e.decodeOrdinal -= 1; return e
        })
    }
    var formatDescription: CMFormatDescription { base.formatDescription }
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] {
        try await base.samples(for: (range.lowerBound + 1)...(range.upperBound + 1))
    }
}

/// Review FB-L: without any sync frame before the target the decoder starts from a blank canvas, not from whatever
/// the canvas held.
@Test func rleWithoutKeyFrameStartsFromBlankCanvas() async throws {
    let url = try await RLEMovWriter.write(frames: movingBox(30), width: w, height: h)
    let demux = HeadlessDemuxer(base: try await AVDemuxer(url: url))
    let reference = bytes(try await RLEDecoder(demuxer: demux, media: UUID()).decode(3...3)[0].pixelBuffer)
    let dec = try RLEDecoder(demuxer: demux, media: UUID())
    _ = try await dec.decode(20...20)
    dec.invalidate()
    #expect(bytes(try await dec.decode(3...3)[0].pixelBuffer) == reference)
}

/// Review FB-L: decoders of the same media share one checkpoint store (one background pass, one budget).
@Test func rleDecodersOfOneMediaShareCheckpoints() async throws {
    let fr = movingBox(60)
    let url = try await RLEMovWriter.write(frames: fr, width: w, height: h)
    let demux = try await AVDemuxer(url: url)
    let media = UUID()
    let a = try RLEDecoder(demuxer: demux, media: media), b = try RLEDecoder(demuxer: demux, media: media, scale: .half)
    let c = try RLEDecoder(demuxer: demux, media: UUID())
    #expect(a.checkpoints === b.checkpoints)
    #expect(a.checkpoints !== c.checkpoints)
    let reference = try await c.decode(0...59).map { bytes($0.pixelBuffer) }
    for i in [50, 7, 33] { #expect(bytes(try await a.decode(i...i)[0].pixelBuffer) == reference[i]) }
}
