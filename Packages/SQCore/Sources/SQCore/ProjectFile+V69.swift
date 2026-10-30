import Foundation

// v69: pixel aspect ratio (PixelAspect.swift): `VideoTrackInfo.pixelAspect` (the file's tag, written only when not square)
// and `VideoTrackInfo.pixelAspectOverride` (the ratio chosen for the media item, written only when set). A v68 build would
// show such media squeezed, fit it by its stored size and drop both keys on the next save; at v69 it refuses the file with
// `ProjectFileError.newerVersion` instead. Projects with square media store neither key and keep the lowest version that
// holds their content. Files before v69 have neither key: every item opens square.

extension Project {
    /// Any media item is shown with non-square pixels or carries a chosen pixel aspect: the file must be v69.
    public var containsV69Content: Bool {
        media.contains { m in
            guard let v = m.info?.video else { return false }
            return !v.pixelAspect.isSquare || v.pixelAspectOverride != nil
        }
    }
}
