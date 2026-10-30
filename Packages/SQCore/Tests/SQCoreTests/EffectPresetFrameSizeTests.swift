import Foundation
import Testing
@testable import SQCore

// C7: a preset remembers the sequence frame it was made on and scales its canvas-pixel values to the frame it is applied
// on, exactly as Change Format conforms a picture (`SequenceConform`): Motion Position and a Group Transform's Position and
// Anchor, by one uniform fill factor (circles stay circles). Anchor Point (layer pixels), Scale and effect points in the
// clip's own pixels stay.

private let portrait = Vec2(1080, 1920)
private let uhd = Vec2(3840, 2160)

private func clip() -> Clip {
    Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
}

private func near(_ a: Vec2, _ b: Vec2, _ tol: Double = 1e-9) -> Bool { abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol }

/// Position keyed with a spatial tangent, a static anchor offset and a Radial Blur center point.
private func sourceClip() -> Clip {
    var c = clip()
    c.animation.position.track = KeyframeTrack(keys: [
        Keyframe(time: .zero, value: Vec2(-300, 600), outTangent: Vec2(108, -192)),
        Keyframe(time: Time(1, 1), value: Vec2(270, -480), inTangent: Vec2(-54, 96)),
    ])
    c.animation.anchor = AnimatedProperty(Vec2(54, 96))
    c.animation.scale = AnimatedProperty(Vec2(1.5, 1.5))
    var fx = ClipEffect(kind: ClipEffect.radialBlurKind)
    fx.points[ClipEffect.radialCenterKey] = AnimatedProperty(Vec2(-108, 192))
    fx.parameters[ClipEffect.radialAmountKey] = AnimatedProperty(40)
    c.effects = [fx]
    return c
}

@Suite struct EffectPresetFrameSizeTests {
    @Test func captureRecordsTheFrameSize() {
        let p = EffectPreset.capture(from: sourceClip(), frameSize: portrait)
        #expect(p.frameSize == portrait)
        #expect(EffectPreset.capture(from: sourceClip()).frameSize == nil)
    }

    @Test func spatialValuesScaleToTheTargetFrame() {
        let p = EffectPreset.capture(from: sourceClip(), frameSize: portrait)
        var t = clip()
        t.applyPreset(p, frameSize: uhd)
        let k = 3840.0 / 1080   // fill: max(3840/1080, 2160/1920), the Change Format default
        #expect(p.spatialScale(to: uhd) == k)
        let keys = t.animation.position.track.keys
        #expect(near(keys[0].value, Vec2(-300 * k, 600 * k)))
        #expect(near(keys[1].value, Vec2(270 * k, -480 * k)))
        #expect(near(keys[0].outTangent, Vec2(108 * k, -192 * k)))
        #expect(near(keys[1].inTangent, Vec2(-54 * k, 96 * k)))
        // Layer pixels and factors stay: Anchor Point, Scale, the effect's sliders and its center (clip pixels).
        #expect(t.animation.anchor.value == Vec2(54, 96))
        #expect(t.animation.scale.value == Vec2(1.5, 1.5))
        #expect(t.effects[0].parameters[ClipEffect.radialAmountKey]?.value == 40)
        #expect(t.effects[0].points[ClipEffect.radialCenterKey]!.value == Vec2(-108, 192))
    }

    /// A circular motion path stays circular (one factor for both axes).
    @Test func uniformFactorKeepsPathShape() {
        var src = clip()
        src.animation.position.track = KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(100, 0)), Keyframe(time: Time(1, 1), value: Vec2(0, 100)),
        ])
        var t = clip()
        t.applyPreset(EffectPreset.capture(from: src, frameSize: Vec2(1920, 1080)), frameSize: portrait)
        let v = t.animation.position.track.keys.map(\.value)
        #expect(abs(v[0].x - v[1].y) < 1e-9)
    }

    /// Group Transform: Position and Anchor (canvas px) scale like Change Format; its Scale (a factor, default 1,1) stays,
    /// so a 16:9 preset applied in 9:16 does not squash the picture. Effect points in clip pixels never scale.
    @Test func groupTransformAndClipPixelPoints() {
        var src = clip()
        var g = ClipEffect(kind: ClipEffect.groupTransformKind)
        g.points[ClipEffect.groupScaleKey] = AnimatedProperty(Vec2(1, 1))
        g.points[ClipEffect.groupPositionKey] = AnimatedProperty(Vec2(100, 50))
        g.points[ClipEffect.groupAnchorKey] = AnimatedProperty(Vec2(10, 20))
        let groupScale = g.points[ClipEffect.groupScaleKey]
        var tw = ClipEffect(kind: ClipEffect.twirlKind)
        tw.points[ClipEffect.twirlCenterKey] = AnimatedProperty(Vec2(30, 40))
        src.effects = [g, tw]
        var t = clip()
        t.applyPreset(EffectPreset.capture(from: src, frameSize: Vec2(1920, 1080)), frameSize: portrait)
        let k = max(1080.0 / 1920, 1920.0 / 1080)
        #expect(near(t.effects[0].points[ClipEffect.groupPositionKey]!.value, Vec2(100 * k, 50 * k)))
        #expect(near(t.effects[0].points[ClipEffect.groupAnchorKey]!.value, Vec2(10 * k, 20 * k)))
        #expect(t.effects[0].points[ClipEffect.groupScaleKey] == groupScale)
        #expect(t.effects[1].points[ClipEffect.twirlCenterKey]!.value == Vec2(30, 40))
    }

    /// A text clip scales per axis, like Change Format's `conformText` (a lower third stays a lower third): a 16:9 preset
    /// with text at x -700 and a Group Transform lands where Change Format would put the same clip in 9:16.
    @Test func textClipScalesPerAxisLikeChangeFormat() {
        let text = GeneratorRef(kind: GeneratorRef.text, payload: Data("t".utf8))
        var src = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                       start: .zero, generator: text)
        src.animation.position = AnimatedProperty(Vec2(-700, 380))
        var g = ClipEffect(kind: ClipEffect.groupTransformKind)
        g.points[ClipEffect.groupPositionKey] = AnimatedProperty(Vec2(100, 50))
        g.points[ClipEffect.groupAnchorKey] = AnimatedProperty(Vec2(10, 20))
        src.effects = [g]
        let wide = SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 25))
        let tall = SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 25))
        let expected = SequenceConform.conformText(src, from: wide, to: tall, blockSize: nil)
        var t = src
        t.animation = ClipAnimation(); t.effects = []
        t.applyPreset(EffectPreset.capture(from: src, frameSize: Vec2(1920, 1080)), frameSize: portrait)
        #expect(near(t.animation.position.value, expected.animation.position.value))
        #expect(near(t.effects[0].points[ClipEffect.groupPositionKey]!.value,
                     expected.effects[0].points[ClipEffect.groupPositionKey]!.value))
        #expect(near(t.effects[0].points[ClipEffect.groupAnchorKey]!.value,
                     expected.effects[0].points[ClipEffect.groupAnchorKey]!.value))
        // A picture clip keeps the uniform factor.
        var v = clip()
        v.applyPreset(EffectPreset.capture(from: src, frameSize: Vec2(1920, 1080)), frameSize: portrait)
        let k = 1920.0 / 1080
        #expect(near(v.animation.position.value, Vec2(-700 * k, 380 * k)))
    }

    /// 1920 x 1080 -> 3840 x 2160 -> 1920 x 1080 gives the original values back. (Across shapes the fill factor is not
    /// its own inverse, as with Change Format.)
    @Test func roundTripHDToUHDAndBack() {
        let src = sourceClip(), hd = Vec2(1920, 1080)
        var big = clip()
        big.applyPreset(EffectPreset.capture(from: src, frameSize: hd), frameSize: uhd)
        #expect(near(big.animation.position.track.keys[0].value, Vec2(-600, 1200)))
        var back = clip()
        back.applyPreset(EffectPreset.capture(from: big, frameSize: uhd), frameSize: hd)
        for (a, b) in zip(back.animation.position.track.keys, src.animation.position.track.keys) {
            #expect(near(a.value, b.value) && near(a.inTangent, b.inTangent) && near(a.outTangent, b.outTangent))
        }
        #expect(back.animation.anchor.value == src.animation.anchor.value)
        #expect(back.effects[0].points[ClipEffect.radialCenterKey]!.value == Vec2(-108, 192))
    }

    @Test func sameSizeUnknownSizeOrNoTargetKeepValues() {
        let src = sourceClip()
        for (made, target) in [(portrait, portrait as Vec2?), (portrait, nil)] {
            var t = clip()
            t.applyPreset(EffectPreset.capture(from: src, frameSize: made), frameSize: target)
            #expect(t.animation.position.track.keys.map(\.value) == src.animation.position.track.keys.map(\.value))
        }
        var old = clip()       // a preset saved before C7 (no frame size) applies unscaled
        old.applyPreset(EffectPreset.capture(from: src), frameSize: uhd)
        #expect(old.animation.position.track.keys.map(\.value) == src.animation.position.track.keys.map(\.value))
        var zero = clip()      // a broken size never divides by zero
        zero.applyPreset(EffectPreset.capture(from: src, frameSize: Vec2(0, 1920)), frameSize: uhd)
        #expect(zero.animation.position.track.keys.map(\.value) == src.animation.position.track.keys.map(\.value))
    }

    @Test func relativeModeScalesThePresetsOffset() {
        var p = EffectPreset(referenceDuration: Time(1, 1), position: AnimatedProperty(Vec2(100, 100)))
        p.frameSize = portrait
        var t = clip()
        t.animation.position = AnimatedProperty(Vec2(10, 10))
        t.applyPreset(p, mode: .relative, frameSize: uhd)
        #expect(near(t.animation.position.value, Vec2(10 + 100 * 3840 / 1080, 10 + 100 * 3840 / 1080)))
    }

    @Test func timelineApplyUsesItsOwnFormat() throws {
        var track = Track(kind: .video)
        let c = clip()
        try track.overwrite(c)
        var tl = Timeline(name: "S", format: SequenceFormat(width: 3840, height: 2160, frameDuration: Time(1, 30)), tracks: [track])
        try tl.applyPreset(EffectPreset.capture(from: sourceClip(), frameSize: portrait), to: [c.id])
        let got = tl.tracks[0].clips[0].animation.position.track.keys[0].value
        #expect(near(got, Vec2(-300 * 3840 / 1080, 600 * 3840 / 1080)))
    }

    /// The field is optional: absent from payloads without it (old builds read new payloads), decoded as nil from old ones.
    @Test func payloadCodingIsAdditive() throws {
        let plain = try EffectPreset.capture(from: sourceClip()).payload()
        #expect(!String(decoding: plain, as: UTF8.self).contains("frameSize"))
        #expect(try EffectPreset(payload: plain, version: 1).frameSize == nil)
        let sized = EffectPreset.capture(from: sourceClip(), frameSize: portrait)
        let back = try EffectPreset(payload: sized.payload(), version: EffectPreset.payloadVersion)
        #expect(back == sized && back.frameSize == portrait)
        #expect(EffectPreset.payloadVersion == 1)
    }
}
