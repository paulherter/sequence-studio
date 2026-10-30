import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorSession
@testable import SQInspectorUI

@MainActor @Suite struct CTAEndCardTests {
    private func session() -> EditorSession {
        let t = Timeline(name: "Main", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                         tracks: [Track(kind: .video), Track(kind: .audio)])
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    @Test func layersArePillIconAndTwoLabelStates() throws {
        let l = try CTAEndCard.layers(canvasWidth: 1080, canvasHeight: 1920)
        #expect(l.map(\.name) == ["Pill", "Pill Done", "Icon", "Label", "Label Done"])
        #expect(l.filter(\.isText).count == 3)
        guard case .text(let ref) = l[3].content else { Issue.record("text layer"); return }
        #expect(try TextGenerator.decode(ref).0.text == "FOLGEN")
    }

    @Test func stateSwitchesFromFolgenToGefolgtAtThePress() throws {
        let l = try CTAEndCard.layers(canvasWidth: 1080, canvasHeight: 1920)
        let before = Time(1, 1), after = Time(5, 2)
        #expect(l[3].animation.opacity.value(atLocal: before) == 1 && l[3].animation.opacity.value(atLocal: after) == 0)
        #expect(l[4].animation.opacity.value(atLocal: before) == 0 && l[4].animation.opacity.value(atLocal: after) == 1)
        #expect(l[1].animation.opacity.value(atLocal: before) == 0 && l[1].animation.opacity.value(atLocal: after) == 1)
    }

    @Test func pressDipsToNinetyPercentAndLayersKeepTheirPlaceInTheCard() throws {
        let l = try CTAEndCard.layers(canvasWidth: 1080, canvasHeight: 1920)
        #expect(abs(CTAEndCard.cardScale(atLocal: CTAEndCard.pressDown) - 0.9) < 1e-9)
        #expect(CTAEndCard.cardScale(atLocal: .zero) == 0)
        #expect(CTAEndCard.cardScale(atLocal: Time(3, 1)) == 1)
        let icon = l[2].animation, pill = l[0].animation
        let t = CTAEndCard.pressDown
        #expect(abs(icon.scale.value(atLocal: t).x - 0.9) < 1e-9)
        // The icon's offset from the pill center shrinks with the card (positions scale about the pill center).
        let rest = Time(3, 1)
        let d0 = icon.position.value(atLocal: rest).x - pill.position.value(atLocal: rest).x
        let d1 = icon.position.value(atLocal: t).x - pill.position.value(atLocal: t).x
        #expect(abs(d1 - 0.9 * d0) < 1e-6)
        #expect(pill.position.value(atLocal: t) == pill.position.value(atLocal: rest))
    }

    @Test func commandPlacesOneGraphicsClipAsOneUndoStep() throws {
        let s = session()
        let depth = s.undoDepth
        let id = try #require(s.addCTAEndCard(at: Time(2, 1)))
        #expect(s.undoDepth == depth + 1)
        let clip = try #require(s.activeTimeline?.tracks.lazy.flatMap(\.clips).first { $0.id == id })
        #expect(clip.isGraphics && clip.graphics?.layers.count == 5)
        #expect(clip.start == Time(2, 1) && clip.timeline.duration == CTAEndCard.duration)
        s.undo()
        #expect(s.activeTimeline?.tracks.lazy.flatMap(\.clips).isEmpty == true)
    }

    @Test func libraryOffersTheCTAAndTheTwoTierTitle() throws {
        let cta = try #require(TextTemplateCatalog.entry(id: CTAEndCard.id))
        #expect(cta.isCTA && cta.name == "CTA End Card")
        let two = try #require(TextTemplateCatalog.entry(id: TextTemplateCatalog.title2TierID))
        #expect(!two.isCTA)
        let big = try #require(two.template.style.secondLine)
        #expect(big.size > two.template.style.size * 2)     // small top line, big second line
        #expect(two.template.text.split(separator: "\n").count == 2)
        #expect(two.template.style.lineStyle(1).size == big.size)
    }
}
