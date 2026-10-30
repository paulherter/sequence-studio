import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

private let fd = Time(1, 24)

@Suite struct TimelineZoomMathTests {
    @Test func anchorStaysUnderPointer() {
        for anchor in [0.0, 300, 1000] {
            let old = 20.0, new = 80.0, scroll = 500.0
            let t = (anchor + scroll) / old
            let ns = TimelineZoom.anchoredScroll(oldScale: old, newScale: new, scrollX: scroll, anchorX: anchor)
            #expect(abs((anchor + ns) / new - t) < 1e-9)
        }
    }

    @Test func pressesFromFitToFrameLevel() {
        // 10 minute sequence in a 1400 pt wide view, 24 fps.
        let viewport = 1400.0 - Double(TimelineGeometry.contentOriginX)
        let fit = (viewport - 48) / 600
        let lim = TimelineZoom.limits(fit: fit, viewportWidth: viewport, frameSeconds: 1.0 / 24)
        let presses = TimelineZoom.steps(from: fit, to: lim.upperBound)
        print("zoom: presses from fit to frame level (10 min, 24 fps): \(presses); max scale \(lim.upperBound) pt/s = \(lim.upperBound / 24) pt/frame")
        #expect(presses <= 10)
        var s = fit
        for _ in 0..<presses { s = TimelineZoom.clamp(s * TimelineZoom.keyStep, to: lim) }
        #expect(s == lim.upperBound)
    }

    @Test func limitsClamp() {
        let lim = TimelineZoom.limits(fit: 2, viewportWidth: 1000, frameSeconds: 1.0 / 30)
        #expect(lim.lowerBound == 1)                         // zoom out stops at half of fit
        #expect(lim.upperBound == 1000 / 4 * 30)             // 4 frames across the width
        #expect(TimelineZoom.clamp(1e9, to: lim) == lim.upperBound && TimelineZoom.clamp(0, to: lim) == lim.lowerBound)
        let huge = TimelineZoom.limits(fit: 2, viewportWidth: 20000, frameSeconds: 1.0 / 30)
        #expect(huge.upperBound == 400 * 30)                 // points-per-frame cap
    }

    @Test func gains() {
        #expect(TimelineZoom.scrollFactor(delta: 300, precise: true) > 100)
        #expect(TimelineZoom.pinchFactor(magnification: 1) > 20)
        #expect(abs(TimelineZoom.pinchFactor(magnification: 0.4) - exp(1.2)) < 1e-9)   // ~3.32x
        #expect(abs(TimelineZoom.scrollFactor(delta: 1, precise: false) - 1.22) < 0.01)
        #expect(TimelineZoom.scrollFactor(delta: -5, precise: true) < 1)
    }

    @Test func fitToggleRoundTrip() {
        var t = ZoomFitToggle()
        #expect(t.press(scale: 40, scrollX: 700, fit: 2) == .fit)
        #expect(t.press(scale: 2, scrollX: 0, fit: 2) == .restore(scale: 40, scrollX: 700))
        #expect(t.press(scale: 2, scrollX: 0, fit: 2) == .fit)
    }

    @Test func barHandlesAndDrag() {
        let e = TimelineZoom.barExtent(contentSeconds: 100, scrollX: 0, viewport: 1000, scale: 10)
        #expect(e == 100)
        let h = TimelineZoom.handles(scrollX: 200, viewport: 1000, scale: 10, extent: e)
        #expect(abs(h.lo - 0.2) < 1e-9 && abs(h.hi - 1.0) < 1e-9)
        let range = 0.5...1000.0
        let r = TimelineZoom.dragHandle(lower: true, fraction: 0.5, scrollX: 0, viewport: 1000, scale: 10, extent: 100, range: range)
        #expect(abs(r.scale - 20) < 1e-9 && abs(r.scrollX - 1000) < 1e-9)
        let c = TimelineZoom.dragHandle(lower: true, fraction: 2, scrollX: 0, viewport: 1000, scale: 10, extent: 100, range: range)
        #expect(c.scale == range.upperBound)
    }
}

@MainActor
struct TimelineZoomViewTests {
    private func make(width: CGFloat = 1400) -> TimelineView {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video), Track(kind: .audio)])
        for i in 0..<200 {
            let c = Clip(name: "c\(i)", media: UUID(), kind: .video,
                         source: TimeRange(start: .zero, duration: fd * 70), start: fd * Int64(i * 72), mediaDuration: fd * 400)
            try! t.tracks[0].overwrite(c)
        }
        return TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: width, height: 160))
    }

    @Test func keyZoomKeepsPlayheadAnchored() {
        let v = make()
        v.zoomToFit(); v.settleZoomAnimation()
        v.setPlayhead(fd * 3000)
        let x0 = v.geometry.x(for: fd * 3000)
        for _ in 0..<4 { v.zoomIn(anchorX: x0); v.settleZoomAnimation() }
        #expect(abs(v.geometry.x(for: fd * 3000) - x0) < 1.5)
        #expect(v.geometry.pointsPerSecond <= v.zoomLimits.upperBound)
    }

    @Test func fitTogglesBackToThePreviousZoom() {
        let v = make()
        v.setZoom(pointsPerSecond: 60, anchorX: TimelineGeometry.contentOriginX)
        v.setZoom(pointsPerSecond: 60, anchorX: TimelineGeometry.contentOriginX)
        let z = v.geometry.pointsPerSecond, s = v.geometry.scrollX
        v.zoomToFit(); v.settleZoomAnimation()
        #expect(abs(v.geometry.pointsPerSecond - v.fitScale) < 1e-6)
        v.zoomToFit(); v.settleZoomAnimation()
        #expect(v.geometry.pointsPerSecond == z && v.geometry.scrollX == s)
    }

    @Test func fullRangeIsReachableAndClamped() {
        let v = make()
        for _ in 0..<30 { v.zoomOut() }; v.settleZoomAnimation()
        #expect(v.geometry.pointsPerSecond == v.zoomLimits.lowerBound)
        var n = 0
        while v.geometry.pointsPerSecond < v.zoomLimits.upperBound { v.zoomIn(); v.settleZoomAnimation(); n += 1; if n > 40 { break } }
        print("zoom: key presses from zoom-out limit to frame level on the 200 clip fixture: \(n)")
        #expect(v.geometry.pointsPerSecond == v.zoomLimits.upperBound)
    }

    @Test func drawTimeDuringZoomSweep() {
        let v = make()
        v.setPlayhead(fd * 300)
        v.zoomToFit()
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        for _ in 0..<5 { v.cacheDisplay(in: v.bounds, to: rep) }
        var samples: [Double] = []
        for i in 0..<60 {
            let f = i < 30 ? 1.15 : 1 / 1.15
            v.setZoom(pointsPerSecond: v.geometry.pointsPerSecond * f, anchorX: v.geometry.x(for: fd * 300))
            let t0 = threadCPUNanos()   // CPU time, not wall time: stable under machine load
            v.cacheDisplay(in: v.bounds, to: rep)
            samples.append(Double(threadCPUNanos() - t0) / 1e6)
        }
        samples.sort()
        print("zoom sweep draw (200 clips, 1400x160): median \(String(format: "%.2f", samples[30])) ms, worst \(String(format: "%.2f", samples[59])) ms")
        // CPU time still stretches when the machine is oversubscribed (cache/SMT contention); a real regression (full
        // redraw per step, the old ~100 ms) stays far above this margin.
        #expect(samples[30] < 40)
    }
}

@MainActor @Suite struct TimelineZoomAnimationViewTests {
    @Test func directZoomCancelsRunningAnimation() {
        let v = TimelineView(timeline: Timeline(name: "t", frameDuration: fd), frame: NSRect(x: 0, y: 0, width: 1000, height: 160))
        v.setZoom(pointsPerSecond: 50)
        v.zoomIn()
        v.setZoom(pointsPerSecond: 60)               // direct zoom input cancels the animation
        v.settleZoomAnimation()                      // nothing left to settle
        #expect(v.geometry.pointsPerSecond == 60)
    }
}

@Suite struct TimelineZoomMaxScrollTests {
    @Test func fittingSequenceDoesNotScroll() {
        #expect(TimelineZoom.maxScroll(contentWidth: 500, viewportWidth: 1000) == 0)
        #expect(TimelineZoom.maxScroll(contentWidth: 900, viewportWidth: 1000) == 1400)
    }
}

/// Zoomed all the way out (any gesture, from anywhere in the sequence) the whole sequence is on screen, starting at the
/// left edge, with free space on its right (Premiere).
@MainActor @Suite struct TimelineZoomOutLimitTests {
    private func view(seconds: Int64, width: CGFloat) -> TimelineView {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(seconds, 1)), start: .zero)
        let t = Timeline(name: "z", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip], name: "V1", isTargeted: true)])
        return TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: width, height: 300))
    }

    @Test(arguments: [(Int64(10), CGFloat(900)), (Int64(3600), CGFloat(1600)), (Int64(1), CGFloat(500))])
    func zoomedAllTheWayOutShowsTheWholeSequenceWithRoomOnTheRight(seconds: Int64, width: CGFloat) {
        let v = view(seconds: seconds, width: width)
        let end = Time(seconds, 1)
        v.setZoom(pointsPerSecond: 50, anchorX: TimelineGeometry.contentOriginX)
        v.scroll(toX: v.geometry.width(of: end))                      // tail at the left edge, start far off screen
        v.setZoom(pointsPerSecond: 1e-9, anchorX: width - 10)         // past the limit, anchored at the right
        #expect(v.geometry.scrollX == 0)
        #expect(v.geometry.x(for: .zero) == TimelineGeometry.contentOriginX)
        let free = width - v.geometry.x(for: end)
        #expect(free >= (width - TimelineGeometry.contentOriginX) * 0.25)  // the end is on screen, room after it
        // Scrolling cannot push the sequence off screen at that zoom.
        v.scroll(byX: 500, y: 0)
        #expect(v.geometry.scrollX == 0)
    }
}
