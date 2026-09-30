import Testing
@testable import SSEditorUI

@Suite struct DockDragHelperTests {
    let rect = (x: 10.0, y: 20.0, width: 400.0, height: 200.0)

    @Test func highlightRects() {
        let c = DropZone.highlightRect(.center, in: rect)
        #expect(c.x == 110 && c.y == 70 && c.width == 200 && c.height == 100)
        let l = DropZone.highlightRect(.left, in: rect)
        #expect(l.x == 10 && l.width == 100 && l.height == 200)
        let b = DropZone.highlightRect(.bottom, in: rect)
        #expect(b.y == 170 && b.height == 50 && b.width == 400)
    }

    @Test func highlightContainsZonePoint() {
        for z in DropZone.allCases {
            let h = DropZone.highlightRect(z, in: rect)
            let p = (x: h.x + h.width / 2, y: h.y + h.height / 2)
            #expect(DropZone.zone(for: p, in: rect) == z)
        }
    }

    @Test func reorderIndex() {
        let mids = [20.0, 60.0, 100.0]
        #expect(TabReorder.finalIndex(current: 0, x: 105, midXs: mids) == 2)
        #expect(TabReorder.finalIndex(current: 2, x: 5, midXs: mids) == 0)
        #expect(TabReorder.finalIndex(current: 1, x: 65, midXs: mids) == 1)
        #expect(TabReorder.finalIndex(current: 1, x: 500, midXs: mids) == 2)
        #expect(TabReorder.finalIndex(current: 0, x: 5, midXs: []) == 0)
    }

    @Test func anchor() {
        #expect(Workspace.dockAnchor(group: [.timeline, .project], selected: .timeline, dragging: .timeline) == .project)
        #expect(Workspace.dockAnchor(group: [.timeline, .project], selected: .project, dragging: .timeline) == .project)
        #expect(Workspace.dockAnchor(group: [.timeline], selected: .timeline, dragging: .timeline) == nil)
    }

    @Test func storeRenameDelete() {
        var s = WorkspaceStore()
        #expect(!s.canRenameOrDeleteCurrent)
        let r0 = s.renameCurrent(to: "X"), d0 = s.deleteCurrent()
        #expect(!r0 && !d0)
        _ = s.library.saveAs("Mine", from: s.current)
        s.selectEdit("Mine")
        #expect(s.canRenameOrDeleteCurrent)
        let r1 = s.renameCurrent(to: "Yours")
        #expect(r1)
        #expect(s.editName == "Yours" && s.current.name == "Yours")
        let d1 = s.deleteCurrent()
        #expect(d1)
        #expect(s.editName == Workspace.editingPC.name)
        #expect(!s.canResetCurrent)
    }
}
