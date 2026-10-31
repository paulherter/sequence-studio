import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI

/// Everything the clip layer's quads depend on. Two frames with an equal key draw the same quads, so the second one replays
/// the first one's. The playhead, hover, gesture overlays, ruler and headers are not in it: they draw live every frame.
struct LaneCacheKey: Equatable {
    var revision: Int
    var geometry: TimelineGeometry
    var frame: DrawRect
    var clip: DrawRect
    var scale: Float
    var size: CGSize
    var theme: DrawTheme
    var selection: Set<Clip.ID>
    var labels: LabelResolver
    var speedBandClips: Set<Clip.ID>
    var gradeOutline: Set<Clip.ID>
    var analysisProgress: [Clip.ID: Double]
    var selectedLineKeys: Set<UUID>
    var thumbnailMode: ThumbnailMode
    var openItemLanes: Set<Clip.ID>
    var atlas: ObjectIdentifier?
    var atlasGeneration: Int
    var media: ObjectIdentifier?
    var mediaRevision: Int
}

/// The clip layer's quads of the last frame, with the key they were built for. Backend-neutral: it holds `DrawQuad`s, so the
/// Mac Metal host and the PC's D3D12 host both replay them. shortcut: one layer for all rows, upgrade to a layer per row when
/// a single track edit should not rebuild the others.
final class LaneCache {
    private var key: LaneCacheKey?
    private var quads: [DrawQuad] = []
    private(set) var hits = 0, misses = 0

    func lookup(_ k: LaneCacheKey) -> [DrawQuad]? {
        guard key == k else { return nil }
        hits += 1
        return quads
    }

    func store(_ k: LaneCacheKey, _ q: [DrawQuad]) {
        key = k; quads = q; misses += 1
    }

    func invalidate() { key = nil; quads = [] }
}

extension TimelinePanel {
    /// nil when the media source cannot stamp its changes (the layer is then drawn fresh every frame).
    func laneCacheKey(atlas: GlyphAtlas?, clip: DrawRect) -> LaneCacheKey? {
        var mediaRevision = 0
        if let media {
            guard let r = media.drawRevision else { return nil }
            mediaRevision = r
        }
        return LaneCacheKey(revision: contentRevision, geometry: geometry, frame: frame, clip: clip, scale: scale, size: size,
                            theme: theme, selection: selection, labels: labels, speedBandClips: speedBandClips,
                            gradeOutline: gradeOutline, analysisProgress: analysisProgress, selectedLineKeys: selectedLineKeys,
                            thumbnailMode: thumbnailMode, openItemLanes: itemLanes.open,
                            atlas: atlas.map(ObjectIdentifier.init), atlasGeneration: atlas?.wipes ?? 0,
                            media: media.map { ObjectIdentifier($0) }, mediaRevision: mediaRevision)
    }

    /// `drawLanes`, replayed from the cache while nothing it draws has changed.
    func drawLanesThroughCache(_ cv: inout Canvas, rows: [TrackRow], clip: CGRect) {
        guard let key = laneCacheKey(atlas: cv.atlas, clip: cv.list.clip) else {
            drawLanes(&cv, rows: rows, clip: clip)
            return
        }
        if let quads = laneCache.lookup(key) { cv.list.append(quads: quads); return }
        let start = cv.list.quads.count
        drawLanes(&cv, rows: rows, clip: clip)
        laneCache.store(key, cv.list.quads(from: start))
    }

    /// What sits on the clips but belongs to someone else's live state: Effect Controls' key lanes (selected clips), the
    /// duck curve and the Magic mask confidence strips. Drawn every frame over the cached clip layer.
    func drawLaneDecorations(_ cv: inout Canvas, rows: [TrackRow], clip: CGRect) {
        let duck = duckContext()
        let keyed = keyLanes != nil && !selection.isEmpty
        let weak = trackWeakSpans != nil
        guard duck != nil || keyed || weak else { return }
        let visibleX = CGRect(x: clip.minX, y: 0, width: clip.width, height: size.height)
        for row in rows {
            let lane = CGRect(x: clip.minX, y: row.y, width: clip.width, height: row.height)
            guard lane.intersects(clip), let track = timeline.track(row.track) else { continue }
            let confidence = weak && track.kind == .video
            let ducked = duck != nil && track.kind == .audio
            guard keyed || confidence || ducked else { continue }
            for c in track.clips[visibleClipIndices(track, from: clip.minX, to: clip.maxX)] {
                let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
                guard x1 >= clip.minX, x0 <= clip.maxX else { continue }
                let rect = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height)
                if rect.width >= 3 {                         // the LOD sliver draws the body only
                    if keyed, selection.contains(c.id) { drawKeyLane(&cv, c, rect: rect, visible: visibleX, selected: true) }
                    if ducked, let duck, duck.clips.contains(c.id) {
                        drawDuckCurve(&cv, clipRect: rect, visible: visibleX, ranges: duck.ranges, ducking: duck.ducking)
                    }
                }
                if confidence { drawTrackConfidence(&cv, c, rect: rect, visible: visibleX) }
            }
        }
    }

    /// The veil of disabled and solo-inactive clips (sliver runs keep theirs in the cached layer). It sits over the clip and
    /// its decorations, as before the cache, so it is drawn after `drawLaneDecorations` each frame.
    func drawLaneVeils(_ cv: inout Canvas, rows: [TrackRow], clip: CGRect) {
        let soloActive = Self.audioSoloActive(in: timeline)
        for (rowIndex, row) in rows.enumerated() {
            let lane = CGRect(x: clip.minX, y: row.y, width: clip.width, height: row.height)
            guard lane.intersects(clip), let track = timeline.track(row.track) else { continue }
            let inactive = Self.isInactive(track, soloActive: soloActive)
            guard inactive || track.clips.contains(where: { !$0.isEnabled }) else { continue }
            let laneColor = Self.isAltLane(rowIndex, in: rows) ? theme.lane : theme.timeline
            for c in track.clips[visibleClipIndices(track, from: clip.minX, to: clip.maxX)] {
                let x0 = geometry.x(for: c.timeline.start), x1 = geometry.x(for: c.timeline.end)
                guard x1 >= clip.minX, x0 <= clip.maxX, x1 - x0 >= 3 else { continue }
                let fade: Float? = inactive ? (selection.contains(c.id) ? 0.5 : 0.72) : (c.isEnabled ? nil : 0.68)
                guard let fade else { continue }
                let body = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height).insetBy(dx: 0, dy: 1)
                cv.fill(roundedRect: body, radius: min(DrawTheme.Radius.small.cg, body.height / 2), laneColor.alpha(fade))
            }
        }
    }
}
