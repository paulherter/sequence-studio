import AppKit
import SQCore
import SQMedia

/// Finished waveform outlines per audio clip and tile of `tileColumns` columns, in clip-local coordinates. Scrolling (and
/// playhead strips, selection changes, ...) redraws a waveform with one fill of the cached tiles; columns are computed
/// again only when the clip, its drawn size (zoom, row height) or the peaks it was made from change.
///
/// A tile made while the zoom bucket was still cold (mip-pyramid read, see `WaveformPath.columns`) is remade once the
/// background build has stored that bucket, so the picture ends up exactly what a direct draw shows.
@MainActor
final class WaveformTileCache {
    static let tileColumns = 512
    /// Tiles kept; beyond this the least recently drawn half goes.
    static let limit = 1024

    private struct Key: Hashable { var clip: Clip.ID; var tile: Int }
    private struct Entry {
        var clip: Clip
        var size: CGSize
        /// Made from the exact zoom bucket (or a path that never uses one); false = fallback picture.
        var exact: Bool
        /// The tile's columns; `first` is the clip-local index of the first one.
        var first: Int
        var columns: [[WaveformColumn]]
        /// Outline for a CoreGraphics fill, made on first use (only drawing outside the content cache needs it).
        var path: CGPath?
        /// Yellow / red clipping bands (`WaveformClipping`), made on first use.
        var bands: (near: CGPath, over: CGPath)?
        var lastUse: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    /// Tiles computed so far (tests).
    private(set) var computedTiles = 0

    var count: Int { entries.count }
    func removeAll() { entries.removeAll() }

    /// Waveform color.
    static var color: CGColor { Theme.TimelineSkin.waveform.cgColor }

    /// Draws `clip`'s waveform over its body. `rect` is the clip's full rectangle, `visible` the horizontal range to draw.
    /// `mask`: a row mask begun for this clip's row (`WaveformMask.begin`); the columns go into it and the caller blends the
    /// whole row at once. Without one (or for a CTM the mask refused) the outline is filled here.
    func draw(clip c: Clip, data: WaveformData, rect: CGRect, visible: CGRect, cache: WaveformCache?, in cg: CGContext,
              mask: WaveformMask? = nil) {
        guard rect.width >= 1 else { return }
        let wave = ClipDrawing.waveformRect(in: rect)
        guard wave.height >= 4 else { return }
        let from = max(Int((visible.minX - wave.minX).rounded(.down)), 0)
        let to = min(Int((visible.maxX - wave.minX).rounded(.up)), Int(wave.width.rounded()))
        guard to > from else { return }
        clock &+= 1
        let style = WaveformStyle()
        let local = CGRect(origin: .zero, size: wave.size)
        let sourceMap = TimelineView.sourceMap(of: c)
        let pps = Double(max(Int(wave.width.rounded()), 1)) / max(Double(c.source.duration.value) / Double(c.source.duration.timescale), 1e-9)
        let usesBuckets = cache != nil && sourceMap == nil && pps <= WaveformCache.maxColumnsPerSecond
        func exactNow() -> Bool { !usesBuckets || cache?.cached(media: c.media, pointsPerSecond: pps) != nil }

        let combined = mask == nil ? CGMutablePath() : nil
        // Columns start on a device pixel, as the mask snaps them: both ways draw the same pixels.
        let transform = CGAffineTransform(translationX: WaveformMask.snappedX(wave.minX, ctm: cg.ctm), y: wave.minY)
        let T = Self.tileColumns
        for tile in (from / T)...((to - 1) / T) {
            let key = Key(clip: c.id, tile: tile)
            var e: Entry
            if let hit = entries[key], hit.size == wave.size, hit.clip == c, hit.exact || !exactNow() {
                e = hit
                // A fallback picture always has its exact bucket on the way: the build it asked for may have been evicted
                // before the redraw that would have used it (request is a no-op while cached or in flight).
                if !hit.exact, let cache { cache.requestBuild(media: c.media, data: data, pointsPerSecond: pps, radius: 2) }
            } else {
                let exact = exactNow()
                let cols = tile * T..<min((tile + 1) * T, Int(wave.width.rounded()))
                var input = WaveformPath.Input(data: data, source: c.source, clipWidth: wave.width, visibleColumns: cols,
                                               style: style, volumeDB: TimelineView.volumeDB(of: c), cache: cache.map { ($0, c.media) })
                input.reversed = c.reversed
                input.sourceMap = sourceMap
                e = Entry(clip: c, size: wave.size, exact: exact, first: cols.lowerBound, columns: WaveformPath.columns(input),
                          path: nil, bands: nil, lastUse: clock)
                computedTiles += 1
            }
            e.lastUse = clock
            if let mask {
                var r = wave
                r.origin.x = transform.tx
                mask.add(columns: e.columns, rect: r, style: style, firstColumn: e.first)
            } else {
                let path = e.path ?? WaveformPath.outline(columns: e.columns, rect: local, style: style, firstColumn: e.first)
                e.path = path
                combined?.addPath(path, transform: transform)
            }
            entries[key] = e
        }
        if let combined {
            cg.saveGState()
            cg.setFillColor(Self.color)
            cg.addPath(combined)
            cg.fillPath()
            cg.restoreGState()
        }
        if entries.count > Self.limit { evict() }
    }

    /// Draws the clipping bands over the tiles `draw` has just made for this clip (yellow near 0 dBFS, red at or over).
    /// Tiles that are not cached (or were made for another size) are skipped: nothing is computed here.
    func drawClipping(clip c: Clip, rect: CGRect, visible: CGRect, in cg: CGContext) {
        guard rect.width >= 1 else { return }
        let wave = ClipDrawing.waveformRect(in: rect)
        guard wave.height >= 4 else { return }
        let from = max(Int((visible.minX - wave.minX).rounded(.down)), 0)
        let to = min(Int((visible.maxX - wave.minX).rounded(.up)), Int(wave.width.rounded()))
        guard to > from else { return }
        let style = WaveformStyle()
        let local = CGRect(origin: .zero, size: wave.size)
        let transform = CGAffineTransform(translationX: WaveformMask.snappedX(wave.minX, ctm: cg.ctm), y: wave.minY)
        let T = Self.tileColumns
        let near = CGMutablePath(), over = CGMutablePath()
        for tile in (from / T)...((to - 1) / T) {
            let key = Key(clip: c.id, tile: tile)
            guard var e = entries[key], e.size == wave.size, e.clip == c else { continue }
            let b = e.bands ?? WaveformClipping.bands(columns: e.columns, rect: local, style: style, firstColumn: e.first)
            e.bands = b
            entries[key] = e
            near.addPath(b.near, transform: transform)
            over.addPath(b.over, transform: transform)
        }
        guard !near.isEmpty || !over.isEmpty else { return }
        cg.saveGState()
        cg.clip(to: CGRect(x: visible.minX, y: wave.minY, width: visible.width, height: wave.height))
        cg.setFillColor(WaveformClipping.nearColor); cg.addPath(near); cg.fillPath()
        cg.setFillColor(WaveformClipping.overColor); cg.addPath(over); cg.fillPath()
        cg.restoreGState()
    }

    private func evict() {
        let keep = entries.sorted { $0.value.lastUse > $1.value.lastUse }.prefix(Self.limit / 2)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}
