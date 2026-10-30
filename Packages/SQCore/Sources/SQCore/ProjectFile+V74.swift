import Foundation

// v74: item ranges in a Graphic (`GraphicsLayer.range`, Graphics+ItemRange.swift). A v73 build does not know the key: it
// would draw every item for the whole clip and drop the ranges on save; at v74 it refuses the file with
// `ProjectFileError.newerVersion` instead. Projects without a range keep the lowest version that holds their content.

extension Project {
    /// Some item of a Graphic shows for only a part of its clip: the file must be v74.
    public var containsV74Content: Bool {
        allClips().contains { $0.graphics?.hasItemRanges ?? false }
    }
}

extension Timeline {
    /// Some item of a Graphic in this sequence has a range: templates gate their format on it too (a build without item
    /// ranges would draw every item for the whole clip).
    public var containsItemRanges: Bool {
        tracks.contains { $0.clips.contains { $0.graphics?.hasItemRanges ?? false } }
    }
}
