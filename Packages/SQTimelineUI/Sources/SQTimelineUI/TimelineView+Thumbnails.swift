import AppKit
import SQCore

extension TimelineView {
    /// The tiles of the thumbnail modes Head and Tail and Continuous for `c`, each with its frame (nil image = empty well).
    /// nil in Head mode or without a frame hook: the clip then draws its head column from the poster as before.
    func thumbnailPictures(for c: Clip, clipWidth: CGFloat, x0: CGFloat, rowHeight: CGFloat, visible: CGRect) -> [ClipThumbnailPicture]? {
        guard thumbnailMode != .head, let frame = thumbnailFrame else { return nil }
        let column = ClipDrawing.thumbnailColumn(clipWidth: clipWidth, rowHeight: rowHeight, width: ClipDrawing.thumbnailWidth)
        guard column > 0 else { return nil }
        let local = (visible.minX - x0 - 8)...(visible.maxX - x0 + 8)
        let fd = geometry.frameDuration
        return ThumbnailLayout.tiles(mode: thumbnailMode, clipWidth: clipWidth, column: column, visible: local).map { tile in
            ClipThumbnailPicture(tile: tile, image: frame(c.media, ThumbnailLayout.mediaTime(of: tile.anchor, clip: c, frameDuration: fd)))
        }
    }
}
