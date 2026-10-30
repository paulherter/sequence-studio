import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}

@MainActor @Suite struct TextPresetSessionTests {
    private func template() -> TextTemplate { TextTemplate(name: "T", text: "Hello", style: TextStyle(size: 40)) }

    @Test func lookThenMotionStackAndEachIsOneUndoStep() throws {
        let session = makeSession()
        let id = try #require(session.addTextClip(template: template(), at: Time(1, 1), duration: Time(4, 1)))
        let look = TextPresetCatalog.looks[0], motion = TextPresetCatalog.motions[0]
        #expect(session.addEffect(kind: TextPresetCatalog.lookID(look), to: [id]))
        #expect(session.addEffect(kind: TextPresetCatalog.motionID(motion), to: [id]))
        let (t, a) = try TextGenerator.decode(try #require(session.singleSelectedClip?.generator))
        #expect(t.style == look.style && t.text == "Hello")
        #expect(a?.animationIn == motion.animationIn)
        session.undo()
        let (t2, a2) = try TextGenerator.decode(try #require(session.singleSelectedClip?.generator))
        #expect(t2.style == look.style && a2 == nil)
        session.undo()
        #expect(try TextGenerator.decode(try #require(session.singleSelectedClip?.generator)).0.style == TextStyle(size: 40))
    }

    @Test func refusesNonTextClipsAndUnknownIds() throws {
        let session = makeSession()
        let id = try #require(session.addTextClip(template: template()))
        #expect(!session.addTextPreset(id: "textlook.nope", to: [id]))
        #expect(!session.addTextPreset(id: TextPresetCatalog.lookID(TextPresetCatalog.looks[0]), to: [UUID()]))
    }

    @Test func builtInLooksAreOffTheEffectsPanelWhileTheSwitchIsOff() {
        #expect(!BuiltInTextLooks.isEnabled)
        #expect(EffectsPanelView.textPresetEntries.isEmpty)
        let rows = EffectFolderOutline.rows(entries: EffectsPanelView.catalog + EffectsPanelView.textPresetEntries, store: EffectFolderStore(), expanded: [], query: "")
        #expect(!rows.filter { $0.isFolder && $0.depth == 0 }.map(\.title).contains("Text"))
    }

    @Test func previewDrawsLooksAndLoopsMotions() throws {
        let w = EffectPreviewPlan.sampleWidth, h = EffectPreviewPlan.sampleHeight
        let bg = EffectPreviewPlan.sampleImages(width: w, height: h).a
        let look = TextPresetCatalog.lookID(TextPresetCatalog.looks[0])
        #expect(TextPresetPreview.still(look, background: bg, width: w, height: h) != bg)
        let motion = TextPresetCatalog.motionID(TextPresetCatalog.motions[0])
        let loop = try #require(TextPresetPreview.loop(motion, fps: 30, background: bg, width: w, height: h))
        #expect(loop.count > 10 && loop.first != loop[loop.count / 3])
    }

    @Test func generatedLooksHoverWithTheirSuggestedMotion() throws {
        let w = EffectPreviewPlan.sampleWidth, h = EffectPreviewPlan.sampleHeight
        let bg = EffectPreviewPlan.sampleImages(width: w, height: h).a
        let gen = try #require(TextLookGenerator.looks.first)
        let loop = try #require(TextPresetPreview.loop(TextPresetCatalog.lookID(gen), fps: 30, background: bg, width: w, height: h))
        #expect(loop.count > 10 && loop.first != loop[loop.count / 3])
        // Hand-made looks (no suggested motion) stay still.
        #expect(TextPresetPreview.loop(TextPresetCatalog.lookID(TextPresetCatalog.handmade[0]), fps: 30, background: bg, width: w, height: h) == nil)
    }
}
