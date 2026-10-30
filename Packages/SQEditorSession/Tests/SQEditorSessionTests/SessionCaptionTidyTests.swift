import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct SessionCaptionTidyTests {
    @Test func tidyIsOneUndoStepAndUndoRestores() {
        let tl = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let session = EditorSession(project: Project(name: "P", timelines: [tl]))
        let item = CaptionItem(lines: ["one two three four five six"], range: TimeRange(start: .zero, end: Time(3, 1)), styleRef: "default")
        #expect(session.addCaptions([item]))
        let depth = session.undoDepth
        #expect(session.tidyCaptions() == 2)
        #expect(session.captionItems.map(\.text) == ["one two three", "four five six"])
        #expect(session.undoDepth == depth + 1)
        session.undo()
        #expect(session.captionItems.map(\.text) == ["one two three four five six"])
    }

    @Test func tidyWithoutCaptionsExplainsWhy() {
        let tl = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        let session = EditorSession(project: Project(name: "P", timelines: [tl]))
        #expect(session.tidyCaptions() == nil)
        #expect(session.lastError != nil)
    }
}
