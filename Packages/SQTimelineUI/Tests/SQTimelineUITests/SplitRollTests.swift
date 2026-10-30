#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

/// Opt-drag on a cut between linked A/V clips: only the audio edit moves (J / L cut in one gesture).
@Suite struct SplitRollTests {
    private let fd = Time(1, 24)
    private func X(_ f: Double) -> CGFloat { TimelineGeometry.contentOriginX + CGFloat(f) * 4 }   // 4 pt per frame, same rows as TimelineInteractionTests
    private let yV1: CGFloat = 70

    private func make() -> TimelineInteraction {
        func c(_ start: Int64, _ kind: TrackKind, _ l: UUID) -> Clip {
            Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: fd * 50, duration: fd * 20),
                 start: fd * start, link: l, mediaDuration: fd * 200)
        }
        let l1 = UUID(), l2 = UUID()
        let v = Track(kind: .video, clips: [c(0, .video, l1), c(20, .video, l2)])
        let a = Track(kind: .audio, clips: [c(0, .audio, l1), c(20, .audio, l2)])
        let t = Timeline(name: "t", frameDuration: fd, tracks: [v, Track(kind: .video), a, Track(kind: .audio)])
        var i = TimelineInteraction(timeline: t, geometry: TimelineGeometry(frameDuration: fd, pointsPerFrame: 4))
        i.toolState = ToolState(tool: .selection, snapping: false, linkedSelection: true)
        return i
    }

    @Test func optionDragOnACutMovesOnlyTheAudioEdit() throws {
        var i = make()
        let m: GestureModifiers = .option
        i.mouseDown(CGPoint(x: X(20) - 1, y: yV1), modifiers: m)
        i.mouseDragged(CGPoint(x: X(15), y: yV1), modifiers: m)
        i.mouseDragged(CGPoint(x: X(12), y: yV1), modifiers: m)
        let ghost = try #require(i.splitRollGhost)
        #expect(ghost.cut == fd * 20)
        #expect(ghost.offset == fd * -8)
        #expect(ghost.label(frameDuration: fd).hasPrefix("J cut"))
        let up = i.mouseUp(CGPoint(x: X(12), y: yV1), modifiers: m)
        let commit = try #require(up)
        #expect(commit.undoName == "Split Edit Audio")
        let v = commit.timeline.tracks[0], a = commit.timeline.tracks[2]
        #expect(v.clips.map(\.start) == [.zero, fd * 20])           // picture stays
        #expect(a.clips.map(\.start) == [.zero, fd * 12])           // audio of the second clip leads
        #expect(i.splitRollGhost == nil)
    }

    @Test func dragRightMakesAnLCut() throws {
        var i = make()
        let m: GestureModifiers = .option
        i.mouseDown(CGPoint(x: X(20) - 1, y: yV1), modifiers: m)
        i.mouseDragged(CGPoint(x: X(24), y: yV1), modifiers: m)
        i.mouseDragged(CGPoint(x: X(26), y: yV1), modifiers: m)
        #expect(i.splitRollGhost?.label(frameDuration: fd).hasPrefix("L cut") == true)
        let up = i.mouseUp(CGPoint(x: X(26), y: yV1), modifiers: m)
        let commit = try #require(up)
        #expect(commit.timeline.tracks[2].clips.map(\.start) == [.zero, fd * 26])
    }

    @Test func withoutOptionTheEdgeStillTrims() throws {
        var i = make()
        i.mouseDown(CGPoint(x: X(20) - 1, y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(18), y: yV1), modifiers: [])
        i.mouseDragged(CGPoint(x: X(16), y: yV1), modifiers: [])
        #expect(i.splitRollGhost == nil)
        _ = i.mouseUp(CGPoint(x: X(16), y: yV1), modifiers: [])
    }
}
