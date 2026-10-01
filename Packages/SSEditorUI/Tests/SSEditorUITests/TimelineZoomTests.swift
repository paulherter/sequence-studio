import AppKit
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

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
        let viewport = 1400.0 - 162
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
        #expect(TimelineZoom.pinchFactor(magnification: 1) > 80)
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
        v.zoomToFit()
        v.setPlayhead(fd * 3000)
        let x0 = v.geometry.x(for: fd * 3000)
        for _ in 0..<4 { v.zoomIn(anchorX: x0) }
        #expect(abs(v.geometry.x(for: fd * 3000) - x0) < 1.5)
        #expect(v.geometry.pointsPerSecond <= v.zoomLimits.upperBound)
    }

    @Test func fitTogglesBackToThePreviousZoom() {
        let v = make()
        v.setZoom(pointsPerSecond: 60, anchorX: 162)
        v.setZoom(pointsPerSecond: 60, anchorX: 162)
        let z = v.geometry.pointsPerSecond, s = v.geometry.scrollX
        v.zoomToFit()
        #expect(abs(v.geometry.pointsPerSecond - v.fitScale) < 1e-6)
        v.zoomToFit()
        #expect(v.geometry.pointsPerSecond == z && v.geometry.scrollX == s)
    }

    @Test func fullRangeIsReachableAndClamped() {
        let v = make()
        for _ in 0..<30 { v.zoomOut() }
        #expect(v.geometry.pointsPerSecond == v.zoomLimits.lowerBound)
        var n = 0
        while v.geometry.pointsPerSecond < v.zoomLimits.upperBound { v.zoomIn(); n += 1; if n > 40 { break } }
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
            let t0 = DispatchTime.now().uptimeNanoseconds
            v.cacheDisplay(in: v.bounds, to: rep)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        samples.sort()
        print("zoom sweep draw (200 clips, 1400x160): median \(String(format: "%.2f", samples[30])) ms, worst \(String(format: "%.2f", samples[59])) ms")
        #expect(samples[30] < 12)
    }
}
