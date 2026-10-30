import Foundation
import Testing
@testable import SQCore

/// Preferences > Interface Size as a portable store (the Mac `UIScale` and the Windows theme read the same key).
@Suite struct InterfaceScaleTests {
    func defaults() -> UserDefaults { UserDefaults(suiteName: "sq.test.uiscale.\(UUID().uuidString)")! }

    @Test func missingMeansOneAndValuesAreClamped() {
        let d = defaults()
        #expect(InterfaceScale.load(from: d) == 1)
        InterfaceScale.store(3, in: d)
        #expect(InterfaceScale.load(from: d) == InterfaceScale.steps.last)
        InterfaceScale.store(.nan, in: d)
        #expect(InterfaceScale.load(from: d) == 1)
        InterfaceScale.store(1.25, in: d)
        #expect(d.double(forKey: InterfaceScale.defaultsKey) == 1.25)
    }

    @Test func stepsStopAtTheEnds() {
        #expect(InterfaceScale.stepped(from: 1, delta: 1) == 1.1)
        #expect(InterfaceScale.stepped(from: 1, delta: -1) == 0.9)
        #expect(InterfaceScale.stepped(from: 1.5, delta: 1) == 1.5)
        #expect(InterfaceScale.stepped(from: 0.8, delta: -1) == 0.8)
    }
}
