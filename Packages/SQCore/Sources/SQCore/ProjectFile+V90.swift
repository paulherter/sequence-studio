import Foundation

// v90: the Track Mask effect (kind `trackMask`, TrackMaskEffect.swift) with `ClipEffect.maskTrack`. A v89 build would list the
// kind as an inert effect and drop the track on the next save; at v90 it refuses the file with
// `ProjectFileError.newerVersion` instead. Files without one keep the lowest version that holds their content
// (byte-identical). Identity step: `maskTrack` is optional on decode.

extension Project {
    /// Any clip holds a Track Mask effect: the file must be v90.
    public var containsV90Content: Bool {
        allClips().contains { $0.effects.contains(where: \.isTrackMask) }
    }
}
