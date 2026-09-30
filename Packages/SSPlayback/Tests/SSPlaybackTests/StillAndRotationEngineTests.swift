import CoreGraphics
import CoreVideo
import CoreMedia
import Foundation
import Metal
import Testing
import SSCore
import SSMedia
import SSMediaTestSupport
@testable import SSPlayback

private let fd = Time(1, 30)

private func readback(_ texture: MTLTexture, device: MTLDevice) -> [Float16]? {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let p = buf.contents().assumingMemoryBound(to: Float16.self)
    return Array(UnsafeBufferPointer(start: p, count: w * h * 4))
}

private func redStill(width: Int, height: Int) throws -> StillFrame {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return StillFrame(buffer: try StillImage.pixelBuffer(from: ctx.makeImage()!), info: StillImage.trackInfo(width: width, height: height))
}

@Suite(.serialized) @MainActor struct StillAndRotationEngineTests {
    @Test func stillImageClipPlaysThroughTheEngine() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let media = UUID()
        let still = try redStill(width: 64, height: 36)
        let resolver = StaticMediaResolver(stills: [media: still])
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        let clip = Clip(name: "still", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                        start: .zero, isStill: true)
        engine.setTimeline(Timeline(name: "s", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                                    tracks: [Track(kind: .video, clips: [clip])]))
        engine.seek(to: Time(1, 1))
        await engine.waitForDecodes()
        #expect(engine.tick())
        let tex = try #require(engine.lastRenderedTexture)
        let px = try #require(readback(tex, device: device))
        let i = (90 * 320 + 160) * 4
        #expect(Float(px[i]) > 0.95 && Float(px[i + 1]) < 0.02 && Float(px[i + 2]) < 0.02,
                "rgba \(px[i]) \(px[i + 1]) \(px[i + 2]) \(px[i + 3])")
        #expect(engine.stats.droppedFrames == 0)
        #expect(engine.decodeCalls == 0)
    }

    @Test func portraitClipFillsPortraitSequenceUpright() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec()
        spec.width = 320; spec.height = 180; spec.frameCount = 60; spec.frameDuration = TestClipSpec.fps(30); spec.rotation = 90
        let url = try await TestClipWriter.write(spec)
        let media = UUID()
        let resolver = StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)])
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        let clip = Clip(name: "p", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 60),
                        start: .zero, mediaDuration: fd * 60)
        engine.setTimeline(Timeline(name: "p", format: SequenceFormat(width: 180, height: 320, frameDuration: fd),
                                    tracks: [Track(kind: .video, clips: [clip])]))
        engine.seek(to: fd * 37)
        await engine.waitForDecodes()
        #expect(engine.tick())
        let tex = try #require(engine.lastRenderedTexture)
        let px = try #require(readback(tex, device: device))
        // Native stamp (top-left, bit 0 leftmost) turned clockwise by 90: it runs down the right edge, bit 0 at the top.
        var value = 0
        for bit in 0..<FrameStamp.bitCount {
            var sum: Float = 0, n: Float = 0
            for y in (bit * 16 + 4)..<(bit * 16 + 12) {
                for x in (180 - 12)..<(180 - 4) {
                    let i = (y * 180 + x) * 4
                    sum += 0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2]); n += 1
                }
            }
            if sum / n > 0.7 { value |= 1 << bit }
        }
        #expect(value == 37)
    }
}
