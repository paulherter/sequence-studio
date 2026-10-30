import Foundation

// v65: Picture masks (C6, PictureMask.swift): `MaskSource.picture` with `ClipMask.pictureTrack` / `pictureChannel`. A v64
// build would read such a mask as its full-frame path (nothing cut, a different picture) and drop the link on the next save;
// at v65 it refuses the file with `ProjectFileError.newerVersion` instead. Files without them keep the lowest version that
// holds their content (byte-identical to before).

extension Project {
    /// Any clip mask (graphics clips included) reads another track's picture: the file must be v65.
    public var containsV65Content: Bool {
        allClips().contains { c in c.masks.contains { $0.source == .picture } }
    }
}
