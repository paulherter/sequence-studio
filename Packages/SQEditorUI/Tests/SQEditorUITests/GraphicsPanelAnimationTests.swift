import AppKit
import Testing
import SQCore
import SQLibrary
@testable import SQEditorUI
@testable import SQInspectorUI

/// The Graphics panel's text item reads and saves animations in the window's Library, like the Text section in Controls.
@MainActor @Suite struct GraphicsPanelAnimationTests {
    private func store() -> KeystonesPanelModel {
        let p = KeystonesPanelModel()
        p.onSave = { [unowned p] k in if let item = try? KeystoneLibrary.presetItem(for: k) { p.presets.append(item) } }
        return p
    }

    private func panel(width: Int = 1080, height: Int = 1920) -> (GraphicsPanelView, GraphicsEditor) {
        let tl = Timeline(name: "T", format: SequenceFormat(width: width, height: height, frameDuration: Time(1, 30)),
                          tracks: Timeline.defaultTracks(video: 2, audio: 1))
        let e = GraphicsEditor(session: EditorSession(project: Project(name: "P", timelines: [tl])))
        let v = GraphicsPanelView(editor: e)
        e.newGraphicsClip()
        e.addText()
        v.sync([.project, .selection])
        return (v, e)
    }

    @Test func theTextItemSavesAndListsTheWindowsAnimations() async throws {
        let (v, e) = panel()
        let library = store()
        v.keystones = library                    // set after the panel was built, as the app does
        let block = try #require(v.textBlock), model = try #require(v.textModel)
        #expect(model.keystones === library && model.canSaveAnimations)
        var notices: [String] = []
        v.onNotice = { notices.append($0) }
        block.askLookName = { _, _ in "Mine" }

        block.pickAnimation(AnimationChoices.customID, side: .intro)
        #expect(e.textAnimations?.animationIn.map(AnimationChoices.isCustom) == true)
        await block.saveAnimation(.intro)
        #expect(library.savedAnimations(.intro).map(\.name) == ["Mine"] && notices.isEmpty)
        let id = try #require(model.selectedInID)
        #expect(model.inAnimationIDs.contains(id) && model.animationTitle(.intro) == "Mine")
        #expect(e.textAnimations?.animationIn.map(AnimationChoices.isCustom) == false)

        // A panel built later (another selection, a rebuild) gets the store too.
        v.sync([.project, .selection])
        #expect(v.textModel?.keystones === library && v.textModel?.animationTitle(.intro) == "Mine")
    }

    @Test func aSaveWithoutALibraryIsSaidThroughTheHost() async throws {
        let (v, _) = panel()
        let block = try #require(v.textBlock)
        var notices: [String] = []
        v.onNotice = { notices.append($0) }
        block.askLookName = { _, _ in "Mine" }
        block.pickAnimation(AnimationChoices.customID, side: .intro)
        await block.saveAnimation(.intro)
        #expect(notices.count == 1)
    }

    @Test func savedPositionsFollowTheSequenceFormat() throws {
        let (v, _) = panel(width: 3840, height: 2160)
        #expect(try #require(v.textModel).frameSize == Vec2(3840, 2160))
    }
}
