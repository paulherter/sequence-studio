import Foundation
import Testing
@testable import SQCore

// W7.1: an effect with its own transform stage (Transform, Auto Reframe) multiplies onto the clip's Motion; it never
// replaces the user's values or keys.

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 25)

private func clip(_ effects: [ClipEffect] = []) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero)
    c.effects = effects
    return c
}

private func stage(_ values: [String: Double] = [:], kind: String = ClipEffect.transformKind) -> ClipEffect {
    var e = ClipEffect.make(kind: kind)!
    for (k, v) in values { e.parameters[k] = AnimatedProperty(v) }
    return e
}

private func close(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }
private func close(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-9) -> Bool { close(a.x, b.x, tol) && close(a.y, b.y, tol) }

@Suite struct EffectTransformStageCatalogTests {
    @Test func transformIsOfferedAndReframeIsKnownButHidden() {
        #expect(EffectCatalog.all.contains { $0.kind == ClipEffect.transformKind })
        #expect(!EffectCatalog.all.contains { $0.kind == ClipEffect.reframeKind })
        #expect(EffectCatalog.spec(for: ClipEffect.reframeKind) != nil)
        #expect(EffectCatalog.title(for: ClipEffect.transformKind) == "Transform")
        #expect(EffectCatalog.param(ClipEffect.transformKind, ClipEffect.stageShutterAngleKey) != nil)
    }

    @Test func freshStageStartsAtItsOwnHundredPercent() {
        let e = stage()
        #expect(e.isTransformStage)
        let t = e.stageTransform(atLocal: .zero, clipDuration: nil, frame: Vec2(1920, 1080))
        #expect(t == StageTransform.identity)
        #expect(clip([e]).renderTransform(at: s(1), frame: Vec2(1920, 1080)) == clip().transform(at: s(1)))
    }
}

@Suite struct EffectTransformStageEvaluationTests {
    @Test func effectScaleMultipliesOntoBaseScale() {
        var c = clip([stage([ClipEffect.stageScaleKey: 110])])
        c.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        let r = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        #expect(close(r.scale.x, 1.32) && close(r.scale.y, 1.32))
        // The user's own value is untouched.
        #expect(c.transform(at: s(1)).scale == Vec2(1.2, 1.2))
        #expect(c.animation.scale.value == Vec2(1.2, 1.2))
    }

    @Test func userScaleKeysStayUntouchedAndStillAnimate() {
        var c = clip([stage([ClipEffect.stageScaleKey: 110])])
        let keys = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(1, 1)), Keyframe(time: s(2), value: Vec2(1.2, 1.2))])
        c.animation.scale = AnimatedProperty(Vec2(1, 1), track: keys)
        let before = c.animation
        #expect(close(c.renderTransform(at: .zero, frame: Vec2(1920, 1080)).scale.x, 1.1))
        #expect(close(c.renderTransform(at: s(1), frame: Vec2(1920, 1080)).scale.x, 1.21))
        #expect(close(c.renderTransform(at: s(2), frame: Vec2(1920, 1080)).scale.x, 1.32))
        #expect(c.animation == before)
    }

    @Test func positionIsInTheClipsOwnPixelsSoItScalesWithMotion() {
        var c = clip([stage([ClipEffect.stagePositionXKey: 10, ClipEffect.stagePositionYKey: -5])])
        c.animation.scale = AnimatedProperty(Vec2(2, 2))
        c.animation.position = AnimatedProperty(Vec2(100, 50))
        let r = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        #expect(close(r.map(.zero), Vec2(120, 40)))
    }

    @Test func rotationAddsAndPivotsAboutTheEffectAnchor() {
        let c = clip([stage([ClipEffect.stageRotationKey: 90, ClipEffect.stageAnchorXKey: 100])])
        let r = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        #expect(close(r.rotation, 90))
        #expect(close(r.map(Vec2(100, 0)), Vec2(100, 0)))      // the anchor stays where it is
        #expect(close(r.map(Vec2(0, 0)), Vec2(100, -100)))     // clockwise on screen (y down)
    }

    @Test func scaleAboutTheEffectAnchorKeepsThatPoint() {
        var c = clip([stage([ClipEffect.stageScaleKey: 200, ClipEffect.stageAnchorXKey: -50, ClipEffect.stageAnchorYKey: 20])])
        c.animation.position = AnimatedProperty(Vec2(7, 3))
        let r = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        #expect(close(r.map(Vec2(-50, 20)), Vec2(-43, 23)))
        #expect(close(r.map(Vec2(-40, 20)), Vec2(-23, 23)))
    }

    @Test func stagesComposeInListOrder() {
        let move = stage([ClipEffect.stagePositionXKey: 100]), turn = stage([ClipEffect.stageRotationKey: 90])
        // Move first, then turn about the frame center: the moved center swings down.
        #expect(close(clip([move, turn]).renderTransform(at: s(1), frame: Vec2(1920, 1080)).map(.zero), Vec2(0, 100)))
        // Turn first, then move.
        #expect(close(clip([turn, move]).renderTransform(at: s(1), frame: Vec2(1920, 1080)).map(.zero), Vec2(100, 0)))
    }

    @Test func baseAnchorAndRotationStillApplyAfterTheStage() {
        var c = clip([stage([ClipEffect.stagePositionXKey: 10])])
        c.animation.anchor = AnimatedProperty(Vec2(30, 0))
        c.animation.rotation = AnimatedProperty(90)
        c.animation.position = AnimatedProperty(Vec2(5, 5))
        // Base alone maps p to R90 (p - anchor) + position; the stage moved p by (10, 0) first.
        let r = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        #expect(close(r.map(.zero), Vec2(5 - 0, 5 + (10 - 30))))
        #expect(close(r.map(Vec2(30, 0)), Vec2(5, 5 + 10)))
    }

    @Test func opacityMultiplies() {
        var c = clip([stage([ClipEffect.stageOpacityKey: 50])])
        c.animation.opacity = AnimatedProperty(0.8)
        #expect(close(c.renderTransform(at: s(1), frame: Vec2(1920, 1080)).opacity, 0.4))
    }

    @Test func disabledStageIsIgnoredAndOtherEffectsAreNoStage() {
        var e = stage([ClipEffect.stageScaleKey: 300]); e.enabled = false
        var c = clip([e, ClipEffect.make(kind: ClipEffect.gaussianBlurKind)!])
        c.animation.scale = AnimatedProperty(Vec2(1.5, 1.5))
        #expect(c.renderTransform(at: s(1), frame: Vec2(1920, 1080)) == c.transform(at: s(1)))
        #expect(!c.hasTransformStage)
    }

    @Test func stageWorksWithMotionSwitchedOff() {
        var c = clip([stage([ClipEffect.stageScaleKey: 150])])
        c.animation.scale = AnimatedProperty(Vec2(3, 3))
        c.motionEnabled = false
        #expect(close(c.renderTransform(at: s(1), frame: Vec2(1920, 1080)).scale.x, 1.5))
    }

    @Test func nonUniformBaseWithStageRotationKeepsTheCentreRight() {
        var c = clip([stage([ClipEffect.stageRotationKey: 30, ClipEffect.stagePositionXKey: 40])])
        c.animation.scale = AnimatedProperty(Vec2(2, 1))
        c.animation.position = AnimatedProperty(Vec2(10, 0))
        let r = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        // The stage moves the center by 40 clip px, the base stretches x by 2: the center lands at 10 + 80.
        #expect(close(r.map(.zero), Vec2(90, 0)))
        #expect(close(r.rotation, 30) && r.scale == Vec2(2, 1))
    }

    @Test func keyedStageParametersAnimate() {
        var e = stage()
        e.parameters[ClipEffect.stageScaleKey] = AnimatedProperty(100, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 100), Keyframe(time: s(2), value: 200)]))
        let c = clip([e])
        #expect(close(c.renderTransform(at: s(1), frame: Vec2(1920, 1080)).scale.x, 1.5))
    }
}

@Suite struct EffectTransformStageLayerTests {
    private func timeline(_ c: Clip) -> Timeline {
        Timeline(name: "S", format: SequenceFormat(width: 640, height: 360, frameDuration: fd),
                 tracks: [Track(kind: .video, clips: [c])])
    }

    @Test func videoLayersCarryTheComposedTransform() {
        var c = clip([stage([ClipEffect.stageScaleKey: 110])])
        c.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        let l = timeline(c).videoLayers(at: s(1))
        #expect(l.count == 1 && close(l[0].transform.scale.x, 1.32))
        #expect(l[0].motionBlur == nil)
    }

    @Test func shutterAngleGivesSubFrameSamplesAroundTheFrame() throws {
        var e = stage([ClipEffect.stageShutterAngleKey: 180])
        e.parameters[ClipEffect.stagePositionXKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 0), Keyframe(time: s(1), value: 250)]))      // 10 px per frame at 25 fps
        let l = timeline(clip([e])).videoLayers(at: Time(1, 2))
        let mb = try #require(l.first?.motionBlur)
        #expect(mb.transforms.count == EffectTransformStage.sampleCount(shutterAngle: 180))
        #expect(mb.format.width == 640)
        let xs = mb.transforms.map(\.position.x)
        // Half a frame open, centered on the frame: 125 - 2.5 ... 125 + 2.5.
        #expect(close(xs.first!, 122.5, 1e-6) && close(xs.last!, 127.5, 1e-6))
        #expect(close((xs.first! + xs.last!) / 2, l[0].transform.position.x, 1e-6))
        #expect(xs == xs.sorted())
    }

    @Test func noBlurWithoutShutterOrWithoutMotion() {
        var still = stage([ClipEffect.stageShutterAngleKey: 180, ClipEffect.stagePositionXKey: 40])
        #expect(timeline(clip([still])).videoLayers(at: s(1))[0].motionBlur == nil)   // nothing moves
        still.parameters[ClipEffect.stageShutterAngleKey] = AnimatedProperty(0)
        still.parameters[ClipEffect.stagePositionXKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 0), Keyframe(time: s(1), value: 250)]))
        #expect(timeline(clip([still])).videoLayers(at: Time(1, 2))[0].motionBlur == nil)   // shutter closed
    }

    @Test func shutterAlsoBlursTheBaseMotion() throws {
        var c = clip([stage([ClipEffect.stageShutterAngleKey: 360])])
        c.animation.position = AnimatedProperty(.zero, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: .zero), Keyframe(time: s(1), value: Vec2(0, 100))]))
        let mb = try #require(timeline(c).videoLayers(at: Time(1, 2))[0].motionBlur)
        #expect(close(mb.transforms.first!.position.y, 48, 1e-6) && close(mb.transforms.last!.position.y, 52, 1e-6))
    }

    @Test func sampleCountGrowsWithTheAngle() {
        #expect(EffectTransformStage.sampleCount(shutterAngle: 0) == 0)
        #expect(EffectTransformStage.sampleCount(shutterAngle: 10) >= 2)
        #expect(EffectTransformStage.sampleCount(shutterAngle: 180) < EffectTransformStage.sampleCount(shutterAngle: 360))
        #expect(EffectTransformStage.sampleCount(shutterAngle: 720) == EffectTransformStage.sampleCount(shutterAngle: 360))
    }

    /// M7: the per-frame evaluation of a typical clip (Color + Transform x 3, all keyed, one with motion blur) stays far
    /// below the 8 ms tick budget.
    @Test func m7TickWithThreeStagesStaysUnderBudget() {
        func keyed(_ key: String, _ a: Double, _ b: Double) -> ClipEffect {
            var e = stage()
            e.parameters[key] = AnimatedProperty(a, track: KeyframeTrack(keys: [
                Keyframe(time: .zero, value: a, interpolation: .bezier), Keyframe(time: s(2), value: b, interpolation: .bezier)]))
            return e
        }
        var blur = keyed(ClipEffect.stagePositionXKey, 0, 300)
        blur.parameters[ClipEffect.stageShutterAngleKey] = AnimatedProperty(180)
        var c = clip([ClipEffect.make(kind: ClipEffect.colorKind)!, keyed(ClipEffect.stageScaleKey, 100, 120),
                      keyed(ClipEffect.stageRotationKey, 0, 10), blur])
        c.animation.scale = AnimatedProperty(Vec2(1, 1), track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(1, 1)), Keyframe(time: s(3), value: Vec2(1.2, 1.2))]))
        let tl = timeline(c)
        for i in 0..<75 { _ = tl.videoLayers(at: Time(Int64(i), 25)) }   // warm-up
        // CPU time per call (not wall): a descheduled thread under machine load does not count. Median of 4 rounds of 300.
        var rounds: [Double] = []
        for _ in 0..<4 {
            let cpu = SQTiming.cpuMs { for i in 0..<300 { _ = tl.videoLayers(at: Time(Int64(i % 75), 25)) } }
            rounds.append(cpu / 300)
        }
        let best = rounds.min()!
        #expect(best < SQTiming.budget(8), "cpu per tick \(best) ms")
    }
}

@Suite struct EffectTransformStageReframeTests {
    /// The stage values that make a clip with `base` Motion land on the absolute framing (`scale`, `position`, about
    /// `base.anchor`) Auto Reframe planned.
    @Test func reframeStageReachesThePlannedFramingOnTopOfTheBase() {
        let keys = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(100, 0)), Keyframe(time: s(2), value: Vec2(-100, 20))])
        let plan = AnimatedProperty(Vec2(100, 0), track: keys)
        var c = clip()
        c.animation.scale = AnimatedProperty(Vec2(0.5, 0.5))
        c.animation.position = AnimatedProperty(Vec2(30, -10))
        c.animation.anchor = AnimatedProperty(Vec2(12, 4))
        let before = c.animation
        let e = EffectTransformStage.reframeEffect(scale: 1.8, position: plan, base: c.transform(at: c.start))
        #expect(e.kind == ClipEffect.reframeKind)
        c.effects.append(e)
        for t in [Time.zero, s(1), s(2)] {
            let want = plan.value(atLocal: t)
            let r = c.renderTransform(at: t, frame: Vec2(1920, 1080))
            #expect(close(r.scale.x, 1.8) && close(r.scale.y, 1.8))
            #expect(close(r.map(Vec2(12, 4)), want, 1e-9), "anchor lands on the planned position at \(t)")
            #expect(close(r.map(Vec2(112, 4)), want + Vec2(180, 0), 1e-9))
        }
        #expect(c.animation == before)
    }

    @Test func stageParametersSplitIntoScalarKeysForVariantOverrides() {
        let keys = KeyframeTrack(keys: [Keyframe(time: .zero, value: Vec2(10, 0)), Keyframe(time: s(1), value: Vec2(-10, 4))])
        let e = EffectTransformStage.reframeEffect(scale: 2, position: AnimatedProperty(Vec2(10, 0), track: keys),
                                                   base: .identity)
        #expect(e.parameters[ClipEffect.stagePositionXKey]?.track.keys.map(\.value) == [10, -10])
        #expect(e.parameters[ClipEffect.stagePositionYKey]?.track.keys.map(\.value) == [0, 4])
        #expect(e.parameters[ClipEffect.stageScaleKey]?.value == 200)
    }
}

@Suite struct EffectTransformStageFileTests {
    @Test func currentVersionIs28OrLater() { #expect(ProjectFile.currentVersion >= 28) }

    @Test func stageRoundTripsThroughTheProjectFile() throws {
        var c = clip([stage([ClipEffect.stageScaleKey: 110, ClipEffect.stageShutterAngleKey: 180])])
        c.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        let tl = Timeline(name: "S", format: SequenceFormat(width: 640, height: 360, frameDuration: fd),
                          tracks: [Track(kind: .video, clips: [c])])
        let p = Project(name: "P", timelines: [tl])
        let back = try ProjectFile.decode(try ProjectFile.encode(p), migrations: ProjectFile.migrations)
        let bc = back.timelines[0].tracks[0].clips[0]
        #expect(bc.effects == c.effects)
        #expect(close(bc.renderTransform(at: s(1), frame: Vec2(1920, 1080)).scale.x, 1.32))
    }
}

// P5: the Transform effect's optional separate Scale Height (`scaleY`). Absent = linked (Height follows Scale).
@Suite struct EffectTransformStageScaleYTests {
    @Test func freshTransformHasNoScaleYAndIsLinked() {
        let e = stage()
        #expect(e.parameters[ClipEffect.stageScaleYKey] == nil)
        #expect(EffectCatalog.param(ClipEffect.transformKind, ClipEffect.stageScaleYKey) != nil)
        let pair = EffectCatalog.spec(for: ClipEffect.transformKind)?.pair(containing: ClipEffect.stageScaleKey)
        #expect(pair?.linkable == true && pair?.y == ClipEffect.stageScaleYKey)
    }

    @Test func missingScaleYFollowsScale() {
        let t = stage([ClipEffect.stageScaleKey: 150]).stageTransform(atLocal: .zero, clipDuration: nil, frame: Vec2(1920, 1080))
        #expect(close(t.scale, 1.5) && close(t.scaleY, 1.5))
    }

    @Test func separateHeightStretchesOnlyY() {
        let c = clip([stage([ClipEffect.stageScaleKey: 200, ClipEffect.stageScaleYKey: 50])])
        let r = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        #expect(close(r.scale.x, 2) && close(r.scale.y, 0.5))
    }

    @Test func separateHeightMultipliesOntoMotionAndStages() {
        var c = clip([stage([ClipEffect.stageScaleKey: 200, ClipEffect.stageScaleYKey: 50]),
                      stage([ClipEffect.stageScaleKey: 110])])
        c.animation.scale = AnimatedProperty(Vec2(1.2, 1.0))
        let r = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        #expect(close(r.scale.x, 1.2 * 2 * 1.1) && close(r.scale.y, 0.5 * 1.1))
    }

    @Test func separateHeightMapsFramePointsLikeTheStageMap() {
        // Scale about the stage anchor (100, 40): (x, y) -> anchor + (2 (x - 100), 0.5 (y - 40)).
        let c = clip([stage([ClipEffect.stageScaleKey: 200, ClipEffect.stageScaleYKey: 50,
                             ClipEffect.stageAnchorXKey: 100, ClipEffect.stageAnchorYKey: 40])])
        let tr = c.renderTransform(at: s(1), frame: Vec2(1920, 1080))
        let p = tr.map(Vec2(300, 240))
        #expect(close(p, Vec2(100 + 2 * 200, 40 + 0.5 * 200), 1e-6))
    }

    @Test func scaleYKeysAnimate() {
        var e = stage([ClipEffect.stageScaleKey: 100])
        e.parameters[ClipEffect.stageScaleYKey] = AnimatedProperty(
            100, track: KeyframeTrack(keys: [Keyframe(time: .zero, value: 100), Keyframe(time: s(2), value: 50)]))
        let c = clip([e])
        #expect(close(c.renderTransform(at: s(1), frame: Vec2(1920, 1080)).scale.y, 0.75))
        #expect(close(c.renderTransform(at: s(1), frame: Vec2(1920, 1080)).scale.x, 1))
        #expect(!c.transformIsStatic)
    }
}
