import Foundation

// v79: Parallel and Layer Steps and the per-Step Mix in the Pro grade (`ColorStep.kind`, `ColorStep.mix`). A v78 build would
// read such a graph as plain serial Steps at full strength and show a different picture; at v79 it refuses the file with
// `ProjectFileError.newerVersion` instead. Graphs with only serial Steps at Mix 100 (and renamed Steps) stay v78.

extension Project {
    /// A clip or graphics layer holds a Color Graph with a Parallel or Layer Step or a Step below Mix 100: the file must be v79.
    public var containsV79Content: Bool {
        func uses(_ effects: [ClipEffect]) -> Bool {
            effects.contains { $0.isColorGraph && ($0.colorGraph?.steps.contains(where: \.usesV79Fields) ?? false) }
        }
        return allClips().contains { c in
            uses(c.effects) || (c.graphics?.layers.contains { uses($0.effects) } ?? false)
        }
    }
}
