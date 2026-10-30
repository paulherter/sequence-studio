import SQEditorSession
import SQUIKit

extension ShellHost {
    /// Delete Project Items, and Edit > Delete with the Project or Library focused, remove the selected items (the AppKit
    /// `CommandRouting.editRoute` target `.project`). False = not this route.
    func runFocusedDelete(_ c: EditorCommand) -> Bool {
        guard focusedDeletesProject(c), let list = projectList else { return false }
        list.deleteSelection()
        return true
    }

    func focusedDeletesProject(_ c: EditorCommand) -> Bool {
        c == .deleteProjectItems
            || (c == .delete && CommandRouting.editRoute(target: FocusedEditTarget(panel: focus), verb: .delete).action == .deleteProjectItems)
    }
}
