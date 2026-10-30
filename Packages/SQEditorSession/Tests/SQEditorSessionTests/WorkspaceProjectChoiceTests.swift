import Foundation
import Testing
@testable import SQEditorSession

/// Every project opens in "Editing – PC" unless the user picked another workspace for that project himself.
@Suite struct WorkspaceProjectChoiceTests {
    private let all = Workspace.builtIns.map(\.name)

    @Test func projectWithoutChoiceOpensInEditingPC() {
        let c = WorkspaceChoices()
        #expect(c.name(project: "/a/One.sqproj", available: all) == Workspace.editingPC.name)
        #expect(c.name(project: nil, available: all) == Workspace.editingPC.name)
    }

    @Test func choiceIsRememberedPerProject() {
        var c = WorkspaceChoices()
        c.choose(Workspace.editingMacBook.name, project: "/a/One.sqproj")
        #expect(c.name(project: "/a/One.sqproj", available: all) == Workspace.editingMacBook.name)
        #expect(c.name(project: "/a/Two.sqproj", available: all) == Workspace.editingPC.name)
        #expect(c.name(project: nil, available: all) == Workspace.editingPC.name)
    }

    @Test func untitledProjectKeepsItsChoiceUntilTheNextNewProject() {
        var c = WorkspaceChoices()
        c.choose(Workspace.editingPortrait.name, project: nil)
        #expect(c.name(project: nil, available: all) == Workspace.editingPortrait.name)
        c.forgetUntitled()
        #expect(c.name(project: nil, available: all) == Workspace.editingPC.name)
    }

    @Test func deletedWorkspaceFallsBackToEditingPC() {
        var c = WorkspaceChoices()
        c.choose("Mine", project: "/a/One.sqproj")
        #expect(c.name(project: "/a/One.sqproj", available: all) == Workspace.editingPC.name)
        #expect(c.name(project: "/a/One.sqproj", available: all + ["Mine"]) == "Mine")
    }

    @Test func choosingEditingPCAgainClearsTheEntry() {
        var c = WorkspaceChoices()
        c.choose(Workspace.editingMacBook.name, project: "/a/One.sqproj")
        c.choose(Workspace.editingPC.name, project: "/a/One.sqproj")
        #expect(c.byProject.isEmpty)
    }

    @Test func storedDictionaryRoundTrips() {
        var c = WorkspaceChoices()
        c.choose(Workspace.editing27.name, project: "/a/One.sqproj")
        #expect(WorkspaceChoices(stored: c.byProject) == c)
        #expect(WorkspaceChoices(stored: nil) == WorkspaceChoices())
    }

    /// The store keeps one global name (the last workspace on screen); a stale "Editing – MacBook" from an earlier
    /// session must not survive a project open.
    @Test func staleGlobalNameIsReplacedOnOpen() {
        var s = WorkspaceStore()
        s.selectEdit(Workspace.editingMacBook.name)
        let name = WorkspaceChoices().name(project: "/a/One.sqproj", available: s.library.all.map(\.name))
        s.selectEdit(name)
        #expect(s.editName == Workspace.editingPC.name)
    }

    /// v9 board: left column (Controls 1.3fr | monitor 1fr over the timeline, rows 1fr / .92fr), right column 339 of
    /// 1422 px with Library 1.15fr over Project 1fr.
    @Test func editingPCFollowsTheBoardProportions() {
        guard case .split(.horizontal, let cols, let cf) = Workspace.editingPC.root,
              case .split(.vertical, let left, let lf) = cols[0], case .split(.horizontal, _, let uf) = left[0],
              case .split(.vertical, _, let rf) = cols[1] else { Issue.record("shape"); return }
        #expect(abs(cf[1] * 1422 - 339) < 1.5)
        #expect(abs(uf[0] / uf[1] - 1.3) < 0.01)
        #expect(abs(lf[0] / lf[1] - 1 / 0.92) < 0.01)
        #expect(abs(rf[0] / rf[1] - 1.15) < 0.01)
    }

    @Test func storeOlderThanTheBoardLayoutGetsTheNewProportions() throws {
        var old = WorkspaceStore()
        var w = Workspace.editingPC; w.hide(.effects)
        _ = old.library.update(w)
        _ = old.library.saveAs("Mine", from: Workspace.editingMacBook)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sq-ws-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try old.save(to: url)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        json["layoutVersion"] = 3
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = WorkspaceStore.load(from: url)
        #expect(loaded.layoutVersion == WorkspaceStore.currentLayoutVersion)
        #expect(loaded.library.workspace(named: Workspace.editingPC.name) == Workspace.editingPC)
        #expect(loaded.library.names.contains("Mine"))
    }
}
