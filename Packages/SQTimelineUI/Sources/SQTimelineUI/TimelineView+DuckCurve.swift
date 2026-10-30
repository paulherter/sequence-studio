import AppKit
import SQCore

extension TimelineView {
    /// Rows this short have no room for a second line next to the waveform.
    static let duckCurveMinRowHeight: CGFloat = 40

    /// Draws the curve over `clipRect` (a Music clip's rect in view coordinates), clipped to `visible`.
    func drawDuckCurve(clipRect: CGRect, visible: CGRect, ranges: [TimeRange], ducking d: LiveDucking) {
        guard !ranges.isEmpty, clipRect.height >= Self.duckCurveMinRowHeight, let cg = NSGraphicsContext.current?.cgContext else { return }
        let area = clipRect.intersection(visible)
        guard !area.isNull, area.width > 0 else { return }
        let pad = d.reach
        let t0 = geometry.time(atX: area.minX), t1 = geometry.time(atX: area.maxX)
        let pts = d.curve(ranges: ranges, in: TimeRange(start: t0 - pad, end: t1 + pad))
        guard pts.count >= 2 else { return }
        let top = clipRect.minY + 4
        let depth = min(clipRect.height * 0.45, 28)
        let span = max(1 - Double(d.floorGain), 0.0001)
        let path = pts.map { p in
            CGPoint(x: geometry.x(for: p.time), y: top + CGFloat((1 - Double(p.gain)) / span) * depth)
        }
        cg.saveGState()
        cg.clip(to: area)
        cg.setLineWidth(1.5); cg.setLineJoin(.round)
        cg.setStrokeColor(Theme.OnPicture.clipBadgeEdge.cgColor)
        cg.addLines(between: path.map { CGPoint(x: $0.x, y: $0.y + 1) }); cg.strokePath()
        cg.setStrokeColor(Theme.TimelineSkin.duckCurve.cgColor)
        cg.addLines(between: path); cg.strokePath()
        cg.restoreGState()
    }

    /// The ducked Music clips (clip tag, else track role) and the ranges that duck them, for this draw (nil when ducking is off
    /// or nobody speaks).
    typealias DuckContext = (ducking: LiveDucking, ranges: [TimeRange], clips: Set<Clip.ID>)

    /// Cached between draws (scroll draws every tick); `duckContextCache` is cleared when the timeline, the setting or the pauses change.
    func duckCurveContext() -> DuckContext? {
        if let cached = duckContextCache { return cached }
        let fresh = computeDuckCurveContext()
        duckContextCache = .some(fresh)
        return fresh
    }

    func computeDuckCurveContext() -> DuckContext? {
        guard let src = duckCurve, let d = src.ducking(), !d.isOff else { return nil }
        let clips = LiveDucking.duckedClipIDs(in: timeline)
        guard !clips.isEmpty else { return nil }
        let ranges = LiveDucking.dialogueRanges(in: timeline, silences: src.silences)
        return ranges.isEmpty ? nil : (d, ranges, clips)
    }
}
