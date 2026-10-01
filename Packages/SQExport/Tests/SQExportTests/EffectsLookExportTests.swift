import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Testing
import SQCore
import SQMedia
import SQPlayback
@testable import SQExport

private let fd = Time(1, 30)

private func solidStill(_ w: Int, _ h: Int, r: Double, g: Double, b: Double) throws -> StillFrame {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return StillFrame(buffer: try StillImage.pixelBuffer(from: ctx.makeImage()!), info: StillImage.trackInfo(width: w, height: h))
}

private func exportPixel(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let p = base + y * CVPixelBufferGetBytesPerRow(pb) + x * 4
    return (Int(p[2]), Int(p[1]), Int(p[0]))
}

/// Playback's linear half-float texture (private storage: blit to a buffer first), rgba per pixel.
private func playbackPixels(_ t: MTLTexture, device: MTLDevice) -> [Float16] {
    let w = t.width, h = t.height, bpr = w * 8
    let q = device.makeCommandQueue()!, buf = device.makeBuffer(length: bpr * h, options: .storageModeShared)!
    let cb = q.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float16.self), count: w * h * 4))
}

private func oetf709(_ l: Double) -> Double {
    let l = max(0, min(1, l))
    return l < 0.018053968510807 ? 4.5 * l : 1.09929682680944 * pow(l, 0.45) - 0.09929682680944
}

@Suite(.serialized) @MainActor struct EffectsLookExportTests {
    /// V1: orange. V2: blue with Crop (left 25 %), Gaussian Blur and Multiply. The export frame and the playback frame come
    /// out of the same compositor and the same effect evaluation, so they agree to within the 8-bit encode.
    @Test func exportEqualsPlaybackWithCropBlurAndBlend() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bgMedia = UUID(), fgMedia = UUID()
        let stills = [bgMedia: try solidStill(64, 36, r: 1, g: 0.6, b: 0.3), fgMedia: try solidStill(64, 36, r: 0.4, g: 0.7, b: 1)]
        let resolver = StaticMediaResolver(stills: stills)
        let dur = TimeRange(start: .zero, duration: Time(2, 1))
        let bg = Clip(name: "bg", media: bgMedia, kind: .video, source: dur, start: .zero, isStill: true)
        var fg = Clip(name: "fg", media: fgMedia, kind: .video, source: dur, start: .zero, isStill: true)
        fg.blendMode = .multiply
        let crop = fg.addEffect(kind: ClipEffect.cropKind)!
        fg.setParameter(crop, ClipEffect.cropLeftKey, to: 25)
        let blur = fg.addEffect(kind: ClipEffect.gaussianBlurKind)!
        fg.setParameter(blur, ClipEffect.blurrinessKey, to: 2)
        let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 36, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [bg]), Track(kind: .video, clips: [fg])])

        let source = try TimelineFrameSource(timeline: tl, provider: DecoderFrameProvider(resolver: resolver),
                                             width: 64, height: 36, frameDuration: fd, frameCount: 2)
        let exported = try await source.frame(at: 0)

        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.setTimeline(tl)
        engine.seek(to: .zero)
        await engine.waitForDecodes()
        #expect(engine.tick())
        let tex = try #require(engine.lastRenderedTexture)
        let pixels = playbackPixels(tex, device: device)

        // Away from the crop edge and the picture border: multiply of both stills. Inside the cropped strip: the background.
        for (x, y) in [(48, 18), (6, 18), (40, 10)] {
            let i = (y * tex.width + x) * 4
            let lin = [Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])]
            let e = exportPixel(exported, x, y)
            let want = [oetf709(lin[0]), oetf709(lin[1]), oetf709(lin[2])].map { Int(($0 * 255).rounded()) }
            #expect(abs(e.r - want[0]) <= 3 && abs(e.g - want[1]) <= 3 && abs(e.b - want[2]) <= 3,
                    "(\(x),\(y)) export \(e) vs playback-encoded \(want)")
        }
        // And the effects are really there: the cropped strip shows the orange background, the interior is darker than it.
        let strip = exportPixel(exported, 6, 18), inner = exportPixel(exported, 48, 18)
        #expect(strip.r > 230)
        #expect(inner.r < strip.r - 60)
    }

    @Test func identityEffectsExportBitIdenticalToNoEffects() async throws {
        let media = UUID()
        let resolver = StaticMediaResolver(stills: [media: try solidStill(64, 36, r: 0.2, g: 0.5, b: 0.9)])
        let dur = TimeRange(start: .zero, duration: Time(2, 1))
        var clip = Clip(name: "c", media: media, kind: .video, source: dur, start: .zero, isStill: true)
        func frame(_ c: Clip) async throws -> [UInt8] {
            let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 36, frameDuration: fd),
                              tracks: [Track(kind: .video, clips: [c])])
            let s = try TimelineFrameSource(timeline: tl, provider: DecoderFrameProvider(resolver: resolver),
                                            width: 64, height: 36, frameDuration: fd, frameCount: 1)
            let pb = try await s.frame(at: 0)
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: base, count: CVPixelBufferGetBytesPerRow(pb) * 36))
        }
        let plain = try await frame(clip)
        _ = clip.addEffect(kind: ClipEffect.cropKind)
        _ = clip.addEffect(kind: ClipEffect.gaussianBlurKind)
        clip.blendMode = .normal
        #expect(try await frame(clip) == plain)
    }
}
