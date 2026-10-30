import Foundation

// v86: keyable Sequence Volume (`Timeline.masterVolumeKeys`, dB keys in sequence time; follow-up of v66). A v85 build would
// play such a sequence at its static level and drop the keys on the next save; at v86 it refuses the file with
// `ProjectFileError.newerVersion` instead. Sequences without keys store no key, so they keep the lowest version that holds
// their content (byte-identical). Identity step: the key is optional on decode.

extension ClipEffect {
    /// Aged Film joined v86 without a bump of its own (no version number was free to take): raw string, like the other gates.
    static let v86Kinds: Set<String> = ["agedFilm"]
    var needsV86: Bool { Self.v86Kinds.contains(kind) }
}

extension Project {
    /// Any sequence (nested ones included) has a keyed Sequence Volume or an Aged Film effect: the file must be v86.
    public var containsV86Content: Bool {
        timelines.contains { $0.isMasterVolumeKeyed }
            || allClips().contains { c in
                c.effects.contains(where: \.needsV86)
                    || (c.graphics?.layers.contains { $0.effects.contains(where: \.needsV86) } ?? false)
            }
    }
}
