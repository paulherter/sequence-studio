import AppKit
import Testing
import SQCore
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor @Suite struct GraphicsPanelResizePerfTests {
    private func panel(layers n: Int, text: Bool = false) -> (GraphicsPanelView, NSWindow) {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        let e = GraphicsEditor(session: s)
        e.newGraphicsClip()
        for i in 0..<n { e.addShape(i % 2 == 0 ? .rectangle : .ellipse) }
        if text { e.addText() }
        let p = GraphicsPanelView(editor: e)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = p
        p.sync([.project, .selection])
        p.layoutSubtreeIfNeeded()
        return (p, w)
    }

    /// Resize cost of the Graphics panel. Before the list laid out only its visible rows, 40 layers cost 2.5x the list
    /// time of 5 layers per resize step (2.2 ms against 0.4 ms in this rig); now the list time does not depend on the
    /// layer count. The assertion is relative (robust against a busy machine); the numbers are printed.
    @Test func listResizeCostDoesNotGrowWithTheLayerCount() {
        func listMs(_ n: Int) -> Double {
            let (p, _) = panel(layers: n)
            let t = Date()
            for i in 0..<120 { p.list.frame.size.width = 300 + CGFloat(i % 30) * 8; p.list.layoutSubtreeIfNeeded() }
            return Date().timeIntervalSince(t) * 1000 / 120
        }
        _ = listMs(5)                                   // warm up
        let few = listMs(5), many = listMs(60)
        print("PERF list resize step: 5 layers \(few) ms, 60 layers \(many) ms")
        #expect(many < few * 2.5 + 0.2)
    }

    @Test func rowsOutsideTheScrollWindowAreHiddenUntilTheyScrollIn() {
        let (p, w) = panel(layers: 40)
        _ = w
        p.list.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        p.list.layoutSubtreeIfNeeded()
        let doc = p.list.subviews.compactMap { $0 as? NSScrollView }[0].documentView!
        let rowViews = doc.subviews.compactMap { $0 as? LayerListRowView }
        #expect(rowViews.count == 41 || rowViews.count == 40)
        #expect(rowViews.filter { !$0.isHidden }.count < 15)
        let scroll = doc.enclosingScrollView!
        scroll.contentView.scroll(to: NSPoint(x: 0, y: Theme.Row.list * 30))
        scroll.reflectScrolledClipView(scroll.contentView)
        p.list.layoutSubtreeIfNeeded()
        let shown = rowViews.filter { !$0.isHidden }
        #expect(shown.contains { abs($0.frame.minY - Theme.Row.list * 32) < 1 })
        #expect(shown.count < 15)
    }
}
