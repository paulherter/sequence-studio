import Foundation
import Testing
@testable import SQEditorSession

@Suite struct WorkspaceStoreTests {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sq-ws-\(UUID().uuidString)/workspaces.json")
    }

    @Test func colorWorkspaceHoldsEveryPanelOnce() {
        let panels = Workspace.color.allPanels
        #expect(panels.sorted { $0.rawValue < $1.rawValue } == (PanelID.dockable + [.colorClips, .steps]).sorted { $0.rawValue < $1.rawValue })
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
        s.setPage(.color)                                          // the Color layout paired with MacBook
        var c = s.current
        let ok2 = c.setFractions(at: [], [0.7, 0.3]); #expect(ok2)
        s.updateCurrent(c)

        let url = tmp()
        try s.save(to: url)
        var loaded = WorkspaceStore.load(from: url)
        #expect(loaded == s)
        loaded.setPage(.edit)
        loaded.selectEdit(Workspace.editingPC.name)
        guard case .split(_, _, let f) = loaded.current.root else { Issue.record("not a split"); return }
        #expect(f == [0.6, 0.4])
        loaded.selectEdit(Workspace.editingMacBook.name)
        loaded.setPage(.color)
        guard case .split(_, _, let cf) = loaded.current.root else { Issue.record("not a split"); return }
        #expect(cf == [0.7, 0.3])
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

    // The maintainer's bug: after switching Editing - PC to Editing - MacBook, PC was gone from the list.
    @Test func switchingBackAndForthKeepsEveryWorkspaceListed() throws {
        var s = WorkspaceStore()
        _ = s.library.saveAs("Mine", from: Workspace.editingPC)
        let expected = Workspace.builtIns.map(\.name) + ["Mine"]
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
        #expect(lib.names.count == Workspace.builtIns.count + 3 && Set(lib.names.map { $0.lowercased() }).count == lib.names.count)
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

    @Test func olderLayoutVersionResetsBuiltInsOnceAndKeepsUserWorkspaces() throws {
        var old = WorkspaceStore()
        var w = Workspace.editingPC; w.hide(.effects)
        _ = old.library.update(w)
        _ = old.library.saveAs("Mine", from: Workspace.editingMacBook)
        var c = Workspace.color; c.hide(.scopes)
        old.layoutVersion = 0
        let url = tmp()
        try old.save(to: url)
        let loaded = WorkspaceStore.load(from: url)
        #expect(loaded.layoutVersion == WorkspaceStore.currentLayoutVersion)
        #expect(loaded.colorWorkspace == Workspace.color)
        #expect(!loaded.library.isModifiedBuiltIn(Workspace.editingPC.name))
        #expect(loaded.library.names.contains("Mine"))
        // Second load: an edit made after the reset survives.
        var again = loaded
        again.colorWorkspace = c
        try again.save(to: url)
        #expect(WorkspaceStore.load(from: url).colorWorkspace == c)
    }

    @Test func defaultLayoutsMatchTheBoards() {
        let edit = Workspace.editingPC
        #expect(edit.root.panels.prefix(3) == [.effectControls, .text, .graphics])
        guard case .split(.horizontal, _, let f) = edit.root else { Issue.record("edit root"); return }
        #expect(abs(f[1] - 340.0 / 1440) < 0.01)
        let color = Workspace.color
        #expect(color.isVisible(.scopes) && color.isVisible(.colorInspector) && !color.isVisible(.audioMeter))
        // Version 5: viewer and Scopes over the lower tab group | Color settings (340), no clip column.
        guard case .split(.horizontal, let cols, let f) = color.visibleRoot ?? color.root, cols.count == 2,
              case .split(.vertical, let rows, _) = cols[0], case .tabs(let right, _) = cols[1] else { Issue.record("color columns"); return }
        #expect(right == [.colorInspector] && abs(f[1] - 340.0 / 1440) < 0.01)
        #expect(rows[0].panels == [.programMonitor, .sourceMonitor, .scopes], "Program | Source, Scopes beside them")
        #expect(rows[1].panels.prefix(3) == [.steps, .timeline, .colorClips])
    }

    /// Version 5: the Color page docks Sources and Steps as tabs of its lower group; Edit layouts never hold them.
    @Test func colorPageIsOneLayoutAndOldStoresMigrate() throws {
        #expect(Workspace.color.isVisible(.colorClips))
        #expect(Workspace.color.allPanels.sorted { $0.rawValue < $1.rawValue } == (PanelID.dockable + [.colorClips, .steps]).sorted { $0.rawValue < $1.rawValue })
        var w = Workspace.color
        w.hide(.colorClips); w.show(.colorClips)                // the Window menu shows it again where it was
        #expect(w.isVisible(.colorClips) && w.hidden == Workspace.color.hidden)
        var e = Workspace.editingPC
        e.show(.colorClips)                                     // an Edit layout can not dock it
        #expect(e == Workspace.editingPC)
        // A store of layout version 1: shaped Color pages, the Clips panel docked, an Edit layout holding it too.
        let clips = Workspace(name: "Color", root: .split(axis: .horizontal, children: [
            .tabs(panels: [.colorClips], selected: .colorClips),
            .tabs(panels: [.colorInspector, .programMonitor, .timeline], selected: .colorInspector),
        ], fractions: [0.3, 0.7]))
        var s = WorkspaceStore()
        s.setPage(.color)
        s.colorWorkspace = clips                                 // (a version 1 store holds one Color page)
        let user = s.library.suggestedNewName(base: "Mine")
        s.library.saveAs(user, from: Workspace(name: user, root: .tabs(panels: [.timeline, .colorClips, .project], selected: .colorClips)))
        let url = tmp()
        try s.save(to: url)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["layoutVersion"] = 1
        json["colorWorkspace"] = (json["colorLayouts"] as! [String: Any]).values.first
        json.removeValue(forKey: "colorLayouts")
        json["colorPortraitWorkspace"] = json["colorWorkspace"]
        json["colorFormat"] = "portrait"
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let back = WorkspaceStore.load(from: url)
        #expect(back.page == .color && back.layoutVersion == WorkspaceStore.currentLayoutVersion)
        #expect(back.colorWorkspace == Workspace.color && back.current == Workspace.color)
        let mine = try #require(back.library.workspace(named: user))
        #expect(!mine.allPanels.contains(.colorClips) && mine.isVisible(.timeline) && mine.isVisible(.project), "a user layout stays, without the retired panel")
    }

    @Test func colorPageWithoutTheColorInspectorIsRepaired() throws {
        var s = WorkspaceStore()
        s.colorWorkspace = Workspace(name: "Color", root: .tabs(panels: [.programMonitor], selected: .programMonitor))
        let url = tmp()
        try s.save(to: url)
        #expect(WorkspaceStore.load(from: url).colorWorkspace == Workspace.color)
    }
}
