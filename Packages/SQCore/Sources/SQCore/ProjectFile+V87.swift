import Foundation

// v87: Color range masks (`MaskSource.colorRange`, `ClipMask.colorRange`, ColorRangeKey.swift). A v86 build would read such
// a mask as its full-frame path (nothing cut) and drop the key on the next save; at v87 it refuses the file with
// `ProjectFileError.newerVersion` instead. Files without one keep the lowest version that holds their content
// (byte-identical to before). Identity step: the key is optional on decode.

extension Project {
    /// Any clip mask (graphics and nested sequences included) keys the picture by color: the file must be v87.
    public var containsV87Content: Bool {
        allClips().contains { c in c.masks.contains { $0.source == .colorRange } }
    }
}
