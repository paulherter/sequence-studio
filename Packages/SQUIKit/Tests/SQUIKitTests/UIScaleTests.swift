import Foundation
import Testing
@testable import SQUIKit

@Suite struct UIScaleTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "sq.test.uiscale.\(UUID().uuidString)")!
    }

    @Test func stepsGoUpAndDownAndClamp() {
        #expect(UIScale.stepped(from: 1.0, delta: 1) == 1.1)
        #expect(UIScale.stepped(from: 1.0, delta: -1) == 0.9)
        #expect(UIScale.stepped(from: UIScale.steps.last!, delta: 1) == UIScale.steps.last!)
        #expect(UIScale.stepped(from: UIScale.steps.first!, delta: -1) == UIScale.steps.first!)
        // A value between steps moves to the next step in the direction.
        #expect(UIScale.stepped(from: 1.05, delta: 1) == 1.1)
        #expect(UIScale.stepped(from: 1.05, delta: -1) == 1.0)
    }

    @Test func clampKeepsValueInRange() {
        #expect(UIScale.clamp(5) == UIScale.steps.last!)
        #expect(UIScale.clamp(0.1) == UIScale.steps.first!)
        #expect(UIScale.clamp(.nan) == 1)
    }

    @Test func persistsInDefaults() {
        let d = defaults()
        #expect(UIScale.load(from: d) == 1)
        UIScale.increase(in: d)
        #expect(d.double(forKey: UIScale.defaultsKey) == 1.1)
        UIScale.increase(in: d)
        #expect(UIScale.load(from: d) == 1.25)
        UIScale.decrease(in: d)
        #expect(UIScale.load(from: d) == 1.1)
        UIScale.reset(in: d)
        #expect(UIScale.load(from: d) == 1)
    }

    @Test func scaledRoundsToHalfPoints() {
        #expect(UIScale.scaled(22, by: 1) == 22)
        #expect(UIScale.scaled(22, by: 1.25) == 27.5)
        #expect(UIScale.scaled(11, by: 1.1) == 12)
    }
}

@Suite struct UIScaleLiveTests {
    @Test func tokensFollowTheLiveFactor() {
        let d = UserDefaults.standard
        let saved = d.object(forKey: UIScale.defaultsKey)
        defer { if let saved { d.set(saved, forKey: UIScale.defaultsKey) } else { d.removeObject(forKey: UIScale.defaultsKey) }; UIScale.set(UIScale.load(from: d)) }
        UIScale.set(1)
        let base = Theme.Row.standard, font = Theme.Typography.body.pointSize
        UIScale.set(1.5)
        #expect(UIScale.current == 1.5)
        #expect(Theme.Row.standard == base * 1.5)
        #expect(Theme.Typography.body.pointSize == (font * 1.5 * 2).rounded() / 2)
        UIScale.set(1)
        #expect(Theme.Row.standard == base)
    }
    @Test func rescaleBetweenFactors() {
        #expect(UIScale.rescaled(11, from: 1, to: 1.5) == 16.5)
        #expect(UIScale.rescaled(16.5, from: 1.5, to: 1) == 11)
        #expect(UIScale.ratio(from: 0, to: 2) == 1)
    }
}
