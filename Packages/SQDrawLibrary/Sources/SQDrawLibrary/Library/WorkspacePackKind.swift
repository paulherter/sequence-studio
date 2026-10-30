import Foundation
import SQLibrary
import SQInspectorUI
import SQEditorSession

/// Workspace layouts as a `.sqpack` entry kind. Not a PresetStore kind: workspaces live in the workspace store, so the
/// Library hands imported entries to the host (`LibraryPanelModel.onImportWorkspaces`).
public enum WorkspacePackKind {
    public static let kind = "workspace"
    public static let payloadVersion = 1

    public static func entry(for workspace: Workspace) throws -> SQPackEntry {
        var w = workspace
        w.maximized = nil
        return SQPackEntry(kind: kind, name: w.name, payloadVersion: payloadVersion, payload: try JSONEncoder().encode(w))
    }

    /// The validated workspace of an entry; nil when the layout is unreadable or inconsistent.
    public static func workspace(from entry: SQPackEntry) -> Workspace? {
        guard entry.kind == kind, entry.payloadVersion <= payloadVersion,
              let w = try? JSONDecoder().decode(Workspace.self, from: entry.payload), w.validationProblems.isEmpty else { return nil }
        return w
    }

    public static func register(in registry: inout SQPackKindRegistry) {
        registry.register(kind) { payload, version in
            if version > payloadVersion { throw LibraryStoreError.newerFormat(found: version, supported: payloadVersion) }
            guard let w = try? JSONDecoder().decode(Workspace.self, from: payload), w.validationProblems.isEmpty else {
                throw SQPackError.malformed("workspace")
            }
        }
    }
}
