import Foundation
import Testing
@testable import SQEditorUI

@Suite struct WorkspaceStoreTests {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sq-ws-\(UUID().uuidString)/workspaces.json")
    }

    @Test func colorWorkspaceHoldsEveryPanelOnce() {
        let panels = Workspace.color.allPanels
        #expect(panels.sorted { $0.rawValue < $1.rawValue } == PanelID.allCases.sorted { $0.rawValue < $1.rawValue })
        #expect(Workspace.color.isVisible(.programMonitor) && Workspace.color.isVisible(.timeline))
        #expect(!Workspace.builtIns.contains { $0.name == Workspace.color.name })
    }

    @Test func defaultsShowEditingPC() {
        let s = WorkspaceStore()
        #expect(s.current == Workspace.editingPC)
    }

    @Test func fractionsArePersistedPerWorkspace() throws {
        var s = WorkspaceStore()
        var w = s.current
        let ok1 = w.setFractions(at: [], [0.6, 0.4]); #expect(ok1)
        s.updateCurrent(w)
        s.selectEdit(Workspace.editingMacBook.name)
        #expect(s.current == Workspace.editingMacBook)             // other workspace untouched
        s.setPage(.color)
        var c = s.current
        let ok2 = c.setFractions(at: [], [0.5, 0.5]); #expect(ok2)
        s.updateCurrent(c)

        let url = tmp()
        try s.save(to: url)
        var loaded = WorkspaceStore.load(from: url)
        #expect(loaded == s)
        loaded.setPage(.edit)
        loaded.selectEdit(Workspace.editingPC.name)
        guard case .split(_, _, let f) = loaded.current.root else { Issue.record("not a split"); return }
        #expect(f == [0.6, 0.4])
        loaded.setPage(.color)
        guard case .split(_, _, let cf) = loaded.current.root else { Issue.record("not a split"); return }
        #expect(cf == [0.5, 0.5])
    }

    @Test func hidePanelIsStoredAndMaximizeIsNot() {
        var s = WorkspaceStore()
        var w = s.current
        w.hide(.library)
        w.toggleMaximize(.timeline)
        s.updateCurrent(w)
        #expect(s.current.hidden.contains(.library))
        #expect(s.current.maximized == nil)
    }

    @Test func unknownWorkspaceNameIsRefused() {
        var s = WorkspaceStore()
        let ok = s.selectEdit("Nope"); #expect(!ok)
        #expect(s.page == .edit)
    }

    @Test func garbageFileGivesDefaults() throws {
        let url = tmp()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(WorkspaceStore.load(from: url) == WorkspaceStore())
        #expect(WorkspaceStore.load(from: tmp()) == WorkspaceStore())
        // Review finding 32: the unreadable file is kept next to it, so the next save does not destroy it.
        let backup = url.appendingPathExtension("corrupt")
        #expect(try Data(contentsOf: backup) == Data("not json".utf8))
    }

    // Paul's bug: after switching Editing - PC to Editing - MacBook, PC was gone from the list.
    @Test func switchingBackAndForthKeepsEveryWorkspaceListed() throws {
        var s = WorkspaceStore()
        _ = s.library.saveAs("Mine", from: Workspace.editingPC)
        let expected = [Workspace.editingPC.name, Workspace.editingMacBook.name, "Mine"]
        #expect(s.library.names == expected)
        for name in [Workspace.editingMacBook.name, Workspace.editingPC.name, "Mine", Workspace.editingMacBook.name] {
            let ok = s.selectEdit(name); #expect(ok)
            var w = s.current
            w.hide(.effects)                       // an edit while the workspace is showing (stored as override)
            s.updateCurrent(w)
            #expect(s.library.names == expected)
            #expect(s.editName == name)
        }
        let url = tmp()
        try s.save(to: url)
        #expect(WorkspaceStore.load(from: url).library.names == expected)
    }

    @Test func persistedStateMissingBuiltInsStillListsThem() throws {
        let url = tmp()
        var s = WorkspaceStore()
        s.editName = "Gone"
        try s.save(to: url)
        let loaded = WorkspaceStore.load(from: url)
        #expect(loaded.library.names.starts(with: [Workspace.editingPC.name, Workspace.editingMacBook.name]))
        #expect(loaded.current.name == Workspace.editingPC.name)
    }

    @Test func userWorkspaceShadowedByABuiltInNameIsKeptUnderANewName() {
        let lib = WorkspaceLibrary(userWorkspaces: [
            Workspace(name: Workspace.editingPC.name.uppercased(), root: Workspace.editingPC.root),
            Workspace(name: "Mine", root: Workspace.editingPC.root), Workspace(name: "mine", root: Workspace.editingPC.root),
        ]).healed()
        #expect(lib.names.count == 5 && Set(lib.names.map { $0.lowercased() }).count == 5)
    }

    @Test func resetAllBuiltInsDropsOverridesOnly() {
        var lib = WorkspaceLibrary()
        var w = Workspace.editingPC; w.hide(.effects)
        _ = lib.update(w)
        _ = lib.saveAs("Mine", from: Workspace.editingMacBook)
        lib.resetAllBuiltIns()
        #expect(!lib.isModifiedBuiltIn(Workspace.editingPC.name))
        #expect(lib.names.contains("Mine"))
    }
}
