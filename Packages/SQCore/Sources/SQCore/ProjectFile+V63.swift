import Foundation

// v63: `GraphicsLayer.follow` (G11 Follow, Graphics+Follow.swift): a layer pinned to another layer or the frame. A v62 build
// would drop the field on decode and draw the follower where it was authored (a different picture), then lose it on the
// next save; at v63 it refuses the file with `ProjectFileError.newerVersion` instead.

extension Project {
    /// Any graphics layer follows another layer or the frame: the file must be v63.
    public var containsV63Content: Bool {
        timelines.contains(where: \.containsFollow)
    }
}

extension Timeline {
    /// Any graphics layer of this sequence's clips follows something (G11): templates gate their format on it too.
    public var containsFollow: Bool {
        tracks.contains { $0.clips.contains { $0.graphics?.layers.contains { $0.follow != nil } ?? false } }
    }
}
