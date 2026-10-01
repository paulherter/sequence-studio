import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }

@Suite struct TimeInterpolationTests {
    private func pair() throws -> Timeline {
        let link = UUID(), m = UUID()
        let v = Clip(name: "v", media: m, kind: .video, source: TimeRange(start: .zero, duration: f(60)), start: .zero, link: link, mediaDuration: f(600))
        let a = Clip(name: "a", media: m, kind: .audio, source: TimeRange(start: .zero, duration: f(60)), start: .zero, link: link, mediaDuration: f(600))
        var tv = Track(kind: .video), ta = Track(kind: .audio)
        try tv.overwrite(v); try ta.overwrite(a)
        return Timeline(name: "t", frameDuration: fd, tracks: [tv, ta])
    }

    @Test func dialogChangeStoresTheInterpolationOnTheClipAndItsPartner() throws {
        var tl = try pair()
        let id = tl.tracks[0].clips[0].id
        try tl.apply(SpeedChange(speed: ClipSpeed(percent: 50), timeInterpolation: .frameBlend), to: id)
        #expect(tl.tracks[0].clips[0].timeInterpolation == .frameBlend && tl.tracks[1].clips[0].timeInterpolation == .frameBlend)
        #expect(tl.tracks[0].clips[0].duration == f(120))
        // nil leaves it alone
        try tl.apply(SpeedChange(speed: ClipSpeed(percent: 100)), to: id)
        #expect(tl.tracks[0].clips[0].timeInterpolation == .frameBlend)
    }

    @Test func layerRequestCarriesTheInterpolation() throws {
        var tl = try pair()
        let id = tl.tracks[0].clips[0].id
        try tl.setTimeInterpolation(id, .frameBlend)
        #expect(tl.videoLayers(at: f(3)).first?.interpolation == .frameBlend)
    }

    @Test func atHalfSpeedTheSourceTimeFallsBetweenTwoSourceFrames() throws {
        var tl = try pair()
        let id = tl.tracks[0].clips[0].id
        try tl.setSpeed(id, to: ClipSpeed(percent: 50))
        let t = tl.videoLayers(at: f(1)).first!.sourceTime
        #expect(t == Time(1, 60))                       // half a source frame in: weight 0.5 between frame 0 and frame 1
    }

    @Test func averageSpeedOfARemappedClip() throws {
        var tl = try pair()
        let id = tl.tracks[0].clips[0].id
        try tl.editSpeedKeys(id) { k in
            let (n, b) = k.addingKey(at: f(30), frameDuration: fd)!
            return n.settingSpeed(ofSegment: b, to: ClipSpeed(percent: 300), frameDuration: fd)
        }
        let c = tl.tracks[0].clips[0]
        #expect(c.averageSpeed.num * c.duration.value * 1 > 0)
        #expect(c.averageSpeed.unscale(c.retimeSpan) == c.duration)
    }

    @Test func shortenedMediaCutsTheTailOfARemappedTrack() {
        let k = SpeedKeys(segments: [SpeedSegment(duration: f(30), from: .normal), SpeedSegment(duration: f(30), from: ClipSpeed(percent: 200))],
                          origin: .zero)                                   // 30 + 60 = 90 frames of source
        let fit = k.fitting(media: f(70), frameDuration: fd)!
        #expect(fit.hull.end <= f(70) && fit.duration < k.duration && fit.duration >= f(30 + 19))
        #expect(k.fitting(media: f(1000), frameDuration: fd) == k)
        #expect(k.fitting(media: f(0), frameDuration: fd) == nil)
    }

    @Test func movingARampKeepsItsWidth() throws {
        let k = SpeedKeys(segments: [SpeedSegment(duration: f(60), from: .normal), SpeedSegment(duration: f(10), from: .normal, to: ClipSpeed(percent: 300)),
                                     SpeedSegment(duration: f(50), from: ClipSpeed(percent: 300))], origin: .zero)
        let m = try #require(k.movingRamp(atSegment: 1, by: f(10), frameDuration: fd))
        #expect(m.segments.map(\.duration) == [f(70), f(10), f(40)] && m.duration == k.duration)
        #expect(k.movingRamp(atSegment: 1, by: f(500), frameDuration: fd)?.segments[2].duration == f(1))
    }
}

