import AppKit
import Foundation
import SSCore
import Testing
@testable import SSEditorUI

private let fd = Time(1, 24)

private func clip(_ n: Int, _ startFrame: Int64, _ frames: Int64, kind: TrackKind, media: UUID = UUID()) -> Clip {
    Clip(name: "Clip \(n)", media: media, kind: kind,
         source: TimeRange(start: .zero, duration: fd * frames), start: fd * startFrame)
}

/// 4 tracks x 50 clips = 200 clips, 24 frames each with a 6-frame gap.
@MainActor private func bigTimeline() -> Timeline {
    var tracks: [Track] = []
    for (i, kind) in [TrackKind.video, .video, .audio, .audio].enumerated() {
        let clips = (0..<50).map { clip(i * 50 + $0, Int64($0) * 30, 24, kind: kind) }
        tracks.append(Track(kind: kind, clips: clips, name: "T\(i)", isTargeted: i == 0))
    }
    var t = Timeline(name: "big", frameDuration: fd, tracks: tracks)
    t.inOut = TimeRange(start: fd * 100, end: fd * 400)
    t.markers = [Marker(time: fd * 200, name: "m"), Marker(time: fd * 900)]
    return t
}

/// 1x RGBA bitmap, top-left origin.
@MainActor private func makeRep(_ size: CGSize) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)!
}

/// Like `render`, but the view is asked to draw only `dirty` (what AppKit does for `setNeedsDisplay(rect)`).
@MainActor private func drawRegion(_ v: TimelineView, _ dirty: CGRect, into rep: NSBitmapImageRep) {
    guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return }
    let cg = base.cgContext
    cg.translateBy(x: 0, y: CGFloat(rep.pixelsHigh)); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    cg.clip(to: dirty)
    v.draw(dirty)
    NSGraphicsContext.restoreGraphicsState()
}

/// Direct draw calls of the view and its children into a flipped bitmap context (header button controls excluded:
/// those are stock NSButtons drawn by AppKit).
@MainActor private func render(_ v: TimelineView, _ rep: NSBitmapImageRep) {
    guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return }
    let cg = base.cgContext
    cg.translateBy(x: 0, y: CGFloat(rep.pixelsHigh)); cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    v.draw(v.bounds)
    for sub in v.subviews where !sub.isHidden {
        cg.saveGState()
        cg.translateBy(x: sub.frame.minX, y: sub.frame.minY)
        sub.draw(sub.bounds)
        cg.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
}

@MainActor @Suite struct TimelineViewTests {
    @Test func zoomKeepsAnchorTimeFixed() {
        let v = TimelineView(timeline: bigTimeline(), frame: NSRect(x: 0, y: 0, width: 1600, height: 180))
        v.setZoom(pointsPerSecond: 50, anchorX: 162)
        v.scroll(toX: 400)
        let anchor: CGFloat = 700
        let before = v.geometry.unsnappedTime(atX: anchor)
        v.setZoom(pointsPerSecond: 120, anchorX: anchor)
        let after = v.geometry.unsnappedTime(atX: anchor)
        #expect(abs(Double(before.value) / Double(before.timescale) - Double(after.value) / Double(after.timescale)) < 1e-4)
        #expect(v.geometry.pointsPerSecond == 120)
    }

    @Test func zoomCommandsAndClamp() {
        let v = TimelineView(timeline: bigTimeline(), frame: NSRect(x: 0, y: 0, width: 1600, height: 180))
        let z0 = v.geometry.pointsPerSecond
        v.zoomIn(); #expect(v.geometry.pointsPerSecond > z0)
        v.zoomOut(); v.zoomOut(); #expect(v.geometry.pointsPerSecond < z0)
        for _ in 0..<80 { v.zoomOut() }
        #expect(v.geometry.pointsPerSecond >= TimelineView.minPointsPerSecond)
        for _ in 0..<80 { v.zoomIn() }
        #expect(v.geometry.pointsPerSecond <= TimelineView.maxPointsPerFrame * 24 + 1e-9)
    }

    @Test func zoomToFitShowsWholeSequence() {
        let v = TimelineView(timeline: bigTimeline(), frame: NSRect(x: 0, y: 0, width: 1600, height: 180))
        v.setTimeline({ var t = bigTimeline(); t.inOut = nil; return t }())
        v.zoomToFit()
        let end = v.contentEnd
        #expect(v.geometry.x(for: end) <= 1600)
        #expect(v.geometry.x(for: .zero) >= TimelineGeometry.contentOriginX)
    }

    @Test func scrollClampsAndVertical() {
        let v = TimelineView(timeline: bigTimeline(), frame: NSRect(x: 0, y: 0, width: 1600, height: 100))
        v.scroll(byX: -500, y: -500)
        #expect(v.geometry.scrollX == 0 && v.geometry.scrollY == 0)
        v.scroll(byX: 1e9, y: 1e9)
        #expect(v.geometry.scrollX < 1e7)
        // Content height 22+32+32+26+26 = 138, viewport 100 -> max 38.
        #expect(v.geometry.scrollY == 38)
    }

    @Test func playheadAndSelectionInput() {
        let v = TimelineView(timeline: bigTimeline())
        v.setPlayhead(fd * 12)
        #expect(v.playhead == fd * 12)
        let id = v.timeline.tracks[0].clips[0].id
        v.setSelection([id])
        #expect(v.selection == [id])
        // Selection is pruned when the clip disappears.
        var t = v.timeline
        t.tracks[0] = Track(id: t.tracks[0].id, kind: .video)
        v.setTimeline(t)
        #expect(v.selection.isEmpty)
    }

    @Test func drawsSomething() throws {
        let v = TimelineView(timeline: bigTimeline(), frame: NSRect(x: 0, y: 0, width: 1600, height: 120))
        v.setZoom(pointsPerSecond: 23, anchorX: 162)
        let rep = makeRep(v.bounds.size)
        render(v, rep)
        // A video clip pixel (first clip of V1 is the bottom-most video row: row order V2, V1) differs from the lane colour.
        let c = try #require(rep.colorAt(x: 170, y: 22 + 20 + 16)?.usingColorSpace(.sRGB))
        #expect(c.blueComponent > c.redComponent)
    }

    /// FEEDBACK-4 item 16: repainting only the thin strip around the playhead must not erase the clip name under it.
    @Test func thinDirtyRectKeepsTheClipName() throws {
        var t = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, name: "V1")])
        let c = Clip(name: "Interview", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: fd * 480), start: .zero)
        try t.tracks[0].overwrite(c)
        let v = TimelineView(timeline: t, frame: NSRect(x: 0, y: 0, width: 1000, height: 120))
        v.setZoom(pointsPerSecond: 23, anchorX: 162)
        let full = makeRep(v.bounds.size)
        render(v, full)
        let partial = makeRep(v.bounds.size)
        memcpy(partial.bitmapData!, full.bitmapData!, full.bytesPerRow * full.pixelsHigh)
        // A 2 pt wide strip through the first letters of the name (name starts ~5 pt after the clip start at x 162).
        let strip = CGRect(x: 170, y: TimelineGeometry.rulerHeight, width: 2, height: 100)
        drawRegion(v, strip, into: partial)
        #expect(memcmp(partial.bitmapData!, full.bitmapData!, full.bytesPerRow * full.pixelsHigh) == 0)
    }

    /// T-02 acceptance: a 200-clip timeline redraws in under 4 ms.
    @Test func redrawPerformance200Clips() throws {
        let v = TimelineView(timeline: bigTimeline(), frame: NSRect(x: 0, y: 0, width: 1600, height: 120))
        v.setZoom(pointsPerSecond: 23, anchorX: 162)   // whole timeline visible: all 200 clips on screen
        v.setSelection(Set(v.timeline.tracks[0].clips.prefix(10).map(\.id)))
        v.setPlayhead(fd * 300)
        let rep = makeRep(v.bounds.size)
        for _ in 0..<5 { render(v, rep) }   // warm up fonts, caches
        let runs = 30
        var samples: [Double] = []
        for _ in 0..<runs {
            let t0 = DispatchTime.now().uptimeNanoseconds
            render(v, rep)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        samples.sort()
        let median = samples[runs / 2]
        print("T-02 redraw 200 clips (direct draw 1600x120, 4 tracks, full): median \(String(format: "%.2f", median)) ms, best \(String(format: "%.2f", samples[0])) ms, worst \(String(format: "%.2f", samples[runs - 1])) ms")
        #expect(median < 4)
    }
}
