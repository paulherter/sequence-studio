import Foundation
import Testing
@testable import SQCore

// W7.4: parametric motion effects on the transform stage; the maintainer's top-10 recipes within 1 px of his keys.

private func ms(_ n: Int64) -> Time { Time(n, 1000) }
private let W = 1920.0, H = 1080.0
private let frame = Vec2(W, H)

private func clip(_ effects: [ClipEffect], seconds: Int64 = 4) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(seconds, 1)), start: .zero)
    c.effects = effects
    return c
}
private func at(_ c: Clip, _ t: Time) -> ClipTransform { c.renderTransform(at: t, frame: frame) }
private func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

/// Scale in px of the frame width, so "within 1 px" is a tolerance on the picture's edge.
private func scalePx(_ t: ClipTransform) -> Double { t.scale.x * W }

@Suite struct MotionEffectsCatalogTests {
    @Test func offeredAndAreStages() {
        for k in ["motionMove", "motionZoom", "motionPop", "motionFade", "motionShake"] {
            // FB-G: Move, Zoom, Pop and Fade are transitions now; they still evaluate in old projects.
            #expect(EffectCatalog.all.contains { $0.kind == k } == (k == "motionShake"))
            #expect(ClipEffect.make(kind: k)!.isTransformStage)
        }
    }

    @Test func freshEffectsAtRestAreHarmlessMidClip() {
        // Default modes are In: after the edge the picture is untouched (Zoom holds its To value, so skip it).
        for k in [ClipEffect.moveKind, ClipEffect.popKind, ClipEffect.fadeKind, ClipEffect.shakeKind] {
            let c = clip([ClipEffect.make(kind: k)!])
            let t = at(c, Time(2, 1))
            #expect(t.position == .zero && near(t.scale.x, 1, 1e-9) && t.opacity == 1 && t.rotation == 0)
        }
    }

    @Test func noKeyframesAreWritten() {
        for s in MotionEffects.specs {
            let e = ClipEffect.make(kind: s.kind)!
            #expect(e.keyTimes.isEmpty)
        }
    }

    @Test func stackedWithMotionMultiplies() {
        var c = clip([ClipEffect.make(kind: ClipEffect.zoomKind)!])
        c.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        // Zoom In default 100 -> 110 over 0.5 s: after it, 120 % * 110 %.
        #expect(near(at(c, Time(2, 1)).scale.x, 1.32, 1e-9))
        #expect(c.animation.scale.track.keys.isEmpty)
    }
}

@Suite struct MotionEffectsBehaviourTests {
    @Test func moveDirectionRotationAndStrength() {
        var e = ClipEffect.make(kind: ClipEffect.moveKind)!
        e.parameters[ClipEffect.moveSideKey] = AnimatedProperty(Double(MoveSide.angle.rawValue))   // FB-T3: the Angle slider
        e.parameters[ClipEffect.moveDirectionKey] = AnimatedProperty(90)   // from the right
        e.parameters[ClipEffect.moveDistanceKey] = AnimatedProperty(50)
        e.parameters[ClipEffect.moveRotationKey] = AnimatedProperty(10)    // Rotation defaults to Clockwise
        let c = clip([e])
        let start = at(c, .zero)
        #expect(near(start.position.x, 0.5 * W, 1e-6) && near(start.position.y, 0, 1e-6) && near(start.rotation, 10, 1e-9))
        // Diagonal: share of the frame along the direction.
        e.parameters[ClipEffect.moveDirectionKey] = AnimatedProperty(0)    // from the top
        #expect(near(at(clip([e]), .zero).position.y, -0.5 * H, 1e-6))
        let end = at(c, Time(1, 1))
        #expect(end.position == .zero && end.rotation == 0)
    }

    @Test func outModeIsTheTimeReverseOfIn() {
        var e = ClipEffect.make(kind: ClipEffect.moveKind)!
        e.parameters[ClipEffect.moveDirectionKey] = AnimatedProperty(90)
        e.parameters[ClipEffect.motionDurationKey] = AnimatedProperty(1)
        var o = e; o.parameters[ClipEffect.motionModeKey] = AnimatedProperty(1)
        let cin = clip([e]), cout = clip([o])
        for ts in [0, 100, 300, 500, 900] as [Int64] {
            #expect(near(at(cin, ms(ts)).position.x, at(cout, ms(4000 - ts)).position.x, 1e-6))
        }
    }

    @Test func loopRepeatsPerDuration() {
        var e = ClipEffect.make(kind: ClipEffect.zoomKind)!
        e.parameters[ClipEffect.motionModeKey] = AnimatedProperty(3)
        e.parameters[ClipEffect.motionDurationKey] = AnimatedProperty(1)
        let c = clip([e])
        #expect(near(at(c, ms(250)).scale.x, at(c, ms(1250)).scale.x, 1e-9))
        #expect(near(at(c, .zero).scale.x, 1, 1e-9))
        #expect(near(at(c, ms(500)).scale.x, 1.1, 1e-9))
    }

    @Test func shakeIsDeterministicSmoothAndSettlesIn() {
        var e = ClipEffect.make(kind: ClipEffect.shakeKind)!
        e.parameters[ClipEffect.motionDurationKey] = AnimatedProperty(1)
        let c = clip([e])
        let a = at(c, ms(200)), b = at(c, ms(200))
        #expect(a == b)
        #expect(a.position != .zero)
        #expect(at(c, ms(1500)).position == .zero)   // In: decays to rest after the duration
        #expect(abs(at(c, ms(200)).position.x - at(c, ms(204)).position.x) < 6)   // continuous
        e.parameters[ClipEffect.motionModeKey] = AnimatedProperty(3)
        #expect(at(clip([e]), ms(2500)).position != .zero)
    }

    @Test func curveChangesTheMiddleNotTheEnds() {
        var lin = ClipEffect.make(kind: ClipEffect.zoomKind)!
        lin.parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(MotionCurve.linear.rawValue))
        lin.parameters[ClipEffect.motionDurationKey] = AnimatedProperty(1)
        var eo = lin; eo.parameters[ClipEffect.motionCurveKey] = AnimatedProperty(Double(MotionCurve.easeOut100.rawValue))
        #expect(at(clip([eo]), ms(300)).scale.x > at(clip([lin]), ms(300)).scale.x)
        #expect(near(at(clip([eo]), .zero).scale.x, 1, 1e-12) && near(at(clip([eo]), ms(1000)).scale.x, 1.1, 1e-12))
    }

    @Test func positionIsAShareOfTheCanvas() {
        var e = ClipEffect.make(kind: ClipEffect.moveKind)!
        e.parameters[ClipEffect.moveDirectionKey] = AnimatedProperty(270)
        let c = clip([e])
        #expect(near(c.renderTransform(at: .zero, frame: Vec2(1080, 1920)).position.x, -1080, 1e-6))
    }
}

// The maintainer's top-10 recipes (docs/RESEARCH-PAUL-CURVES.md section 3): keys at their times, within 1 px.
@Suite struct MotionRecipesTests {
    private func clipWith(_ e: [ClipEffect], _ d: Time) -> Clip {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: d), start: .zero)
        c.effects = e
        return c
    }

    @Test func r1CaptionPop() {
        let c = clipWith(MotionRecipes.captionPop(), Time(3, 1))
        #expect(near(scalePx(at(c, .zero)), 0.90 * W, 1))
        #expect(near(scalePx(at(c, ms(100))), 1.05 * W, 1))
        #expect(near(scalePx(at(c, ms(130))), 1.00 * W, 1))
        #expect(near(scalePx(at(c, Time(2, 1))), 1.00 * W, 1))
        // Linear between the keys: halfway to the peak is 97.5 %.
        #expect(near(scalePx(at(c, ms(50))), 0.975 * W, 1.5))
    }

    @Test func r2And3ZoomInOutAndOutIn() {
        let d = ms(3670)
        for top in [false, true] {
            let c = clipWith(MotionRecipes.zoomInOut(top: top), d)
            #expect(near(scalePx(at(c, ms(970))), 1.10 * W, 1))
            #expect(near(scalePx(at(c, ms(1800))), 1.10 * W, 1))
            #expect(near(scalePx(at(c, ms(2570))), 1.10 * W, 1))
            #expect(near(scalePx(at(c, ms(3670))), 1.00 * W, 1))
            #expect(near(scalePx(at(c, .zero)), 1.00 * W, 1))
            #expect(near(at(c, ms(1800)).opacity, 1, 1e-9))
            if top {   // opacity 0 -> 100 and 100 -> 0 in 0.1 s
                #expect(near(at(c, .zero).opacity, 0, 1e-9) && near(at(c, ms(100)).opacity, 1, 1e-9))
                #expect(near(at(c, ms(3570)).opacity, 1, 1e-9) && near(at(c, ms(3670)).opacity, 0, 1e-9))
            }
        }
        let inv = clipWith(MotionRecipes.zoomOutIn(), d)
        #expect(near(scalePx(at(inv, .zero)), 1.10 * W, 1))
        #expect(near(scalePx(at(inv, ms(970))), 1.00 * W, 1))
        #expect(near(scalePx(at(inv, ms(2570))), 1.00 * W, 1))
        #expect(near(scalePx(at(inv, ms(3670))), 1.10 * W, 1))
    }

    @Test func r4VideoStartIn() {
        let c = clipWith(MotionRecipes.videoStartIn(), Time(5, 1))
        #expect(near(scalePx(at(c, .zero)), W, 1) && near(scalePx(at(c, ms(1800))), 1.10 * W, 1))
        #expect(near(scalePx(at(c, Time(4, 1))), 1.10 * W, 1))
        let blur = c.effects[1].parameters[ClipEffect.blurrinessKey]!
        #expect(near(blur.value(atLocal: .zero), 40, 1e-9) && near(blur.value(atLocal: ms(500)), 0, 1e-9))
    }

    @Test func r5VideoEnd() {
        let d = Time(5, 1)
        let c = clipWith(MotionRecipes.videoEnd(clipDuration: d), d)
        #expect(near(scalePx(at(c, ms(4350))), W, 1) && near(scalePx(at(c, d)), 1.10 * W, 1))
        #expect(near(scalePx(at(c, ms(2000))), W, 1))
        let blur = c.effects[1].parameters[ClipEffect.blurrinessKey]!
        #expect(near(blur.value(atLocal: ms(4830)), 0, 1e-9) && near(blur.value(atLocal: d), 40, 1e-9))
    }

    @Test func r6MoveFrom() {
        let d = Time(4, 1)
        let l = clipWith(MotionRecipes.moveFrom(.left), d)
        #expect(near(at(l, .zero).position.x, -1.02 * W, 1) && near(at(l, ms(830)).position.x, 0, 1))
        let r = clipWith(MotionRecipes.moveFrom(.right), d)
        #expect(near(at(r, .zero).position.x, 1.02 * W, 1) && near(at(r, ms(830)).position.x, 0, 1))
        let b = clipWith(MotionRecipes.moveFrom(.bottom), d)
        #expect(near(at(b, .zero).position.y, 0.085 * H, 1) && near(at(b, ms(1000)).position.y, 0, 1))
        #expect(near(at(b, .zero).opacity, 0, 1e-9) && near(at(b, ms(140)).opacity, 1, 1e-9))
        #expect(near(at(b, ms(500)).opacity, 1, 1e-9))
    }

    @Test func r7MoveTo() {
        let d = Time(4, 1)
        let r = clipWith(MotionRecipes.moveTo(.right), d)
        #expect(near(at(r, ms(3170)).position.x, 0, 1) && near(at(r, d).position.x, 1.01 * W, 1))
        let l = clipWith(MotionRecipes.moveTo(.left), d)
        #expect(near(at(l, d).position.x, -1.005 * W, 1))
        let b = clipWith(MotionRecipes.moveTo(.bottom), d)
        #expect(near(at(b, d).position.y, 0.44 * H, 1) && near(at(b, ms(2900)).position.y, 0, 1))
    }

    @Test func r8SlideInOvershoot() {
        let c = clipWith(MotionRecipes.slideInOvershoot(), Time(4, 1))
        #expect(near(at(c, .zero).position.x, 0.464 * W, 1) && near(at(c, ms(380)).position.x, 0, 1))
        #expect(near(scalePx(at(c, .zero)), 2.0 * W, 1))
        #expect(near(scalePx(at(c, ms(350))), 1.003 * W, 1))
        #expect(near(scalePx(at(c, Time(3, 1))), 1.003 * W, 1))
        // The overshoot: the scale dips to 104.6 on the way down.
        #expect(near(scalePx(at(c, ms(210))), 1.046 * W, 1))
    }

    @Test func r9Fade() {
        let d = Time(4, 1)
        let i = clipWith(MotionRecipes.fadeIn(), d)
        #expect(near(at(i, .zero).opacity, 0, 1e-9) && near(at(i, ms(100)).opacity, 1, 1e-9) && near(at(i, Time(2, 1)).opacity, 1, 1e-9))
        let o = clipWith(MotionRecipes.fadeOut(), d)
        #expect(near(at(o, ms(3900)).opacity, 1, 1e-9) && near(at(o, d).opacity, 0, 1e-9) && near(at(o, ms(1000)).opacity, 1, 1e-9))
    }

    @Test func r10Pop50() {
        let c = clipWith(MotionRecipes.pop50(), Time(3, 1))
        #expect(near(scalePx(at(c, .zero)), 0.50 * W, 1))
        #expect(near(scalePx(at(c, ms(230))), 0.956 * W, 1))
        #expect(near(scalePx(at(c, ms(330))), 0.997 * W, 1))
        #expect(near(scalePx(at(c, Time(2, 1))), 0.997 * W, 1))
    }
}

// Review fixes: canvas-space distances, Pop In & Out normalization, nil clip length.
@Suite struct MotionEffectsCanvasSpaceTests {
    private func moveLeft() -> ClipEffect {
        var e = ClipEffect.make(kind: ClipEffect.moveKind)!
        e.parameters[ClipEffect.moveDirectionKey] = AnimatedProperty(270)
        e.parameters[ClipEffect.moveDistanceKey] = AnimatedProperty(100)
        return e
    }
    private func canvasCentre(_ c: Clip, _ t: Time) -> Vec2 { c.renderTransform(at: t, frame: frame).map(.zero) }

    @Test func moveIsOnCanvasWhateverTheMotionScaleOrRotation() {
        for (scale, rot) in [(0.5, 0.0), (2.0, 0.0), (1.0, 90.0), (0.5, 33.0)] {
            var c = clip([moveLeft()])
            c.animation.scale = AnimatedProperty(Vec2(scale, scale))
            c.animation.rotation = AnimatedProperty(rot)
            let p = canvasCentre(c, .zero)
            #expect(near(p.x, -W, 1e-6) && near(p.y, 0, 1e-6), "scale \(scale) rot \(rot): \(p)")
            #expect(near(canvasCentre(c, Time(2, 1)).x, 0, 1e-6))
        }
    }

    @Test func laterStagesDoNotChangeTheCanvasShift() {
        var zoom = ClipEffect.make(kind: ClipEffect.zoomKind)!
        zoom.parameters[ClipEffect.zoomFromKey] = AnimatedProperty(200)
        zoom.parameters[ClipEffect.zoomToKey] = AnimatedProperty(200)
        var c = clip([moveLeft(), zoom])
        c.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
        #expect(near(canvasCentre(c, .zero).x, -W, 1e-6))
    }

    @Test func shakeAmplitudeIsCanvasSizedAtAnyScale() {
        var e = ClipEffect.make(kind: ClipEffect.shakeKind)!
        e.parameters[ClipEffect.motionModeKey] = AnimatedProperty(3)
        e.parameters[ClipEffect.shakeRotationKey] = AnimatedProperty(0)
        let a = clip([e])
        var b = clip([e])
        b.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
        for ts in [100, 370, 900] as [Int64] {
            let pa = canvasCentre(a, ms(ts)), pb = canvasCentre(b, ms(ts))
            #expect(near(pa.x, pb.x, 1e-6) && near(pa.y, pb.y, 1e-6))
        }
    }

    @Test func popInOutNormalisesBySettle() {
        var e = ClipEffect.make(kind: ClipEffect.popKind)!
        e.parameters[ClipEffect.motionModeKey] = AnimatedProperty(2)
        e.parameters[ClipEffect.popSettleKey] = AnimatedProperty(120)
        #expect(near(at(clip([e]), Time(2, 1)).scale.x, 1.2, 1e-9))
        e.parameters[ClipEffect.motionModeKey] = AnimatedProperty(1)
        #expect(near(at(clip([e]), Time(2, 1)).scale.x, 1.0, 1e-9))
    }

    @Test func nilClipLengthMeansNoEndEdge() {
        var pop = ClipEffect.make(kind: ClipEffect.popKind)!
        pop.parameters[ClipEffect.popSettleKey] = AnimatedProperty(120)
        pop.parameters[ClipEffect.motionModeKey] = AnimatedProperty(1)
        #expect(near(pop.stageTransform(atLocal: Time(2, 1), clipDuration: nil, frame: frame).scale, 1, 1e-9))
        pop.parameters[ClipEffect.motionModeKey] = AnimatedProperty(2)
        #expect(near(pop.stageTransform(atLocal: Time(2, 1), clipDuration: nil, frame: frame).scale, 1.2, 1e-9))
        var mv = moveLeft()
        mv.parameters[ClipEffect.motionModeKey] = AnimatedProperty(1)
        mv.parameters[ClipEffect.moveFadeKey] = AnimatedProperty(1)
        let s = mv.stageTransform(atLocal: Time(2, 1), clipDuration: nil, frame: frame)
        #expect(s.opacity == 1 && s.position == .zero)
    }
}

// N3: loop animators (Bounce, Pulse, Wiggle).
@Suite struct LoopAnimatorTests {
    private func loopClip(_ kind: String, _ set: [String: Double] = [:], text: Bool = false) -> Clip {
        var e = ClipEffect.make(kind: kind)!
        for (k, x) in set { e.parameters[k] = AnimatedProperty(x) }
        var c = clip([e], seconds: 10)
        if text { c.generator = GeneratorRef(kind: GeneratorRef.text, payload: Data(), payloadVersion: 1) }
        return c
    }

    @Test func offeredAsStagesWithoutKeys() {
        for k in [ClipEffect.bounceKind, ClipEffect.pulseKind, ClipEffect.wiggleKind] {
            #expect(EffectCatalog.all.contains { $0.kind == k })
            let e = ClipEffect.make(kind: k)!
            #expect(e.isTransformStage && e.isMotionPreset && e.keyTimes.isEmpty)
        }
    }

    @Test func periodIsExactAndDeterministic() {
        for k in [ClipEffect.bounceKind, ClipEffect.pulseKind, ClipEffect.wiggleKind] {
            let c = loopClip(k, [ClipEffect.loopPeriodKey: 0.8, ClipEffect.wiggleShiftKey: 3, ClipEffect.bounceSquashKey: 20,
                                 ClipEffect.pulseFadeKey: 30])
            for t in [130, 400, 710, 1900] as [Int64] {
                let a = at(c, ms(t)), b = at(c, ms(t + 800 * 3))
                #expect(near(a.position.x, b.position.x, 1e-6) && near(a.position.y, b.position.y, 1e-6))
                #expect(near(a.scale.x, b.scale.x, 1e-9) && near(a.rotation, b.rotation, 1e-6) && near(a.opacity, b.opacity, 1e-9))
                #expect(at(c, ms(t)) == a)
            }
        }
    }

    @Test func bounceHopsUpAndLandsEveryPeriod() {
        let c = loopClip(ClipEffect.bounceKind, [ClipEffect.loopPeriodKey: 1, ClipEffect.bounceHeightKey: 10])
        #expect(near(at(c, ms(0)).map(.zero).y, 0, 1e-6))
        #expect(near(at(c, ms(1000)).map(.zero).y, 0, 1e-6))
        #expect(near(at(c, ms(500)).map(.zero).y, -0.1 * H, 1e-6))
        #expect(near(at(c, ms(500)).map(.zero).x, 0, 1e-6))
        let side = loopClip(ClipEffect.bounceKind, [ClipEffect.loopPeriodKey: 1, ClipEffect.bounceHeightKey: 10,
                                                    ClipEffect.bounceDirectionKey: 90])
        #expect(near(at(side, ms(500)).map(.zero).x, 0.1 * W, 1e-6))
    }

    @Test func pulseBreathesBetweenFromAndTo() {
        let c = loopClip(ClipEffect.pulseKind, [ClipEffect.loopPeriodKey: 2, ClipEffect.pulseFromKey: 100, ClipEffect.pulseToKey: 120])
        #expect(near(at(c, ms(0)).scale.x, 1, 1e-9))
        #expect(near(at(c, ms(1000)).scale.x, 1.2, 1e-9))
        #expect(near(at(c, ms(500)).scale.x, 1.1, 1e-9))
        #expect(near(at(c, ms(2000)).scale.x, 1, 1e-9))
    }

    @Test func wiggleSwingsBothWays() {
        let c = loopClip(ClipEffect.wiggleKind, [ClipEffect.loopPeriodKey: 1, ClipEffect.wiggleAngleKey: 10])
        #expect(near(at(c, ms(250)).rotation, 10, 1e-6))
        #expect(near(at(c, ms(750)).rotation, -10, 1e-6))
        #expect(near(at(c, ms(0)).rotation, 0, 1e-6))
    }

    @Test func phaseShiftsTheLoop() {
        let c = loopClip(ClipEffect.wiggleKind, [ClipEffect.loopPeriodKey: 1, ClipEffect.wiggleAngleKey: 10, ClipEffect.loopPhaseKey: 25])
        #expect(near(at(c, ms(0)).rotation, 10, 1e-6))
    }

    @Test func textClipsLoopLikeAnyClip() {
        // Monitor and export both read `Clip.renderTransform`, so a text clip with the effect gets the same stage in both.
        let c = loopClip(ClipEffect.pulseKind, [ClipEffect.loopPeriodKey: 1], text: true)
        #expect(c.renderTransform(at: ms(500), frame: frame).scale.x > 1.1)
    }
}


@Test func motionCurveDisplayNameIsBezierAndOldDataStillDecodes() throws {
    #expect(MotionCurve.titles.first == "Gentle")
    #expect(MotionCurve.titles.count == MotionCurve.allCases.count)
    #expect(MotionCurve.premiereDefault.rawValue == 0)          // persisted as the index: unchanged
    #expect(EasingCurve.premiereDefault.name == "Classic")
    // A curve saved under the old name still decodes (the name is only a label; the id and handles carry the meaning).
    let old = EasingCurve(name: "Premiere default bezier", interpolation: .bezier,
                          outHandle: EaseHandle(dx: 0.167, dy: 0), inHandle: EaseHandle(dx: 0.167, dy: 0))
    let back = try JSONDecoder().decode(EasingCurve.self, from: JSONEncoder().encode(old))
    #expect(back == old)
}

@Test func ultraKeyEffectKeepsPremiereNameAndKind() {
    let spec = EffectCatalog.all.first { $0.kind == ClipEffect.ultraKeyKind }
    #expect(spec?.title == "Color Key")
    #expect(ClipEffect.ultraKeyKind == "ultraKey")
}
