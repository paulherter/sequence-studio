import Foundation

// v78: the Pro grade (Color Graph effect, kind `colorGraph`, `ClipEffect.colorGraph`). A v77 build does not know the kind
// and would drop the graph on save (and render the clip with the dimmed Simple grade); at v78 it refuses the file with
// `ProjectFileError.newerVersion` instead. Projects without a Color Graph keep the lowest version that holds their content.

extension Project {
    /// A clip or graphics layer holds a Color Graph effect (active or not): the file must be v78.
    public var containsV78Content: Bool {
        allClips().contains { c in
            c.effects.contains(where: \.isColorGraph)
                || (c.graphics?.layers.contains { $0.effects.contains(where: \.isColorGraph) } ?? false)
        }
    }
}
