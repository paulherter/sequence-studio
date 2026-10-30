import Foundation
import Testing
import SQCore
import SQText
@testable import SQInspectorUI

/// Multi-select in the Text section: which non-number controls (color wells, layer switches, format pills, alignment)
/// show the mixed state, from the differing template paths.
@MainActor @Suite struct TextMixedControlsTests {
    private func model(_ paths: Set<String>) -> TextInspectorModel {
        let m = TextInspectorModel()
        m.mixedPaths = paths
        return m
    }

    @Test func colourIsMixedWhenAChannelDiffers() {
        #expect(model(["style.color.red"]).isMixedColor("color"))
        #expect(model(["style.shadow.color.blue"]).isMixedColor("shadow.color"))
        #expect(!model(["style.color.alpha"]).isMixedColor("color"))          // opacity has its own field
        #expect(!model(["style.size"]).isMixedColor("color"))
        // A layer on in some clips and off in others: its color is mixed too.
        #expect(model(["style.stroke"]).isMixedColor("stroke.color"))
    }

    @Test func layerSwitchIsMixedOnlyWhenPresenceDiffers() {
        #expect(model(["style.shadow"]).isMixedPresence("shadow"))
        #expect(!model(["style.shadow.blur"]).isMixedPresence("shadow"))
        #expect(!model([]).isMixedPresence("background"))
    }

    @Test func emptyWhenOneClip() {
        let m = model([])
        #expect(!m.isMixedColor("color") && !m.isMixedPresence("stroke") && !m.isMixed("italic"))
    }

    @Test func mixedPathsOfTwoStylesDriveTheControls() throws {
        let a = TextTemplate(name: "A", text: "x", style: TextStyle(color: .white, italic: true))
        let b = TextTemplate(name: "B", text: "x", style: TextStyle(color: .black, stroke: TextStroke(color: .black, width: 2)))
        let m = model(try CodableMerge.differingPaths([a, b]))
        #expect(m.isMixedColor("color"))
        #expect(m.isMixed("italic"))
        #expect(m.isMixedPresence("stroke"))
        #expect(!m.isMixed("alignment"))
    }

    // MARK: Setting a mixed field to the shown clip's own value

    @Test func unchangedEditOfAMixedFieldStillFiresWithForcedPaths() {
        let m = model(["style.italic", "style.color.red"])
        var fired: [Set<String>] = []
        m.onChange = { [unowned m] _, _ in fired.append(m.pendingForcedPaths) }
        m.setItalic(m.style.italic)                       // same value as shown, but the clips differ
        m.setColor(m.style.color)
        m.setAlignment(m.style.alignment)                 // not mixed: nothing to do
        #expect(fired == [["style.italic"], ["style.color.red"]])
        #expect(m.pendingForcedPaths.isEmpty)
    }

    @Test func sessionCopiesForcedFieldsToTheOtherTexts() throws {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video)])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        let a = try #require(session.addTextClip(template: TextTemplate(name: "A", text: "One", style: TextStyle(size: 80)), position: .zero))
        session.seek(to: Time(10, 1))
        let b = try #require(session.addTextClip(template: TextTemplate(name: "B", text: "Two", style: TextStyle(size: 40, italic: true)),
                                                 position: .zero))
        session.select(clips: [a, b])
        func template(_ id: Clip.ID) throws -> TextTemplate {
            let c = try #require(session.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id })
            return try TextGenerator.decode(try #require(c.generator)).0
        }
        let shown = try template(a)
        session.updateTextClips(primary: a, from: shown, to: shown, animations: nil, oldAnimations: nil, continuesGesture: false,
                                forcing: ["style.size", "style.italic"])
        #expect(try template(b).style.size == 80)
        #expect(try template(b).style.italic == false)
        #expect(try template(b).text == "Two")
        session.undo()
        #expect(try template(b).style.size == 40)
    }
}
