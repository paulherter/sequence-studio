import CoreGraphics
import CoreVideo
import Foundation
import Testing
import SQCore
import SQMedia
import SQPlayback
@testable import SQExport

private func pixel(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let p = base + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return (Int(p[0]), Int(p[1]), Int(p[2]))
}

/// Solid frame whose track info carries a rotation (like a phone clip).
private struct RotatedProvider: FrameProvider {
    var rotation: Int
    func frame(media: UUID, at sourceTime: Time) async throws -> ProvidedFrame? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, 128, 64, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<64 { for x in 0..<128 {
            let p = base + y * CVPixelBufferGetBytesPerRow(buf) + x * 4
            p[0] = 0; p[1] = 255; p[2] = 0; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return ProvidedFrame(buffer: buf, info: VideoTrackInfo(width: 128, height: 64, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                                                               nominalFrameDuration: Time(1, 30), isVariableFrameRate: false,
                                                               rotation: rotation))
    }
}

@Suite struct StillAndRotationExportTests {
    @Test func rotatedClipFillsPortraitCanvas() async throws {
        let media = UUID()
        let clip = Clip(name: "p", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 128, frameDuration: Time(1, 30)),
                          tracks: [Track(kind: .video, clips: [clip])])
        let rotated = try TimelineFrameSource(timeline: tl, provider: RotatedProvider(rotation: 90), width: 64, height: 128,
                                              frameDuration: Time(1, 30), frameCount: 2)
        let pb = try await rotated.frame(at: 0)
        #expect(pixel(pb, 32, 4).g > 250 && pixel(pb, 32, 124).g > 250)        // upright 64x128 fills the canvas
        let flat = try TimelineFrameSource(timeline: tl, provider: RotatedProvider(rotation: 0), width: 64, height: 128,
                                           frameDuration: Time(1, 30), frameCount: 2)
        let pb0 = try await flat.frame(at: 0)
        #expect(pixel(pb0, 32, 4).g < 5 && pixel(pb0, 32, 64).g > 250)        // unrotated: letterboxed
    }

    @Test func stillImageExports() async throws {
        let ctx = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        let frame = StillFrame(buffer: try StillImage.pixelBuffer(from: ctx.makeImage()!), info: StillImage.trackInfo(width: 64, height: 36))
        let media = UUID()
        let provider = DecoderFrameProvider(resolver: StaticMediaResolver(stills: [media: frame]))
        let clip = Clip(name: "s", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(5, 1)), start: .zero, isStill: true)
        let tl = Timeline(name: "t", format: SequenceFormat(width: 128, height: 72, frameDuration: Time(1, 30)),
                          tracks: [Track(kind: .video, clips: [clip])])
        let src = try TimelineFrameSource(timeline: tl, provider: provider, width: 128, height: 72, frameDuration: Time(1, 30), frameCount: 3)
        let pb = try await src.frame(at: 1)
        let c = pixel(pb, 64, 36)
        #expect(c.b > 250 && c.r < 5 && c.g < 5)
    }
}
