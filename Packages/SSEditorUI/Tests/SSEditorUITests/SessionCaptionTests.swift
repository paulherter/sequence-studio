import Foundation
import Testing
import SSCore
@testable import SSEditorUI

private func s(_ n: Int64) -> Time { Time(n, 1) }

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}
private func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: s(a), end: s(b)), styleRef: "default")
}

@MainActor @Suite struct SessionCaptionTests {
    @Test func splitAtPlayheadIsOneUndoStep() throws {
        let session = makeSession()
        #expect(session.replaceCaptions([item("one two three four", 0, 8)]))
        session.seek(to: s(4))
        let depth = session.undoDepth
        #expect(session.splitCaption())
        #expect(session.captionItems.map(\.text) == ["one two", "three four"])
        #expect(session.captionSelection.count == 1)
        #expect(session.undoDepth == depth + 1)
        session.undo()
        #expect(session.captionItems.count == 1)
    }

    @Test func splitWithoutCaptionUnderPlayheadSaysSo() {
        let session = makeSession()
        #expect(!session.splitCaption())
        #expect(session.lastError != nil)
    }

    @Test func mergeSelectedAndDelete() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1), item("b", 1, 2), item("c", 2, 3)])
        let ids = session.captionItems.map(\.id)
        session.select(clips: [], captions: [ids[0], ids[1]])
        #expect(session.mergeSelectedCaptions())
        #expect(session.captionItems.map(\.text) == ["a b", "c"])
        session.select(clips: [], captions: [session.captionItems[1].id])
        #expect(session.deleteSelectedCaptions())
        #expect(session.captionItems.map(\.text) == ["a b"])
    }

    @Test func typingIntoOneCaptionIsOneStepAndMultiLineSplitsIntoLines() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1)])
        let id = session.captionItems[0].id
        let depth = session.undoDepth
        session.setCaptionText(id, "H", continuesGesture: false)
        session.setCaptionText(id, "Hi", continuesGesture: true)
        session.setCaptionText(id, "Hi\nthere", continuesGesture: true)
        #expect(session.undoDepth == depth + 1)
        #expect(session.captionItems[0].lines == ["Hi", "there"])
    }

    @Test func replaceAllAndStyleForTheWholeTrack() {
        let session = makeSession()
        session.replaceCaptions([item("cat", 0, 1), item("Cat dog", 1, 2)])
        #expect(session.replaceCaptionText(find: "cat", with: "fox", caseSensitive: false) == 2)
        #expect(session.captionItems.map(\.text) == ["fox", "fox dog"])
        #expect(session.setCaptionStyle(styleRef: "tiktok"))
        #expect(session.captionItems.allSatisfy { $0.styleRef == "tiktok" })
    }

    @Test func createCaptionsForASecondClipKeepsTheFirstOnes() {
        let session = makeSession()
        session.replaceCaptions([item("first", 0, 2)])
        #expect(session.addCaptions([item("second", 5, 7)]))
        #expect(session.captionItems.map(\.text) == ["first", "second"])
        #expect(session.addCaptions([item("again", 6, 8)]))      // overlaps "second": it is replaced
        #expect(session.captionItems.map(\.text) == ["first", "again"])
    }

    @Test func addCaptionAtPlayheadSelectsIt() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1)])
        session.seek(to: s(2))
        let id = session.addCaptionAtPlayhead()
        #expect(id != nil && session.captionSelection == [id!])
        #expect(session.captionItem(id!)?.range == TimeRange(start: s(2), end: s(5)))
    }
}
