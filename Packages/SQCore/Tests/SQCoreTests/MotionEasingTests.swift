import Foundation
import Testing
@testable import SQCore

// FB-T3: the easing library of the motion effects (Premiere's interpolations + the short-form families + a custom
// cubic bezier), the parametrised Move and the built-in motion presets.

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }
private let frame = Vec2(1920, 1080)

private func clip(_ effects: [ClipEffect], seconds: Int64 = 4) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(seconds, 1)), start: .zero)
    c.effects = effects
    return c
}
private func ms(_ n: Int64) -> Time { Time(n, 1000) }

@Suite struct MotionEasingLibraryTests {
    @Test func everyCurveStartsAtZeroAndEndsAtOne() {
        for c in MotionCurve.allCases {
            #expect(c.ease(0) == 0, "\(c)")
            #expect(c.ease(1) == 1, "\(c)")
            #expect(c.ease(-0.5) == 0 && c.ease(1.5) == 1, "\(c) clamps")
        }
    }

    @Test func titlesMatchCasesAndPremiereComesFirst() {
        #expect(MotionCurve.titles.count == MotionCurve.allCases.count)
        #expect(Array(MotionCurve.titles.prefix(5)) == ["Gentle", "Smooth", "Auto", "Steady", "Hold"])
        #expect(MotionCurve.titles.last == "Custom")
        #expect(MotionCurve.allCases.allSatisfy { MotionCurve.titles[$0.rawValue] == $0.title })
        #expect(Set(MotionCurve.titles).count == MotionCurve.titles.count, "no duplicate names")
    }

    @Test func curvesStayContinuousNearTheEnds() {
        // No visible jump right after 0 or right before 1 (expo / elastic are normalized to land exactly).
        for c in MotionCurve.allCases where c != .hold {
            // Circ has a vertical tangent at one end (sqrt), so a millionth in time is ~0.0014 in value.
            #expect(abs(c.ease(1e-6)) < 2e-3, "\(c) start")
            #expect(abs(c.ease(1 - 1e-6) - 1) < 2e-3, "\(c) end")
        }
    }

    @Test func premiereInterpolations() {
        #expect(MotionCurve.linear.ease(0.3) == 0.3)
        #expect(MotionCurve.autoBezier.ease(0.3) == 0.3, "two-key auto bezier is straight speed, as in Premiere")
        #expect(MotionCurve.hold.ease(0.999) == 0 && MotionCurve.hold.ease(1) == 1)
        #expect(MotionCurve.continuousBezier.ease(0.5).isFinite && near(MotionCurve.continuousBezier.ease(0.5), 0.5, 1e-9))
        #expect(MotionCurve.continuousBezier.ease(0.2) < 0.2 && MotionCurve.continuousBezier.ease(0.8) > 0.8)
        // Premiere's Ease In slows into the key (fast start), Ease Out slows out of it (slow start).
        #expect(MotionCurve.easeIn.ease(0.25) > 0.25 && MotionCurve.easeOut.ease(0.25) < 0.25)
    }

    @Test func familiesHaveTheirShape() {
        // In accelerates (below the diagonal), Out decelerates (above), In-Out is symmetric about the middle.
        let families: [(MotionCurve, MotionCurve, MotionCurve)] = [
            (.sineIn, .sineOut, .sineInOut), (.quadIn, .quadOut, .quadInOut), (.cubicIn, .cubicOut, .cubicInOut),
            (.quartIn, .quartOut, .quartInOut), (.quintIn, .quintOut, .quintInOut), (.expoIn, .expoOut, .expoInOut),
            (.circIn, .circOut, .circInOut),
        ]
        for (i, o, io) in families {
            #expect(i.ease(0.3) < 0.3 && o.ease(0.3) > 0.3, "\(i) / \(o)")
            #expect(near(io.ease(0.5), 0.5, 1e-9), "\(io) middle")
            #expect(near(io.ease(0.2) + io.ease(0.8), 1, 1e-9), "\(io) symmetric")
            for x in stride(from: 0.0, through: 1, by: 0.05) { #expect(near(o.ease(x), 1 - i.ease(1 - x), 1e-9), "\(o) mirrors \(i)") }
        }
        #expect(near(MotionCurve.cubicIn.ease(0.5), 0.125))
        #expect(near(MotionCurve.quadOut.ease(0.5), 0.75))
    }

    @Test func backOvershootsElasticRingsBounceStaysInside() {
        let backOut = (1..<100).map { MotionCurve.backOut.ease(Double($0) / 100) }
        #expect(backOut.max()! > 1.05, "Back Out overshoots past the end")
        let backIn = (1..<100).map { MotionCurve.backIn.ease(Double($0) / 100) }
        #expect(backIn.min()! < -0.05, "Back In pulls back first")
        let el = (1..<200).map { MotionCurve.elasticOut.ease(Double($0) / 200) }
        #expect(el.max()! > 1.1 && el.contains { $0 < 1 }, "Spring Out rings around the end")
        let bo = (0...200).map { MotionCurve.bounceOut.ease(Double($0) / 200) }
        #expect(bo.allSatisfy { $0 >= -1e-12 && $0 <= 1 + 1e-12 }, "Bounce never leaves 0...1")
        #expect(near(MotionCurve.bounceOut.ease(1 / 2.75), 1, 1e-9), "first floor contact")
        #expect(MotionCurve.spring.ease(0.5) > 0.9)
    }

    @Test func customCubicBezierIsCSSCubicBezier() {
        // cubic-bezier(0.25, 0.1, 0.25, 1) = CSS "ease": 0.5 -> ~0.8024.
        let css = CubicBezierEase(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
        #expect(near(MotionCurve.custom.ease(0.5, custom: css), 0.8024, 2e-3))
        // The straight line is linear.
        let line = CubicBezierEase(x1: 1.0 / 3, y1: 1.0 / 3, x2: 2.0 / 3, y2: 2.0 / 3)
        #expect(near(MotionCurve.custom.ease(0.37, custom: line), 0.37, 1e-6))
        // Y outside 0...1 overshoots (a hand-made back curve).
        let over = CubicBezierEase(x1: 0.3, y1: 1.6, x2: 0.6, y2: 1)
        #expect((1..<100).map { MotionCurve.custom.ease(Double($0) / 100, custom: over) }.max()! > 1)
        // Round trip with the curve editor's shape.
        let shape = css.shape
        #expect(CubicBezierEase(shape) == css)
    }

    @Test func customCurveIsReadFromTheEffect() {
        var e = ClipEffect.make(kind: ClipEffect.zoomKind)!
        e.parameters[ClipEffect.motionDurationKey] = AnimatedProperty(1)
        e.parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(MotionCurve.custom.rawValue))
        e.setCustomCurve(CubicBezierEase(x1: 0, y1: 1, x2: 0, y2: 1))   // very fast start
        #expect(e.customCurve == CubicBezierEase(x1: 0, y1: 1, x2: 0, y2: 1))
        let fast = clip([e]).renderTransform(at: ms(200), frame: frame).scale.x
        var lin = e; lin.parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(MotionCurve.linear.rawValue))
        let slow = clip([lin]).renderTransform(at: ms(200), frame: frame).scale.x
        #expect(fast > slow + 0.03)
        // The custom keys are not in the spec (no rows of their own) and a fresh effect has none.
        #expect(ClipEffect.make(kind: ClipEffect.zoomKind)!.customCurve == nil)
        #expect(!MotionEffects.zoomSpec.params.contains { $0.key == ClipEffect.curveX1Key })
    }
}

@Suite struct ParametrisedMoveTests {
    private func move(_ values: [String: Double]) -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.moveKind)!
        e.parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(MotionCurve.linear.rawValue))
        e.parameters[ClipEffect.motionDurationKey] = AnimatedProperty(1)
        for (k, v) in values { e.parameters[k] = AnimatedProperty(v) }
        return e
    }
    private func at(_ e: ClipEffect, _ t: Time) -> ClipTransform { clip([e]).renderTransform(at: t, frame: frame) }

    @Test func sidesPickTheDirection() {
        let s = ClipEffect.moveSideKey
        #expect(near(at(move([s: 0, ClipEffect.moveDistanceKey: 100]), .zero).position.x, -1920, 1e-6), "Left")
        #expect(near(at(move([s: 1, ClipEffect.moveDistanceKey: 100]), .zero).position.x, 1920, 1e-6), "Right")
        #expect(near(at(move([s: 2, ClipEffect.moveDistanceKey: 100]), .zero).position.y, -1080, 1e-6), "Top")
        #expect(near(at(move([s: 3, ClipEffect.moveDistanceKey: 100]), .zero).position.y, 1080, 1e-6), "Bottom")
        // Angle uses the Direction slider (90 = from the right); the side ignores it.
        let angle = move([s: 4, ClipEffect.moveDirectionKey: 90, ClipEffect.moveDistanceKey: 50])
        #expect(near(at(angle, .zero).position.x, 960, 1e-6))
        let left = move([s: 0, ClipEffect.moveDirectionKey: 90, ClipEffect.moveDistanceKey: 50])
        #expect(near(at(left, .zero).position.x, -960, 1e-6))
        // Without a stored side (older effects) the angle decides, as before.
        var legacy = move([ClipEffect.moveDirectionKey: 90, ClipEffect.moveDistanceKey: 50])
        legacy.parameters[s] = nil
        #expect(near(at(legacy, .zero).position.x, 960, 1e-6))
        #expect(ClipEffect.make(kind: ClipEffect.moveKind)!.parameters[s] != nil, "new Moves store their side")
    }

    @Test func rotationDirectionAndStrength() {
        let s = ClipEffect.moveSpinKey, r = ClipEffect.moveRotationKey
        #expect(at(move([s: 0, r: 40]), .zero).rotation == 0, "None")
        #expect(near(at(move([s: 1, r: 40]), .zero).rotation, 40), "Clockwise")
        #expect(near(at(move([s: 2, r: 40]), .zero).rotation, -40), "Counter-clockwise")
        #expect(near(at(move([s: 2, r: -40]), .zero).rotation, -40), "the strength is a magnitude")
        #expect(near(at(move([s: 1, r: 40]), ms(500)).rotation, 20), "linear half way")
        #expect(at(move([s: 1, r: 40]), ms(1000)).rotation == 0)
    }

    @Test func scaleAtEdgeAndFadeAndOut() {
        let e = move([ClipEffect.moveScaleKey: 50, ClipEffect.moveFadeKey: 1, ClipEffect.moveFadeLengthKey: 0.5])
        #expect(near(at(e, .zero).scale.x, 0.5) && near(at(e, ms(500)).scale.x, 0.75) && near(at(e, ms(1000)).scale.x, 1))
        #expect(near(at(e, .zero).opacity, 0) && near(at(e, ms(250)).opacity, 0.5) && near(at(e, ms(600)).opacity, 1))
        var out = e
        out.parameters[ClipEffect.motionModeKey] = AnimatedProperty(Double(MotionMode.out.rawValue))
        #expect(near(at(out, Time(4, 1)).scale.x, 0.5) && near(at(out, Time(2, 1)).scale.x, 1))
    }

    @Test func easingShapesTheMove() {
        let lin = move([ClipEffect.moveDistanceKey: 100])
        var bounce = lin
        bounce.parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(MotionCurve.bounceOut.rawValue))
        #expect(abs(at(bounce, ms(300)).position.x) < abs(at(lin, ms(300)).position.x))
        // Back Out overshoots: the picture passes its rest position.
        var back = lin
        back.parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(MotionCurve.backOut.rawValue))
        #expect((1..<20).contains { at(back, ms(Int64($0) * 50)).position.x > 1 })
    }

    @Test func elementTransitionMoveSharesTheSpec() {
        let keys = Set(TransitionKind.move.elementParams.map(\.key))
        for k in [ClipEffect.moveSideKey, ClipEffect.moveSpinKey, ClipEffect.moveScaleKey, ClipEffect.motionCurveKey] {
            #expect(keys.contains(k), "\(k)")
        }
    }
}

@Suite struct MotionPresetTests {
    @Test func builtInsAreUniqueAndOnlyEffects() {
        let all = MotionPresets.builtIns
        #expect(Set(all.map(\.id)).count == all.count && Set(all.map(\.name)).count == all.count)
        for name in ["Move From Left", "Move From Right", "Move From Top", "Move From Bottom",
                     "Move To Left", "Move To Right", "Move To Top", "Move To Bottom",
                     "Pop In", "Slide In", "Whip In", "Bounce In", "Drift"] {
            #expect(all.contains { $0.name == name }, "\(name)")
        }
        for p in all {
            #expect(!p.effects.isEmpty && p.preset.motionProperties.isEmpty, "\(p.name): effects only, Motion untouched")
            // Emphasis presets (EmphasisPresetTests) also stack picture effects (blur, RGB split, mosaic).
            if !EmphasisPresetTests.names.contains(p.name) {
                #expect(p.effects.allSatisfy { $0.isTransformStage }, "\(p.name): its own transform stage")
            }
            #expect(p.effects.allSatisfy { EffectCatalog.spec(for: $0.kind) != nil }, "\(p.name): known kinds")
        }
    }

    @Test func moveFromLeftAndRightAreOneEffectWithStartValues() {
        let l = MotionPresets.builtIn(named: "Move From Left")!.effects, r = MotionPresets.builtIn(named: "Move From Right")!.effects
        #expect(l.count == 1 && r.count == 1 && l[0].kind == ClipEffect.moveKind && r[0].kind == ClipEffect.moveKind)
        #expect(l[0].parameters[ClipEffect.moveSideKey]?.value == 0 && r[0].parameters[ClipEffect.moveSideKey]?.value == 1)
        // Start values, not locks: nothing is keyed, everything can be changed afterwards.
        #expect(l[0].keyTimes.isEmpty)
    }

    @Test func applyingKeepsClipMotionAndCanBeBaked() throws {
        var c = clip([], seconds: 3)
        c.animation.scale = AnimatedProperty(Vec2(1.5, 1.5))
        c.applyPreset(MotionPresets.builtIn(named: "Slide In")!.preset)
        #expect(c.animation.scale.value == Vec2(1.5, 1.5), "the clip's own Motion stays")
        #expect(c.effects.count == 1 && c.effects[0].kind == ClipEffect.moveKind)
        // At rest after the edge: exactly the clip's Motion (the effect starts at its own 100 %).
        let rest = c.renderTransform(at: Time(2, 1), frame: frame)
        #expect(near(rest.scale.x, 1.5) && rest.position == .zero)
        // User presets convert to keyframes; the baked curve matches the live one on the frame grid.
        let live = (0..<30).map { c.renderTransform(at: Time(Int64($0), 30), frame: frame) }
        var baked = c
        try baked.convertToKeyframes(effect: c.effects[0].id, frameDuration: Time(1, 30), frame: frame)
        #expect(baked.effects.isEmpty)
        for (i, t) in live.enumerated() {
            let b = baked.renderTransform(at: Time(Int64(i), 30), frame: frame)
            #expect(abs(b.position.x - t.position.x) < 1e-6, "frame \(i)")
            #expect(abs(b.opacity - t.opacity) < 1e-9, "frame \(i)")
        }
    }

    @Test func everyPresetMovesAndComesToRest() {
        let entrances = ["Move From Left", "Move From Right", "Move From Top", "Move From Bottom", "Pop In", "Slide In",
                         "Whip In", "Bounce In", "Spin In", "Elastic Pop"]
        for p in MotionPresets.builtIns where entrances.contains(p.name) {
            var c = clip([], seconds: 6)
            c.applyPreset(p.preset)
            let start = c.renderTransform(at: .zero, frame: frame), rest = c.renderTransform(at: Time(5, 1), frame: frame)
            #expect(start != rest, "\(p.name) animates")
            #expect(rest.position == .zero && near(rest.scale.x, 1, 1e-9) && near(rest.opacity, 1) && near(rest.rotation, 0),
                    "\(p.name) rests at 100 %")
        }
    }
}
