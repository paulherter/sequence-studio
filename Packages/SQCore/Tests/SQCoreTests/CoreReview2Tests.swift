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
