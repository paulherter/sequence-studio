import Testing
import Foundation
import SQCore
import SQMedia
@testable import SQPlayback

private let gb: UInt64 = 1 << 30
private struct Cost: CacheCost { var byteCost: Int }
private func k(_ s: Int64) -> FrameKey { FrameKey(media: UUID(), pts: Time(s, 1)) }

@Suite struct MemoryBudgetTests {
    @Test func eightGigabyteMacIsLowMemory() {
        #expect(MemoryBudget(physicalMemory: 8 * gb).isLowMemory)
        #expect(!MemoryBudget(physicalMemory: 16 * gb).isLowMemory)
    }

    @Test func autoFrameCacheScalesWithRAM() {
        // One budget for both monitors together (before: 25 % per engine, two engines = 50 %).
        #expect(MemoryBudget(physicalMemory: 8 * gb).autoFrameCacheBytes == Int(8 * gb / 6))
        #expect(MemoryBudget(physicalMemory: 16 * gb).autoFrameCacheBytes == Int(4 * gb))
        #expect(MemoryBudget(physicalMemory: 32 * gb).autoFrameCacheBytes == Int(8 * gb))
        #expect(MemoryBudget(physicalMemory: 128 * gb).autoFrameCacheBytes == Int(8 * gb))
    }

    @Test func userChoiceIsClampedToHalfOfRAM() {
        let b = MemoryBudget(physicalMemory: 8 * gb)
        #expect(b.frameCacheBytes(userGB: 0) == b.autoFrameCacheBytes)
        #expect(b.frameCacheBytes(userGB: nil) == b.autoFrameCacheBytes)
        #expect(b.frameCacheBytes(userGB: 2) == Int(2 * gb))
        #expect(b.frameCacheBytes(userGB: 16) == Int(4 * gb))
        #expect(MemoryBudget.cacheChoicesGB(for: b) == [1, 2, 4])
        #expect(MemoryBudget.cacheChoicesGB(for: MemoryBudget(physicalMemory: 32 * gb)) == [1, 2, 4, 8, 16])
    }

    @Test func programGetsThreeQuartersSourceTheRest() {
        let s = MemoryBudget.split(1000)
        #expect(s.program == 750 && s.source == 250)
        #expect(s.program + s.source == 1000)
    }

    /// Weak-Mac part 2: the Source monitor at 1/4 (341 MB on 8 GB) dropped 103 of 1574 frames of a 4K 10-bit 4:2:2 clip at
    /// half quality (6 at 683 MB). Only one monitor plays at a time, so on 8 GB Macs the playing one gets the 3/4.
    @Test func playingMonitorGetsTheLargeShareOnLowMemoryMacs() {
        let air = MemoryBudget(physicalMemory: 8 * gb)
        #expect(air.followsPlayingMonitor)
        let s = air.split(1000, playing: .source)
        #expect(s.program == 250 && s.source == 750)
        #expect(air.split(1000, playing: .program) == MemoryBudget.split(1000))
        // Larger Macs keep the fixed 3:1 (a big Program cache is not thrown away for a Source clip).
        let pro = MemoryBudget(physicalMemory: 32 * gb)
        #expect(!pro.followsPlayingMonitor)
        #expect(pro.split(1000, playing: .source) == MemoryBudget.split(1000))
    }

    @Test func intermediatePoolScalesWithRAM() {
        #expect(MemoryBudget(physicalMemory: 8 * gb).intermediatePoolBytes == 256 << 20)
        #expect(MemoryBudget(physicalMemory: 16 * gb).intermediatePoolBytes == 512 << 20)
        #expect(MemoryBudget(physicalMemory: 64 * gb).intermediatePoolBytes == 1 << 30)
        #expect(MemoryBudget(physicalMemory: 1 * gb).intermediatePoolBytes == 128 << 20)
    }

    @Test func idleDecoderSessionsAreFewerOnLowMemory() {
        // Each kept VideoToolbox session holds its reference frames (a 4K 10-bit GOP: hundreds of MB in VTDecoderXPCService).
        #expect(MemoryBudget(physicalMemory: 8 * gb).idleDecoders == 1)
        #expect(MemoryBudget(physicalMemory: 4 * gb).idleDecoders == 1)
        #expect(MemoryBudget(physicalMemory: 16 * gb).idleDecoders == 2)
        #expect(MemoryBudget(physicalMemory: 64 * gb).idleDecoders == 2)
    }

    @Test func autoPreviewQualityIsHalfOnLowMemory() {
        #expect(MemoryBudget(physicalMemory: 8 * gb).autoPreviewQuality == .half)
        #expect(MemoryBudget(physicalMemory: 16 * gb).autoPreviewQuality == .full)
    }

    @Test func environmentSimulatesASmallerMac() {
        #expect(MemoryBudget.current(environment: ["SQ_RAM_GB": "8"], physicalMemory: 64 * gb).physicalMemory == 8 * gb)
        #expect(MemoryBudget.current(environment: ["SQ_RAM_GB": "x"], physicalMemory: 64 * gb).physicalMemory == 64 * gb)
        // Never more than the machine has.
        #expect(MemoryBudget.current(environment: ["SQ_RAM_GB": "128"], physicalMemory: 16 * gb).physicalMemory == 16 * gb)
        #expect(MemoryBudget.current(environment: [:], physicalMemory: 16 * gb).physicalMemory == 16 * gb)
    }
}

@Suite struct MemoryPressurePolicyTests {
    @Test func normalChangesNothing() {
        #expect(PowerPolicy.normal.underMemoryPressure(.normal) == .normal)
    }

    @Test func warningHalvesPreviewAndPausesBackgroundWork() {
        let p = PowerPolicy.normal.underMemoryPressure(.warning)
        #expect(p.decodeScaleCap == .half && p.halvesPrefetch && p.pausesBackgroundJobs)
        #expect(p.viewerScale(.full) == .half)
        #expect(p.viewerScale(.quarter) == .quarter)
    }

    @Test func criticalGoesToQuarter() {
        let p = PowerPolicy.normal.underMemoryPressure(.critical)
        #expect(p.decodeScaleCap == .quarter)
        #expect(p.viewerScale(.half) == .quarter)
    }

    @Test func pressureNeverRaisesAThermalCap() {
        let hot = PowerPolicy(pausesBackgroundJobs: true, decodeScaleCap: .quarter, halvesPrefetch: true)
        #expect(hot.underMemoryPressure(.warning).decodeScaleCap == .quarter)
    }

    @Test func combinedPolicyFollowsTheSettings() {
        let auto = PowerPolicy.combined(power: .normal, memory: .warning, autoQuality: true, backgroundWork: true)
        #expect(auto.decodeScaleCap == .half && auto.pausesBackgroundJobs)
        // Fixed quality: pressure still pauses background work, never changes the picture size.
        let fixed = PowerPolicy.combined(power: .normal, memory: .critical, autoQuality: false, backgroundWork: true)
        #expect(fixed.decodeScaleCap == .full && fixed.pausesBackgroundJobs && !fixed.halvesPrefetch)
        #expect(PowerPolicy.combined(power: .normal, memory: .normal, autoQuality: true, backgroundWork: true) == .normal)
        #expect(PowerPolicy.combined(power: .normal, memory: .normal, autoQuality: false, backgroundWork: false).pausesBackgroundJobs)
    }

    @Test func backgroundWorkOffPausesJobsOnly() {
        let p = PowerPolicy.normal.withBackgroundWork(false)
        #expect(p.pausesBackgroundJobs && p.decodeScaleCap == .full && !p.halvesPrefetch)
        #expect(PowerPolicy.normal.withBackgroundWork(true) == .normal)
    }
}

@Suite struct FrameCacheResizeTests {
    @Test func shrinkingTheBudgetTrimsAtOnce() {
        let c = FrameCache<Cost>(budgetBytes: 100)
        for i in 0..<10 { c.insert(Cost(byteCost: 10), for: k(Int64(i))) }
        #expect(c.usedBytes == 100)
        c.setBudgetBytes(40)
        #expect(c.budgetBytes == 40 && c.usedBytes <= 40)
        c.insert(Cost(byteCost: 30), for: k(99))
        #expect(c.usedBytes <= 40)
    }

    @Test func growingTheBudgetKeepsFrames() {
        let c = FrameCache<Cost>(budgetBytes: 20)
        c.insert(Cost(byteCost: 10), for: k(1))
        c.setBudgetBytes(200)
        #expect(c.budgetBytes == 200 && c.count == 1)
        for i in 2..<12 { c.insert(Cost(byteCost: 10), for: k(Int64(i))) }
        #expect(c.usedBytes == 110)
    }

    @Test func pressureLimitFollowsTheNewBudget() {
        let c = FrameCache<Cost>(budgetBytes: 100)
        c.handleMemoryPressure(.warning)
        #expect(c.effectiveBudgetBytes == 50)
        c.setBudgetBytes(40)
        #expect(c.effectiveBudgetBytes == 20)
        c.handleMemoryPressure(.normal)
        #expect(c.effectiveBudgetBytes == 40)
    }
}
