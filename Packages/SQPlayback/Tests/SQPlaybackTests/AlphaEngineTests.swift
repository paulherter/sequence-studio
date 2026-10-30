import CoreMedia
import CoreVideo
import Foundation
import Metal
import SQCore
import SQMedia
import SQMediaTestSupport
import Testing
@testable import SQPlayback

// FB-D: a transparent clip played through the whole engine (decoder, cache, render loop, compositor).

private func lin709(_ e: Double) -> Double { e < 0.081242858 ? e / 4.5 : pow((e + 0.09929682680944) / 1.09929682680944, 1 / 0.45) }

private func readback(_ texture: MTLTexture, device: MTLDevice) -> [Float16]? {
    let w = texture.width, h = texture.height, bpr = w * 8
    guard let queue = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: Float16.self), count: w * h * 4))
}

@Suite(.serialized) @MainActor struct AlphaEngineTests {
    private func play(_ codec: TestClipSpec.Codec?) async throws -> [Float16]? {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url: URL
        if let codec {
            var spec = TestClipSpec(); spec.codec = codec; spec.width = 320; spec.height = 180; spec.frameCount = 10
            spec.frameDuration = TestClipSpec.fps(30)
            do { url = try await TestClipWriter.write(spec) } catch TestClipError.encoderUnavailable { return nil }
        } else {
            url = try await PNGMovWriter.write(width: 320, height: 180, frames: 10, fps: 30)
        }
        let media = UUID()
        let resolver = StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)])
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        let fd = Time(1, 30)
        let clip = Clip(name: "a", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 10),
                        start: .zero, mediaDuration: fd * 10)
        engine.setTimeline(Timeline(name: "a", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                                    tracks: [Track(kind: .video, clips: [clip])]))
        engine.seek(to: fd * 3)
        await engine.waitForDecodes()
        #expect(engine.tick())
        let tex = try #require(engine.lastRenderedTexture)
        let w = tex.width, h = tex.height
        _ = (w, h)
        return try #require(readback(tex, device: device))
    }

    private func check(_ codec: TestClipSpec.Codec?) async throws {
        guard let px = try await play(codec) else { return }
        let c = AlphaTestPattern.color
        let want = [lin709(Double(c.r) / 255), lin709(Double(c.g) / 255), lin709(Double(c.b) / 255)]
        // Left half opaque: the color itself. Right quarter: transparent over black = black.
        func at(_ x: Int) -> [Double] { (0..<3).map { Double(px[(90 * 320 + x) * 4 + $0]) } }
        for ch in 0..<3 {
            #expect(abs(at(40)[ch] - want[ch]) < 0.03, "\(String(describing: codec)) opaque ch\(ch): \(at(40)) want \(want)")
            #expect(abs(at(300)[ch]) < 0.03, "\(String(describing: codec)) transparent ch\(ch): \(at(300))")
        }
    }

    @Test func pngMovClipRendersItsColour() async throws { try await check(nil) }

    @Test func proResAlphaClipRendersItsColour() async throws { try await check(.prores4444Alpha) }
    @Test func hevcAlphaClipRendersItsColour() async throws { try await check(.hevcAlpha) }
}
