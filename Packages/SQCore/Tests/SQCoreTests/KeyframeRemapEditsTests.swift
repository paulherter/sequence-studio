import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Keys follow their content through speed changes, paste, nest and unnest (master list: "Keyframe time remapping").
@Suite struct KeyframeRemapEditsTests {
    private func keyed() -> (Timeline, Clip.ID) {
        var c = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(10)), start: s(2),
                     mediaDuration: s(100))
        c.animation.opacity = AnimatedProperty(1.0, track: KeyframeTrack(keys: [
            Keyframe(time: s(0), value: 0.0), Keyframe(time: s(4), value: 1.0)]))
        var t = Track(kind: .video)
        try! t.overwrite(c)
        return (Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t]), c.id)
    }

    @Test func speedUpAndBackRestoresKeys() throws {
        var (tl, id) = keyed()
        try tl.setSpeed(id, to: ClipSpeed(percent: 200))
        #expect(tl.tracks[0].clips[0].animation.opacity.track.keys.map(\.time) == [s(0), s(2)])
        try tl.setSpeed(id, to: ClipSpeed(percent: 100))
        #expect(tl.tracks[0].clips[0].animation.opacity.track.keys.map(\.time) == [s(0), s(4)])
    }

    @Test func pasteKeepsClipLocalKeysAndGivesANewID() throws {
        var (tl, id) = keyed()
        let cb = try #require(tl.clipboard(copying: [id]))
        let ids = try tl.paste(cb, at: s(20))
        let pasted = try #require(tl.tracks.flatMap(\.clips).first { $0.id == ids[0] })
        #expect(pasted.id != id)
        #expect(pasted.start == s(20))
        #expect(pasted.animation.opacity.track.keys.map(\.time) == [s(0), s(4)])
        #expect(abs(pasted.transform(at: s(22)).opacity - 0.5) < 1e-9)
    }

    @Test func nestAndUnnestKeepKeys() throws {
        let (tl, id) = keyed()
        var p = Project(name: "P", media: [], timelines: [tl])
        let seq = try p.nest(clips: [id], in: tl.id)
        let inner = try #require(p.timeline(seq)).tracks.flatMap(\.clips)
        #expect(inner.count == 1)
        #expect(inner[0].animation.opacity.track.keys.map(\.time) == [s(0), s(4)])
        let nest = try #require(p.timeline(tl.id)?.tracks.flatMap(\.clips).first { $0.sequence == seq })
        let back = try p.unnest(clip: nest.id, in: tl.id)
        let c = try #require(p.timeline(tl.id)?.tracks.flatMap(\.clips).first { $0.id == back[0] })
        #expect(c.animation.opacity.track.keys.map(\.time) == [s(0), s(4)])
        #expect(c.start == s(2))
    }
}
