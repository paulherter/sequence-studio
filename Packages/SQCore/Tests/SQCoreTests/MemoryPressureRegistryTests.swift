import Foundation
import Synchronization
import Testing
@testable import SQCore

private let gb: UInt64 = 1 << 30

private final class Recorder: Sendable {
    let levels = Mutex<[MemoryPressure]>([])
    func record(_ l: MemoryPressure) { levels.withLock { $0.append(l) } }
    var all: [MemoryPressure] { levels.withLock { $0 } }
}

@Suite struct MemoryPressureRegistryTests {
    @Test func postReachesEveryLiveRegistration() {
        let reg = MemoryPressureRegistry()
        let a = Recorder(), b = Recorder()
        let ta = reg.register("frame cache") { a.record($0) }
        let tb = reg.register("posters") { b.record($0) }
        reg.post(.warning)
        reg.post(.critical)
        #expect(a.all == [.warning, .critical])
        #expect(b.all == [.warning, .critical])
        #expect(reg.level == .critical)
        #expect(Set(reg.registeredNames) == ["frame cache", "posters"])
        _ = (ta, tb)
    }

    @Test func droppedOrCancelledTokenStopsDelivery() {
        let reg = MemoryPressureRegistry()
        let a = Recorder(), b = Recorder()
        var ta: MemoryPressureToken? = reg.register("a") { a.record($0) }
        let tb = reg.register("b") { b.record($0) }
        ta = nil
        tb.cancel()
        reg.post(.warning)
        #expect(a.all.isEmpty && b.all.isEmpty)
        #expect(reg.registeredNames.isEmpty)
        _ = ta
    }

    @Test func lateRegistrationStartsAtTheCurrentLevel() {
        let reg = MemoryPressureRegistry()
        reg.post(.warning)
        let a = Recorder(), n = Recorder()
        let t = reg.register("late") { a.record($0) }
        #expect(a.all == [.warning])
        reg.post(.normal)
        let tn = reg.register("calm") { n.record($0) }
        #expect(n.all.isEmpty)               // nothing to do at normal
        _ = (t, tn)
    }

    /// A handler may register or post from inside a delivery (no lock held while handlers run).
    @Test func handlersRunOutsideTheLock() {
        let reg = MemoryPressureRegistry()
        let inner = Recorder()
        let box = Mutex<MemoryPressureToken?>(nil)
        let t = reg.register("outer") { _ in
            let tok = reg.register("inner") { inner.record($0) }
            box.withLock { $0 = tok }
        }
        reg.post(.critical)
        #expect(inner.all == [.critical])      // registered while critical: starts at critical
        _ = t
    }

    /// Audit: a `post(.normal)` landing between a registration's level read and its initial delivery must not be
    /// followed by the stale initial level (the cache would stay shrunk).
    @Test func initialLevelNeverArrivesAfterANewerPost() {
        let reg = MemoryPressureRegistry()
        reg.post(.warning)
        let a = Recorder()
        let t = reg.register("late", { a.record($0) }, beforeInitialDelivery: { reg.post(.normal) })
        #expect(a.all == [.normal])
        reg.post(.critical)
        #expect(a.all == [.normal, .critical])
        _ = t
    }

    /// Concurrent posts reach every handler in post order (newest wins: a stale level never arrives last).
    @Test func concurrentPostsEndAtTheLatestLevel() async {
        for _ in 0..<50 {
            let reg = MemoryPressureRegistry()
            let a = Recorder()
            let t = reg.register("cache") { a.record($0) }
            await withTaskGroup(of: Void.self) { g in
                for l in [MemoryPressure.warning, .critical, .warning, .critical] { g.addTask { reg.post(l) } }
            }
            reg.post(.normal)
            #expect(a.all.last == .normal)
            _ = t
        }
    }

    /// A handler may post from inside its own delivery; the nested level is delivered after it, in order.
    @Test func handlerMayPostReentrantly() {
        let reg = MemoryPressureRegistry()
        let a = Recorder()
        let t = reg.register("cache") { l in
            a.record(l)
            if l == .critical { reg.post(.warning) }
        }
        reg.post(.critical)
        #expect(a.all == [.critical, .warning])
        #expect(reg.level == .warning)
        _ = t
    }

    @Test func systemSourceAdapterDeliversThroughTheRegistry() {
        let reg = MemoryPressureRegistry()
        let src = SystemMemoryPressureSource(registry: reg, name: "cache")
        let a = Recorder()
        src.start { a.record($0) }
        reg.post(.warning)
        src.cancel()
        reg.post(.critical)
        #expect(a.all == [.warning])
    }

    @Test func budgetSharesPerLevel() {
        #expect(MemoryPressure.normal.budget(1000) == 1000)
        #expect(MemoryPressure.warning.budget(1000) == 500)
        #expect(MemoryPressure.critical.budget(1000) == 250)
        #expect(MemoryPressure.warning < .critical && MemoryPressure.normal < .warning)
    }
}

@Suite struct WorkLimitsCacheSizeTests {
    @Test func cachesAreHalvedOnlyOnLowMemoryMacs() {
        let air = MachineResources(memoryBytes: 8 * gb, cores: 8).limits
        let pro = MachineResources(memoryBytes: 16 * gb, cores: 10).limits
        let big = MachineResources(memoryBytes: 32 * gb, cores: 10).limits
        // 16 GB and up: the sizes before the audit.
        for l in [pro, big] {
            #expect(l.posterCacheBytes == 64 << 20)
            #expect(l.clipFrameCacheBytes == 48 << 20)
            #expect(l.thumbnailMemoryBytes == 48 << 20)
            #expect(l.waveformCacheBytes == 64 << 20)
        }
        #expect(air.posterCacheBytes == 32 << 20)
        #expect(air.clipFrameCacheBytes == 24 << 20)
        #expect(air.thumbnailMemoryBytes == 24 << 20)
        #expect(air.waveformCacheBytes == 32 << 20)
    }

    @Test func frameCacheAndPoolFollowRAM() {
        let air = MachineResources(memoryBytes: 8 * gb, cores: 8).limits
        let big = MachineResources(memoryBytes: 32 * gb, cores: 10).limits
        let huge = MachineResources(memoryBytes: 64 * gb, cores: 10).limits
        #expect(air.frameCacheBytes == Int(8 * gb / 6))
        #expect(big.frameCacheBytes == Int(8 * gb))
        #expect(huge.frameCacheBytes == Int(8 * gb))
        #expect(MachineResources(memoryBytes: 16 * gb, cores: 8).limits.frameCacheBytes == Int(4 * gb))
        #expect(air.intermediatePoolBytes == 256 << 20)
        #expect(big.intermediatePoolBytes == 1 << 30)
        #expect(MachineResources(memoryBytes: 2 * gb, cores: 2).limits.intermediatePoolBytes == 128 << 20)
    }
}
