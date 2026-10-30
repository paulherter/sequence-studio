import Testing
@testable import SQExport

@Suite struct ExportProgressMathTests {
    @Test func noEstimateBeforeEnoughProgress() {
        var t = ExportProgressTracker()
        t.record(progress: 0, at: 0)
        #expect(t.remaining == nil)
        t.record(progress: 0.005, at: 1)   // too early / too little to extrapolate
        #expect(t.remaining == nil)
    }

    @Test func steadyRateGivesExactEstimate() throws {
        var t = ExportProgressTracker()
        for s in 0...20 { t.record(progress: Double(s) / 100, at: Double(s)) }   // 1 % per second
        let r = try #require(t.remaining)
        #expect(abs(r - 80) < 2)
    }

    @Test func smoothingDampsASpike() throws {
        var steady = ExportProgressTracker()
        for s in 0...20 { steady.record(progress: Double(s) / 100, at: Double(s)) }
        let before = try #require(steady.remaining)
        var spiky = steady
        spiky.record(progress: 0.21, at: 22)   // a 2 s stall for 1 % of work
        let after = try #require(spiky.remaining)
        #expect(after > before - 2)            // moved by the real elapsed time, not jumped
        #expect(after < before + 20)
    }

    @Test func progressNeverGoesBackwardsAndClamps() {
        var t = ExportProgressTracker()
        t.record(progress: 0.5, at: 10)
        t.record(progress: 0.3, at: 11)
        #expect(t.progress == 0.5)
        t.record(progress: 1.7, at: 12)
        #expect(t.progress == 1)
        #expect(t.remaining == 0)
    }

    @Test func formatsDurations() {
        #expect(ExportProgressTracker.format(seconds: 0) == "0:00")
        #expect(ExportProgressTracker.format(seconds: 59.4) == "0:59")
        #expect(ExportProgressTracker.format(seconds: 61) == "1:01")
        #expect(ExportProgressTracker.format(seconds: 3725) == "1:02:05")
        #expect(ExportProgressTracker.remainingText(nil) == "Calculating…")
        #expect(ExportProgressTracker.remainingText(75) == "1:15 left")
        #expect(ExportProgressTracker.remainingText(0.2) == "Almost done")
    }

    @Test func phasesFollowProgress() {
        #expect(ExportProgressTracker.phase(progress: 0, running: false) == .preparing)
        #expect(ExportProgressTracker.phase(progress: 0, running: true) == .rendering)
        #expect(ExportProgressTracker.phase(progress: 0.5, running: true) == .rendering)
        #expect(ExportProgressTracker.phase(progress: 0.995, running: true) == .finishing)
        #expect(ExportProgressTracker.Phase.finishing.title == "Finishing")
    }

    @Test func throttleLimitsUpdateRate() {
        var th = ProgressThrottle(minInterval: 0.1)
        let a = th.accept(progress: 0.01, at: 0)
        let b = th.accept(progress: 0.02, at: 0.05)
        let c = th.accept(progress: 0.03, at: 0.11)
        let d = th.accept(progress: 1.0, at: 0.12)     // completion always passes
        #expect(a && !b && c && d)
    }
}
