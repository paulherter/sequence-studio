import Testing
import Foundation
import SQAudioFX
@testable import SQPlayback

@Suite struct MonitorGainEngineTests {
    @Test func secondDriverDoesNotResetDim() {
        let suite = "sq.test.monitorengine.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        MonitorGain.store(.init(levelDB: -10, dim: true), defaults: d)
        _ = MonitorGainDriver(defaults: d)                               // first engine of the process: launch rules, Dim off
        #expect(!MonitorGain.Setting.current(defaults: d).dim)
        MonitorGain.store(.init(levelDB: -10, dim: true), defaults: d)   // user turns Dim on mid-session
        _ = MonitorGainDriver(defaults: d)                               // a second engine (new project, source monitor)
        let s = MonitorGain.Setting.current(defaults: d)
        #expect(s.dim && s.levelDB == -10)
    }
}
