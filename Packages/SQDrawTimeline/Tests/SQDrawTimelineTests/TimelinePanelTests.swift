import Foundation
import SQCore
import SQDrawKit
import SQEditorSession
import SQMedia
import SQTimelineUI
import Testing
@testable import SQDrawTimeline

private let fd = Time(1, 25)

private func clip(_ startFrame: Int64, _ frames: Int64, kind: TrackKind = .video) -> Clip {
    Clip(name: "c", media: UUID(), kind: kind, source: TimeRange(start: .zero, duration: fd * frames), start: fd * startFrame)
}

private final class TestClock: @unchecked Sendable { var now = 100.0 }

/// A 1000 x 400 pt panel at scale 1 with V1 (two clips), V2, A1, A2.
private func makePanel(clock: TestClock = TestClock()) -> (TimelinePanel, Timeline) {
    let v1 = Track(kind: .video, clips: [clip(0, 50), clip(100, 50)])
    let t = Timeline(name: "t", frameDuration: fd,
                     tracks: [v1, Track(kind: .video), Track(kind: .audio, clips: [clip(0, 50, kind: .audio)]), Track(kind: .audio)])
    var p = TimelinePanel()
    p.clock = { clock.now }
    p.layout(DrawRect(x: 0, y: 0, w: 1000, h: 400), scale: 1)
    p.sync(timeline: t, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
    return (p, t)
}

private func down(_ x: CGFloat, _ y: CGFloat, _ m: InputModifiers = []) -> InputEvent { .mouseDown(x: Float(x), y: Float(y), modifiers: m) }
private func drag(_ x: CGFloat, _ y: CGFloat) -> InputEvent { .mouseDragged(x: Float(x), y: Float(y)) }
private func up(_ x: CGFloat, _ y: CGFloat) -> InputEvent { .mouseUp(x: Float(x), y: Float(y)) }

@Suite struct TimelinePanelTests {
    @Test func rowFactsMatchTheMacView() {
        let (p, _) = makePanel()
        let rows = p.rows
        #expect(TimelinePanel.splitRow(rows) == 1)                  // V1 above the split (rows: V2, V1, A1, A2)
        #expect(TimelinePanel.isAltLane(1, in: rows) == false)      // the track next to the split is plain
        #expect(TimelinePanel.isAltLane(0, in: rows) == true)
        #expect(TimelinePanel.isAltLane(2, in: rows) == true)       // A1 shaded under V1, as on the Mac
        #expect(TimelinePanel.isAltLane(3, in: rows) == false)
    }

    @Test func headerSlotsAndHits() {
        let sl = TimelinePanel.slots(width: 120, height: 40, kind: .audio, showsSync: true, showsLock: true)
        #expect(sl.solo!.maxX == 116 && sl.mute!.maxX == sl.solo!.minX - 4 && sl.lock.maxX == sl.mute!.minX - 4)
        var (p, t) = makePanel()
        let a1 = t.tracks[2]
        let row = p.rows.first { $0.track == a1.id }!
        let s = TimelinePanel.layout(a1, width: TimelineGeometry.headerWidth, height: row.height, hovered: false)
        let x = TimelineGeometry.toolColumnWidth + s.solo!.midX, y = row.y + s.solo!.midY
        #expect(p.handle(down(x, y)) == [.toggleTrack(a1.id, .solo, shift: false, option: false)])
        #expect(p.handle(up(x, y)).isEmpty)
        let chip = TimelinePanel.chipRect(height: row.height)
        let cx = TimelineGeometry.toolColumnWidth + chip.midX
        #expect(p.handle(down(cx, row.y + chip.midY, .shift)) == [.toggleTrack(a1.id, .target, shift: true, option: false)])
    }

    @Test func rulerPressScrubsAndReleaseEnds() {
        var (p, _) = makePanel()
        let x = TimelineGeometry.contentOriginX + 200
        let a = p.handle(down(x, 10))
        #expect(a.first == .beginScrub)
        guard case .scrub(let t)? = a.last else { Issue.record("no scrub"); return }
        #expect(t == p.geometry.time(atX: x))
        #expect(p.handle(drag(x + 50, 10)).count == 1)
        #expect(p.handle(up(x + 50, 10)) == [.endScrub])
        #expect(!p.isDragging)
    }

    @Test func doubleClickOnANestedClipOpensIt() {
        let clock = TestClock()
        var (p, t) = makePanel(clock: clock)
        let seq = UUID()
        var c = clip(0, 50)
        c.sequence = seq
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c]), Track(kind: .audio)])
        _ = t
        p.sync(timeline: tl, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        let row = p.rows.first { $0.track == tl.tracks[0].id }!
        // Mid-clip and in the lower half of the row (the body, not the name band's trim handles).
        let x = (p.geometry.x(for: c.start) + p.geometry.x(for: c.timeline.end)) / 2, y = row.y + row.height * 0.7
        _ = p.handle(down(x, y)); _ = p.handle(up(x, y))
        clock.now += 0.2
        #expect(p.handle(down(x, y)) == [.openNestedSequence(seq)])
        // Two presses far apart in time are two single clicks.
        clock.now += 2
        _ = p.handle(up(x, y))
        #expect(p.handle(down(x, y)).contains(.openNestedSequence(seq)) == false)
    }

    @Test func draggingAClipCommitsAMove() {
        var (p, t) = makePanel()
        let c = t.tracks[0].clips[0]
        let row = p.rows.first { $0.track == t.tracks[0].id }!
        let x = (p.geometry.x(for: c.start) + p.geometry.x(for: c.timeline.end)) / 2, y = row.y + row.height * 0.7
        let a = p.handle(down(x, y))
        #expect(a.contains(.select(clips: [c.id], captions: [])))
        _ = p.handle(drag(x + 20, y))
        _ = p.handle(drag(x + 60, y))
        let end = p.handle(up(x + 60, y))
        #expect(end.contains { if case .commit = $0 { true } else { false } })
        #expect(!p.isDragging)
    }

    @Test func toolKeysWheelZoomAndDraw() {
        var (p, _) = makePanel()
        #expect(p.handle(.keyDown(.character("c"), modifiers: [])).isEmpty)
        #expect(p.toolState.tool == .razor)
        #expect(p.key(.character("q"), modifiers: []) == nil)       // not a timeline key: the host handles it
        let before = p.geometry.pointsPerSecond
        _ = p.handle(.scroll(x: 500, y: 100, dx: 0, dy: -40, modifiers: .command))
        #expect(p.geometry.pointsPerSecond != before)
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        #expect(list.quads.count > 20)
    }
}

@Suite struct TimelineZoomBarTests {
    @Test func barSitsUnderTheTracksAndDragsZoomAndPan() {
        var (p, _) = makePanel()
        let bar = p.zoomBarRect
        #expect(bar.height == ZoomScrollBarControl.height && bar.maxY == 400 && bar.minX == TimelineGeometry.contentOriginX)
        #expect(p.trackAreaHeight == 400 - ZoomScrollBarControl.height)
        // Fitted: the handles span the whole bar.
        let h0 = p.zoomBarHandles
        #expect(h0.lo == 0 && h0.hi > 0.9)
        // Drag the upper handle to the middle: zoomed in, scroll unchanged.
        let g = KeyframeZoomBarGeometry(width: bar.width)
        let xHi = bar.minX + g.x(forFraction: h0.hi), y = bar.midY
        let pps = p.geometry.pointsPerSecond
        #expect(p.handle(down(xHi, y)).isEmpty)
        #expect(p.isDragging)
        _ = p.handle(drag(bar.minX + g.x(forFraction: 0.5), y))
        _ = p.handle(up(bar.minX + g.x(forFraction: 0.5), y))
        #expect(p.geometry.pointsPerSecond > pps * 1.5)
        #expect(!p.isDragging)
        // Pan the body right: the view scrolls.
        let h1 = p.zoomBarHandles
        let mid = bar.minX + g.x(forFraction: (h1.lo + h1.hi) / 2)
        _ = p.handle(down(mid, y))
        _ = p.handle(drag(mid + 100, y))
        _ = p.handle(up(mid + 100, y))
        #expect(p.geometry.scrollX > 0)
    }
}

@Suite struct TimelineClipMarkerTests {
    @Test func flagDragCommitsAMove() {
        let clock = TestClock()
        var (p, _) = makePanel(clock: clock)
        var c = clip(0, 100)
        let m = Marker(time: fd * 20)
        c.markers = [m]
        let tl = Timeline(name: "t", frameDuration: fd, tracks: [Track(kind: .video, clips: [c]), Track(kind: .audio)])
        p.sync(timeline: tl, selection: [], playhead: .zero, selectedTransition: nil, labels: LabelResolver())
        let row = p.rows.first { $0.track == tl.tracks[0].id }!
        let x = p.geometry.x(for: fd * 20), y = row.maxY - 8
        // A flag is drawn (a polygon in the marker color) and a press there grabs it.
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        #expect(p.handle(down(x, y)).isEmpty)
        _ = p.handle(drag(x + 40, y))
        let end = p.handle(up(x + 40, y))
        guard case .moveClipMarker(let clipID, let markerID, let t)? = end.first else { Issue.record("no move"); return }
        #expect(clipID == c.id && markerID == m.id && t > fd * 20)
        #expect(p.timeline.tracks[0].clips[0].markers?.first?.time == fd * 20)   // preview back; the session commits
        // A double-click there opens the clip like anywhere on it (the Mac order: the open check runs first).
        clock.now += 5
        _ = p.handle(down(x, y)); _ = p.handle(up(x, y))
        clock.now += 0.1
        #expect(p.handle(down(x, y)) == [.openInSource(c.media)])
    }
}

/// A host media source: one waveform (a ramp) and one 160 x 90 picture in slot 2.
private final class FakeMedia: TimelineMediaSource {
    var offline: Set<UUID> = []
    func waveform(media: UUID) -> WaveformData? {
        var l0: [Float] = []
        for i in 0..<400 { let v = Float(i + 1) / 400; l0 += [-v, v] }
        return WaveformData(sampleRate: 1000, channelCount: 1, totalFrames: 4000, baseBucketSize: 10, levels: [l0])
    }
    func picture(media: UUID, at: Time?) -> TimelinePicture? { TimelinePicture(slot: 2, pixelSize: CGSize(width: 160, height: 90)) }
    func isOffline(media: UUID) -> Bool { offline.contains(media) }
}

@Suite struct TimelineMediaTests {
    @Test func audioClipsDrawTheirWaveformAndVideoClipsTheirThumbnail() {
        var (p, tl) = makePanel()
        #expect(p.rows.allSatisfy { $0.height >= VolumeLine.minRowHeight })   // tall enough for thumbnails and the volume band
        var bare = DrawList(width: 1000, height: 400)
        p.draw(into: &bare, atlas: nil)
        #expect(!bare.quads.contains { $0.kind == DrawQuad.Kind.image.rawValue })
        let m = FakeMedia()
        p.media = m
        var list = DrawList(width: 1000, height: 400)
        p.draw(into: &list, atlas: nil)
        let images = list.quads.filter { $0.kind == DrawQuad.Kind.image.rawValue }
        #expect(images.count == 2 && images.allSatisfy { $0.pad == 2 })     // the head column of both V1 clips
        // 16:9 into a 25 pt column: cropped to the middle of the picture.
        #expect(images[0].u0 > 0.3 && images[0].u1 < 0.7 && images[0].v0 == 0 && images[0].v1 == 1)
        #expect(list.quads.count > bare.quads.count + 50)                  // the waveform bars of the A1 clip
        // A missing file: the clip reads "Media offline" and loses its thumbnail.
        m.offline = [tl.tracks[0].clips[0].media]
        var off = DrawList(width: 1000, height: 400)
        p.draw(into: &off, atlas: nil)
        #expect(off.quads.filter { $0.kind == DrawQuad.Kind.image.rawValue }.count == 1)
    }

    @Test func pictureCropKeepsTheAspect() {
        let pic = TimelinePicture(slot: 0, source: (0, 0, 0.5, 0.5), pixelSize: CGSize(width: 200, height: 100))
        let c = pic.cropped(toFill: CGRect(x: 0, y: 0, width: 50, height: 50))
        #expect(abs(c.0 - 0.125) < 1e-6 && abs(c.2 - 0.375) < 1e-6 && c.1 == 0 && c.3 == 0.5)
    }
}
