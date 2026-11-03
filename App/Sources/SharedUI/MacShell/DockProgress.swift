import AppKit

/// Dock icon progress bar: the app icon with a thin bar at the bottom while exports run.
@MainActor
final class DockProgress {
    private let bar = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    private var lastDrawn = -1.0

    init() {
        let tile = NSApp.dockTile
        tile.contentView = bar
    }

    func set(fraction: Double) {
        // Redraw the tile only on a visible change (1 %).
        let q = (fraction * 100).rounded() / 100
        guard q != lastDrawn else { return }
        lastDrawn = q
        bar.fraction = q
        NSApp.dockTile.display()
    }

    func clear() {
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

private final class DockProgressView: NSView {
    var fraction = 0.0
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let h: CGFloat = 12, inset: CGFloat = 8
        let track = NSRect(x: inset, y: 10, width: bounds.width - 2 * inset, height: h)
        let theme = MainActor.assumeIsolated { MacWindowStyle.theme }
        MainActor.assumeIsolated { MacWindowStyle.color(theme.overlay) }.setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        let w = max(track.width * CGFloat(min(max(fraction, 0), 1)), h)
        MainActor.assumeIsolated { MacWindowStyle.color(theme.accent) }.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }
}
