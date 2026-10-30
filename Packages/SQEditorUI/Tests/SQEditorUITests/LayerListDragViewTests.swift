import AppKit
import Foundation
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI
@testable import SQTimelineUI

/// The layer list view under a real drag: a long list scrolls while the pointer rests past its edge, and Option copies.
@MainActor @Suite struct LayerListDragViewTests {
    private struct Rig {
        let editor: GraphicsEditor
        let list: LayerListView
        let window: NSWindow
        let doc: LayerListDocument
        let scroll: NSScrollView
        let ids: [UUID]
    }

    private func rig(layers n: Int) throws -> Rig {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        for _ in 0..<n { e.addShape(.rectangle) }
        let ids = try #require(e.document?.layers.map(\.id))
        let list = LayerListView(editor: e)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 232)          // 200 pt of rows above the 32 pt footer
        container.addSubview(list)
        let w = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        w.contentView = container
        list.reload()
        list.layoutSubtreeIfNeeded()
        let scroll = try #require(list.subviews.compactMap { $0 as? NSScrollView }.first)
        let doc = try #require(scroll.documentView as? LayerListDocument)
        return Rig(editor: e, list: list, window: w, doc: doc, scroll: scroll, ids: ids)
    }

    private func event(_ type: NSEvent.EventType, _ r: Rig, docPoint: NSPoint? = nil, windowPoint: NSPoint? = nil,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let p = windowPoint ?? r.doc.convert(docPoint ?? .zero, to: nil)
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0,
                                  windowNumber: r.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func draggingTheBottomLayerToTheTopScrollsWithAHeldPointer() throws {
        let r = try rig(layers: 30)
        let h = Theme.Row.list
        r.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(r.doc.frame.height - r.scroll.contentSize.height, 0)))
        r.scroll.reflectScrolledClipView(r.scroll.contentView)
        let last = CGFloat(r.list.rows.count - 1)
        r.doc.mouseDown(with: event(.leftMouseDown, r, docPoint: NSPoint(x: 120, y: (last + 0.5) * h)))
        // The pointer goes above the list and stays there: only the timer ticks move the list.
        let above = NSPoint(x: 120, y: r.list.convert(NSPoint(x: 0, y: 0), to: nil).y + r.list.bounds.height + 20)
        r.doc.mouseDragged(with: event(.leftMouseDragged, r, windowPoint: above))
        var ticks = 0
        while r.scroll.contentView.bounds.minY > 0, ticks < 2000 { r.list.autoscrollTick(); ticks += 1 }
        #expect(r.scroll.contentView.bounds.minY == 0)
        r.doc.mouseUp(with: event(.leftMouseUp, r, windowPoint: above))
        #expect(r.editor.document?.layers.last?.id == r.ids[0])
        #expect(r.editor.document?.layers.count == 30)
    }

    @Test func optionDragCopiesAndKeepsTheOriginal() throws {
        let r = try rig(layers: 3)
        let h = Theme.Row.list
        // Rows front first: ids[2], ids[1], ids[0]. Drag the bottom row (ids[0]) to the top with Option held.
        r.doc.mouseDown(with: event(.leftMouseDown, r, docPoint: NSPoint(x: 120, y: 2.5 * h), flags: [.option]))
        r.doc.mouseDragged(with: event(.leftMouseDragged, r, docPoint: NSPoint(x: 120, y: 2), flags: [.option]))
        #expect(r.list.isCopying)
        r.doc.mouseUp(with: event(.leftMouseUp, r, docPoint: NSPoint(x: 120, y: 2), flags: [.option]))
        let layers = try #require(r.editor.document?.layers)
        #expect(layers.count == 4 && layers.map(\.id).prefix(3) == r.ids[...])
        #expect(layers.last?.name.hasSuffix("copy") == true)
        #expect(r.editor.selectedLayers == [layers[3].id])
        #expect(!r.list.isCopying)
    }

    @Test func dragWithoutOptionMovesWithoutCopying() throws {
        let r = try rig(layers: 3)
        let h = Theme.Row.list
        r.doc.mouseDown(with: event(.leftMouseDown, r, docPoint: NSPoint(x: 120, y: 2.5 * h)))
        r.doc.mouseDragged(with: event(.leftMouseDragged, r, docPoint: NSPoint(x: 120, y: 2)))
        r.doc.mouseUp(with: event(.leftMouseUp, r, docPoint: NSPoint(x: 120, y: 2)))
        #expect(r.editor.document?.layers.map(\.id) == [r.ids[1], r.ids[2], r.ids[0]])
    }
}
