import Testing
import Foundation
import Synchronization
import SQCore
import SQMedia
@testable import SQPlayback

// W6.4: one cache shared by every clip instance of a media, scored per instance; memory-pressure trimming.

private struct Cost: CacheCost, Equatable { var byteCost: Int }
private let m = UUID()
private func s(_ v: Int64) -> Time { Time(v, 1) }
private func k(_ v: Int64) -> FrameKey { FrameKey(media: m, pts: s(v)) }

/// Fires pressure events on demand (tests and the bench); `start`/`cancel` are recorded.
final class ManualPressureSource: MemoryPressureSource {
    private let handler = Mutex<(@Sendable (MemoryPressure) -> Void)?>(nil)
    private let cancelled = Mutex(false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    var isStarted: Bool { handler.withLock { $0 != nil } }
    func start(_ h: @escaping @Sendable (MemoryPressure) -> Void) { handler.withLock { $0 = h } }
    func cancel() { cancelled.withLock { $0 = true }; handler.withLock { $0 = nil } }
    func fire(_ level: MemoryPressure) { handler.withLock { $0 }?(level) }
}

@Suite struct PerInstanceEvictionTests {
    @Test func aFrameIsAsNearAsItsNearestClipInstance() {
        // Source 10 is shown at timeline 10 (V1) and at timeline 0 (V2, offset 10 s): with the playhead at 0 it is needed now.
        let c = FrameCache<Cost>(budgetBytes: 30)
        c.setFocus(playhead: .zero, direction: 1, placements: { key in
            key.pts >= s(10) ? [key.pts, key.pts - s(10)] : [key.pts]
        })
        c.insert(Cost(byteCost: 10), for: k(10))   // instances at 10 and 0 -> distance 0
        c.insert(Cost(byteCost: 10), for: k(3))    // only at 3
        c.insert(Cost(byteCost: 10), for: k(5))    // only at 5
        c.insert(Cost(byteCost: 10), for: k(1))    // forces one eviction: 5 is the farthest
        #expect(c.frame(k(10)) != nil, "the frame V2 shows right now survives although V1 shows it 10 s later")
        #expect(c.frame(k(5)) == nil)
        #expect(c.frame(k(3)) != nil && c.frame(k(1)) != nil)
    }

    @Test func noPlacementMeansUnplaceable() {
        let c = FrameCache<Cost>(budgetBytes: 20)
        c.setFocus(playhead: .zero, direction: 0, placements: { $0.pts == s(1) ? [] : [$0.pts] })
        c.insert(Cost(byteCost: 10), for: k(1))
        c.insert(Cost(byteCost: 10), for: k(50))
        c.insert(Cost(byteCost: 10), for: k(2))
        #expect(c.frame(k(1)) == nil)
        #expect(c.frame(k(50)) != nil && c.frame(k(2)) != nil)
    }

    @Test func cachedRangesShowEveryInstance() {
        let c = FrameCache<Cost>(budgetBytes: 1000)
        for i in 0..<3 { c.insert(Cost(byteCost: 1), for: FrameKey(media: m, pts: Time(Int64(i), 10))) }
        c.setFocus(playhead: .zero, direction: 0, placements: { [$0.pts, $0.pts + s(5)] })
        let r = c.cachedRanges(frameDuration: Time(1, 10))
        #expect(r == [TimeRange(start: .zero, end: Time(3, 10)), TimeRange(start: s(5), end: s(5) + Time(3, 10))])
    }

    @Test func renderLoopPlacesSharedMediaOnEveryTrack() throws {
        // One media on V1 (source 0..20 at 0) and V2 (source 5..25 at 0): source 7 is at timeline 7 (V1) and 2 (V2).
        let fd = Time(1, 30)
        let v1 = Track(kind: .video, clips: [Clip(name: "a", media: m, kind: .video, source: TimeRange(start: s(0), duration: s(20)), start: .zero)], name: "V1")
        let v2 = Track(kind: .video, clips: [Clip(name: "b", media: m, kind: .video, source: TimeRange(start: s(5), duration: s(20)), start: .zero)], name: "V2")
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [v1, v2])
        let p = RenderLoop.placements(tl)
        #expect(Set(p(k(7))) == [s(7), s(2)])
        #expect(p(k(22)) == [s(17)])
        #expect(p(k(30)).isEmpty)
        #expect(RenderLoop.mapping(tl)(k(7)) == s(7), "the single mapping keeps the first instance")
    }

    /// An in point between two source frames (29.97 fps media on a 30 fps timeline): the frame shown at the clip's first
    /// frame starts before the in point. It must count as placed at the clip start, or a full cache drops it as "not on the
    /// timeline" and the first frame of the clip plays without its picture (PLAYBACK-PERF: stale layer at cuts).
    @Test func frameShownAtTheInPointIsPlacedAtTheClipStart() {
        let frame = Time(1, 25)
        let start = Time(51, 100)                       // between frame 12 (0.48 s) and frame 13 (0.52 s)
        let clip = Clip(name: "a", media: m, kind: .video, source: TimeRange(start: start, duration: s(2)), start: s(10))
        let tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip], name: "V1")])
        let shown: @Sendable (UUID, Time) -> Time? = { _, t in frame * t.frameIndex(frameDuration: frame) }
        let p = RenderLoop.placements(tl, shownFrame: shown)
        #expect(p(FrameKey(media: m, pts: frame * 12)) == [s(10)])
        #expect(p(FrameKey(media: m, pts: frame * 11)).isEmpty)
        #expect(p(FrameKey(media: m, pts: frame * 13)) == [clip.timelineTime(forSource: frame * 13)])
        #expect(RenderLoop.placements(tl)(FrameKey(media: m, pts: frame * 12)).isEmpty, "without a frame lookup: as before")
    }
}

@Suite struct PrefetchBudgetTests {
    private let fd = Time(1, 30)
    private func index(frames: Int, gop: Int = 15) -> SampleIndex {
        SampleIndex(entries: (0..<frames).map {
            SampleIndex.Entry(pts: fd * Int64($0), dts: fd * Int64($0), duration: fd, isSync: $0 % gop == 0, decodeOrdinal: $0)
        })
    }
    private func timeline(_ clips: [Clip]) -> Timeline {
        Timeline(name: "t", frameDuration: fd, tracks: clips.map { Track(kind: .video, clips: [$0], name: "V") })
    }
    private let none: @Sendable (UUID, Int) -> Bool = { _, _ in false }

    @Test func windowIsCappedToWhatTheCacheHolds() {
        let tl = timeline([Clip(name: "c", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero)])
        let ix = [m: index(frames: 300)]
        let all = PrefetchPlanner().jobs(timeline: tl, playhead: s(1), rate: .forward, indexes: ix, cached: none)
        #expect(all.count == 6)
        let capped = PrefetchPlanner().jobs(timeline: tl, playhead: s(1), rate: .forward, indexes: ix, cached: none, maxFrames: 40)
        // Nearest first: the GOP under the playhead, then the one just behind (1 frame away); a third would not fit.
        #expect(capped.map(\.frames) == [30...44, 15...29], "two GOPs (30 frames) fit in 40, a third would not")
        // Cached GOPs in the window still occupy the cache: they count against the cap.
        let cachedFirst: @Sendable (UUID, Int) -> Bool = { _, f in (30...44).contains(f) }
        let rest = PrefetchPlanner().jobs(timeline: tl, playhead: s(1), rate: .forward, indexes: ix, cached: cachedFirst, maxFrames: 40)
        #expect(rest.map(\.frames) == [15...29])
    }

    @Test func gopsUnderThePlayheadAreAlwaysPlanned() {
        // Shared media on three tracks at source offsets 0/5/10 s: every layer's current GOP is needed now.
        let clips = (0..<3).map { k in
            Clip(name: "c", media: m, kind: .video, source: TimeRange(start: s(Int64(5 * k)), duration: s(10)), start: .zero)
        }
        let jobs = PrefetchPlanner().jobs(timeline: timeline(clips), playhead: s(1), rate: .forward,
                                          indexes: [m: index(frames: 900)], cached: none, maxFrames: 10)
        #expect(Set(jobs.map(\.frames)) == [30...44, 180...194, 330...344])
    }

    /// Long GOPs (150 frames, 5 s): a GOP counts with the frames the window shows from it, not with all of its frames, or
    /// the next GOP never fits next to the one under the playhead and is only decoded once its first frame is due (a
    /// stale layer at every long-GOP start; PLAYBACK-PERF).
    @Test func nextLongGopFitsNextToTheOneUnderThePlayhead() {
        let tl = timeline([Clip(name: "c", media: m, kind: .video, source: TimeRange(start: .zero, duration: s(30)), start: .zero)])
        let ix = [m: index(frames: 900, gop: 150)]
        let underPlayhead: @Sendable (UUID, Int) -> Bool = { _, f in f < 150 }
        let jobs = PrefetchPlanner().jobs(timeline: tl, playhead: Time(140, 30), rate: .forward, indexes: ix,
                                          cached: underPlayhead, maxFrames: 100)
        #expect(jobs.map(\.frames) == [150...299], "window frames: 25 of GOP 0 + 51 of GOP 1 fit in 100")
    }
}

@Suite struct MemoryPressureTests {
    private func filled(_ src: ManualPressureSource) -> FrameCache<Cost> {
        let c = FrameCache<Cost>(budgetBytes: 100, pressure: src)
        c.setFocus(playhead: .zero, direction: 1)
        for i in 0..<10 { c.insert(Cost(byteCost: 10), for: k(Int64(i))) }
        return c
    }

    @Test func warningTrimsToHalfKeepingFramesNearThePlayhead() {
        let src = ManualPressureSource()
        let c = filled(src)
        #expect(src.isStarted && c.usedBytes == 100)
        src.fire(.warning)
        #expect(c.usedBytes <= 50)
        #expect(c.pressureLimitBytes == 50)
        #expect((0..<5).allSatisfy { c.frame(k(Int64($0))) != nil }, "the nearest frames stay")
        #expect((5..<10).allSatisfy { c.frame(k(Int64($0))) == nil })
    }

    @Test func limitHoldsUntilNormal() {
        let src = ManualPressureSource()
        let c = filled(src)
        src.fire(.warning)
        for i in 0..<10 { c.insert(Cost(byteCost: 10), for: k(Int64(i))) }
        #expect(c.usedBytes <= 50, "prefetch cannot refill past the pressure limit")
        src.fire(.normal)
        #expect(c.pressureLimitBytes == nil)
        for i in 0..<10 { c.insert(Cost(byteCost: 10), for: k(Int64(i))) }
        #expect(c.usedBytes == 100)
    }

    @Test func capacityFollowsThePressureLimit() {
        let src = ManualPressureSource()
        let c = FrameCache<Cost>(budgetBytes: 100, pressure: src)
        #expect(c.capacityFrames == nil)
        c.insert(Cost(byteCost: 10), for: k(0))
        #expect(c.capacityFrames == 9)
        src.fire(.warning)
        #expect(c.capacityFrames == 4 && c.effectiveBudgetBytes == 50)
    }

    @Test func criticalTrimsToAQuarter() {
        let src = ManualPressureSource()
        let c = filled(src)
        src.fire(.critical)
        #expect(c.usedBytes <= 25 && c.pressureLimitBytes == 25)
        #expect(c.frame(k(0)) != nil)
    }

    @Test func sourceIsCancelledWithTheCache() {
        let src = ManualPressureSource()
        do { _ = FrameCache<Cost>(budgetBytes: 10, pressure: src) }
        #expect(src.isCancelled)
    }

    @Test func pressureDuringConcurrentInsertsKeepsTheBudget() async {
        let src = ManualPressureSource()
        let c = FrameCache<Cost>(budgetBytes: 1000, pressure: src)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<6 {
                group.addTask {
                    for i in 0..<400 {
                        c.insert(Cost(byteCost: 10 + t), for: k(Int64((t * 13 + i) % 300)))
                        _ = c.nearest(media: m, atOrBefore: s(Int64(i % 300)), scale: .full)
                        if i % 40 == 0 { c.setFocus(playhead: s(Int64(i % 300)), direction: 1) }
                        #expect(c.usedBytes <= 1000)
                    }
                }
            }
            group.addTask {
                for i in 0..<200 { src.fire(i % 3 == 0 ? .warning : (i % 3 == 1 ? .critical : .normal)) }
            }
        }
        src.fire(.warning)
        #expect(c.usedBytes <= 500)
    }
}
