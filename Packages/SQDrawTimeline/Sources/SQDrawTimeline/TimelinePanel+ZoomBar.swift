import Foundation
import SQCore
import SQDrawKit
import SQTimelineUI
import SQUIKit

/// The zoom scroll bar under the tracks (`TimelineView.wireZoomBar` / `layoutChildren`): SQDrawKit's
/// `ZoomScrollBarControl` (the `ZoomScrollBar` rules) at the bottom of the content column, the footer fill left of it,
/// and the same `TimelineZoom` math for handles, drags, pans and fit.
extension TimelinePanel {
    var zoomBarRect: CGRect {
        CGRect(x: TimelineGeometry.contentOriginX, y: max(size.height - Self.zoomBarHeight, 0),
               width: max(size.width - TimelineGeometry.contentOriginX, 0), height: Self.zoomBarHeight)
    }

    /// `zoomBarSnapshot`.
    func zoomBarSnapshot() -> ZoomBarSnapshot {
        let scrollX = Double(geometry.scrollX), viewport = Double(contentViewportWidth), pps = geometry.pointsPerSecond
        let seconds = Double(contentEnd.value) / Double(contentEnd.timescale)
        return ZoomBarSnapshot(scrollX: scrollX, viewport: viewport, scale: pps,
                               extent: TimelineZoom.barExtent(contentSeconds: seconds, scrollX: scrollX, viewport: viewport, scale: pps))
    }

    var zoomBarHandles: (lo: Double, hi: Double) {
        let s = zoomBarSnapshot()
        return TimelineZoom.handles(scrollX: s.scrollX, viewport: s.viewport, scale: s.scale, extent: s.extent)
    }

    /// A press on the bar; false = not on it.
    mutating func zoomBarDown(_ p: CGPoint, clicks: Int) -> Bool {
        guard zoomBarRect.contains(p) else { return false }
        var snapshot = zoomBarSnapshot()
        for o in zoomBar.mouseDown(p, clickCount: clicks, in: zoomBarRect, handles: zoomBarHandles) {
            if o == .begin { snapshot = zoomBarSnapshot() }
            applyZoomBar(o, snapshot)
        }
        gesture = zoomBar.isDragging ? .zoomBar(snapshot) : nil
        return true
    }

    mutating func zoomBarDragged(_ p: CGPoint, _ s: ZoomBarSnapshot) {
        if let o = zoomBar.mouseDragged(p, in: zoomBarRect) { applyZoomBar(o, s) }
    }

    mutating func zoomBarUp() { zoomBar.mouseUp() }

    mutating func applyZoomBar(_ o: ZoomScrollBarGesture.Output, _ s: ZoomBarSnapshot) {
        switch o {
        case .begin: break
        case .fit: zoomToFit()
        case .handle(let lower, let f):
            let r = TimelineZoom.dragHandle(lower: lower, fraction: f, scrollX: s.scrollX, viewport: s.viewport, scale: s.scale,
                                            extent: s.extent, range: zoomLimits)
            applyZoom(scale: r.scale, scrollX: r.scrollX)
        case .pan(let start):
            applyZoom(scale: s.scale, scrollX: max(start, 0) * s.extent * s.scale)
        }
    }

    /// `TimelineView.applyZoom`.
    mutating func applyZoom(scale pps: Double, scrollX: Double) {
        geometry.pointsPerSecond = TimelineZoom.clamp(pps, to: zoomLimits)
        geometry.scrollX = CGFloat(scrollX)
        clampScroll()
    }

    func drawZoomBar(_ cv: inout Canvas) {
        let bar = zoomBarRect
        cv.fill(CGRect(x: 0, y: bar.minY, width: TimelineGeometry.contentOriginX, height: bar.height), theme.timeline)
        zoomBar.draw(&cv, in: bar, handles: zoomBarHandles, theme: theme, background: theme.timeline)
    }
}

/// The view state at a zoom bar press (`zoomBarDrag`).
struct ZoomBarSnapshot: Equatable {
    var scrollX: Double, viewport: Double, scale: Double, extent: Double
}
