import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// A drag out of a panel (inside the Project panel the move cue shows instead) shows the chip (icon and name) at the pointer from its first move, not only over the timeline.
@MainActor
@Suite(.serialized) struct DragPreviewTests {
    static var hosts: [ShellHost] = []

    @Test func projectDragShowsTheChipFromTheFirstMoveAndClearsOnDrop() throws {
        let (h, _, _) = ShellImportTests().host()
        Self.hosts.append(h)
        let v = ProjectListView(host: h, defaults: UserDefaults(suiteName: "sq.test.dragPreview.\(UUID())")!)
        v.frame = CGRect(x: 0, y: 0, width: 420, height: 400)
        let row = try #require(v.rows().first { if case .bin = $0.ref { false } else { true } })
        let i = try #require(v.rows().firstIndex { $0.ref == row.ref })
        let r = v.rowRect(i)
        _ = v.handle(.mouseDown(x: Float(r.midX), y: Float(r.midY), modifiers: []), scale: 1)
        #expect(HostDragPreview.shared.item == nil)
        _ = v.handle(.mouseDragged(x: Float(r.midX + 40), y: Float(500)), scale: 1)
        let item = try #require(HostDragPreview.shared.item)
        #expect(item.title == h.projectModel!.displayName(of: row.ref))
        #expect(item.point == CGPoint(x: r.midX + 40, y: 500))
        _ = v.handle(.mouseUp(x: Float(r.midX + 40), y: Float(500)), scale: 1)
        #expect(HostDragPreview.shared.item == nil)
    }

    @Test func emptyTitlesShowNothing() {
        let p = HostDragPreview()
        p.show(title: "", icon: .file, at: .zero)
        #expect(p.item == nil)
        p.show(title: "Blur", icon: .sparkles, at: CGPoint(x: 3, y: 4))
        #expect(p.item?.title == "Blur")
        p.clear()
        #expect(p.item == nil)
    }
}
