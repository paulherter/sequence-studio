import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

private func clip(seconds: Int64 = 2, start: Time = .zero) -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(seconds)), start: start)
}

private func transform(_ params: [String: AnimatedProperty<Double>]) -> ClipEffect {
    var e = ClipEffect.make(kind: ClipEffect.transformKind)!
    for (k, v) in params { e.parameters[k] = v }
    return e
}

private func linear(_ pairs: [(Time, Double)]) -> AnimatedProperty<Double> {
    AnimatedProperty(pairs[0].1, track: KeyframeTrack(keys: pairs.map { Keyframe(time: $0.0, value: $0.1) }))
}

private func close(_ a: ClipTransform, _ b: ClipTransform, _ eps: Double = 1e-6) -> Bool {
    abs(a.position.x - b.position.x) < eps && abs(a.position.y - b.position.y) < eps
        && abs(a.scale.x - b.scale.x) < eps && abs(a.scale.y - b.scale.y) < eps
        && abs(a.rotation - b.rotation) < eps && abs(a.opacity - b.opacity) < eps
        && abs(a.anchor.x - b.anchor.x) < eps && abs(a.anchor.y - b.anchor.y) < eps
}

/// Every frame of the clip renders the same.
private func sameRender(_ a: Clip, _ b: Clip) -> Bool {
    var t = a.start
    while t < a.start + a.duration {
        if !close(a.renderTransform(at: t, frame: Vec2(1920, 1080)), b.renderTransform(at: t, frame: Vec2(1920, 1080))) { return false }
        t = t + fd
    }
    return true
}

@Suite struct UserPresetBakeTests {
    // MARK: Apply absolute / relative

    @Test func absoluteApplyStillReplacesUserKeys() {
        var c = clip()
        c.animation.position = AnimatedProperty(.zero, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(0, 0)), Keyframe(time: s(1), value: Vec2(100, 0)),
        ]))
        let p = EffectPreset(referenceDuration: s(2), position: AnimatedProperty(Vec2(50, 20)))
        c.applyPreset(p, mode: .absolute)
        #expect(!c.animation.position.isAnimated)
        #expect(c.animation.position.value == Vec2(50, 20))
    }

    @Test func relativeApplyAddsToUserKeysInsteadOfReplacing() {
        var c = clip()
        c.animation.position = AnimatedProperty(.zero, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(0, 0)), Keyframe(time: s(1), value: Vec2(100, 0)),
        ]))
        c.animation.rotation = AnimatedProperty(10.0)
        let p = EffectPreset(referenceDuration: s(2), position: AnimatedProperty(Vec2(50, 20)),
                             rotation: AnimatedProperty(5.0))
        c.applyPreset(p, mode: .relative)
        let keys = c.animation.position.track.keys
        #expect(keys.map(\.time) == [.zero, s(1)])
        #expect(keys.map(\.value) == [Vec2(50, 20), Vec2(150, 20)])
        #expect(c.animation.rotation.value == 15)
    }

    @Test func relativeScaleAndOpacityMultiplyOntoTheClip() {
        var c = clip()
        c.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        c.animation.opacity = AnimatedProperty(0.8)
        let p = EffectPreset(referenceDuration: s(2), scale: AnimatedProperty(Vec2(1.1, 1.1)), opacity: AnimatedProperty(0.5))
        c.applyPreset(p, mode: .relative)
        #expect(abs(c.animation.scale.value.x - 1.32) < 1e-12)
        #expect(abs(c.animation.opacity.value - 0.4) < 1e-12)
    }

    @Test func relativeAnimatedPresetOnStaticClipKeepsThePresetCurve() {
        var c = clip()
        c.animation.position = AnimatedProperty(Vec2(10, 10))
        let ease = EaseHandle(dx: 0.6, dy: 0)
        let p = EffectPreset(referenceDuration: s(2), position: AnimatedProperty(.zero, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(0, 0), interpolation: .bezier, outHandle: ease),
            Keyframe(time: s(1), value: Vec2(0, -40)),
        ])))
        c.applyPreset(p, mode: .relative)
        let keys = c.animation.position.track.keys
        #expect(keys.map(\.value) == [Vec2(10, 10), Vec2(10, -30)])
        #expect(keys[0].interpolation == .bezier && keys[0].outHandle == ease)
    }

    @Test func relativeWithBothAnimatedSumsAtEveryKeyTime() {
        var c = clip()
        c.animation.rotation = linear([(.zero, 0), (s(1), 90)])
        let p = EffectPreset(referenceDuration: s(2), rotation: linear([(Time(1, 2), 0), (Time(3, 2), 10)]))
        c.applyPreset(p, mode: .relative)
        let keys = c.animation.rotation.track.keys
        #expect(keys.map(\.time) == [.zero, Time(1, 2), s(1), Time(3, 2)])
        // user(t) + preset(t) at each key time; the preset holds 0 before its first key, 10 after its last.
        #expect(keys.map(\.value) == [0, 45, 95, 100])
    }

    @Test func relativeLeavesEffectsAppendedAsBefore() {
        var c = clip()
        let p = EffectPreset(referenceDuration: s(2), effects: [transform([ClipEffect.stageScaleKey: AnimatedProperty(110)])])
        c.applyPreset(p, mode: .relative)
        #expect(c.effects.count == 1 && c.effects[0].kind == ClipEffect.transformKind)
    }

    // MARK: Convert to Keyframes

    @Test func convertStaticStageBakesIntoMotion() throws {
        var c = clip()
        c.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        let fx = transform([ClipEffect.stageScaleKey: AnimatedProperty(110)])
        c.effects = [fx]
        let before = c
        try c.convertToKeyframes(effect: fx.id, frameDuration: fd, frame: Vec2(1920, 1080))
        #expect(c.effects.isEmpty)
        #expect(abs(c.animation.scale.value.x - 1.32) < 1e-9)
        #expect(!c.animation.scale.isAnimated)
        #expect(sameRender(before, c))
        #expect(c.bakedEffects.count == 1)
        #expect(c.bakedEffects[0].recipeID == ClipEffect.transformKind)
        #expect(c.bakedEffects[0].effect == fx)
    }

    @Test func convertAnimatedStageMatchesEveryFrameWithFewKeys() throws {
        var c = clip()
        c.animation.position = AnimatedProperty(Vec2(20, 0))
        let fx = transform([ClipEffect.stagePositionXKey: linear([(.zero, 0), (s(1), 100)])])
        c.effects = [fx]
        let before = c
        try c.convertToKeyframes(effect: fx.id, frameDuration: fd, frame: Vec2(1920, 1080))
        #expect(sameRender(before, c))
        // A linear move needs no per-frame keys: start, end of the move, nothing redundant.
        #expect(c.animation.position.track.keys.count == 2)
        #expect(!c.animation.scale.isAnimated && !c.animation.rotation.isAnimated)
    }

    @Test func convertRotatingStageOnScaledMotionMatchesEveryFrame() throws {
        var c = clip()
        c.animation.scale = linear2([(.zero, 1), (s(2), 1.5)])
        c.animation.position = AnimatedProperty(Vec2(30, -10))
        c.animation.anchor = AnimatedProperty(Vec2(5, 5))
        let fx = transform([ClipEffect.stageRotationKey: linear([(.zero, 0), (s(1), 45)]),
                            ClipEffect.stageAnchorXKey: AnimatedProperty(40),
                            ClipEffect.stageOpacityKey: AnimatedProperty(50)])
        c.effects = [fx]
        let before = c
        try c.convertToKeyframes(effect: fx.id, frameDuration: fd, frame: Vec2(1920, 1080))
        #expect(sameRender(before, c))
    }

    @Test func reopenAsEffectRestoresTheParametersAndMotion() throws {
        var c = clip()
        let blur = ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(4)])
        let fx = transform([ClipEffect.stagePositionXKey: linear([(.zero, 0), (s(1), 100)]),
                            ClipEffect.stageOpacityKey: AnimatedProperty(80)])
        c.effects = [fx, blur]
        c.animation.scale = AnimatedProperty(Vec2(1.2, 1.2))
        let before = c
        try c.convertToKeyframes(effect: fx.id, frameDuration: fd, frame: Vec2(1920, 1080))
        #expect(c.effects == [blur])
        let rec = try #require(c.bakedEffects.first)
        try c.reopenAsEffect(rec.id)
        #expect(c.effects == before.effects)
        #expect(c.animation == before.animation)
        #expect(c.bakedEffects.isEmpty)
    }

    @Test func convertRefusesEffectsWithoutTransformStage() {
        var c = clip()
        let blur = ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(4)])
        c.effects = [blur]
        #expect(!c.canConvertToKeyframes(effect: blur.id))
        #expect(throws: BakeError.notConvertible) { try c.convertToKeyframes(effect: blur.id, frameDuration: fd, frame: Vec2(1920, 1080)) }
    }

    @Test func convertRefusesAStageWithAnotherStageAfterIt() {
        var c = clip()
        let a = transform([ClipEffect.stageScaleKey: AnimatedProperty(110)])
        let b = transform([ClipEffect.stageRotationKey: AnimatedProperty(10)])
        c.effects = [a, b]
        #expect(!c.canConvertToKeyframes(effect: a.id))
        #expect(c.canConvertToKeyframes(effect: b.id))
    }

    @Test func convertRefusesWhenMotionIsSwitchedOff() {
        var c = clip()
        let a = transform([ClipEffect.stageScaleKey: AnimatedProperty(110)])
        c.effects = [a]
        c.motionEnabled = false
        #expect(!c.canConvertToKeyframes(effect: a.id))
    }

    @Test func transitionsHaveNoConvertCommand() throws {
        func handled(_ at: Time) -> Clip {
            Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(1), duration: s(2)), start: at,
                 mediaDuration: s(10))
        }
        let a = handled(.zero), b = handled(s(2))
        let v = Track(kind: .video, clips: [a, b])
        var t = Timeline(name: "s", frameDuration: fd, tracks: [v])
        let id = try t.addTransition(point: .cut(outgoing: a.id, incoming: b.id), kind: .crossDissolve, track: v.id,
                                     duration: Time(1, 2))
        #expect(!t.canConvertToKeyframes(effect: id, in: id))
        #expect(throws: EditError.clipNotFound) { try t.convertToKeyframes(effect: id, in: id) }
    }

    @Test func timelineConvertAndReopenUseTheSequenceFrameRate() throws {
        var c = clip()
        let fx = transform([ClipEffect.stageScaleKey: AnimatedProperty(150)])
        c.effects = [fx]
        var t = Timeline(name: "s", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        try t.convertToKeyframes(effect: fx.id, in: c.id)
        let baked = try #require(t.tracks[0].clips.first)
        #expect(baked.effects.isEmpty && baked.bakedEffects.count == 1)
        try t.reopenAsEffect(baked.bakedEffects[0].id, in: c.id)
        #expect(t.tracks[0].clips.first == c)
    }

    // MARK: Record follows edits and persists

    @Test func headTrimKeepsTheRecordOnTheSameFrames() throws {
        var c = clip(seconds: 4)
        let fx = transform([ClipEffect.stagePositionXKey: linear([(s(1), 0), (s(2), 100)])])
        c.effects = [fx]
        try c.convertToKeyframes(effect: fx.id, frameDuration: fd, frame: Vec2(1920, 1080))
        var trimmed = try #require(c.cropped(to: TimeRange(start: s(1), duration: s(3))))
        try trimmed.reopenAsEffect(trimmed.bakedEffects[0].id)
        let keys = try #require(trimmed.effects.first?.parameters[ClipEffect.stagePositionXKey]?.track.keys)
        #expect(keys.map(\.time) == [.zero, s(1)])
    }

    @Test func recordRoundTripsAndClipsWithoutOneWriteNothing() throws {
        var c = clip()
        let fx = transform([ClipEffect.stageScaleKey: AnimatedProperty(110)])
        c.effects = [fx]
        try c.convertToKeyframes(effect: fx.id, frameDuration: fd, frame: Vec2(1920, 1080))
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Clip.self, from: data) == c)
        let plain = try JSONEncoder().encode(clip())
        let obj = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(obj["bakedEffects"] == nil)
    }

    // MARK: Review fixes

    @Test func onlyTheNewestBakeCanBeReopened() throws {
        var c = clip()
        let a = transform([ClipEffect.stageScaleKey: AnimatedProperty(110)])
        c.effects = [a]
        try c.convertToKeyframes(effect: a.id, frameDuration: fd, frame: Vec2(1920, 1080))
        let b = transform([ClipEffect.stageRotationKey: AnimatedProperty(10)])
        c.effects.append(b)
        let afterA = c
        try c.convertToKeyframes(effect: b.id, frameDuration: fd, frame: Vec2(1920, 1080))
        let (recA, recB) = (c.bakedEffects[0].id, c.bakedEffects[1].id)
        #expect(!c.canReopenAsEffect(recA) && c.canReopenAsEffect(recB))
        #expect(throws: BakeError.notNewest) { try c.reopenAsEffect(recA) }
        try c.reopenAsEffect(recB)
        #expect(c == afterA)
        #expect(c.canReopenAsEffect(recA))
    }

    @Test func convertRefusesWhenAVariantOverridesMotion() {
        var c = clip()
        let a = transform([ClipEffect.stageScaleKey: AnimatedProperty(110)])
        c.effects = [a]
        c.variantOverrides = [UUID(): VariantOverride(scale: AnimatedProperty(Vec2(2, 2)))]
        #expect(!c.canConvertToKeyframes(effect: a.id))
    }

    @Test func convertRefusesTextGenerators() {
        var c = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(2)), start: .zero,
                     generator: GeneratorRef(kind: GeneratorRef.text, payload: Data([1])))
        let a = transform([ClipEffect.stageScaleKey: AnimatedProperty(110)])
        c.effects = [a]
        #expect(!c.canConvertToKeyframes(effect: a.id))
    }

    @Test func convertRefusesAnOpenShutter() {
        var c = clip()
        let a = transform([ClipEffect.stageShutterAngleKey: linear([(.zero, 0), (s(1), 90)])])
        c.effects = [a]
        #expect(!c.canConvertToKeyframes(effect: a.id))
    }

    @Test func insertedFrameHoldFreezesTheBakeRecord() throws {
        var c = clip(seconds: 4)
        let fx = transform([ClipEffect.stagePositionXKey: linear([(.zero, 0), (s(4), 400)])])
        c.effects = [fx]
        try c.convertToKeyframes(effect: fx.id, frameDuration: fd, frame: Vec2(1920, 1080))
        var t = Timeline(name: "s", frameDuration: fd, tracks: [Track(kind: .video, clips: [c])])
        let hold = try t.insertFrameHold(of: c.id, at: s(1), duration: s(1))
        var h = try #require(t.tracks[0].clips.first { $0.id == hold })
        try h.reopenAsEffect(try #require(h.bakedEffects.first).id)
        let x = try #require(h.effects.first?.parameters[ClipEffect.stagePositionXKey])
        #expect(!x.isAnimated && x.value == 100)
    }

    @Test func projectFileIsVersion29() {
        #expect(ProjectFile.currentVersion >= 29)
    }
}

private func linear2(_ pairs: [(Time, Double)]) -> AnimatedProperty<Vec2> {
    AnimatedProperty(Vec2(pairs[0].1, pairs[0].1),
                     track: KeyframeTrack(keys: pairs.map { Keyframe(time: $0.0, value: Vec2($0.1, $0.1)) }))
}
