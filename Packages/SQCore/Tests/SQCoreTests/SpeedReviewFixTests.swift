import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }

private func clip(start: Int64 = 0, from: Int64 = 0, frames: Int64, media: Int64 = 3000, kind: TrackKind = .video,
                  link: UUID? = nil, speed: ClipSpeed = .normal, reversed: Bool = false) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: f(from), duration: f(frames)), start: f(start),
         link: link, mediaDuration: f(media), speed: speed, reversed: reversed)
}
private func timeline(_ tracks: [[Clip]], kinds: [TrackKind]? = nil) throws -> Timeline {
    var ts: [Track] = []
    for (i, cs) in tracks.enumerated() {
        var t = Track(kind: kinds?[i] ?? .video)
        for c in cs { try t.overwrite(c) }
        ts.append(t)
    }
    return Timeline(name: "t", frameDuration: fd, tracks: ts)
}

private func keyed(_ c: Clip, _ keys: [Int64]) -> Clip {
    var c = c
    for (i, k) in keys.enumerated() { c.animation.volume.track.insert(Keyframe(time: f(k), value: Double(i))) }
    c.effects = [ClipEffect.roundedCorners()]
    for k in keys { c.effects[0].parameters[ClipEffect.radiusKey]!.track.insert(Keyframe(time: f(k), value: 1.0)) }
    return c
}
private func keyTimes(_ c: Clip) -> [Time] { c.animation.volume.track.keys.map(\.time).sorted() }
private func effectKeyTimes(_ c: Clip) -> [Time] { c.effects[0].parameters[ClipEffect.radiusKey]!.track.keys.map(\.time).sorted() }

@Suite struct SpeedKeyframeTests {
    @Test func keysScaleWithTheNewLength() throws {
        var tl = try timeline([[keyed(clip(from: 0, frames: 60), [20, 40])]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: pct(200))
        #expect(keyTimes(tl.tracks[0].clips[0]) == [f(10), f(20)] && effectKeyTimes(tl.tracks[0].clips[0]) == [f(10), f(20)])
        try tl.setSpeed(id, to: pct(50))                                        // 120 frames
        #expect(keyTimes(tl.tracks[0].clips[0]) == [f(40), f(80)])
    }

    @Test func reversingMirrorsTheKeys() throws {
        var tl = try timeline([[keyed(clip(from: 0, frames: 60), [20])]])
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: .normal, reversed: true)
        #expect(keyTimes(tl.tracks[0].clips[0]) == [f(40)])
        try tl.setSpeed(id, to: pct(200), reversed: false)                      // mirror back, then scale 0.5
        #expect(keyTimes(tl.tracks[0].clips[0]) == [f(10)])
    }

    @Test func rateStretchHeadScalesKeys() throws {
        var tl = try timeline([[keyed(clip(start: 20, from: 0, frames: 60), [30])]])
        let id = tl.tracks[0].clips[0].id
        try tl.rateStretch(id, edge: .head, by: f(-20))                          // 60 -> 80 frames, start 0
        let c = tl.tracks[0].clips[0]
        #expect(c.start == f(0) && c.duration == f(80) && keyTimes(c) == [f(40)])
    }

    @Test func linkedPartnerKeysScaleToo() throws {
        let l = UUID()
        var tl = try timeline([[keyed(clip(from: 0, frames: 60, link: l), [30])],
                               [keyed(clip(from: 0, frames: 60, kind: .audio, link: l), [30])]], kinds: [.video, .audio])
        try tl.setSpeed(tl.tracks[0].clips[0].id, to: pct(200))
        #expect(keyTimes(tl.tracks[0].clips[0]) == [f(15)] && keyTimes(tl.tracks[1].clips[0]) == [f(15)])
    }
}

@Suite struct SpeedReviewFixTests {
    @Test func matchFrameThroughSpeedAndReverse() throws {
        let tl = try timeline([[clip(start: 10, from: 20, frames: 60, speed: pct(200))]])
        let m = try #require(tl.matchFrame(at: f(15)))
        #expect(m.sourceTime == f(30))
        #expect(tl.reverseMatchFrame(media: m.media, sourceTime: f(30), playhead: f(15)) == f(15))
        let tr = try timeline([[clip(start: 10, from: 20, frames: 30, reversed: true)]])
        let r = try #require(tr.matchFrame(at: f(12)))
        #expect(r.sourceTime == f(47))                                           // 50 - 2 - 1
        #expect(tr.reverseMatchFrame(media: r.media, sourceTime: r.sourceTime, playhead: f(12)) == f(12))
    }

    @Test func slipOnReversedClipMovesContentTheSameVisualWay() throws {
        var tl = try timeline([[clip(from: 10, frames: 20, media: 100, reversed: true)]])
        let id = tl.tracks[0].clips[0].id
        let applied = try tl.slip(id, by: f(3))
        #expect(applied == f(3) && tl.tracks[0].clips[0].source.start == f(7))   // positive = earlier source for a reversed clip
        let more = try tl.slip(id, by: f(50))
        #expect(more == f(7) && tl.tracks[0].clips[0].source.start == .zero)    // limited by the media start
        let back = try tl.slip(id, by: f(-500))
        #expect(back == f(-80) && tl.tracks[0].clips[0].source.end == f(100))   // limited by the media end
    }

    @Test func rateStretchAtTheClampKeepsLimits() throws {
        var tl = try timeline([[clip(from: 0, frames: 3000, media: 3000), clip(start: 3000, from: 0, frames: 30)]])
        let id = tl.tracks[0].clips[0].id
        try tl.rateStretch(id, edge: .tail, by: f(-2999))
        let c = tl.tracks[0].clips[0]
        #expect(c.speed == .maximum && c.source.end <= f(3000) && c.duration >= fd)
        var t2 = try timeline([[clip(from: 0, frames: 30, media: 30), clip(start: 100, from: 0, frames: 30)]])
        let id2 = t2.tracks[0].clips[0].id
        try t2.rateStretch(id2, edge: .tail, by: f(100_000))
        let d = t2.tracks[0].clips[0]
        #expect(d.timeline.end <= f(100) && d.source.end <= f(30))
    }

    private func project(_ c: Clip) -> (Project, MediaRef) {
        let v = VideoTrackInfo(width: 1080, height: 1920, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: fd, isVariableFrameRate: false)
        let m = MediaRef(name: "m", path: "/x/m.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(8, 1),
                         info: MediaInfo(duration: Time(8, 1), video: v, audio: nil))
        var p = Project(name: "p")
        var cc = c; cc.media = m.id
        p.add(m)
        var tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video)])
        try? tl.tracks[0].overwrite(cc)
        p.timelines = [tl]
        return (p, m)
    }
    private func shorter(_ m: MediaRef) -> MediaRef { var s = m; s.duration = Time(2, 1); s.info?.duration = Time(2, 1); return s }

    @Test func replaceWithShorterMediaSnapsRetimedForwardClips() throws {
        var (p, m) = project(Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(3, 1)),
                                  start: .zero, mediaDuration: Time(8, 1), speed: pct(33.33)))
        p.replaceMedia(m.id, with: shorter(m))
        let c = p.timelines[0].tracks[0].clips[0]
        #expect(c.source.end <= Time(2, 1) && c.duration == fd * 180 && c.source.duration == pct(33.33).scale(fd * 180))
    }

    @Test func replaceWithShorterMediaCutsTheHeadOfReversedClips() throws {
        var (p, m) = project(Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: Time(1, 1), duration: Time(5, 1)),
                                  start: f(300), mediaDuration: Time(8, 1), reversed: true))      // plays source 6 s ... 1 s
        p.replaceMedia(m.id, with: shorter(m))
        let c = p.timelines[0].tracks[0].clips[0]
        #expect(c.source == TimeRange(start: Time(1, 1), end: Time(2, 1)) && c.start == f(300 + 120) && c.duration == f(30))
        #expect(c.timeline.end == f(450))
    }
}
