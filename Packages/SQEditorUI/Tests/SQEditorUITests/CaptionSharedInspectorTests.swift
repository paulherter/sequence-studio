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

/// The Captions Style tab shares the Text panel's model and sections: every Text panel setting reaches the caption look
/// (kit caption style for All Captions, an own look for Selected) and the drawn style, so preview and export agree.
@MainActor @Suite(.serialized) struct CaptionSharedInspectorTests {
    private let lib = CaptionPresetLibrary.builtIn

    // MARK: Diff

    @Test func diffListsOnlyWhatChanged() {
        let a = TextStyle()
        #expect(CaptionStyleEdit.fields(from: a, to: a).isEmpty)
        var b = a
        b.weight = .bold; b.tracking = 2; b.alignment = .left
        #expect(CaptionStyleEdit.fields(from: a, to: b) == [.weight(.bold), .alignment(.left), .tracking(2)])
    }

    @Test func diffCarriesAllValuesOfALayerThatComesOn() {
        let a = TextStyle()
        var b = a
        b.stroke = TextStroke(color: red, width: 6, position: .centre)
        b.shadow = TextShadow(color: red, offsetX: 1, offsetY: 2, blur: 3)
        b.background = TextBackground(color: red, padding: BoxPadding(horizontal: 24, vertical: 12), cornerRadius: 10_000)
        let f = CaptionStyleEdit.fields(from: a, to: b)
        #expect(f.contains(.outline(red)) && f.contains(.strokeWidth(6)) && f.contains(.strokePosition(.centre)))
        #expect(f.contains(.pill(red)) && f.contains(.pillCorners(nil)))
        #expect(f.contains(.pillPadding(horizontalEm: 24 / a.size, verticalEm: 12 / a.size)))
        #expect(f.contains(.shadow(b.shadow)))
        #expect(CaptionStyleEdit.fields(from: b, to: a).contains(.outline(nil)))
        #expect(CaptionStyleEdit.fields(from: b, to: a).contains(.pill(nil)))
        #expect(CaptionStyleEdit.fields(from: b, to: a).contains(.shadow(nil)))
    }

    @Test func displayStyleDropsInvisibleLayers() {
        var s = TextStyle()
        s.stroke = TextStroke(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0), width: 4)
        s.background = TextBackground(color: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0), padding: BoxPadding(horizontal: 1, vertical: 1), cornerRadius: 1)
        s.tokens = TextStyleTokens(font: "brand")
        let d = CaptionStyleEdit.displayStyle(s)
        #expect(d.stroke == nil && d.background == nil && d.tokens == nil)
    }

    // MARK: Kit (All Captions)

    @Test func everyTextPanelFieldReachesTheKitCaptionStyle() throws {
        var f: [CaptionStyleField] = [.weight(.heavy), .italic(true), .alignment(.right), .tracking(3), .lineSpacing(7),
                                      .outline(red), .strokeWidth(9), .strokePosition(.centre)]
        let sh = TextShadow(color: red, offsetX: 2, offsetY: 3, blur: 5)
        f.append(.shadow(sh))
        let kit = CaptionStyleEdit.apply(f, to: StyleKit())
        let s = try #require(kit.captionStyle(base: lib))
        #expect(s.weight == .heavy && s.italic && s.alignment == .right && s.tracking == 3 && s.lineSpacing == 7)
        #expect(s.stroke?.color == red && s.stroke?.width == 9 && s.stroke?.position == .centre)
        #expect(s.shadow?.color == red && s.shadow?.offsetX == 2 && s.shadow?.offsetY == 3 && s.shadow?.blur == 5)
        // The drawn style (preview and export both read the library) is the registered kit caption style.
        #expect(lib.applying(kit).style(for: StyleKit.captionStyleRef).weight == .heavy)
    }

    @Test func shadowOffRemovesTheLooksShadowAndOnBringsItBack() throws {
        var kit = CaptionStyleEdit.apply(.look("outline"), to: StyleKit())
        let base = lib.style(for: "outline")
        kit = CaptionStyleEdit.apply(.shadow(nil), to: kit)
        #expect(try #require(kit.captionStyle(base: lib)).shadow == nil)
        if base.shadow != nil { #expect(kit.caption?.tweaks?.hidesShadow == true) }
        let sh = TextShadow(color: red, offsetX: 0, offsetY: 4, blur: 8)
        kit = CaptionStyleEdit.apply(.shadow(sh), to: kit)
        #expect(try #require(kit.captionStyle(base: lib)).shadow?.blur == 8)
        #expect(kit.caption?.tweaks?.hidesShadow == nil)
    }

    @Test func pillPaddingEditsTheKitPillAndKeepsTheLookClean() throws {
        let kit = CaptionStyleEdit.apply(.pillPadding(horizontalEm: 0.6, verticalEm: 0.2), to: StyleKit())
        #expect(kit.pill?.horizontalEm == 0.6 && kit.pill?.verticalEm == 0.2 && kit.caption?.usesPill == true)
        // A new look starts clean: tweaks of the old look are gone.
        let tweaked = CaptionStyleEdit.apply(.weight(.black), to: kit)
        #expect(CaptionStyleEdit.apply(.look("outline"), to: tweaked).caption?.tweaks == nil)
    }

    @Test func tweaksSurviveTheStyleKitCodableRoundTrip() throws {
        let kit = CaptionStyleEdit.apply([.weight(.bold), .tracking(1.5), .shadow(TextShadow(color: red, offsetX: 1, offsetY: 1, blur: 2))], to: StyleKit())
        let data = try JSONEncoder().encode(kit)
        let back = try JSONDecoder().decode(StyleKit.self, from: data)
        #expect(back == kit)
        #expect(back.captionStyle(base: lib)?.weight == .bold)
    }

    @Test func aKitWithoutTweaksStillDecodesAndDrawsAsBefore() throws {
        let old = StyleKit(caption: CaptionStyleSpec(baseStyle: "default", size: 70))
        var obj = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        var cap = try #require(obj["caption"] as? [String: Any])
        #expect(cap["tweaks"] == nil)                                            // nil tweaks are not written
        cap["tweaks"] = nil; obj["caption"] = cap
        let back = try JSONDecoder().decode(StyleKit.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.caption?.tweaks == nil && back.caption?.size == 70)
    }

    // MARK: Selected captions

    @Test func selectedScopeAppliesTheSameFieldsToTheStyle() {
        let base = lib.style(for: "default")
        let f: [CaptionStyleField] = [.weight(.black), .alignment(.left), .tracking(4), .outline(red), .strokeWidth(5), .strokePosition(.centre),
                                      .pill(red), .pillPadding(horizontalEm: 0.5, verticalEm: 0.25), .pillCorners(8), .shadow(TextShadow(color: red, offsetX: 0, offsetY: 1, blur: 2))]
        let s = CaptionStyleEdit.apply(f, to: base, library: lib)
        #expect(s.weight == .black && s.alignment == .left && s.tracking == 4)
        #expect(s.stroke?.width == 5 && s.stroke?.position == .centre)
        #expect(s.background?.padding.horizontal == (base.size * 0.5).rounded() && s.background?.cornerRadius == 8)
        #expect(s.shadow?.blur == 2)
    }

    // MARK: Session + view

    @Test func severalFieldsAreOneUndoStep() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1)])
        let depth = s.undoDepth
        #expect(s.editCaptionStyle([.weight(.bold), .tracking(2), .italic(true)], scope: .all))
        #expect(s.undoDepth == depth + 1)
        #expect(s.captionStyleState(scope: .all)?.style.tracking == 2)
        s.undo()
        #expect(s.captionStyleState(scope: .all)?.style.tracking == 0)
    }

    @Test func inspectorEditsReachBothScopes() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1), item("b", 2, 3)])
        let view = CaptionStyleTabView()
        view.session = s
        view.inspectorModel.setTracking(3)
        view.inspectorModel.setShadowEnabled(true)
        #expect(s.captionStyleState(scope: .all)?.style.tracking == 3)
        #expect(s.captionStyleState(scope: .all)?.style.shadow != nil)
        s.select(clips: [], captions: [s.captionItems[0].id])
        view.refresh()
        view.scopeControlSelect(1)
        #expect(view.inspectorModel.style.tracking == 3)                          // the selected caption shows the same look
        view.inspectorModel.setWeight(.black)
        #expect(s.captionStyleState(scope: .selected)?.style.weight == .black)
        #expect(s.captionStyleState(scope: .all)?.style.weight != .black)         // only the selection changed
    }

    @Test func aScrubGestureIsOneUndoStep() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1)])
        let view = CaptionStyleTabView()
        view.session = s
        let depth = s.undoDepth
        view.inspectorModel.beginEditing()
        for v in [1.0, 2, 3, 4] { view.inspectorModel.setTracking(v) }
        view.inspectorModel.endEditing()
        #expect(s.undoDepth == depth + 1)
        #expect(s.captionStyleState(scope: .all)?.style.tracking == 4)
    }
}

extension CaptionStyleTabView {
    /// Test helper: picks a scope segment the way a click does.
    func scopeControlSelect(_ i: Int) {
        scopeControl.selectedSegment = i
        scopeControl.sendAction(scopeControl.action, to: scopeControl.target)
    }
}
