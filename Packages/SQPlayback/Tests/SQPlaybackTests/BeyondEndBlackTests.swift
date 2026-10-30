import Foundation
import Metal
import SQCore
import SQMedia
import SQMediaTestSupport
import Testing
@testable import SQPlayback

// A playhead past the last clip shows black, not a still of the last frame.

@MainActor private func red(_ engine: PlaybackEngine, device: MTLDevice, x: Int, y: Int) -> Float16? {
    guard let texture = engine.lastRenderedTexture else { return nil }
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    let p = buf.contents().assumingMemoryBound(to: Float16.self)
    return (0..<3).map { p[(y * w + x) * 4 + $0] }.max()
}

@Suite(.serialized) @MainActor struct BeyondEndBlackTests {
    @Test func isBeyondEnd() {
        let fd = Time(1, 30)
        let clip = Clip(name: "a", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 10),
                        start: .zero, mediaDuration: fd * 10)
        let tl = Timeline(name: "a", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [clip])])
        #expect(!RenderLoop.isBeyondEnd(fd * 9, tl))
        #expect(RenderLoop.isBeyondEnd(fd * 10, tl))
        #expect(RenderLoop.isBeyondEnd(fd * 50, tl))
    }

    @Test func seekPastTheEndRendersBlackThenBackToPicture() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await PNGMovWriter.write(width: 320, height: 180, frames: 10, fps: 30)
        let media = UUID()
        let resolver = StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)])
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        let fd = Time(1, 30)
        let clip = Clip(name: "a", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 10),
                        start: .zero, mediaDuration: fd * 10)
        engine.setTimeline(Timeline(name: "a", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                                    tracks: [Track(kind: .video, clips: [clip])]))
        engine.seek(to: fd * 9)
        await engine.waitForDecodes()
        #expect(engine.tick())
        let lit = try #require(red(engine, device: device, x: 40, y: 90))
        #expect(lit > 0.01, "the last frame shows the picture")

        engine.seek(to: fd * 40)
        #expect(engine.tick())
        let past = try #require(red(engine, device: device, x: 40, y: 90))
        #expect(past < 0.001, "past the last clip: black, got \(past)")

        engine.seek(to: fd * 9)
        await engine.waitForDecodes()
        #expect(engine.tick())
        let back = try #require(red(engine, device: device, x: 40, y: 90))
        #expect(back > 0.01, "back on the clip: the picture again")
    }
}
