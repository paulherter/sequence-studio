import Foundation
import Testing
@testable import SQEditorSession

/// The Workspace dropdown / Window menu flows end to end on the model: Save as New Workspace, switching, closing a
/// panel, Reset to Saved Layout.
@Suite struct WorkspaceMenuFlowTests {
    @Test func saveAsNewWorkspaceListsAndSelectsIt() {
        var s = WorkspaceStore()
        var w = s.current
        w.hide(.effects)
        s.updateCurrent(w)
        var named = s.current
        named.name = "Vertical"
        let saved = s.library.saveAs("Vertical", from: named)
        let selected = s.selectEdit("Vertical")
        #expect(saved && selected)
        #expect(s.library.names.contains("Vertical"))
        #expect(s.editName == "Vertical")
        #expect(!s.current.isVisible(.effects))
        // The built-in this was derived from keeps its own (modified) state and stays listed.
        #expect(s.library.names.contains(Workspace.editingPC.name))
        // Saving under the same name again replaces it instead of adding a second entry; built-in names are refused.
        let count = s.library.names.count
        let again = s.library.saveAs("vertical", from: named)
        #expect(again && s.library.names.count == count)
        let builtIn = s.library.saveAs(Workspace.editingPC.name, from: named)
        #expect(!builtIn)
    }

    @Test func closingAPanelAndResettingRestoresTheSavedLayout() {
        var s = WorkspaceStore()
        #expect(s.current.isVisible(.effects))
        var w = s.current
        w.hide(.effects)                      // Close Panel in the tab context menu / Window menu
        s.updateCurrent(w)
        #expect(!s.current.isVisible(.effects))
        #expect(s.canResetCurrent)
        let reset = s.library.resetBuiltIn(s.editName)
        #expect(reset)
        #expect(s.current.isVisible(.effects))
        #expect(!s.canResetCurrent)
    }

    @Test func windowMenuTogglesEveryListedPanel() {
        var w = Workspace.editingPC
        for p in EditorMenus.windowPanels where p != .colorClips && p != .steps {     // Sources and Steps are Color-page tabs, not Edit dock panels
            let was = w.isVisible(p)
            w.toggle(p)
            #expect(w.isVisible(p) != was, "\(p)")
        }
    }
}
