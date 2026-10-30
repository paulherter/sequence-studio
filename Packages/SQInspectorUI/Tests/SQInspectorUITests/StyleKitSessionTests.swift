import Foundation
import Testing
import SQCore
import SQText
@testable import SQInspectorUI

@MainActor private func makeSession() -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
    return EditorSession(project: Project(name: "P", timelines: [t]))
}

private func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: Time(a, 1), end: Time(b, 1)), styleRef: "default")
}

@MainActor @Suite(.serialized) struct StyleKitSessionTests {
    @Test func changingTheKitIsOneUndoStepAndCaptionsFollow() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1), item("b", 2, 3)])
        var kit = StyleKit.starter
        session.setStyleKit(kit)
        #expect(session.useKitCaptionStyle())
        #expect(session.captionItems.allSatisfy { $0.styleRef == StyleKit.captionStyleRef })
        kit.fonts[StyleKit.brandFontToken] = "Futura-Bold"
        let depth = session.undoDepth
        session.setStyleKit(kit)
        #expect(session.undoDepth == depth + 1)
        for c in session.captionItems {
            #expect(CaptionPresetLibrary.builtIn.style(for: c.styleRef).fontName == "Futura-Bold")
        }
        session.undo()
        #expect(CaptionPresetLibrary.builtIn.style(for: StyleKit.captionStyleRef).fontName == TextStyle.defaultFontName)
    }

    @Test func importPaulsKitIsOneUndoStepAndCaptionsUseInter() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1)])
        let depth = session.undoDepth
        #expect(!session.importPaulsKit().isEmpty)
        #expect(session.undoDepth == depth + 1)
        #expect(session.useKitCaptionStyle())
        #expect(CaptionPresetLibrary.builtIn.style(for: StyleKit.captionStyleRef).fontName == "Inter-Bold")
        #expect(session.importPaulsKit().isEmpty)          // second import adds nothing
    }

    @Test func saveCaptionLookToKitIsOneUndoStepAndCaptionsCanUseIt() throws {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let session = makeSession()
        #expect(session.saveCaptionLookToKit(name: "Loud") == nil)          // no captions yet
        session.replaceCaptions([item("a", 0, 1)])
        let depth = session.undoDepth
        let id = try #require(session.saveCaptionLookToKit(name: "Loud Look"))
        #expect(id == "loud-look" && session.undoDepth == depth + 1)
        #expect(session.project.styleKit?.looks[id]?.name == "Loud Look")
        // the kit look resolves through the caption library under the kit's look id
        let ref = CaptionLook.styleID(for: StyleKit.lookID(id))
        #expect(CaptionPresetLibrary.builtIn.hasStyle(ref))
        // same name again replaces, no second entry
        #expect(session.saveCaptionLookToKit(name: "Loud Look") == id)
        #expect(session.project.styleKit?.looks.count == 1)
        #expect(session.saveCaptionLookToKit(name: "  ") == nil)
    }

    @Test func useKitCaptionStyleNeedsAKitCaptionStyle() {
        let session = makeSession()
        session.replaceCaptions([item("a", 0, 1)])
        #expect(!session.useKitCaptionStyle())
    }

    @Test func importKeepsTheProjectsBrandAndExportWritesTheKit() throws {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Brand.sqstyle")
        var theirs = StyleKit.starter
        theirs.fonts[StyleKit.brandFontToken] = "Avenir-Black"
        theirs.colors["accent"] = EffectColor(red: 1, green: 0, blue: 0)
        try StyleKitFile.write(theirs, to: url)

        let session = makeSession()
        var mine = StyleKit()
        mine.fonts[StyleKit.brandFontToken] = "Futura-Bold"
        session.setStyleKit(mine)
        let report = try session.importStyleKit(from: url)
        #expect(session.project.styleKit?.fonts[StyleKit.brandFontToken] == "Futura-Bold")
        #expect(session.project.styleKit?.colors["accent"] == EffectColor(red: 1, green: 0, blue: 0))
        #expect(report.keptTokens.contains("font:\(StyleKit.brandFontToken)"))

        let out = dir.appendingPathComponent("Out.sqstyle")
        try session.exportStyleKit(to: out)
        #expect(try StyleKitFile.read(from: out) == session.project.styleKit)
    }

    @Test func exportWithoutAKitWritesTheStarter() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString).sqstyle")
        defer { try? FileManager.default.removeItem(at: out) }
        try makeSession().exportStyleKit(to: out)
        #expect(try StyleKitFile.read(from: out) == StyleKit.starter)
    }

    @Test func newMotionEffectsTakeTheKitDefaults() throws {
        let clip = Clip(name: "v", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)), start: .zero)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video, clips: [clip])])
        let session = EditorSession(project: Project(name: "P", timelines: [t]))
        var kit = StyleKit()
        kit.motion = MotionDefaults(duration: Time(1, 4), curve: MotionCurve.spring.rawValue)
        session.setStyleKit(kit)
        #expect(session.addEffect(kind: ClipEffect.zoomKind, to: [clip.id]))
        let e = try #require(session.activeTimeline?.tracks.first?.clips.first?.effects.first)
        #expect(e.parameters[ClipEffect.motionDurationKey]?.value == 0.25)
        #expect(e.parameters[ClipEffect.motionCurveKey]?.value == Double(MotionCurve.spring.rawValue))
    }

    // MARK: Review fixes

    @Test func manualInspectorChoicesUnbindTheirTokens() {
        var style = TextStyle(fontName: "Helvetica", stroke: TextStroke(color: .black, width: 2),
                              background: TextBackground(color: .black, padding: BoxPadding(horizontal: 1, vertical: 1), cornerRadius: 1))
        style.tokens = TextStyleTokens(font: "brand", color: "text", strokeColor: "s", backgroundColor: "pill")
        let m = TextInspectorModel(style: style, fontFamilies: { ["Helvetica", "Menlo"] })
        m.setFontFamily("Menlo")
        #expect(m.style.tokens?.font == nil && m.style.tokens?.color == "text")
        m.setColor(.black)
        #expect(m.style.tokens?.color == nil)
        m.setStrokeColor(.white)
        #expect(m.style.tokens?.strokeColor == nil)
        m.setBackgroundOpacity(0.5)
        #expect(m.style.tokens == nil)                 // nothing bound any more
        var kit = StyleKit.starter
        kit.fonts[StyleKit.brandFontToken] = "Futura-Bold"
        #expect(m.style.resolved(in: kit).fontName == "Menlo")
    }

    @Test func inspectorPresetsFollowTheCurrentKit() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        CaptionLookRegistry.shared.setStyleKit(nil)
        let m = TextInspectorModel(fontFamilies: { [] })
        #expect(!m.presetIDs.contains(StyleKit.captionStyleRef))
        CaptionLookRegistry.shared.setStyleKit(.starter)
        let kitStyle = CaptionPresetLibrary.builtIn.style(for: StyleKit.captionStyleRef)
        m.load(style: kitStyle, animations: AnimationSet(in: nil, out: nil))
        #expect(m.presetIDs.contains(StyleKit.captionStyleRef))
        #expect(m.selectedPresetID == StyleKit.captionStyleRef)
    }

    @Test func textTemplatesOfferTheKitCaptionStyle() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        CaptionLookRegistry.shared.setStyleKit(nil)
        #expect(TextTemplateCatalog.entry(id: StyleKit.captionStyleRef) == nil)
        var kit = StyleKit.starter
        kit.fonts[StyleKit.brandFontToken] = "Futura-Bold"
        CaptionLookRegistry.shared.setStyleKit(kit)
        #expect(TextTemplateCatalog.entry(id: StyleKit.captionStyleRef)?.template.style.fontName == "Futura-Bold")
    }

    @Test func insertedTokenBoundTextIsResolvedInTheSameStep() throws {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        var kit = StyleKit.starter
        kit.fonts[StyleKit.brandFontToken] = "Futura-Bold"
        var style = TextStyle(fontName: "Helvetica")              // stale literal, e.g. a template made under another kit
        style.tokens = TextStyleTokens(font: StyleKit.brandFontToken)
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: "Hi", style: style), animations: nil)
        let clip = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)),
                        start: .zero, generator: ref)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video)])
        var p = Project(name: "P", timelines: [t])
        p.styleKit = kit
        let session = EditorSession(project: p)
        let depth = session.undoDepth
        try session.performTimeline("Paste") { tl in
            tl.tracks[0] = Track(id: tl.tracks[0].id, kind: .video, clips: [clip])
        }
        #expect(session.undoDepth == depth + 1)
        let g = try #require(session.activeTimeline?.tracks[0].clips.first?.generator)
        #expect(try TextGenerator.decode(g).0.style.fontName == "Futura-Bold")
    }
}
