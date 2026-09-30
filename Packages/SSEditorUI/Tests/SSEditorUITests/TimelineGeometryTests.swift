import CoreGraphics
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1, 24)

private func clip(_ startFrame: Int64, _ frames: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind,
         source: TimeRange(start: .zero, duration: fd * frames), start: fd * startFrame)
}

private func makeTimeline() -> (Timeline, v1: Track, v2: Track, a1: Track, a2: Track) {
    let v1 = Track(kind: .video, clips: [clip(0, 48), clip(72, 2), clip(100, 3)])
    let v2 = Track(kind: .video)
    let a1 = Track(kind: .audio)
    let a2 = Track(kind: .audio)
    return (Timeline(name: "t", frameDuration: fd, tracks: [v1, v2, a1, a2]), v1, v2, a1, a2)
}

@Suite struct TimelineGeometryTests {
    @Test func roundTripOneFrame200pt() {
        let g = TimelineGeometry(frameDuration: fd, pointsPerFrame: 200)
        #expect(abs(g.width(of: fd) - 200) < 1e-9)
        for n: Int64 in [0, 1, 2, 23, 24, 1000, 86_400] {
            let t = fd * n
            #expect(g.time(atX: g.x(for: t)) == t)
            #expect(g.time(atX: g.x(for: t) + 99) == t)            // just under half a frame
            #expect(g.time(atX: g.x(for: t) + 101) == t + fd)
        }
    }

    @Test func roundTripOneHour300pt() {
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 300.0 / 3600)
        let hour = Time(seconds: 3600)
        #expect(abs(g.width(of: hour) - 300) < 1e-9)
        #expect(g.time(atX: g.x(for: hour)) == hour)
        for n: Int64 in [0, 1, 24, 86_399, 86_400] {
            #expect(g.time(atX: g.x(for: fd * n)) == fd * n)
        }
        // A point 300 pt right of the origin is one hour, snapped to a frame.
        #expect(g.time(atX: TimelineGeometry.contentOriginX + 300) == hour)
    }

    @Test func ntscFrameDuration() {
        let ntsc = Time(1001, 30000)
        let g = TimelineGeometry(frameDuration: ntsc, pointsPerFrame: 50)
        for n: Int64 in [0, 1, 29, 107_892] { #expect(g.time(atX: g.x(for: ntsc * n)) == ntsc * n) }
    }

    @Test func scrollShiftsX() {
        var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 100)
        #expect(g.x(for: .zero) == TimelineGeometry.contentOriginX)
        g.scrollX = 50
        #expect(g.x(for: .zero) == TimelineGeometry.contentOriginX - 50)
        #expect(g.time(atX: g.x(for: Time(seconds: 2))) == Time(seconds: 2))
    }

    @Test func unsnappedTime() {
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 100)
        #expect(g.unsnappedTime(atX: TimelineGeometry.contentOriginX + 50) == Time(1, 2))
    }

    @Test func snapThresholdConversion() {
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 100)
        #expect(g.snapThreshold() == Time(2, 25))                   // 8 pt = 0.08 s
        #expect(g.snapThreshold(points: 10) == Time(1, 10))
        let far = TimelineGeometry(frameDuration: fd, pointsPerSecond: 300.0 / 3600)
        #expect(far.snapThreshold() == Time(96, 1))                 // 8 pt = 96 s
        let near = TimelineGeometry(frameDuration: fd, pointsPerFrame: 200)
        #expect(near.snapThreshold() < fd)
        #expect(near.snapThreshold() > .zero)
    }

    @Test func defaultRowHeightsAndLayout() {
        let (tl, v1, v2, a1, a2) = makeTimeline()
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 100)
        let rows = g.rows(for: tl)
        #expect(rows.map(\.track) == [v2.id, v1.id, a1.id, a2.id])   // V2, V1, A1, A2
        #expect(rows.map(\.label) == ["V2", "V1", "A1", "A2"])
        #expect(rows.map(\.height) == [20, 32, 26, 20])              // Track.height (48) is ignored
        #expect(rows[0].y == TimelineGeometry.rulerHeight)
        #expect(rows[1].y == rows[0].maxY)
        #expect(g.contentHeight(for: tl) == TimelineGeometry.rulerHeight + 98)
    }

    @Test func heightOverride() {
        let (tl, v1, _, _, _) = makeTimeline()
        var g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 100)
        g.heightOverrides[v1.id] = 60
        #expect(g.rows(for: tl).first { $0.track == v1.id }?.height == 60)
    }

    @Test func columnsAndRuler() {
        let (tl, v1, v2, _, _) = makeTimeline()
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 100)
        #expect(TimelineGeometry.toolColumnWidth == 38 && TimelineGeometry.headerWidth == 124)
        #expect(g.hitTest(CGPoint(x: 300, y: 5), in: tl) == .ruler)
        #expect(g.hitTest(CGPoint(x: 10, y: 5), in: tl) == .toolColumn)
        #expect(g.hitTest(CGPoint(x: 10, y: 50), in: tl) == .toolColumn)
        let rows = g.rows(for: tl)
        #expect(g.hitTest(CGPoint(x: 38, y: rows[0].y + 1), in: tl) == .header(v2.id))
        #expect(g.hitTest(CGPoint(x: 161, y: rows[1].y + 1), in: tl) == .header(v1.id))
        #expect(g.hitTest(CGPoint(x: 300, y: rows[3].maxY + 5), in: tl) == .none)
    }

    @Test func clipZonesAtEdges() {
        let (tl, v1, _, _, _) = makeTimeline()
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 100)
        let y = g.rows(for: tl).first { $0.track == v1.id }!.y + 5
        let c = v1.clips[0]                                          // frames 0..48 = 2 s = 200 pt
        let x0 = g.x(for: c.timeline.start), x1 = g.x(for: c.timeline.end)
        #expect(g.hitTest(CGPoint(x: x0, y: y), in: tl) == .clip(c.id, zone: .head))
        #expect(g.hitTest(CGPoint(x: x0 + 5.9, y: y), in: tl) == .clip(c.id, zone: .head))
        #expect(g.hitTest(CGPoint(x: x0 + 6, y: y), in: tl) == .clip(c.id, zone: .body))
        #expect(g.hitTest(CGPoint(x: x1 - 6.1, y: y), in: tl) == .clip(c.id, zone: .body))
        #expect(g.hitTest(CGPoint(x: x1 - 6, y: y), in: tl) == .clip(c.id, zone: .tail))
        #expect(g.hitTest(CGPoint(x: x1 - 0.1, y: y), in: tl) == .clip(c.id, zone: .tail))
        if case .gap(let id, let t) = g.hitTest(CGPoint(x: x1, y: y), in: tl) {    // end is exclusive
            #expect(id == v1.id && t == c.timeline.end)
        } else { Issue.record("expected gap at clip end") }
    }

    @Test func narrowClipKeepsBody() {
        let (tl, v1, _, _, _) = makeTimeline()
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 100)
        let y = g.rows(for: tl).first { $0.track == v1.id }!.y + 5
        let c = v1.clips[1]                                          // 2 frames = 8.33 pt wide
        let x0 = g.x(for: c.timeline.start), w = g.width(of: c.timeline.duration)
        let h = TimelineGeometry.trimHandleWidth(forClipWidth: w)
        #expect(abs(h - w / 3) < 1e-9)
        #expect(g.hitTest(CGPoint(x: x0 + w / 2, y: y), in: tl) == .clip(c.id, zone: .body))
        #expect(g.hitTest(CGPoint(x: x0 + 0.5, y: y), in: tl) == .clip(c.id, zone: .head))
        #expect(g.hitTest(CGPoint(x: x0 + w - 0.5, y: y), in: tl) == .clip(c.id, zone: .tail))
        #expect(TimelineGeometry.trimHandleWidth(forClipWidth: 100) == 6)
        #expect(TimelineGeometry.trimHandleWidth(forClipWidth: 18) == 6)
        #expect(TimelineGeometry.trimHandleWidth(forClipWidth: 12) == 4)
        #expect(TimelineGeometry.trimHandleWidth(forClipWidth: 0) == 0)
    }

    @Test func gapTimeIsSnappedAndClamped() {
        let (tl, _, v2, _, _) = makeTimeline()
        let g = TimelineGeometry(frameDuration: fd, pointsPerSecond: 100)
        let y = g.rows(for: tl)[0].y + 5
        // 100 pt right of origin = 1 s = frame 24
        #expect(g.hitTest(CGPoint(x: TimelineGeometry.contentOriginX + 100, y: y), in: tl) == .gap(v2.id, fd * 24))
        var scrolled = g
        scrolled.scrollX = -40                                       // rubber-band: time < 0 clamps to zero
        #expect(scrolled.hitTest(CGPoint(x: TimelineGeometry.contentOriginX + 10, y: y), in: tl) == .gap(v2.id, .zero))
    }
}
