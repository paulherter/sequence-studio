import Foundation

// v88: the source patch of a sequence (`Timeline.sourcePatch`: which track the source video and audio go to, and whether
// each stream is connected), saved with the project and changed by undoable steps. A v87 build would forget the patch on
// the next save; at v88 it refuses the file with `ProjectFileError.newerVersion` instead. A sequence on the default patch
// stores no key, so such files keep the lowest version that holds their content (byte-identical). Identity step: the key
// is optional on decode.

extension Project {
    /// Any sequence (nested ones included) has a source patch that is not the default: the file must be v88.
    public var containsV88Content: Bool { timelines.contains { $0.sourcePatch != SourcePatch() } }
}
