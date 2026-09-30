import Testing
import Foundation
import Synchronization
import CoreVideo
import SSCore
import SSMedia
@testable import SSPlayback

private let fd = Time(1, 30)

private final class Probe: Sendable {
    struct State {
        var inflight: [UUID: Int] = [:], maxPerMedia = 0, total = 0, maxTotal = 0
        var started: [UUID] = [], cancelled: [UUID] = [], calls = 0, released = false
    }
    let state = Mutex(State())
    func begin(_ m: UUID) { state.withLock { $0.calls += 1; $0.started.append(m); $0.inflight[m, default: 0] += 1
        $0.maxPerMedia = max($0.maxPerMedia, $0.inflight[m]!); $0.total += 1; $0.maxTotal = max($0.maxTotal, $0.total) } }
    func end(_ m: UUID, cancelled: Bool) { state.withLock { $0.inflight[m, default: 1] -= 1; $0.total -= 1; if cancelled { $0.cancelled.append(m) } } }
    var released: Bool { state.withLock { $0.released } }
    func release() { state.withLock { $0.released = true } }
    func snapshot() -> State { state.withLock { $0 } }
}

private struct FakeDecoder: VideoDecoding {
    let media: UUID, probe: Probe, failing: Bool
    var info: VideoTrackInfo { VideoTrackInfo(width: 2, height: 2, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false) }
    var isHardware: Bool { false }
    func invalidate() {}
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        probe.begin(media)
        do {
            while !probe.released { try await Task.sleep(for: .milliseconds(2)) }
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

private func make(_ probe: Probe, _ r: Results, max: Int = 4, failing: Set<UUID> = []) -> DecodeScheduler {
    DecodeScheduler(maxConcurrent: max,
        decoder: { FakeDecoder(media: $0, probe: probe, failing: failing.contains($0)) },
        sink: { j, f in r.jobs.withLock { $0.append(j) }; r.frames.withLock { $0.append(f.count) } },
        onError: { j, _ in r.errors.withLock { $0.append(j) } })
}

@Suite struct DecodeSchedulerTests {
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
        await eventually("a cancelled") { probe.snapshot().cancelled.contains(a) }
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
        #expect(got.allSatisfy { $0.hasPrefix("SSPlayback.decode.") })
    }
}
