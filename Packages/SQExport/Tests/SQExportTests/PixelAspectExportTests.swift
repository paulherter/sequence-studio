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

private struct InfoStillResolver: MediaResolver {
    let base: StaticMediaResolver
    let colorResolver: LayerColorResolver?
    func demuxer(for media: UUID) throws -> any Demuxing { try base.demuxer(for: media) }
    func audio(for media: UUID) throws -> any SQMedia.AudioSource { try base.audio(for: media) }
    func stillFrame(for media: UUID) throws -> StillFrame? { try base.stillFrame(for: media) }
}

private func still(_ w: Int, _ h: Int) throws -> StillFrame {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.6, blue: 0.4, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return StillFrame(buffer: try StillImage.pixelBuffer(from: ctx.makeImage()!), info: StillImage.trackInfo(width: w, height: h))
}

private func playbackRed(_ t: MTLTexture, x: Int, y: Int, device: MTLDevice) -> Float {
    let w = t.width, h = t.height, bpr = w * 8
    let q = device.makeCommandQueue()!, buf = device.makeBuffer(length: bpr * h, options: .storageModeShared)!
    let cb = q.makeCommandBuffer()!, blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    return Float(buf.contents().assumingMemoryBound(to: Float16.self)[(y * w + x) * 4])
}

/// F7.3: a 32x36 picture in a 64x36 sequence. Square pixels leave the canvas black left and right of it; with a 2:1 pixel
/// aspect on the media item the picture covers the canvas, in export and in the monitor alike.
@Suite(.serialized) @MainActor struct PixelAspectExportTests {
    private func run(_ aspect: PixelAspect?) async throws -> (exportEdge: Int, exportCenter: Int, playEdge: Float, playCenter: Float) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let media = UUID()
        let frame = try still(32, 36)
        var v = frame.info
        v.pixelAspectOverride = aspect
        let info = MediaInfo(duration: fd * 2, video: v, isStill: true)
        let resolver = InfoStillResolver(base: StaticMediaResolver(stills: [media: frame]),
                                         colorResolver: LayerColorResolver(lutProvider: nil) { $0 == media ? info : nil })
        let clip = Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero,
                        isStill: true)
        let tl = Timeline(name: "t", format: SequenceFormat(width: 64, height: 36, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [clip])])

        let s = try TimelineFrameSource(timeline: tl, provider: DecoderFrameProvider(resolver: resolver),
                                        width: 64, height: 36, frameDuration: fd, frameCount: 1, colorResolver: resolver.colorResolver)
        let pb = try await s.frame(at: 0)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let row = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self) + 18 * CVPixelBufferGetBytesPerRow(pb)
        let edge = Int(row[4 * 4 + 2]), center = Int(row[32 * 4 + 2])
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)

        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.setTimeline(tl)
        engine.seek(to: .zero)
        await engine.waitForDecodes()
        #expect(engine.tick())
        let t = try #require(engine.lastRenderedTexture)
        return (edge, center, playbackRed(t, x: 4, y: 18, device: device), playbackRed(t, x: 32, y: 18, device: device))
    }

    @Test func squarePixelsLeaveTheSidesEmpty() async throws {
        let r = try await run(nil)
        #expect(r.exportCenter > 150 && r.exportEdge < 10)
        #expect(r.playCenter > 0.3 && r.playEdge < 0.02)
    }

    @Test func chosenPixelAspectWidensThePictureInExportAndPlayback() async throws {
        let r = try await run(PixelAspect(2, 1)!)
        #expect(r.exportCenter > 150 && abs(r.exportEdge - r.exportCenter) <= 2)
        #expect(r.playCenter > 0.3 && abs(r.playEdge - r.playCenter) < 0.01)
    }
}
