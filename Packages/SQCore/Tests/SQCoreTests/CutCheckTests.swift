import Foundation
import Testing
@testable import SQCore

private func s(_ n: Int64) -> Time { Time(n, 1) }
private let fd = Time(1, 30)

@Suite struct CutCheckTests {
    func clip(_ m: UUID, _ kind: TrackKind, src: Int64, len: Int64, at: Int64) -> Clip {
        Clip(name: "c", media: m, kind: kind, source: TimeRange(start: s(src), duration: s(len)), start: s(at))
    }
    func tl(_ tracks: [Track], captions: [CaptionTrack] = []) -> Timeline {
        Timeline(name: "t", format: SequenceFormat(frameDuration: fd), tracks: tracks, captionTracks: captions)
    }

    @Test func jumpCutSameMediaSameFraming() {
        let m = UUID()
        let t = tl([Track(kind: .video, clips: [clip(m, .video, src: 0, len: 3, at: 0), clip(m, .video, src: 10, len: 3, at: 3)])])
        let f = CutCheck.analyze(t).filter { $0.kind == .jumpCut }
        #expect(f.count == 1)
        #expect(f[0].time == s(3))
    }

    @Test func noJumpCutWhenSourceContinuousOrFramingDiffers() {
        let m = UUID()
        let cont = tl([Track(kind: .video, clips: [clip(m, .video, src: 0, len: 3, at: 0), clip(m, .video, src: 3, len: 3, at: 3)])])
        #expect(CutCheck.analyze(cont).allSatisfy { $0.kind != .jumpCut })
        var b = clip(m, .video, src: 10, len: 3, at: 3)
        b.animation.scale = AnimatedProperty(Vec2(1.3, 1.3))
        let punch = tl([Track(kind: .video, clips: [clip(m, .video, src: 0, len: 3, at: 0), b])])
        #expect(CutCheck.analyze(punch).allSatisfy { $0.kind != .jumpCut })
        let other = tl([Track(kind: .video, clips: [clip(m, .video, src: 0, len: 3, at: 0), clip(UUID(), .video, src: 0, len: 3, at: 3)])])
        #expect(CutCheck.analyze(other).allSatisfy { $0.kind != .jumpCut })
    }

    @Test func gapsBetweenVideoClips() {
        let t = tl([Track(kind: .video, clips: [clip(UUID(), .video, src: 0, len: 2, at: 0), clip(UUID(), .video, src: 0, len: 2, at: 5)])])
        let g = CutCheck.analyze(t).filter { $0.kind == .gap }
        #expect(g.count == 1)
        #expect(g[0].time == s(2) && g[0].duration == s(3))
    }

    @Test func gapCoveredByOtherTrackIsNoGap() {
        let a = Track(kind: .video, clips: [clip(UUID(), .video, src: 0, len: 2, at: 0), clip(UUID(), .video, src: 0, len: 2, at: 5)])
        let b = Track(kind: .video, clips: [clip(UUID(), .video, src: 0, len: 6, at: 0)])
        #expect(CutCheck.analyze(tl([a, b])).allSatisfy { $0.kind != .gap })
    }

    @Test func audioPopWithoutFade() {
        let m = UUID()
        let t = tl([Track(kind: .audio, clips: [clip(m, .audio, src: 0, len: 2, at: 0), clip(m, .audio, src: 9, len: 2, at: 2)])])
        #expect(CutCheck.analyze(t).filter { $0.kind == .audioPop }.count == 1)
    }

    @Test func audioFadeOrContinuousSourceIsNoPop() {
        let m = UUID()
        var a = clip(m, .audio, src: 0, len: 2, at: 0)
        a.animation.volume = FadeKeys.settingTail(a.animation.volume, marks: &a.audioFades, length: Time(1, 10), duration: s(2), frameDuration: fd)
        let faded = tl([Track(kind: .audio, clips: [a, clip(m, .audio, src: 9, len: 2, at: 2)])])
        #expect(CutCheck.analyze(faded).allSatisfy { $0.kind != .audioPop })
        let cont = tl([Track(kind: .audio, clips: [clip(m, .audio, src: 0, len: 2, at: 0), clip(m, .audio, src: 2, len: 2, at: 2)])])
        #expect(CutCheck.analyze(cont).allSatisfy { $0.kind != .audioPop })
    }

    @Test func captionOutsideSafeZone() {
        let item = CaptionItem(lines: ["hi"], range: TimeRange(start: s(1), duration: s(2)))
        let ct = CaptionTrack(items: [item])
        let t = tl([], captions: [ct])
        let low = NormRect(x: 0.2, y: 0.9, width: 0.6, height: 0.06)
        let mid = NormRect(x: 0.2, y: 0.5, width: 0.6, height: 0.06)
        let bad = CutCheck.analyze(t, platform: .tiktok, captionBounds: { _ in low })
        #expect(bad.filter { $0.kind == .captionOutsideSafeZone }.count == 1)
        #expect(CutCheck.analyze(t, platform: .tiktok, captionBounds: { _ in mid }).isEmpty)
        #expect(CutCheck.analyze(t, platform: nil, captionBounds: { _ in low }).isEmpty)
    }

    @Test func safeZoneMapsToTheCentred9x16WindowOfALandscapeFrame() {
        let vertical = SafeZone.zone(for: .tiktok).rect
        #expect(SafeZone.rect(for: .tiktok, frameAspect: 9.0 / 16) == vertical)
        let wide = SafeZone.rect(for: .tiktok, frameAspect: 16.0 / 9)   // window is (9/16)/(16/9) of the width
        let win = (9.0 / 16) / (16.0 / 9)
        #expect(abs(wide.width - vertical.width * win) < 1e-9)
        #expect(abs(wide.x - ((1 - win) / 2 + vertical.x * win)) < 1e-9)
        #expect(wide.y == vertical.y && wide.height == vertical.height)
        // A caption in the middle of a landscape frame is inside, one at the far left is not.
        let item = CaptionItem(lines: ["hi"], range: TimeRange(start: s(1), duration: s(2)))
        let t = tl([], captions: [CaptionTrack(items: [item])])
        let mid = NormRect(x: 0.4, y: 0.5, width: 0.2, height: 0.06)
        let left = NormRect(x: 0.02, y: 0.5, width: 0.2, height: 0.06)
        #expect(CutCheck.analyze(t, platform: .reels, frameAspect: 16.0 / 9, captionBounds: { _ in mid }).isEmpty)
        #expect(CutCheck.analyze(t, platform: .reels, frameAspect: 16.0 / 9, captionBounds: { _ in left }).count == 1)
    }

    @Test func safeZonesDefinedForEachPlatform() {
        for p in CutCheckPlatform.allCases {
            let z = SafeZone.zone(for: p)
            #expect(z.top > 0 && z.bottom > 0 && z.left > 0 && z.right > 0)
            #expect(z.rect.width > 0 && z.rect.height > 0)
        }
    }

    @Test func statsHistogramAndCutRate() {
        let m = UUID()
        let t = tl([Track(kind: .video, clips: [
            clip(m, .video, src: 0, len: 1, at: 0), clip(m, .video, src: 0, len: 4, at: 1), clip(m, .video, src: 0, len: 15, at: 5)])])
        let st = CutCheck.stats(t)
        #expect(st.shotCount == 3)
        #expect(st.cuts == 2)
        #expect(abs(st.cutsPerMinute - 6.0) < 0.001) // 2 cuts in 20 s
        #expect(abs(st.averageShotSeconds - 20.0 / 3) < 0.001)
        #expect(st.longestShotSeconds == 15 && st.shortestShotSeconds == 1)
        #expect(st.histogram.map(\.count).reduce(0, +) == 3)
        #expect(st.histogram.first { $0.label == "> 4 s" }?.count == 2)
    }

    @Test func statsEmptyTimeline() {
        let st = CutCheck.stats(tl([]))
        #expect(st.shotCount == 0 && st.cutsPerMinute == 0)
    }

    @Test func markersReplacePreviousRunOnly() {
        var t = tl([Track(kind: .video, clips: [clip(UUID(), .video, src: 0, len: 2, at: 0), clip(UUID(), .video, src: 0, len: 2, at: 5)])])
        _ = t.addMarker(at: s(1), name: "mine")
        t.applyCutCheck(CutCheck.analyze(t))
        #expect(t.markers.count == 2)
        t.applyCutCheck(CutCheck.analyze(t))
        #expect(t.markers.count == 2)
        #expect(t.markers.contains { $0.name == "mine" })
        let m = t.markers.first { CutCheck.kind(of: $0) == .gap }
        #expect(m != nil && m?.duration == s(3))
    }
}
