import Testing
import Foundation
import Metal
import Synchronization
import CoreVideo
import SQCore
import SQMedia
import SQMediaTestSupport
@testable import SQPlayback

// W6.6 KeyframeOnlyScrub: while a scrub gesture runs only sync frames are decoded (one-frame jobs that are never canceled
// once running), the exact frame follows on release; decoders hand frames over one by one.

private let fd = Time(1, 30)
private func sec(_ n: Int64, _ d: Int64 = 1) -> Time { Time(n, d) }

/// 30 fps, no B-frames, sync every `gop` frames.
private func index(frames: Int, gop: Int = 15) -> SampleIndex {
    SampleIndex(entries: (0..<frames).map {
        SampleIndex.Entry(pts: fd * Int64($0), dts: fd * Int64($0), duration: fd, isSync: $0 % gop == 0, decodeOrdinal: $0)
    })
}

/// Open GOP: the second GOP's sync sample (decode ordinal 15) is presented at 17, after its leading pictures 15 and 16.
private func openGOPIndex() -> SampleIndex {
    SampleIndex(entries: (0..<30).map { p in
        let ordinal: Int = switch p { case 17: 15; case 15: 16; case 16: 17; default: p }
        return SampleIndex.Entry(pts: fd * Int64(p), dts: fd * Int64(ordinal), duration: fd, isSync: p == 0 || p == 17, decodeOrdinal: ordinal)
    })
}

private func clip(_ media: UUID, start: Time = .zero, dur: Time) -> Clip {
    Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: dur), start: start)
}
private func timeline(_ rows: [[Clip]]) throws -> Timeline {
    var tracks: [Track] = []
    for row in rows { var t = Track(kind: .video); for c in row { try t.overwrite(c) }; tracks.append(t) }
    return Timeline(name: "t", frameDuration: fd, tracks: tracks)
}
private let none: @Sendable (UUID, Int) -> Bool = { _, _ in false }
private let planner = PrefetchPlanner()

@Suite struct KeyframeScrubPlannerTests {
    @Test func requestsOnlyTheSyncFrameAtOrBeforeTheTarget() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(10))]])
        let jobs = planner.scrubJobs(timeline: tl, playhead: fd * 40, indexes: [m: index(frames: 300)], cached: none)
        let want = PrefetchPlanner.Job(media: m, frames: 30...30, priority: 0, finishesWhenDropped: true)
        #expect(jobs == [want])
        // On a sync frame: that frame.
        let on = planner.scrubJobs(timeline: tl, playhead: fd * 45, indexes: [m: index(frames: 300)], cached: none)
        #expect(on.map(\.frames) == [45...45])
    }

    /// Scrub latency: with the drag's velocity (frames per move) the next keyframe in the drag direction is queued behind
    /// the current one, so it is decoded when the playhead enters its GOP.
    @Test func velocityQueuesTheNextKeyframeInTheDragDirection() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(10))]])
        let idx = [m: index(frames: 300)]
        let fwd = planner.scrubJobs(timeline: tl, playhead: fd * 40, indexes: idx, velocity: 4, cached: none)
        #expect(fwd == [PrefetchPlanner.Job(media: m, frames: 30...30, priority: 0, finishesWhenDropped: true),
                        PrefetchPlanner.Job(media: m, frames: 45...45, priority: 1, finishesWhenDropped: true)])
        let back = planner.scrubJobs(timeline: tl, playhead: fd * 40, indexes: idx, velocity: -4, cached: none)
        #expect(back.map(\.frames) == [30...30, 15...15])
        // A fast move skips GOPs: the keyframe where the next move lands.
        let fast = planner.scrubJobs(timeline: tl, playhead: fd * 40, indexes: idx, velocity: 24, cached: none)
        #expect(fast.map(\.frames) == [30...30, 60...60])
        // No velocity: unchanged. Current keyframe cached: only the predicted one. Predicted cached: only the current one.
        #expect(planner.scrubJobs(timeline: tl, playhead: fd * 40, indexes: idx, velocity: 0, cached: none).map(\.frames) == [30...30])
        let curCached = planner.scrubJobs(timeline: tl, playhead: fd * 40, indexes: idx, velocity: 4, cached: { $1 == 30 })
        #expect(curCached == [PrefetchPlanner.Job(media: m, frames: 45...45, priority: 0, finishesWhenDropped: true)])
        #expect(planner.scrubJobs(timeline: tl, playhead: fd * 40, indexes: idx, velocity: 4, cached: { $1 == 45 }).map(\.frames) == [30...30])
        // Past the end of the timeline: nothing predicted.
        #expect(planner.scrubJobs(timeline: tl, playhead: fd * 295, indexes: idx, velocity: 8, cached: none).map(\.frames) == [285...285])
    }

    @Test func nothingWhenTheKeyframeOrTheExactFrameIsCached() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(10))]])
        let idx = [m: index(frames: 300)]
        let keyCached = planner.scrubJobs(timeline: tl, playhead: fd * 40, indexes: idx, cached: { $1 == 30 })
        let exactCached = planner.scrubJobs(timeline: tl, playhead: fd * 40, indexes: idx, cached: { $1 == 40 })
        #expect(keyCached.isEmpty)
        #expect(exactCached.isEmpty)
    }

    @Test func leadingPictureOfAnOpenGOPUsesThePreviousSync() {
        let idx = openGOPIndex()
        let got = [16, 17, 25, 0].map { PrefetchPlanner.scrubFrame(for: $0, in: idx) }
        #expect(got == [0, 17, 17, 0])     // 16 is presented before its GOP's sync (17)
    }

    /// An edit list hides the first two samples (sync 0 and 1 have zero duration); frame 2 is the first one shown.
    private func hiddenSyncIndex() -> SampleIndex {
        SampleIndex(entries: (0..<30).map { p in
            let shown = p >= 2
            return SampleIndex.Entry(pts: shown ? fd * Int64(p - 2) : .zero, dts: fd * Int64(p), duration: shown ? fd : .zero,
                                     isSync: p % 15 == 0, decodeOrdinal: p)
        })
    }

    @Test func syncHiddenByAnEditListScrubsToTheFirstShownFrame() throws {
        let idx = hiddenSyncIndex()
        #expect(idx.entries[0].duration == .zero && idx.entries[0].isSync)
        #expect(PrefetchPlanner.scrubFrame(for: 5, in: idx) == 2)
        #expect(PrefetchPlanner.scrubRange(for: 5, in: idx) == 0...2)
        #expect(PrefetchPlanner.scrubRange(for: 2, in: idx) == 0...2)
        #expect(PrefetchPlanner.scrubRange(for: 20, in: idx) == 15...15)
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(1, 2))]])
        let jobs = planner.scrubJobs(timeline: tl, playhead: fd * 3, indexes: [m: idx], cached: none)
        #expect(jobs.map(\.frames) == [0...2])
        // Shown frame cached: nothing to do (the hidden sync never lands in the cache).
        #expect(planner.scrubJobs(timeline: tl, playhead: fd * 3, indexes: [m: idx], cached: { $1 == 2 }).isEmpty)
    }

    @Test func oneJobPerStackedLayerInLayerOrder() throws {
        let a = UUID(), b = UUID()
        let tl = try timeline([[clip(a, dur: sec(10))], [clip(b, dur: sec(10))]])
        let jobs = planner.scrubJobs(timeline: tl, playhead: fd * 20, indexes: [a: index(frames: 300), b: index(frames: 300, gop: 12)],
                                     cached: none)
        #expect(Set(jobs.map(\.media)) == [a, b])
        #expect(jobs.map(\.priority) == [0, 1])
        let ja = jobs.first(where: { $0.media == a })?.frames, jb = jobs.first(where: { $0.media == b })?.frames
        #expect(ja == 15...15)
        #expect(jb == 12...12)
        #expect(jobs.allSatisfy { $0.finishesWhenDropped })
    }

    @Test func outsideTheTimelineNoJobs() throws {
        let m = UUID()
        let tl = try timeline([[clip(m, dur: sec(1))]])
        let jobs = planner.scrubJobs(timeline: tl, playhead: sec(5), indexes: [m: index(frames: 300)], cached: none)
        #expect(jobs.isEmpty)
    }
}

// MARK: Scheduler

private final class Gate: Sendable {
    let open = Mutex(false)
    let started = Mutex<[ClosedRange<Int>]>([])
    let cancelled = Mutex<[ClosedRange<Int>]>([])
}

private func frame(_ media: UUID, _ i: Int) throws -> DecodedFrame {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pb)
    return DecodedFrame(media: media, pts: fd * Int64(i), duration: fd, pixelBuffer: try #require(pb))
}

/// Delivers the range's first frame at once, then waits for the gate before the rest (frames returned, not delivered).
/// `ignoresCancel`: keeps running like a VT decode that already submitted its sample.
private struct GatedDecoder: VideoDecoding {
    let media: UUID, gate: Gate, progressive: Bool, ignoresCancel: Bool
    var info: VideoTrackInfo { VideoTrackInfo(width: 2, height: 2, codec: "avc1", bitDepth: 8, chroma: "4:2:0", nominalFrameDuration: fd, isVariableFrameRate: false) }
    var isHardware: Bool { false }
    func invalidate() {}
    func decode(_ range: ClosedRange<Int>) async throws -> [DecodedFrame] {
        try await decode(range, deliver: { _ in })
    }
    func decode(_ range: ClosedRange<Int>, deliver: @escaping @Sendable (DecodedFrame) -> Void) async throws -> [DecodedFrame] {
        gate.started.withLock { $0.append(range) }
        let first = try frame(media, range.lowerBound)
        if progressive { deliver(first) }
        while !gate.open.withLock({ $0 }) {
            if Task.isCancelled && !ignoresCancel { gate.cancelled.withLock { $0.append(range) }; throw CancellationError() }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if Task.isCancelled { gate.cancelled.withLock { $0.append(range) } }
        return try range.map { try frame(media, $0) }
    }
}

private final class Sunk: Sendable {
    let batches = Mutex<[(frames: ClosedRange<Int>, pts: [Time])]>([])
    var all: [Time] { batches.withLock { $0.flatMap(\.pts) } }
    var ranges: [ClosedRange<Int>] { batches.withLock { $0.map(\.frames) } }
}

private func eventually(_ what: String = "", _ cond: @Sendable () -> Bool) async {
    for _ in 0..<1000 { if cond() { return }; try? await Task.sleep(for: .milliseconds(2)) }
    Issue.record("timeout waiting for \(what)")
}

private func scheduler(_ gate: Gate, _ sunk: Sunk, progressive: Bool = false, ignoresCancel: Bool = true) -> DecodeScheduler {
    DecodeScheduler(decoder: { GatedDecoder(media: $0, gate: gate, progressive: progressive, ignoresCancel: ignoresCancel) },
                    sink: { j, f in sunk.batches.withLock { $0.append((j.frames, f.map(\.pts))) } })
}

private func key(_ m: UUID, _ f: Int, prio: Int = 0) -> PrefetchPlanner.Job {
    .init(media: m, frames: f...f, priority: prio, finishesWhenDropped: true)
}

@Suite struct KeyframeScrubSchedulerTests {
    @Test func runningKeyframeFinishesAndOnlyTheNewestPositionIsQueued() async {
        let gate = Gate(), sunk = Sunk(), a = UUID()
        let s = scheduler(gate, sunk, ignoresCancel: false)
        await s.submit([key(a, 0)])
        await eventually("first keyframe started") { gate.started.withLock { $0.count } == 1 }
        await s.submit([key(a, 15)])          // drag moves on: 15 queued behind the running 0
        await s.submit([key(a, 30)])          // and on: 15 was never started, 30 replaces it
        gate.open.withLock { $0 = true }
        await s.waitUntilIdle()
        let cancelled = gate.cancelled.withLock { $0 }, started = gate.started.withLock { $0 }
        let sunkRanges = sunk.ranges
        #expect(cancelled.isEmpty)
        #expect(started == [0...0, 30...30])
        #expect(sunkRanges == [0...0, 30...30])   // the running keyframe still lands
    }

    @Test func releaseCancelsARunningGOPJobButNotAKeyframe() async {
        let gate = Gate(), sunk = Sunk(), a = UUID(), b = UUID()
        let s = scheduler(gate, sunk, ignoresCancel: false)
        await s.submit([key(a, 0), .init(media: b, frames: 0...14, priority: 1)])
        await eventually("both started") { gate.started.withLock { $0.count } == 2 }
        await s.submit([.init(media: a, frames: 30...44, priority: 0)])   // release: exact GOP of a
        await eventually("b canceled") { gate.cancelled.withLock { $0 } == [0...14] }
        gate.open.withLock { $0 = true }
        await s.waitUntilIdle()
        let sunkRanges = sunk.ranges
        #expect(sunkRanges == [0...0, 30...44])
    }

    @Test func framesReachTheSinkBeforeTheJobEndsAndOnlyOnce() async {
        let gate = Gate(), sunk = Sunk(), a = UUID()
        let s = scheduler(gate, sunk, progressive: true)
        await s.submit([.init(media: a, frames: 30...44, priority: 0)])
        await eventually("first frame delivered") { sunk.all == [fd * 30] }
        let idle = await s.isIdle
        #expect(!idle)                        // still decoding the rest of the GOP
        gate.open.withLock { $0 = true }
        await s.waitUntilIdle()
        let pts = sunk.all
        #expect(pts.count == 15)
        #expect(Set(pts) == Set((30...44).map { fd * Int64($0) }))
    }

    @Test func framesOfACancelledJobAreDropped() async {
        let gate = Gate(), sunk = Sunk(), a = UUID(), b = UUID()
        let s = scheduler(gate, sunk, progressive: true, ignoresCancel: true)
        await s.submit([.init(media: a, frames: 0...14, priority: 0)])
        await eventually("first frame") { sunk.all.count == 1 }
        await s.submit([.init(media: b, frames: 0...14, priority: 0)])   // a is canceled while running
        gate.open.withLock { $0 = true }
        await s.waitUntilIdle()
        // a: only the frame delivered before the cancel; b: all 15.
        let counts: [Int] = sunk.batches.withLock { b in b.filter { $0.frames == 0...14 }.map { $0.pts.count } }
        #expect(counts.reduce(0, +) == 16)
    }
}

// MARK: Cache placement of scrub frames, decode counter

private struct Cost: CacheCost { var byteCost: Int }

@Suite struct KeyframeScrubCacheTests {
    /// A scrub keyframe before the clip's in-point (or a hold clip's keyframe) has no timeline placement; while it is the
    /// frame on screen it is placed at the playhead, so a full cache does not evict it at once.
    @Test func wantedScrubFrameSurvivesAFullCache() {
        let m = UUID()
        func key(_ s: Int64) -> FrameKey { FrameKey(media: m, pts: Time(s, 1), scale: .full) }
        let base: RenderLoop.Placements = { k in k.pts >= Time(10, 1) ? [k.pts] : [] }     // the clip starts at source 10 s
        let c = FrameCache<Cost>(budgetBytes: 30)
        c.setFocus(playhead: Time(10, 1), direction: 0,
                   placements: RenderLoop.scrubPlacements(base, wanted: [key(5)], playhead: Time(10, 1)))
        c.insert(Cost(byteCost: 10), for: key(5))
        for s in [10, 11, 12, 13] as [Int64] { c.insert(Cost(byteCost: 10), for: key(s)) }
        #expect(c.frame(key(5)) != nil)
        // Without the wanted placement the same frame is the first victim.
        let plain = FrameCache<Cost>(budgetBytes: 30)
        plain.setFocus(playhead: Time(10, 1), direction: 0, placements: base)
        plain.insert(Cost(byteCost: 10), for: key(5))
        for s in [10, 11, 12, 13] as [Int64] { plain.insert(Cost(byteCost: 10), for: key(s)) }
        #expect(plain.frame(key(5)) == nil)
    }

    @Test func decodeCounterKeepsOnlyRecentRanges() {
        let c = DecodeCounter()
        for i in 0..<1000 { c.record(i...i) }
        #expect(c.value == 1000)
        #expect(c.ranges.count <= DecodeCounter.keep)
        #expect(c.ranges(since: 990) == (990..<1000).map { $0...$0 })
        #expect(c.ranges(since: 1000).isEmpty)
    }
}

// MARK: Engine (real H.264 clip, GOP 12 with B-frames)

private actor KeyframeClip {
    static let shared = KeyframeClip()
    private var url: URL?
    func get() async throws -> URL {
        if let url { return url }
        var spec = TestClipSpec()
        spec.frameCount = 90
        spec.frameDuration = TestClipSpec.fps(30)
        let u = try await TestClipWriter.write(spec)
        url = u
        return u
    }
}

@Suite(.serialized) @MainActor struct KeyframeScrubEngineTests {
    private func rig(blendAtHalfSpeed: Bool = false) async throws -> (PlaybackEngine, SampleIndex, UUID) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let demuxer = try await AVDemuxer(url: try await KeyframeClip.shared.get())
        let m = UUID()
        let e = try PlaybackEngine(device: device, media: StaticMediaResolver(demuxers: [m: demuxer]), clock: ManualClock())
        var c = Clip(name: "V", media: m, kind: .video, source: TimeRange(start: .zero, duration: fd * 90), start: .zero, mediaDuration: fd * 90)
        if blendAtHalfSpeed { c.speed = ClipSpeed(num: 1, den: 2); c.timeInterpolation = .frameBlend }
        e.setTimeline(Timeline(name: "S", format: SequenceFormat(width: 320, height: 180, frameDuration: fd), tracks: [Track(kind: .video, clips: [c])]))
        return (e, demuxer.index, m)
    }

    /// Ticks until `done` or the decodes are idle twice in a row.
    private func settle(_ e: PlaybackEngine, until done: () -> Bool) async {
        for _ in 0..<SQTiming.polls(50) where !done() {
            _ = e.tick()
            await e.waitForDecodes()
        }
        _ = e.tick()
    }

    @Test func dragDecodesOnlyKeyframesAndReleaseDecodesTheExactFrame() async throws {
        let (e, idx, m) = try await rig()
        e.seek(to: .zero)
        await settle(e) { e.stats.stepLatencies.count == 1 }
        let target = (40..<idx.count).first { !idx.entries[$0].isSync && !idx.entries[$0 - 1].isSync }!
        let key = PrefetchPlanner.scrubFrame(for: target, in: idx)
        #expect(key < target)

        let before = e.decodeCalls
        e.beginScrub()
        e.scrub(to: idx.entries[target].pts)
        await settle(e) { e.stats.scrubLatencies.count == 1 }
        let dragRanges = e.decodeRanges(since: before)
        #expect(dragRanges == [key...key])                    // one keyframe, nothing else (no paused window)
        #expect(e.stats.scrubLatencies.count == 1)
        #expect(e.cachedFrame(media: m, pts: idx.entries[target].pts) == false)

        let mark = e.decodeCalls
        let steps = e.stats.stepLatencies.count
        e.endScrub()
        await settle(e) { e.stats.stepLatencies.count > steps }
        #expect(e.stats.stepLatencies.count == steps + 1)       // the exact frame was composited
        #expect(e.decodeRanges(since: mark).contains { $0.contains(target) })
        #expect(e.cachedFrame(media: m, pts: idx.entries[target].pts))
        #expect(e.position == idx.entries[target].pts)
    }

    @Test func scrubBackToAShownKeyframeNeedsNoDecode() async throws {
        let (e, idx, _) = try await rig()
        e.prefetchesScrubDirection = false                   // only the playhead's keyframes (no next one in drag direction)
        e.seek(to: .zero)
        await settle(e) { e.stats.stepLatencies.count == 1 }
        e.beginScrub()
        e.scrub(to: idx.entries[50].pts)
        await settle(e) { e.stats.scrubLatencies.count == 1 }
        e.scrub(to: idx.entries[80].pts)
        await settle(e) { e.stats.scrubLatencies.count == 2 }
        let mark = e.decodeCalls
        e.scrub(to: idx.entries[50].pts)
        await settle(e) { e.stats.scrubLatencies.count == 3 }
        #expect(e.decodeCalls == mark)
        #expect(e.stats.scrubLatencies.count == 3)
        e.endScrub()
    }

    /// Frame Blending needs the next source frame too; a scrub shows the keyframe alone and must not request it.
    @Test func frameBlendClipDragStillDecodesOnlyTheKeyframe() async throws {
        let (e, idx, _) = try await rig(blendAtHalfSpeed: true)
        e.seek(to: .zero)
        await settle(e) { e.stats.stepLatencies.count == 1 }
        let target = (40..<idx.count - 1).first { !idx.entries[$0].isSync && !idx.entries[$0 - 1].isSync && !idx.entries[$0 + 1].isSync }!
        let key = PrefetchPlanner.scrubFrame(for: target, in: idx)
        let before = e.decodeCalls
        e.beginScrub()
        e.scrub(to: idx.entries[target].pts * 2 + fd)          // half speed: source = target + half a frame
        await settle(e) { e.stats.scrubLatencies.count == 1 }
        for _ in 0..<5 { _ = e.tick(); await e.waitForDecodes() }
        #expect(e.decodeRanges(since: before) == [key...key])
        e.endScrub()
    }

    @Test func stepAndSeekOutsideAScrubStayExact() async throws {
        let (e, idx, m) = try await rig()
        e.seek(to: idx.entries[40].pts)
        await settle(e) { e.stats.stepLatencies.count == 1 }
        #expect(e.decodeRanges(since: 0).contains { $0.contains(40) && $0.count > 1 })
        #expect(e.stats.scrubLatencies.isEmpty)
        #expect(e.cachedFrame(media: m, pts: idx.entries[40].pts))
    }
}
