import Foundation

// v64: the Trails (C4), Outline and Long Shadow (C5) effect kinds. A v63 build does not know them: it would show them inert
// and strip them on the next save. At v64 it refuses the file with `ProjectFileError.newerVersion` instead. Files without
// them keep the lowest version that holds their content (byte-identical to before).
//
// Effect presets remembering their sequence size (C7, `EffectPreset.frameSize`) live in the Library's preset store, not in
// the project file, so they need no gate here (older builds ignore the optional key).

extension ClipEffect {
    /// Raw strings (`trailsKind`, `outlineKind`, `longShadowKind`), so the gate does not depend on where the constants live.
    static let v64Kinds: Set<String> = ["trails", "alphaOutline", "longShadow"]

    var needsV64: Bool { Self.v64Kinds.contains(kind) }
}

extension Project {
    /// A clip or graphics layer uses Trails, Outline or Long Shadow: the file must be v64.
    public var containsV64Content: Bool {
        allClips().contains { c in
            c.effects.contains(where: \.needsV64)
                || (c.graphics?.layers.contains { $0.effects.contains(where: \.needsV64) } ?? false)
        }
    }
}
