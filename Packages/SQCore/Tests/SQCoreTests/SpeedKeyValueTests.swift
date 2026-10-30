import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private func seg(_ frames: Int64, _ a: Double, _ b: Double? = nil) -> SpeedSegment {
    SpeedSegment(duration: f(frames), from: pct(a), to: pct(b ?? a), reversed: false)
}

/// Speed keyframes on the speed track: value at a key, ease between keys, same model as Time Remapping.
@Suite struct SpeedKeyValueTests {
    private func plain(frames: Int64 = 120) -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: f(frames)),
             start: .zero, mediaDuration: f(6000))
    }
    private func timeline(_ c: Clip) throws -> Timeline {
        var t = Track(kind: .video)
        try t.overwrite(c)
        return Timeline(name: "t", frameDuration: fd, tracks: [t])
    }
    private let easeInOut = EaseShape(interpolation: .bezier, out: EaseHandle(dx: 0.42, dy: 0), in: EaseHandle(dx: 0.42, dy: 0))

    @Test func twoKeysGiveARampBetweenThem() throws {
        let one = SpeedKeys(constant: .normal, reversed: false, duration: f(120), origin: f(30))
        let a = try #require(one.settingKeySpeed(atLocal: f(30), to: pct(100), frameDuration: fd))
        let b = try #require(a.settingKeySpeed(atLocal: f(60), to: pct(120), frameDuration: fd))
        #expect(b.boundaries == [f(0), f(30), f(60), f(120)])
        #expect(b.segments.map(\.from) == [pct(100), pct(100), pct(120)])
        #expect(b.segments.map(\.to) == [pct(100), pct(120), pct(120)])
        #expect(b.duration == f(120))
        // Linear ramp over 30 frames from 1.0 to 1.2: span = 30 * 1.1.
        #expect(b.segments[1].span == f(33))
        #expect(b.position(at: f(60)) == f(30 + 30 + 33))
        #expect(b.position(at: f(120)) == f(30 + 30 + 33 + 72))
    }

    @Test func settingAKeyValueIsContinuousAtTheKey() throws {
        let k0 = SpeedKeys(segments: [seg(30, 100), seg(30, 100), seg(60, 100)], origin: f(0))
        let k = try #require(k0.settingKeySpeed(atLocal: f(60), to: pct(200), frameDuration: fd))
        // Position at the key is the end of the ramp 100 -> 200 over 30 frames: 30 + 45.
        #expect(k.position(at: f(60)) == f(75))
        // One frame before and after the key the positions differ by about one frame of the key's speed (no jump).
        let eps = f(1)
        let before = k.position(at: f(60) - eps), after = k.position(at: f(60) + eps)
        #expect(after - before < f(6))
    }

    @Test func easeBetweenKeysIntegratesTheEasedSpeed() throws {
        let k0 = SpeedKeys(segments: [seg(30, 100), seg(30, 100), seg(60, 100)], origin: f(0))
        var k = try #require(k0.settingKeySpeed(atLocal: f(60), to: pct(300), frameDuration: fd))
        let linear = k
        k = try #require(k.settingEase(easeInOut, ofSegment: 1))
        // Symmetric ease covers the same source as the linear ramp (average speed 2.0 over 30 frames).
        #expect(k.segments[1].span == f(60))
        #expect(k.position(at: f(60)) == f(30 + 60))
        // Eased: slower than linear early in the transition.
        #expect(k.position(at: f(40)) < linear.position(at: f(40)))
        #expect(abs(k.speedValue(at: f(45)) - 2.0) < 0.1)
    }

    @Test func settingTheFirstKeyChangesTheStretchBeforeIt() throws {
        let k0 = SpeedKeys(segments: [seg(30, 100), seg(90, 100)], origin: f(0))
        let k = try #require(k0.settingKeySpeed(atLocal: f(30), to: pct(50), frameDuration: fd))
        #expect(k.segments[0].from == pct(50) && k.segments[0].to == pct(50))
        #expect(k.segments[1].from == pct(50))
    }

    @Test func aNewKeyMidRampKeepsTheSpeedThenChanges() throws {
        let k0 = SpeedKeys(segments: [seg(30, 100), seg(30, 100, 200), seg(60, 200)], origin: f(0))
        let k = try #require(k0.settingKeySpeed(atLocal: f(45), to: pct(400), frameDuration: fd))
        #expect(k.boundaries == [f(0), f(30), f(45), f(60), f(120)])
        #expect(k.segments[1].from == pct(100) && k.segments[1].to == pct(400))
        #expect(k.segments[2].from == pct(400) && k.segments[2].to == pct(200))
    }

    @Test func outsideTheClipIsRefused() {
        let k = SpeedKeys(constant: .normal, reversed: false, duration: f(120), origin: f(0))
        #expect(k.settingKeySpeed(atLocal: f(120), to: pct(200), frameDuration: fd) == nil)
    }

    @Test func timelineEditKeepsLengthUndoAndSaveLoad() throws {
        var t = try timeline(plain())
        let c = t.tracks[0].clips[0]
        let before = t
        try t.editSpeedKeys(c.id, keepingKeys: true) { $0.settingKeySpeed(atLocal: f(30), to: pct(100), frameDuration: fd) }
        try t.editSpeedKeys(c.id, keepingKeys: true) { $0.settingKeySpeed(atLocal: f(60), to: pct(150), frameDuration: fd) }
        let out = t.tracks[0].clips[0]
        #expect(out.duration == f(120))
        #expect(out.speedKeys?.segments.count == 3)
        // Source range is the hull of the track, longer than the constant clip's (average speed above 1).
        #expect(out.source.duration > f(120))
        // Snapshot undo: the value type still holds the old state.
        #expect(before.tracks[0].clips[0].speedKeys == nil)
        // Save / load keeps the track bit for bit.
        let data = try JSONEncoder().encode(out)
        let back = try JSONDecoder().decode(Clip.self, from: data)
        #expect(back.speedKeys == out.speedKeys)
    }

    @Test func aFlatRampKeepsItsCurveWhenTheValueDragsThroughIt() throws {
        let k0 = SpeedKeys(segments: [seg(30, 100), seg(30, 100), seg(60, 100)], origin: f(0))
        var k = try #require(k0.settingKeySpeed(atLocal: f(60), to: pct(300), frameDuration: fd))
        k = try #require(k.settingEase(easeInOut, ofSegment: 1))
        let flat = try #require(k.settingKeySpeed(atLocal: f(60), to: pct(100), frameDuration: fd))
        #expect(!flat.segments[1].isRamp)
        let back = try #require(flat.settingKeySpeed(atLocal: f(60), to: pct(300), frameDuration: fd))
        #expect(back.ease(ofSegment: 1) == k.ease(ofSegment: 1))
    }

    @Test func aValueAtClipStartGoesToTheFirstKey() throws {
        let k0 = SpeedKeys(segments: [seg(30, 100), seg(90, 100)], origin: f(0))
        let k = try #require(k0.settingKeySpeed(atLocal: .zero, to: pct(200), frameDuration: fd))
        #expect(k.boundaries == k0.boundaries)                     // no unlisted key
        #expect(k.segments.map(\.from) == [pct(200), pct(200)])
        let plain = SpeedKeys(constant: .normal, reversed: false, duration: f(120), origin: f(0))
        let one = try #require(plain.settingKeySpeed(atLocal: .zero, to: pct(50), frameDuration: fd))
        #expect(one.segments.count == 1 && one.segments[0].from == pct(50))
    }

    @Test func aValueThatLeavesTheMediaIsRefusedWhenAsked() throws {
        var c = plain()
        c.mediaDuration = f(160)                                   // source 30..150, room for little more
        var t = try timeline(c)
        let id = t.tracks[0].clips[0].id
        let before = t
        #expect(throws: EditError.self) {
            try t.editSpeedKeys(id, keepingKeys: true, refuseShortening: true) {
                $0.settingKeySpeed(atLocal: f(30), to: pct(400), frameDuration: fd)
            }
        }
        #expect(t == before)
        // Without the flag the old behavior (cut the tail) stays for band drags.
        try t.editSpeedKeys(id, keepingKeys: true) { $0.settingKeySpeed(atLocal: f(30), to: pct(400), frameDuration: fd) }
        #expect(t.tracks[0].clips[0].duration < f(120))
    }
}
