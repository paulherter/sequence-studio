import Testing
@testable import SQEditorSession

@Suite struct WorkspaceLayoutPickTests {
    @Test func everyFormatAndScreenPicksEditingPC() {
        let pc = Workspace.editingPC.name
        #expect(WorkspaceAutoPick.name(screenWidth: 2560, screenHeight: 1440, sequenceWidth: 1080, sequenceHeight: 1920) == pc)
        #expect(WorkspaceAutoPick.name(screenWidth: 1512, screenHeight: 982, sequenceWidth: 1080, sequenceHeight: 1350) == pc)
        #expect(WorkspaceAutoPick.name(screenWidth: 1512, screenHeight: 982, sequenceWidth: 1920, sequenceHeight: 1080) == pc)
        #expect(WorkspaceAutoPick.name(screenWidth: 2560, screenHeight: 1440, sequenceWidth: 1920, sequenceHeight: 1080) == pc)
        #expect(WorkspaceAutoPick.name(screenWidth: 0, screenHeight: 0, sequenceWidth: 0, sequenceHeight: 0) == pc)
    }

    @Test func newBuiltInsAreValidAndUnique() {
        for w in [Workspace.editingPortrait, Workspace.editing27] {
            #expect(Workspace.builtIns.contains(w))
            #expect(w.isVisible(.programMonitor) && w.isVisible(.timeline))
            #expect(w.root.sanitized == w.root)
        }
        #expect(Set(Workspace.builtIns.map(\.name)).count == Workspace.builtIns.count)
    }

    @Test func portraitProgramIsFarRightAndFullHeight() {
        guard case .split(.horizontal, let kids, _) = Workspace.editingPortrait.root, let last = kids.last else { Issue.record("shape"); return }
        #expect(last.panels.contains(.programMonitor) && !last.panels.contains(.timeline))
    }

    @Test func suggestedNameIsUnique() {
        var lib = WorkspaceLibrary()
        #expect(lib.suggestedNewName(base: "My Layout") == "My Layout")
        lib.saveAs("My Layout", from: .editingPC)
        #expect(lib.suggestedNewName(base: "My Layout") == "My Layout 2")
        lib.saveAs("My Layout 2", from: .editingPC)
        #expect(lib.suggestedNewName(base: "My Layout") == "My Layout 3")
        #expect(lib.suggestedNewName(base: Workspace.editingPC.name) == "\(Workspace.editingPC.name) 2")
    }

    @Test func saveCurrentAsNewSelectsCopy() {
        var s = WorkspaceStore()
        s.selectEdit(Workspace.editingPortrait.name)
        let name = s.saveCurrentAsNew(base: "Mine")
        #expect(name == "Mine")
        #expect(s.editName == "Mine" && s.page == .edit)
        #expect(s.current.root == Workspace.editingPortrait.root)
        s.setPage(.color)
        #expect(s.saveCurrentAsNew(base: "Mine") == "Mine 2")
        #expect(s.current.root == WorkspaceStore.automaticColor(forEdit: Workspace.editingPortrait.name).root)
    }
}
