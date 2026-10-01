import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let frame = Time(1, 30)
private func audio() -> Clip {
    Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: s(10)), start: .zero)
}
private func video(_ frames: Int64) -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: frame * frames), start: .zero)
}

@Suite struct CoreReview2Tests {
    @Test func audioFadeRemovalRestoresUserKeyAtClipStart() {
        var c = audio()
        c.animation.volume = AnimatedProperty(1.0)
        c.animation.volume.track.insert(Keyframe(time: .zero, value: 0.5))
        c.animation.volume.track.insert(Keyframe(time: s(5), value: 0.8))
        let before = c.animation.volume.track.keys
        c.setAudioFadeIn(s(1), frameDuration: frame)
        c.setAudioFadeIn(.zero, frameDuration: frame)
        #expect(c.animation.volume.track.keys == before)
    }

    @Test func audioFadeRemovalRestoresUserKeyAtClipEnd() {
        var c = audio()
        c.animation.volume = AnimatedProperty(1.0)
        c.animation.volume.track.insert(Keyframe(time: s(10), value: 0.4))
        c.animation.volume.track.insert(Keyframe(time: s(5), value: 0.8))
        let before = c.animation.volume.track.keys
        c.setAudioFadeOut(s(1), frameDuration: frame)
        c.setAudioFadeOut(s(2), frameDuration: frame)
        c.setAudioFadeOut(.zero, frameDuration: frame)
        #expect(c.animation.volume.track.keys == before)
    }

    @Test func videoFadesOnAThreeFrameClipDoNotCross() {
        var c = video(3)
        c.applyVideoFade(.head, duration: s(1), frameDuration: frame)
        c.applyVideoFade(.tail, duration: s(1), frameDuration: frame)
        #expect(c.animation.opacity.track.keys.map(\.value).max() == 1)
    }

    @Test func videoFadeOnAOneFrameClipLeavesItVisible() {
        var c = video(1)
        c.applyVideoFade(.head, duration: s(1), frameDuration: frame)
        c.applyVideoFade(.tail, duration: s(1), frameDuration: frame)
        #expect((c.animation.opacity.track.keys.map(\.value).max() ?? 1) == 1)
    }

    @Test func duckingWithZeroFadeStillDucks() {
        var c = audio()
        let n = c.applyDucking(dialogue: [TimeRange(start: s(2), duration: s(2))], amountDB: 12, fade: .zero)
        #expect(n > 0)
        #expect(c.volume(at: s(3)) < 0.3)
    }
}

private func f(_ n: Int64) -> Time { Time(n, 30) }
private func kclip(start: Int64 = 0) -> Clip {
    var c = Clip(name: "K", media: UUID(), kind: .video, source: TimeRange(start: f(60), duration: f(60)), start: f(start),
                 mediaDuration: f(300))
    c.setSpeedKeys(SpeedKeys(segments: [SpeedSegment(duration: f(30), from: .normal),
                                        SpeedSegment(duration: f(30), from: ClipSpeed(num: 2, den: 1))], origin: f(60)))
    return c
}

@Suite struct CoreReview2TransitionSpeedTests {
    @Test func sourceRangeOutsideAKeyedClipDoesNotTrap() {
        let c = kclip()
        let r = c.sourceRange(fromLocal: f(-10), toLocal: f(-5))
        #expect(r.start <= r.end)
        let r2 = c.sourceRange(fromLocal: f(70), toLocal: f(80))
        #expect(r2.start <= r2.end)
    }

    @Test func setTransitionNeverStoresOneThatFitsNoFrame() throws {
        func clip(_ name: String, _ start: Int64, from: Int64) -> Clip {
            Clip(name: name, media: UUID(), kind: .video, source: TimeRange(start: f(from), duration: f(60)), start: f(start),
                 mediaDuration: f(300))
        }
        let a = clip("A", 0, from: 30), b = clip("B", 60, from: 0)
        var t = Track(kind: .video); try t.overwrite(a); try t.overwrite(b)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t])
        let tr = tl.tracks[0].id
        let id = try tl.addTransition(kind: .crossDissolve, track: tr, outgoing: a.id, incoming: b.id, duration: f(20))
        #expect(throws: EditError.self) { try tl.setTransition(id, alignment: .endAtCut) }
        #expect(tl.resolvedTransitions(on: tr).count == 1)
    }

    @Test func reversingAKeyedClipMirrorsItsOpacityKeys() throws {
        var c = kclip()
        c.animation.opacity.track.insert(Keyframe(time: f(10), value: 0.5))
        var t = Track(kind: .video); try t.overwrite(c)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t])
        try tl.setSpeed(c.id, to: .normal, reversed: true)
        let out = try #require(tl.tracks[0].clips.first)
        let k = try #require(out.animation.opacity.track.keys.first)
        let half = Time(out.duration.value, out.duration.timescale * 2)
        #expect(k.time > half)                       // key was early in the clip; reversed it sits late
    }

    @Test func removingAKeyKeepsTheEndPositionExact() {
        let fr = Time(1001, 30000)
        let k = SpeedKeys(segments: [SpeedSegment(duration: fr * 10, from: ClipSpeed(num: 1, den: 3)),
                                     SpeedSegment(duration: fr * 10, from: ClipSpeed(num: 1, den: 2))], origin: .zero)
        #expect(k.removingKey(atBoundary: 1)?.endPosition == k.endPosition)
    }
}
