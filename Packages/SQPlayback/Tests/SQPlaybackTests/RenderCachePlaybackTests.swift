import CoreMedia
import Foundation
import Metal
import Testing
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// Preview render cache, read path: a timeline whose `renderCacheSpans` cover a range shows that range from the cache file
// (one layer, file time = timeline time - span start) and decodes none of the clips it replaces; outside the span the clips
// play as before.

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { fd * n }

@Suite(.serialized) @MainActor struct RenderCachePlaybackTests {
    @Test func aCachedSpanIsReadFromTheFileAndTheClipsUnderItAreNotDecoded() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec(); spec.frameCount = 150
        let a = UUID(), b = UUID(), cache = UUID()
        let resolver = StaticMediaResolver(demuxers: [
            a: try await AVDemuxer(url: try await TestClipWriter.write(spec)),
            b: try await AVDemuxer(url: try await TestClipWriter.write(spec)),
            cache: try await AVDemuxer(url: try await TestClipWriter.write(spec)),
        ], audio: [:])
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.quality = .full
        engine.waitsForStartFrame = false
        let lower = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(150)), start: .zero)
        let upper = Clip(name: "B", media: b, kind: .video, source: TimeRange(start: f(30), duration: f(30)), start: f(30))
        var tl = Timeline(name: "t", format: SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [lower]), Track(kind: .video, clips: [upper])])
        tl.renderCacheSpans = [RenderCacheSpan(range: TimeRange(start: f(30), duration: f(30)), media: cache)]
        engine.setTimeline(tl)

        func show(_ n: Int64) async throws -> TickProfile {
            engine.seek(to: f(n))
            for _ in 0..<200 {
                _ = engine.tick()
                if let p = engine.lastTickProfile, p.time == f(n), p.presented, p.missing == 0, p.noFrame == 0 {
                    await engine.waitForDecodes()
                    return p
                }
                await engine.waitForDecodes()
            }
            throw CancellationError()
        }

        let inside = try await show(40)
        #expect(inside.layers == 1)
        #expect(engine.cachedFrame(media: cache, pts: f(10)))
        #expect(!engine.cachedFrame(media: a, pts: f(40)) && !engine.cachedFrame(media: b, pts: f(40)))

        let outside = try await show(100)
        #expect(outside.layers == 1)
        #expect(engine.cachedFrame(media: a, pts: f(100)))
        #expect(!engine.cachedFrame(media: cache, pts: f(70)))

        // Before / After on the color page needs the real clips: while a bypass is set the spans are ignored.
        engine.setColorBypass(ColorBypass(clips: [upper.id], mode: .before))
        let bypassed = try await show(45)
        #expect(bypassed.layers >= 1)
        #expect(engine.cachedFrame(media: b, pts: f(45)))
        engine.setColorBypass(nil)
        let back = try await show(50)
        #expect(back.layers == 1)

        // Display P3 / HDR views show colors the cache file does not keep: spans are ignored there as well.
        // (Earlier reads may have read ahead in the cache file; what counts is that nothing more is read from it here.)
        func cachedFileFrames() -> [Int64] { (0..<30).filter { engine.cachedFrame(media: cache, pts: f($0)) } }
        let readBefore = cachedFileFrames()
        engine.cacheDisplayView = { .displayP3 }
        engine.setTimeline(tl)
        _ = try await show(52)
        #expect(engine.cachedFrame(media: b, pts: f(52)))
        #expect(cachedFileFrames() == readBefore)
        engine.cacheDisplayView = { .sdr }
        engine.setTimeline(tl)
        _ = try await show(54)
        #expect(engine.cachedFrame(media: cache, pts: f(24)))
    }

    @Test func seededPendingFramesShowWithoutReadingTheFile() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec(); spec.frameCount = 90
        let a = UUID(), cache = UUID()
        // The cache file is not resolvable at all: what shows inside the span can only come from the seeded frames.
        let resolver = StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: try await TestClipWriter.write(spec))], audio: [:])
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.quality = .full
        engine.waitsForStartFrame = false
        engine.cacheDisplayView = { .sdr }
        let clip = Clip(name: "A", media: a, kind: .video, source: TimeRange(start: .zero, duration: f(90)), start: .zero)
        var tl = Timeline(name: "t", format: SequenceFormat(width: spec.width, height: spec.height, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [clip])])
        tl.renderCacheSpans = [RenderCacheSpan(range: TimeRange(start: f(30), duration: f(30)), media: cache)]
        var frames: [DecodedFrame] = []
        for i in 0..<30 {
            var pb: CVPixelBuffer?
            let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                                        kCVPixelBufferMetalCompatibilityKey as String: true]
            CVPixelBufferCreate(nil, spec.width, spec.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
            frames.append(DecodedFrame(media: cache, pts: f(Int64(i)), duration: fd, pixelBuffer: try #require(pb)))
        }
        engine.setTimeline(tl)
        engine.seedFrames(frames)
        #expect(engine.cachedFrame(media: cache, pts: f(10)))
        engine.seek(to: f(40))
        var shown = false
        for _ in 0..<200 {
            _ = engine.tick()
            if let p = engine.lastTickProfile, p.time == f(40), p.presented, p.missing == 0, p.noFrame == 0 { shown = true; break }
            await engine.waitForDecodes()
        }
        #expect(shown)
        #expect(engine.lastTickProfile?.layers == 1)
        // Shown from the seeded frame (the file cannot be opened), the clip under the span not decoded.
        #expect(!engine.cachedFrame(media: a, pts: f(40)))
    }
}
