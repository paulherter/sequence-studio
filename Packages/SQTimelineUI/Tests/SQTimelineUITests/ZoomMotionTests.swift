import AppKit
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI

/// Zoom in motion (the design notes 2026-10-11): 1x backing while zoom steps arrive, full scale after a quiet period.
struct ZoomMotionStateTests {
    private let q = ZoomMotion.quietPeriod

    @Test func continuousStepEntersAndExpires() {
        var m = ZoomMotion()
        let r12 = m.step(.continuous, now: 10)
        #expect(r12)
        #expect(m.active)
        let r15 = m.step(.continuous, now: 10.05)
        #expect(!r15)           // already in motion: not an entry
        let r17 = m.tick(now: 10.05 + q / 2)
        #expect(!r17 && m.active)
        let r19 = m.tick(now: 10.05 + q)
        #expect(r19 && !m.active)         // quiet period after the LAST step
        let r21 = m.tick(now: 99)
        #expect(!r21)
    }

    @Test func singleKeyPressNeverEnters() {
        var m = ZoomMotion()
        let r27 = m.step(.discrete, now: 5)
        #expect(!r27)
        m.animationFrame(now: 5.05)                          // animation frames of one press never start it
        #expect(!m.active)
        let r31 = m.step(.discrete, now: 5 + q + 0.01)
        #expect(!r31)       // a press after the quiet period is a first again
    }

    @Test func secondKeyPressWithinQuietPeriodEnters() {
        var m = ZoomMotion()
        let r37 = m.step(.discrete, now: 5)
        #expect(!r37)
        let r39 = m.step(.discrete, now: 5 + q / 2)
        #expect(r39)
        m.animationFrame(now: 5.2)
        let r42 = m.tick(now: 5.2 + q / 2)
        #expect(!r42 && m.active)       // animation frames keep it alive
        let r44 = m.tick(now: 5.2 + q)
        #expect(r44)
    }

    @Test func endLeavesAtOnceAndForgetsHistory() {
        var m = ZoomMotion()
        _ = m.step(.continuous, now: 1)
        let r51 = m.end()
        #expect(r51 && !m.active && m.deadline == nil)
        let r53 = m.end()
        #expect(!r53)
        let r55 = m.step(.discrete, now: 1.01)
        #expect(!r55)               // history cleared: a first press again
    }

    @Test func neverStuckAfterAnyStepSequence() {
        var m = ZoomMotion()
        var t = 0.0
        for i in 0..<200 {
            t += Double((i * 37) % 23) / 100
            _ = m.step(i % 3 == 0 ? .discrete : .continuous, now: t)
        }
        #expect(m.active)
        let r67 = m.tick(now: t + q)
        #expect(r67)                          // whatever happened, one quiet period ends it
        #expect(!m.active)
    }

    @Test func hairlineIsAtLeastOneDevicePixel() {
        #expect(ClipDrawing.edgeWidth(scale: 2) == 0.5)      // unchanged at full scale
        #expect(ClipDrawing.edgeWidth(scale: 1) == 1)        // one device pixel at 1x
        #expect(ClipDrawing.edgeWidth(scale: 3) == 0.5)
    }
}

@MainActor @Suite(.serialized) struct ZoomMotionViewTests {
    private func makeView() -> (TimelineView, NSWindow) {
        let fd = Time(1, 24)
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 480), start: .zero)
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip], name: "V1")])
        let size = NSSize(width: 900, height: 400)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let v = TimelineView(timeline: tl, frame: NSRect(origin: .zero, size: size))
        window.contentView = v
        return (v, window)
    }

    @Test func stepsLowerScaleAndTimerRestoresIt() async throws {
        let (v, w) = makeView()
        defer { w.close() }
        v.setZoom(pointsPerSecond: 50)
        #expect(v.isZoomInMotion && v.contentScaleLimit == 1)
        v.setZoom(pointsPerSecond: 60)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!v.isZoomInMotion)
        #expect(v.contentScaleLimit == nil)
    }

    @Test func windowResignAndRemovalLeaveTheMotion() {
        let (v, w) = makeView()
        v.setZoom(pointsPerSecond: 50)
        #expect(v.isZoomInMotion)
        v.windowResignedKey()
        #expect(!v.isZoomInMotion && v.contentScaleLimit == nil)
        v.setZoom(pointsPerSecond: 70)
        #expect(v.isZoomInMotion)
        w.contentView = NSView()
        #expect(!v.isZoomInMotion)
        w.close()
    }

    @Test func captionStyleStepStaysFullScale() {
        let (v, w) = makeView()
        defer { w.close() }
        v.setZoom(pointsPerSecond: 50, motion: false)
        #expect(!v.isZoomInMotion)
    }

    @Test func tickBeforeDeadlineKeepsMotion() {
        let (v, w) = makeView()
        defer { w.close() }
        v.setZoom(pointsPerSecond: 50)
        v.zoomMotionTick(now: ProcessInfo.processInfo.systemUptime)
        #expect(v.isZoomInMotion)
        v.zoomMotionTick(now: ProcessInfo.processInfo.systemUptime + 1)
        #expect(!v.isZoomInMotion)
    }
}

@MainActor @Suite(.serialized) struct ZoomMotionCacheTests {
    private func rendered(limit: CGFloat?, _ measure: @escaping (CGContext) -> CGFloat) -> [CGFloat] {
        let cache = TimelineContentCache()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        cg.translateBy(x: 0, y: 400); cg.scaleBy(x: 2, y: -2)
        var out: [CGFloat] = []
        let content = CGRect(x: 0, y: 0, width: 400, height: 200)
        _ = cache.draw(in: cg, content: content, clip: content, scrollX: 0, scrollY: 0, pointsPerSecond: 10, canShift: true,
                       edgeItems: { _ in [] }, scaleLimit: limit) { _ in
            out.append(measure(NSGraphicsContext.current!.cgContext))
        }
        return out
    }

    @Test func contentIsRenderedAtTheLimitedScaleAndFullScaleWithoutIt() {
        let scale: (CGContext) -> CGFloat = { abs($0.userSpaceToDeviceSpaceTransform.a) }
        #expect(rendered(limit: nil, scale) == [2])
        #expect(rendered(limit: 1, scale) == [1])
        #expect(rendered(limit: 3, scale) == [2])             // a limit above the display's scale changes nothing
    }

    @Test func edgeLineKeepsOneDevicePixelInTheLimitedBitmap() {
        #expect(rendered(limit: 1, { ClipDrawing.edgeWidth($0) }) == [1])
        #expect(rendered(limit: nil, { ClipDrawing.edgeWidth($0) }) == [0.5])
    }
}
