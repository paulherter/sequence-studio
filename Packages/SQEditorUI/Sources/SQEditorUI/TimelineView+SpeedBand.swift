import AppKit
import SQCore

public enum SpeedEditPhase: Sendable { case began, changed, ended }

/// One speed band edit for the host: the clip and its new speed track.
public struct SpeedEdit: Sendable {
    public var clip: Clip.ID
    public var keys: SpeedKeys
    public var phase: SpeedEditPhase
}

/// State of one speed band drag (kept in `TimelineView.speedDrag`).
struct SpeedDrag {
    var clip: Clip.ID
    var gesture: SpeedBand.Gesture
    var last: SpeedKeys
    var tip: String?
}

/// Mouse handling and drawing of the Time Remapping speed band on video clips (see `SpeedBand`). Selection tool only.
extension TimelineView {
    /// Video clips that show the band (View state; toggled with "Show Time Remapping").
    public func setSpeedBand(_ ids: Set<Clip.ID>) { speedBandClips = ids; needsDisplay = true }

    /// The video clip, its rectangle and lane under a view point, when the band is shown there.
    private func speedTarget(at p: CGPoint) -> (clip: Clip, rect: CGRect, lane: CGRect)? {
        guard toolState.tool == .selection, !speedBandClips.isEmpty,
              let row = geometry.rows(for: timeline).first(where: { p.y >= $0.y && p.y < $0.maxY }),
              row.kind == .video, SpeedBand.isAvailable(rowHeight: row.height),
              let track = timeline.track(row.track), !track.isLocked,
              let clip = track.clips.first(where: { speedBandClips.contains($0.id) && geometry.x(for: $0.timeline.start) - 6 <= p.x
                                                    && p.x < geometry.x(for: $0.timeline.end) + 6 })
        else { return nil }
        let rect = CGRect(x: geometry.x(for: clip.timeline.start), y: row.y,
                          width: geometry.x(for: clip.timeline.end) - geometry.x(for: clip.timeline.start), height: row.height)
        return (clip, rect, ClipDrawing.waveformRect(in: rect))
    }

    /// Key or transition under a point, for the context menu ("Delete Speed Keyframe") and the Delete key.
    public func speedKeyHit(at p: CGPoint) -> (clip: Clip.ID, key: SpeedBandKeyHit)? {
        guard let t = speedTarget(at: p), let keys = t.clip.speedKeys,
              let h = SpeedBand.hit(keys: keys, clipStart: t.clip.start, lane: t.lane, at: p, x: { self.geometry.x(for: $0) }) else { return nil }
        switch h {
        case .key(let b): return (t.clip.id, SpeedBandKeyHit(hit: .key(b)))
        case .ramp(let i), .rampHandle(let i): return (t.clip.id, SpeedBandKeyHit(hit: .ramp(i)))
        case .segment: return nil
        }
    }

    func beginSpeedDrag(at p: CGPoint, event: NSEvent) -> Bool {
        guard let t = speedTarget(at: p) else { return false }
        let keys = SpeedKeys.of(t.clip)
        let hit = SpeedBand.hit(keys: keys, clipStart: t.clip.start, lane: t.lane, at: p, x: { self.geometry.x(for: $0) })
        guard let hit else { return false }
        let cmd = event.modifierFlags.contains(.command)
        if !cmd, VolumeLine.edgeWins(at: p, clipRect: t.rect) { return false }          // trimming wins at the edges
        let key: Bool
        if case .segment = hit { key = cmd } else { key = false }
        // A segment drag without Cmd edits its speed; Cmd-click adds a key. Keys and transitions need no modifier.
        let tl = geometry
        let g = SpeedBand.Gesture(keys: keys, clipStart: t.clip.start, hit: hit, start: p, lane: t.lane, frameDuration: timeline.frameDuration,
                                  addKey: key, option: event.modifierFlags.contains(.option), shift: event.modifierFlags.contains(.shift),
                                  timeAt: { tl.time(atX: $0) })
        onPointerDown?()
        speedDrag = SpeedDrag(clip: t.clip.id, gesture: g, last: keys, tip: nil)
        if selection != [t.clip.id] { onSelectionChange?([t.clip.id], []) }
        onSpeedEdit?(SpeedEdit(clip: t.clip.id, keys: keys, phase: .began))
        switch hit {
        case .segment: NSCursor.resizeUpDown.set()
        default: NSCursor.resizeLeftRight.set()
        }
        if key { _ = updateSpeedDrag(to: p) }
        return true
    }

    func updateSpeedDrag(to p: CGPoint) -> Bool {
        guard var d = speedDrag else { return false }
        let k = d.gesture.update(to: p)
        d.tip = d.gesture.tooltip(at: p)
        guard k != d.last else { speedDrag = d; needsDisplay = true; return true }
        d.last = k
        speedDrag = d
        previewSpeed(clip: d.clip, keys: k)
        onSpeedEdit?(SpeedEdit(clip: d.clip, keys: k, phase: .changed))
        return true
    }

    func endSpeedDrag(at p: CGPoint) -> Bool {
        guard speedDrag != nil else { return false }
        _ = updateSpeedDrag(to: p)
        if let d = speedDrag { onSpeedEdit?(SpeedEdit(clip: d.clip, keys: d.last, phase: .ended)) }
        speedDrag = nil
        NSCursor.arrow.set()
        needsDisplay = true
        return true
    }

    /// Shows the edited clip at once; the host applies the same edit to the session.
    private func previewSpeed(clip id: Clip.ID, keys: SpeedKeys) {
        var t = timeline
        guard (try? t.editSpeedKeys(id) { _ in keys }) != nil else { return }
        setTimeline(t)
    }

    /// Waveform mapping of a clip with a speed track: clip fraction -> source seconds since `source.start` (nil for constant clips).
    static func sourceMap(of clip: Clip) -> (@Sendable (Double) -> Double)? {
        guard let k = clip.speedKeys else { return nil }
        let total = Double(k.duration.value) / Double(k.duration.timescale)
        let base = Double(clip.source.start.value) / Double(clip.source.start.timescale)
        return { f in k.positionApprox(atSeconds: f * total) - base }
    }

    // MARK: Drawing

    func drawSpeedBand(clip c: Clip, rect: CGRect, visible: CGRect, selected: Bool) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let lane = ClipDrawing.waveformRect(in: rect)
        let keys = SpeedKeys.of(c)
        let xs: (Time) -> CGFloat = { self.geometry.x(for: $0) }
        cg.saveGState()
        cg.clip(to: visible.intersection(rect))
        // Strip behind the keys and shaded spans of the transitions.
        let strip = SpeedBand.strip(in: lane)
        cg.setFillColor(Theme.white(0.14).cgColor)
        cg.fill(strip)
        for r in SpeedBand.rampMarks(keys: keys, clipStart: c.start, lane: lane, x: xs) {
            cg.setFillColor(Theme.white(0.38).cgColor)
            cg.fill(CGRect(x: r.x0, y: strip.minY, width: max(r.x1 - r.x0, 1), height: strip.height))
        }
        // Rubber band: a dark shadow line under a white one, like the volume band.
        let pts = SpeedBand.linePoints(keys: keys, clipStart: c.start, lane: lane, x: xs)
        cg.setLineWidth(1)
        cg.setStrokeColor(Theme.black(0.45).cgColor)
        cg.addLines(between: pts.map { CGPoint(x: $0.x, y: $0.y + 1) }); cg.strokePath()
        cg.setStrokeColor(Theme.white(selected ? 0.95 : 0.8).cgColor)
        cg.addLines(between: pts); cg.strokePath()
        // Speed text on every segment wide enough.
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: Theme.white(0.92)]
        let area = SpeedBand.lineArea(in: lane), starts = keys.boundaries
        for (i, s) in keys.segments.enumerated() {
            let x0 = xs(c.start + starts[i]), x1 = xs(c.start + starts[i + 1])
            guard x1 - x0 > 44 else { continue }
            let mid = s.speedValue(at: Time(s.duration.value, s.duration.timescale * 2))
            let text = SpeedBand.label(speed: mid) as NSString
            let y = SpeedBand.y(forSpeed: mid, in: area)
            text.draw(at: CGPoint(x: (x0 + x1) / 2 - text.size(withAttributes: attrs).width / 2, y: y + 3), withAttributes: attrs)
        }
        // Keys: triangles in the strip (halves lean toward their transition); centre handles on the transitions.
        cg.setFillColor(Theme.white(0.95).cgColor)
        cg.setStrokeColor(Theme.black(0.6).cgColor)
        for k in SpeedBand.keyMarks(keys: keys, clipStart: c.start, x: xs) {
            let p = CGMutablePath()
            if k.isHalf {
                let dir: CGFloat = k.isLeftHalf ? 1 : -1                      // a left half points into the transition
                p.move(to: CGPoint(x: k.x, y: strip.minY)); p.addLine(to: CGPoint(x: k.x, y: strip.maxY))
                p.addLine(to: CGPoint(x: k.x + 4 * dir, y: strip.midY))
            } else {
                p.move(to: CGPoint(x: k.x - 4, y: strip.minY)); p.addLine(to: CGPoint(x: k.x + 4, y: strip.minY))
                p.addLine(to: CGPoint(x: k.x, y: strip.maxY))
            }
            p.closeSubpath()
            cg.addPath(p); cg.fillPath(); cg.addPath(p); cg.strokePath()
        }
        for r in SpeedBand.rampMarks(keys: keys, clipStart: c.start, lane: lane, x: xs) {
            let dot = CGRect(x: r.handle.x - 3.5, y: r.handle.y - 3.5, width: 7, height: 7)
            cg.setFillColor(Theme.Colors.accent.cgColor)
            cg.fillEllipse(in: dot)
            cg.setStrokeColor(Theme.white(0.95).cgColor)
            cg.strokeEllipse(in: dot)
        }
        cg.restoreGState()
    }

    /// Tooltip "Speed 250%" next to the pointer while a segment is dragged.
    func drawSpeedTip() {
        guard let d = speedDrag, let tip = d.tip, let cg = NSGraphicsContext.current?.cgContext else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Theme.white(0.95)]
        let s = tip as NSString, size = s.size(withAttributes: attrs)
        let origin = CGPoint(x: d.gesture.start.x + 12, y: d.gesture.start.y - size.height - 10)
        let box = CGRect(origin: origin, size: size).insetBy(dx: -6, dy: -3)
        cg.setFillColor(Theme.black(0.8).cgColor)
        cg.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil)); cg.fillPath()
        s.draw(at: origin, withAttributes: attrs)
    }
}

/// A key or a transition of a speed band (what the context menu and Delete act on).
public struct SpeedBandKeyHit: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case key(Int), ramp(Int) }
    public var hit: Kind
    var band: SpeedBand.Hit {
        switch hit {
        case .key(let b): return .key(b)
        case .ramp(let i): return .ramp(i)
        }
    }
    public var title: String {
        switch hit {
        case .key: return "Delete Speed Keyframe"
        case .ramp: return "Remove Speed Transition"
        }
    }
}
