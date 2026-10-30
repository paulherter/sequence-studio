import Foundation
import SQCore
import Testing
@testable import SQEditorSession

@MainActor
struct SequenceSettingsSessionTests {
    private func session() -> EditorSession {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: Timeline.defaultTracks())
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    @Test func oneUndoStepForAllFields() throws {
        let s = session()
        var wanted = try #require(s.activeTimeline?.settings)
        wanted.name = "Reel"
        wanted.format.width = 1080; wanted.format.height = 1920
        wanted.editMode = .magnetic
        wanted.timecodeStart = Time(3600, 1); wanted.timecodeDisplay = .frames; wanted.previewQuality = .half
        #expect(s.applySequenceSettings(wanted))
        #expect(s.activeTimeline?.settings == wanted)
        s.undo()
        #expect(s.activeTimeline?.name == "Main" && s.activeTimeline?.editMode == .normal && s.activeTimeline?.format.width == 1920)
        #expect(s.activeTimeline?.timecodeStart == .zero && s.activeTimeline?.previewQuality == nil)
    }

    @Test func unchangedSettingsAreNoStep() throws {
        let s = session()
        let same = try #require(s.activeTimeline?.settings)
        #expect(!s.applySequenceSettings(same))
    }
}
