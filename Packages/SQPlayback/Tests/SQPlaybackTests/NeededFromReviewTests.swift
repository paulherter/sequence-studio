import Testing
import Foundation
import CoreVideo
import Metal
import Synchronization
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// Review of phase lock + seek skip: pause position, reverse misses, widening a running seek job, no re-post per tick.

private let fd = Time(1, 30)
private typealias Job = PrefetchPlanner.Job

private func job(_ m: UUID, _ r: ClosedRange<Int>, _ p: Int = 0, from: Int?) -> Job {
    var j = Job(media: m, frames: r, priority: p); j.neededFrom = from; return j
}

@Suite struct NeededFromReviewTests {
    @Test func jobEqualityIgnoresNeededFrom() {
        let m = UUID()
        #expect(job(m, 0...29, from: 12) == job(m, 0...29, from: 20))
        #expect(Set([job(m, 0...29, from: 12), job(m, 0...29, from: 20)]).count == 1)
    }

    @Test func queueIsPostedOnlyWhenItChangesOrNeedsEarlierFrames() {
        let m = UUID()
        let last = [job(m, 30...59, from: 45), job(m, 60...89, 1, from: 60)]
        // Playing on: neededFrom moves forward each tick, nothing to post.
        #expect(!RenderLoop.needsPost(last: last, new: [job(m, 30...59, from: 47), job(m, 60...89, 1, from: 60)]))
        // A step back / reverse needs frames the running seek skips.
        #expect(RenderLoop.needsPost(last: last, new: [job(m, 30...59, from: 38), job(m, 60...89, 1, from: 60)]))
        #expect(RenderLoop.needsPost(last: last, new: [job(m, 30...59, from: nil), job(m, 60...89, 1, from: 60)]))
        // A different queue.
        #expect(RenderLoop.needsPost(last: last, new: [job(m, 60...89, from: 60)]))
        #expect(!RenderLoop.needsPost(last: [job(m, 0...29, from: nil)], new: [job(m, 0...29, from: 10)]))
    }

    @Test func reverseMissNeedsTheWholeGop() {
        #expect(RenderLoop.missNeededFrom(45, reverse: false) == 45)
        #expect(RenderLoop.missNeededFrom(45, reverse: true) == nil)
    }

    @Test func widens() {
        #expect(DecodeScheduler.widens(5, 15))
        #expect(DecodeScheduler.widens(nil, 15))
        #expect(!DecodeScheduler.widens(20, 15))
        #expect(!DecodeScheduler.widens(15, 15))
        #expect(!DecodeScheduler.widens(5, nil))
    }

    @Test func runningSeekJobRestartsWhenEarlierFramesAreNeeded() async throws {
        let gate = OpenGate(), log = NeededLog()
        let m = UUID()
        let s = DecodeScheduler(decoder: { RecordingDecoder(media: $0, gate: gate, log: log) }, sink: { _, _ in })
        await s.submit([job(m, 30...59, from: 45)])
        try await until { log.values.count == 1 }
        // Later frame needed: the running job covers it, no restart.
        await s.submit([job(m, 30...59, from: 50)])
        // Earlier frame needed (step back after a seek): restarted from there.
        await s.submit([job(m, 30...59, from: 38)])
        gate.open()
        try await until { log.values.count == 2 }
        await s.waitUntilIdle()
        #expect(log.values == [45, 38])
    }

    @MainActor @Test func pauseStaysOnTheFrameThePhaseLockShowed() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var spec = TestClipSpec(); spec.frameCount = 60; spec.frameDuration = TestClipSpec.fps(30)
        let file = try await TestClipWriter.write(spec)
        let a = UUID(), clock = ManualClock()
        let engine = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [a: try await AVDemuxer(url: file)]),
                                        clock: clock)
        engine.waitsForStartFrame = false
        let clip = Clip(name: "c", media: a, kind: .video, source: TimeRange(start: .zero, duration: fd * 60), start: .zero,
                        mediaDuration: fd * 60)
        engine.setTimeline(Timeline(name: "s", format: SequenceFormat(width: 320, height: 180, frameDuration: fd),
                                    tracks: [Track(kind: .video, clips: [clip])]))
        engine.seek(to: .zero)
        await engine.waitForDecodes()
        engine.play()
        // 60 Hz ticks exactly on the frame boundaries: the lock moves the sampled position off them.
        for _ in 0..<30 { clock.advance(by: Time(1, 60)); _ = engine.tick(); await engine.waitForDecodes() }
        let offset = engine.loop.phaseOffset
        #expect(offset > .zero)
        // Clock 7/8 into frame 15: the lock shows frame 16 already.
        clock.advance(by: Time(7, 240))
        _ = engine.tick()
        await engine.waitForDecodes()
        #expect(engine.position == fd * 16)
        engine.pause()
        #expect(clock.now() == fd * 16, "pause lands on the shown frame, not the one before")
    }
}

private func until(_ cond: () -> Bool) async throws {
    let end = ContinuousClock.now + .seconds(5)
    while !cond() {
        guard ContinuousClock.now < end else { Issue.record("timed out"); return }
        try await Task.sleep(for: .milliseconds(2))
    }
}

private final class OpenGate: Sendable {
    private let released = Mutex(false)
    func open() { released.withLock { $0 = true } }
    func wait() async { while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(2)) } }
}

private final class NeededLog: Sendable {
    private let m = Mutex<[Int?]>([])
    func add(_ v: Int?) { m.withLock { $0.append(v) } }
    var values: [Int?] { m.withLock { $0 } }
}

private struct RecordingDecoder: VideoDecoding {
    let media: UUID, gate: OpenGate, log: NeededLog
    var info: VideoTrackInfo { VideoTrackInfo(width: 2, height: 2, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false) }
    var isHardware: Bool { false }
    func invalidate() {}
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        try await decode(range, neededFrom: nil, deliver: { _ in })
    }
    func decode(_ range: ClosedRange<Int>, neededFrom: Int?,
                deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        log.add(neededFrom)
        await gate.wait()
        try Task.checkCancellation()
        return try range.map { i in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pb)
            return DecodedFrame(media: media, pts: fd * Int64(i), duration: fd, pixelBuffer: try #require(pb))
        }
    }
}
