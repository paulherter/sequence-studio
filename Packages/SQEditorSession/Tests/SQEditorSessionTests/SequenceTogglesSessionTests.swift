import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor private func makeSession() -> EditorSession {
    EditorSession(engine: StubProgramEngine(), autosaveStore: AutosaveStore(base: FileManager.default.temporaryDirectory
        .appendingPathComponent("sq-\(UUID().uuidString)"), policy: AutosavePolicy(interval: 300, keep: 3)))
}

/// Snapping, Linked Selection and Delete Track are saved with the sequence and are one undo step each.
@MainActor @Suite struct SequenceTogglesSessionTests {
    @Test func snappingIsStoredPerSequenceAndUndoable() {
        let session = makeSession()
        #expect(session.activeTimeline!.snappingOn)
        #expect(session.setSnapping(false))
        #expect(!session.activeTimeline!.snappingOn)
        #expect(!session.setSnapping(false))          // no change, no step
        session.undo()
        #expect(session.activeTimeline!.snappingOn)
        session.redo()
        #expect(!session.activeTimeline!.snappingOn)
    }

    @Test func linkedSelectionIsStoredAndMirroredToTheSession() {
        let session = makeSession()
        #expect(session.setLinkedSelection(false))
        #expect(!session.activeTimeline!.linkedSelectionOn && !session.linkedSelection)
        session.undo()
        #expect(session.activeTimeline!.linkedSelectionOn)
    }

    @Test func deleteTrackIsOneUndoStep() {
        let session = makeSession()
        session.addTrack(.video); session.addTrack(.video)
        let before = session.activeTimeline!.tracks.count
        let ids = session.activeTimeline!.tracks.filter { $0.kind == .video }.suffix(2).map(\.id)
        session.attempt("Target") { t in for i in t.tracks.indices { t.tracks[i].isTargeted = ids.contains(t.tracks[i].id) } }
        session.deleteTargetedTracks()
        #expect(session.activeTimeline!.tracks.count <= before - 1)
        session.undo()
        #expect(session.activeTimeline!.tracks.count == before)
    }
}
