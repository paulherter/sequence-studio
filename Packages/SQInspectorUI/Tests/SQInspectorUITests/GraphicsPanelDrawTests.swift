import Foundation
import Testing
import SQCore
import SQDrawKit
@testable import SQInspectorUI

/// The draw-list Graphics panel (Windows): empty state, layer list selection / reorder / rename / context menu, property
/// rows that edit through `GraphicsEditor` with one undo step per gesture, Delete.
@MainActor @Suite(.serialized) struct GraphicsPanelDrawTests {
    func rig(layers: Bool = true) -> (EditorSession, GraphicsEditor, GraphicsPanelDraw) {
        UserDefaults.standard.removeObject(forKey: "sq.graphics.listHeight")
        let tl = Timeline(name: "T", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                          tracks: Timeline.defaultTracks(video: 2, audio: 1))
        let session = EditorSession(project: Project(name: "P", timelines: [tl]))
        let e = GraphicsEditor(session: session)
        if layers {
            e.newGraphicsClip()
            e.addShape(.rectangle)
            e.addText()
        }
        let p = GraphicsPanelDraw(editor: e)
        p.size = CGSize(width: 360, height: 900)
        var now = 100.0
        p.clock = { now += 1; return now }      // every press is its own click
        p.sync()
        return (session, e, p)
    }

    /// Center of the list row `i` in panel coordinates.
    func rowPoint(_ p: GraphicsPanelDraw, _ i: Int) -> CGPoint {
        CGPoint(x: 120, y: p.listFrame.minY + CGFloat(i) * GraphicsLayerListDraw.rowHeight + GraphicsLayerListDraw.rowHeight / 2)
    }

    /// Center of field `k` of the form row titled `title`, in panel coordinates.
    func fieldPoint(_ p: GraphicsPanelDraw, _ title: String, _ k: Int = 0) -> CGPoint? {
        for (r, y) in p.form.visible {
            guard case .numbers(let t, _, _) = r.kind, t == title,
                  let f = p.form.frame(.field(k), of: r, y: y) else { continue }
            return CGPoint(x: f.midX, y: f.midY + p.blocks().form)
        }
        return nil
    }

    func click(_ p: GraphicsPanelDraw, _ at: CGPoint, _ m: InputModifiers = []) {
        p.mouseDown(at: at, modifiers: m); p.mouseUp(at: at, modifiers: m)
    }

    func type(_ p: GraphicsPanelDraw, _ s: String) {
        for ch in s { _ = p.key(.character(ch), modifiers: []) }
        _ = p.key(.enter, modifiers: [])
    }

    @Test func effectsDroppedOnThePanelGoToTheOneSelectedLayer() {
        let (_, e, p) = rig()
        let had = e.selectedLayer?.effects.count ?? 0
        #expect(e.selectedLayers.count == 1)
        #expect(p.dropEffects([ClipEffect.gaussianBlurKind]))
        #expect((e.selectedLayer?.effects.count ?? 0) == had + 1)
        #expect(!p.dropEffects([]))
        e.selectAllLayers()
        #expect(p.dropEffects([ClipEffect.gaussianBlurKind]))            // taken, but refused with a status line
        #expect(p.status?.text == "Select one layer to add an effect.")
    }

    @Test func effectsDroppedOnALayerRowGoToThatLayerAndSelectIt() {
        let (_, e, p) = rig()
        click(p, rowPoint(p, 1))
        let other = e.selectedLayer?.id
        let target = rowPoint(p, 0)
        p.effectDragOver(at: target)
        #expect(p.list.effectTarget == 0)
        p.effectDragOver(at: nil)
        #expect(p.list.effectTarget == nil)
        #expect(p.dropEffects([ClipEffect.gaussianBlurKind], at: target))
        #expect(e.selectedLayer?.id != other)
        #expect(e.selectedLayer?.effects.count == 1)
        #expect(p.list.effectTarget == nil)
    }

    @Test func returnEditsTheTextOfATextLayerAndRenamesOtherLayers() {
        let (_, e, p) = rig()
        click(p, rowPoint(p, 0))
        #expect(e.selectedLayer?.isText == true)
        #expect(p.key(.enter, modifiers: []))
        #expect(p.textBlock?.editor != nil)
        click(p, rowPoint(p, 1))
        #expect(p.key(.enter, modifiers: []))
        #expect(p.list.renameField != nil)
    }

    @Test func effectDropIsIgnoredWithoutAGraphic() {
        let (_, _, p) = rig(layers: false)
        #expect(!p.dropEffects([ClipEffect.gaussianBlurKind]))
    }

    @Test func emptyStateMakesANewGraphicsClip() {
        let (_, e, p) = rig(layers: false)
        #expect(e.clip == nil && p.emptyState == .noGraphic)
        let b = p.emptyButtonFrame
        click(p, CGPoint(x: b.midX, y: b.midY))
        #expect(e.clip?.graphics != nil)
        #expect(p.hasClip)
    }

    @Test func listShowsLayersFrontFirstAndSelects() {
        let (_, e, p) = rig()
        #expect(p.list.rows.count == 2)
        #expect(p.list.rows.first?.symbol == .text)          // the newest layer is in front
        click(p, rowPoint(p, 1))
        #expect(e.selectedLayer?.isText == false)
        #expect(p.form.rows.contains { if case .section(_, "shape", _, _, _) = $0.kind { true } else { false } })
        click(p, rowPoint(p, 0), .command)
        #expect(e.selectedLayers.count == 2)
        // No layer selected: Intro and Outro.
        click(p, CGPoint(x: 120, y: p.listFrame.minY + GraphicsLayerListDraw.rowHeight * 2.5))
        #expect(e.selectedLayers.isEmpty)
        #expect(p.form.rows.contains { if case .section(_, "introOutro", _, _, _) = $0.kind { true } else { false } })
    }

    @Test func typedOpacityIsOneUndoStep() throws {
        let (s, e, p) = rig()
        click(p, rowPoint(p, 1))
        let at = try #require(fieldPoint(p, "Opacity"))
        click(p, at)
        type(p, "40")
        #expect(abs((e.value(.opacity) ?? 0) - 0.4) < 1e-9)
        #expect(s.undo())
        #expect(abs((e.value(.opacity) ?? 0) - 1) < 1e-9)
    }

    @Test func dragReordersAndOptionCopies() {
        let (_, e, p) = rig()
        let front = p.list.rows[0].layerID
        let a = rowPoint(p, 0), below = CGPoint(x: a.x, y: p.listFrame.minY + GraphicsLayerListDraw.rowHeight * 2 - 2)
        p.mouseDown(at: a); p.mouseDragged(to: CGPoint(x: a.x, y: a.y + 10)); p.mouseDragged(to: below); p.mouseUp(at: below)
        p.sync()
        #expect(p.list.rows.last?.layerID == front)
        let n = e.document?.layers.count ?? 0
        let b = rowPoint(p, 1)
        p.mouseDown(at: b); p.mouseDragged(to: CGPoint(x: b.x, y: b.y - 10), modifiers: .option)
        p.mouseDragged(to: CGPoint(x: b.x, y: p.listFrame.minY + 1), modifiers: .option)
        p.mouseUp(at: CGPoint(x: b.x, y: p.listFrame.minY + 1), modifiers: .option)
        #expect(e.document?.layers.count == n + 1)
    }

    @Test func doubleClickRenamesAndContextMenuLists() {
        let (_, e, p) = rig()
        var menu: [SQMenuItem] = []
        p.onMenu = { items, _ in menu = items }
        let id = p.list.rows[1].layerID
        click(p, rowPoint(p, 1))
        click(p, rowPoint(p, 1))
        p.mouseDown(at: rowPoint(p, 1), clickCount: 2); p.mouseUp(at: rowPoint(p, 1))
        #expect(p.list.renameField != nil)
        for _ in 0..<20 { _ = p.key(.backspace, modifiers: []) }
        type(p, "Box")
        #expect(id.flatMap { e.document?.layer($0)?.name } == "Box")
        p.mouseDown(at: rowPoint(p, 1), modifiers: .secondary); p.mouseUp(at: rowPoint(p, 1), modifiers: .secondary)
        #expect(menu.map(\.title).contains("Bring to Front"))
        #expect(menu.map(\.title).contains("Label"))
    }

    @Test func deleteKeyRemovesSelectedLayers() {
        let (_, e, p) = rig()
        click(p, rowPoint(p, 0))
        #expect(p.key(.delete, modifiers: []))
        #expect(e.document?.layers.count == 1)
        #expect(p.list.rows.count == 1)
    }

    @Test func textLayerEmbedsTheTextBlockAndAllStatesDraw() {
        let (_, e, p) = rig()
        var c = Canvas(width: 360, height: 900, atlas: nil, scale: 1)
        p.draw(&c)
        click(p, rowPoint(p, 0))
        #expect(e.selectedLayer?.isText == true)
        #expect(p.textBlock != nil)
        p.draw(&c)
        click(p, rowPoint(p, 1))
        #expect(p.textBlock == nil)
        p.draw(&c)
        let (_, _, empty) = rig(layers: false)
        empty.draw(&c)
    }

    @Test func listHeightDragsAndPersists() {
        let (_, _, p) = rig()
        let h0 = p.listHeight, y = p.handleFrame.midY
        p.mouseDown(at: CGPoint(x: 100, y: y)); p.mouseDragged(to: CGPoint(x: 100, y: y + 48)); p.mouseUp(at: CGPoint(x: 100, y: y + 48))
        #expect(p.listHeight == h0 + 48)
        #expect(UserDefaults.standard.double(forKey: "sq.graphics.listHeight") == Double(h0 + 48))
        UserDefaults.standard.removeObject(forKey: "sq.graphics.listHeight")
    }
}
