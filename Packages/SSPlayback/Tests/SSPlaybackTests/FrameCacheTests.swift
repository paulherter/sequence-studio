import Testing
import Foundation
import SSCore
import SSMedia
@testable import SSPlayback

private struct Fake: CacheCost, Equatable {
    var id: Int
    var byteCost: Int
}

private let media = UUID()
private func key(_ sec: Int64, _ m: UUID = media, _ s: DecodeScale = .full) -> FrameKey {
    FrameKey(media: m, pts: Time(sec, 1), scale: s)
}

@Suite struct FrameCacheTests {
    @Test func insertAndLookup() {
        let c = FrameCache<Fake>(budgetBytes: 100)
        c.insert(Fake(id: 1, byteCost: 10), for: key(1))
        #expect(c.frame(key(1)) == Fake(id: 1, byteCost: 10))
        #expect(c.frame(key(2)) == nil)
        #expect(c.frame(key(1, media, .half)) == nil)
        #expect(c.usedBytes == 10)
    }

    @Test func reinsertReplacesCost() {
        let c = FrameCache<Fake>(budgetBytes: 100)
        c.insert(Fake(id: 1, byteCost: 10), for: key(1))
        c.insert(Fake(id: 2, byteCost: 30), for: key(1))
        #expect(c.usedBytes == 30)
        #expect(c.count == 1)
    }

    @Test func budgetNeverExceeded() {
        let c = FrameCache<Fake>(budgetBytes: 95)
        for i in 0..<200 {
            c.insert(Fake(id: i, byteCost: 10 + i % 7), for: key(Int64(i)))
            #expect(c.usedBytes <= 95)
        }
        c.setFocus(playhead: Time(50, 1), direction: 1)
        #expect(c.usedBytes <= 95)
    }

    @Test func oversizedPayloadRejected() {
        let c = FrameCache<Fake>(budgetBytes: 50)
        c.insert(Fake(id: 1, byteCost: 20), for: key(1))
        c.insert(Fake(id: 2, byteCost: 51), for: key(2))
        #expect(c.frame(key(2)) == nil)
        #expect(c.frame(key(1)) != nil)
        #expect(c.usedBytes == 20)
    }

    @Test func evictsFarthestFromPlayheadFirst() {
        let c = FrameCache<Fake>(budgetBytes: 40)
        c.setFocus(playhead: Time(10, 1), direction: 0)
        for s in [10, 11, 12, 20] as [Int64] { c.insert(Fake(id: Int(s), byteCost: 10), for: key(s)) }
        // 0 and 20 are both 10 away: tie goes to the older insertion (20).
        c.insert(Fake(id: 0, byteCost: 10), for: key(0))
        #expect(c.frame(key(20)) == nil)
        #expect(c.frame(key(0)) != nil)
        // A new frame that is itself the farthest is the one dropped.
        c.insert(Fake(id: 99, byteCost: 10), for: key(100))
        #expect(c.frame(key(100)) == nil)
        #expect(c.frame(key(10)) != nil && c.frame(key(11)) != nil && c.frame(key(12)) != nil)
    }

    @Test func behindDirectionWeightedDouble() {
        let c = FrameCache<Fake>(budgetBytes: 20)
        c.setFocus(playhead: Time(10, 1), direction: 1)
        c.insert(Fake(id: 1, byteCost: 10), for: key(7))   // behind by 3 -> weight 6
        c.insert(Fake(id: 2, byteCost: 10), for: key(14))  // ahead by 4 -> weight 4
        c.insert(Fake(id: 3, byteCost: 10), for: key(10))  // forces one eviction
        #expect(c.frame(key(7)) == nil)
        #expect(c.frame(key(14)) != nil && c.frame(key(10)) != nil)
    }

    @Test func reverseDirectionFlipsWeighting() {
        let c = FrameCache<Fake>(budgetBytes: 20)
        c.setFocus(playhead: Time(10, 1), direction: -1)
        c.insert(Fake(id: 1, byteCost: 10), for: key(7))   // ahead of reverse play: weight 3
        c.insert(Fake(id: 2, byteCost: 10), for: key(13))  // behind (time greater): weight 6
        c.insert(Fake(id: 3, byteCost: 10), for: key(10))
        #expect(c.frame(key(13)) == nil)
        #expect(c.frame(key(7)) != nil)
    }

    @Test func unmappedKeysEvictedFirst() {
        let c = FrameCache<Fake>(budgetBytes: 30)
        for s in 0..<3 as Range<Int64> { c.insert(Fake(id: Int(s), byteCost: 10), for: key(s)) }
        c.setFocus(playhead: .zero, direction: 0) { $0.pts == Time(1, 1) ? nil : $0.pts }
        c.insert(Fake(id: 10, byteCost: 10), for: key(0, media, .half))
        #expect(c.frame(key(1)) == nil)
        #expect(c.frame(key(0)) != nil)
        #expect(c.usedBytes <= 30)
    }

    @Test func evictsToLowWaterNotEveryInsert() {
        let c = FrameCache<Fake>(budgetBytes: 100)
        #expect(c.lowWaterBytes == 90)
        c.setFocus(playhead: Time(105, 1), direction: 0)   // new frames are near the playhead, so they are kept
        for i in 0..<100 { c.insert(Fake(id: i, byteCost: 1), for: key(Int64(i))) }
        #expect(c.usedBytes == 100)
        #expect(c.evictionPasses == 0)
        for i in 100..<110 { c.insert(Fake(id: i, byteCost: 1), for: key(Int64(i))) }
        // One pass drops to 90 %, the next nine inserts fit without any eviction work.
        #expect(c.evictionPasses == 1)
        #expect(c.usedBytes <= 100)
    }

    @Test func defaultBudgetIsQuarterOfMemoryCappedAt8GB() {
        let gb: UInt64 = 1024 * 1024 * 1024
        #expect(FrameCache<Fake>.defaultBudgetBytes(physicalMemory: 16 * gb) == Int(4 * gb))
        #expect(FrameCache<Fake>.defaultBudgetBytes(physicalMemory: 128 * gb) == Int(8 * gb))
        #expect(FrameCache<Fake>().budgetBytes > 0)
    }

    @Test func nearestSurvivesEvictionAndReplace() {
        let c = FrameCache<Fake>(budgetBytes: 30)
        c.setFocus(playhead: Time(100, 1), direction: 0)
        for s in [1, 50, 90, 95] as [Int64] { c.insert(Fake(id: Int(s), byteCost: 10), for: key(s)) }
        // 1 is farthest and gone; the index must not return it.
        #expect(c.nearest(media: media, atOrBefore: Time(10, 1), scale: .full) == nil)
        c.insert(Fake(id: 7, byteCost: 10), for: key(95))
        #expect(c.nearest(media: media, atOrBefore: Time(200, 1), scale: .full)?.id == 7)
    }

    @Test func nearestAtOrBefore() {
        let c = FrameCache<Fake>(budgetBytes: 1000)
        let other = UUID()
        for s in [0, 2, 4, 6] as [Int64] { c.insert(Fake(id: Int(s), byteCost: 1), for: key(s)) }
        c.insert(Fake(id: 50, byteCost: 1), for: key(5, other))
        c.insert(Fake(id: 60, byteCost: 1), for: key(5, media, .half))
        #expect(c.nearest(media: media, atOrBefore: Time(5, 1), scale: .full)?.id == 4)
        #expect(c.nearest(media: media, atOrBefore: Time(4, 1), scale: .full)?.id == 4)
        #expect(c.nearest(media: media, atOrBefore: Time(1, 2), scale: .full)?.id == 0)
        #expect(c.nearest(media: media, atOrBefore: Time(-1, 1), scale: .full) == nil)
        #expect(c.nearest(media: other, atOrBefore: Time(9, 1), scale: .full)?.id == 50)
        #expect(c.nearest(media: media, atOrBefore: Time(9, 1), scale: .half)?.id == 60)
    }

    @Test func rationalKeysAreExact() {
        let c = FrameCache<Fake>(budgetBytes: 100)
        let fd = Time(1001, 30000)
        c.insert(Fake(id: 1, byteCost: 1), for: FrameKey(media: media, pts: fd * 3))
        #expect(c.frame(FrameKey(media: media, pts: Time(3003, 30000)))?.id == 1)
        #expect(c.frame(FrameKey(media: media, pts: Time(6006, 60000)))?.id == 1)
    }

    @Test func concurrentInsertLookupFromEightTasks() async {
        let c = FrameCache<Fake>(budgetBytes: 500)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for i in 0..<500 {
                        let s = Int64((t * 7 + i) % 200)
                        c.insert(Fake(id: i, byteCost: 10 + t), for: key(s))
                        _ = c.frame(key(s))
                        _ = c.nearest(media: media, atOrBefore: Time(s, 1), scale: .full)
                        if i % 50 == 0 { c.setFocus(playhead: Time(Int64(i % 200), 1), direction: t % 2 == 0 ? 1 : -1) }
                        #expect(c.usedBytes <= 500)
                    }
                }
            }
        }
        #expect(c.usedBytes <= 500)
    }
}
