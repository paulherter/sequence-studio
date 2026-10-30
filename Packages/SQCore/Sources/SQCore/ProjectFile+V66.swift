import Foundation

// v66: Sequence Volume (`Timeline.masterVolumeDB`, parity audit item 13). A v65 build would play and export such a sequence
// at 0 dB and drop the level on the next save; at v66 it refuses the file with `ProjectFileError.newerVersion` instead.
// Sequences at 0 dB store no key, so files without a level keep the lowest version that holds their content (byte-identical).

extension Project {
    /// Any sequence (nested ones included) has a Sequence Volume other than 0 dB: the file must be v66.
    public var containsV66Content: Bool { timelines.contains { $0.masterLevel != nil } }
}
