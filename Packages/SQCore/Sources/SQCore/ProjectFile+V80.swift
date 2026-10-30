import Foundation

// v80: explicit Steps wiring (`ColorGraph.links`) and key wires (`ColorGraph.keyLinks`). A v79 build would ignore them and show
// the graph with the wires the Step kinds say; at v80 it refuses the file with `ProjectFileError.newerVersion` instead.
// Graphs wired the way the kinds say (links == nil) and without key wires stay at their lower version.

extension Project {
    /// A clip or graphics layer holds a Color Graph with custom wiring or a key wire: the file must be v80.
    public var containsV80Content: Bool {
        func uses(_ effects: [ClipEffect]) -> Bool {
            effects.contains { $0.isColorGraph && ($0.colorGraph?.usesV80Fields ?? false) }
        }
        return allClips().contains { c in
            uses(c.effects) || (c.graphics?.layers.contains { uses($0.effects) } ?? false)
        }
    }
}
