import Foundation
import Testing
import SQCore
import SQMedia
@testable import SQPlayback

/// Q-PERF2 rec 3: thermal / Low Power policy (pure).
@Suite struct PowerPolicyTests {
    @Test func nominalIsNormal() {
        #expect(PowerPolicy(thermal: .nominal, lowPower: false) == .normal)
        #expect(!PowerPolicy.normal.pausesBackgroundJobs)
        #expect(PowerPolicy.normal.decodeScaleCap == .full)
        #expect(!PowerPolicy.normal.halvesPrefetch)
    }

    @Test func fairPausesBackgroundJobsOnly() {
        let p = PowerPolicy(thermal: .fair, lowPower: false)
        #expect(p.pausesBackgroundJobs)
        #expect(p.decodeScaleCap == .full)
        #expect(!p.halvesPrefetch)
    }

    @Test func lowPowerModeActsLikeFair() {
        #expect(PowerPolicy(thermal: .nominal, lowPower: true) == PowerPolicy(thermal: .fair, lowPower: false))
    }

    @Test func seriousHalvesDecodeAndPrefetch() {
        let p = PowerPolicy(thermal: .serious, lowPower: false)
        #expect(p.pausesBackgroundJobs)
        #expect(p.decodeScaleCap == .half)
        #expect(p.halvesPrefetch)
        #expect(PowerPolicy(thermal: .critical, lowPower: true) == p)
    }

    @Test func viewerScaleNeverRaisesTheUsersChoice() {
        let serious = PowerPolicy(thermal: .serious, lowPower: false)
        #expect(serious.viewerScale(.full) == .half)
        #expect(serious.viewerScale(.half) == .half)
        #expect(serious.viewerScale(.quarter) == .quarter)
        #expect(PowerPolicy.normal.viewerScale(.quarter) == .quarter)
        #expect(PowerPolicy.normal.viewerScale(.full) == .full)
    }

    @Test func prefetchLookaheadHalved() {
        let base = PrefetchPlanner()
        #expect(PowerPolicy.normal.planner(base).lookahead == base.lookahead)
        let p = PowerPolicy(thermal: .serious, lowPower: false).planner(base)
        #expect(p.lookahead == Time(1, 1))
        #expect(p.behind == base.behind)
        #expect(p.pausedRadius == base.pausedRadius)
    }

    @Test func thermalLevelFromProcessInfo() {
        #expect(ThermalLevel(ProcessInfo.ThermalState.nominal) == .nominal)
        #expect(ThermalLevel(ProcessInfo.ThermalState.fair) == .fair)
        #expect(ThermalLevel(ProcessInfo.ThermalState.serious) == .serious)
        #expect(ThermalLevel(ProcessInfo.ThermalState.critical) == .critical)
    }

    @Test func environmentOverride() {
        #expect(ThermalLevel(environment: ["SQ_THERMAL": "serious"]) == .serious)
        #expect(ThermalLevel(environment: ["SQ_THERMAL": "FAIR"]) == .fair)
        #expect(ThermalLevel(environment: ["SQ_THERMAL": "bogus"]) == nil)
        #expect(ThermalLevel(environment: [:]) == nil)
    }
}
