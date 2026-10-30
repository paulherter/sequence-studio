import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func ms(_ n: Int64) -> Time { Time(n, 1000) }
private let fd = Time(1, 30)
private let easeOut = EaseHandle(dx: 0.6, dy: 0)
private let easeIn = EaseHandle(dx: 0.4, dy: 0.1)

private func clip(seconds: Int64, start: Time = .zero, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: s(seconds)), start: start)
}

/// Pop-in: Scale 0 → 1 and Opacity 0 → 1 over the first 500 ms, eased.
private func popInClip(seconds: Int64 = 4) -> Clip {
    var c = clip(seconds: seconds)
    c.animation.scale.track = KeyframeTrack(keys: [
        Keyframe(time: .zero, value: Vec2(0, 0), interpolation: .bezier, outHandle: easeOut),
        Keyframe(time: ms(500), value: Vec2(1, 1), interpolation: .bezier, inHandle: easeIn),
    ])
    c.animation.opacity.track = KeyframeTrack(keys: [
        Keyframe(time: .zero, value: 0.0, interpolation: .bezier, outHandle: easeOut),
        Keyframe(time: ms(500), value: 1.0, interpolation: .bezier, inHandle: easeIn),
    ])
    return c
}

@Suite struct EffectPresetTests {
    // MARK: Capture

    @Test func captureTakesAnimatedAndChangedMotionAndAllEffects() {
        var c = popInClip()
        c.animation.rotation = AnimatedProperty(15.0)      // changed static value
        c.effects = [ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(8)])]
        let p = EffectPreset.capture(from: c)
        #expect(p.motionProperties == [.scale, .opacity, .rotation])
        #expect(p.position == nil && p.anchorPoint == nil)
        #expect(p.effects.count == 1 && p.effects[0].kind == ClipEffect.gaussianBlurKind)
        #expect(p.referenceDuration == s(4))
        #expect(p.anchor == .start)
        #expect(!p.isEmpty)
    }

    @Test func captureOfUntouchedClipIsEmpty() {
        #expect(EffectPreset.capture(from: clip(seconds: 3)).isEmpty)
    }

    @Test func captureCanBeLimitedToChosenPropertiesAndEffects() {
        var c = popInClip()
        let blur = ClipEffect(kind: ClipEffect.gaussianBlurKind)
        c.effects = [blur, ClipEffect(kind: ClipEffect.cropKind)]
        let p = EffectPreset.capture(from: c, motion: [.opacity], effects: [blur.id])
        #expect(p.motionProperties == [.opacity])
        #expect(p.effects.map(\.kind) == [ClipEffect.gaussianBlurKind])
    }

    // MARK: Apply (acceptance: pop-in on 2 s and 10 s clips, keys at the start)

    @Test func popInLandsAtStartOfShortAndLongClips() throws {
        let preset = EffectPreset.capture(from: popInClip(seconds: 4))
        for length: Int64 in [2, 10] {
            var target = clip(seconds: length, start: s(7))
            target.applyPreset(preset)
            let scale = target.animation.scale.track.keys
            let opacity = target.animation.opacity.track.keys
            #expect(scale.map(\.time) == [.zero, ms(500)])
            #expect(opacity.map(\.time) == [.zero, ms(500)])
            #expect(scale.map(\.value) == [Vec2(0, 0), Vec2(1, 1)])
            #expect(opacity.map(\.value) == [0, 1])
            // Easing survives.
            #expect(scale[0].outHandle == easeOut && scale[1].inHandle == easeIn)
            #expect(opacity[0].interpolation == .bezier)
            // Evaluates the same as the source at the same clip-local time (timeline time = start + local).
            let src = popInClip()
            #expect(target.transform(at: s(7) + ms(200)) == src.transform(at: ms(200)))
            #expect(target.transform(at: s(7) + s(1)).opacity == 1)
        }
    }

    @Test func applyGivesFreshKeyIDs() {
        let source = popInClip()
        var target = clip(seconds: 2)
        target.applyPreset(EffectPreset.capture(from: source))
        let srcIDs = Set(source.animation.scale.track.keys.map(\.id))
        #expect(srcIDs.isDisjoint(with: target.animation.scale.track.keys.map(\.id)))
    }

    @Test func applyingTwiceGivesEffectKeysFreshIDs() {
        var source = clip(seconds: 4)
        var blur = ClipEffect(kind: ClipEffect.gaussianBlurKind)
        blur.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: .zero, value: 10.0), Keyframe(time: s(1), value: 0.0)]))
        source.effects = [blur]
        let preset = EffectPreset.capture(from: source)
        var target = clip(seconds: 2)
        target.applyPreset(preset)
        target.applyPreset(preset)
        let ids = target.effects.flatMap { $0.parameters.values.flatMap { $0.track.keys.map(\.id) } }
            + blur.parameters.values.flatMap { $0.track.keys.map(\.id) }
        #expect(ids.count == 6 && Set(ids).count == 6)
    }

    @Test func applyGivesColourAndPointKeysFreshIDsAndRemapsThem() {
        var source = clip(seconds: 4)
        var fx = ClipEffect(kind: ClipEffect.dropShadowKind)
        fx.colors[ClipEffect.shadowColorKey] = AnimatedProperty(.black, track: KeyframeTrack(keys: [
            Keyframe(time: s(3), value: EffectColor.black), Keyframe(time: s(4), value: EffectColor.white)]))
        fx.points["center"] = AnimatedProperty(Vec2(0, 0), track: KeyframeTrack(keys: [
            Keyframe(time: s(3), value: Vec2(0, 0)), Keyframe(time: s(4), value: Vec2(10, 10))]))
        source.effects = [fx]
        let preset = EffectPreset.capture(from: source, anchor: .end)
        var target = clip(seconds: 10)
        target.applyPreset(preset)
        target.applyPreset(preset)
        let colourKeys = target.effects.flatMap { $0.colors.values.flatMap(\.track.keys) }
        let pointKeys = target.effects.flatMap { $0.points.values.flatMap(\.track.keys) }
        let srcIDs = Set(fx.colors.values.flatMap { $0.track.keys.map(\.id) } + fx.points.values.flatMap { $0.track.keys.map(\.id) })
        let ids = colourKeys.map(\.id) + pointKeys.map(\.id)
        #expect(ids.count == 8 && Set(ids).count == 8 && srcIDs.isDisjoint(with: ids))
        #expect(colourKeys.map(\.time) == [s(9), s(10), s(9), s(10)])
        #expect(pointKeys.map(\.time) == [s(9), s(10), s(9), s(10)])
    }

    /// A preset saved before v24 stores the Drop Shadow color as three 0...255 channels.
    @Test func legacyDropShadowPresetAppliesWithItsColour() throws {
        var legacy = ClipEffect(kind: ClipEffect.dropShadowKind)
        legacy.parameters = [ClipEffect.shadowRedKey: AnimatedProperty(255), ClipEffect.shadowGreenKey: AnimatedProperty(51),
                             ClipEffect.shadowBlueKey: AnimatedProperty(0), ClipEffect.shadowOpacityKey: AnimatedProperty(50)]
        let old = EffectPreset(referenceDuration: s(4), effects: [legacy])
        let decoded = try EffectPreset(payload: try old.payload(), version: 1)
        var target = clip(seconds: 2)
        target.applyPreset(decoded)
        let e = try #require(target.effects.first)
        #expect(e.parameters[ClipEffect.shadowRedKey] == nil && e.parameters[ClipEffect.shadowGreenKey] == nil
                && e.parameters[ClipEffect.shadowBlueKey] == nil)
        #expect(e.colors[ClipEffect.shadowColorKey]?.value == EffectColor(red: 1, green: 0.2, blue: 0))
        #expect(e.parameters[ClipEffect.shadowOpacityKey]?.value == 50)
    }

    @Test func applyReplacesMotionPropertyButLeavesOthers() {
        var target = clip(seconds: 2)
        target.animation.position = AnimatedProperty(Vec2(10, 20))
        target.animation.scale = AnimatedProperty(Vec2(3, 3))
        target.applyPreset(EffectPreset.capture(from: popInClip()))
        #expect(target.animation.position.value == Vec2(10, 20))
        #expect(target.animation.scale.track.keys.count == 2)
    }

    @Test func effectsAreAppendedWithNewIDsAndRemappedKeys() {
        var source = clip(seconds: 4)
        var blur = ClipEffect(kind: ClipEffect.gaussianBlurKind)
        blur.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(0, track: KeyframeTrack(keys: [
            Keyframe(time: s(3), value: 0.0), Keyframe(time: s(4), value: 20.0),
        ]))
        source.effects = [blur]
        let preset = EffectPreset.capture(from: source, anchor: .end)
        var target = clip(seconds: 10)
        target.effects = [ClipEffect(kind: ClipEffect.cropKind)]
        target.applyPreset(preset)
        #expect(target.effects.map(\.kind) == [ClipEffect.cropKind, ClipEffect.gaussianBlurKind])
        #expect(target.effects[1].id != blur.id)
        let keys = target.effects[1].parameters[ClipEffect.blurrinessKey]?.track.keys.map(\.time)
        #expect(keys == [s(9), s(10)])
    }

    // MARK: Anchors

    @Test func endAnchorKeepsDistanceToClipEnd() {
        let preset = EffectPreset(anchor: .end, referenceDuration: s(4),
                                  opacity: AnimatedProperty(1, track: KeyframeTrack(keys: [
                                      Keyframe(time: s(3), value: 1.0), Keyframe(time: s(4), value: 0.0)])))
        var a = clip(seconds: 2); a.applyPreset(preset)
        #expect(a.animation.opacity.track.keys.map(\.time) == [s(1), s(2)])
        var b = clip(seconds: 10); b.applyPreset(preset)
        #expect(b.animation.opacity.track.keys.map(\.time) == [s(9), s(10)])
    }

    @Test func stretchScalesKeyTimesExactly() {
        let preset = EffectPreset(anchor: .stretch, referenceDuration: s(4),
                                  rotation: AnimatedProperty(0, track: KeyframeTrack(keys: [
                                      Keyframe(time: .zero, value: 0.0), Keyframe(time: s(1), value: 90.0),
                                      Keyframe(time: s(4), value: 360.0)])))
        var a = clip(seconds: 2); a.applyPreset(preset)
        #expect(a.animation.rotation.track.keys.map(\.time) == [.zero, ms(500), s(2)])
        var b = clip(seconds: 10); b.applyPreset(preset)
        #expect(b.animation.rotation.track.keys.map(\.time) == [.zero, Time(5, 2), s(10)])
        // NTSC-ish durations stay rational.
        var c = Clip(name: "c", media: UUID(), kind: .video,
                     source: TimeRange(start: .zero, duration: Time(1001 * 90, 30000)), start: .zero)
        c.applyPreset(preset)
        #expect(c.animation.rotation.track.keys.last?.time == Time(1001 * 90, 30000))
        #expect(c.animation.rotation.track.keys[1].time == Time(1001 * 90, 120000))
    }

    @Test func stretchMapsTimeHelper() {
        #expect(EffectPreset.mapTime(s(1), anchor: .stretch, reference: s(3), target: s(1)) == Time(1, 3))
        #expect(EffectPreset.mapTime(s(1), anchor: .start, reference: s(3), target: s(1)) == s(1))
        #expect(EffectPreset.mapTime(s(1), anchor: .end, reference: s(3), target: s(1)) == s(-1))
        // Zero reference length: stretch falls back to start.
        #expect(EffectPreset.mapTime(s(1), anchor: .stretch, reference: .zero, target: s(5)) == s(1))
    }

    // MARK: Timeline

    @Test func timelineAppliesToVideoClipsOnly() throws {
        var v = Track(kind: .video)
        let a = clip(seconds: 2), b = clip(seconds: 10, start: s(2))
        try v.overwrite(a); try v.overwrite(b)
        var au = Track(kind: .audio)
        let sound = clip(seconds: 2, kind: .audio)
        try au.overwrite(sound)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [v, au])
        let n = try tl.applyPreset(EffectPreset.capture(from: popInClip()), to: [a.id, b.id, sound.id])
        #expect(n == 2)
        let clips = tl.tracks[0].clips
        #expect(clips.allSatisfy { $0.animation.scale.track.keys.map(\.time) == [.zero, ms(500)] })
        #expect(tl.tracks[1].clips[0].animation.opacity.track.isEmpty)
        #expect(throws: EditError.wrongTrackKind) { try tl.applyPreset(EffectPreset.capture(from: popInClip()), to: [sound.id]) }
    }

    /// An audio preset (only audio effects, no Motion) lands on audio clips; video clips in the set are skipped.
    @Test func audioOnlyPresetAppliesToAudioClips() throws {
        var v = Track(kind: .video)
        let pic = clip(seconds: 2)
        try v.overwrite(pic)
        var au = Track(kind: .audio)
        let sound = clip(seconds: 2, kind: .audio)
        try au.overwrite(sound)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [v, au])
        var eq = ClipEffect.make(kind: ClipEffect.audioParametricEQKind)!
        eq.parameters[ClipEffect.peqKey("b4", "Gain")] = AnimatedProperty(1)
        let preset = EffectPreset(anchor: .stretch, referenceDuration: s(3), effects: [eq])
        #expect(preset.isAudioOnly)
        #expect(!EffectPreset.capture(from: popInClip()).isAudioOnly)
        let n = try tl.applyPreset(preset, to: [pic.id, sound.id])
        #expect(n == 1)
        let fx = tl.tracks[1].clips[0].effects
        #expect(fx.map(\.kind) == [ClipEffect.audioParametricEQKind])
        #expect(fx[0].id != eq.id)
        #expect(fx[0].parameters[ClipEffect.peqKey("b4", "Gain")]?.value == 1)
        #expect(tl.tracks[0].clips[0].effects.isEmpty)
        #expect(throws: EditError.wrongTrackKind) { try tl.applyPreset(preset, to: [pic.id]) }
    }

    // MARK: Coding

    @Test func payloadRoundTrips() throws {
        var c = popInClip()
        c.animation.position.track = KeyframeTrack(keys: [
            Keyframe(time: .zero, value: Vec2(0.1, -3.3), outTangent: Vec2(4, 5)), Keyframe(time: s(1), value: Vec2(7, 8))])
        c.effects = [ClipEffect(kind: ClipEffect.gaussianBlurKind, parameters: [ClipEffect.blurrinessKey: AnimatedProperty(0.3)])]
        let p = EffectPreset.capture(from: c, anchor: .stretch)
        let back = try EffectPreset(payload: p.payload(), version: EffectPreset.payloadVersion)
        #expect(back == p)
    }

    @Test func newerPayloadVersionIsRejected() throws {
        let data = try EffectPreset.capture(from: popInClip()).payload()
        #expect(throws: EffectPreset.PayloadError.newerVersion(found: 99, supported: EffectPreset.payloadVersion)) {
            try EffectPreset(payload: data, version: 99)
        }
    }
}
