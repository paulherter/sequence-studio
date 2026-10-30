import Foundation
import Testing
import SQCore
@testable import SQInspectorUI

@MainActor @Suite struct ColorSoloTests {
    @Test func soloOnlyWhileTheClipsStripIsShown() {
        let id = UUID()
        #expect(ColorInspectorPanelView.soloClip(clipsMode: true, stripVisible: true, picked: id) == id)
        #expect(ColorInspectorPanelView.soloClip(clipsMode: true, stripVisible: false, picked: id) == nil)   // Timeline group hidden
        #expect(ColorInspectorPanelView.soloClip(clipsMode: false, stripVisible: true, picked: id) == nil)
        #expect(ColorInspectorPanelView.soloClip(clipsMode: true, stripVisible: true, picked: nil) == nil)
    }

    @Test func hidingTheStripClearsTheSessionSolo() {
        let session = EditorSession(project: Project(name: "P"), engine: StubProgramEngine())
        let view = ColorInspectorPanelView(session: session)
        session.colorSoloClip = UUID()
        view.stripVisible = false
        #expect(session.colorSoloClip == nil)
    }
}
