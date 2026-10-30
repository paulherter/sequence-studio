import Foundation
import Testing
@testable import SQCore

private let fd = Time(1, 30)
private func f(_ n: Int64) -> Time { Time(n, 30) }
private func pct(_ p: Double) -> ClipSpeed { ClipSpeed(percent: p) }
private func seg(_ frames: Int64, _ a: Double, _ b: Double? = nil) -> SpeedSegment {
    SpeedSegment(duration: f(frames), from: pct(a), to: pct(b ?? a), reversed: false)
}

/// A speed key the user adds (Effect Controls diamond) changes nothing until it is dragged: normalization keeps a key
/// between two equal speeds instead of merging it away (Premiere keeps such keys too); only a track that is uniform as a
/// whole collapses to a constant clip, and the diamond opts out of that. See the design notes.
@Suite struct SpeedKeysNoChangeKeyTests {
    private func timeline(_ c: Clip) throws -> Timeline {
        var t = Track(kind: .video)
        try t.overwrite(c)
        return Timeline(name: "t", frameDuration: fd, tracks: [t])
    }
    private func plain(frames: Int64 = 96, speed: ClipSpeed = .normal) -> Clip {
        Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: f(30), duration: speed.scale(f(frames))),
             start: .zero, mediaDuration: f(6000), speed: speed)
    }

    @Test func normalizationKeepsAKeyBetweenEqualSpeeds() {
        let k = SpeedKeys(segments: [seg(24, 100), seg(24, 100), seg(48, 200)], origin: f(30))
        #expect(k.normalized().boundaries == [f(0), f(24), f(48), f(96)])
    }

    @Test func aUniformTrackCollapsesUnlessAsked() {
        let k = SpeedKeys(segments: [seg(24, 100), seg(72, 100)], origin: f(30))
        #expect(k.isUniform && k.normalized().segments.count == 1 && k.normalized().duration == f(96))
        #expect(k.normalized(collapsingUniform: false).boundaries == [f(0), f(24), f(96)])
        #expect(!SpeedKeys(segments: [seg(24, 100), seg(72, 100, 200)], origin: f(30)).isUniform)
    }

    @Test func removingARampLeavesOneKey() throws {
        let k = SpeedKeys(segments: [seg(30, 100), seg(10, 100, 200), seg(30, 200)], origin: f(30))
        let r = try #require(k.removingRamp(atSegment: 1, frameDuration: fd))
        #expect(r.segments.map(\.from) == [pct(100), pct(200)] && r.boundaries == [f(0), f(35), f(70)])
    }

    @Test func normalizationStillDropsEmptySegments() {
        let k = SpeedKeys(segments: [seg(24, 100), seg(0, 300), seg(72, 50)], origin: f(30))
        #expect(k.normalized().segments.map(\.duration) == [f(24), f(72)])
    }

    @Test func addingAKeyToAConstantClipChangesNothingButTheKey() throws {
        let c = plain(speed: pct(150))
        var tl = try timeline(c)
        let before = (0..<Int64(c.duration.frameIndex(frameDuration: fd))).map { c.sourceTime(at: f($0), frameDuration: fd) }
        let delta = try tl.editSpeedKeys(c.id, keepingKeys: true) { $0.addingKey(at: f(24), frameDuration: fd)?.keys }
        #expect(delta == .zero)
        let e = tl.tracks[0].clips[0]
        #expect(e.speedKeys?.boundaries == [f(0), f(24), e.duration])
        #expect(e.duration == c.duration && e.source == c.source)
        let after = (0..<Int64(e.duration.frameIndex(frameDuration: fd))).map { e.sourceTime(at: f($0), frameDuration: fd) }
        #expect(after == before)
    }

    @Test func aSecondNoChangeKeySurvivesTheNextEdit() throws {
        let c = plain()
        var tl = try timeline(c)
        _ = try tl.editSpeedKeys(c.id, keepingKeys: true) { $0.addingKey(at: f(24), frameDuration: fd)?.keys }
        _ = try tl.editSpeedKeys(c.id) { $0.addingKey(at: f(48), frameDuration: fd)?.keys }   // a keyed track stays keyed
        // Dragging the last segment faster keeps both earlier keys.
        _ = try tl.editSpeedKeys(c.id) { $0.settingSpeed(ofSegment: 2, to: pct(200), frameDuration: fd) }
        let k = try #require(tl.tracks[0].clips[0].speedKeys)
        #expect(k.boundaries.prefix(3) == [f(0), f(24), f(48)])
        #expect(k.segments.map(\.from) == [pct(100), pct(100), pct(200)])
    }

    @Test func keepingKeysMakesADragIndependentOfItsIntermediateSteps() throws {
        let c = plain()
        var tl = try timeline(c)
        _ = try tl.editSpeedKeys(c.id, keepingKeys: true) { $0.addingKey(at: f(24), frameDuration: fd)?.keys }
        let keyed = try #require(tl.tracks[0].clips[0].speedKeys)
        // One drag: faster, then back; each step replaces the track with one computed from the mouse-down track.
        _ = try tl.editSpeedKeys(c.id, keepingKeys: true) { _ in keyed.settingSpeed(ofSegment: 1, to: pct(200), frameDuration: fd) }
        _ = try tl.editSpeedKeys(c.id, keepingKeys: true) { _ in keyed }
        #expect(tl.tracks[0].clips[0].speedKeys == keyed)
    }

    @Test func settingASegmentToItsNeighboursSpeedKeepsTheKey() {
        let k = SpeedKeys(segments: [seg(30, 100), seg(30, 200)], origin: f(30))
        let s = k.settingSpeed(ofSegment: 1, to: pct(100), frameDuration: fd)
        #expect(s.segments.count == 2 && s.segments.allSatisfy { $0.from == pct(100) })
    }

    @Test func removingTheOnlyKeyMakesTheClipPlainAgain() throws {
        let c = plain()
        var tl = try timeline(c)
        _ = try tl.editSpeedKeys(c.id, keepingKeys: true) { $0.addingKey(at: f(24), frameDuration: fd)?.keys }
        _ = try tl.editSpeedKeys(c.id) { $0.removingKey(atBoundary: 1) }
        let e = tl.tracks[0].clips[0]
        #expect(e.speedKeys == nil && e.speed == .normal && e.source == c.source && e.duration == c.duration)
    }
}
