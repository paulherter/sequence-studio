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

// Second round: problems found in review of the first set of fixes.

private let fd = Time(1, 30)

private final class Counter: Sendable {
    private let m = Mutex(0)
    func bump() { m.withLock { $0 += 1 } }
    var value: Int { m.withLock { $0 } }
}

private final class Gate: Sendable {
    private let released = Mutex(false)
    func open() { released.withLock { $0 = true } }
    func wait() async { while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(2)) } }
    func waitBlocking() { while !released.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.002) } }
}

private struct GatedDecoder: VideoDecoding {
    let media: UUID, gate: Gate?, invalidations: Counter
    var info: VideoTrackInfo { VideoTrackInfo(width: 2, height: 2, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false) }
    var isHardware: Bool { false }
    func invalidate() { invalidations.bump() }
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        await gate?.wait()
        try Task.checkCancellation()
        return try range.map { i in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pb)
            return DecodedFrame(media: media, pts: fd * Int64(i), duration: fd, pixelBuffer: try #require(pb))
        }
    }
}

@Suite struct DecoderThrashTests {
    private func job(_ m: UUID, _ first: Int) -> PrefetchPlanner.Job { .init(media: m, frames: first...(first + 14), priority: 0) }

    // Review 3: a window with 3+ media alternating must keep one decoder per media (trim looked only at pending jobs).
    @Test func threeAlternatingMediaCreateEachDecoderOnce() async {
        let created = Mutex(0), inv = Counter()
        let s = DecodeScheduler(maxConcurrent: 2, idleDecoders: 1,
                                decoder: { created.withLock { $0 += 1 }; return GatedDecoder(media: $0, gate: nil, invalidations: inv) },
                                sink: { _, _ in }, onError: { _, _ in })
        let ms = (0..<3).map { _ in UUID() }
        for i in 0..<100 {
            // The planner's window: all three media, a different GOP each round.
            await s.submit(ms.map { job($0, 15 * (i % 20)) })
            await s.waitUntilIdle()
        }
        #expect(created.withLock { $0 } == 3, "created \(created.withLock { $0 })")
        #expect(inv.value == 0)
    }

    // Review 2: a job in flight for the old file must not store frames after a relink.
    @Test func inFlightJobAcrossForgetStoresNothing() async {
        let stored = Mutex(0), inv = Counter(), created = Mutex(0), gate = Gate(), m = UUID()
        let s = DecodeScheduler(maxConcurrent: 2,
                                decoder: { created.withLock { $0 += 1 }; return GatedDecoder(media: $0, gate: gate, invalidations: inv) },
                                sink: { _, f in stored.withLock { $0 += f.count } }, onError: { _, _ in })
        await s.submit([job(m, 0)])
        for _ in 0..<SQTiming.polls(500) where created.withLock({ $0 }) == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        await s.forget([m])
        gate.open()
        await s.waitUntilIdle()
        #expect(stored.withLock { $0 } == 0)
        #expect(inv.value == 1, "the old file's decoder is discarded")
        #expect(await s.decoderCount == 0)
    }
}

private struct TagDemuxer: Demuxing {
    let tag: Int
    let fmt: CMFormatDescription
    var index: SampleIndex { SampleIndex(entries: []) }
    var formatDescription: CMFormatDescription { fmt }
    func samples(for range: ClosedRange<Int>) async throws -> [CMSampleBuffer] { [] }
    init(_ tag: Int) {
        self.tag = tag
        var f: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 2, height: 2, extensions: nil, formatDescriptionOut: &f)
        fmt = f!
    }
}

private final class SlowFirstResolver: MediaResolver, Sendable {
    private let s = Mutex((calls: 0, current: 1))
    let entered = Gate(), proceed = Gate()
    func switchTo(_ n: Int) { s.withLock { $0.current = n } }
    func demuxer(for media: UUID) throws -> any Demuxing {
        let (n, tag) = s.withLock { $0.calls += 1; return ($0.calls, $0.current) }
        if n == 1 { entered.open(); proceed.waitBlocking() }
        return TagDemuxer(tag)
    }
    func audio(for media: UUID) throws -> any AudioSource { throw MediaResolverError.unknownMedia(media) }
}

@Suite struct MediaEpochTests {
    // Review 2: a resolve that began before the relink must not leave the old file's demuxer behind.
    @Test func resolveStartedBeforeForgetIsRedone() async {
        let r = SlowFirstResolver(), table = MediaTable(resolver: r), id = UUID()
        let done = Mutex(false)
        Thread.detachNewThread { table.resolve(id); done.withLock { $0 = true } }
        await r.entered.wait()
        r.switchTo(2)                       // the file was relinked while the first open is still running
        table.forget([id])
        r.proceed.open()
        for _ in 0..<SQTiming.polls(500) where !done.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(2)) }
        guard case .ready(let d) = table.known(id) else { Issue.record("not resolved"); return }
        #expect((d as? TagDemuxer)?.tag == 2)
    }

    @Test func staleEpochDecodeReturnsNoFrames() async throws {
        let table = MediaTable(resolver: StaticMediaResolver()), id = UUID(), gate = Gate()
        let inner = GatedDecoder(media: id, gate: gate, invalidations: Counter())
        let dec = EpochDecoder(inner: inner, media: table, id: id, epoch: table.epoch(id))
        async let frames = dec.decode(0...3)
        try await Task.sleep(for: .milliseconds(20))
        table.forget([id])
        gate.open()
        #expect(try await frames.isEmpty)
        let fresh = EpochDecoder(inner: inner, media: table, id: id, epoch: table.epoch(id))
        #expect(try await fresh.decode(0...3).count == 4)
    }
}

private actor ClipFile {
    static let shared = ClipFile()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec(); spec.frameCount = 60; spec.frameDuration = TestClipSpec.fps(30)
        let u = try await TestClipWriter.write(spec); url = u; return u
    }
}

private func stamp(_ tex: MTLTexture, device: MTLDevice) -> Int? {
    let w = tex.width, h = tex.height, bpr = w * 8
    guard let q = device.makeCommandQueue(), let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared),
          let cb = q.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return nil }
    blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
              destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let px = buf.contents().assumingMemoryBound(to: Float16.self)
    var value = 0
    for bit in 0..<FrameStamp.bitCount {
        var sum: Float = 0, n: Float = 0
        for y in 4..<12 { for x in (bit * 16 + 4)..<(bit * 16 + 12) {
            let i = y * w * 4 + x * 4
            sum += 0.2126 * Float(px[i]) + 0.7152 * Float(px[i + 1]) + 0.0722 * Float(px[i + 2]); n += 1
        } }
        let v = sum / n
        if v > 0.3 && v < 0.7 { return nil }
        if v >= 0.7 { value |= 1 << bit }
    }
    return value
}

@Suite(.serialized) @MainActor struct EngineReview2Tests {
    private let format = SequenceFormat(width: 320, height: 180, frameDuration: fd)

    // Review 1: media added during playback is opened ahead, so the cut into it is not held or drawn as a placeholder.
    @Test func cutIntoMediaAddedDuringPlaybackIsNotCold() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let file = try await ClipFile.shared.get()
        let a = UUID(), b = UUID(), clock = ManualClock()
        let resolver = StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: file), b: try await AVDemuxer(url: file)])
        let engine = try PlaybackEngine(device: device, media: resolver, clock: clock)
        func clip(_ m: UUID, at start: Time) -> Clip {
            Clip(name: "c", media: m, kind: .video, source: TimeRange(start: .zero, duration: fd * 60), start: start, mediaDuration: fd * 60)
        }
        let only = Timeline(name: "s", format: format, tracks: [Track(kind: .video, clips: [clip(a, at: .zero)])])
        var cut = only
        try cut.tracks[0].overwrite(clip(b, at: fd * 60))
        engine.setTimeline(only)
        engine.seek(to: .zero)
        await engine.waitForDecodes()
        for _ in 0..<5 { _ = engine.tick(); await engine.waitForDecodes() }
        engine.play()
        let before = engine.stats
        var atCut: Int?
        for i in 1...75 {
            clock.advance(by: fd)
            if i == 15 { engine.setTimeline(cut) }                 // the user drops a second clip while playing
            let presented = engine.tick()
            await engine.waitForDecodes()
            if i == 60, presented, let t = engine.lastRenderedTexture { atCut = stamp(t, device: device) }
        }
        engine.pause()
        #expect(atCut == 0, "first frame of the second clip shown exactly at the cut, got \(String(describing: atCut))")
        #expect(engine.stats.droppedFrames - before.droppedFrames == 0)
    }

    // Review 5: the retry budget belongs to one generation: an invalidation starts a fresh series.
    @Test func renderRetriesStartOverAfterAnInvalidation() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(), clock: ManualClock())
        var tl = Timeline(name: "s", format: format, tracks: [Track(kind: .video)])
        tl.format = SequenceFormat(width: 0, height: 0, frameDuration: fd)
        engine.setTimeline(tl)
        for _ in 0..<(RenderLoop.maxRenderRetries + 3) { _ = engine.tick() }
        #expect(engine.loop.state.withLock { $0.renderedGeneration == $0.generation }, "gave up")
        engine.redraw()
        _ = engine.tick()
        #expect(engine.loop.state.withLock { $0.renderedGeneration != $0.generation }, "tries again after a change")
    }
}
