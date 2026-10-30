import Foundation
import Testing
@testable import SQCore

private let gb: UInt64 = 1 << 30

@Suite struct WorkPoolsTests {
    @Test func poolsAreCappedSeparately() {
        let air = MachineResources(memoryBytes: 8 * gb, cores: 8).limits.pools
        #expect(air == WorkPools(decode: 2, gpu: 1, cpu: 1))
        let big = MachineResources(memoryBytes: 64 * gb, cores: 16).limits.pools
        #expect(big == WorkPools(decode: 4, gpu: 2, cpu: 8))
        let tiny = MachineResources(memoryBytes: 4 * gb, cores: 1).limits.pools
        #expect(tiny.decode == 1 && tiny.gpu == 1 && tiny.cpu == 1)
    }

    @Test func capsNeverDropBelowOne() {
        #expect(WorkPools(decode: 0, gpu: -2, cpu: 0) == WorkPools(decode: 1, gpu: 1, cpu: 1))
    }

    @Test func debugLineOnlyWhenPreferenceIsOn() {
        let suite = "sq.test.workpools.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let p = WorkPools(decode: 4, gpu: 2, cpu: 3)
        #expect(WorkPools.debugLine(for: p, defaults: d) == nil)
        d.set(true, forKey: WorkPools.debugDefaultsKey)
        #expect(WorkPools.debugLine(for: p, defaults: d) == "work pools: decode 4, gpu 2, cpu 3")
    }
}
