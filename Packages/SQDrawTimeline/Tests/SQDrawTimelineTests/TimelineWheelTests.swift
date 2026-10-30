import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)
private final class Clock: @unchecked Sendable { var now = 100.0 }
private func secs(_ t: Time) -> Double { Double(t.value) / Double(t.timescale) }

/// 1000 x 200 pt at scale 1, ten video tracks (the tracks overflow vertically), 30 s of clips, zoomed in so time scrolls.
private func panel(magnetic: Bool = false, clock: Clock = Clock()) -> TimelinePanel {
    let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 750), start: .zero)
    var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip])] + (0..<9).map { _ in Track(kind: .video) })
    if magnetic { t.editMode = .magnetic }
    var p = TimelinePanel()
    p.clock = { clock.now }
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 200), scale: 1)
    p.sync(timeline: t, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
    p.setZoom(pointsPerSecond: p.geometry.pointsPerSecond * 8, anchorX: TimelineGeometry.contentOriginX)
    return p
}

private func pad(_ dx: Double, _ dy: Double, _ phase: ScrollPhase, momentum: ScrollPhase = .none) -> ScrollGesture {
    ScrollGesture(deltaX: dx, deltaY: dy, precise: true, phase: phase, momentumPhase: momentum)
}

/// `TimelineView.scrollWheel / magnify / smartMagnify` on the shared panel: AppKit deltas, the old gains and locks.
@Suite struct TimelineWheelTests {
    @Test func aTrackpadSwipeLocksToItsFirstAxisAtTheTrackpadGain() {
        var p = panel()
        p.geometry.scrollX = 200; p.geometry.scrollY = 20
        let y0 = p.geometry.scrollY
        // Mostly sideways start: horizontal, the held-back movement released at 1.6x; vertical is dropped.
        p.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: pad(-10, -3, .began), modifiers: [])
        #expect(p.geometry.scrollX == 216 && p.geometry.scrollY == y0)
        p.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: pad(0, -20, .changed), modifiers: [])
        #expect(p.geometry.scrollX == 216 && p.geometry.scrollY == y0)
        // A new, clearly vertical gesture scrolls the tracks 1:1 (not 2.4x as before the port).
        p.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: pad(0, -12, .began), modifiers: [])
        #expect(p.geometry.scrollX == 216 && p.geometry.scrollY == y0 + 12)
    }

    @Test func aMouseWheelLineIsOneNotchAndFollowsTheAppKitSign() {
        var p = panel()
        p.geometry.scrollX = 200
        p.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: ScrollGesture(deltaY: -1), modifiers: [])
        #expect(p.geometry.scrollY == 48)                       // toward the user: the tracks move up
        p.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: ScrollGesture(deltaY: 0.5), modifiers: [])
        #expect(p.geometry.scrollY == 24)
        p.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: ScrollGesture(deltaY: 1), modifiers: .shift)
        #expect(p.geometry.scrollX == 152 && p.geometry.scrollY == 24)    // Shift: time only
    }

    @Test func theHostPathUsesThePublishedGestureAndWindowsPixelsMeanNotches() {
        var p = panel()
        p.geometry.scrollX = 200
        let h = HostGesture()
        HostGesture.$current.withValue(h) {
            // The Mac host's pixels (2 px for 1 pt) do not matter: the published trackpad points do.
            _ = h.with(pad(0, -30, .began)) { p.handle(.scroll(x: 500, y: 100, dx: 0, dy: -60, modifiers: [])) }
        }
        #expect(p.geometry.scrollY == 30)
        // No gesture (Windows): 40 px are one wheel notch.
        _ = p.handle(.scroll(x: 500, y: 100, dx: 0, dy: 40, modifiers: []))
        #expect(p.geometry.scrollY == 0)
    }

    @Test func commandOrOptionScrollZoomsAndTheMomentumTailKeepsZooming() {
        var p = panel()
        let s0 = p.geometry.pointsPerSecond
        p.scrollWheel(at: CGPoint(x: 600, y: 100), gesture: pad(0, 10, .began), modifiers: .option)
        let s1 = p.geometry.pointsPerSecond
        #expect(abs(s1 / s0 - exp(10 * TimelineZoom.preciseScrollGain)) < 1e-9)
        p.scrollWheel(at: CGPoint(x: 600, y: 100), gesture: pad(0, 0, .ended), modifiers: [])
        // Key released, the tail still zooms (ScrollZoomState) instead of scrolling sideways.
        let x = p.geometry.scrollX
        p.scrollWheel(at: CGPoint(x: 600, y: 100), gesture: pad(0, -5, .none, momentum: .changed), modifiers: [])
        #expect(abs(p.geometry.pointsPerSecond / s1 - exp(-5 * TimelineZoom.preciseScrollGain)) < 1e-9)
        p.scrollWheel(at: CGPoint(x: 600, y: 100), gesture: pad(0, 0, .none, momentum: .ended), modifiers: [])
        // Mouse wheel with Command: the wheel gain.
        let s2 = p.geometry.pointsPerSecond
        p.scrollWheel(at: CGPoint(x: 600, y: 100), gesture: ScrollGesture(deltaY: -1), modifiers: .command)
        #expect(abs(p.geometry.pointsPerSecond / s2 - exp(-TimelineZoom.wheelGain)) < 1e-9)
        _ = x
    }

    @Test func pinchZoomsAboutThePointerAndItsResidueDoesNotScroll() {
        let clock = Clock()
        var p = panel(clock: clock)
        p.geometry.scrollX = 100
        let anchor: CGFloat = 400
        let t = secs(p.geometry.unsnappedTime(atX: anchor))
        let s0 = p.geometry.pointsPerSecond
        p.scrollWheel(at: CGPoint(x: anchor, y: 100), gesture: ScrollGesture(kind: .magnify(0.1), precise: true, phase: .changed), modifiers: [])
        #expect(abs(p.geometry.pointsPerSecond / s0 - exp(0.1 * TimelineZoom.pinchGain)) < 1e-9)
        #expect(abs(secs(p.geometry.unsnappedTime(atX: anchor)) - t) < 0.01)
        p.scrollWheel(at: CGPoint(x: anchor, y: 100), gesture: ScrollGesture(kind: .magnify(0), precise: true, phase: .ended), modifiers: [])
        let y = p.geometry.scrollY
        p.scrollWheel(at: CGPoint(x: anchor, y: 100), gesture: pad(0, -20, .began), modifiers: [])
        #expect(p.geometry.scrollY == y)                          // inside the pinch tail
        clock.now += 1
        p.scrollWheel(at: CGPoint(x: anchor, y: 100), gesture: pad(0, -20, .began), modifiers: [])
        #expect(p.geometry.scrollY == y + 20)
    }

    @Test func fastCutDoubleTapFitsAndTheEndsRubberBandBack() {
        let clock = Clock()
        var normal = panel()
        let zoomed = normal.geometry.pointsPerSecond
        normal.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: ScrollGesture(kind: .smartMagnify), modifiers: [])
        #expect(normal.geometry.pointsPerSecond == zoomed)       // Normal: no double tap
        var p = panel(magnetic: true, clock: clock)
        p.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: ScrollGesture(kind: .smartMagnify), modifiers: [])
        #expect(p.geometry.pointsPerSecond == p.fitScale)
        p.setZoom(pointsPerSecond: zoomed, anchorX: TimelineGeometry.contentOriginX)
        p.geometry.scrollX = 0
        // Pull past the start: damped, kept through layout, then sprung back by `tick`.
        p.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: pad(30, 0, .began), modifiers: [])
        #expect(p.geometry.scrollX < 0 && p.geometry.scrollX > -30)
        p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 200), scale: 1)
        #expect(p.geometry.scrollX < 0)
        p.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: pad(0, 0, .ended), modifiers: [])
        #expect(p.isSpringingBack)
        let pulled = p.geometry.scrollX
        clock.now += RubberBand.springDuration / 2
        _ = p.tick()
        #expect(p.geometry.scrollX > pulled && p.geometry.scrollX < 0)
        clock.now += RubberBand.springDuration
        _ = p.tick()
        #expect(p.geometry.scrollX == 0 && !p.isSpringingBack)
    }

    /// Windows (`WinScroll`): a touchpad pinch zooms like the Mac pinch, a touchpad scroll moves like the Mac trackpad,
    /// a mouse notch like the Mac wheel line.
    @Test func windowsTouchpadAndWheelMeanTheMacGestures() {
        let clock = Clock()
        var p = panel(clock: clock)
        p.geometry.scrollX = 100
        var w = WinScroll()
        let s0 = p.geometry.pointsPerSecond
        p.scrollWheel(at: CGPoint(x: 400, y: 100), gesture: w.wheel(delta: 120, horizontal: false, control: false, now: 0),
                      modifiers: [])                                  // a notch: no pinch
        #expect(p.geometry.pointsPerSecond == s0)
        let pinch = w.wheel(delta: 60, horizontal: false, control: true, now: 1)
        #expect(pinch.kind == .magnify(0.05))
        p.scrollWheel(at: CGPoint(x: 400, y: 100), gesture: pinch, modifiers: [.command])
        #expect(abs(p.geometry.pointsPerSecond / s0 - exp(0.05 * TimelineZoom.pinchGain)) < 1e-9)
        if let end = w.idle(now: 2) { p.scrollWheel(at: CGPoint(x: 400, y: 100), gesture: end, modifiers: []) }
        // A sideways touchpad swipe after the pinch tail: precise points through the trackpad formula.
        clock.now += 1
        var q = panel(clock: clock)
        q.geometry.scrollX = 200
        let x0 = q.geometry.scrollX
        q.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: w.wheel(delta: 30, horizontal: true, control: false, now: 10), modifiers: [])
        var mac = panel(clock: clock)
        mac.geometry.scrollX = 200
        mac.scrollWheel(at: CGPoint(x: 500, y: 100), gesture: pad(-10, 0, .began), modifiers: [])
        #expect(q.geometry.scrollX == mac.geometry.scrollX && q.geometry.scrollX != x0)
    }
}
