import Foundation

/// Which workspaces exist, which one is showing, and their split fractions: everything the window shell persists
/// about layout. Fractions live in the workspaces themselves (`Workspace.setFractions`), so saving the store
/// saves them per workspace. The Color page is one more workspace (`Workspace.color`) behind the Edit | Color switch.
public struct WorkspaceStore: Codable, Sendable, Equatable {
    public enum Page: String, Codable, Sendable { case edit, color }

    public var library = WorkspaceLibrary()
    /// Color layouts the user changed, keyed by the Edit workspace they are paired with (a preset is a pair: the
    /// Edit layout plus the Color layout under one name). A missing key means the automatic Color layout.
    public var colorLayouts: [String: Workspace] = [:]
    /// Name of the Edit workspace in use (built-in or user).
    public var editName = Workspace.editingPC.name
    public var page = Page.edit
    /// Version of the built-in layouts the saved layouts were made for. A store older than `currentLayoutVersion` is
    /// migrated once on load (user-made workspaces stay). 1 = redesign round 2 (Main and Color boards): every built-in
    /// reset. 2 = the Color page is one fixed layout with the Clips strip in its lower panel: the Color page reset.
    /// 3 = Color layouts are paired with Edit workspaces (`colorLayouts`); the single legacy Color page is dropped.
    /// 4 = "Editing – PC" follows the v9 board proportions: its saved override is dropped once.
    /// 5 = Color panels are normal dock tabs (no Clips column; Steps | Timeline | Sources tabs, Scopes beside the viewer):
    /// saved Color layouts are dropped once.
    public var layoutVersion = WorkspaceStore.currentLayoutVersion
    public static let currentLayoutVersion = 5

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case library, colorLayouts, editName, page, layoutVersion
    }

    /// Older stores hold one Color page (`colorWorkspace`) and portrait/square variants: ignored, every preset starts
    /// with its automatic Color layout.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        library = try c.decode(WorkspaceLibrary.self, forKey: .library)
        colorLayouts = (try? c.decodeIfPresent([String: Workspace].self, forKey: .colorLayouts)) ?? [:]
        editName = try c.decodeIfPresent(String.self, forKey: .editName) ?? Workspace.editingPC.name
        page = try c.decodeIfPresent(Page.self, forKey: .page) ?? .edit
        layoutVersion = try c.decodeIfPresent(Int.self, forKey: .layoutVersion) ?? 0
    }

    /// The automatic Color layout paired with an Edit workspace: Portrait and MacBook keep the viewer far right like
    /// their Edit layouts, everything else (PC, 27", user presets) gets the landscape layout.
    public static func automaticColor(forEdit name: String) -> Workspace {
        switch name {
        case Workspace.editingPortrait.name: .colorPortrait
        case Workspace.editingMacBook.name: .colorMacBook
        default: .color
        }
    }

    /// The Color layout of the Edit workspace in use (`editName`): the user's version or the automatic one.
    public var colorPage: Workspace {
        get { colorLayouts[editName] ?? Self.automaticColor(forEdit: editName) }
        set {
            var c = newValue; c.maximized = nil; c.name = Workspace.color.name
            colorLayouts[editName] = c
        }
    }
    /// Same as `colorPage` (the name from when the Color page was one layout).
    public var colorWorkspace: Workspace {
        get { colorPage }
        set { colorPage = newValue }
    }

    /// The Color layout of the Edit workspace in use goes back to its automatic layout.
    public mutating func resetCurrentColor() { colorLayouts[editName] = nil }
    /// Every Color layout goes back to its automatic layout.
    public mutating func resetAllColor() { colorLayouts = [:] }

    /// The workspace on screen.
    public var current: Workspace {
        switch page {
        case .color: colorPage
        case .edit: library.workspace(named: editName) ?? .editingPC
        }
    }

    /// Stores changes to the on-screen workspace (fractions, hidden panels, tab selection). A maximized panel is a
    /// transient state and is not saved.
    public mutating func updateCurrent(_ w: Workspace) {
        switch page {
        case .color:
            colorPage = w
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
        return true
    }

    /// "Save as New Workspace": stores the Edit layout in use together with its Color layout as a new user preset
    /// (a pair) with a unique name derived from `base`, and switches to it. The page stays. Returns the name used.
    @discardableResult
    public mutating func saveCurrentAsNew(base: String) -> String {
        let name = library.suggestedNewName(base: base)
        let colour = colorPage
        var w = library.workspace(named: editName) ?? .editingPC
        w.name = name
        library.saveAs(name, from: w)
        editName = name
        colorPage = colour
        return name
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
        guard let raw = try? Data(contentsOf: url) else { return WorkspaceStore() }           // no file yet
        guard var s = try? JSONDecoder().decode(WorkspaceStore.self, from: WorkspaceMigration.dropUnknownPanels(raw)),
              s.library.version <= WorkspaceLibrary.currentVersion else {
            // Unreadable or written by a newer version: keep it, the next save would overwrite the user's workspaces.
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return WorkspaceStore()
        }
        s.library = s.library.healed().droppingColorClips()
        if s.layoutVersion < currentLayoutVersion {
            if s.layoutVersion < 1 { s.library.resetAllBuiltIns() }
            if s.layoutVersion < 4 { _ = s.library.resetBuiltIn(Workspace.editingPC.name) }
            if s.layoutVersion < 5 { s.colorLayouts = [:] }
            s.layoutVersion = currentLayoutVersion
        }
        // Color layouts of presets that are gone, or without the Color settings: back to the automatic layout.
        let lib = s.library
        s.colorLayouts = s.colorLayouts.filter { name, w in
            lib.workspace(named: name) != nil && w.allPanels.contains(.colorInspector)
        }.mapValues { var w = $0; w.name = Workspace.color.name; return w }
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
