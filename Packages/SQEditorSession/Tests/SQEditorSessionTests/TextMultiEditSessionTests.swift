import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession

private func s(_ n: Int64) -> Time { Time(n, 1) }

/// Multi-select editing in the Text section: an edit of the shown text goes to every selected text clip, field by field.
@MainActor @Suite struct TextMultiEditSessionTests {
    private func rig() throws -> (EditorSession, a: Clip.ID, b: Clip.ID) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video)])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        let a = try #require(session.addTextClip(template: TextTemplate(name: "A", text: "One",
                                style: TextStyle(fontName: "Helvetica-Bold", size: 80, color: .white)), position: .zero))
        session.seek(to: s(10))
        let b = try #require(session.addTextClip(template: TextTemplate(name: "B", text: "Two",
                                style: TextStyle(fontName: "Georgia", size: 40, color: .white)), position: .zero))
        return (session, a, b)
    }

    private func template(_ session: EditorSession, _ id: Clip.ID) throws -> TextTemplate {
        let c = try #require(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id })
        return try TextGenerator.decode(try #require(c.generator)).0
    }

    @Test func selectedTextClipsNeedsSeveralTexts() throws {
        let (session, a, b) = try rig()
        session.select(clips: [a])
        #expect(session.selectedTextClips.isEmpty)
        session.select(clips: [a, b])
        #expect(session.selectedTextClips.map(\.id) == [a, b])
    }

    @Test func mixedPathsNameTheDifferingFields() throws {
        let (session, a, b) = try rig()
        session.select(clips: [a, b])
        let mixed = session.textMixedPaths
        #expect(mixed.contains("style.size") && mixed.contains("style.fontName") && mixed.contains("text"))
        #expect(!mixed.contains("style.color"))
    }

    @Test func editCarriesOnlyTheChangedFieldInOneUndoStep() throws {
        let (session, a, b) = try rig()
        session.select(clips: [a, b])
        let old = try template(session, a)
        var new = old; new.style.size = 120
        session.updateTextClips(primary: a, from: old, to: new, animations: nil, oldAnimations: nil, continuesGesture: false)
        #expect(try template(session, a).style.size == 120)
        #expect(try template(session, b).style.size == 120)
        #expect(try template(session, b).style.fontName == "Georgia")     // untouched field keeps its own value
        #expect(try template(session, b).text == "Two")
        session.undo()
        #expect(try template(session, a).style.size == 80)
        #expect(try template(session, b).style.size == 40)
    }

    @Test func typingSetsTheTextOfAll() throws {
        let (session, a, b) = try rig()
        session.select(clips: [a, b])
        let old = try template(session, a)
        var new = old; new.text = "Same"
        session.updateTextClips(primary: a, from: old, to: new, animations: nil, oldAnimations: nil, continuesGesture: false)
        #expect(try template(session, b).text == "Same")
        #expect(!session.textMixedPaths.contains("text"))
    }
}
