import Foundation
import Testing
import SQCore
import SQEditorSession
import SQText
import SQUIKit
import SQDrawKit
@testable import SQInspectorUI

/// The text clip's Controls block on the shared toolkit (Windows): `TextBlockView` translated onto `TextInspectorModel`.
@MainActor @Suite(.serialized) struct TextBlockDrawTests {
    private func block() -> TextBlockDraw {
        for l in TextBlockDraw.Layer.allCases { UserDefaults.standard.removeObject(forKey: TextBlockDraw.layerKey(l)) }
        UserDefaults.standard.removeObject(forKey: TextBlockDraw.sectionKey("textblock.text"))
        UserDefaults.standard.removeObject(forKey: TextBlockDraw.sectionKey("textblock.animation"))
        let m = TextInspectorModel(style: TextStyle(), fontFamilies: { ["Inter", "Georgia"] })
        let b = TextBlockDraw(model: m)
        b.width = 360
        b.clock = { 0 }
        return b
    }

    private func click(_ b: TextBlockDraw, _ c: TextBlockDraw.Control, _ part: TextBlockDraw.Part = .text) throws {
        let f = try #require(b.frame(c, part))
        let p = CGPoint(x: f.midX, y: f.midY)
        b.mouseDown(at: p, part: part, clickCount: 1)
        b.mouseUp(at: p, part: part)
    }

    @Test func styleTogglesAndAlignmentSetTheModel() throws {
        let b = block()
        try click(b, .button(.style, 0))
        #expect(b.model.style.weight >= .bold)
        try click(b, .button(.style, 0))
        #expect(b.model.style.weight == .regular)
        try click(b, .button(.style, 1))
        #expect(b.model.style.italic)
        try click(b, .button(.align, 2))
        #expect(b.model.style.alignment == .right)
        try click(b, .button(.vertical, 2))
        #expect(b.model.style.verticalAlignment == .bottom)
    }

    @Test func directionPressedAgainReturnsToAutomatic() throws {
        let b = block()
        try click(b, .button(.direction, 1))
        #expect(b.model.style.direction == .rightToLeft)
        try click(b, .button(.direction, 1))
        #expect(b.model.style.direction == nil)
    }

    @Test func appearanceCheckAddsTheLayerAndChevronOpensDetails() throws {
        let b = block()
        let closed = b.height(.text)
        #expect(b.model.style.stroke == nil)
        try click(b, .check(.outline))
        #expect(b.model.style.stroke != nil)
        #expect(b.frame(.slider(.strokeWidth), .text) == nil)
        try click(b, .chevron(.outline))
        #expect(b.frame(.slider(.strokeWidth), .text) != nil)
        #expect(b.height(.text) == closed + 2 * ControlsGrid.rowHeight)
        try click(b, .button(.strokePosition, 1))
        #expect(b.model.style.stroke?.position == .centre)
    }

    @Test func variableFontShowsAxisRowsThatEditTheStyle() throws {
        let b = block()
        b.model.setFontFamily("Inter")
        let wght = try #require(b.axis("wght"))
        let f = try #require(b.frame(.field(.axis("wght")), .text))
        #expect(b.value(.axis("wght")) == wght.defaultValue)
        b.mouseDown(at: CGPoint(x: f.midX, y: f.midY), part: .text, clickCount: 1)
        b.mouseDragged(to: CGPoint(x: f.midX + 60, y: f.midY), part: .text)
        b.mouseUp(at: CGPoint(x: f.midX + 60, y: f.midY), part: .text)
        let v = try #require(b.model.style.fontAxes?["wght"])
        #expect(v > wght.defaultValue && v <= wght.maximum)
        b.tick()
        var c = Canvas(width: 400, height: 900, atlas: nil, scale: 1)
        b.draw(&c, part: .text)
    }

    @Test func sliderTrackDragSetsTheValueInOneUndoStep() throws {
        let b = block()
        let f = try #require(b.frame(.slider(.size), .text))
        let track = b.sliderParts(f).track
        var begins = 0, ends = 0
        b.model.onBeginEditing = { begins += 1 }
        b.model.onEndEditing = { ends += 1 }
        b.mouseDown(at: CGPoint(x: track.minX + 2, y: f.midY), part: .text, clickCount: 1)
        b.mouseDragged(to: CGPoint(x: track.maxX, y: f.midY), part: .text)
        b.mouseUp(at: CGPoint(x: track.maxX, y: f.midY), part: .text)
        #expect(b.model.style.size == 400)
        #expect(begins == 1 && ends == 1)
    }

    @Test func typingInTheBoxReportsOneGestureAndReturnBreaksTheLine() throws {
        let b = block()
        b.text = "Hi"
        var changes: [String] = [], began = 0, ended = 0
        b.onTextBegin = { began += 1 }
        b.onTextChange = { changes.append($0) }
        b.onTextEnd = { ended += 1 }
        let one = b.height(.text)
        try click(b, .textBox)
        #expect(b.editor != nil)
        #expect(b.key(.character("!"), modifiers: []))
        #expect(b.key(.enter, modifiers: []))
        #expect(b.key(.character("x"), modifiers: []))
        #expect(changes == ["Hi!", "Hi!\n", "Hi!\nx"])
        #expect(b.height(.text) == one)   // two lines fit the two-line minimum
        #expect(b.key(.escape, modifiers: []))
        #expect(b.editor == nil)
        #expect(began == 1 && ended == 1)
    }

    @Test func fontPopupOffersTheFamilies() throws {
        let b = block()
        var shown: [SQMenuItem] = []
        b.onMenu = { items, _, part in shown = items; #expect(part == .text) }
        try click(b, .font)
        #expect(shown.map(\.title) == ["Inter", "Georgia"])
    }

    @Test func arrangeButtonsAskTheHostToAlign() throws {
        let b = block()
        var got: FrameAlignment?
        b.model.onAlignToFrame = { got = $0 }
        try click(b, .button(.frame, 5), .arrange)
        #expect(got == .bottom)
        #expect(b.height(.arrange) == ControlsGrid.rowHeight)
    }

    @Test func animationHeaderOpensTheIntroAndOutroRows() throws {
        let b = block()
        #expect(b.height(.animation) == ControlsGrid.rowHeight)
        try click(b, .animationHeader, .animation)
        #expect(b.frame(.intro, .animation) != nil)
        #expect(b.frame(.field(.outLength), .animation) != nil)
        try click(b, .animationHeader, .animation)
    }

    @Test func colorWellSessionIsOneUndoStepAndKeepsOpacity() throws {
        let b = block()
        try click(b, .check(.background))
        let alpha = try #require(b.model.style.background?.color.alpha)
        var begins = 0, ends = 0
        b.model.onBeginEditing = { begins += 1 }
        b.model.onEndEditing = { ends += 1 }
        var change: (@MainActor (EffectColor?) -> Void)?
        b.onPickColor = { _, _, _, c in change = c }
        try click(b, .well(.background))
        change?(EffectColor(red: 1, green: 0, blue: 0, alpha: 1))
        change?(EffectColor(red: 0, green: 1, blue: 0, alpha: 1))
        change?(nil)
        #expect(b.model.style.background?.color.green == 1)
        #expect(b.model.style.background?.color.alpha == alpha)
        #expect(begins == 1 && ends == 1)
    }

    @Test func eyedropperSamplesInOneUndoStepKeepsOpacityAndHidesWithoutASampler() throws {
        let b = block()
        #expect(b.frame(.eyedropper(.fill), .text) == nil)
        var answer: (@MainActor (SQColorValue?) -> Void)?
        b.sampleScreenColor = { answer = $0 }
        try click(b, .check(.outline))
        let alpha = try #require(b.model.style.stroke?.color.alpha)
        #expect(b.frame(.eyedropper(.gradient), .text) == nil)
        var begins = 0, ends = 0
        b.model.onBeginEditing = { begins += 1 }
        b.model.onEndEditing = { ends += 1 }
        try click(b, .eyedropper(.outline))
        answer?(SQColorValue(r: 0, g: 0, b: 1))
        #expect(b.model.style.stroke?.color.blue == 1)
        #expect(b.model.style.stroke?.color.alpha == alpha)
        #expect(begins == 1 && ends == 1)
        // A canceled sample changes nothing; an off layer's eyedropper does not sample.
        answer = nil
        try click(b, .eyedropper(.shadow))
        #expect(answer == nil)
        let f = try #require(b.frame(.eyedropper(.fill), .text))
        #expect(b.help(at: CGPoint(x: f.midX, y: f.midY), part: .text) == "Pick Fill Color")
    }

    @Test func drawsEveryPartWithoutTraps() throws {
        let b = block()
        for l in TextBlockDraw.Layer.allCases where l.hasDetail { try click(b, .chevron(l)) }
        try click(b, .animationHeader, .animation)
        for part in TextBlockDraw.Part.allCases {
            var c = Canvas(width: Float(b.width), height: Float(b.height(part)), atlas: nil, scale: 1)
            b.draw(&c, part: part)
        }
    }

    // MARK: Round 2: animators, name prompt, Look menu, multi-line box

    @Test func animatorRowsFollowTheEffect() throws {
        let b = block()
        try click(b, .animationHeader, .animation)
        var shown: [SQMenuItem] = []
        b.onMenu = { items, _, _ in shown = items }
        // No animator: only the effect popup takes input.
        #expect(b.menu(for: .animator(.in, .unit)) == nil)
        #expect(!b.isEnabled(.animator(.in, .stagger)))
        try click(b, .animator(.in, .effect), .animation)
        #expect(shown.map(\.title) == TextAnimatorChoices.effects.map(\.0))
        #expect(shown.first?.isChecked == true)                        // "None"
        let item0 = try #require(shown.first { $0.title == "Slide" })
        item0.action?()
        #expect(b.model.animator(.in)?.effect == .slide)
        #expect(b.isEnabled(.animator(.in, .distance)) && !b.isEnabled(.animator(.in, .loops)))
        #expect(b.popupTitle(.animator(.in, .effect)) == "Slide")
        #expect(b.popupTitle(.animator(.in, .unit)) == "By Word")
        try click(b, .animator(.in, .direction), .animation)
        let item1 = try #require(shown.first { $0.title == "Left" })
        item1.action?()
        #expect(b.model.animator(.in)?.direction == .left)
        b.set(.animator(.in, .length), 450)
        #expect(b.value(.animator(.in, .length)) == 450)
        b.set(.animator(.in, .distance), 90)
        #expect(b.model.animator(.in)?.distance == 90)
        // The Out side stays off.
        #expect(b.model.animator(.out) == nil)
        #expect(b.frame(.field(.animator(.out, .loops)), .animation) != nil)
    }

    @Test func saveAsNewLookAsksForTheNameAndCancelSavesNothing() throws {
        let b = block()
        var pending: (@MainActor (String?) -> Void)?
        var asked: [String] = []
        b.askName = { title, initial, done in asked.append("\(title)|\(initial)"); pending = done }
        let before = b.model.styles.entries.count
        b.saveLookAsNew()
        #expect(asked == ["Save as New Look|My Look"])
        let cancel = try #require(pending)
        cancel(nil)
        #expect(b.model.styles.entries.count == before)
        b.saveLookAsNew()
        let answer = try #require(pending)
        answer("  Mine  ")
        #expect(b.model.styles.entries.count == before + 1)
        #expect(b.model.appliedStyleID.flatMap { b.model.styles.entry($0)?.name } == "Mine")
    }

    @Test func rightClickOnTheLookOffersRenameAndDelete() throws {
        let b = block()
        var shown: [SQMenuItem] = []
        b.onMenu = { items, _, _ in shown = items }
        let f = try #require(b.frame(.look, .text))
        #expect(b.contextMenu(at: CGPoint(x: f.midX, y: f.midY), part: .text))
        #expect(shown.map(\.title) == ["Save as New Look\u{2026}"])
        let id = try #require(b.model.saveCurrentAsStyle(named: "Mine"))
        b.askName = { _, _, done in done("Yours") }
        #expect(b.contextMenu(at: CGPoint(x: f.midX, y: f.midY), part: .text))
        #expect(shown.count == 4)
        let item0 = try #require(shown.first { $0.title.hasPrefix("Rename") })
        item0.action?()
        #expect(b.model.styles.entry(id)?.name == "Yours")
        let item1 = try #require(shown.last)   // Delete
        item1.action?()
        #expect(b.model.styles.entry(id) == nil)
        #expect(!b.contextMenu(at: CGPoint(x: 1, y: 1), part: .text))   // the header: not the Look popup
    }

    @Test func boxEditsLineByLine() throws {
        let b = block()
        b.text = "ab\ncd"
        try click(b, .textBox)
        var e = try #require(b.editor)
        #expect(e.position(of: e.caret) == (1, 2))                      // the click hit the second line, right of its text
        _ = b.key(.up, modifiers: [])
        e = try #require(b.editor)
        #expect(e.position(of: e.caret) == (0, 2))
        _ = b.key(.home, modifiers: [])
        _ = b.key(.character("X"), modifiers: [])
        #expect(b.editor?.string == "Xab\ncd")
        // A drag from the start of the box selects across the lines.
        let f = try #require(b.frame(.textBox, .text))
        b.mouseDown(at: CGPoint(x: f.minX + 8, y: f.minY + 6), part: .text, clickCount: 1)
        b.mouseDragged(to: CGPoint(x: f.maxX - 2, y: f.minY + 4 + TextBlockDraw.lineHeight * 1.5), part: .text)
        b.mouseUp(at: CGPoint(x: f.maxX - 2, y: f.minY + 4 + TextBlockDraw.lineHeight * 1.5), part: .text)
        #expect(b.editor?.selection == 0..<6)
    }

    // MARK: In the panel (ClipSectionsDraw + EffectControlsDrawPanel)

    private func textSession() throws -> (EditorSession, Clip.ID) {
        let ref = try TextGenerator.makeRef(template: TextTemplate(name: "T", text: "Hi", style: TextStyle()), animations: nil)
        let clip = Clip(name: "t", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(4, 1)),
                        start: .zero, generator: ref)
        var v = Track(kind: .video)
        try v.overwrite(clip)
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [v])
        let s = EditorSession(project: Project(name: "P", timelines: [t]), engine: StubProgramEngine())
        s.select(clips: [clip.id])
        return (s, clip.id)
    }

    @Test func panelPlacesArrangeAfterTransformAndAnimationBelowIt() throws {
        let (s, _) = try textSession()
        let m = EffectControlsModel()
        m.sync(with: s, change: [.project, .selection])
        let p = EffectControlsDrawPanel(model: m)
        p.size = CGSize(width: 400, height: 3000)
        let sec = ClipSectionsDraw(session: s)
        p.clipSections = sec
        #expect(sec.mode == .text)
        #expect(sec.textBlock.text == "Hi")
        #expect(p.sectionFrame.minY == 0 && p.sectionFrame.height == sec.textBlock.height(.text))
        let motion = try #require(p.rows.first { $0.kind == .section(.motion) })
        #expect(motion.y >= p.sectionFrame.maxY)
        #expect(p.arrangeFrame.height == ControlsGrid.rowHeight)
        #expect(p.animationFrame.minY == p.arrangeFrame.maxY + ControlsMetrics.sectionGap)
        // Every section after Transform starts below the Animation section.
        let after = p.rows.filter { r in if case .section(let x) = r.kind { return x != .motion && r.y > motion.y } else { return false } }
        for r in after { #expect(r.y >= p.animationFrame.maxY) }
    }

    @Test func titleTemplatesJoinTheLookPopup() throws {
        let (s, _) = try textSession()
        let sec = ClipSectionsDraw(session: s)
        let id = UUID()
        var picked: UUID?
        sec.templateEntries = { [(id, "Promo")] }
        sec.onPickTemplate = { picked = $0 }
        var shown: [SQMenuItem] = []
        sec.onMenu = { items, _ in shown = items }
        let b = sec.textBlock
        b.width = 360
        try click(b, .look)
        let item = try #require(shown.first { $0.title == "Promo (Template)" })
        item.action?()
        #expect(picked == id)
        // A right click on the Look popup offers at least Save as New Look (the carried Look decides the rest).
        let f = try #require(b.frame(.look, .text))
        #expect(sec.contextMenu(at: CGPoint(x: f.midX, y: f.midY)))
        #expect(shown.contains { $0.title == "Save as New Look\u{2026}" })
    }

    @Test func typingAndStyleEditsReachTheClip() throws {
        let (s, id) = try textSession()
        let sec = ClipSectionsDraw(session: s)
        let b = sec.textBlock
        b.width = 360
        b.clock = { 0 }
        try click(b, .textBox)
        _ = b.key(.character("!"), modifiers: [])
        _ = b.key(.escape, modifiers: [])
        try click(b, .button(.style, 1))
        let clip = try #require(s.activeTimeline?.tracks[0].clips.first { $0.id == id })
        let (t, _) = try TextGenerator.decode(try #require(clip.generator))
        #expect(t.text == "Hi!")
        #expect(t.style.italic)
    }
}
