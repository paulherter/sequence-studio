import AppKit
import SQCore

extension TimelineView {
    /// A click on a weak stretch of a clip's confidence strip moves the playhead to where that stretch begins (MASK-UX 5.4).
    func jumpToWeakStretch(at p: CGPoint) -> Bool {
        guard toolState.timelineTool == .selection, let spansOf = trackWeakSpans,
              let row = layoutRows().first(where: { p.y >= $0.y && p.y < $0.maxY }), row.kind == .video,
              let track = timeline.track(row.track),
              let clip = track.clips.first(where: { geometry.x(for: $0.timeline.start) <= p.x && p.x < geometry.x(for: $0.timeline.end) }),
              let weak = spansOf(clip)
        else { return false }
        let x0 = geometry.x(for: clip.timeline.start), x1 = geometry.x(for: clip.timeline.end)
        let rect = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height)
        guard rect.width >= 12, TrackConfidenceStrip.hitBand(clipRect: rect).contains(p),
              let target = TrackConfidenceStrip.jumpTarget(clip: clip, spans: weak, at: geometry.time(atX: p.x), frameDuration: geometry.frameDuration)
        else { return false }
        onSeek?(target)
        return true
    }
}
