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

extension ShellHost {
    /// Cut, Copy, Paste, Select All and Delete follow the focused panel (the AppKit `executeFocusedEdit`, one table:
    /// `CommandRouting.editRoute`). A panel that has no such command swallows the key, so it never reaches the timeline's
    /// clips; the Graphics, Keystones and Captions panels run their own action (`editActions`, set by their hosts).
    /// nil = this route does not decide (timeline, Effect Controls, Project): the generic path goes on.
    func runFocusedEdit(_ c: EditorCommand) -> Bool? {
        guard let verb = EditVerb(command: c), !currentFacts().textEditing,
              CommandRouting.focusOverride(c, focus: focus) == nil else { return nil }
        let facts = currentFacts()
        if CommandRouting.deletesMonitorLayers(command: c, panel: focus, hasLayerSelection: facts.graphicsHasSelection ?? false) {
            editActions[.deleteGraphicsLayers]?()
            return true
        }
        let route = CommandRouting.editRoute(target: FocusedEditTarget(panel: focus), verb: verb)
        switch route.action {
        case .swallow: return true
        case .deleteGraphicsLayers, .selectAllGraphicsLayers, .deleteKeystones, .deleteCaptions:
            guard menuEnabled(c) else { return true }
            editActions[route.action]?()
            return true
        case .fallThrough, .effectControls, .deleteProjectItems, .pasteMedia: return nil
        }
    }
}
