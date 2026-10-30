import Foundation
import Testing
import SQCore
@testable import SQEditorSession

private let fd = Time(1, 30)
private func s(_ n: Int64) -> Time { Time(n, 1) }
private func clip(_ start: Int64, _ dur: Int64) -> Clip {
    Clip(name: "c\(start)", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: s(dur)), start: s(start))
}

@MainActor private func makeSession(_ clips: [Clip], url: URL? = nil) -> EditorSession {
    var t = Track(kind: .video)
    for c in clips { try! t.overwrite(c) }
    let tl = Timeline(name: "Main", frameDuration: fd, tracks: [t])
    return EditorSession(project: Project(name: "P", timelines: [tl]), fileURL: url, engine: StubProgramEngine())
}

@MainActor private func ids(_ ses: EditorSession) -> [UUID] { ses.activeTimeline!.tracks.flatMap(\.clips).map(\.id) }

@MainActor @Suite struct IdStabilitySessionTests {
    @Test func splitDeletePasteNestUndoRedoReproduceIds() {
        let a = clip(0, 4), b = clip(4, 4)
        let ses = makeSession([a, b])
        let trackID = ses.activeTimeline!.tracks[0].id
        let start = ids(ses)

        ses.seek(to: s(2)); ses.addEditAtPlayhead()                 // split a
        let afterSplit = ids(ses)
        #expect(afterSplit.count == 3 && afterSplit.contains(a.id))
        #expect(ses.undo()); #expect(ids(ses) == start)
        #expect(ses.redo()); #expect(ids(ses) == afterSplit)

        ses.select(clips: [b.id]); ses.deleteSelection(ripple: true)
        let afterDelete = ids(ses)
        #expect(!afterDelete.contains(b.id))
        #expect(ses.undo()); #expect(ids(ses) == afterSplit)
        #expect(ses.redo()); #expect(ids(ses) == afterDelete)
        #expect(ses.undo())

        ses.select(clips: [a.id]); #expect(ses.copySelection())
        ses.seek(to: s(20)); ses.pasteClipboard()
        let afterPaste = ids(ses)
        #expect(afterPaste.count == 4)
        #expect(ses.undo()); #expect(ids(ses) == afterSplit)
        #expect(ses.redo()); #expect(ids(ses) == afterPaste)
        #expect(ses.undo())

        ses.select(clips: [b.id])
        let seq = ses.nestSelection(name: "N")
        #expect(seq != nil)
        let afterNest = ids(ses)
        #expect(!afterNest.contains(b.id))                            // b now lives inside the nested sequence
        #expect(ses.undo()); #expect(ids(ses) == afterSplit)
        #expect(ses.redo()); #expect(ids(ses) == afterNest)
        #expect(ses.activeTimeline!.tracks[0].id == trackID)          // outer track id never changes
    }

    @Test func saveAndReloadKeepsIds() async throws {
        let a = clip(0, 4), b = clip(4, 4)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-ids-\(UUID().uuidString).sqproj")
        defer { try? FileManager.default.removeItem(at: url) }
        let ses = makeSession([a, b])
        ses.seek(to: s(2)); ses.addEditAtPlayhead()
        try ses.performTimeline("Marker") { _ = $0.addMarker(at: s(1)) }
        try await ses.saveAs(to: url)
        let loaded = try ProjectFile.read(from: url)
        #expect(loaded == ses.project)
        #expect(loaded.timelines[0].tracks.map(\.id) == ses.project.timelines[0].tracks.map(\.id))
        #expect(loaded.timelines[0].markers.map(\.id) == ses.project.timelines[0].markers.map(\.id))
    }
}
