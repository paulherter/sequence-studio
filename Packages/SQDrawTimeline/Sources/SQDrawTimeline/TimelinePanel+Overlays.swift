import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI

/// Clip overlays the host feeds (grade outline, analysis progress, Magic mask confidence, live duck curve) and the
/// confidence-strip click, translated from ClipDrawing+GradeOutline / +AnalysisProgress, TrackConfidenceStrip,
/// TimelineView+TrackConfidence and +DuckCurve.
extension TimelinePanel {
    /// `drawGradeOutline`: a 2 pt yellow outline just inside the clip.
    func drawGradeOutline(_ cv: inout Canvas, rect: CGRect) {
        guard rect.width >= 4 else { return }
        cv.stroke(roundedRect: rect.insetBy(dx: 1, dy: 1), radius: DrawTheme.Radius.small.cg, width: 2, theme.yellow.alpha(0.9))
    }

    /// `drawAnalysisProgress`: a 3 pt strip along the bottom edge showing the share done.
    func drawAnalysisProgress(_ cv: inout Canvas, rect: CGRect, progress: Double) {
        guard rect.width >= 12 else { return }
        let h: CGFloat = 3
        let strip = CGRect(x: rect.minX + 1, y: rect.maxY - h - 1, width: rect.width - 2, height: h)
        cv.fill(strip, theme.accent.alpha(0.3))
        cv.fill(CGRect(x: strip.minX, y: strip.minY, width: strip.width * CGFloat(min(max(progress, 0), 1)), height: h), theme.accent)
    }

    /// `drawTrackConfidence`: amber stretches along the bottom of the body where tracking is weak, a tick where each begins.
    func drawTrackConfidence(_ cv: inout Canvas, _ c: Clip, rect: CGRect, visible: CGRect) {
        guard rect.width >= 12, rect.height >= ClipBodyMetrics.bodyMinHeight, let spans = trackWeakSpans?(c) else { return }
        let fd = geometry.frameDuration, start = c.timeline.start, len = c.timeline.duration
        let weak = TrackConfidenceStrip.weakRanges(width: rect.width, step: 2, source: { f in
            let t = start + Time(Int64((Double(len.value) * f).rounded()), len.timescale)
            let s = c.sourceTime(at: t, frameDuration: fd)
            return Double(s.value) / Double(s.timescale)
        }, spans: spans)
        guard !weak.isEmpty else { return }
        let body = rect.insetBy(dx: 0, dy: 1), h = TrackConfidenceStrip.height
        // shortcut: clipped to the body rectangle, not its rounded corners (a 3 pt strip under a 4 pt radius); round the
        // clip when Canvas gets a rounded clip.
        cv.saveGState()
        cv.clip(to: body.intersection(visible))
        for r in weak {
            cv.fill(CGRect(x: rect.minX + r.lowerBound, y: body.maxY - h, width: r.upperBound - r.lowerBound, height: h), skin.warning)
            cv.fill(CGRect(x: rect.minX + r.lowerBound, y: body.maxY - h - 3, width: 2, height: h + 3), skin.warning)
        }
        cv.restoreGState()
    }

    /// `jumpToWeakStretch`: a click on a weak stretch seeks to where it begins.
    func weakStretchJump(at p: CGPoint) -> Time? {
        guard toolState.timelineTool == .selection, let spansOf = trackWeakSpans,
              let row = rows.first(where: { p.y >= $0.y && p.y < $0.maxY }), row.kind == .video,
              let track = timeline.track(row.track),
              let clip = track.clips.first(where: { geometry.x(for: $0.timeline.start) <= p.x && p.x < geometry.x(for: $0.timeline.end) }),
              let weak = spansOf(clip) else { return nil }
        let x0 = geometry.x(for: clip.timeline.start), x1 = geometry.x(for: clip.timeline.end)
        let rect = CGRect(x: x0, y: row.y, width: x1 - x0, height: row.height)
        guard rect.width >= 12, TrackConfidenceStrip.hitBand(clipRect: rect).contains(p) else { return nil }
        return TrackConfidenceStrip.jumpTarget(clip: clip, spans: weak, at: geometry.time(atX: p.x), frameDuration: geometry.frameDuration)
    }

    /// `computeDuckCurveContext`: the ducked Music clips and the ranges that duck them (nil = nothing to draw).
    /// shortcut: recomputed per draw (the Mac caches it until the timeline or the setting changes); cache it when a long
    /// sequence with ducking draws slowly.
    func duckContext() -> (ducking: LiveDucking, ranges: [TimeRange], clips: Set<Clip.ID>)? {
        guard let src = duckCurve, let d = src.ducking(), !d.isOff else { return nil }
        let clips = LiveDucking.duckedClipIDs(in: timeline)
        guard !clips.isEmpty else { return nil }
        let ranges = LiveDucking.dialogueRanges(in: timeline, silences: src.silences)
        return ranges.isEmpty ? nil : (d, ranges, clips)
    }

    /// `drawDuckCurve`: an amber line that dips under speaking dialogue, with a dark shadow line under it.
    func drawDuckCurve(_ cv: inout Canvas, clipRect: CGRect, visible: CGRect, ranges: [TimeRange], ducking d: LiveDucking) {
        guard !ranges.isEmpty, clipRect.height >= 40 else { return }        // `duckCurveMinRowHeight`
        let area = clipRect.intersection(visible)
        guard !area.isNull, area.width > 0 else { return }
        let pad = d.reach
        let pts = d.curve(ranges: ranges, in: TimeRange(start: geometry.time(atX: area.minX) - pad, end: geometry.time(atX: area.maxX) + pad))
        guard pts.count >= 2 else { return }
        let top = clipRect.minY + 4, depth = min(clipRect.height * 0.45, 28)
        let span = max(1 - Double(d.floorGain), 0.0001)
        let path = pts.map { CGPoint(x: geometry.x(for: $0.time), y: top + CGFloat((1 - Double($0.gain)) / span) * depth) }
        cv.saveGState()
        cv.clip(to: area)
        cv.strokePolyline(path.map { CGPoint(x: $0.x, y: $0.y + 1) }, width: 1.5, skin.badgeEdge)
        cv.strokePolyline(path, width: 1.5, skin.warning.alpha(0.9))   // `Theme.TimelineSkin.duckCurve`
        cv.restoreGState()
    }

    // MARK: Hold-S and height persistence

    /// Hold-S during a drag flips snapping until the key comes up; the running drag is recomputed at once (the Mac
    /// `setSnapInverted`). The host calls it with false on the S key-up.
    public mutating func setSnapInverted(_ on: Bool) -> [TimelineAction] {
        guard isDragging || !on, interaction.snapInverted != on else { return [] }
        interaction.snapInverted = on
        guard let p = lastDrag else { return [] }
        return mouseDragged(p)
    }

    /// Keeps the user's heights and split for this sequence (`TrackHeightStore`, the Mac host's `onTrackHeightsChanged`).
    func persistHeights() {
        guard let store = heightStore else { return }
        store.save(geometry.heightOverrides, for: timeline.id)
        store.saveSplit(geometry.splitFraction, for: timeline.id)
    }
}
