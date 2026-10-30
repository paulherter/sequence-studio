import Foundation
import SQCore
import Testing
@testable import SQEditorSession

/// Pre-release timeline audit (2026-10-07): session edit commands.
@MainActor
struct SessionTimelineAuditTests {
    static let fd = Time(1, 30)
    static func sec(_ n: Int64) -> Time { Time(n, 1) }
    static func clip(_ start: Time, _ dur: Time, kind: TrackKind = .video) -> Clip {
        Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: dur), start: start)
    }

    /// One 15 s clip; In marked at 2 s while the sequence was 10 s long (stored end 10 s, In only).
    static func grownInOnly() -> EditorSession {
        var t = Timeline(name: "T", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(.zero, sec(15))])])
        t.inOut = TimeRange(start: sec(2), end: sec(10))
        t.inOutKind = .inOnly
        return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
    }

    /// In only = to the CURRENT sequence end (Premiere, like `exportRange`), not the end when In was marked.
    @Test func clearRangeWithInOnlyReachesCurrentEnd() {
        let s = Self.grownInOnly()
        s.liftRange()
        let clips = s.activeTimeline!.tracks[0].clips
        #expect(clips.count == 1)
        #expect(clips.first?.timeline.end == Self.sec(2))
    }

    @Test func deleteRangeWithInOnlyReachesCurrentEnd() {
        let s = Self.grownInOnly()
        s.extractRange()
        #expect(s.activeTimeline!.tracks[0].clips.map(\.timeline.end) == [Self.sec(2)])
    }

    @Test func goToOutWithInOnlyIsLastFrame() {
        let s = Self.grownInOnly()
        s.goToOut()
        #expect(s.playhead == Self.sec(15) - Self.fd)
    }

    /// Cut Out moves the playhead to the join; undo must bring it back like every other ripple.
    @Test func cutOutPlayheadIsUndone() {
        let t = Timeline(name: "T", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [Self.clip(.zero, Self.sec(10))])])
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        s.seek(to: Self.sec(2)); s.cutOut()
        s.seek(to: Self.sec(5)); s.cutOut()
        #expect(s.playhead == Self.sec(2))
        #expect(s.undo())
        #expect(s.playhead == Self.sec(5))
        #expect(s.redo())
        #expect(s.playhead == Self.sec(2))
    }

    /// Cmd+X names its undo step "Cut", not "Delete".
    @Test func cutSelectionUndoName() {
        let c = Self.clip(.zero, Self.sec(4))
        let t = Timeline(name: "T", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [c])])
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        s.select(clips: [c.id])
        s.cutSelection()
        #expect(s.activeTimeline!.tracks[0].clips.isEmpty)
        #expect(s.undoName == "Cut")
    }

    /// A cut long ago (here: then undone) must not turn the next single cut into "select the piece between two cuts".
    /// Clips 0-4 s and 4-10 s: after a cut at 6 s the piece 4-6 s lies between 2 s and 6 s, so a stale 2 s cut point
    /// would select it.
    static func twoClipSession() -> EditorSession {
        let t = Timeline(name: "T", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip(.zero, sec(4)), clip(sec(4), sec(6))])])
        return EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
    }

    @Test func staleCutPointDoesNotSelectAPiece() {
        let s = Self.twoClipSession()
        s.seek(to: Self.sec(2)); s.addEditAtPlayhead()
        #expect(s.undo())
        s.select(clips: [])
        s.seek(to: Self.sec(6)); s.addEditAtPlayhead()
        #expect(s.selection.isEmpty)
    }

    /// Cut, undo, another edit, cut: the undo depth is back where a direct second cut would be, but the first cut is gone.
    @Test func cutPointForgottenAfterUndoAndAnotherEdit() {
        let s = Self.twoClipSession()
        s.seek(to: Self.sec(2)); s.addEditAtPlayhead()
        #expect(s.undo())
        _ = s.attempt("M") { _ = $0.addMarker(at: Self.sec(8)) }
        s.select(clips: [])
        s.seek(to: Self.sec(6)); s.addEditAtPlayhead()
        #expect(s.selection.isEmpty)
    }

    /// Two cuts in a row still select the piece between them.
    @Test func twoCutsInARowSelectThePiece() {
        let c = Self.clip(.zero, Self.sec(10))
        let t = Timeline(name: "T", frameDuration: Self.fd, tracks: [Track(kind: .video, clips: [c])])
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        s.seek(to: Self.sec(2)); s.addEditAtPlayhead()
        s.seek(to: Self.sec(6)); s.addEditAtPlayhead()
        #expect(s.selection.count == 1)
    }
}
