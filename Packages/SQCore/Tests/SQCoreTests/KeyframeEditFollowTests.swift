import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private func keyed(_ start: Int64, _ dur: Int64, src: Int64 = 0, key: Int64, media: Int64? = 100) -> Clip {
    var c = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: s(src), duration: s(dur)),
                 start: s(start), mediaDuration: media.map(s))
    c.animation.opacity.track = KeyframeTrack(keys: [kfKey(key, 0.5)])
    return c
}
private func keyTime(_ c: Clip) -> Time { c.animation.opacity.track.keys[0].time }
private func timeline(_ clips: [Clip]) throws -> Timeline {
    var t = Track(kind: .video)
    for c in clips { try t.overwrite(c) }
    return Timeline(name: "t", frameDuration: Time(1, 30), tracks: [t])
}

@Suite struct KeyframeEditFollowTests {
    @Test func trimHeadKeepsKeyOnSourceFrame() throws {
        let c = keyed(10, 10, key: 2)
        var tl = try timeline([c])
        _ = try tl.trim(c.id, edge: .head, by: s(1))
        let n = tl.tracks[0].clips[0]
        #expect(n.source.start == s(1))
        #expect(keyTime(n) == s(1))                       // still source frame 2
    }
    @Test func trimHeadPastKeyKeepsItOffscreen() throws {
        let c = keyed(10, 10, key: 2)
        var tl = try timeline([c])
        _ = try tl.trim(c.id, edge: .head, by: s(4))
        #expect(keyTime(tl.tracks[0].clips[0]) == s(-2))
    }
    @Test func trimInThenOutRestoresKey() throws {
        let c = keyed(10, 10, src: 5, key: 2)
        var tl = try timeline([c])
        _ = try tl.trim(c.id, edge: .head, by: s(4))
        _ = try tl.trim(c.id, edge: .head, by: s(-4))
        #expect(keyTime(tl.tracks[0].clips[0]) == s(2))
        #expect(tl.tracks[0].clips[0].source.start == s(5))
    }
    @Test func rippleTrimHeadKeepsKey() throws {
        let c = keyed(10, 10, key: 2)
        var tl = try timeline([c])
        _ = try tl.rippleTrim(c.id, edge: .head, by: s(1))
        #expect(keyTime(tl.tracks[0].clips[0]) == s(1))
    }
    @Test func rippleTrimToPlayheadHeadKeepsKey() throws {
        let c = keyed(10, 10, key: 5)
        var tl = try timeline([c])
        _ = try tl.rippleTrimToPlayhead(.head, at: s(13), tracks: nil)
        let n = tl.tracks[0].clips[0]
        #expect(n.source.start == s(3))
        #expect(keyTime(n) == s(2))
    }
    @Test func tailTrimLeavesKeyAlone() throws {
        let c = keyed(10, 10, key: 2)
        var tl = try timeline([c])
        _ = try tl.trim(c.id, edge: .tail, by: s(-3))
        #expect(keyTime(tl.tracks[0].clips[0]) == s(2))
    }
    @Test func rollShiftsIncomingClipKeys() throws {
        let a = keyed(0, 10, key: 1), b = keyed(10, 10, src: 20, key: 3)
        var tl = try timeline([a, b])
        _ = try tl.roll(a.id, by: s(2))
        let cs = tl.tracks[0].clips
        #expect(cs[1].source.start == s(22))
        #expect(keyTime(cs[1]) == s(1))
        #expect(keyTime(cs[0]) == s(1))
    }
    @Test func slideShiftsNeighbourKeys() throws {
        let a = keyed(0, 10, key: 1), m = keyed(10, 10, src: 50, key: 4), b = keyed(20, 10, src: 30, key: 6)
        var tl = try timeline([a, m, b])
        _ = try tl.slide(m.id, by: s(2))
        let cs = tl.tracks[0].clips
        #expect(cs[2].source.start == s(32))
        #expect(keyTime(cs[2]) == s(4))                   // next: key follows media
        #expect(keyTime(cs[0]) == s(1))                   // previous: tail only
        #expect(keyTime(cs[1]) == s(4))                   // moved clip keeps own keys
    }
    @Test func slipMovesKeysWithContent() throws {
        let c = keyed(10, 10, src: 5, key: 2)
        var tl = try timeline([c])
        _ = try tl.slip(c.id, by: s(3))
        let n = tl.tracks[0].clips[0]
        #expect(n.source.start == s(8))
        #expect(keyTime(n) == s(-1))                      // still on source frame 7, now before the clip start
    }
    @Test func slipKeyframesStayKeepsKeyOnTimeline() throws {
        let c = keyed(10, 10, src: 5, key: 2)
        var tl = try timeline([c])
        _ = try tl.slip(c.id, by: s(3), keyframes: .stay)
        let n = tl.tracks[0].clips[0]
        #expect(n.source.start == s(8))
        #expect(keyTime(n) == s(2))                       // same timeline position, new content under it
    }
    @Test func slipKeysFollowOnlyTheClampedAmount() throws {
        let c = keyed(10, 10, src: 5, key: 2, media: 20)  // 5 frames of later source left
        var tl = try timeline([c])
        let d = try tl.slip(c.id, by: s(8))
        #expect(d == s(5))
        #expect(keyTime(tl.tracks[0].clips[0]) == s(-3))
    }
    @Test func slipBackAndForthRestoresKeys() throws {
        let c = keyed(10, 10, src: 5, key: 2)
        var tl = try timeline([c])
        _ = try tl.slip(c.id, by: s(-4))
        #expect(keyTime(tl.tracks[0].clips[0]) == s(6))
        _ = try tl.slip(c.id, by: s(4))
        #expect(keyTime(tl.tracks[0].clips[0]) == s(2))
    }
    @Test func slipMovesEffectKeysAndStayLeavesThem() throws {
        var c = keyed(10, 10, src: 5, key: 2)
        var e = ClipEffect(kind: "test")
        e.parameters["amount"] = AnimatedProperty(0, track: KeyframeTrack(keys: [kfKey(4, 1)]))
        c.effects = [e]
        var tl = try timeline([c])
        _ = try tl.slip(c.id, by: s(1))
        #expect(tl.tracks[0].clips[0].effects[0].parameters["amount"]?.track.keys[0].time == s(3))
        _ = try tl.slip(c.id, by: s(1), keyframes: .stay)
        #expect(tl.tracks[0].clips[0].effects[0].parameters["amount"]?.track.keys[0].time == s(3))
        #expect(tl.tracks[0].clips[0].source.start == s(7))
    }
}
