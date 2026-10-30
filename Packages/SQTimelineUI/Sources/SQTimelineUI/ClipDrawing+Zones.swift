import AppKit
import SQCore

extension ClipDrawing {
    /// Zone markers (animation zones, TEMPLATE-ECOSYSTEM T3): a short bar along the lower edge over the intro zone and
    /// another over the outro zone, each closed by a small tick where the zone ends, so the part that keeps its length
    /// when the clip is trimmed can be seen. Theme tokens only. Skipped when the clip is too small to show it.
    @MainActor static func drawZoneMarkers(_ zones: AnimationZones, duration: Time, rect: CGRect, visible: CGRect) {
        guard rect.width >= 24, rect.height >= 14, duration > .zero else { return }
        let span = rect.width
        func sec(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }
        func x(_ t: Time) -> CGFloat { rect.minX + span * CGFloat(min(max(sec(t) / sec(duration), 0), 1)) }
        let barH: CGFloat = 3, y = rect.maxY - 2 - barH
        Theme.Colors.accent.withAlphaComponent(0.9).setFill()
        var edges: [CGFloat] = []
        if zones.introEnd > .zero {
            let r = CGRect(x: rect.minX + 1, y: y, width: max(x(zones.introEnd) - rect.minX - 1, 1), height: barH)
            if r.intersects(visible) { NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill() }
            edges.append(x(zones.introEnd))
        }
        if zones.outroLength > .zero {
            let start = x(zones.outroStart(in: duration))
            let r = CGRect(x: start, y: y, width: max(rect.maxX - 1 - start, 1), height: barH)
            if r.intersects(visible) { NSBezierPath(roundedRect: r, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small).fill() }
            edges.append(start)
        }
        for e in edges where e >= visible.minX && e <= visible.maxX {
            NSBezierPath(rect: CGRect(x: e - 0.5, y: y - 3, width: 1, height: barH + 3)).fill()
        }
    }
}
