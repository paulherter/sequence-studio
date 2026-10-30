import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Testing
import SQCore
import SQMedia
import SQPlayback
import SQRender
@testable import SQExport

private let fd = Time(1, 30)

private struct ColorStillResolver: MediaResolver {
    let base: StaticMediaResolver
    let colorResolver: LayerColorResolver?
    func demuxer(for media: UUID) throws -> any Demuxing { try base.demuxer(for: media) }
    func audio(for media: UUID) throws -> any SQMedia.AudioSource { try base.audio(for: media) }
    func stillFrame(for media: UUID) throws -> StillFrame? { try base.stillFrame(for: media) }
}

private func still(_ w: Int, _ h: Int) throws -> StillFrame {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.4, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return StillFrame(buffer: try StillImage.pixelBuffer(from: ctx.makeImage()!), info: StillImage.trackInfo(width: w, height: h))
}

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

private func linearToRec709(_ l: Double) -> Double {
    let l = max(0, min(1, l))
    return l < 0.018053968510807 ? 4.5 * l : 1.09929682680944 * pow(l, 0.45) - 0.09929682680944
}

@Suite(.serialized) @MainActor struct GradedClipExportTests {
    /// COL-42 / EXP-23: a clip with a color override renders the same in export as in the monitor, and not like the ungraded clip.
    @Test func gradedClipExportEqualsPlayback() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let media = UUID()
        let info = MediaInfo(duration: fd * 2)
        let layerResolver = LayerColorResolver(lutProvider: nil) { $0 == media ? info : nil }
        let base = StaticMediaResolver(stills: [media: try still(64, 36)])
        let resolver = ColorStillResolver(base: base, colorResolver: layerResolver)
        let dur = TimeRange(start: .zero, duration: Time(2, 1))
        let clip = Clip(name: "c", media: media, kind: .video, source: dur, start: .zero, isStill: true)
        var graded = clip
        graded.color.source = .sLog3SGamut3Cine
        func tl(_ c: Clip) -> Timeline {
            Timeline(name: "t", format: SequenceFormat(width: 64, height: 36, frameDuration: fd),
                     tracks: [Track(kind: .video, clips: [c])])
        }
        func exported(_ c: Clip) async throws -> (r: Int, g: Int, b: Int) {
            let s = try TimelineFrameSource(timeline: tl(c), provider: DecoderFrameProvider(resolver: resolver),
                                            width: 64, height: 36, frameDuration: fd, frameCount: 1,
                                            colorResolver: resolver.colorResolver)
            let pb = try await s.frame(at: 0)
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let p = b + 18 * CVPixelBufferGetBytesPerRow(pb) + 32 * 4
            return (Int(p[2]), Int(p[1]), Int(p[0]))
        }
        let plain = try await exported(clip)
        let gradedOut = try await exported(graded)
        #expect(abs(plain.r - gradedOut.r) + abs(plain.g - gradedOut.g) + abs(plain.b - gradedOut.b) > 12,
                "grade must change the export")

        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.setTimeline(tl(graded))
        engine.seek(to: .zero)
        await engine.waitForDecodes()
        #expect(engine.tick())
        let t = try #require(engine.lastRenderedTexture)
        let px = playbackPixels(t, device: device)
        let i = (18 * t.width + 32) * 4
        let want = [0, 1, 2].map { Int((linearToRec709(Double(px[i + $0])) * 255).rounded()) }
        #expect(abs(gradedOut.r - want[0]) <= 3 && abs(gradedOut.g - want[1]) <= 3 && abs(gradedOut.b - want[2]) <= 3,
                "export \(gradedOut) vs playback-encoded \(want)")
    }
}
