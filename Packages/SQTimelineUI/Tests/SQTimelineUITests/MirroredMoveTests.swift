#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 24)

/// 4 pt per frame. Rows (no captions): V2 y22..<42, V1 42..<74, A1 74..<100, A2 100..<120.
private func X(_ f: Double) -> CGFloat { TimelineGeometry.contentOriginX + CGFloat(f) * 4 }
private let yV2: CGFloat = 42, yV1: CGFloat = 82, yA1: CGFloat = 116, yA2: CGFloat = 144

@Suite struct MirroredTrackMoveTests {
    let link = UUID()
    let v: Clip, a: Clip
    let timeline: Timeline

    init() {
        v = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 20), start: fd * 10, link: link)
        a = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: fd * 20), start: fd * 10, link: link)
        timeline = Timeline(name: "t", frameDuration: fd, tracks: [
            Track(kind: .video, clips: [v]), Track(kind: .video), Track(kind: .audio, clips: [a]), Track(kind: .audio)])
    }

    private func interaction(_ t: Timeline? = nil) -> TimelineInteraction {
        var i = TimelineInteraction(timeline: t ?? timeline, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: .selection, snapping: false, linkedSelection: true)
        return i
    }

    private func drag(_ i: inout TimelineInteraction, from a: CGPoint, to b: CGPoint) -> TimelineCommit? {
        i.mouseDown(a, modifiers: [])
        i.mouseDragged(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), modifiers: [])
        i.mouseDragged(b, modifiers: [])
        return i.mouseUp(b, modifiers: [])
    }

    private func trackOf(_ t: Timeline, _ id: Clip.ID) -> Int? { t.tracks.firstIndex { $0.clips.contains { $0.id == id } } }

    @Test func videoUpMovesLinkedAudioDown() throws {
        var i = interaction()
        let raw = drag(&i, from: CGPoint(x: X(15), y: yV1), to: CGPoint(x: X(15), y: yV2))
        let c = try #require(raw)
        #expect(trackOf(c.timeline, v.id) == 1)     // V2
        #expect(trackOf(c.timeline, a.id) == 3)     // A2
        #expect(c.undoName == "Move Clip")
    }

    @Test func audioDownMovesLinkedVideoUp() throws {
        var i = interaction()
        let raw = drag(&i, from: CGPoint(x: X(15), y: yA1), to: CGPoint(x: X(15), y: yA2))
        let c = try #require(raw)
        #expect(trackOf(c.timeline, a.id) == 3)
        #expect(trackOf(c.timeline, v.id) == 1)
    }

    @Test func dragPastTopCreatesVideoAndMirroredAudioTracks() throws {
        var i = interaction()
        let raw = drag(&i, from: CGPoint(x: X(15), y: yV1), to: CGPoint(x: X(15), y: 23 - 14))
        let c = try #require(raw)
        let t = c.timeline
        let videoIdx = t.tracks.indices.filter { t.tracks[$0].kind == .video }
        let audioIdx = t.tracks.indices.filter { t.tracks[$0].kind == .audio }
        #expect(videoIdx.count == 3)
        #expect(audioIdx.count == 3)
        #expect(trackOf(t, v.id) == videoIdx.last)
        #expect(trackOf(t, a.id) == audioIdx.last)
    }

    @Test func partnerStaysAtFirstTrackWhenMirrorWouldLeaveTheTimeline() throws {
        // Video on V2, audio on A1: moving the video down to V1 cannot move the audio above A1.
        var t = timeline
        try t.move(v.id, to: fd * 10, track: t.tracks[1].id)
        var i = interaction(t)
        let raw = drag(&i, from: CGPoint(x: X(15), y: yV2), to: CGPoint(x: X(15), y: yV1))
        let c = try #require(raw)
        #expect(trackOf(c.timeline, v.id) == 0)
        #expect(trackOf(c.timeline, a.id) == 2)
    }

    @Test func smallWobbleInsideTheRowKeepsTheTrack() throws {
        var i = interaction()
        // 4 pt below the V1 row bottom is still V1 (hysteresis), so a plain horizontal move commits without a track change.
        i.mouseDown(CGPoint(x: X(15), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(20), y: 74 + 4), modifiers: [])
        let raw = i.mouseUp(CGPoint(x: X(20), y: 74 + 4), modifiers: [])
        let c = try #require(raw)
        #expect(trackOf(c.timeline, v.id) == 0)
        #expect(trackOf(c.timeline, a.id) == 2)
    }
}
