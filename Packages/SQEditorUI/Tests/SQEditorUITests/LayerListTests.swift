import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQTimelineUI

@MainActor @Suite struct LayerListTests {
    private func layer(_ name: String) -> GraphicsLayer {
        var l = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
        l.name = name
        return l
    }

    @Test func aRangedItemIsDimmedOutsideItsRangeAtThePlayhead() {
        func s(_ n: Int64) -> Time { Time(n, 1) }
        var ranged = layer("r")
        ranged.range = TimeRange(start: s(2), end: s(4))
        let fd = Time(1, 30)
        #expect(LayerListLogic.isOutsideRange(ranged, local: s(2) - fd))
        #expect(!LayerListLogic.isOutsideRange(ranged, local: s(2)))            // first frame
        #expect(!LayerListLogic.isOutsideRange(ranged, local: s(4) - fd))       // last frame
        #expect(LayerListLogic.isOutsideRange(ranged, local: s(4)))             // the end is exclusive
        #expect(!LayerListLogic.isOutsideRange(ranged, local: nil))             // playhead outside the clip: no state
        #expect(!LayerListLogic.isOutsideRange(layer("whole"), local: s(3)))    // no range: never dimmed

        // The strip's range bar: across the range, never thinner than 2 pt and never past the strip.
        let d = s(10)
        let bar = KeyTickStrip.rangeSpan(TimeRange(start: s(2), end: s(4)), duration: d, width: 100)
        #expect(abs(bar.x - 20) < 1e-9 && abs(bar.width - 20) < 1e-9)
        let stub = KeyTickStrip.rangeSpan(TimeRange(start: s(10), end: s(10)), duration: d, width: 100)
        #expect(stub.x == 98 && stub.width == 2)

        // The row view: name and icon take the disabled state, and come back.
        let row = LayerListLogic.rows(GraphicsDocument(layers: [ranged]))[0]
        let v = LayerListRowView(row: row)
        let name = v.subviews.compactMap { $0 as? NSTextField }.first
        let icon = v.subviews.compactMap { $0 as? NSImageView }.first
        #expect(name?.textColor == Theme.Colors.label && icon?.alphaValue == 1)
        v.isOutsideRange = true
        #expect(name?.textColor == Theme.State.disabledText && icon?.alphaValue == Theme.State.disabledAlpha)
        v.isOutsideRange = false
        #expect(name?.textColor == Theme.Colors.label && icon?.alphaValue == 1)
    }

    /// Bottom first a, b, c, d; b and c grouped "G". Display (front first): d, G, c, b, a.
    private func doc() -> (GraphicsDocument, [UUID], UUID) {
        var d = GraphicsDocument()
        let ids = ["a", "b", "c", "d"].map { d.add(layer($0)) }
        let g = d.group([ids[1], ids[2]], name: "G")!
        return (d, ids, g)
    }

    @Test func rowsAreFrontFirstWithGroupHeaders() {
        let (d, ids, g) = doc()
        let rows = LayerListLogic.rows(d)
        #expect(rows.map(\.kind) == [.layer(ids[3]), .group(g), .layer(ids[2]), .layer(ids[1]), .layer(ids[0])])
        #expect(rows.map(\.isIndented) == [false, false, true, true, false])
        #expect(rows[1].name == "G" && rows[1].isOpen)
        let closed = LayerListLogic.rows(d, collapsed: [g])
        #expect(closed.map(\.kind) == [.layer(ids[3]), .group(g), .layer(ids[0])])
        #expect(closed[1].isOpen == false)
    }

    @Test func groupRowShowsLockAndEyeOfAllMembers() {
        var (d, ids, g) = doc()
        d.update(ids[1]) { $0.isLocked = true }
        #expect(LayerListLogic.rows(d)[1].isLocked == false)
        d.update(ids[2]) { $0.isLocked = true; $0.isVisible = false }
        let r = LayerListLogic.rows(d)[1]
        #expect(r.groupID == g && r.isLocked && r.isVisible == false)
    }

    @Test func dropBetweenMembersJoinsTheGroup() {
        let (d, ids, g) = doc()
        let rows = LayerListLogic.rows(d)
        // d dragged into the gap between c and b (before rows[3] = b).
        let drop = LayerListLogic.drop(.layers([ids[3]]), rows: rows, document: d, gap: 3)
        #expect(drop == LayerDrop(ids: [ids[3]], toIndex: 2, group: g))
        var after = d
        after.move(drop!.ids, toIndex: drop!.toIndex, group: drop!.group)
        #expect(after.layers.map(\.id) == [ids[0], ids[1], ids[3], ids[2]])
    }

    @Test func dropAboveAGroupHeaderStaysOutside() {
        let (d, ids, _) = doc()
        let rows = LayerListLogic.rows(d)
        // a dragged to the gap before the header: right above c, outside the group.
        let drop = LayerListLogic.drop(.layers([ids[0]]), rows: rows, document: d, gap: 1)
        #expect(drop == LayerDrop(ids: [ids[0]], toIndex: 2, group: nil))
    }

    @Test func dropOntoAGroupRowJoinsAtItsTop() {
        let (d, ids, g) = doc()
        let rows = LayerListLogic.rows(d)
        let drop = LayerListLogic.drop(.layers([ids[0]]), rows: rows, document: d, gap: 0, onto: 1)
        #expect(drop == LayerDrop(ids: [ids[0]], toIndex: 2, group: g))
    }

    @Test func memberDraggedToTheBottomLeavesTheGroup() {
        let (d, ids, _) = doc()
        let rows = LayerListLogic.rows(d)
        let drop = LayerListLogic.drop(.layers([ids[2]]), rows: rows, document: d, gap: rows.count)
        #expect(drop == LayerDrop(ids: [ids[2]], toIndex: 0, group: nil))
    }

    @Test func rowsCarryLabelsAndGroupShowsSharedOne() {
        var (d, ids, g) = doc()
        d.update(ids[1]) { $0.label = .rose }
        #expect(LayerListLogic.rows(d).first { $0.groupID == g }?.label == nil)      // members differ
        d.update(ids[2]) { $0.label = .rose }
        let rows = LayerListLogic.rows(d)
        #expect(rows.first { $0.groupID == g }?.label == .rose)
        #expect(rows.first { $0.layerID == ids[1] }?.label == .rose && rows.first { $0.layerID == ids[0] }?.label == nil)
    }

    @Test func draggedGroupNeverLandsInsideAnotherGroup() {
        var d = GraphicsDocument()
        let ids = ["a", "b", "c", "d"].map { d.add(layer($0)) }
        let low = d.group([ids[0], ids[1]], name: "Low")!
        let high = d.group([ids[2], ids[3]], name: "High")!
        let rows = LayerListLogic.rows(d)          // High, d, c, Low, b, a
        // Drag Low into the gap between d and c: it goes above High instead, keeping its own group.
        let drop = LayerListLogic.drop(.group(low), rows: rows, document: d, gap: 2)
        #expect(drop == LayerDrop(ids: [ids[0], ids[1]], toIndex: 2, group: low))
        _ = high
    }

    @Test func dropInPlaceIsNil() {
        let (d, ids, _) = doc()
        let rows = LayerListLogic.rows(d)
        #expect(LayerListLogic.drop(.layers([ids[3]]), rows: rows, document: d, gap: 0) == nil)
        #expect(LayerListLogic.drop(.layers([ids[3]]), rows: rows, document: d, gap: 1) == nil)
    }

    @Test func clickSelection() {
        let (d, ids, g) = doc()
        let rows = LayerListLogic.rows(d)
        #expect(LayerListLogic.select(rows: rows, document: d, current: [], index: 1, anchor: nil, toggle: false, range: false)
                == [ids[1], ids[2]])
        #expect(LayerListLogic.select(rows: rows, document: d, current: [ids[3]], index: 4, anchor: nil, toggle: true, range: false)
                == [ids[3], ids[0]])
        #expect(LayerListLogic.select(rows: rows, document: d, current: [ids[3], ids[0]], index: 4, anchor: nil, toggle: true, range: false)
                == [ids[3]])
        #expect(LayerListLogic.select(rows: rows, document: d, current: [], index: 3, anchor: 0, toggle: false, range: true)
                == [ids[3], ids[2], ids[1]])
        #expect(LayerListLogic.isSelected(rows[1], document: d, selection: [ids[1], ids[2]]))
        #expect(!LayerListLogic.isSelected(rows[1], document: d, selection: [ids[1]]))
        _ = g
    }

    // MARK: Editor

    private func session() -> EditorSession {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        return EditorSession(project: Project(name: "P", timelines: [t]))
    }

    @Test func editorDropRenameAndGroupFlagsAreOneUndoStepEach() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle); e.addShape(.ellipse); e.addShape(.line)
        let ids = try #require(e.document?.layers.map(\.id))
        e.select([ids[1], ids[2]])
        e.groupSelected()
        let g = try #require(e.document?.groups.first?.id)

        var depth = s.undoDepth
        e.renameGroup(g, "Lower third")
        #expect(e.document?.group(g)?.name == "Lower third" && s.undoDepth == depth + 1)
        e.renameGroup(g, "Lower third")                       // unchanged: no step
        #expect(s.undoDepth == depth + 1)

        depth = s.undoDepth
        e.setLocked(e.members(of: g), true)
        e.setVisible(e.members(of: g), false)
        #expect(s.undoDepth == depth + 2)
        #expect(e.document?.layers.filter { $0.group == g }.allSatisfy { $0.isLocked && !$0.isVisible } == true)

        depth = s.undoDepth
        let doc = try #require(e.document)
        let drop = try #require(LayerListLogic.drop(.layers([ids[0]]), rows: LayerListLogic.rows(doc), document: doc, gap: 0))
        e.apply(drop)
        #expect(s.undoDepth == depth + 1)
        #expect(e.document?.layers.last?.id == ids[0] && e.selectedLayers == [ids[0]])
        s.undo()
        #expect(e.document?.layers.first?.id == ids[0])
    }

    @Test func bringToFrontAndSendToBack() throws {
        let s = session()
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        e.addShape(.rectangle); e.addShape(.ellipse); e.addShape(.line)
        let ids = try #require(e.document?.layers.map(\.id))
        e.select([ids[0]])
        e.reorder(.front)
        #expect(e.document?.layers.map(\.id) == [ids[1], ids[2], ids[0]])
        e.reorder(.back)
        #expect(e.document?.layers.map(\.id) == ids)
    }

    // MARK: Step 2 of the graphic layer system

    @Test func rowShowsEyeThenLockAtTheTrailingEdgeAndTheNameFillsTheRest() {
        var d = GraphicsDocument()
        _ = d.add(layer("Bar"))
        let v = LayerListRowView(row: LayerListLogic.rows(d)[0])
        v.frame = NSRect(x: 0, y: 0, width: 260, height: Theme.Row.list)
        v.layoutSubtreeIfNeeded()
        let buttons = v.subviews.compactMap { $0 as? IconButton }
        let eye = buttons.first { $0.accessibilityLabel() == "Hide" }
        let lock = buttons.first { $0.accessibilityLabel() == "Lock" }
        let name = v.subviews.compactMap { $0 as? NSTextField }.first
        #expect(eye != nil && lock != nil && name != nil)
        #expect(eye!.frame.maxX <= lock!.frame.minX)                       // eye, then lock
        #expect(lock!.frame.maxX == 260 - Theme.Spacing.md)
        #expect(name!.frame.maxX <= eye!.frame.minX)                       // the name never runs under the toggles
        #expect(name!.frame.minX == LayerListRowView.nameX(for: LayerListLogic.rows(d)[0]))
        // Narrower: the name shrinks, the toggles stay at the edge.
        v.frame.size.width = 120
        v.layoutSubtreeIfNeeded()
        #expect(lock!.frame.maxX == 120 - Theme.Spacing.md && name!.frame.maxX <= eye!.frame.minX)
    }

    private func panel(_ build: (GraphicsEditor) -> Void) -> (GraphicsPanelView, GraphicsEditor, NSWindow) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let e = GraphicsEditor(session: EditorSession(project: Project(name: "P", timelines: [t])))
        e.newGraphicsClip()
        build(e)
        let p = GraphicsPanelView(editor: e)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = p
        p.sync([.project, .selection])
        p.layoutSubtreeIfNeeded()
        return (p, e, w)
    }

    @Test func returnOnATextLayerFocusesItsTextBox() {
        let (p, e, w) = panel { $0.addShape(.rectangle); $0.addText() }
        #expect(e.selectedLayers.count == 1)
        #expect(p.editSelectedLayer())
        #expect(w.firstResponder is NSTextView)
        #expect((w.firstResponder as? NSView)?.isDescendant(of: p.textBlock!) == true)
    }

    @Test func returnOnAShapeLayerRenamesItsRow() {
        let (p, e, w) = panel { $0.addShape(.rectangle) }
        #expect(e.selectedLayers.count == 1)
        #expect(p.editSelectedLayer())
        #expect(p.list.isRenaming)
        _ = w
    }

    @Test func returnWithoutOrWithSeveralLayersDoesNothing() {
        let (p, e, _) = panel { $0.addShape(.rectangle); $0.addShape(.ellipse) }
        e.selectAllLayers()
        #expect(!p.editSelectedLayer())
        e.select([])
        #expect(!p.editSelectedLayer())
    }

    @Test func selectedRowIsHighlightedAndOthersAreNot() {
        let (p, e, _) = panel { $0.addShape(.rectangle); $0.addShape(.ellipse) }
        p.list.reload()
        let d = e.document!
        let flags = p.list.rows.map { LayerListLogic.isSelected($0, document: d, selection: e.selectedLayers) }
        #expect(flags.filter { $0 }.count == 1)
    }
}
