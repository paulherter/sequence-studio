import Foundation
import Testing
@testable import SQCore

/// Keyframe control of the Color panel (INTERACTION-AUDIT §2): animate / stop / add-remove key / navigate for one
/// slider or one wheel group (its hue, amount and luma parameters move together).
@Suite struct ColorKeyframingTests {
    typealias K = ClipEffect
    static let exposure = [K.colorExposureKey]
    static let midtones = [K.colorWheelMidtonesHueKey, K.colorWheelMidtonesAmountKey, K.colorWheelMidtonesLumaKey]

    static func graded(exposure: Float = 1.5) -> Clip {
        var c = ColorGradeEffectTests.picture()
        var color = ClipColor()
        color.effects[0].basic.exposure = exposure
        c.color = color
        return c
    }

    /// Runs a mutating call outside the `#expect` macro (it cannot capture `inout`).
    static func run(_ c: inout Clip, _ body: (inout Clip) -> Bool) -> Bool { body(&c) }

    @Test func staticGroupIsNotAnimated() {
        let c = Self.graded()
        #expect(!c.isColorAnimated(effect: 1, keys: Self.exposure))
        #expect(c.colorKeyTimes(effect: 1, keys: Self.exposure).isEmpty)
    }

    @Test func animateAddsOneKeyAtTheTimeWithTheShownValue() {
        var c = Self.graded()
        let t = Time(1, 1)
        #expect(Self.run(&c) { $0.setColorAnimated(true, effect: 1, keys: Self.exposure, atLocal: t) })
        #expect(c.isColorAnimated(effect: 1, keys: Self.exposure))
        #expect(c.colorKeyTimes(effect: 1, keys: Self.exposure) == [t])
        #expect(c.color(atLocal: Time(3, 1)).effects[0].basic.exposure == 1.5)
    }

    @Test func animateWithoutAPlayheadOnTheClipIsRefused() {
        var c = Self.graded()
        let before = c
        #expect(!Self.run(&c) { $0.setColorAnimated(true, effect: 1, keys: Self.exposure, atLocal: nil) })
        #expect(c == before)
    }

    @Test func stopAnimatingKeepsTheValueAtTheTime() {
        var c = Self.graded(exposure: 0)
        #expect(Self.run(&c) { $0.setColorAnimated(true, effect: 1, keys: Self.exposure, atLocal: .zero) })
        #expect(Self.run(&c) { $0.toggleColorKey(effect: 1, keys: Self.exposure, atLocal: Time(2, 1)) })
        // Edit the second key: exposure ramps 0 -> 2 over two seconds.
        c.setColor({ var x = c.color(atLocal: Time(2, 1)); x.effects[0].basic.exposure = 2; return x }(),
                   editedFrom: c.color(atLocal: Time(2, 1)), atLocal: Time(2, 1))
        #expect(Self.run(&c) { $0.setColorAnimated(false, effect: 1, keys: Self.exposure, atLocal: Time(1, 1)) })
        #expect(!c.isColorAnimated(effect: 1, keys: Self.exposure))
        #expect(c.color.effects[0].basic.exposure == 1)
    }

    @Test func toggleKeyAddsThenRemoves() {
        var c = Self.graded()
        #expect(Self.run(&c) { $0.setColorAnimated(true, effect: 1, keys: Self.exposure, atLocal: .zero) })
        let t = Time(2, 1)
        #expect(!c.hasColorKey(effect: 1, keys: Self.exposure, atLocal: t))
        #expect(Self.run(&c) { $0.toggleColorKey(effect: 1, keys: Self.exposure, atLocal: t) })
        #expect(c.hasColorKey(effect: 1, keys: Self.exposure, atLocal: t))
        #expect(c.colorKeyTimes(effect: 1, keys: Self.exposure) == [.zero, t])
        #expect(Self.run(&c) { $0.toggleColorKey(effect: 1, keys: Self.exposure, atLocal: t) })
        #expect(c.colorKeyTimes(effect: 1, keys: Self.exposure) == [.zero])
    }

    @Test func removingTheLastKeyLeavesTheShownValueStatic() {
        var c = Self.graded()
        #expect(Self.run(&c) { $0.setColorAnimated(true, effect: 1, keys: Self.exposure, atLocal: .zero) })
        #expect(Self.run(&c) { $0.toggleColorKey(effect: 1, keys: Self.exposure, atLocal: .zero) })
        #expect(!c.isColorAnimated(effect: 1, keys: Self.exposure))
        #expect(c.color.effects[0].basic.exposure == 1.5)
    }

    @Test func toggleKeyOnAStaticGroupAnimatesIt() {
        var c = Self.graded()
        #expect(Self.run(&c) { $0.toggleColorKey(effect: 1, keys: Self.exposure, atLocal: Time(1, 1)) })
        #expect(c.colorKeyTimes(effect: 1, keys: Self.exposure) == [Time(1, 1)])
    }

    @Test func wheelGroupKeysAllItsParameters() {
        var c = Self.graded()
        #expect(Self.run(&c) { $0.setColorAnimated(true, effect: 1, keys: Self.midtones, atLocal: Time(1, 1)) })
        let fx = c.colorGradeEffects[0]
        for k in Self.midtones { #expect(fx.parameters[k]?.track.keys.map(\.time) == [Time(1, 1)]) }
        // Other parameters stay static.
        #expect(fx.parameters[K.colorExposureKey]?.isAnimated == false)
        #expect(fx.parameters[K.colorWheelShadowsHueKey]?.isAnimated == false)
    }

    @Test func groupIsAnimatedWhenAnyMemberIs() {
        var c = Self.graded()
        #expect(Self.run(&c) { $0.setColorAnimated(true, effect: 1, keys: [K.colorWheelMidtonesLumaKey], atLocal: Time(1, 1)) })
        #expect(c.isColorAnimated(effect: 1, keys: Self.midtones))
        #expect(c.colorKeyTimes(effect: 1, keys: Self.midtones) == [Time(1, 1)])
    }

    @Test func clipWithoutColourEffectGetsOneOnAnimate() {
        var c = ColorGradeEffectTests.picture()
        #expect(c.colorGradeEffects.isEmpty)
        #expect(Self.run(&c) { $0.setColorAnimated(true, effect: 1, keys: Self.exposure, atLocal: .zero) })
        #expect(c.colorGradeEffects.count == 1)
        #expect(c.isColorAnimated(effect: 1, keys: Self.exposure))
    }

    @Test func missingSecondEffectIsRefused() {
        var c = Self.graded()
        #expect(!Self.run(&c) { $0.setColorAnimated(true, effect: 2, keys: Self.exposure, atLocal: .zero) })
        #expect(!Self.run(&c) { $0.toggleColorKey(effect: 2, keys: Self.exposure, atLocal: .zero) })
    }

    @Test func secondEffectIsAddressedByItsInspectorId() {
        var c = Self.graded()
        var color = c.color
        color.addEffect()
        c.color = color
        #expect(Self.run(&c) { $0.setColorAnimated(true, effect: 2, keys: Self.exposure, atLocal: .zero) })
        #expect(!c.isColorAnimated(effect: 1, keys: Self.exposure))
        #expect(c.isColorAnimated(effect: 2, keys: Self.exposure))
    }

    @Test func theFirstColourEffectCreatedByAKeyConvertsAutomatically() {
        var c = ColorGradeEffectTests.picture()
        c.effects.removeAll { $0.isColor }
        #expect(Self.run(&c) { $0.setColorAnimated(true, effect: 1, keys: Self.exposure, atLocal: .zero) })
        #expect(c.color.effects[0].inputLUT == .automatic)
    }

    @Test func linkedCutsOfOneSourceTakeKeysOnTheSameFootageFrame() throws {
        typealias L = ColorGradeLinkTests
        let media = UUID()
        let a = L.clip("A", media: media)
        var b = L.clip("B", media: media, start: Time(4, 1))
        b.source = TimeRange(start: Time(2, 1), duration: Time(4, 1))      // B plays the footage from 2 s
        var p = L.project([a, b])
        #expect(p.linkGrades([a.id, b.id], source: a.id) != nil)
        let old = p
        p.forEachClipInPlace { c in
            guard c.id == a.id else { return }
            _ = c.setColorAnimated(true, effect: 1, keys: Self.exposure, atLocal: Time(3, 1))
        }
        p.propagateGradeLinks(from: old)
        #expect(L.find(p, b.id).colorKeyTimes(effect: 1, keys: Self.exposure) == [Time(1, 1)])
        // Other media keep the clip-local times.
        var x = Clip(name: "X", media: UUID(), kind: .video, source: TimeRange(start: Time(2, 1), duration: Time(4, 1)), start: .zero)
        x.effects = []
        let mapped = x.mappingKeyTimes(of: L.find(p, a.id).colorGradeEffects[0], from: L.find(p, a.id))
        #expect(mapped.parameters[ClipEffect.colorExposureKey]?.track.keys.map(\.time) == [Time(3, 1)])
    }
}
