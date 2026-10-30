import AppKit
import CoreGraphics
import Foundation
import SQCore
import Testing
@testable import SQTimelineUI
import SQUIKit

private let fd = Time(1, 24)

@MainActor @Suite struct SkimmerRulesTests {
    private let geo = TimelineGeometry(frameDuration: fd, pointsPerFrame: 4)
    private let fast = Skimmer.Context(isFastCut: true, isDragging: false, isPlaying: false, isRazor: false)
    private let bar: CGFloat = 20

    private func time(_ p: CGPoint?, _ c: Skimmer.Context) -> Time? {
        Skimmer.time(pointer: p, context: c, viewHeight: 400, zoomBarHeight: bar, geometry: geo)
    }

    @Test func overTheTracksItIsTheFrameUnderThePointer() {
        let x = TimelineGeometry.contentOriginX + 4 * 30 + 1
        #expect(time(CGPoint(x: x, y: 120), fast) == fd * 30)
    }

    @Test func scrolledViewMapsLikeTheRulerScrub() {
        var g = geo
        g.scrollX = 100
        let p = CGPoint(x: TimelineGeometry.contentOriginX + 40, y: 120)
        let t = Skimmer.time(pointer: p, context: fast, viewHeight: 400, zoomBarHeight: bar, geometry: g)
        #expect(t == g.time(atX: p.x))
        #expect(t == fd * 35)
    }

    @Test func hiddenInTheRulerHeadersAndZoomBar() {
        let x = TimelineGeometry.contentOriginX + 100
        #expect(time(CGPoint(x: x, y: TimelineGeometry.rulerHeight - 1), fast) == nil)
        #expect(time(CGPoint(x: TimelineGeometry.contentOriginX - 1, y: 120), fast) == nil)
        #expect(time(CGPoint(x: x, y: 400 - bar), fast) == nil)
        #expect(time(nil, fast) == nil)
    }

    @Test func hiddenOutsideFastCutWhileDraggingPlayingOrWithTheRazor() {
        let p = CGPoint(x: TimelineGeometry.contentOriginX + 100, y: 120)
        var c = fast
        c.isFastCut = false
        #expect(time(p, c) == nil)
        c = fast; c.isDragging = true
        #expect(time(p, c) == nil)
        c = fast; c.isPlaying = true
        #expect(time(p, c) == nil)
        c = fast; c.isRazor = true
        #expect(time(p, c) == nil)
        #expect(time(p, fast) != nil)
    }

    @Test func lineIsTwoPointsBelowTheRulerOnly() {
        let r = Skimmer.lineRect(x: 300.4, viewHeight: 400, zoomBarHeight: bar)
        #expect(r.width == PlayheadLineView.width)
        #expect(r.minY == TimelineGeometry.rulerHeight)
        #expect(r.maxY == 400 - bar)
        #expect(r.midX == 300)
    }
}

@MainActor @Suite struct SkimmerViewTests {
    private func timeline(fastCut: Bool) -> Timeline {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [
            Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: fd * 50, duration: fd * 6000), start: .zero,
                 mediaDuration: fd * 7000)])])
        if fastCut { t.setEditMode(.magnetic) }
        return t
    }

    private func view(fastCut: Bool = true) -> TimelineView {
        let v = TimelineView(timeline: timeline(fastCut: fastCut), frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        v.layoutSubtreeIfNeeded()
        return v
    }

    private func over(_ v: TimelineView, frame f: Int64) -> CGPoint {
        CGPoint(x: v.geometry.x(for: fd * f) + 0.3, y: TimelineGeometry.rulerHeight + 20)
    }

    @Test func showsAndReportsOnceForTheSameFrame() {
        let v = view()
        #expect(v.timeline.isFastCut)
        var reported: [Time?] = []
        v.onSkim = { reported.append($0) }
        v.updateSkimmer(pointer: over(v, frame: 10))
        v.updateSkimmer(pointer: over(v, frame: 10))
        v.updateSkimmer(pointer: over(v, frame: 12))
        #expect(v.skimmerTime == fd * 12)
        #expect(reported == [fd * 10, fd * 12])
    }

    @Test func hidesWhenThePointerLeaves() {
        let v = view()
        var reported: [Time?] = []
        v.onSkim = { reported.append($0) }
        v.updateSkimmer(pointer: over(v, frame: 10))
        v.updateSkimmer(pointer: nil)
        #expect(v.skimmerTime == nil)
        #expect(reported == [fd * 10, nil])
    }

    @Test func neverInNormalMode() {
        let v = view(fastCut: false)
        var calls = 0
        v.onSkim = { _ in calls += 1 }
        v.updateSkimmer(pointer: over(v, frame: 10))
        #expect(v.skimmerTime == nil)
        #expect(calls == 0)
    }

    @Test func hiddenWhilePlayingAndComesBackWhenStopped() {
        let v = view()
        var playing = false
        v.isPlaybackRunning = { playing }
        let p = over(v, frame: 10)
        v.pointerProvider = { p }
        v.updateSkimmerFromPointer()
        #expect(v.skimmerTime == fd * 10)
        playing = true
        v.updateSkimmerFromPointer()
        #expect(v.skimmerTime == nil)
        playing = false
        v.updateSkimmerFromPointer()
        #expect(v.skimmerTime == fd * 10)
    }

    @Test func followsAStationaryPointerWhenTheViewScrolls() {
        let v = view()
        let p = over(v, frame: 10)
        v.pointerProvider = { p }
        v.updateSkimmerFromPointer()
        v.scroll(byX: 40, y: 0)
        #expect(v.skimmerTime == v.geometry.time(atX: p.x))
        #expect(v.skimmerTime != fd * 10)
    }

    @Test func rulerPointerHidesIt() {
        let v = view()
        v.updateSkimmer(pointer: over(v, frame: 10))
        v.updateSkimmer(pointer: CGPoint(x: v.geometry.x(for: fd * 10), y: 5))
        #expect(v.skimmerTime == nil)
    }
}
