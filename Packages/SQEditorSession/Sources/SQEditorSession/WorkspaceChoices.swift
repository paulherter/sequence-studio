import Foundation

/// The Edit workspace each project opens in. A project opens in "Editing – PC" (the arrangement of the design board)
/// unless the user picked another workspace while that project was open; the pick is remembered per project file.
/// Pure: the app stores `byProject` in its defaults (`WorkspaceChoices.defaultsKey`) and asks on every project open.
public struct WorkspaceChoices: Equatable, Sendable {
    /// Project file path -> workspace name. A project without an entry opens in "Editing – PC".
    public private(set) var byProject: [String: String] = [:]
    /// The pick made in a project that has no file yet.
    public private(set) var untitled: String?

    public static let defaultsKey = "sq.workspace.projectChoices"

    public init() {}
    /// From the stored dictionary (nil or another type: no picks).
    public init(stored: Any?) { byProject = stored as? [String: String] ?? [:] }

    /// The user picked `name` himself while `project` (file path, nil = not saved yet) was open.
    public mutating func choose(_ name: String, project: String?) {
        let pick: String? = name == Workspace.editingPC.name ? nil : name
        if let project { byProject[project] = pick } else { untitled = pick }
    }

    /// A new, unsaved project starts without a pick.
    public mutating func forgetUntitled() { untitled = nil }

    /// The workspace `project` opens in: its remembered pick while that workspace still exists, else "Editing – PC".
    public func name(project: String?, available: [String]) -> String {
        let pick = project.map { byProject[$0] } ?? untitled
        if let pick, available.contains(pick) { return pick }
        return Workspace.editingPC.name
    }
}
