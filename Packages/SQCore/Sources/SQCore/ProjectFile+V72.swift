import Foundation

// v72: one Look library. The Looks a project carries stay in `StyleKit.looks` (id -> name + opaque payload, SQCore knows
// no text types). Payload version 1 is the caption look (style + animation) every build since W8.3 reads. Version 2
// (SQText `Look`) also holds a Look without an animation, a word highlight and a caption segmentation. A v71 build skips
// a look whose payload version it does not know, so captions that carry its ref would be drawn in the default style and
// the next save would keep a file that looks wrong; at v72 it refuses the file with `ProjectFileError.newerVersion`
// instead. Projects whose Looks are all version 1 keep the lowest version that holds their content: nothing in an old
// file has to be rewritten, the new library lists its Looks as they are.

extension StyleKit {
    /// The newest look payload a v71 build reads.
    public static let captionLookPayloadVersion = 1
}

extension Project {
    /// Any Look of the project's kit has a payload newer than the caption look: the file must be v72.
    public var containsV72Content: Bool {
        styleKit?.looks.values.contains { $0.payloadVersion > StyleKit.captionLookPayloadVersion } ?? false
    }
}
