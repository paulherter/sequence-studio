import Foundation

/// Which workspaces exist, which one is showing, and their split fractions: everything the window shell persists
/// about layout. Fractions live in the workspaces themselves (`Workspace.setFractions`), so saving the store
/// saves them per workspace. The Color page is one more workspace (`Workspace.color`) behind the Edit | Color switch.
public struct WorkspaceStore: Codable, Sendable, Equatable {
    public enum Page: String, Codable, Sendable { case edit, color }

    public var library = WorkspaceLibrary()
    public var colorWorkspace = Workspace.color
    /// Name of the Edit workspace in use (built-in or user).
    public var editName = Workspace.editingPC.name
    public var page = Page.edit

    public init() {}

    /// The workspace on screen.
    public var current: Workspace {
        switch page {
        case .color: colorWorkspace
        case .edit: library.workspace(named: editName) ?? .editingPC
        }
    }

    /// Stores changes to the on-screen workspace (fractions, hidden panels, tab selection). A maximized panel is a
    /// transient state and is not saved.
    public mutating func updateCurrent(_ w: Workspace) {
        switch page {
        case .color:
            var c = w; c.maximized = nil; c.name = Workspace.color.name
            colorWorkspace = c
        case .edit:
            var w = w; w.name = editName
            _ = library.update(w)
        }
    }

    /// Switches to an Edit workspace by name. False when no such workspace exists.
    @discardableResult
    public mutating func selectEdit(_ name: String) -> Bool {
        guard let w = library.workspace(named: name) else { return false }
        editName = w.name
        page = .edit
        return true
    }

    public mutating func setPage(_ p: Page) { page = p }

    // MARK: Persistence

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Sequence Studio/workspaces.json")
    }

    /// Missing or unreadable files give the defaults; a stored edit name that no longer exists falls back to the first built-in.
    public static func load(from url: URL = WorkspaceStore.defaultURL) -> WorkspaceStore {
        guard let data = try? Data(contentsOf: url), var s = try? JSONDecoder().decode(WorkspaceStore.self, from: data) else {
            return WorkspaceStore()
        }
        if s.library.workspace(named: s.editName) == nil { s.editName = Workspace.editingPC.name }
        return s
    }

    public func save(to url: URL = WorkspaceStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }
}
