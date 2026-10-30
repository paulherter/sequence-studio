import Foundation

// Pure helpers for the drag-to-dock session. The AppKit drag in the app target only feeds them coordinates.

public extension DropZone {
    /// The region of `rect` that `zone` covers, for the drag overlay highlight (edge bands are `edgeBand` wide).
    static func highlightRect(_ zone: DropZone, in rect: (x: Double, y: Double, width: Double, height: Double)) -> (x: Double, y: Double, width: Double, height: Double) {
        let bw = rect.width * edgeBand, bh = rect.height * edgeBand
        switch zone {
        case .center: return (rect.x + bw, rect.y + bh, rect.width - 2 * bw, rect.height - 2 * bh)
        case .left: return (rect.x, rect.y, bw, rect.height)
        case .right: return (rect.x + rect.width - bw, rect.y, bw, rect.height)
        case .top: return (rect.x, rect.y, rect.width, bh)
        case .bottom: return (rect.x, rect.y + rect.height - bh, rect.width, bh)
        }
    }
}

public enum TabReorder {
    /// Final index for `moveTab` when the tab at `current` is dropped with the pointer at `x`. `midXs` are the tab
    /// centers in strip order (including the dragged tab). The tab lands before the first tab whose center lies right of `x`.
    public static func finalIndex(current: Int, x: Double, midXs: [Double]) -> Int {
        guard !midXs.isEmpty else { return 0 }
        let slot = midXs.filter { $0 < x }.count
        let final = slot > current ? slot - 1 : slot
        return min(max(final, 0), midXs.count - 1)
    }
}

public extension Workspace {
    /// The panel a drop onto a tab group should be relative to: the group's selected panel, or another one when the
    /// dragged panel is itself the selected one. Nil when the group holds only the dragged panel.
    static func dockAnchor(group: [PanelID], selected: PanelID, dragging: PanelID) -> PanelID? {
        if selected != dragging { return selected }
        return group.first { $0 != dragging }
    }
}

public extension WorkspaceStore {
    /// Renames the current user workspace (both layouts of the pair). False for built-ins, empty or taken names.
    @discardableResult
    mutating func renameCurrent(to name: String) -> Bool {
        guard library.rename(editName, to: name) else { return false }
        let old = editName
        editName = library.workspace(named: name)?.name ?? name
        if let c = colorLayouts.removeValue(forKey: old) { colorLayouts[editName] = c }
        return true
    }

    /// Deletes the current user workspace and falls back to the default Edit workspace. False for built-ins.
    @discardableResult
    mutating func deleteCurrent() -> Bool {
        guard library.delete(editName) else { return false }
        colorLayouts[editName] = nil
        editName = Workspace.editingPC.name
        return true
    }

    /// True when "Reset to Saved Layout" has something to restore: the Color page, or a built-in with edits.
    var canResetCurrent: Bool { (page == .color && colorLayouts[editName] != nil) || library.isModifiedBuiltIn(editName) }
    var canRenameOrDeleteCurrent: Bool { !library.isBuiltIn(editName) }
}
