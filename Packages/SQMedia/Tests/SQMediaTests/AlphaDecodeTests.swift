import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SQCore
import SQMediaTestSupport
import Testing
@testable import SQMedia

// W9.2: transparent video (ProRes 4444 with alpha, HEVC with alpha) decodes with its alpha channel into packed
// 'y416' (A, Y', Cb, Cr, 16 bit) and every frame carries its alpha mode as a CVBuffer attachment.

private func decoder(_ codec: TestClipSpec.Codec, frames: Int = 3, width: Int = 64) async throws -> VTVideoDecoder {
    var spec = TestClipSpec(); spec.codec = codec; spec.width = width; spec.height = 32; spec.frameCount = frames
    let url = try await TestClipWriter.write(spec)
    return try VTVideoDecoder(demuxer: try await AVDemuxer(url: url), media: UUID())
}

/// (A, Y', Cb, Cr) 16-bit codes of pixel (x, y) of a y416 buffer.
private func ayuv(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let p = (CVPixelBufferGetBaseAddress(pb)! + y * CVPixelBufferGetBytesPerRow(pb)).assumingMemoryBound(to: UInt16.self)
    return (0..<4).map { Int(p[x * 4 + $0]) }
}

private func alphaMode(_ pb: CVPixelBuffer) -> String? {
    CVBufferCopyAttachment(pb, kCVImageBufferAlphaChannelModeKey, nil) as? String
}

@Test func proResAlphaDecodesWithStraightAlpha() async throws {
    let dec = try await decoder(.prores4444Alpha)
    #expect(dec.alpha == .straight)
    let frames = try await dec.decode(0...2)
    #expect(frames.count == 3)
    let pb = frames[0].pixelBuffer
    #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_4444AYpCbCr16)
    #expect(alphaMode(pb) == (kCVImageBufferAlphaChannelMode_StraightAlpha as String))
    // Alpha by column: opaque, half, transparent (alpha is full range 16 bit).
    #expect(abs(ayuv(pb, 8, 16)[0] - 65535) <= 256)
    #expect(abs(ayuv(pb, 40, 16)[0] - 128 * 257) <= 512)
    #expect(ayuv(pb, 60, 16)[0] <= 256)
    // Straight: the half-transparent column keeps the full color (same luma as the opaque one).
    #expect(abs(ayuv(pb, 40, 16)[1] - ayuv(pb, 8, 16)[1]) <= 512)
}

@Test func hevcAlphaDecodesWithPremultipliedAlpha() async throws {
    let dec: VTVideoDecoder
    do { dec = try await decoder(.hevcAlpha) } catch TestClipError.encoderUnavailable { return }
    #expect(dec.alpha == .premultiplied)
    let frames = try await dec.decode(0...2)
    let pb = frames[0].pixelBuffer
    #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_4444AYpCbCr16)
    #expect(alphaMode(pb) == (kCVImageBufferAlphaChannelMode_PremultipliedAlpha as String))
    #expect(abs(ayuv(pb, 8, 16)[0] - 65535) <= 512)
    #expect(abs(ayuv(pb, 40, 16)[0] - 128 * 257) <= 1024)
    #expect(ayuv(pb, 60, 16)[0] <= 512)
    // Premultiplied: luma above black (4096) halves in the half-transparent column.
    let yOpaque = Double(ayuv(pb, 8, 16)[1] - 4096), yHalf = Double(ayuv(pb, 40, 16)[1] - 4096)
    #expect(abs(yHalf / yOpaque - 0.5) < 0.05)
}

/// FB-D: a PNG-in-MOV ('png ') transparent animation has no VideoToolbox decoder (it used to show as the amber damaged
/// placeholder); ImageIO decodes it into premultiplied BGRA with its alpha.
@Test func pngMovDecodesWithAlpha() async throws {
    let url = try await PNGMovWriter.write(width: 64, height: 32, frames: 3)
    let demux = try await AVDemuxer(url: url)
    #expect(throws: MediaError.self) { _ = try VTVideoDecoder(demuxer: demux, media: UUID()) }
    let dec = try makeVideoDecoder(demuxer: demux, media: UUID())
    #expect(dec is ImageSampleDecoder)
    let frames = try await dec.decode(0...2)
    #expect(frames.count == 3)
    #expect(frames[1].pts == demux.index.entries[1].pts)
    let pb = frames[0].pixelBuffer
    #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA)
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
    func px(_ x: Int) -> [Int] { (0..<4).map { Int(base.load(fromByteOffset: 16 * stride + x * 4 + $0, as: UInt8.self)) } }
    let c = AlphaTestPattern.color
    #expect(px(8) == [Int(c.b), Int(c.g), Int(c.r), 255])
    let half = px(40)   // premultiplied by alpha 128/255
    #expect(abs(half[3] - 128) <= 1)
    #expect(abs(half[2] - Int(c.r) * 128 / 255) <= 2 && abs(half[0] - Int(c.b) * 128 / 255) <= 2)
    #expect(px(60) == [0, 0, 0, 0])
}

@Test func opaqueStreamsKeepBiPlanarDecode() async throws {
    let dec = try await decoder(.h264, frames: 2, width: FrameStamp.minimumWidth)
    #expect(dec.alpha == nil)
    let frames = try await dec.decode(0...1)
    #expect(CVPixelBufferGetPixelFormatType(frames[0].pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    #expect(alphaMode(frames[0].pixelBuffer) == nil)
}

@Test func alphaModeDetectionFromFormatDescription() throws {
    func fd(_ codec: CMVideoCodecType, _ ext: [CFString: Any]) throws -> CMFormatDescription {
        var out: CMFormatDescription?
        let st = CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: 16, height: 16,
                                                extensions: ext as CFDictionary, formatDescriptionOut: &out)
        #expect(st == noErr)
        return out!
    }
    let ap4h = kCMVideoCodecType_AppleProRes4444
    // Tag wins.
    #expect(DecodePixelFormat.alphaChannel(of: try fd(ap4h, [kCMFormatDescriptionExtension_Depth: 32,
        kCMFormatDescriptionExtension_AlphaChannelMode: kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha])) == .premultiplied)
    // ProRes 4444 flagged alpha without a mode tag: straight (SMPTE RDD 36, what FFmpeg and Premiere assume).
    #expect(DecodePixelFormat.alphaChannel(of: try fd(ap4h, [kCMFormatDescriptionExtension_Depth: 32,
        kCMFormatDescriptionExtension_ContainsAlphaChannel: true])) == .straight)
    // Depth 32 alone (third-party ProRes 4444 with alpha, no ContainsAlphaChannel key): straight alpha.
    #expect(DecodePixelFormat.alphaChannel(of: try fd(ap4h, [kCMFormatDescriptionExtension_Depth: 32])) == .straight)
    // Depth 32 on other codecs says nothing.
    #expect(DecodePixelFormat.alphaChannel(of: try fd(kCMVideoCodecType_HEVC, [kCMFormatDescriptionExtension_Depth: 32])) == nil)
    // A mode tag alone counts as alpha.
    #expect(DecodePixelFormat.alphaChannel(of: try fd(ap4h, [
        kCMFormatDescriptionExtension_AlphaChannelMode: kCMFormatDescriptionAlphaChannelMode_StraightAlpha])) == .straight)
    // ProRes 4444 without alpha (depth 24): opaque.
    #expect(DecodePixelFormat.alphaChannel(of: try fd(ap4h, [kCMFormatDescriptionExtension_Depth: 24])) == nil)
    // HEVC flagged alpha without a mode tag: premultiplied (Apple's HEVC-with-alpha default).
    #expect(DecodePixelFormat.alphaChannel(of: try fd(kCMVideoCodecType_HEVC,
        [kCMFormatDescriptionExtension_ContainsAlphaChannel: true])) == .premultiplied)
    #expect(DecodePixelFormat.alphaChannel(of: try fd(kCMVideoCodecType_HEVC, [:])) == nil)
    #expect(DecodePixelFormat.alphaChannel(of: try fd(kCMVideoCodecType_H264, [kCMFormatDescriptionExtension_Depth: 24])) == nil)
}
