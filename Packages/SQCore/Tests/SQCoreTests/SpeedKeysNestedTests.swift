import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }

@Suite struct NestedRetimeTests {
    /// Inner: a 10 s video clip and a 10 s audio clip. Outer: one nested clip of the inner sequence.
    private func setup(speed: ClipSpeed = .normal, reversed: Bool = false) -> (outer: Timeline, inner: Timeline) {
        let m = UUID()
        let iv = Clip(name: "iv", media: m, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero, mediaDuration: Time(10, 1))
        let ia = Clip(name: "ia", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero, mediaDuration: Time(10, 1))
        let inner = Timeline(name: "inner", frameDuration: fd, tracks: [Track(kind: .video, clips: [iv]), Track(kind: .audio, clips: [ia])])
        var n = Clip(name: "n", media: inner.id, kind: .video, source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero,
                     mediaDuration: Time(10, 1), sequence: inner.id)
        n.speed = speed; n.reversed = reversed
        let outer = Timeline(name: "outer", frameDuration: fd, tracks: [Track(kind: .video, clips: [n])])
        return (outer, inner)
    }

    @Test func nestedClipCanBeRetimedAndRefreshesItsInnerDuration() throws {
        var (outer, inner) = setup()
        let iv = Clip(name: "iv", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero,
                      mediaDuration: Time(4, 1))
        inner.tracks = [Track(kind: .video, clips: [iv])]
        outer.refreshNestedDurations { $0 == inner.id ? inner.duration : nil }
        #expect(outer.tracks[0].clips[0].mediaDuration == Time(4, 1))
        let id = outer.tracks[0].clips[0].id
        try outer.setSpeed(id, to: pct(200))
        #expect(outer.tracks[0].clips[0].speed == pct(200))
    }

    @Test func innerVideoTimeFollowsTheNestedClipsSpeed() {
        let (outer, inner) = setup(speed: pct(200))
        let layers = outer.videoLayers(at: Time(1, 1), sequences: { $0 == inner.id ? inner : nil })
        #expect(layers.count == 1 && layers[0].sourceTime == Time(2, 1))
        let (rev, inner2) = setup(speed: pct(100), reversed: true)
        let l2 = rev.videoLayers(at: .zero, sequences: { $0 == inner2.id ? inner2 : nil })
        #expect(l2.count == 1 && l2[0].sourceTime == Time(10, 1) - fd)
    }

    @Test func innerAudioSegmentsAreMappedBackThroughTheSpeed() {
        var (outer, inner) = setup(speed: pct(200))                  // outer clip is 5 s long
        var an = outer.tracks[0].clips[0]; an.kind = .audio
        outer.tracks = [Track(kind: .audio, clips: [an])]
        inner.name = "inner"
        let segs = outer.audioSegments(in: TimeRange(start: .zero, duration: Time(5, 1)), sequences: { $0 == inner.id ? inner : nil })
        #expect(segs.count == 1)
        #expect(segs[0].timeline == TimeRange(start: .zero, duration: Time(5, 1)) && segs[0].nests.count == 1)
        #expect(segs[0].clipStart == .zero)
    }

    @Test func nestedClipWithASpeedTrackMapsVideo() throws {
        var (outer, inner) = setup()
        let id = outer.tracks[0].clips[0].id
        try outer.editSpeedKeys(id) { k in
            let (n, b) = k.addingKey(at: Time(5, 1), frameDuration: fd)!
            return n.settingSpeed(ofSegment: b, to: pct(200), frameDuration: fd)
        }
        let n = outer.tracks[0].clips[0]
        #expect(n.speedKeys != nil && n.duration == Time(15, 2))        // 5 s + 5 s of source at 200 %
        let layers = outer.videoLayers(at: Time(6, 1), sequences: { $0 == inner.id ? inner : nil })
        #expect(layers[0].sourceTime == Time(7, 1))
        inner.name = "x"
    }
}
