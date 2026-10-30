import Foundation

/// Picks the Edit workspace for a screen and sequence (pure; the app calls it when a project opens).
public enum WorkspaceAutoPick {
    /// Every format and screen opens with "Editing – PC", the arrangement of the approved design board. The other
    /// built-ins (Portrait, MacBook, 27") stay selectable in the workspace popup but are never picked automatically.
    /// The size parameters stay so callers need no change.
    public static func name(screenWidth: Double, screenHeight: Double, sequenceWidth: Double, sequenceHeight: Double) -> String {
        Workspace.editingPC.name
    }
}
