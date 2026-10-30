import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Every keyed thing of a clip stays on its timeline frame when the clip is cut, also with a speed change
/// (MASTER-LIST: keyframe time remapping on edits).
@Suite struct KeyframeSplitRemapTests {
    private func keyed(speed: ClipSpeed = .normal, dur: Int64 = 10, start: Int64 = 20) -> Clip {
        var c = Clip(name: "c", media: UUID(), kind: .video,
                     source: TimeRange(start: s(0), duration: speed.scale(s(dur))), start: s(start))
        c.speed = speed
        c.animation.opacity.track = KeyframeTrack(keys: [kfKey(0, 0), kfKey(dur, 1)])
        c.effects = [ClipEffect(kind: "blur", parameters: ["radius": AnimatedProperty(0.0, track: KeyframeTrack(keys: [kfKey(0, 0), kfKey(dur, 10)]))])]
        var m = ClipMask(path: .rectangle(Vec2(0.2, 0.2), Vec2(0.8, 0.8)))
        m.opacity = AnimatedProperty(1.0, track: KeyframeTrack(keys: [kfKey(0, 0), kfKey(dur, 1)]))
        c.masks = [m]
        return c
    }

    private func keyTimes(_ c: Clip) -> (opacity: [Time], effect: [Time], mask: [Time]) {
        (c.animation.opacity.track.keys.map(\.time),
         c.effects[0].parameters["radius"]!.track.keys.map(\.time),
         c.masks[0].opacity.track.keys.map(\.time))
    }

    @Test func splitShiftsAllKeyKindsOfTheRightHalf() throws {
        var tr = Track(kind: .video)
        try tr.overwrite(keyed())
        try tr.split(at: s(24))
        let l = keyTimes(tr.clips[0]), r = keyTimes(tr.clips[1])
        #expect(l.opacity == [s(0), s(10)] && l.effect == [s(0), s(10)] && l.mask == [s(0), s(10)])
        #expect(r.opacity == [s(-4), s(6)] && r.effect == [s(-4), s(6)] && r.mask == [s(-4), s(6)])
    }

    @Test func splitOfASpedUpClipKeepsKeysOnTheirTimelineFrames() throws {
        var tr = Track(kind: .video)
        let c = keyed(speed: ClipSpeed(num: 2, den: 1))
        try tr.overwrite(c)
        try tr.split(at: s(25))
        let left = tr.clips[0], right = tr.clips[1]
        #expect(left.timeline.end == s(25) && right.start == s(25))
        for t in [21, 23, 26, 28] as [Int64] {
            let half = t < 25 ? left : right
            #expect(abs(half.transform(at: s(t)).opacity - c.transform(at: s(t)).opacity) < 1e-9)
        }
        #expect(right.source.start == c.source.start + c.speed.scale(s(5)))
    }

    @Test func splitTwiceStaysOnFrame() throws {
        var tr = Track(kind: .video)
        let c = keyed()
        try tr.overwrite(c)
        try tr.split(at: s(23))
        try tr.split(at: s(27))
        #expect(tr.clips.count == 3)
        for t in [21, 22, 24, 26, 28, 29] as [Int64] {
            let half = tr.clips.first { $0.timeline.contains(s(t)) }!
            #expect(abs(half.transform(at: s(t)).opacity - c.transform(at: s(t)).opacity) < 1e-9)
            let e = half.effects[0].parameters["radius"]!.value(atLocal: s(t) - half.start)
            #expect(abs(e - c.effects[0].parameters["radius"]!.value(atLocal: s(t) - c.start)) < 1e-9)
            let m = half.masks[0].opacity.value(atLocal: s(t) - half.start)
            #expect(abs(m - c.masks[0].opacity.value(atLocal: s(t) - c.start)) < 1e-9)
        }
    }
}

@Suite struct KeyInterpolationNamingTests {
    /// The Temporal Interpolation submenu reads the same names as the one-click list.
    @Test func submenuWordingMatchesTheOneClickList() {
        for c in KeyInterpolationChoice.allCases { #expect(c.fullTitle == c.title) }
    }
}
