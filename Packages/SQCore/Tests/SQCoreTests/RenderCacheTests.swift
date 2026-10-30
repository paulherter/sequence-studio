import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

@Suite struct RenderCacheTests {
    let ctx = RenderCacheContext(rendererID: "r1", workingSpace: "rec709")

    private func clip(_ start: Int64, _ len: Int64, media: UUID = UUID(), effects: [ClipEffect] = []) -> Clip {
        Clip(name: "c", media: media, kind: .video, source: TimeRange(start: .zero, duration: s(len)), start: s(start), effects: effects)
    }
    private func timeline(_ tracks: [[Clip]]) -> Timeline {
        Timeline(name: "T", frameDuration: Time(1, 30), tracks: tracks.map { Track(kind: .video, clips: $0) })
    }
    private let blur = ClipEffect(kind: ClipEffect.gaussianBlurKind)

    @Test func splitsAtEveryClipEdgeAndMarksHeavy() {
        let m = UUID()
        let t = timeline([[clip(0, 4, media: m)], [clip(2, 4, media: m, effects: [blur])]])
        let segs = RenderCachePlan.segments(of: t, context: ctx)
        #expect(segs.map { $0.range.start } == [s(0), s(2), s(4)])
        #expect(segs.map { $0.isHeavy } == [false, true, true])
    }

    @Test func rippleKeepsLaterKeysAndEditChangesOnlyItsOwn() {
        let a = UUID(), b = UUID()
        let c0 = clip(0, 3, media: a), c1 = clip(3, 4, media: b, effects: [blur])
        let t1 = timeline([[c0, c1]])
        var moved = c1; moved.start = s(5)
        let t2 = timeline([[c0, moved]])
        let k1 = RenderCachePlan.segments(of: t1, context: ctx).last!.key
        #expect(RenderCachePlan.segments(of: t2, context: ctx).last!.key == k1)
        var edited = c1; edited.effects = []
        let t3 = timeline([[c0, edited]])
        #expect(RenderCachePlan.segments(of: t3, context: ctx).last!.key != k1)
        #expect(RenderCachePlan.segments(of: t3, context: ctx).first!.key == RenderCachePlan.segments(of: t1, context: ctx).first!.key)
    }

    @Test func rendererWorkingSpaceAndMediaStampChangeTheKey() {
        let t = timeline([[clip(0, 3, effects: [blur])]])
        let base = RenderCachePlan.segments(of: t, context: ctx)[0].key
        #expect(RenderCachePlan.segments(of: t, context: RenderCacheContext(rendererID: "r2", workingSpace: "rec709"))[0].key != base)
        #expect(RenderCachePlan.segments(of: t, context: RenderCacheContext(rendererID: "r1", workingSpace: "p3"))[0].key != base)
        let stamped = RenderCacheContext(rendererID: "r1", workingSpace: "rec709", mediaStamp: { _ in "v2" })
        #expect(RenderCachePlan.segments(of: t, context: stamped)[0].key != base)
        #expect(RenderCachePlan.segments(of: t, context: ctx)[0].key == base)
    }

    @Test func indexEvictsLeastRecentlyUsedAndProtectsCurrent() {
        var i = RenderCacheIndex()
        let t0 = Date(timeIntervalSince1970: 1000)
        i.record(key: "a", bytes: 100, duration: s(1), now: t0)
        i.record(key: "b", bytes: 100, duration: s(1), now: t0.addingTimeInterval(10))
        i.record(key: "c", bytes: 100, duration: s(1), now: t0.addingTimeInterval(20))
        i.touch("a", now: t0.addingTimeInterval(30))
        #expect(i.evict(limitBytes: 200) == ["b"])
        #expect(i.evict(limitBytes: 100, protecting: ["a"]) == ["c"])
        #expect(i.contains("a") && !i.contains("c"))
        let gone = i.purge(olderThan: 5, now: t0.addingTimeInterval(100))
        #expect(gone == ["a"] && i.entries.isEmpty)
    }

    @Test func schedulerWaitsThenPicksDroppedFramesThenNearest() {
        let t = timeline([[clip(0, 2, effects: [blur]), clip(2, 2, effects: [blur]), clip(4, 2, effects: [blur]), clip(6, 2)]])
        let segs = RenderCachePlan.segments(of: t, context: ctx)
        let edit = Date(timeIntervalSince1970: 0)
        func next(_ idx: RenderCacheIndex = RenderCacheIndex(), playhead: Int64 = 0, dropped: [Time] = [], playing: Bool = false,
                  throttled: Bool = false, at: Double = 10) -> Time? {
            RenderCacheScheduler.nextJob(segments: segs, index: idx, playhead: s(playhead), droppedFrames: dropped, playing: playing,
                                         throttled: throttled, lastEdit: edit, now: Date(timeIntervalSince1970: at))?.range.start
        }
        #expect(next(at: 0.1) == nil && next(at: 0.5) != nil)
        #expect(next(playing: true) == nil && next(throttled: true) == nil)
        #expect(next() == s(0))
        #expect(next(playhead: 5) == s(4))
        #expect(next(dropped: [s(3)]) == s(2))
        var idx = RenderCacheIndex()
        idx.record(key: segs[0].key, bytes: 1, duration: s(2), now: edit)
        #expect(next(idx) == s(2))
        #expect(idx.cachedSegment(at: s(1), in: segs)?.range.start == s(0))
        #expect(idx.cachedSegment(at: s(3), in: segs) == nil)
    }

    @Test func storeCommitsCapsAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RenderCacheStore(directory: dir, byteCap: 150, disk: .unchecked)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var idx = store.load()
        let t0 = Date(timeIntervalSince1970: 5000)
        for (n, k) in ["a", "b"].enumerated() {
            try Data(repeating: 1, count: 100).write(to: store.fileURL(for: k))
            try store.commit(key: k, duration: s(1), to: &idx, protecting: [], now: t0.addingTimeInterval(Double(n)))
        }
        #expect(!idx.contains("a") && idx.contains("b"))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: "a").path))
        #expect(store.load().contains("b"))
        try FileManager.default.removeItem(at: store.fileURL(for: "b"))
        #expect(!store.load().contains("b"))
        #expect(store.mayWrite(bytes: 1 << 40))
    }
}
