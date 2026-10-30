import Foundation

/// Source settings > Deinterlace. Interlaced media (a `fieldOrder`) is deinterlaced right after decode by default;
/// the switch belongs to the media item, not to a clip.
extension Project {
    /// Whether `id` is interlaced media, and whether its fields are deinterlaced. nil for progressive or unprobed media.
    public func deinterlace(of id: MediaRef.ID) -> Bool? {
        guard let v = media(id)?.info?.video, v.isInterlaced else { return nil }
        return !v.deinterlaceOff
    }

    /// Turns deinterlacing of `id` on or off, for every clip of it (subclips share their file's setting). Returns whether
    /// anything changed; false for unknown, unprobed and progressive media.
    @discardableResult
    public mutating func setDeinterlace(_ on: Bool, for id: MediaRef.ID) -> Bool {
        guard let item = media(id) else { return false }
        let file = item.subclip?.parent ?? id
        var changed = false
        for i in media.indices where media[i].id == file || media[i].subclip?.parent == file {
            guard let v = media[i].info?.video, v.isInterlaced, v.deinterlaceOff == on else { continue }
            media[i].info?.video?.deinterlaceOff = !on
            changed = true
        }
        return changed
    }
}
