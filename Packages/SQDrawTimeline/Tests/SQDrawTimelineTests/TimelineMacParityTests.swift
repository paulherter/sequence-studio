import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)
private final class Clock: @unchecked Sendable { var now = 100.0 }

/// 1000 x 400 pt at scale 1, two tracks with a 30 s clip each.
private func panel(magnetic: Bool = false, clock: Clock = Clock()) -> TimelinePanel {
    func clip() -> Clip { Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 750), start: .zero) }
    var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [clip()]), Track(kind: .video, clips: [clip()])])
    if magnetic { t.editMode = .magnetic }
    var p = TimelinePanel()
    p.clock = { clock.now }
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    p.sync(timeline: t, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
    return p
}

/// Behaviors of the Mac `TimelineView` the shared panel must show the same (zoom ease, skimmer press, razor guide, autoscroll).
@MainActor @Suite struct TimelineMacParityTests {
    @Test func aZoomKeyEasesOverTheMacDurationAndLandsOnTheKeyStep() {
        let c = Clock()
        var p = panel(clock: c)
        p.setZoom(pointsPerSecond: p.geometry.pointsPerSecond * 4, anchorX: TimelineGeometry.contentOriginX)
        let start = p.geometry.pointsPerSecond
        _ = p.key(.character("="), modifiers: [])
        #expect(p.geometry.pointsPerSecond == start && p.isZooming, "the key only starts the ease")
        c.now += ZoomAnimation.duration / 2
        _ = p.tick()
        #expect(p.geometry.pointsPerSecond > start && p.geometry.pointsPerSecond < start * TimelineZoom.keyStep && p.isZooming)
        c.now += ZoomAnimation.duration
        _ = p.tick()
        #expect(abs(p.geometry.pointsPerSecond - start * TimelineZoom.keyStep) < 1e-6 && !p.isZooming)
    }

    @Test func aSecondZoomKeyDuringTheEaseContinuesFromItsTarget() {
        let c = Clock()
        var p = panel(clock: c)
        p.setZoom(pointsPerSecond: p.geometry.pointsPerSecond * 2, anchorX: TimelineGeometry.contentOriginX)
        let start = p.geometry.pointsPerSecond
        _ = p.key(.character("="), modifiers: [])
        _ = p.key(.character("="), modifiers: [])
        c.now += ZoomAnimation.duration * 2
        _ = p.tick()
        let want = min(start * TimelineZoom.keyStep * TimelineZoom.keyStep, p.zoomLimits.upperBound)
        #expect(abs(p.geometry.pointsPerSecond - want) < 1e-6)
    }

    @Test func aWheelScrollEndsTheRunningEase() {
        var p = panel()
        _ = p.key(.minus, modifiers: [])
        #expect(p.isZooming)
        p.setZoom(pointsPerSecond: p.geometry.pointsPerSecond * 1.5)
        #expect(!p.isZooming)
    }

    @Test func backslashFitsThenReturnsToThePreviousLevel() {
        let c = Clock()
        var p = panel(clock: c)
        p.setZoom(pointsPerSecond: p.geometry.pointsPerSecond * 6, anchorX: TimelineGeometry.contentOriginX)
        p.geometry.scrollX = 100
        let before = (p.geometry.pointsPerSecond, p.geometry.scrollX)
        p.zoomToFit()
        c.now += 1; _ = p.tick()
        #expect(abs(p.geometry.pointsPerSecond - p.fitScale) < 1e-6)
        p.zoomToFit()
        c.now += 1; _ = p.tick()
        #expect(abs(p.geometry.pointsPerSecond - before.0) < 1e-6 && abs(p.geometry.scrollX - before.1) < 1e-3)
    }

    @Test func backslashFitsInOutWhenSetButZoomLimitsKeepTheWholeSequence() {
        let c = Clock()
        var p = panel(clock: c)
        var t = p.timeline
        t.setMarkedRange(TimeRange(start: fd * 50, duration: fd * 50))
        p.sync(timeline: t, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        let whole = p.wholeSequenceFitScale
        #expect(p.fitScale > whole * 5, "2 s of 30 s fill the width")
        #expect(p.zoomLimits.lowerBound <= whole)
        p.zoomToFit()
        c.now += 1; _ = p.tick()
        #expect(abs(p.geometry.pointsPerSecond - p.fitScale) < 1e-6)
        #expect(p.geometry.x(for: fd * 50) == TimelineGeometry.contentOriginX + CGFloat(DrawTheme.Spacing.lg))
    }

    @Test func aZoomToolClickEasesAroundThePointer() {
        let c = Clock()
        var p = panel(clock: c)
        p.toolState.select(.zoom)
        let y = Float(TimelineGeometry.rulerHeight + 20)
        _ = p.handle(.mouseDown(x: 500, y: y, modifiers: []))
        _ = p.handle(.mouseUp(x: 500, y: y))
        let start = p.geometry.pointsPerSecond
        #expect(p.isZooming && p.geometry.pointsPerSecond == start)
        c.now += 1; _ = p.tick()
        #expect(p.geometry.pointsPerSecond > start)
    }

    @Test func aPlainPressUnderTheFastCutSkimmerAlsoMovesThePlayhead() {
        var p = panel(magnetic: true)
        let y = Float(TimelineGeometry.rulerHeight + 20)
        _ = p.handle(.mouseMoved(x: 400, y: y))
        let at = p.skimmerTime
        #expect(at != nil)
        let a = p.handle(.mouseDown(x: 400, y: y, modifiers: []))
        #expect(a.contains(.seek(at!)) && a.contains(.skim(nil)))
    }

    @Test func aModifiedPressUnderTheSkimmerDoesNotSeek() {
        var p = panel(magnetic: true)
        let y = Float(TimelineGeometry.rulerHeight + 20)
        _ = p.handle(.mouseMoved(x: 400, y: y))
        let a = p.handle(.mouseDown(x: 400, y: y, modifiers: .shift))
        #expect(!a.contains { if case .seek = $0 { true } else { false } })
    }

    @Test func theRazorGuideSpansEveryTrackWithShiftAndOneWithout() {
        var p = panel()
        p.toolState.select(.razor)
        let y = Float(p.rows[0].y + 10)
        _ = p.handle(.mouseMoved(x: 400, y: y))
        let clip = CGRect(x: 0, y: 0, width: 1000, height: 400)
        p.liveModifiers = { [] }
        let one = p.razorGuideRects(rows: p.rows, clip: clip)
        p.liveModifiers = { .shift }
        let all = p.razorGuideRects(rows: p.rows, clip: clip)
        #expect(one.count == 1 && all.count == 1)
        #expect(all[0].height > one[0].height * 1.5, "Shift: one line through all tracks")
        #expect(all[0].minY <= one[0].minY && all[0].maxY >= p.rows[1].maxY - 0.5)
    }

    @Test func theRazorGuideStaysOffTheZoomBarAndTheRuler() {
        var p = panel()
        p.toolState.select(.razor)
        _ = p.handle(.mouseMoved(x: 400, y: 5))
        #expect(p.razorGuideRects(rows: p.rows, clip: CGRect(x: 0, y: 0, width: 1000, height: 400)).isEmpty)
    }

    @Test func aDragAtTheEdgeKeepsTheHostDrawingEveryFrame() {
        var p = panel()
        p.setZoom(pointsPerSecond: p.geometry.pointsPerSecond * 6, anchorX: TimelineGeometry.contentOriginX)
        let y = Float(p.rows[0].y + p.rows[0].height * 0.7)
        _ = p.handle(.mouseDown(x: 400, y: y, modifiers: []))
        _ = p.handle(.mouseDragged(x: 500, y: y))
        #expect(!p.isAutoscrolling)
        _ = p.handle(.mouseDragged(x: 999, y: y))
        #expect(p.isAutoscrolling)
        _ = p.handle(.mouseUp(x: 999, y: y))
        #expect(!p.isAutoscrolling)
    }
}
