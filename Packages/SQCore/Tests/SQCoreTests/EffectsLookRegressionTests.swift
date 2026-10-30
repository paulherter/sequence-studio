import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

/// Regression tests for behavior that already existed before the effects-look stream and that the new effects must keep.
@Suite struct EffectsLookRegressionTests {
    private func blurKeyed() -> (Timeline, Clip.ID, ClipEffect.ID) {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: .zero,
                     mediaDuration: s(100))
        let id = c.addEffect(kind: ClipEffect.gaussianBlurKind)!
        var e = c.effects[0]
        e.parameters[ClipEffect.blurrinessKey] = AnimatedProperty(0.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 0.0), Keyframe(time: s(4), value: 20.0)]))
        c.effects[0] = e
        c.animation.opacity.track.insert(Keyframe(time: s(4), value: 0.5))
        var t = Track(kind: .video)
        try! t.overwrite(c)
        return (Timeline(name: "t", frameDuration: fd, tracks: [t]), c.id, id)
    }

    @Test func clipSpeedRescalesEffectAndOpacityKeys() throws {
        var (tl, clip, _) = blurKeyed()
        try tl.setSpeed(clip, to: ClipSpeed(percent: 200))
        let c = tl.tracks[0].clips[0]
        #expect(c.duration == s(5))
        #expect(c.effects[0].parameters[ClipEffect.blurrinessKey]!.track.keys.map(\.time) == [s(0), s(2)])
        #expect(c.animation.opacity.track.keys.map(\.time) == [s(2)])
    }

    @Test func splitKeepsKeysOnTheSameFramesAndGivesBothHalvesTheEffects() throws {
        var (tl, _, _) = blurKeyed()
        try tl.tracks[0].split(at: s(2))
        let (a, b) = (tl.tracks[0].clips[0], tl.tracks[0].clips[1])
        #expect(a.effects.count == 1 && b.effects.count == 1)
        #expect(b.effects[0].parameters[ClipEffect.blurrinessKey]!.track.keys.map(\.time) == [s(-2), s(2)])   // clip-local
        #expect(abs(b.effects(at: s(4)).blur - ClipEffect.gaussianSigma(blurriness: 20)) < 1e-9)           // the frame at 4 s looks as before the split
        #expect(abs(a.effects(at: s(1)).blur - ClipEffect.gaussianSigma(blurriness: 5)) < 1e-9)
    }

    @Test func rippleTrimHeadShiftsEffectKeys() throws {
        var (tl, clip, _) = blurKeyed()
        _ = try tl.trim(clip, edge: .head, by: s(1))
        let c = tl.tracks[0].clips[0]
        #expect(c.effects[0].parameters[ClipEffect.blurrinessKey]!.track.keys.map(\.time) == [s(-1), s(3)])
    }

    @Test func roundedCornersStillWorksAndIsOneInstanceAmongOthers() {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero)
        c.roundedCorners = .roundedCorners(radius: 30)
        _ = c.addEffect(kind: ClipEffect.cropKind)
        #expect(c.roundedCorners?.parameters[ClipEffect.radiusKey]?.value == 30)
        #expect(c.effects(at: s(1)).cornerRadius == 30)
        c.roundedCorners = nil
        #expect(c.effects.count == 1 && c.effects[0].kind == ClipEffect.cropKind)
    }

    @Test func v9ProjectWithOldEffectStillDecodes() throws {
        // An effect as written before this stream: no new fields, parameters by key.
        let json = """
        {"id":"\(UUID().uuidString)","kind":"roundedCorners","enabled":true,"parameters":{"radius":{"value":12,"track":{"keys":[]}}}}
        """
        let e = try JSONDecoder().decode(ClipEffect.self, from: Data(json.utf8))
        #expect(e.kind == ClipEffect.roundedCornersKind && e.parameters[ClipEffect.radiusKey]?.value == 12)
    }
}
