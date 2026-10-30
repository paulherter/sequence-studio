import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

private func vclip(dur: Int64, start: Int64 = 0) -> Clip {
    Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: s(0), duration: s(dur)), start: s(start))
}

private func zoomClip(dur: Int64) -> Clip {
    var c = vclip(dur: dur)
    c.animation.scale = AnimatedProperty(Vec2(1, 1), track: KeyframeTrack(keys: [
        Keyframe(time: s(0), value: Vec2(1, 1)), Keyframe(time: s(2), value: Vec2(1.2, 1.2))]))
    return c
}

@Suite struct PasteAttributesScaleTimesTests {
    @Test func offKeepsKeyTimes() {
        let out = vclip(dur: 1).pastingAttributes(from: zoomClip(dur: 2), groups: [.motion])
        #expect(out.animation.scale.track.keys.map(\.time) == [s(0), s(2)])
    }

    @Test func onStretchesKeysToTheTargetLength() {
        let out = vclip(dur: 1).pastingAttributes(from: zoomClip(dur: 2), groups: [.motion], scaleTimes: true)
        #expect(out.animation.scale.track.keys.map(\.time) == [s(0), s(1)])
    }

    @Test func timelinePasteScalesPerTarget() throws {
        var t = Track(kind: .video)
        let a = vclip(dur: 1)
        let b = vclip(dur: 4, start: 1)
        try t.overwrite(a); try t.overwrite(b)
        var tl = Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t])
        try tl.pasteAttributes(from: zoomClip(dur: 2), to: [a.id, b.id], groups: [.motion], scaleTimes: true)
        #expect(tl.tracks[0].clips.first { $0.id == a.id }?.animation.scale.track.keys.map(\.time) == [s(0), s(1)])
        #expect(tl.tracks[0].clips.first { $0.id == b.id }?.animation.scale.track.keys.map(\.time) == [s(0), s(4)])
    }
}
