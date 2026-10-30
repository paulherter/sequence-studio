import Foundation

// v82: `Timeline.channelLayout` (SequenceChannels.swift), written only when not Stereo, and the sequence pixel shape
// (`SequenceFormat.pixelAspect`, SequencePixelShape.swift), written only when not square. A v81 build would drop them on the
// next save; at v82 it refuses the file with `ProjectFileError.newerVersion` instead. Projects whose sequences keep the defaults
// stay at their lower version. Identity migration step.

extension Project {
    /// Any sequence has a non-default channel layout or a non-square pixel shape: the file must be v82.
    public var containsV82Content: Bool {
        timelines.contains { $0.channelLayoutStore != nil || $0.format.pixelAspectStore != nil }
    }
}
