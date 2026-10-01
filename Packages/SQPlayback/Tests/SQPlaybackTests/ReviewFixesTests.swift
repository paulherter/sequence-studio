import Testing
import Foundation
import CoreMedia
import CoreVideo
import Metal
import Synchronization
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// Regression tests for the findings of docs/cloud/review-SQPlayback-SQRender.md that were verified on current main.

private let fd = Time(1, 30)
private func sec(_ n: Int64, _ d: Int64 = 1) -> Time { Time(n, d) }
private let sr: Int64 = 48_000

private func gopIndex(frames: Int, gop: Int = 30) -> SampleIndex {
    SampleIndex(entries: (0..<frames).map {
        SampleIndex.Entry(pts: fd * Int64($0), dts: fd * Int64($0), duration: fd, isSync: $0 % gop == 0, decodeOrdinal: $0)
    })
}

/// outer: one nested clip (outer 5 s... showing inner 1 s...4 s) over `inner`: one clip of `media` (inner 0...10 s).
private func nestedFixture(media: UUID) throws -> (outer: Timeline, inner: Timeline) {
    var innerTrack = Track(kind: .video)
    try innerTrack.overwrite(Clip(name: "m", media: media, kind: .video, source: TimeRange(start: .zero, duration: sec(10)), start: .zero))
    let inner = Timeline(name: "inner", frameDuration: fd, tracks: [innerTrack])
    var outerTrack = Track(kind: .video)
    try outerTrack.overwrite(Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: sec(1), duration: sec(3)),
                                  start: sec(5), sequence: inner.id))
    return (Timeline(name: "outer", frameDuration: fd, tracks: [outerTrack]), inner)
}

@Suite struct NestedPlaybackPlanTests {
    // Finding 1: nested clips produced no prefetch jobs and their frames were "unplaceable" (evicted first).
    @Test func plannerPlansTheGOPsOfNestedClips() throws {
        let m = UUID()
        let (outer, inner) = try nestedFixture(media: m)
        let ix = [m: gopIndex(frames: 300)]
        let none: @Sendable (UUID, Int) -> Bool = { _, _ in false }
        let blind = PrefetchPlanner().jobs(timeline: outer, playhead: sec(5), rate: .forward, indexes: ix, cached: none)
        #expect(blind.isEmpty)       // without the sequences nothing can be resolved
        let jobs = PrefetchPlanner().jobs(timeline: outer, sequences: [inner.id: inner], playhead: sec(5), rate: .forward,
                                          indexes: ix, cached: none)
        // Outer 5 s shows inner 1 s = source frame 30 = GOP 30...59; two seconds ahead covers the next GOPs.
        #expect(jobs.first?.frames == 30...59)
        #expect(jobs.count >= 2 && jobs.allSatisfy { $0.media == m })
    }

    @Test func nestedMediaFramesMapToOuterTimelineTime() throws {
        let m = UUID()
        let (outer, inner) = try nestedFixture(media: m)
        let map = RenderLoop.mapping(outer, sequences: [inner.id: inner])
        // inner 2 s is one second into the nested clip, which starts at outer 5 s.
        #expect(map(FrameKey(media: m, pts: sec(2))) == sec(6))
        #expect(map(FrameKey(media: m, pts: sec(0))) == nil)      // before the nested clip's source range
        #expect(RenderLoop.mapping(outer)(FrameKey(media: m, pts: sec(2))) == nil)   // no sequences: unplaceable, as before
    }
}

private struct Fake: CacheCost { var byteCost: Int }

@Suite struct FrameCacheScaleTests {
    // Finding 9: after Full -> Half the old Full frames were as "near" as the new ones and survived eviction.
    @Test func framesOfAnotherScaleAreEvictedFirst() {
        let m = UUID()
        let c = FrameCache<Fake>(budgetBytes: 40)
        c.setFocus(playhead: .zero, direction: 1, scale: .full)
        for i in 0..<4 { c.insert(Fake(byteCost: 10), for: FrameKey(media: m, pts: sec(Int64(i)), scale: .full)) }
        c.setFocus(playhead: .zero, direction: 1, scale: .half)             // quality changed to Half
        for i in 0..<4 { c.insert(Fake(byteCost: 10), for: FrameKey(media: m, pts: sec(Int64(i)), scale: .half)) }
        let half = (0..<4).filter { c.frame(FrameKey(media: m, pts: sec(Int64($0)), scale: .half)) != nil }.count
        #expect(half == 4, "all four Half frames are kept; the stale Full copies made room")
        #expect(c.usedBytes <= 40)
    }

    @Test func removeMediaDropsOnlyThatMedia() {
        let a = UUID(), b = UUID()
        let c = FrameCache<Fake>(budgetBytes: 1000)
        for i in 0..<3 {
            c.insert(Fake(byteCost: 10), for: FrameKey(media: a, pts: sec(Int64(i))))
            c.insert(Fake(byteCost: 10), for: FrameKey(media: b, pts: sec(Int64(i))))
        }
        c.remove(media: a)
        #expect(c.count == 3 && c.usedBytes == 30)
        #expect(c.nearest(media: a, atOrBefore: sec(5), scale: .full) == nil)
        #expect(c.nearest(media: b, atOrBefore: sec(5), scale: .full) != nil)
    }
}

private final class DecoderStats: Sendable {
    private let s = Mutex((created: 0, invalidated: 0, decodes: 0))
    func created() { s.withLock { $0.created += 1 } }
    func invalidated() { s.withLock { $0.invalidated += 1 } }
    func decoded() { s.withLock { $0.decodes += 1 } }
    var value: (created: Int, invalidated: Int, decodes: Int) { s.withLock { $0 } }
}

private struct CountingFake: VideoDecoding {
    let media: UUID, stats: DecoderStats, failFirstFrame: Int?
    var info: VideoTrackInfo { VideoTrackInfo(width: 2, height: 2, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false) }
    var isHardware: Bool { false }
    func invalidate() { stats.invalidated() }
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        stats.decoded()
        if range.lowerBound == failFirstFrame { throw MediaError.truncated }
        return try range.map { i in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pb)
            return DecodedFrame(media: media, pts: fd * Int64(i), duration: fd, pixelBuffer: try #require(pb))
        }
    }
}

@Suite struct DecoderLifetimeTests {
    private func scheduler(_ stats: DecoderStats, idle: Int = 1, failing: Int? = nil) -> DecodeScheduler {
        DecodeScheduler(maxConcurrent: 2, idleDecoders: idle,
                        decoder: { stats.created(); return CountingFake(media: $0, stats: stats, failFirstFrame: failing) },
                        sink: { _, _ in }, onError: { _, _ in })
    }
    private func job(_ m: UUID, _ first: Int) -> PrefetchPlanner.Job { .init(media: m, frames: first...(first + 14), priority: 0) }

    // Finding 5: every media that was ever decoded kept a VideoToolbox session until the engine died.
    @Test func decodersOfMediaOutsideTheWindowAreReleased() async {
        let stats = DecoderStats(), s = scheduler(stats, idle: 1)
        let ms = (0..<5).map { _ in UUID() }
        for m in ms { await s.submit([job(m, 0)]); await s.waitUntilIdle() }
        let live = await s.decoderCount
        #expect(live <= 2, "wanted + 1 idle, got \(live)")
        #expect(stats.value.created == 5 && stats.value.invalidated >= 3)
    }

    // Finding 6: a failed decode threw the decoder away; the next GOP then opened a new session.
    @Test func decoderSurvivesAFailedGOP() async {
        let stats = DecoderStats(), s = scheduler(stats, failing: 0), m = UUID()
        await s.submit([job(m, 0)]); await s.waitUntilIdle()
        await s.submit([job(m, 15)]); await s.waitUntilIdle()
        #expect(stats.value.created == 1)
        #expect(stats.value.decodes == 2)
    }

    // Finding 4: a relinked media must get a new decoder.
    @Test func forgetDropsTheDecoder() async {
        let stats = DecoderStats(), s = scheduler(stats), m = UUID()
        await s.submit([job(m, 0)]); await s.waitUntilIdle()
        await s.forget([m])
        #expect(await s.decoderCount == 0 && stats.value.invalidated == 1)
        await s.submit([job(m, 15)]); await s.waitUntilIdle()
        #expect(stats.value.created == 2)
    }
}

@Suite struct AudioClockReviewTests {
    // Finding 2: a cold file open longer than 250 ms (output priming, nothing consumed yet) failed the audio.
    @Test func slowPrimingIsNotAStall() {
        let audio = ManualAudio(autoFlush: false)
        let clock = AudioClock(audio: audio)
        clock.start(at: .zero, rate: .forward)
        audio.advanceTime(nanoseconds: 1_000_000_000)             // feeder still opening the source
        #expect(clock.sample().stalled == false)
        audio.advanceTime(nanoseconds: 1_100_000_000)             // never primed: now it is a stall
        #expect(clock.sample().stalled == true)
    }

    @Test func aStallAfterAudioFlowedStillTripsTheShortWatchdog() {
        let audio = ManualAudio()
        let clock = AudioClock(audio: audio)
        clock.start(at: .zero, rate: .forward)
        audio.render(frames: 480)
        #expect(clock.sample().stalled == false)
        audio.advanceTime(nanoseconds: 300_000_000)
        #expect(clock.sample().stalled == true)
    }

    // Finding 3: with output latency above one frame the reverse clock rested above frame 0 and the watchdog fired.
    @Test(arguments: [PlaybackRate.reverse, PlaybackRate(-2)])
    func reversePlayReachesTheStartDespiteOutputLatency(rate: PlaybackRate) {
        let audio = ManualAudio(latencySamples: 480, outputLatency: Time(60, 1000))   // 60 ms: two frames at 30 fps
        let clock = AudioClock(audio: audio)
        clock.start(at: sec(1), rate: rate)
        audio.render(frames: 10_000)
        #expect(clock.now() < sec(1))
        audio.render(frames: Int(sr) - 10_000)                     // everything from 1 s down to 0 consumed
        #expect(clock.now() < fd, "clock \(clock.now()) must be inside frame 0")
        #expect(clock.now() == .zero)
    }
}

@Suite struct RingFlushRaceTests {
    // Finding 11: a flush + push landing between the epoch load and the write-index load played pre-flush frames.
    @Test func flushThatRacesPopNeverPlaysStaleFrames() {
        let r = RingBuffer(capacity: 16)
        func push(_ v: [Float]) { v.withUnsafeBufferPointer { _ = r.push(left: $0.baseAddress!, right: $0.baseAddress!, count: v.count) } }
        push([1, 2, 3, 4])
        let fired = Mutex(false)
        r.afterEpochLoad = {
            guard !fired.withLock({ let was = $0; $0 = true; return was }) else { return }
            r.flush(); push([9, 8])
        }
        var l = [Float](repeating: -1, count: 2), rr = l
        let got = l.withUnsafeMutableBufferPointer { lp in rr.withUnsafeMutableBufferPointer { rp in
            r.pop(left: lp.baseAddress!, right: rp.baseAddress!, count: 2) } }
        #expect(got == 2 && l == [9, 8], "played \(l)")
    }
}

@Suite struct ScrubVoiceCancelTests {
    // Finding 12: the first render after a cancel dropped a grain already published for the new generation.
    @Test func grainOfTheNewGenerationSurvivesCancel() throws {
        let v = ScrubVoice(capacity: 1024, fadeFrames: 64)
        v.cancel()
        let slot = try #require(v.claim())
        let (bl, br) = v.buffers(slot)
        for i in 0..<600 { bl[i] = 0.5; br[i] = 0.5 }
        v.publish(slot: slot, frames: 600, hop: 300, generation: v.generation, tag: 7)
        var l = [Float](repeating: 0, count: 256), r = l
        let silent = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            v.render(left: lp.baseAddress!, right: rp.baseAddress!, count: 256) } }
        #expect(!silent && v.grainsStarted == 1 && v.lastStartedTag == 7)
    }
}

// MARK: Engine

private actor ClipFile {
    static let shared = ClipFile()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec(); spec.frameCount = 60; spec.frameDuration = TestClipSpec.fps(30)
        let u = try await TestClipWriter.write(spec); url = u; return u
    }
}

/// Swappable resolver: records every `demuxer` call and the thread it came from.
private final class SwapResolver: MediaResolver, Sendable {
    private struct S { var demuxer: any Demuxing; var calls = 0; var onMain = 0 }
    private let s: Mutex<S>
    init(_ d: any Demuxing) { s = Mutex(S(demuxer: d)) }
    func swap(_ d: any Demuxing) { s.withLock { $0.demuxer = d } }
    var calls: Int { s.withLock { $0.calls } }
    var callsOnMainThread: Int { s.withLock { $0.onMain } }
    func demuxer(for media: UUID) throws -> any Demuxing {
        let main = Thread.isMainThread
        return s.withLock { $0.calls += 1; if main { $0.onMain += 1 }; return $0.demuxer }
    }
    func audio(for media: UUID) throws -> any AudioSource { throw MediaResolverError.unknownMedia(media) }
}

@Suite(.serialized) @MainActor struct EngineReviewTests {
    private let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)

    private func timeline(_ media: UUID) -> Timeline {
        let clip = Clip(name: "A", media: media, kind: .video, source: TimeRange(start: .zero, duration: fd * 60), start: .zero, mediaDuration: fd * 60)
        return Timeline(name: "Seq", format: format, tracks: [Track(kind: .video, clips: [clip])])
    }

    // Finding 8: the render tick called the resolver itself (blocking open on the render/main thread).
    @Test func resolverIsNeverCalledOnTheRenderThread() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resolver = SwapResolver(try await AVDemuxer(url: try await ClipFile.shared.get()))
        let media = UUID()
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.setTimeline(timeline(media))
        _ = engine.tick()                                          // first frame: nothing resolved yet
        for _ in 0..<300 {
            await engine.waitForDecodes(); _ = engine.tick()
            if engine.cacheCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(resolver.calls >= 1)
        #expect(resolver.callsOnMainThread == 0)
        #expect(engine.cacheCount > 0, "the media still gets resolved, planned and decoded")
    }

    // Finding 4: relinking an online media to another file kept the old demuxer, decoder and frames.
    @Test func mediaChangedReopensDecodesAndDropsOldFrames() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let resolver = SwapResolver(try await AVDemuxer(url: try await ClipFile.shared.get()))
        let media = UUID()
        let engine = try PlaybackEngine(device: device, media: resolver, clock: ManualClock())
        engine.setTimeline(timeline(media))
        engine.seek(to: .zero); await engine.waitForDecodes()
        for _ in 0..<5 { _ = engine.tick(); await engine.waitForDecodes() }
        #expect(resolver.calls == 1 && engine.cacheCount > 0)
        let decodes = engine.decodeCalls
        engine.mediaChanged([media])
        #expect(engine.cacheCount == 0, "frames of the old file are gone")
        await engine.waitForDecodes()
        for _ in 0..<50 where resolver.calls < 2 { _ = engine.tick(); try await Task.sleep(for: .milliseconds(10)); await engine.waitForDecodes() }
        await engine.waitForDecodes()
        #expect(resolver.calls == 2, "resolved again")
        #expect(engine.decodeCalls > decodes, "decoded again with a new decoder")
    }

    // Finding 7: a composite that failed was never retried until the next edit.
    @Test func failedCompositeIsRetriedOnTheNextTick() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let media = UUID()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock())
        var tl = timeline(media)
        tl.format = SequenceFormat(width: 0, height: 0, frameDuration: fd)       // no render target can be made
        engine.setTimeline(tl)
        #expect(engine.tick() == false)
        let pending = engine.loop.state.withLock { $0.renderedGeneration != $0.generation }
        #expect(pending, "the failed render must stay due")
        for _ in 0..<(RenderLoop.maxRenderRetries + 2) { _ = engine.tick() }
        let gaveUp = engine.loop.state.withLock { $0.renderedGeneration == $0.generation }
        #expect(gaveUp, "a persistent failure stops retrying")
    }

    // Finding 10: scrub/step re-walked every clip per event. Cost of the walk that is now done once per edit.
    @Test func audibleWalkCostForALargeTimeline() {
        let clips = (0..<2000).map { Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: sec(1)), start: sec(Int64($0))) }
        let track = Track(kind: .audio, clips: clips)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [track])
        let t0 = ContinuousClock.now
        for _ in 0..<20 { _ = PlaybackEngine.isAudible(tl, sequences: [:]) }
        let per = (ContinuousClock.now - t0) / 20
        print("[review] isAudible on 2000 clips: \(per)")
        #expect(PlaybackEngine.isAudible(tl, sequences: [:]))
    }
}
