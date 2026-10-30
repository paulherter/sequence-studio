import CoreGraphics
import CoreMedia
import Foundation
import Metal
import Testing
import SQAnalysis
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

private let fd = Time(1, 30)

/// W9.8: the render loop hands subject-masked layers a person matte from `SubjectMatteScheduler` (segmented off the
/// render tick): fast while playing or scrubbing, balanced for a settled frame; stills too; state released with the clip.
@Suite(.serialized) @MainActor struct SubjectMaskPlaybackTests {
    private func timeline(_ clip: Clip) -> Timeline {
        Timeline(name: "s", format: SequenceFormat(width: 320, height: 180, frameDuration: fd), tracks: [Track(kind: .video, clips: [clip])])
    }

    private func engine(masks: [ClipMask]) async throws -> (PlaybackEngine, Clip) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await TestClipWriter.write(TestClipSpec())
        let media = UUID()
        let resolver = StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)])
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        var clip = Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 60),
                        start: .zero, mediaDuration: fd * 60)
        clip.masks = masks
        engine.setTimeline(timeline(clip))
        engine.seek(to: fd * 37)
        await engine.waitForDecodes()
        return (engine, clip)
    }

    private func key(_ c: Clip) -> SubjectMatteScheduler.Key { .init(clip: c.id, source: c.media) }

    @Test func settledFrameGetsTheBalancedMatteAfterItLands() async throws {
        let (engine, clip) = try await engine(masks: [ClipMask.makeSubject(name: "Subject")])
        #expect(engine.tick())                       // presents at once; Vision runs on the scheduler's queue
        await engine.loop.subjects.waitUntilIdle()
        #expect(engine.tick())                       // redraw with the matte
        let m = try #require(engine.loop.subjects.cached(key: key(clip), frameIndex: 37, quality: .balanced))
        #expect(m.width > 0 && m.height > 0)
        #expect(engine.loop.subjects.cached(key: key(clip), frameIndex: 37, quality: .fast) == nil)
        #expect(!engine.loop.subjects.timings.isEmpty)
    }

    @Test func scrubbingUsesTheFastQuality() async throws {
        let (engine, clip) = try await engine(masks: [ClipMask.makeSubject(name: "Subject")])
        engine.loop.setScrubbing(true)
        engine.tick()
        await engine.loop.subjects.waitUntilIdle()
        #expect(engine.loop.subjects.segmentations >= 1)
        #expect(engine.loop.subjects.keys == [key(clip)])
        #expect(engine.loop.subjects.cached(key: key(clip), frameIndex: 37, quality: .balanced) == nil)
        #expect(RenderLoop.subjectQuality(playing: false, scrubbing: true) == .fast)
        #expect(RenderLoop.subjectQuality(playing: true, scrubbing: false) == .fast)
        #expect(RenderLoop.subjectQuality(playing: false, scrubbing: false) == .balanced)
    }

    /// With the media's file known, the clip's frames are precomputed in the background; a later frame is then drawn
    /// from the store without a live Vision run.
    @Test func precomputedMattesAreDrawnWithoutLiveSegmentation() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let url = try await TestClipWriter.write(TestClipSpec())
        let media = UUID()
        var resolver = StaticMediaResolver(demuxers: [media: try await AVDemuxer(url: url)])
        resolver.fileURLs = [media: url]
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        var clip = Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 60),
                        start: .zero, mediaDuration: fd * 60)
        clip.masks = [ClipMask.makeSubject(name: "Subject")]
        engine.setTimeline(timeline(clip))
        engine.seek(to: fd * 37)
        await engine.waitForDecodes()
        let key = SubjectMattePrecompute.cacheKey(media: media, path: url.path)
        defer { engine.loop.subjectPrecompute.store.remove(key: key) }
        engine.tick()
        await engine.loop.subjectPrecompute.waitUntilIdle()
        await engine.loop.subjects.waitUntilIdle()
        #expect(engine.loop.subjectPrecompute.store.times(key: key).count == 60)
        let live = engine.loop.subjects.segmentations
        engine.seek(to: fd * 44)
        await engine.waitForDecodes()
        engine.tick()
        await engine.loop.subjects.waitUntilIdle()
        #expect(engine.loop.subjects.segmentations == live)
    }

    @Test func clipsWithoutSubjectMaskAreNotSegmented() async throws {
        let (engine, _) = try await engine(masks: [ClipMask.make(.rectangle, name: "Mask 1")])
        #expect(engine.tick())
        await engine.loop.subjects.waitUntilIdle()
        #expect(engine.loop.subjects.segmentations == 0)
        #expect(engine.loop.subjects.keys.isEmpty)
    }

    @Test func disabledSubjectMaskIsNotSegmented() async throws {
        var m = ClipMask.makeSubject(name: "Subject")
        m.enabled = false
        let (engine, _) = try await engine(masks: [m])
        #expect(engine.tick())
        await engine.loop.subjects.waitUntilIdle()
        #expect(engine.loop.subjects.segmentations == 0)
    }

    @Test func removingTheMaskOrRelinkingReleasesTheState() async throws {
        let (engine, clip) = try await engine(masks: [ClipMask.makeSubject(name: "Subject")])
        engine.tick()
        await engine.loop.subjects.waitUntilIdle()
        #expect(engine.loop.subjects.keys == [key(clip)])
        var plain = clip
        plain.masks = []
        engine.setTimeline(timeline(plain))
        #expect(engine.loop.subjects.keys.isEmpty)
        // Back with the mask, then the media is relinked: the matte history of that source goes.
        engine.setTimeline(timeline(clip))
        engine.tick()
        await engine.loop.subjects.waitUntilIdle()
        #expect(engine.loop.subjects.keys == [key(clip)])
        engine.mediaChanged([clip.media])
        #expect(engine.loop.subjects.keys.isEmpty)
    }

    @Test func stillImageClipIsSegmentedOnce() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let media = UUID()
        let still = try SubjectMaskPlaybackTests.grayStill()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(stills: [media: still]), clock: ManualClock())
        var clip = Clip(name: "still", media: media, kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                        start: .zero, isStill: true)
        clip.masks = [ClipMask.makeSubject(name: "Subject")]
        engine.setTimeline(timeline(clip))
        for f in [10, 20] {
            engine.seek(to: fd * Int64(f))
            await engine.waitForDecodes()
            #expect(engine.tick())
            await engine.loop.subjects.waitUntilIdle()
        }
        #expect(engine.loop.subjects.segmentations == 1)       // one frame: index 0 for the whole still
        #expect(engine.loop.subjects.cached(key: key(clip), frameIndex: 0, quality: .balanced) != nil)
    }

    static func grayStill() throws -> StillFrame {
        let ctx = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        return StillFrame(buffer: try StillImage.pixelBuffer(from: ctx.makeImage()!), info: StillImage.trackInfo(width: 96, height: 64))
    }
}
