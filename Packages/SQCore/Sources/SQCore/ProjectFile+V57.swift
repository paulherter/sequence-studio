import Foundation

// v57: bundles (`Clip.bundle`, Premiere's Clip > Group; Timeline+Bundle.swift) and subclips (`MediaRef.subclip`,
// Subclip.swift). A v56 build would drop the bundle tag (the clips come apart) and show a subclip as a second full copy of
// the file, then lose both on the next save; at v57 it refuses the file with `ProjectFileError.newerVersion` instead.

extension Project {
    /// Any clip carries a bundle or any media item is a subclip: the file must be v57.
    public var containsV57Content: Bool {
        media.contains(where: \.isSubclip) || timelines.contains(where: \.containsBundles)
    }
}
