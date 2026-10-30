import Foundation
import Testing
import SQCore
import SQText
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor private func makeSession(_ items: [CaptionItem]) -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    s.replaceCaptions(items)
    return s
}

private func item(_ text: String, _ a: Int64, _ b: Int64) -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: Time(a, 1), end: Time(b, 1)), styleRef: "default")
}

private let red = RGBAColor(red: 1, green: 0, blue: 0)

/// FB-M point 6 / W8.3: the Style tab of the Captions panel. "All captions" edits the kit caption style (brand tokens in
/// place), "Selected" gives the selected captions a look of their own. Every edit is one undo step.
@MainActor @Suite(.serialized) struct CaptionStyleTabTests {
    // MARK: Pure edit rules

    @Test func allScopeEditsTheBoundTokenInPlace() {
        let kit = CaptionStyleEdit.apply(.font("Futura-Bold"), to: .starter)
        #expect(kit.fonts[StyleKit.brandFontToken] == "Futura-Bold")             // the brand changes, binding stays
        #expect(kit.caption?.font == .token(StyleKit.brandFontToken))
        let c = CaptionStyleEdit.apply(.textColor(red), to: .starter)
        #expect(c.colors[StyleKit.textColorToken] == EffectColor(red: 1, green: 0, blue: 0))
    }

    @Test func allScopeWritesALiteralWhenNothingIsBound() {
        let kit = CaptionStyleEdit.apply(.font("Menlo"), to: StyleKit())
        #expect(kit.caption?.font == .literal("Menlo"))
        #expect(kit.caption?.baseStyle == "default")
        #expect(CaptionStyleEdit.apply(.size(80), to: kit).caption?.size == 80)
        #expect(CaptionStyleEdit.apply(.allCaps(true), to: kit).caption?.allCaps == true)
        #expect(CaptionStyleEdit.apply(.animation("fade"), to: kit).caption?.animation == "fade")
    }

    @Test func allScopeLookStartsFromThatLookAndKeepsTheBrandFont() {
        var kit = CaptionStyleEdit.apply(.size(90), to: .starter)
        kit = CaptionStyleEdit.apply(.look("outline"), to: kit)
        #expect(kit.caption?.baseStyle == "outline")
        #expect(kit.caption?.size == nil && kit.caption?.usesPill == false)
        #expect(kit.caption?.font == .token(StyleKit.brandFontToken))
    }

    @Test func allScopeOutlineAndPillTurnOnAndOff() throws {
        let lib = CaptionPresetLibrary.builtIn
        var kit = CaptionStyleEdit.apply(.look("outline"), to: StyleKit())
        kit = CaptionStyleEdit.apply(.outline(nil), to: kit)
        let off = try #require(kit.captionStyle(base: lib))
        #expect(off.stroke == nil || off.stroke?.color.alpha == 0)
        kit = CaptionStyleEdit.apply(.outline(red), to: kit)
        #expect(kit.captionStyle(base: lib)?.stroke?.color == red)
        kit = CaptionStyleEdit.apply(.pill(red), to: kit)
        #expect(kit.captionStyle(base: lib)?.background?.color == red)
        kit = CaptionStyleEdit.apply(.pill(nil), to: kit)
        #expect(kit.captionStyle(base: lib)?.background == nil)
        // the pill look itself turned off loses its box too
        let pillOff = CaptionStyleEdit.apply(.pill(nil), to: CaptionStyleEdit.apply(.look(CaptionPill.styleID), to: StyleKit()))
        #expect(pillOff.captionStyle(base: lib)?.background == nil)
    }

    @Test func selectedScopeEditsAStyleAndUnbindsTheField() {
        var style = CaptionPresetLibrary.builtIn.style(for: "default")
        style.tokens = TextStyleTokens(font: StyleKit.brandFontToken, color: StyleKit.textColorToken)
        let lib = CaptionPresetLibrary.builtIn
        let f = CaptionStyleEdit.apply(.font("Menlo"), to: style, library: lib)
        #expect(f.fontName == "Menlo" && f.tokens?.font == nil && f.tokens?.color == StyleKit.textColorToken)
        #expect(CaptionStyleEdit.apply(.outline(red), to: style, library: lib).stroke?.color == red)
        #expect(CaptionStyleEdit.apply(.pill(red), to: style, library: lib).background?.color == red)
        #expect(CaptionStyleEdit.apply(.pill(nil), to: CaptionStyleEdit.apply(.pill(red), to: style, library: lib), library: lib).background == nil)
        #expect(CaptionStyleEdit.apply(.look("outline"), to: style, library: lib).stroke != nil)
    }

    // MARK: Session

    @Test func allCaptionsIsOneUndoStepAndEveryCaptionUsesTheKitStyle() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1), item("b", 2, 3)])
        s.select(clips: [], captions: [s.captionItems[0].id])
        #expect(s.setSelectedCaptionStyle("outline"))                        // one caption with its own style
        let depth = s.undoDepth
        #expect(s.editCaptionStyle(.size(90), scope: .all))
        #expect(s.undoDepth == depth + 1)
        #expect(s.project.styleKit?.caption?.size == 90)
        #expect(s.captionItems.allSatisfy { $0.styleRef == StyleKit.captionStyleRef && !$0.styleOverridden })
        #expect(s.captionStyleState(scope: .all)?.style.size == 90)
        s.undo()
        #expect(s.project.styleKit == nil)
    }

    @Test func continuingAGestureMergesIntoOneUndoStep() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1)])
        let depth = s.undoDepth
        #expect(s.editCaptionStyle(.textColor(red), scope: .all))
        #expect(s.editCaptionStyle(.textColor(RGBAColor(red: 0, green: 1, blue: 0)), scope: .all, continuesGesture: true))
        #expect(s.undoDepth == depth + 1)
    }

    @Test func selectedCaptionsGetTheirOwnLookAndTheOthersStay() throws {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1), item("b", 2, 3), item("c", 4, 5)])
        let a = s.captionItems[0].id, b = s.captionItems[1].id
        s.select(clips: [], captions: [a])
        let depth = s.undoDepth
        #expect(s.editCaptionStyle(.textColor(red), scope: .selected))
        #expect(s.undoDepth == depth + 1)
        let ref = try #require(s.captionItems.first { $0.id == a }?.styleRef)
        #expect(ref.hasPrefix(CaptionLook.styleID(for: StyleKit.lookID(""))))
        #expect(s.captionItems.filter { $0.id != a }.allSatisfy { $0.styleRef == "default" })
        #expect(CaptionLookRegistry.shared.library(for: s.project.styleKit).style(for: ref).color == red)
        #expect(s.captionStyleState(scope: .selected)?.style.color == red)
        // editing the same caption again updates its look instead of adding one
        #expect(s.editCaptionStyle(.size(70), scope: .selected))
        #expect(s.project.styleKit?.looks.count == 1)
        // another caption gets a look of its own; the first keeps red
        s.select(clips: [], captions: [b])
        #expect(s.editCaptionStyle(.size(40), scope: .selected))
        #expect(s.project.styleKit?.looks.count == 2)
        let lib = CaptionLookRegistry.shared.library(for: s.project.styleKit)
        #expect(lib.style(for: s.captionItems.first { $0.id == a }?.styleRef).size == 70)
        #expect(lib.style(for: s.captionItems.first { $0.id == b }?.styleRef).size == 40)
    }

    @Test func allCaptionsDropsLooksNoCaptionUsesAnyMore() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1), item("b", 2, 3)])
        s.select(clips: [], captions: [s.captionItems[0].id])
        #expect(s.editCaptionStyle(.size(70), scope: .selected))
        #expect(s.project.styleKit?.looks.count == 1)
        #expect(s.editCaptionStyle(.size(50), scope: .all))
        #expect(s.project.styleKit?.looks.isEmpty == true)
    }

    @Test func selectedScopeNeedsASelection() {
        let s = makeSession([item("a", 0, 1)])
        #expect(!s.editCaptionStyle(.size(70), scope: .selected))
        #expect(!s.editCaptionStyle(.animation("fade"), scope: .selected))
    }

    @Test func selectedScopeAnimatesOnlyTheSelectedCaptionsAsOneUndoStep() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1), item("b", 2, 3)])
        let a = s.captionItems[0].id
        s.select(clips: [], captions: [a])
        let depth = s.undoDepth
        #expect(s.editCaptionStyle(.animation("fade"), scope: .selected))
        #expect(s.undoDepth == depth + 1)
        #expect(s.captionItems[0].animationRef == "fade")
        #expect(s.captionItems[1].animationRef != "fade")
        #expect(s.captionStyleState(scope: .selected)?.animationID == "fade")
        // a style edit of the same caption keeps its animation
        #expect(s.editCaptionStyle(.size(70), scope: .selected))
        #expect(s.captionItems[0].animationRef == "fade")
        // All Captions is the master: it hands every caption back to the kit animation
        #expect(s.editCaptionStyle(.animation("pop"), scope: .all))
        #expect(s.captionItems.allSatisfy { $0.animationRef == StyleKit.captionAnimationRef })
    }

    // MARK: View

    @Test func styleTabShowsTheCaptionStyleAndItsControlsEditIt() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1), item("b", 2, 3)])
        let view = CaptionStyleTabView()
        view.session = s
        #expect(view.lookPopUp.selectedItem?.representedObject as? String == "default")
        #expect(view.inspectorModel.style.size == CaptionPresetLibrary.builtIn.style(for: "default").size)
        #expect(!view.scopeControl.isEnabled(forSegment: 1))                  // nothing selected
        view.inspectorModel.setSize(90)
        #expect(s.project.styleKit?.caption?.size == 90)
        view.inspectorModel.setBackgroundEnabled(true)
        view.refresh()
        #expect(s.captionStyleState(scope: .all)?.hasPill == true)
        #expect(view.inspectorModel.style.background != nil)
        s.select(clips: [], captions: [s.captionItems[0].id])
        view.refresh()
        #expect(view.scopeControl.isEnabled(forSegment: 1))
    }

    @Test func panelHasTranscribeCaptionsAndStyleTabs() {
        #expect(TextPanelView.Tab.allCases.map(\.title) == ["Transcribe", "List", "Look", "Templates"])
    }

    @Test func editStyleKitCoalescesAGesture() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1)])
        let depth = s.undoDepth
        s.editStyleKit { $0.colors["accent"] = EffectColor(red: 1, green: 0, blue: 0) }
        s.editStyleKit(continuesGesture: true) { $0.colors["accent"] = EffectColor(red: 0, green: 0, blue: 1) }
        #expect(s.undoDepth == depth + 1)
        #expect(s.project.styleKit?.colors["accent"] == EffectColor(red: 0, green: 0, blue: 1))
    }
}
