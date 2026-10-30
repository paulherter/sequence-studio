import AppKit
import Foundation
import SQCore
import SQMedia
import Testing
@testable import SQTimelineUI

/// The content cache shifts its pixels on horizontal scroll and re-renders only the exposed strip and the clips crossing a
/// viewport edge. Every frame must be the picture a direct draw (cache off) gives.
@MainActor @Suite struct TimelineContentCacheTests {
    private static let fd = Time(1, 24)
    private static let size = CGSize(width: 900, height: 320)
    private static let scale: CGFloat = 2

    private func view(fx: Bool = false) -> TimelineView {
        let media = (0..<3).map { _ in UUID() }
        var tracks: [Track] = []
        for i in 0..<4 {
            let kind: TrackKind = i < 2 ? .video : .audio
            var start: Int64 = 0
            let clips = (0..<14).map { n -> Clip in
                let len = Int64(24 * (2 + (n * 5 + i * 3) % 7))                 // 2...8 s: some wider than the view's edges
                var c = Clip(name: "Clip \(i)-\(n) with a long name", media: kind == .audio ? media[(i + n) % 3] : UUID(), kind: kind,
                             source: TimeRange(start: Self.fd * Int64(n * 11), duration: Self.fd * len), start: Self.fd * start)
                if n == 4 { c.isEnabled = false }
                if fx, kind == .video { c.blendMode = .multiply }          // an applied effect shows the fx badge
                if kind == .audio, n % 3 == 0 { c.animation.volume.value = 0.5 }
                start += len + Int64(n % 4 == 0 ? 12 : 0)
                return c
            }
            tracks.append(Track(kind: kind, clips: clips, name: "T\(i)", isTargeted: i == 0))
        }
        var t = Timeline(name: "cache", frameDuration: Self.fd, tracks: tracks)
        t.captionTracks = [CaptionTrack(items: (0..<20).map { n in
            CaptionItem(lines: ["Caption number \(n) runs long"], range: TimeRange(start: Time(Int64(n * 4), 1), end: Time(Int64(n * 4 + 3), 1)))
        })]
        let v = TimelineView(timeline: t, frame: NSRect(origin: .zero, size: Self.size))
        let wf = TimelineWaveforms(builder: { _ in throw CancellationError() })
        for (i, id) in media.enumerated() { wf.setData(TimelineScrollPerfTests.waveform(seed: i), for: id) }
        v.waveforms = wf
        v.setZoom(pointsPerSecond: 40)
        v.setSelection([tracks[0].clips[3].id, tracks[2].clips[5].id])
        return v
    }

    private func render(_ v: TimelineView, offset: CGFloat = 0) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Self.size.width * Self.scale), pixelsHigh: Int(Self.size.height * Self.scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        cg.translateBy(x: 0, y: Self.size.height * Self.scale); cg.scaleBy(x: Self.scale, y: -Self.scale)
        cg.translateBy(x: offset, y: offset)                           // fractional panel origin: off the pixel grid
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        v.draw(v.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Bytes that differ by more than `tolerance`.
    private func differing(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, tolerance: Int = 2, skipColumn: Int = -1, skipRow: Int = -1) -> Int {
        guard let pa = a.bitmapData, let pb = b.bitmapData else { return -1 }
        var n = 0
        for y in 0..<a.pixelsHigh where y != skipRow {
            for x in 0..<(a.pixelsWide * 4) where x / 4 != skipColumn && abs(Int(pa[y * a.bytesPerRow + x]) - Int(pb[y * b.bytesPerRow + x])) > tolerance { n += 1 }
        }
        return n
    }

    private func expectSameAsDirect(_ v: TimelineView, _ note: String) {
        let cached = render(v)
        v.contentCache.isEnabled = false
        let direct = render(v)
        v.contentCache.isEnabled = true
        #expect(differing(cached, direct) == 0, "\(note)")
    }

    /// Feedback 2026-10-05: scrolling right to left stamped fx badges and name glyphs into clips. Every scrolled frame, name and
    /// badge bands included, must equal a fresh render at that offset (scrolls of both signs, small and large steps).
    @Test func scrolledNamesAndFXBadgesMatchAFreshRender() async {
        let v = view(fx: true)
        await v.waveforms?.cache.waitForIdle()
        expectSameAsDirect(v, "first frame")
        v.scroll(byX: 600, y: 0)
        expectSameAsDirect(v, "jump right")
        for (i, dx) in ([-3, -17, -40.5, -1, -90, -2, 25, -13, -64, -5] as [CGFloat]).enumerated() {
            v.scroll(byX: dx, y: 0)
            expectSameAsDirect(v, "step \(i) dx \(dx) scrollX \(v.geometry.scrollX)")
        }
    }

    @Test func shiftedFramesMatchTheDirectDraw() async {
        let v = view()
        await v.waveforms?.cache.waitForIdle()
        expectSameAsDirect(v, "first frame")
        let content = (Self.size.width - TimelineGeometry.contentOriginX) * (Self.size.height - TimelineGeometry.rulerHeight)
        for (i, dx) in ([37, 12.5, -50, 3, 0.5, -0.5, 120, -7.5, 400, 64] as [CGFloat]).enumerated() {
            let before = v.contentCache.renderedArea
            v.scroll(byX: dx, y: 0)
            expectSameAsDirect(v, "step \(i) dx \(dx) scrollX \(v.geometry.scrollX)")
            if abs(dx) < 200 { #expect(v.contentCache.renderedArea - before < content * 0.5, "step \(i)") }
        }
        #expect(v.contentCache.shifts >= 9)
    }

    /// FB-Q: vertical scroll shifts the pixels too (rows, captions and ghost strips all move with scrollY under the fixed
    /// ruler), re-rendering only the exposed strip; diagonal steps shift both ways at once.
    @Test func verticalScrollShiftsToo() async {
        let v = view()
        v.setTrackHeights(Dictionary(uniqueKeysWithValues: v.timeline.tracks.map { ($0.id, CGFloat(120)) }))
        await v.waveforms?.cache.waitForIdle()
        expectSameAsDirect(v, "tall rows")
        let content = (Self.size.width - TimelineGeometry.contentOriginX) * (Self.size.height - TimelineGeometry.rulerHeight)
        let shifts = v.contentCache.shifts
        let steps: [(CGFloat, CGFloat)] = [(0, 20), (0, 13.5), (0, -8), (0, 0.5), (15, 10), (-22.5, -6), (0, 40), (0, 10.3), (0, 400), (0, -60)]
        for (i, (dx, dy)) in steps.enumerated() {
            let before = v.contentCache.renderedArea
            v.scroll(byX: dx, y: dy)
            expectSameAsDirect(v, "step \(i) dx \(dx) dy \(dy) scrollY \(v.geometry.scrollY)")
            if abs(dy) < 100, dy != 10.3 { #expect(v.contentCache.renderedArea - before < content * 0.5, "step \(i)") }
        }
        #expect(v.contentCache.shifts >= shifts + 8)
    }

    @Test func overlaysAndStateChangesStayCorrect() async {
        let v = view()
        await v.waveforms?.cache.waitForIdle()
        _ = render(v)
        // Playhead moves draw over the cache without re-rendering clips.
        let area = v.contentCache.renderedArea
        v.setPlayhead(Time(7, 1))
        v.setPlayhead(Time(9, 1))
        expectSameAsDirect(v, "playhead")
        #expect(v.contentCache.renderedArea == area)
        // Selection change, then scroll: the new selection is in the shifted picture.
        v.setSelection([v.timeline.tracks[1].clips[2].id])
        v.scroll(byX: 25, y: 0)
        expectSameAsDirect(v, "selection then scroll")
        // Zoom and vertical scroll re-render; the next horizontal scroll shifts again.
        v.setZoom(pointsPerSecond: 55, anchorX: 400)
        expectSameAsDirect(v, "zoom")
        v.scroll(byX: 0, y: 10)
        expectSameAsDirect(v, "vertical")
        let shifts = v.contentCache.shifts
        v.scroll(byX: -30, y: 0)
        expectSameAsDirect(v, "after zoom")
        #expect(v.contentCache.shifts == shifts + 1)
    }

    /// QA after the redesign: layout and model changes between scrolls (height presets, Fit All Tracks, a locked / hidden track,
    /// markers, In/Out, a tool change) never leave stale cached pixels behind.
    @Test func layoutAndModelChangesBetweenScrollsMatchTheDirectDraw() async {
        let v = view()
        await v.waveforms?.cache.waitForIdle()
        expectSameAsDirect(v, "first frame")
        v.scroll(byX: 80, y: 0)
        expectSameAsDirect(v, "scrolled")
        v.setHeightMode(.large)
        expectSameAsDirect(v, "large preset")
        v.scroll(byX: -20, y: 6)
        expectSameAsDirect(v, "scroll after preset")
        v.setHeightMode(.small)
        v.scroll(byX: 30, y: 0)
        expectSameAsDirect(v, "small preset then scroll")
        v.setFitsTracks(true)
        expectSameAsDirect(v, "fit all")
        v.scroll(byX: 45, y: 0)
        expectSameAsDirect(v, "scroll in fit")
        v.setFitsTracks(false)
        expectSameAsDirect(v, "fit off")
        var t = v.timeline
        t.tracks[1].isLocked = true
        t.tracks[2].isVisible = false
        t.markers = [Marker(time: Time(5, 1)), Marker(time: Time(12, 1))]
        t.inOut = TimeRange(start: Time(3, 1), end: Time(20, 1))
        v.setTimeline(t)
        expectSameAsDirect(v, "model change")
        v.scroll(byX: 55, y: 0)
        expectSameAsDirect(v, "scroll after model change")
        v.toolState.tool = .razor
        v.scroll(byX: -35, y: 0)
        expectSameAsDirect(v, "razor then scroll")
        v.setZoom(pointsPerSecond: 20, anchorX: 300)
        v.scroll(byX: 10, y: 0)
        expectSameAsDirect(v, "zoom out then scroll")
    }

    @Test func fractionalOriginStillShifts() async {
        let v = view()
        await v.waveforms?.cache.waitForIdle()
        for offset: CGFloat in [0.25, 0.75] {
            _ = render(v, offset: offset)
            let shifts = v.contentCache.shifts
            for dx: CGFloat in [20, -7.5, 33] {
                v.scroll(byX: dx, y: 0)
                let cached = render(v, offset: offset)
                v.contentCache.isEnabled = false
                let direct = render(v, offset: offset)
                v.contentCache.isEnabled = true
                // The device pixel the content edge cuts through is a blend of several partly covered layers in a direct draw
                // and one copied pixel from the cache; every other pixel must match.
                let edgeX = Int(((TimelineGeometry.contentOriginX + offset) * Self.scale).rounded(.down))
                let edgeY = Int(((TimelineGeometry.rulerHeight + offset) * Self.scale).rounded(.down))
                #expect(differing(cached, direct, skipColumn: edgeX, skipRow: edgeY) == 0, "offset \(offset) dx \(dx)")
            }
            #expect(v.contentCache.shifts == shifts + 3, "offset \(offset)")
        }
    }

    @Test func zoomAnimationLinkDoesNotKeepTheViewAlive() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        weak var weakView: TimelineView?
        autoreleasepool {
            let v = view()
            window.contentView?.addSubview(v)
            v.zoomIn()
            let target = v.geometry.pointsPerSecond
            v.removeFromSuperview()                                       // leaving the window settles the animation
            #expect(v.geometry.pointsPerSecond != target)
            weakView = v
        }
        #expect(weakView == nil)
    }

    /// UI speed: a clip drag re-renders only the rows whose clips changed (not the whole content per drag event), and every
    /// frame is still the direct draw; cancel restores the picture.
    @Test func clipDragRerendersOnlyTheChangedRows() async {
        let v = view()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = v
        await v.waveforms?.cache.waitForIdle()
        _ = render(v)
        let c = v.timeline.tracks[0].clips[1]
        let row = v.geometry.rows(for: v.timeline).first { $0.track == v.timeline.tracks[0].id }!
        let p = CGPoint(x: (v.geometry.x(for: c.timeline.start) + v.geometry.x(for: c.timeline.end)) / 2, y: row.y + row.height / 2)
        func event(_ type: NSEvent.EventType, _ at: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: v.convert(at, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        v.mouseDown(with: event(.leftMouseDown, p))
        expectSameAsDirect(v, "mouse down")
        let content = (Self.size.width - TimelineGeometry.contentOriginX) * (Self.size.height - TimelineGeometry.rulerHeight)
        for (i, dx) in ([6, 14, 30, 22, 50, 3] as [CGFloat]).enumerated() {
            let before = v.contentCache.renderedArea
            v.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: p.x + dx, y: p.y)))
            #expect(v.timeline.tracks[0].clips.contains { $0.id == c.id && $0.start != c.start } || dx < 10, "step \(i) moved")
            expectSameAsDirect(v, "drag step \(i) dx \(dx)")
            #expect(v.contentCache.renderedArea - before < content * 0.5, "step \(i) re-rendered \(v.contentCache.renderedArea - before)")
        }
        v.cancelGesture()
        expectSameAsDirect(v, "cancelled")
        #expect(v.timeline.tracks[0].clips.first { $0.id == c.id }?.start == c.start)
        window.close()
    }

    @Test func fractionalPixelScrollRendersWhole() async {
        let v = view()
        await v.waveforms?.cache.waitForIdle()
        _ = render(v)
        let shifts = v.contentCache.shifts
        v.scroll(byX: 10.3, y: 0)                                  // not on the 2x pixel grid: no shift
        expectSameAsDirect(v, "fractional")
        #expect(v.contentCache.shifts == shifts)
    }
}
