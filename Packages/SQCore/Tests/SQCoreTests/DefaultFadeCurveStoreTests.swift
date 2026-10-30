import Foundation
import Testing
@testable import SQCore

/// Preferences > Audio > Fade Shape: the stored default curve of a new audio fade, readable by every timeline host.
@Suite struct DefaultFadeCurveStoreTests {
    @Test func storedCurveRoundTripsAndUnknownFallsBackToLinear() {
        let d = UserDefaults(suiteName: "sq.test.fadecurve.store.\(UUID().uuidString)")!
        #expect(DefaultFadeCurve.current(d) == .linear)
        DefaultFadeCurve.set(.sCurve, defaults: d)
        #expect(DefaultFadeCurve.current(d) == .sCurve)
        #expect(d.string(forKey: "sq.audio.defaultFadeCurve") == "sCurve")
        d.set("nonsense", forKey: DefaultFadeCurve.defaultsKey)
        #expect(DefaultFadeCurve.current(d) == .linear)
    }
}
