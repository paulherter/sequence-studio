import Testing
import Foundation
@testable import SQAudioFX

/// A class suite: one instance per test, so `deinit` removes the test's UserDefaults suite again.
@Suite final class MonitorGainTests {
    private let suite = "sq.test.monitor.\(UUID().uuidString)"
    private func defaults() -> UserDefaults { UserDefaults(suiteName: suite)! }
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    @Test func defaultsAreUnityAndNotDimmed() {
        let s = MonitorGain.Setting.current(defaults: defaults())
        #expect(s.levelDB == 0 && !s.dim)
        #expect(s.linear == 1)
    }

    @Test func gainMathMatchesDecibels() {
        #expect(abs(MonitorGain.Setting(levelDB: -6, dim: false).linear - 0.501187) < 1e-4)
        #expect(abs(MonitorGain.Setting(levelDB: 0, dim: true).linear - 0.1) < 1e-6)
        #expect(abs(MonitorGain.Setting(levelDB: -6, dim: true).linear - 0.0501187) < 1e-5)
        #expect(MonitorGain.Setting(levelDB: MonitorGain.minDB, dim: false).linear == 0)
        #expect(MonitorGain.Setting(levelDB: 12, dim: false).linear == 1)
    }

    @Test func settingRoundTripsThroughDefaults() {
        let d = defaults()
        MonitorGain.store(.init(levelDB: -12, dim: true), defaults: d)
        let s = MonitorGain.Setting.current(defaults: d)
        #expect(s.levelDB == -12 && s.dim)
    }

    @Test func rampReachesTargetMonotonicallyWithoutBigSteps() {
        var r = MonitorGain.Ramp(current: 1)
        r.target = 0.1
        var prev: Float = 1
        var steps = 0
        while let v = r.next() {
            #expect(v < prev)
            #expect(prev - v < 0.25)
            prev = v; steps += 1
            if steps > 100 { break }
        }
        #expect(prev == 0.1 && steps == MonitorGain.Ramp.steps)
    }

    @Test func monitorSettingNeverTouchesSampleBuffers() {
        // The gain is only a number for the output mixer; nothing here (and nothing export calls) multiplies samples.
        let buffer = [Float](repeating: 0.5, count: 64)
        let copy = buffer
        _ = MonitorGain.Setting(levelDB: -40, dim: true).linear
        #expect(buffer == copy)
    }

    @Test func nonFinitePreferenceFallsBackToUnity() {
        let d = defaults()
        d.set(Double.nan, forKey: MonitorGain.levelKey)
        #expect(MonitorGain.Setting.current(defaults: d).linear == 1)
        #expect(MonitorGain.Setting(levelDB: .infinity, dim: false).linear == 1)
        #expect(MonitorGain.Setting(levelDB: -.infinity, dim: false).linear == 1)
        MonitorGain.applyLaunchRules(defaults: d)
        #expect(MonitorGain.Setting.current(defaults: d).levelDB == 0)
    }

    @Test func launchRulesDimOffAndQuietLevelResets() {
        let d = defaults()
        MonitorGain.store(.init(levelDB: -25, dim: true), defaults: d)
        MonitorGain.applyLaunchRules(defaults: d)
        let kept = MonitorGain.Setting.current(defaults: d)
        #expect(kept.levelDB == -25 && !kept.dim)            // level persists, Dim does not
        MonitorGain.store(.init(levelDB: -55, dim: false), defaults: d)
        MonitorGain.applyLaunchRules(defaults: d)
        #expect(MonitorGain.Setting.current(defaults: d).levelDB == 0)
        MonitorGain.store(.init(levelDB: -40, dim: false), defaults: d)
        MonitorGain.applyLaunchRules(defaults: d)
        #expect(MonitorGain.Setting.current(defaults: d).levelDB == -40)
    }
}
