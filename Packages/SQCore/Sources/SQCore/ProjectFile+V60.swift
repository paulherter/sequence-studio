import Foundation

// v60: clip markers (`Clip.markers`, ClipMarkers.swift) and the effect kinds added after the v59 build went to a tester
// (2026-10-06). A v59 build would ignore the marker key and lose the markers on the next save, and would play a clip
// without an effect it does not know; at v60 it refuses the file with `ProjectFileError.newerVersion` instead. An empty
// marker list does not gate.

extension ClipEffect {
    /// Effect kinds a v59 build does not know: High Cut, Stereo Width, Chorus (audio), Edge Feather, Glitch (video).
    /// Raw strings, so the gate does not depend on where the kind constants live (`audioHighCutKind`, `audioStereoWidthKind`,
    /// `audioChorusKind`, `edgeFeatherKind`, `glitchKind`).
    static let v60Kinds: Set<String> = ["audio.highCut", "audio.stereoWidth", "audio.chorus", "edgeFeather", "glitchDisplace"]

    var needsV60: Bool { Self.v60Kinds.contains(kind) }
}

extension Project {
    /// Any clip carries a marker, or a clip / graphics layer uses an effect kind newer than v59: the file must be v60.
    public var containsV60Content: Bool {
        allClips().contains { c in
            !(c.markers ?? []).isEmpty
                || c.effects.contains(where: \.needsV60)
                || (c.graphics?.layers.contains { $0.effects.contains(where: \.needsV60) } ?? false)
        }
    }
}
