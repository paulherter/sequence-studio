import Testing
import Foundation
import Synchronization
import CoreVideo
import SQCore
import SQMedia
@testable import SQPlayback

private let fd = Time(1, 30)

private final class Probe: Sendable {
    struct State {
        var inflight: [UUID: Int] = [:], maxPerMedia = 0, total = 0, maxTotal = 0
        var started: [UUID] = [], cancelled: [UUID] = [], calls = 0, released = false
        /// Media whose decodes may finish while `released` is false.
        var releasedMedia: Set<UUID> = []
        /// (decoder instance, first frame) of every decode, in start order.
        var decodes: [(decoder: Int, first: Int)] = []
        /// Decodes starting at one of these frames hold until removed (also after `released`).
        var blockedFirst: Set<Int> = []
    }
    let state = Mutex(State())
    func begin(_ m: UUID) { state.withLock { $0.calls += 1; $0.started.append(m); $0.inflight[m, default: 0] += 1
        $0.maxPerMedia = max($0.maxPerMedia, $0.inflight[m]!); $0.total += 1; $0.maxTotal = max($0.maxTotal, $0.total) } }
    func end(_ m: UUID, cancelled: Bool) { state.withLock { $0.inflight[m, default: 1] -= 1; $0.total -= 1; if cancelled { $0.cancelled.append(m) } } }
    var released: Bool { state.withLock { $0.released } }
    func released(_ m: UUID) -> Bool { state.withLock { $0.released || $0.releasedMedia.contains(m) } }
    func release() { state.withLock { $0.released = true } }
    func release(_ m: UUID) { state.withLock { _ = $0.releasedMedia.insert(m) } }
    func snapshot() -> State { state.withLock { $0 } }
    func blocks(_ first: Int) -> Bool { state.withLock { $0.blockedFirst.contains(first) } }
    func block(_ first: Int) { state.withLock { _ = $0.blockedFirst.insert(first) } }
    func unblock(_ first: Int) { state.withLock { _ = $0.blockedFirst.remove(first) } }
}

private struct FakeDecoder: VideoDecoding {
    let media: UUID, probe: Probe, failing: Bool
    /// Serial number of the decoder instance (factory call order), recorded per decode as (instance, first frame).
    var serial = 0
    var info: VideoTrackInfo { VideoTrackInfo(width: 2, height: 2, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false) }
    var isHardware: Bool { false }
    func invalidate() {}
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        probe.begin(media)
        probe.state.withLock { $0.decodes.append((serial, range.lowerBound)) }
        do {
            while !probe.released(media) || probe.blocks(range.lowerBound) { try await Task.sleep(for: .milliseconds(2)) }
        } catch { probe.end(media, cancelled: true); throw error }
        probe.end(media, cancelled: false)
        if failing { throw MediaError.truncated }
        return try range.map { i in
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pb)
            return DecodedFrame(media: media, pts: fd * Int64(i), duration: fd, pixelBuffer: try #require(pb))
        }
    }
}

private final class Results: Sendable {
    let jobs = Mutex<[PrefetchPlanner.Job]>([])
    let frames = Mutex<[Int]>([])
    let errors = Mutex<[PrefetchPlanner.Job]>([])
}

private func job(_ m: UUID, _ first: Int, prio: Int = 0) -> PrefetchPlanner.Job {
    .init(media: m, frames: first...(first + 14), priority: prio)
}

private func eventually(_ what: String = "", _ cond: @Sendable () -> Bool) async {
    for _ in 0..<1000 { if cond() { return }; try? await Task.sleep(for: .milliseconds(2)) }
    Issue.record("timeout waiting for \(what)")
}

/// Counts decoder instances the factory made.
private final class Made: Sendable {
    private let n = Mutex(0)
    var count: Int { n.withLock { $0 } }
    func next() -> Int { n.withLock { $0 += 1; return $0 } }
}

private func make(_ probe: Probe, _ r: Results, max: Int = 4, lanes: Int = 1, failing: Set<UUID> = [],
                  made: Made = Made(), spareLinger: Duration = .seconds(1)) -> DecodeScheduler {
    DecodeScheduler(maxConcurrent: max, lanesPerMedia: lanes, spareLaneLinger: spareLinger,
        decoder: { m in FakeDecoder(media: m, probe: probe, failing: failing.contains(m), serial: made.next()) },
        sink: { j, f in r.jobs.withLock { $0.append(j) }; r.frames.withLock { $0.append(f.count) } },
        onError: { j, _ in r.errors.withLock { $0.append(j) } })
}

@Suite struct DecodeSchedulerTests {
    @Test func softwareDecoderCapEvictsIdleSessions() async {
        // Weak Mac: at most 2 live software decoders. Six stacked layers decode one after the other; idle sessions go.
        let probe = Probe(), r = Results(), made = Made()
        let s = DecodeScheduler(maxConcurrent: 1, idleDecoders: 8, maxSoftwareDecoders: 2,
            decoder: { m in FakeDecoder(media: m, probe: probe, failing: false, serial: made.next()) },
            sink: { j, f in r.jobs.withLock { $0.append(j) } })
        probe.release()
        let media = (0..<6).map { _ in UUID() }
        await s.submit(media.enumerated().map { job($1, 0, prio: $0) })
        await s.waitUntilIdle()
        #expect(r.jobs.withLock { $0.count } == 6)
        #expect(await s.decoderCount <= 2)
        // Uncapped (default) keeps them, as before.
        let r2 = Results(), made2 = Made()
        let s2 = DecodeScheduler(maxConcurrent: 1, idleDecoders: 8,
            decoder: { m in FakeDecoder(media: m, probe: probe, failing: false, serial: made2.next()) },
            sink: { j, _ in r2.jobs.withLock { $0.append(j) } })
        await s2.submit(media.enumerated().map { job($1, 0, prio: $0) })
        await s2.waitUntilIdle()
        #expect(await s2.decoderCount == 6)
    }

    /// The cap never closes the idle decoder of a layer whose next GOP is queued: more software layers than the cap
    /// keep one decoder each while their runs continue (no new session per GOP, no reseek).
    @Test(arguments: [(2, 1), (3, 2)])
    func softwareDecoderCapKeepsContinuingRuns(layers: Int, cap: Int) async {
        let probe = Probe(), r = Results(), made = Made()
        let s = DecodeScheduler(maxConcurrent: layers, idleDecoders: 8, maxSoftwareDecoders: cap,
            decoder: { m in FakeDecoder(media: m, probe: probe, failing: false, serial: made.next()) },
            sink: { j, _ in r.jobs.withLock { $0.append(j) } })
        probe.release()
        let media = (0..<layers).map { _ in UUID() }
        let gops = [0, 15, 30, 45, 60, 75]
        await s.submit(gops.enumerated().flatMap { g, first in
            media.enumerated().map { l, m in job(m, first, prio: g * layers + l) }
        })
        await s.waitUntilIdle()
        #expect(r.jobs.withLock { $0.count } == layers * gops.count)
        #expect(made.count == layers)
        #expect(await s.decoderCount <= cap)       // done: idle ones beyond the cap are closed
    }

    /// Review 6: continuing runs keep their idle decoders beyond the cap only up to a hard ceiling (`cap + 1`): four
    /// software layers on a cap-2 Mac hold three sessions, not four, while their next GOPs are queued.
    @Test func softwareDecoderCeilingBoundsContinuingRuns() async {
        let probe = Probe(), r = Results(), made = Made()
        let (layers, cap) = (4, 2)
        let s = DecodeScheduler(maxConcurrent: 1, idleDecoders: 8, maxSoftwareDecoders: cap,
            decoder: { m in FakeDecoder(media: m, probe: probe, failing: false, serial: made.next()) },
            sink: { j, _ in r.jobs.withLock { $0.append(j) } })
        probe.block(15)
        probe.release()
        let media = (0..<layers).map { _ in UUID() }
        await s.submit([0, 15].enumerated().flatMap { g, first in
            media.enumerated().map { l, m in job(m, first, prio: g * layers + l) }
        })
        await eventually("second GOP started") { probe.snapshot().decodes.contains { $0.first == 15 } }
        #expect(DecodeScheduler.softwareDecoderCeiling(cap: cap) == cap + 1)
        #expect(await s.decoderCount == cap + 1)
        probe.unblock(15)
        await s.waitUntilIdle()
        #expect(r.jobs.withLock { $0.count } == layers * 2)
        #expect(await s.decoderCount <= cap)
    }

    @Test func oneJobInFlightPerMedia() async {
        let probe = Probe(), r = Results(), a = UUID()
        let s = make(probe, r)
        await s.submit([job(a, 0, prio: 0), job(a, 15, prio: 1), job(a, 30, prio: 2)])
        await eventually("first start") { probe.snapshot().calls >= 1 }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(probe.snapshot().calls == 1)
        probe.release()
        await s.waitUntilIdle()
        #expect(probe.snapshot().maxPerMedia == 1)
        #expect(r.jobs.withLock { $0.map(\.frames.lowerBound) } == [0, 15, 30])   // priority order
    }

    @Test func totalInFlightIsCappedAtFour() async {
        let probe = Probe(), r = Results()
        let s = make(probe, r)
        await s.submit((0..<6).map { job(UUID(), 0, prio: $0) })
        await eventually("4 started") { probe.snapshot().calls >= 4 }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(probe.snapshot().calls == 4)
        probe.release()
        await s.waitUntilIdle()
        #expect(probe.snapshot().maxTotal == 4)
        #expect(r.jobs.withLock { $0.count } == 6)
    }

    @Test func submitCancelsInFlightJobsNotInTheNewQueue() async {
        let probe = Probe(), r = Results(), a = UUID(), b = UUID(), c = UUID()
        let s = make(probe, r)
        await s.submit([job(a, 0, prio: 0), job(b, 0, prio: 1)])
        await eventually("a+b started") { probe.snapshot().calls >= 2 }
        await s.submit([job(c, 0, prio: 0), job(b, 0, prio: 1)])     // seek: a is dropped, b stays, c is new
        await eventually("c started") { probe.snapshot().started.contains(c) }
        await eventually("a canceled") { probe.snapshot().cancelled.contains(a) }
        #expect(!probe.snapshot().cancelled.contains(b))
        #expect(probe.snapshot().calls == 3)                          // b was not restarted
        probe.release()
        await s.waitUntilIdle()
        let done = r.jobs.withLock { Set($0.map(\.media)) }
        #expect(done == [b, c])
    }

    @Test func newJobForSameMediaWaitsForCancelledOneToFinish() async {
        let probe = Probe(), r = Results(), a = UUID()
        let s = make(probe, r)
        await s.submit([job(a, 0)])
        await eventually("start") { probe.snapshot().calls >= 1 }
        await s.submit([job(a, 150)])
        probe.release()
        await s.waitUntilIdle()
        #expect(probe.snapshot().maxPerMedia == 1)
        #expect(r.jobs.withLock { $0.map(\.frames.lowerBound) }.contains(150))
    }

    @Test func sinkReceivesAllFramesOfTheJob() async {
        let probe = Probe(), r = Results(), a = UUID()
        let s = make(probe, r)
        probe.release()
        await s.submit([job(a, 45)])
        await s.waitUntilIdle()
        #expect(r.frames.withLock { $0 } == [15])
        #expect(r.jobs.withLock { $0.first?.frames } == 45...59)
    }

    @Test func failingJobIsReportedOnceAndNotRetried() async {
        let probe = Probe(), r = Results(), bad = UUID(), good = UUID()
        let s = make(probe, r, failing: [bad])
        probe.release()
        await s.submit([job(bad, 0, prio: 0), job(good, 0, prio: 1)])
        await s.waitUntilIdle()
        #expect(r.errors.withLock { $0.map(\.media) } == [bad])
        #expect(r.jobs.withLock { $0.map(\.media) } == [good])
        await s.submit([job(bad, 0, prio: 0)])
        await s.waitUntilIdle()
        #expect(r.errors.withLock { $0.count } == 1)
        #expect(probe.snapshot().calls == 2)
        await s.resetFailures()
        await s.submit([job(bad, 0)])
        await s.waitUntilIdle()
        #expect(r.errors.withLock { $0.count } == 2)
    }

    @Test func cancelAllStopsEverything() async {
        let probe = Probe(), r = Results(), a = UUID(), b = UUID()
        let s = make(probe, r, max: 1)
        await s.submit([job(a, 0, prio: 0), job(b, 0, prio: 1)])
        await eventually("start") { probe.snapshot().calls >= 1 }
        await s.cancelAll()
        await s.waitUntilIdle()
        probe.release()
        #expect(probe.snapshot().calls == 1)
        #expect(probe.snapshot().cancelled == [a])
        #expect(r.jobs.withLock { $0.isEmpty })
    }

    @Test func dropQueuedKeepsRunningJobsAndDiscardsWaitingOnes() async {
        let probe = Probe(), r = Results(), a = UUID(), b = UUID()
        let s = make(probe, r, max: 1)
        await s.submit([job(a, 0, prio: 0), job(b, 0, prio: 1)])
        await eventually("start") { probe.snapshot().calls >= 1 }
        await s.dropQueued()
        probe.release()
        await s.waitUntilIdle()
        #expect(probe.snapshot().calls == 1)
        #expect(probe.snapshot().cancelled.isEmpty)
        #expect(r.jobs.withLock { $0.map(\.media) } == [a])
    }

    /// Blocking decoder work must not run on the cooperative pool: jobs run on a per-media serial queue.
    @Test func decodeRunsOnDedicatedQueue() async {
        final class Labels: Sendable { let list = Mutex<[String]>([]) }
        struct LabelDecoder: VideoDecoding {
            let labels: Labels
            var info: VideoTrackInfo { VideoTrackInfo(width: 2, height: 2, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false) }
            var isHardware: Bool { false }
            func invalidate() {}
            func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
                let label = String(cString: __dispatch_queue_get_label(nil))
                labels.list.withLock { $0.append(label) }
                return []
            }
        }
        let labels = Labels(), a = UUID()
        let s = DecodeScheduler(decoder: { _ in LabelDecoder(labels: labels) }, sink: { _, _ in })
        await s.submit([job(a, 0)])
        await s.waitUntilIdle()
        let got = labels.list.withLock { $0 }
        #expect(got.count == 1)
        #expect(got.allSatisfy { $0.hasPrefix("SQPlayback.decode.") })
    }

    // MARK: Second decoder per media (two clips of one file at different source positions)

    @Test func secondClipOfSameMediaGetsItsOwnDecoder() async {
        let probe = Probe(), r = Results(), a = UUID(), made = Made()
        let s = make(probe, r, lanes: 2, made: made)
        await s.submit([job(a, 0, prio: 0), job(a, 600, prio: 1)])
        await eventually("both started") { probe.snapshot().calls >= 2 }
        #expect(probe.snapshot().maxPerMedia == 2)
        #expect(made.count == 2)
        probe.release()
        await s.waitUntilIdle()
        #expect(Set(r.jobs.withLock { $0.map(\.frames.lowerBound) }) == [0, 600])
    }

    /// GOPs that follow each other (forward or reverse) are one run: they stay on one decoder, in order.
    @Test func adjacentGopsStayOnOneDecoder() async {
        for order in [[0, 15, 30], [30, 15, 0]] {
            let probe = Probe(), r = Results(), a = UUID(), made = Made()
            let s = make(probe, r, lanes: 2, made: made)
            await s.submit(order.enumerated().map { job(a, $0.element, prio: $0.offset) })
            await eventually("first start") { probe.snapshot().calls >= 1 }
            try? await Task.sleep(for: .milliseconds(40))
            #expect(probe.snapshot().calls == 1)
            probe.release()
            await s.waitUntilIdle()
            #expect(probe.snapshot().maxPerMedia == 1)
            #expect(made.count == 1)
            #expect(r.jobs.withLock { $0.map(\.frames.lowerBound) } == order)
        }
    }

    /// A run's next GOP waits for its own decoder; a GOP elsewhere in the file takes the second one at once.
    @Test func runContinuationWaitsWhileAFarGopStarts() async {
        let probe = Probe(), r = Results(), a = UUID()
        let s = make(probe, r, lanes: 2)
        await s.submit([job(a, 0, prio: 0), job(a, 15, prio: 1), job(a, 600, prio: 2)])
        await eventually("two started") { probe.snapshot().calls >= 2 }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(probe.snapshot().calls == 2)
        #expect(Set(probe.snapshot().decodes.map(\.first)) == [0, 600])
        probe.release()
        await s.waitUntilIdle()
        #expect(r.jobs.withLock { $0.count } == 3)
    }

    /// Only a near job (rank below `maxConcurrent`) opens a second decoder; a far one waits for the media's lane.
    @Test func farJobDoesNotOpenASecondDecoder() async {
        let probe = Probe(), r = Results(), a = UUID(), b = UUID(), made = Made()
        let s = make(probe, r, max: 3, lanes: 2, made: made)
        await s.submit([job(a, 0, prio: 0), job(b, 0, prio: 1), job(b, 15, prio: 2), job(a, 600, prio: 3)])
        await eventually("two started") { probe.snapshot().calls >= 2 }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(probe.snapshot().calls == 2)
        #expect(made.count == 2)
        probe.release()
        await s.waitUntilIdle()
        #expect(r.jobs.withLock { $0.count } == 4)
    }

    @Test func atMostTwoDecodersPerMedia() async {
        let probe = Probe(), r = Results(), a = UUID(), made = Made()
        let s = make(probe, r, lanes: 2, made: made)
        await s.submit([job(a, 0, prio: 0), job(a, 600, prio: 1), job(a, 1200, prio: 2)])
        await eventually("two started") { probe.snapshot().calls >= 2 }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(probe.snapshot().calls == 2)
        probe.release()
        await s.waitUntilIdle()
        #expect(probe.snapshot().maxPerMedia == 2)
        #expect(made.count == 2)
        #expect(r.jobs.withLock { $0.count } == 3)
    }

    /// The next GOP of a run goes to the decoder that decoded the previous one (it continues without a reseek).
    @Test func continuationGoesToTheDecoderThatDecodedThePreviousGop() async {
        let probe = Probe(), r = Results(), a = UUID()
        let s = make(probe, r, lanes: 2)
        probe.release()
        await s.submit([job(a, 0, prio: 0), job(a, 600, prio: 1)])
        await s.waitUntilIdle()
        await s.submit([job(a, 615, prio: 0), job(a, 15, prio: 1)])
        await s.waitUntilIdle()
        let d = Dictionary(probe.snapshot().decodes.map { ($0.first, $0.decoder) }, uniquingKeysWith: { a, _ in a })
        #expect(d[0] != d[600])
        #expect(d[615] == d[600])
        #expect(d[15] == d[0])
    }

    @Test func forgetDropsBothDecodersOfAMedia() async {
        let probe = Probe(), r = Results(), a = UUID()
        let s = make(probe, r, lanes: 2)
        await s.submit([job(a, 0, prio: 0), job(a, 600, prio: 1)])
        await eventually("both started") { probe.snapshot().calls >= 2 }
        await s.forget([a])
        await s.waitUntilIdle()
        #expect(probe.snapshot().cancelled.count == 2)
        #expect(await s.decoderCount == 0)
        #expect(r.jobs.withLock { $0.isEmpty })
    }

    /// A seek within one clip cancels the running GOP: the new GOP waits for that decoder (it returns at once) instead
    /// of opening a second VideoToolbox session.
    @Test func seekInOneClipReusesItsDecoder() async {
        let probe = Probe(), r = Results(), a = UUID(), made = Made()
        let s = make(probe, r, lanes: 2, made: made)
        await s.submit([job(a, 0)])
        await eventually("start") { probe.snapshot().calls >= 1 }
        await s.submit([job(a, 600)])
        await s.submit([job(a, 900)])
        probe.release()
        await s.waitUntilIdle()
        #expect(made.count == 1)
        #expect(probe.snapshot().maxPerMedia == 1)
        #expect(r.jobs.withLock { $0.map(\.frames.lowerBound) } == [900])
    }

    /// The second decoder of a media is released once only one run of it is left (after a short linger), even while
    /// the media stays wanted: each wanted media must not keep two sessions.
    @Test func spareDecoderIsReleasedWhenOneRunIsLeft() async {
        let probe = Probe(), r = Results(), a = UUID()
        let s = make(probe, r, lanes: 2, spareLinger: .milliseconds(30))
        probe.release()
        await s.submit([job(a, 0, prio: 0), job(a, 600, prio: 1)])
        await s.waitUntilIdle()
        #expect(await s.decoderCount == 2)
        await s.submit([job(a, 15, prio: 0)])
        await s.waitUntilIdle()
        for _ in 0..<SQTiming.polls(200) where await s.decoderCount > 1 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await s.decoderCount == 1)
        // The one kept is the one the run continues on.
        let d = Dictionary(probe.snapshot().decodes.map { ($0.first, $0.decoder) }, uniquingKeysWith: { a, _ in a })
        #expect(d[15] == d[0])
    }

    /// A second decoder is not dropped at once when the other clip has no job for a moment.
    @Test func spareDecoderLingers() async {
        let probe = Probe(), r = Results(), a = UUID(), made = Made()
        let s = make(probe, r, lanes: 2, made: made, spareLinger: .seconds(10))
        probe.release()
        await s.submit([job(a, 0, prio: 0), job(a, 600, prio: 1)])
        await s.waitUntilIdle()
        await s.submit([job(a, 15, prio: 0)])
        await s.waitUntilIdle()
        await s.submit([job(a, 30, prio: 0), job(a, 615, prio: 1)])
        await s.waitUntilIdle()
        #expect(made.count == 2)
    }

    /// The "nearest `maxConcurrent`" rule uses the job's rank now (running jobs plus its place in the queue), not the
    /// priority of the last submit: once nearer jobs finished, a far GOP of a busy media may open the second decoder.
    @Test func secondDecoderRankIsTheCurrentOne() async {
        let probe = Probe(), r = Results(), a = UUID(), b = UUID(), c = UUID()
        let s = make(probe, r, max: 3, lanes: 2)
        await s.submit([job(b, 0, prio: 0), job(c, 0, prio: 1), job(a, 0, prio: 2), job(a, 600, prio: 3)])
        await eventually("three started") { probe.snapshot().calls >= 3 }
        #expect(!probe.snapshot().decodes.contains { $0.first == 600 })
        probe.release(b); probe.release(c)
        await eventually("far GOP of a on the second decoder") { probe.snapshot().decodes.contains { $0.first == 600 } }
        #expect(probe.snapshot().inflight[a] == 2)
        probe.release()
        await s.waitUntilIdle()
    }

    /// All-intra media (ProRes) plans one job per frame: a pump over a long queue must stay cheap (it runs on every
    /// finished job).
    @Test func longQueueOfSingleFrameJobsPumpsFast() async {
        let probe = Probe(), r = Results(), a = UUID(), b = UUID()
        let s = make(probe, r, lanes: 2)
        let jobs = (0..<1500).flatMap { i in
            [PrefetchPlanner.Job(media: a, frames: i...i, priority: 2 * i),
             PrefetchPlanner.Job(media: b, frames: i...i, priority: 2 * i + 1)]
        }
        let clock = ContinuousClock()
        let t = clock.now
        for _ in 0..<5 { await s.submit(jobs) }
        #expect(clock.now - t < SQTiming.budget(.milliseconds(500)))
        await s.cancelAll()
        probe.release()
        await s.waitUntilIdle()
    }
}
