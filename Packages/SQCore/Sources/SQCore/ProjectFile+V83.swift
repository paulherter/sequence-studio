import Foundation

// v83: `Project.notes` (free text of the project, edited in the Project Notes dialog), written only when not empty. A v82 build
// would drop the text on the next save; at v83 it refuses the file with `ProjectFileError.newerVersion` instead. Projects
// without notes stay at their lower version. Identity migration step.

extension Project {
    /// The project has notes: the file must be v83.
    public var containsV83Content: Bool { notesStore != nil }
}
