import Foundation

// v81: `Timeline.timecodeStart`, `.timecodeDisplay` and `.previewQuality` (SequenceTimecode.swift), each written only when not
// the default. A v80 build would drop them on the next save; at v81 it refuses the file with `ProjectFileError.newerVersion`
// instead. Projects whose sequences keep the defaults stay at their lower version. Identity migration step.

extension Project {
    /// Any sequence has a timecode start, the frame-count display or its own preview quality: the file must be v81.
    public var containsV81Content: Bool {
        timelines.contains { $0.timecodeStartStore != nil || $0.timecodeDisplayStore != nil || $0.previewQualityStore != nil }
    }
}
