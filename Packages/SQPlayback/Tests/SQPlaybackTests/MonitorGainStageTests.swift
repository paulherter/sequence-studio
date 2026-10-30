import Testing
import SQAudioFX
@testable import SQPlayback

@Suite struct MonitorGainStageTests {
    private func run(_ stage: MonitorGainStage, _ v: Float, _ n: Int) -> (l: [Float], r: [Float]) {
        var l = [Float](repeating: v, count: n), r = [Float](repeating: v, count: n)
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            stage.process(left: lp.baseAddress!, right: rp.baseAddress!, count: n)
        } }
        return (l, r)
    }

    @Test func fullLevelLeavesTheBlockUntouched() {
        let out = run(MonitorGainStage(), 0.5, 8)
        #expect(out.l == [Float](repeating: 0.5, count: 8) && out.r == out.l)
    }

    @Test func dimRampsOverOneBlockThenHolds() {
        let stage = MonitorGainStage()
        stage.set(MonitorGain.Setting(levelDB: 0, dim: true))
        let target = MonitorGain.Setting(levelDB: 0, dim: true).linear
        let first = run(stage, 1, 4)
        #expect(first.l[0] == 1 && first.l[3] < first.l[0] && first.l[3] > target)   // no jump: a ramp
        #expect(first.r == first.l)
        let second = run(stage, 1, 4)
        #expect(second.l.allSatisfy { abs($0 - target) < 1e-6 })
    }

    @Test func sliderFloorMutes() {
        let stage = MonitorGainStage()
        stage.set(MonitorGain.Setting(levelDB: MonitorGain.minDB, dim: false))
        _ = run(stage, 1, 4)
        #expect(run(stage, 1, 4).l == [0, 0, 0, 0])
    }
}
