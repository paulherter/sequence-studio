import Foundation
import Testing
import SQCore
@testable import SQEditorSession

/// Audit 2026-10 items 1 and 4: Cmd+V pastes onto the copied tracks and moves the playhead to the end of the paste.
private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> (EditorSession, Clip) {
    var v1 = Track(kind: .video, isTargeted: true), v2 = Track(kind: .video)
    try! v1.overwrite(Clip(name: "head", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(60)), start: .zero))
    let title = Clip(name: "title", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(4)), start: .zero)
    try! v2.overwrite(title)
    let tl = Timeline(name: "Main", frameDuration: fd, tracks: [v1, v2])
    return (EditorSession(project: Project(name: "P", timelines: [tl]), engine: StubProgramEngine()), title)
}

@MainActor @Suite struct PasteClipboardSessionTests {
    @Test func twoPastesInARowLayCopiesEndToEnd() {
        let (ses, title) = makeSession()
        ses.select(clips: [title.id]); #expect(ses.copySelection())
        ses.seek(to: s(10))
        ses.pasteClipboard()
        #expect(ses.playhead == s(14))
        ses.pasteClipboard()
        #expect(ses.playhead == s(18))
        let v2 = ses.activeTimeline!.tracks[1].clips.map(\.start)
        #expect(v2 == [.zero, s(10), s(14)])
        #expect(ses.activeTimeline!.tracks[0].clips.count == 1)        // V1 untouched though it is targeted
        #expect(ses.undo())
        #expect(ses.activeTimeline!.tracks[1].clips.count == 2)
    }

    @Test func pasteInsertAlsoMovesThePlayhead() {
        let (ses, title) = makeSession()
        ses.select(clips: [title.id]); #expect(ses.copySelection())
        ses.seek(to: s(10))
        ses.pasteClipboard(insert: true)
        #expect(ses.playhead == s(14))
    }

    @Test func pasteToTargetedTrackLandsOnV1() {
        let (ses, title) = makeSession()
        ses.select(clips: [title.id]); #expect(ses.copySelection())
        ses.seek(to: s(10))
        ses.pasteClipboard(toTargets: true)
        #expect(ses.activeTimeline!.tracks[0].clips.map(\.start) == [.zero, s(10), s(14)])
        #expect(ses.playhead == s(14))
    }
}
