import Foundation
import Testing
@testable import SQCore

@Suite struct CacheDiskPolicyTests {
    static let gb: Int64 = 1 << 30

    @Test func floorIsFiveGBOrFivePercent() {
        #expect(CacheDiskPolicy.floorBytes(volumeBytes: 64 * Self.gb) == 5 * Self.gb)
        #expect(CacheDiskPolicy.floorBytes(volumeBytes: 2000 * Self.gb) == 10 * Self.gb)
        #expect(CacheDiskPolicy.floorBytes(volumeBytes: nil) == 5 * Self.gb)
    }

    @Test func floorOf128GBDisk() {
        #expect(CacheDiskPolicy.floorBytes(volumeBytes: 128 * Self.gb) == Int64(Double(128 * Self.gb) * 0.05))
    }

    @Test func allowsOnlyWhileAboveFloorAfterWrite() {
        let p = CacheDiskPolicy(space: { _ in (free: 20 * Self.gb, total: 256 * Self.gb) })
        let url = URL(fileURLWithPath: "/x")
        #expect(p.allowsWrite(bytes: 1 * Self.gb, at: url))
        #expect(!p.allowsWrite(bytes: 11 * Self.gb, at: url))     // 20 - 11 < 10 (floor capped at 10 GB)
    }

    @Test func unknownSpaceAllowsWrite() {
        let p = CacheDiskPolicy(space: { _ in (free: nil, total: nil) })
        #expect(p.allowsWrite(bytes: 100 * Self.gb, at: URL(fileURLWithPath: "/x")))
    }

    @Test func belowFloorBlocksEvenZeroBytes() {
        let p = CacheDiskPolicy(space: { _ in (free: 2 * Self.gb, total: 256 * Self.gb) })
        #expect(p.isBelowFloor(at: URL(fileURLWithPath: "/x")))
        #expect(!p.allowsWrite(bytes: 0, at: URL(fileURLWithPath: "/x")))
    }

    @Test func lruPlanRemovesOldestFirstUntilFits() {
        let d = { (s: Double) in Date(timeIntervalSince1970: s) }
        let entries = [CacheEntry(id: "a", bytes: 4, lastUse: d(3)), CacheEntry(id: "b", bytes: 4, lastUse: d(1)),
                       CacheEntry(id: "c", bytes: 4, lastUse: d(2))]
        #expect(CacheDiskPolicy.evictionPlan(entries, limitBytes: 8, protecting: []) == ["b"])
        #expect(CacheDiskPolicy.evictionPlan(entries, limitBytes: 4, protecting: []) == ["b", "c"])
        #expect(CacheDiskPolicy.evictionPlan(entries, limitBytes: 12, protecting: []).isEmpty)
    }

    @Test func lruPlanSkipsProtected() {
        let d = { (s: Double) in Date(timeIntervalSince1970: s) }
        let entries = [CacheEntry(id: "a", bytes: 4, lastUse: d(1)), CacheEntry(id: "b", bytes: 4, lastUse: d(2))]
        #expect(CacheDiskPolicy.evictionPlan(entries, limitBytes: 4, protecting: ["a"]) == ["b"])
    }
}
