import Foundation
import Testing
import SQCore
@testable import SQEditorSession

@MainActor @Suite struct ColorMatteSessionTests {
    private func session() -> EditorSession {
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                          tracks: Timeline.defaultTracks(video: 2, audio: 1))
        return EditorSession(project: Project(name: "P", timelines: [tl]))
    }

    private func matteColor(_ s: EditorSession, _ id: Clip.ID) -> ColorMatteColor? {
        s.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id }?.matteColor
    }

    @Test func addsOneUndoStepAndSelectsTheMatte() throws {
        let s = session()
        let depth = s.undoDepth
        let id = try #require(s.addColorMatte(ColorMatteColor(r: 10, g: 20, b: 30), name: "Back", duration: Time(3, 1)))
        #expect(s.undoDepth == depth + 1)
        #expect(s.selection == [id] && matteColor(s, id) == ColorMatteColor(r: 10, g: 20, b: 30))
        let c = try #require(s.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id })
        #expect(c.name == "Back" && c.duration == Time(3, 1))
        #expect(s.undo())
        #expect(matteColor(s, id) == nil)
    }

    @Test func aColorDragIsOneUndoStep() throws {
        let s = session()
        let id = try #require(s.addColorMatte(.default))
        let depth = s.undoDepth
        for i in 0..<20 {
            s.setColorMatte(id, ColorMatteColor(r: UInt8(i * 5), g: 0, b: 0), continuesGesture: i > 0)
        }
        #expect(s.undoDepth == depth + 1)
        #expect(matteColor(s, id) == ColorMatteColor(r: 95, g: 0, b: 0))
        #expect(s.undo())
        #expect(matteColor(s, id) == .default)
        // Each new pick is its own step.
        s.setColorMatte(id, ColorMatteColor(r: 1, g: 2, b: 3))
        s.setColorMatte(id, ColorMatteColor(r: 4, g: 5, b: 6))
        #expect(s.undoDepth == depth + 2)
    }
}
