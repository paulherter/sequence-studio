import Foundation

// v68: Canon Log, Canon Log 2 and Canon Log 3 input color spaces (F7.2, nine `ColorSpaceID` cases). A v67 build does not
// know their raw strings: it would read a Canon project input as "none" and drop it on the next save, and fail with a raw
// decode error on a clip set to one. At v68 it refuses the file with `ProjectFileError.newerVersion` instead. Projects that
// use none of them keep the lowest version that holds their content (byte-identical).

extension ColorSpaceID {
    /// One of the color spaces that came with ProjectFile v68.
    var needsV68: Bool { InputColorProfile.logSpaces(for: .canon).contains(self) }
}

extension Project {
    /// A Canon Log space is the project input, a clip's input ("Interpret As"), or stored on a media item: the file must be v68.
    public var containsV68Content: Bool {
        inputColorSpace?.needsV68 == true
            || allClips().contains { $0.footageColor.source?.needsV68 == true }
            || media.contains { $0.info?.detectedColorSpace?.needsV68 == true }
    }
}
