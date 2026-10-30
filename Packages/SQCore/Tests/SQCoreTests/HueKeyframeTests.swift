import Foundation
import Testing
@testable import SQCore

/// COL-25: hue parameters take the short way round the color circle between keys (350 -> 10 passes through 0, not
/// through 180). Rotation-like angles stay linear. Color wheel pucks move in a straight line across the disc.
@Suite struct HueKeyframeTests {
    typealias K = ClipEffect

    static func s(_ v: Double) -> Time { Time(Int64(v * 1000), 1000) }

    static func prop(_ keys: [(Double, Double)], _ interpolation: Interpolation = .linear) -> AnimatedProperty<Double> {
        var p = AnimatedProperty(keys.first?.1 ?? 0)
        for (t, v) in keys { p.track.insert(Keyframe(time: s(t), value: v, interpolation: interpolation)) }
        return p
    }

    static func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }
    static func near(_ a: Float, _ b: Double, _ eps: Double = 1e-4) -> Bool { abs(Double(a) - b) < eps }
    /// Same hue on the circle (0 and 360 are one hue).
    static func sameHue(_ a: Double, _ b: Double, _ eps: Double = 1e-4) -> Bool {
        let d = (a - b).truncatingRemainder(dividingBy: 360)
        return abs(d) < eps || abs(abs(d) - 360) < eps
    }

    // MARK: Shortest arc

    @Test func hueCrossesZeroTheShortWay() {
        let p = Self.prop([(0, 350), (2, 10)])
        #expect(Self.sameHue(p.hueValue(atLocal: Self.s(1)), 0))
        #expect(Self.near(p.hueValue(atLocal: Self.s(0.5)), 355))
        #expect(Self.near(p.hueValue(atLocal: Self.s(1.5)), 5))
    }

    @Test func hueKeepsTheKeyValuesAtTheKeys() {
        let p = Self.prop([(0, 350), (2, 10), (4, 360)])
        #expect(p.hueValue(atLocal: .zero) == 350)
        #expect(p.hueValue(atLocal: Self.s(2)) == 10)
        #expect(p.hueValue(atLocal: Self.s(4)) == 360)
        #expect(p.hueValue(atLocal: Self.s(9)) == 360)
    }

    @Test func hueResultStaysOnTheCircle() {
        let p = Self.prop([(0, 10), (2, 350), (4, 20)])
        let a = p.hueValue(atLocal: Self.s(1)), b = p.hueValue(atLocal: Self.s(3))
        #expect(a >= 0 && a <= 360 && Self.sameHue(a, 0))
        #expect(b >= 0 && b <= 360 && Self.sameHue(b, 5))
    }

    @Test func halfTurnKeepsTheKeyedDirection() {
        #expect(Self.near(Self.prop([(0, 0), (2, 180)]).hueValue(atLocal: Self.s(1)), 90))
        #expect(Self.near(Self.prop([(0, 180), (2, 0)]).hueValue(atLocal: Self.s(1)), 90))
    }

    @Test func hueKeepsHoldAndEasing() {
        let held = Self.prop([(0, 350), (2, 10)], .hold)
        #expect(held.hueValue(atLocal: Self.s(1.9)) == 350)
        var eased = Self.prop([(0, 350), (2, 10)])
        let ease = EaseHandle(dx: 0.5, dy: 0)
        eased.track.update(eased.track.keys[0].id) { $0.outHandle = ease }
        eased.track.update(eased.track.keys[1].id) { $0.inHandle = ease }
        let v = eased.hueValue(atLocal: Self.s(0.5))
        #expect(v > 350 && v < 355)
    }

    @Test func staticHueIsUnchanged() {
        #expect(AnimatedProperty(400.0).hueValue(atLocal: .zero) == 400)
    }

    @Test func keyHueOfTheColorKeyTakesTheShortWay() {
        let fx = ClipEffect(kind: K.ultraKeyKind, parameters: [K.keyHueKey: Self.prop([(0, 350), (2, 10)])])
        #expect(Self.sameHue(fx.scalar(K.keyHueKey, atLocal: Self.s(1)), 0))
        #expect(Self.near(fx.scalar(K.keyHueKey, atLocal: Self.s(1.5)), 5))
    }

    @Test func shownValueFollowsThePicture() {
        let key = ClipEffect(kind: K.ultraKeyKind, parameters: [K.keyHueKey: Self.prop([(0, 350), (2, 10)])])
        #expect(Self.near(key.shownValue(K.keyHueKey, atLocal: Self.s(1.5))!, 5))
        let mirror = ClipEffect(kind: K.mirrorKind, parameters: [K.mirrorAngleKey: Self.prop([(0, 350), (2, 10)])])
        #expect(Self.near(mirror.shownValue(K.mirrorAngleKey, atLocal: Self.s(1))!, 180))
        let wheel = Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (2, 0.5)])
        #expect(Self.near(wheel.shownValue(K.colorWheelMidtonesAmountKey, atLocal: Self.s(1))!, 0))
        #expect(wheel.shownValue(K.ultraKeyKind, atLocal: .zero) == nil)
    }

    @Test func anglesThatAreNotHuesStayLinear() {
        let fx = ClipEffect(kind: K.mirrorKind, parameters: [K.mirrorAngleKey: Self.prop([(0, 350), (2, 10)])])
        #expect(Self.near(fx.scalar(K.mirrorAngleKey, atLocal: Self.s(1)), 180))
        var a = ClipAnimation()
        a.rotation = Self.prop([(0, 350), (2, 10)])
        #expect(Self.near(a.rotation.value(atLocal: Self.s(1)), 180))
    }

    @Test func catalogMarksOnlyHues() {
        #expect(EffectCatalog.param(K.ultraKeyKind, K.keyHueKey)?.isHue == true)
        #expect(EffectCatalog.param(K.mirrorKind, K.mirrorAngleKey)?.isHue == false)
        #expect(EffectCatalog.param(K.directionalBlurKind, K.blurDirectionKey)?.isHue == false)
    }

    // MARK: Color wheels on the disc

    static func wheel(_ hues: [(Double, Double)], _ amounts: [(Double, Double)],
                      hue: String = K.colorWheelMidtonesHueKey, amount: String = K.colorWheelMidtonesAmountKey) -> ClipEffect {
        var fx = ClipEffect.colorGrade(ColorEffect(id: 1))
        fx.parameters[hue] = hues.count == 1 ? AnimatedProperty(hues[0].1) : prop(hues)
        fx.parameters[amount] = amounts.count == 1 ? AnimatedProperty(amounts[0].1) : prop(amounts)
        return fx
    }

    @Test func oppositeHuesCrossTheCentre() {
        let fx = Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (2, 0.5)])
        let mid = fx.colorEffect(atLocal: Self.s(1), id: 1).wheels.midtones
        #expect(Self.near(mid.amount, 0))
        let quarter = fx.colorEffect(atLocal: Self.s(0.5), id: 1).wheels.midtones
        #expect(Self.near(quarter.amount, 0.25))
        #expect(Self.near(quarter.hue, 0) || Self.near(quarter.hue, 360))
    }

    @Test func puckMovesInAStraightLine() {
        let fx = Self.wheel([(0, 0), (2, 90)], [(0, 1), (2, 1)])
        let mid = fx.colorEffect(atLocal: Self.s(1), id: 1).wheels.midtones
        #expect(Self.near(mid.amount, 0.5.squareRoot()))
        #expect(Self.near(mid.hue, 45))
    }

    @Test func puckCrossesZeroTheShortWay() {
        let fx = Self.wheel([(0, 350), (2, 10)], [(0, 1), (2, 1)])
        let mid = fx.colorEffect(atLocal: Self.s(1), id: 1).wheels.midtones
        #expect(Self.sameHue(Double(mid.hue), 0))
        #expect(Self.near(mid.amount, cos(10 * Double.pi / 180)))
    }

    @Test func amountOnlyAnimationKeepsTheHue() {
        let fx = Self.wheel([(0, 200)], [(0, 0), (2, 1)])
        let mid = fx.colorEffect(atLocal: Self.s(1), id: 1).wheels.midtones
        #expect(Self.near(mid.amount, 0.5))
        #expect(Self.near(mid.hue, 200))
    }

    @Test func wheelKeysAreExactAtTheKeys() {
        let fx = Self.wheel([(0, 30), (2, 250)], [(0, 0.4), (2, 0.7)])
        let a = fx.colorEffect(atLocal: .zero, id: 1).wheels.midtones
        let b = fx.colorEffect(atLocal: Self.s(2), id: 1).wheels.midtones
        #expect(a.hue == 30 && a.amount == 0.4)
        #expect(b.hue == 250 && b.amount == 0.7)
    }

    @Test func wheelHoldKeepsThePuck() {
        var fx = Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (2, 0.5)])
        for k in [K.colorWheelMidtonesHueKey, K.colorWheelMidtonesAmountKey] {
            fx.parameters[k]!.track.update(fx.parameters[k]!.track.keys[0].id) { $0.interpolation = .hold }
        }
        let m = fx.colorEffect(atLocal: Self.s(1.5), id: 1).wheels.midtones
        #expect(m.hue == 0 && m.amount == 0.5)
    }

    @Test func lookTintsAreWheelsToo() {
        let fx = Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (2, 0.5)],
                            hue: K.colorShadowTintHueKey, amount: K.colorShadowTintAmountKey)
        #expect(Self.near(fx.colorEffect(atLocal: Self.s(1), id: 1).creative.shadowTint.amount, 0))
    }

    // MARK: Keying does not move the picture

    static func clip(_ fx: ClipEffect) -> Clip {
        var c = ColorGradeEffectTests.picture()
        c.effects.insert(fx, at: 0)
        return c
    }

    static let midtones = [K.colorWheelMidtonesHueKey, K.colorWheelMidtonesAmountKey, K.colorWheelMidtonesLumaKey]

    @Test func addingAWheelKeyMidwayKeepsThePuck() {
        var c = Self.clip(Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (2, 0.5)]))
        let t = Self.s(0.5)
        let before = c.color(atLocal: t).effects[0].wheels.midtones
        let keyed = c.toggleColorKey(effect: 1, keys: Self.midtones, atLocal: t)
        #expect(keyed)
        let after = c.color(atLocal: t).effects[0].wheels.midtones
        #expect(Self.near(after.hue, Double(before.hue)) && Self.near(after.amount, Double(before.amount)))
    }

    @Test func rewritingTheShownGradeAddsNoKeys() {
        var c = Self.clip(Self.wheel([(0, 350), (2, 10)], [(0, 0.5), (2, 0.8)]))
        let before = c
        let t = Self.s(1)
        c.setColor(c.color(atLocal: t), atLocal: t)
        #expect(c.colorKeyTimes(effect: 1, keys: Self.midtones) == before.colorKeyTimes(effect: 1, keys: Self.midtones))
    }

    // MARK: Per-track fallback (review fixes)

    static func midtones(_ fx: ClipEffect, _ t: Double) -> WheelValue { fx.colorEffect(atLocal: s(t), id: 1).wheels.midtones }

    @Test func hueOnlyAnimationKeepsTheAmount() {
        // Only the hue is keyed: each track on its own, so the grade never goes neutral midway.
        let m = Self.midtones(Self.wheel([(0, 0), (2, 180)], [(0, 0.5)]), 1)
        #expect(Self.near(m.amount, 0.5))
        #expect(Self.near(m.hue, 90))
        let short = Self.midtones(Self.wheel([(0, 350), (2, 10)], [(0, 0.5)]), 1.5)
        #expect(Self.near(short.hue, 5))
    }

    @Test func holdOnEitherTrackHoldsThePuck() {
        var fx = Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (2, 0.5)])
        let k = K.colorWheelMidtonesAmountKey
        fx.parameters[k]!.track.update(fx.parameters[k]!.track.keys[0].id) { $0.interpolation = .hold }
        let m = Self.midtones(fx, 1.5)
        #expect(m.hue == 0 && m.amount == 0.5)
    }

    @Test func differentEasingKeepsEachTrackItsOwn() {
        var fx = Self.wheel([(0, 0), (2, 90)], [(0, 0.2), (2, 1)])
        let k = K.colorWheelMidtonesHueKey, ease = EaseHandle(dx: 0.5, dy: 0)
        fx.parameters[k]!.track.update(fx.parameters[k]!.track.keys[0].id) { $0.outHandle = ease }
        fx.parameters[k]!.track.update(fx.parameters[k]!.track.keys[1].id) { $0.inHandle = ease }
        let m = Self.midtones(fx, 0.5)
        #expect(Self.near(m.hue, fx.parameters[k]!.hueValue(atLocal: Self.s(0.5))))
        #expect(Self.near(m.amount, 0.4))
    }

    @Test func keysAtDifferentTimesKeepEachTrackItsOwn() {
        let fx = Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (1, 0.5), (2, 0.5)])
        let m = Self.midtones(fx, 0.5)
        #expect(Self.near(m.hue, 45) && Self.near(m.amount, 0.5))
    }

    @Test func segmentIndexFindsTheSegment() {
        let tr = Self.prop([(0, 0), (1, 1), (2, 2)]).track
        #expect(tr.segmentIndex(at: Self.s(-1)) == nil)
        #expect(tr.segmentIndex(at: .zero) == 0)
        #expect(tr.segmentIndex(at: Self.s(1)) == 1)
        #expect(tr.segmentIndex(at: Self.s(1.5)) == 1)
        #expect(tr.segmentIndex(at: Self.s(2)) == nil)
    }

    @Test func editingTheWheelHueKeysTheAmountAtItsShownValue() {
        var c = Self.clip(Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (2, 0.5)]))
        let t = Self.s(0.5)
        let base = c.color(atLocal: t)
        var edited = base
        edited.effects[0].wheels.midtones.hue = 30
        let ok = c.setColor(edited, editedFrom: base, atLocal: t)
        #expect(ok)
        let fx = c.effects[0]
        #expect(fx.parameters[K.colorWheelMidtonesAmountKey]!.track.keys.contains { $0.time == t && Self.near($0.value, 0.25) })
        let after = c.color(atLocal: t).effects[0].wheels.midtones
        #expect(Self.near(after.hue, 30) && Self.near(after.amount, 0.25))
    }

    @Test func rewritingAWheelHueKeysTheAmountToo() {
        var c = Self.clip(Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (2, 0.5)]))
        let t = Self.s(0.5)
        var g = c.color(atLocal: t)
        g.effects[0].wheels.midtones.hue = 30
        c.setColor(g, atLocal: t)
        #expect(c.effects[0].parameters[K.colorWheelMidtonesAmountKey]!.track.keys.contains { $0.time == t })
    }

    @Test func stopwatchOffFreezesTheShownHue() {
        let id = UUID()
        var c = ColorGradeEffectTests.picture()
        c.effects.append(ClipEffect(id: id, kind: K.ultraKeyKind, parameters: [K.keyHueKey: Self.prop([(0, 350), (2, 10)])]))
        let before = c
        c.effects[c.effects.count - 1].parameters[K.keyHueKey]!.track = KeyframeTrack()
        c.followShownValues(effect: id, key: K.keyHueKey, atLocal: Self.s(1.5), before: before)
        #expect(Self.near(c.effects.last!.parameters[K.keyHueKey]!.value, 5))
    }

    @Test func addingARowKeyOnAWheelKeysItsPartner() {
        var c = Self.clip(Self.wheel([(0, 0), (2, 180)], [(0, 0.5), (2, 0.5)]))
        let id = c.effects[0].id, t = Self.s(0.5)
        let before = c
        let shown = c.effects[0].shownValue(K.colorWheelMidtonesHueKey, atLocal: t)!
        c.effects[0].parameters[K.colorWheelMidtonesHueKey]!.track.insert(Keyframe(time: t, value: shown))
        c.followShownValues(effect: id, key: K.colorWheelMidtonesHueKey, atLocal: t, before: before)
        #expect(c.effects[0].parameters[K.colorWheelMidtonesAmountKey]!.track.keys.contains { $0.time == t && Self.near($0.value, 0.25) })
        let m = c.color(atLocal: t).effects[0].wheels.midtones
        #expect(Self.near(m.amount, 0.25))
    }
}
