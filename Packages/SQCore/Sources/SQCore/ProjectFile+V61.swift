import Foundation

// v61: the Halftone, Tile and Kaleidoscope effect kinds. They landed after the v59 gate and were missing from the v60 kind
// list, so a v60 build would have opened them inert and stripped them on the next save. At v61 it refuses the file with
// `ProjectFileError.newerVersion` instead.

extension ClipEffect {
    /// Raw strings (`halftoneKind`, `tileKind`, `kaleidoscopeKind`), so the gate does not depend on where the constants live.
    static let v61Kinds: Set<String> = ["halftone", "tile", "kaleidoscope"]

    var needsV61: Bool { Self.v61Kinds.contains(kind) }
}

extension Project {
    /// A clip or graphics layer uses Halftone, Tile or Kaleidoscope: the file must be v61.
    public var containsV61Content: Bool {
        allClips().contains { c in
            c.effects.contains(where: \.needsV61)
                || (c.graphics?.layers.contains { $0.effects.contains(where: \.needsV61) } ?? false)
        }
    }
}
