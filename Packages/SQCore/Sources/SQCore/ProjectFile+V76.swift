import Foundation

// v76: the Graphic EQ audio effect kind and the Hold of the Noise Gate clip effect. A v75 build does not know the Graphic EQ
// (it would play the clip without it) and ignores the stored `hold` of a Noise Gate (the gate would close too early); at v76
// it refuses the file with `ProjectFileError.newerVersion` instead. A missing `hold` reads as its default 0 (the earlier
// behavior), so every older file sounds the same. Projects without either keep the lowest version that holds their content.

extension ClipEffect {
    /// Effect kinds a v75 build does not know. Raw strings, so the gate does not depend on where the kind constants live.
    static let v76Kinds: Set<String> = ["audio.graphicEQ"]

    /// Graphic EQ, or a Noise Gate that stores a Hold other than 0 (0 is the old behavior and needs no gate).
    var needsV76: Bool {
        if Self.v76Kinds.contains(kind) { return true }
        guard kind == Self.audioNoiseGateKind, let p = parameters[Self.gateHoldKey] else { return false }
        return p.isAnimated || p.value != 0
    }
}

extension Project {
    /// A clip or graphics layer uses Graphic EQ or a Noise Gate hold (enabled or not): the file must be v76.
    public var containsV76Content: Bool {
        allClips().contains { c in
            c.effects.contains(where: \.needsV76)
                || (c.graphics?.layers.contains { $0.effects.contains(where: \.needsV76) } ?? false)
        }
    }
}
