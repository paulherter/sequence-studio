import CoreGraphics
import CoreVideo
import Foundation
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
import SQPlayback
@testable import SQExport

// W9.2 end to end: a transparent ProRes 4444 clip (straight alpha) and an HEVC-with-alpha clip (premultiplied) decode
// through DecoderFrameProvider and composite over a lower track in the export render, linear over, no fringes.

private func pixel(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> [Int] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return [Int(p[2]), Int(p[1]), Int(p[0])]   // r, g, b
}

private func lin(_ e: Double) -> Double { e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45) }
private func oetf(_ l: Double) -> Double { l < 0.018053968510807 ? 4.5 * l : 1.09929682680944 * pow(l, 0.45) - 0.09929682680944 }

private func blueStill() throws -> StillFrame {
    let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    return StillFrame(buffer: try StillImage.pixelBuffer(from: ctx.makeImage()!), info: StillImage.trackInfo(width: 64, height: 32))
}

private func exportFrame(_ codec: TestClipSpec.Codec) async throws -> CVPixelBuffer {
    var spec = TestClipSpec(); spec.codec = codec; spec.width = 64; spec.height = 32; spec.frameCount = 4
    let url = try await TestClipWriter.write(spec)
    let (still, alpha) = (UUID(), UUID())
    let provider = DecoderFrameProvider(resolver: StaticMediaResolver(demuxers: [alpha: try await AVDemuxer(url: url)],
                                                                      stills: [still: try blueStill()]))
    let fd = Time(1, 30)
    let lower = Clip(name: "bg", media: still, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 30)), start: .zero, isStill: true)
    let upper = Clip(name: "fg", media: alpha, kind: .video, source: TimeRange(start: .zero, duration: Time(4, 30)), start: .zero)
    let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 32, frameDuration: fd),
                      tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])])
    let src = try TimelineFrameSource(timeline: tl, provider: provider, width: 64, height: 32, frameDuration: fd, frameCount: 4)
    return try await src.frame(at: 1)
}

/// Expected 8-bit R'G'B' of the pattern color at `alpha` over pure blue, composited in linear light.
private func expectedOverBlue(_ alpha: Double) -> [Int] {
    let fg = [AlphaTestPattern.color.r, AlphaTestPattern.color.g, AlphaTestPattern.color.b].map { lin(Double($0) / 255) }
    let bg = [0.0, 0, 1]
    return (0..<3).map { Int((oetf(fg[$0] * alpha + bg[$0] * (1 - alpha)) * 255).rounded()) }
}

private func close(_ a: [Int], _ e: [Int], _ tol: Int, _ note: String) {
    for i in 0..<3 { #expect(abs(a[i] - e[i]) <= tol, "\(note) ch\(i): got \(a) want \(e)") }
}

@Suite(.serialized) struct AlphaVideoExportTests {
    @Test func proResAlphaClipCompositesOverLowerTrack() async throws {
        let pb = try await exportFrame(.prores4444Alpha)
        close(pixel(pb, 12, 16), expectedOverBlue(1), 4, "opaque")
        close(pixel(pb, 40, 16), expectedOverBlue(128.0 / 255), 4, "half")
        close(pixel(pb, 58, 16), expectedOverBlue(0), 3, "transparent")
    }

    @Test func hevcAlphaClipCompositesOverLowerTrack() async throws {
        let pb: CVPixelBuffer
        do { pb = try await exportFrame(.hevcAlpha) } catch TestClipError.encoderUnavailable { return }
        close(pixel(pb, 12, 16), expectedOverBlue(1), 6, "opaque")
        close(pixel(pb, 40, 16), expectedOverBlue(128.0 / 255), 6, "half")
        close(pixel(pb, 58, 16), expectedOverBlue(0), 4, "transparent")
    }
}
