import Foundation
import SQCore
import SQDrawKit
import SQMedia
import SQTimelineUI
import SQUIKit

/// A picture the host has uploaded: image slot `slot`, the cell `source` of it (normalized, an atlas cell) and the
/// picture's pixel size (for the crop that fills a thumbnail tile, like the Mac `fillPicture`).
public struct TimelinePicture: Sendable, Equatable {
    public var slot: Int
    public var source: (u0: Float, v0: Float, u1: Float, v1: Float)
    public var pixelSize: CGSize
    public init(slot: Int, source: (u0: Float, v0: Float, u1: Float, v1: Float) = (0, 0, 1, 1), pixelSize: CGSize) {
        self.slot = slot; self.source = source; self.pixelSize = pixelSize
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.slot == b.slot && a.pixelSize == b.pixelSize
            && a.source.u0 == b.source.u0 && a.source.v0 == b.source.v0 && a.source.u1 == b.source.u1 && a.source.v1 == b.source.v1
    }

    /// The part of `source` that fills `r` cropped to its aspect (centered), as the Mac draws a picture into a tile.
    func cropped(toFill r: CGRect) -> (Float, Float, Float, Float) {
        guard pixelSize.width > 0, pixelSize.height > 0, r.width > 0, r.height > 0 else { return source }
        let k = max(r.width / pixelSize.width, r.height / pixelSize.height)
        let fx = Float(min(r.width / (pixelSize.width * k), 1)), fy = Float(min(r.height / (pixelSize.height * k), 1))
        let w = source.u1 - source.u0, h = source.v1 - source.v0
        let cu = source.u0 + w / 2, cv = source.v0 + h / 2
        return (cu - w * fx / 2, cv - h * fy / 2, cu + w * fx / 2, cv + h * fy / 2)
    }
}

/// What the host knows about the media behind the clips (the Mac view's `waveforms`, `thumbnails` / `thumbnailFrame` and
/// `offlineMedia`). Every answer may be nil while it loads; the host redraws when it arrives.
public protocol TimelineMediaSource: AnyObject {
    /// Peaks of `media` (nil while loading, or media without audio).
    func waveform(media: UUID) -> WaveformData?
    /// The zoom-bucket cache the waveform columns read through (`TimelineWaveforms.cache`); nil = straight from the data.
    var waveformCache: WaveformCache? { get }
    /// A frame of `media` at media time `at` (nil = the poster) for the thumbnail tiles.
    func picture(media: UUID, at: Time?) -> TimelinePicture?
    /// The media file is missing (the clip draws as "Media offline").
    func isOffline(media: UUID) -> Bool
    /// A stamp that changes whenever any answer above may change (a waveform or picture arrived, the paths changed). The panel
    /// replays its clip layer while the stamp holds; nil = cannot say, the layer is drawn fresh every frame.
    var drawRevision: Int? { get }
}

extension TimelineMediaSource {
    public var waveformCache: WaveformCache? { nil }
    public func picture(media: UUID, at: Time?) -> TimelinePicture? { nil }
    public func isOffline(media: UUID) -> Bool { false }
    public var drawRevision: Int? { nil }
}

/// Media drawing, translated from `ClipDrawing.draw` (thumbnail tiles), `WaveformTileCache.draw` / `drawClipping`,
/// `ClipDrawing.drawVolumeLine`, `drawOpacityLine`, `drawFXBadge` and `drawSyncBadge`.
extension TimelinePanel {
    // MARK: Thumbnails

    /// The thumbnail tiles of a video clip and the room they take from the name: (head column, tail column).
    func drawThumbnails(_ cv: inout Canvas, _ c: Clip, rect: CGRect, body: CGRect, drawn: CGRect, radius: CGFloat,
                        selected: Bool, visible: CGRect) -> (head: CGFloat, tail: CGFloat) {
        let column = ClipBodyMetrics.thumbnailColumn(clipWidth: body.width, rowHeight: rect.height, width: ClipBodyMetrics.thumbnailWidth)
        guard column > 0 else { return (0, 0) }
        let local = (visible.minX - rect.minX - 8)...(visible.maxX - rect.minX + 8)
        let strip = min(ClipBodyMetrics.nameStripHeight, drawn.height)
        let fd = geometry.frameDuration
        var head: CGFloat = 0, tail: CGFloat = 0
        for tile in ThumbnailLayout.tiles(mode: thumbnailMode, clipWidth: body.width, column: column, visible: local) {
            // Head mode shows the poster, as the Mac's head column does; the other modes ask for the frame of the tile.
            let at: Time? = thumbnailMode == .head ? nil : ThumbnailLayout.mediaTime(of: tile.anchor, clip: c, frameDuration: fd)
            drawThumbnailTile(&cv, body: body, drawn: drawn, strip: strip, tile: tile, radius: radius,
                              picture: media?.picture(media: c.media, at: at), selected: selected)
            if !tile.belowNameStrip { if tile.anchor == .tail { tail = tile.width } else { head = tile.width } }
        }
        return (head, tail)
    }

    /// `ClipDrawing.drawThumbnailTile`: a column tile spans the body height and is ruled on its inner side; a strip tile
    /// sits under the name strip and is ruled on its right.
    func drawThumbnailTile(_ cv: inout Canvas, body: CGRect, drawn: CGRect, strip: CGFloat, tile: ThumbnailTile, radius: CGFloat,
                           picture: TimelinePicture?, selected: Bool) {
        let inset: CGFloat = selected ? 2 : 0.5
        let top = tile.belowNameStrip ? strip : inset
        var r = CGRect(x: body.minX + tile.offset, y: body.minY + top, width: tile.width, height: body.height - top - inset)
        if r.minX < body.minX + inset { r.size.width -= body.minX + inset - r.minX; r.origin.x = body.minX + inset }
        if r.maxX > body.maxX - inset { r.size.width = body.maxX - inset - r.minX }
        guard r.width > 0, r.height > 0, r.maxX > drawn.minX, r.minX < drawn.maxX else { return }
        cv.saveGState()
        cv.clip(to: r)
        // The well with the body's rounded ends (the Mac clips to the rounded body; here the well itself is rounded).
        cv.fill(roundedRect: body.insetBy(dx: inset, dy: inset), radius: max(radius - inset, 0), skin.thumbWell)
        if let picture { cv.draw(imageSlot: picture.slot, in: r, source: picture.cropped(toFill: r)) }
        cv.restoreGState()
        let ruleX = tile.anchor == .tail && !tile.belowNameStrip ? r.minX : r.maxX - 1
        cv.fill(CGRect(x: ruleX, y: r.minY, width: 1, height: r.height), skin.thumbRule)
    }

    // MARK: Waveforms

    /// The waveform of an audio clip over its body and the clipping bands over it (`WaveformTileCache.draw` and
    /// `drawClipping`). shortcut: columns are computed on every draw (the Mac caches them per tile); add a tile cache when
    /// a long audio timeline draws slowly on the PC.
    func drawWaveform(_ cv: inout Canvas, _ c: Clip, rect: CGRect, visible: CGRect, ink: DrawColor) {
        let toneData = c.tone.map { ToneWaveform.data(for: $0, sourceEnd: c.source.end) }
        guard rect.width >= 1, let data = toneData ?? media?.waveform(media: c.media) else { return }
        let wave = ClipBodyMetrics.waveformRect(in: rect)
        guard wave.height >= 4 else { return }
        let from = max(Int((visible.minX - wave.minX).rounded(.down)), 0)
        let to = min(Int((visible.maxX - wave.minX).rounded(.up)), Int(wave.width.rounded()))
        guard to > from else { return }
        let style = WaveformStyle()
        let cache = toneData == nil ? media?.waveformCache : nil
        var input = WaveformPath.Input(data: data, source: c.source, clipWidth: wave.width, visibleColumns: from..<to,
                                       style: style, volumeDB: ClipAudioCurves.volumeDB(of: c), cache: cache.map { ($0, c.media) })
        input.reversed = c.reversed
        input.sourceMap = ClipAudioCurves.sourceMap(of: c)
        let columns = WaveformPath.columns(input)
        cv.saveGState()
        cv.clip(to: CGRect(x: visible.minX, y: wave.minY, width: visible.width, height: wave.height))
        for r in WaveformPath.bars(columns: columns, rect: wave, style: style, firstColumn: from) { cv.fill(r, ink) }
        let bands = WaveformClipping.bandRects(columns: columns, rect: wave, style: style, firstColumn: from)
        for r in bands.near { cv.fill(r, theme.yellow) }
        for r in bands.over { cv.fill(r, skin.red) }
        cv.restoreGState()
    }

    /// `WaveformTint.color`: the row's ink by audio role.
    func waveformInk(_ track: Track) -> DrawColor {
        switch WaveformTint.role(of: track, clips: track.clips) {
        case nil: DrawColor.white.alpha(0.55)
        case .dialogue: theme.accent.alpha(0.85)
        case .music: skin.green.alpha(0.75)
        case .sfx: theme.yellow.alpha(0.75)
        }
    }

    // MARK: Rubber bands

    /// `ClipDrawing.drawVolumeLine`: a thin line with a diamond on every key, and the two fade handles.
    func drawVolumeLine(_ cv: inout Canvas, _ c: Clip, rect: CGRect, visible: CGRect, selected: Bool) {
        let pts = VolumeLine.points(clip: c, clipRect: rect, visible: visible)
        guard pts.count >= 2 else { return }
        cv.saveGState()
        cv.clip(to: visible.intersection(rect))
        drawBand(&cv, pts, keys: VolumeLine.keyPoints(clip: c, clipRect: rect), keyIDs: c.animation.volume.track.keys.map(\.id),
                 visible: visible, selected: selected)
        if rect.width >= 4 * VolumeLine.handleSize {
            let h = VolumeLine.fadeHandlePoints(clip: c, clipRect: rect), size = VolumeLine.handleSize
            let hidden = hiddenFadeHandles(of: c)
            for (which, p) in [(FadeHandle.head, h.head), (FadeHandle.tail, h.tail)] where !hidden.contains(which) {
                let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                cv.fill(roundedRect: r, radius: 1.5, skin.badgeFill.alpha(selected ? 0.95 : 0.95 * 0.7))
                cv.stroke(roundedRect: r, radius: 1.5, width: 1, skin.badgeEdge)
            }
        }
        cv.restoreGState()
    }

    /// `ClipDrawing.drawOpacityLine`: the same band over a video clip's body.
    func drawOpacityLine(_ cv: inout Canvas, _ c: Clip, rect: CGRect, visible: CGRect, selected: Bool) {
        let pts = OpacityLine.points(clip: c, clipRect: rect, visible: visible)
        guard pts.count >= 2 else { return }
        cv.saveGState()
        cv.clip(to: visible.intersection(rect))
        drawBand(&cv, pts, keys: OpacityLine.keyPoints(clip: c, clipRect: rect), keyIDs: c.animation.opacity.track.keys.map(\.id),
                 visible: visible, selected: selected)
        cv.restoreGState()
    }

    private func drawBand(_ cv: inout Canvas, _ pts: [CGPoint], keys: [CGPoint], keyIDs: [UUID], visible: CGRect, selected: Bool) {
        cv.strokePolyline(pts.map { CGPoint(x: $0.x, y: $0.y + 1) }, width: 1, skin.badgeEdge)
        cv.strokePolyline(pts, width: 1, skin.badgeFill.alpha(selected ? 0.95 : 0.95 * 0.75))
        for (i, k) in keys.enumerated() where k.x >= visible.minX - 4 && k.x <= visible.maxX + 4 {
            let diamond = [CGPoint(x: k.x, y: k.y - 4), CGPoint(x: k.x + 4, y: k.y), CGPoint(x: k.x, y: k.y + 4), CGPoint(x: k.x - 4, y: k.y)]
            cv.fill(polygon: diamond, i < keyIDs.count && selectedLineKeys.contains(keyIDs[i]) ? theme.accent : skin.badgeFill)
            cv.stroke(polygon: diamond, width: 1, skin.badgeEdge)
        }
    }

    // MARK: Badges

    /// `ClipDrawing.drawFXBadge`: a small "fx" pill at the clip's top right once an effect is applied.
    func drawFXBadge(_ cv: inout Canvas, rect: CGRect, visible: CGRect) {
        guard rect.width >= 40 else { return }
        let size = DrawTheme.TypeSize.clipName.cg
        let textW = cv.size(of: "fx", fontSize: size).width
        let w = textW + 6, h: CGFloat = 12
        let pill = CGRect(x: min(rect.maxX, visible.maxX) - 3 - w, y: rect.minY + 4, width: w, height: h)
        guard pill.minX >= rect.minX + ClipBodyMetrics.thumbnailWidth else { return }
        cv.fill(roundedRect: pill, radius: 3, DrawColor.black.alpha(0.5))
        cv.draw("fx", at: CGPoint(x: pill.minX + 3, y: pill.minY), fontSize: size, .white)
    }

    /// Width the clip name gives up for the fx pill (`ClipDrawing.fxBadgeReserve`).
    func fxBadgeReserve(clipWidth: CGFloat, size cv: inout Canvas) -> CGFloat {
        clipWidth >= 40 ? cv.size(of: "fx", fontSize: DrawTheme.TypeSize.clipName.cg).width + 6 + 3 : 0
    }

    /// `ClipDrawing.drawSyncBadge`: frames the linked partner has drifted ("+3"), red on the clip's left edge.
    func drawSyncBadge(_ cv: inout Canvas, frames: Int64, rect: CGRect, visible: CGRect) {
        guard frames != 0, rect.width >= 24 else { return }
        let text = (frames > 0 ? "+" : "\u{2212}") + String(abs(frames))
        let size = DrawTheme.TypeSize.clipName.cg
        let w = cv.size(of: text, fontSize: size).width + 8
        let y = rect.minY + (rect.height >= ClipBodyMetrics.bodyMinHeight ? ClipBodyMetrics.nameStripHeight + 3 : 2)
        let pill = CGRect(x: max(rect.minX, visible.minX) + 3, y: y, width: w, height: 12)
        guard pill.maxX < rect.maxX else { return }
        cv.fill(roundedRect: pill, radius: DrawTheme.Radius.small.cg, skin.red)
        cv.draw(text, at: CGPoint(x: pill.minX + 4, y: pill.minY), fontSize: size, .white)
    }
}
