import Foundation
import Testing
@testable import SQEditorSession

/// A workspace preset is a pair: the Editing layout plus the Color layout saved under one name.
@Suite struct WorkspaceColorPairTests {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sq-wsp-\(UUID().uuidString)/workspaces.json")
    }

    /// Index of the horizontal column holding `panel` in the root split (nil when the root is not a horizontal split).
    private func columnIndex(of panel: PanelID, in w: Workspace) -> (index: Int, count: Int)? {
        guard case .split(.horizontal, let kids, _) = w.visibleRoot ?? w.root else { return nil }
        guard let i = kids.firstIndex(where: { $0.panels.contains(panel) && !w.hidden.contains(panel) }) else { return nil }
        return (i, kids.count)
    }

    @Test func everyBuiltInHasAnAutomaticColorLayout() {
        for b in Workspace.builtIns {
            let c = WorkspaceStore.automaticColor(forEdit: b.name)
            #expect(c.name == Workspace.color.name)
            #expect(c.allPanels.sorted { $0.rawValue < $1.rawValue } == (PanelID.dockable + [.colorClips, .steps]).sorted { $0.rawValue < $1.rawValue })
            #expect(c.isVisible(.programMonitor) && c.isVisible(.colorInspector) && c.isVisible(.scopes) && c.isVisible(.timeline))
        }
        #expect(WorkspaceStore.automaticColor(forEdit: "Whatever").root == Workspace.color.root)
    }

    /// Portrait and MacBook put the viewer far right in Editing; the Color layout keeps it there.
    @Test func portraitAndMacBookColorKeepTheViewerFarRight() throws {
        for edit in [Workspace.editingPortrait, Workspace.editingMacBook] {
            let e = try #require(columnIndex(of: .programMonitor, in: edit))
            #expect(e.index == e.count - 1)
            let c = try #require(columnIndex(of: .programMonitor, in: WorkspaceStore.automaticColor(forEdit: edit.name)))
            #expect(c.index == c.count - 1, "\(edit.name): viewer far right in Color too")
        }
        // Landscape keeps the viewer in the left column, the Color settings full height on the right.
        let c = try #require(columnIndex(of: .programMonitor, in: Workspace.color))
        #expect(c.index == 0 && c.count == 2)
    }

    @Test func switchingTheEditWorkspaceSwitchesTheColorLayout() {
        var s = WorkspaceStore()
        s.setPage(.color)
        #expect(s.current.root == Workspace.color.root)
        s.selectEdit(Workspace.editingPortrait.name)
        #expect(s.page == .color, "the page stays")
        #expect(s.current.root == WorkspaceStore.automaticColor(forEdit: Workspace.editingPortrait.name).root)
        #expect(s.current.root != Workspace.color.root)
    }

    @Test func colorEditsBelongToTheEditWorkspaceOnly() {
        var s = WorkspaceStore()
        s.setPage(.color)
        var c = s.current; c.hide(.scopes); s.updateCurrent(c)
        #expect(!s.current.isVisible(.scopes))
        s.selectEdit(Workspace.editingMacBook.name)
        #expect(s.current.isVisible(.scopes))
        s.selectEdit(Workspace.editingPC.name)
        #expect(!s.current.isVisible(.scopes))
        s.setPage(.edit)
        #expect(s.current == Workspace.editingPC, "the Edit layout is untouched")
    }

    @Test func saveAsNewStoresBothLayoutsUnderOneName() throws {
        var s = WorkspaceStore()
        s.selectEdit(Workspace.editingPortrait.name)
        s.setPage(.color)
        var c = s.current; c.hide(.scopes); s.updateCurrent(c)
        s.setPage(.edit)
        var e = s.current; e.hide(.effects); s.updateCurrent(e)
        let name = s.saveCurrentAsNew(base: "Portrait TikTok")
        #expect(name == "Portrait TikTok" && s.editName == name)
        #expect(s.current.hidden.contains(.effects))
        s.setPage(.color)
        #expect(!s.current.isVisible(.scopes), "the color half was saved too")
        // The source preset keeps its own color layout (edited above, so scopes hidden there as well).
        s.selectEdit(Workspace.editingPortrait.name)
        #expect(!s.current.isVisible(.scopes))
        // Both halves survive a save and load.
        s.selectEdit(name)
        let url = tmp()
        try s.save(to: url)
        let back = WorkspaceStore.load(from: url)
        #expect(back == s)
        #expect(back.page == .color && !back.current.isVisible(.scopes))
    }

    @Test func saveAsNewFromTheColorPageKeepsTheEditHalfAsEditLayout() {
        var s = WorkspaceStore()
        s.selectEdit(Workspace.editingMacBook.name)
        s.setPage(.color)
        let name = s.saveCurrentAsNew(base: "Mine")
        #expect(s.library.workspace(named: name)?.root == Workspace.editingMacBook.root, "the Edit half is the Edit layout, not the Color one")
        #expect(s.page == .color, "stays on the page it was saved from")
        #expect(s.current.root == WorkspaceStore.automaticColor(forEdit: Workspace.editingMacBook.name).root)
    }

    @Test func renameAndDeleteCarryTheColorHalf() {
        var s = WorkspaceStore()
        s.selectEdit(Workspace.editingPortrait.name)
        let name = s.saveCurrentAsNew(base: "Mine")
        s.setPage(.color)
        #expect(s.canRenameOrDeleteCurrent, "also on the Color page")
        var c = s.current; c.hide(.scopes); s.updateCurrent(c)
        let ok = s.renameCurrent(to: "Yours"); #expect(ok)
        #expect(s.editName == "Yours" && !s.current.isVisible(.scopes))
        #expect(s.colorLayouts[name] == nil)
        let del = s.deleteCurrent(); #expect(del)
        #expect(s.colorLayouts["Yours"] == nil)
        #expect(s.editName == Workspace.editingPC.name)
    }

    @Test func resetOnTheColorPageRestoresTheAutomaticLayout() {
        var s = WorkspaceStore()
        s.selectEdit(Workspace.editingPortrait.name)
        s.setPage(.color)
        var c = s.current; c.hide(.scopes); s.updateCurrent(c)
        s.resetCurrentColor()
        #expect(s.current.root == WorkspaceStore.automaticColor(forEdit: Workspace.editingPortrait.name).root && s.current.isVisible(.scopes))
        var all = s
        var c2 = all.current; c2.hide(.scopes); all.updateCurrent(c2)
        all.resetAllColor()
        #expect(all.colorLayouts.isEmpty)
    }

    @Test func legacySingleColorLayoutIsDroppedForTheAutomaticPair() throws {
        var s = WorkspaceStore()
        _ = s.library.saveAs("Mine", from: Workspace.editingPC)
        let url = tmp()
        try s.save(to: url)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json.removeValue(forKey: "colorLayouts")
        json["colorWorkspace"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Workspace.color))
        json["layoutVersion"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        var back = WorkspaceStore.load(from: url)
        #expect(back.colorLayouts.isEmpty)
        back.selectEdit(Workspace.editingPortrait.name); back.setPage(.color)
        #expect(back.current.root == WorkspaceStore.automaticColor(forEdit: Workspace.editingPortrait.name).root)
    }

    @Test func orphanedOrBrokenColorLayoutsAreHealedOnLoad() throws {
        var s = WorkspaceStore()
        s.colorLayouts["Gone"] = Workspace.color
        s.colorLayouts[Workspace.editingMacBook.name] = Workspace(name: "Color", root: .tabs(panels: [.programMonitor], selected: .programMonitor))
        let url = tmp()
        try s.save(to: url)
        let back = WorkspaceStore.load(from: url)
        #expect(back.colorLayouts.isEmpty)
    }

    // MARK: Color page layout (version 5)

    @Test func colorLowerGroupHoldsStepsTimelineSourcesAsTabs() throws {
        for edit in Workspace.builtIns {
            let c = WorkspaceStore.automaticColor(forEdit: edit.name)
            let group = try #require(Workspace.tabGroups(in: c.root).first { $0.panels.contains(.timeline) })
            #expect(group.panels == [.steps, .timeline, .colorClips])
            #expect(group.selected == .timeline)
            let scopes = try #require(Workspace.tabGroups(in: c.root).first { $0.panels.contains(.scopes) })
            #expect(scopes.panels == [.scopes], "Scopes is its own docked tab, beside the viewer")
        }
    }

    @Test func simpleHidingStepsKeepsTimelineSelectedAndScopesVisible() throws {
        var w = Workspace.color
        w.hide(.steps)
        #expect(w.isVisible(.scopes) && w.isVisible(.timeline) && w.isVisible(.colorClips) && !w.isVisible(.steps))
        let vis = try #require(w.visibleRoot)
        let group = try #require(Workspace.tabGroups(in: vis).first { $0.panels.contains(.timeline) })
        #expect(group.panels == [.timeline, .colorClips] && group.selected == .timeline)
        w.show(.steps)
        let vis2 = try #require(w.visibleRoot)
        let again = try #require(Workspace.tabGroups(in: vis2).first { $0.panels.contains(.timeline) })
        #expect(again.panels == [.steps, .timeline, .colorClips] && again.selected == .steps, "showing a tab selects it")
    }

    @Test func tabSwitchKeepsTheGroupAndTheOtherSelections() throws {
        var w = Workspace.color
        w.show(.colorClips)
        w.show(.scopes)
        let groups = Workspace.tabGroups(in: w.root)
        #expect(groups.first { $0.panels.contains(.timeline) }?.selected == .colorClips)
        #expect(groups.first { $0.panels.contains(.colorInspector) }?.selected == .colorInspector)
        #expect(groups.first { $0.panels.contains(.programMonitor) }?.selected == .programMonitor)
        #expect(w.root.panels.sorted { $0.rawValue < $1.rawValue } == Workspace.color.root.panels.sorted { $0.rawValue < $1.rawValue })
    }

    @Test func version4StoreDropsItsColorLayoutsOnLoad() throws {
        var s = WorkspaceStore()
        var old = Workspace.color
        old.root = .tabs(panels: [.colorClips, .programMonitor], selected: .colorClips)
        s.colorLayouts[Workspace.editingPC.name] = old
        let url = tmp()
        try s.save(to: url)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["layoutVersion"] = 4
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        var back = WorkspaceStore.load(from: url)
        #expect(back.layoutVersion == WorkspaceStore.currentLayoutVersion && WorkspaceStore.currentLayoutVersion == 5)
        #expect(back.colorLayouts.isEmpty)
        back.setPage(.color)
        #expect(back.current.root == Workspace.color.root)
    }
}
