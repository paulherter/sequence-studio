import Foundation
import Testing
@testable import SQCore

// FB-G: Motion has its own Shutter Angle (like Transform), and an open shutter on a clip that does not move costs nothing
// (no sub-frame samples are evaluated).

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 25)

private func clip(_ effects: [ClipEffect] = []) -> Clip {
    var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero)
    c.effects = effects
    return c
}

private func stage(_ values: [String: Double] = [:]) -> ClipEffect {
    var e = ClipEffect.make(kind: ClipEffect.transformKind)!
    for (k, v) in values { e.parameters[k] = AnimatedProperty(v) }
    return e
}

private func timeline(_ c: Clip) -> Timeline {
    Timeline(name: "S", format: SequenceFormat(width: 640, height: 360, frameDuration: fd), tracks: [Track(kind: .video, clips: [c])])
}

private func keyedPosition() -> AnimatedProperty<Vec2> {
    AnimatedProperty(.zero, track: KeyframeTrack(keys: [Keyframe(time: .zero, value: .zero), Keyframe(time: s(1), value: Vec2(100, 0))]))
}

@Suite struct MotionShutterTests {
    @Test func motionShutterBlursMotionWithoutAnyEffect() throws {
        var c = clip()
        c.animation.position = keyedPosition()
        c.animation.shutterAngle = AnimatedProperty(360)
        let mb = try #require(timeline(c).videoLayers(at: Time(1, 2))[0].motionBlur)
        #expect(mb.transforms.count == EffectTransformStage.sampleCount(shutterAngle: 360))
        // One full frame (4 px at 100 px/s, 25 fps) centered on the frame.
        #expect(abs(mb.transforms.first!.position.x - 48) < 1e-6 && abs(mb.transforms.last!.position.x - 52) < 1e-6)
    }

    @Test func closedMotionShutterGivesNoSamples() {
        var c = clip()
        c.animation.position = keyedPosition()
        #expect(timeline(c).videoLayers(at: Time(1, 2))[0].motionBlur == nil)
    }

    @Test func motionShutterIsOffWhenMotionIsOff() {
        var c = clip()
        c.animation.position = keyedPosition()
        c.animation.shutterAngle = AnimatedProperty(360)
        c.motionEnabled = false
        #expect(timeline(c).videoLayers(at: Time(1, 2))[0].motionBlur == nil)
    }

    @Test func largestOfMotionAndTransformShutterWins() throws {
        var c = clip([stage([ClipEffect.stageShutterAngleKey: 90])])
        c.animation.position = keyedPosition()
        c.animation.shutterAngle = AnimatedProperty(360)
        let mb = try #require(timeline(c).videoLayers(at: Time(1, 2))[0].motionBlur)
        #expect(mb.transforms.count == EffectTransformStage.sampleCount(shutterAngle: 360))
    }

    @Test func staticClipSkipsTheSamples() {
        // Open shutters, nothing animated: the clip is known to stand still without evaluating a sub-frame.
        var c = clip([stage([ClipEffect.stageShutterAngleKey: 360, ClipEffect.stagePositionXKey: 40])])
        c.animation.shutterAngle = AnimatedProperty(360)
        c.animation.scale = AnimatedProperty(Vec2(1.5, 1.5))
        #expect(c.transformIsStatic)
        #expect(timeline(c).videoLayers(at: s(1))[0].motionBlur == nil)
    }

    @Test func anythingKeyedOrLiveMakesTheClipMove() {
        var keyed = clip()
        keyed.animation.rotation = AnimatedProperty(0, track: KeyframeTrack(keys: [Keyframe(time: .zero, value: 0), Keyframe(time: s(1), value: 90)]))
        #expect(!keyed.transformIsStatic)
        var stageKeyed = stage()
        stageKeyed.parameters[ClipEffect.stageScaleKey] = AnimatedProperty(100, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 100), Keyframe(time: s(1), value: 120)]))
        #expect(!clip([stageKeyed]).transformIsStatic)
        // Motion presets evaluate live from the clip time.
        #expect(!clip([ClipEffect.make(kind: ClipEffect.wiggleKind)!]).transformIsStatic)
        // A disabled keyed stage does not count.
        stageKeyed.enabled = false
        #expect(clip([stageKeyed]).transformIsStatic)
        // Keyed opacity alone moves nothing.
        var faded = clip()
        faded.animation.opacity = AnimatedProperty(1, track: KeyframeTrack(keys: [Keyframe(time: .zero, value: 0), Keyframe(time: s(1), value: 1)]))
        #expect(!faded.transformIsStatic)   // samples carry opacity: keep the exact path
    }

    @Test func shutterAngleRoundTripsAndIsLeftOutAtZero() throws {
        var c = clip()
        let plain = try JSONEncoder().encode(c.animation)
        #expect(!String(decoding: plain, as: UTF8.self).contains("shutterAngle"))
        c.animation.shutterAngle = AnimatedProperty(180)
        let data = try JSONEncoder().encode(c.animation)
        let back = try JSONDecoder().decode(ClipAnimation.self, from: data)
        #expect(back.shutterAngle.value == 180)
        #expect(try JSONDecoder().decode(ClipAnimation.self, from: plain).shutterAngle.value == 0)
    }

    @Test func pastingMotionCarriesTheShutter() {
        var src = clip()
        src.animation.shutterAngle = AnimatedProperty(270)
        var dst = clip()
        dst.replaceMotion(with: src)
        #expect(dst.animation.shutterAngle.value == 270)
    }

    @Test func projectWithMotionShutterIsWrittenAsV40() throws {
        var c = clip()
        var p = Project(name: "p")
        p.timelines = [timeline(c)]
        #expect(ProjectFile.writtenVersion(for: p) < ProjectFile.motionShutterVersion)
        c.animation.shutterAngle = AnimatedProperty(90)
        p.timelines = [timeline(c)]
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.motionShutterVersion)
    }

    @Test func bakedRecordWithOpenShutterIsWrittenAsV40() {
        var c = clip()
        var m = ClipAnimation()
        m.shutterAngle = AnimatedProperty(180)
        c.bakedEffects = [BakedEffect(recipeID: ClipEffect.transformKind, effect: stage(), index: 0, motion: m)]
        var p = Project(name: "p")
        p.timelines = [timeline(c)]
        #expect(p.containsMotionShutter, "Re-open as Effect restores that shutter: older builds would drop it")
        #expect(ProjectFile.writtenVersion(for: p) == ProjectFile.motionShutterVersion)
    }

    @Test func effectPresetCarriesTheShutter() throws {
        var src = clip()
        src.animation.shutterAngle = AnimatedProperty(180)
        let all = EffectPreset.capture(from: src)
        #expect(all.motionProperties.contains(.shutterAngle))
        #expect(!EffectPreset.capture(from: clip()).motionProperties.contains(.shutterAngle), "closed = default, left out")
        let back = try JSONDecoder().decode(EffectPreset.self, from: try all.payload())
        for mode in EffectPreset.ApplyMode.allCases {
            var dst = clip()
            dst.applyPreset(back, mode: mode)
            #expect(dst.animation.shutterAngle.value == 180, "\(mode)")
        }
        let only = EffectPreset.capture(from: src, motion: [.position])
        #expect(only.shutterAngle == nil)
        // Without a shutter the payload is what older builds wrote (and read).
        let plain = try EffectPreset.capture(from: clip()).payload()
        #expect(!String(decoding: plain, as: UTF8.self).contains("shutterAngle"))
    }
}

