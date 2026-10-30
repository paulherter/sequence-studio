import Foundation
import Testing
import SQCore
import SQDrawEditor
@testable import SQDrawKit
import SQText
import SQUIKit

/// A 30 fps sequence: V1 holds "Shot A" (0-4 s) and "Shot B" (4-10 s), A1 a linked audio clip (0-4 s).
func sampleTimeline() -> (Timeline, a: Clip.ID, b: Clip.ID, v1: Track.ID, v2: Track.ID, a1: Track.ID) {
    let fd = Time(1, 30), m = UUID()
    let a = Clip(name: "Shot A", media: m, kind: .video, source: TimeRange(start: .zero, duration: Time(seconds: 4)), start: .zero)
    let b = Clip(name: "Shot B", media: m, kind: .video, source: TimeRange(start: .zero, duration: Time(seconds: 6)),
                 start: Time(seconds: 4))
    let au = Clip(name: "Shot A", media: m, kind: .audio, source: TimeRange(start: .zero, duration: Time(seconds: 4)), start: .zero)
    let v1 = Track(kind: .video, clips: [a, b], name: "V1"), v2 = Track(kind: .video, name: "V2")
    let a1 = Track(kind: .audio, clips: [au], name: "A1")
    let t = Timeline(name: "Sequence 1", format: SequenceFormat(width: 1280, height: 720, frameDuration: fd), tracks: [v1, v2, a1])
    return (t, a.id, b.id, v1.id, v2.id, a1.id)
}

@Suite("SQDrawKit")
struct SQDrawKitTests {
    @Test func integerRectsFillExactly() {
        var l = DrawList(width: 4, height: 4)
        l.fill(DrawRect(x: 1, y: 1, w: 2, h: 2), DrawColor(1, 0, 0))
        let img = SoftwareRenderer.render(l, width: 4, height: 4, clear: .black, atlas: nil)
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(img.pixels[((y * 4 + x) * 4)..<((y * 4 + x) * 4 + 4)]) }
        #expect(px(1, 1) == [255, 0, 0, 255])
        #expect(px(2, 2) == [255, 0, 0, 255])
        #expect(px(0, 0) == [0, 0, 0, 255])
        #expect(px(3, 1) == [0, 0, 0, 255])
    }

    @Test func roundedCornersAndStrokesAntialias() {
        var l = DrawList(width: 20, height: 20)
        l.fill(DrawRect(x: 0, y: 0, w: 20, h: 20), .white, radius: 8)
        let img = SoftwareRenderer.render(l, width: 20, height: 20, clear: .black, atlas: nil)
        #expect(img.pixels[0] == 0)                                    // corner outside the arc
        #expect(img.pixels[(10 * 20 + 10) * 4] == 255)                 // center
        let edge = img.pixels[(1 * 20 + 3) * 4]
        #expect(edge > 0 && edge < 255)                                // on the arc: partial coverage
        var s = DrawList(width: 10, height: 10)
        s.stroke(DrawRect(x: 0, y: 0, w: 10, h: 10), .white, width: 2)
        let st = SoftwareRenderer.render(s, width: 10, height: 10, clear: .black, atlas: nil)
        #expect(st.pixels[(5 * 10 + 1) * 4] == 255)
        #expect(st.pixels[(5 * 10 + 5) * 4] == 0)
    }

    @Test func clipRectLimitsDrawing() {
        var l = DrawList(width: 8, height: 2)
        l.pushClip(DrawRect(x: 0, y: 0, w: 3, h: 2))
        l.fill(DrawRect(x: 0, y: 0, w: 8, h: 2), .white)
        l.popClip()
        let img = SoftwareRenderer.render(l, width: 8, height: 2, clear: .black, atlas: nil)
        #expect(img.pixels[2 * 4] == 255)
        #expect(img.pixels[3 * 4] == 0)
    }

    @Test func textDrawsGlyphsFromTheAtlas() throws {
        let atlas = try #require(GlyphAtlas())
        var l = DrawList(width: 80, height: 20)
        let w = l.text("Hello", x: 2, baseline: 15, pixelSize: 13, color: .white, atlas: atlas)
        #expect(w > 20 && w < 45)
        #expect(l.quads.count == 5)
        #expect(atlas.generation > 0)
        let img = SoftwareRenderer.render(l, width: 80, height: 20, clear: .black, atlas: atlas)
        #expect(img.pixels.enumerated().contains { $0.offset % 4 == 0 && $0.element > 200 })
        // Ellipsis when the text does not fit.
        #expect(atlas.fitted("A long clip name", pixelSize: 11, maxWidth: 40)?.hasSuffix("…") == true)
    }

    @Test func pngHasSignatureAndChunks() {
        let png = PNGWriter.encode(RGBAImage(width: 3, height: 2, fill: DrawColor(0.5, 0.25, 1)))
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(String(decoding: png[12..<16], as: UTF8.self) == "IHDR")
        #expect(String(decoding: png.suffix(8).prefix(4), as: UTF8.self) == "IEND")
    }

    @Test func themeUsesTheAppPalette() {
        let t = DrawTheme()
        #expect(t.panel == DrawColor(hex: 0x1E1E21))
        #expect(t.timeline == DrawColor(hex: 0x151518))
        #expect(t.label == DrawColor(hex: 0xE6E6E8))
        #expect(t.clip(.videoDefault) == DrawColor(hex: LabelColor.videoDefault.rgb))
        #expect(DrawTheme(scale: 2).px(DrawTheme.Metrics.trackHeader) == 312)
    }

    #if canImport(AppKit)
    @Test @MainActor func metricsMatchTheMacTheme() {
        #expect(Double(DrawTheme.Metrics.topBar) == Double(Theme.Metrics.topBar))
        #expect(Double(DrawTheme.Metrics.statusBar) == Double(Theme.Metrics.statusBar))
        #expect(Double(DrawTheme.Metrics.panelHeader) == Double(Theme.Metrics.panelHeader))
        #expect(Double(DrawTheme.Metrics.trackHeader) == Double(Theme.Metrics.trackHeader))
        #expect(Double(DrawTheme.Metrics.capsule) == Double(Theme.Metrics.capsule))
        #expect(Double(DrawTheme.Metrics.monitorHeader) == Double(Theme.Metrics.monitorHeader))
        #expect(Double(DrawTheme.Metrics.monitorFooter) == Double(Theme.Metrics.monitorFooter))
        #expect(Double(DrawTheme.Metrics.scrubBar) == Double(Theme.Metrics.scrubBar))
        #expect(Double(DrawTheme.Radius.small) == Double(Theme.Radius.small))
        #expect(Double(DrawTheme.Radius.panel) == Double(Theme.Radius.panel))
        #expect(Double(DrawTheme.Spacing.md) == Double(Theme.Spacing.md))
    }
    #endif
}

@Suite("SQDrawEditor")
struct SQDrawEditorTests {
    func screen(_ t: Timeline) -> EditorScreen {
        var s = EditorScreen()
        s.layout(width: 1280, height: 800, EditorSnapshot(projectName: "Sample", timeline: t))
        return s
    }

    @Test func barsStayLaidOutButUndrawnWhenTheHostDrawsThem() throws {
        let (t, _, _, _, _, _) = sampleTimeline()
        let atlas = try #require(GlyphAtlas())
        let snap = EditorSnapshot(projectName: "Sample", timeline: t, status: "Ready")
        var s = screen(t)
        let with = s.draw(snap, atlas: atlas, hasPicture: false).quads
        s.drawsBars = false
        s.layout(width: 1280, height: 800, snap)
        let without = s.draw(snap, atlas: atlas, hasPicture: false).quads
        #expect(s.statusBar.h > 0 && s.topBar.h > 0)
        #expect(without.count < with.count)
        func inBar(_ q: DrawQuad) -> Bool { q.y >= s.statusBar.y || q.y + q.h <= s.topBar.maxY }
        #expect(!without.contains(where: inBar))
    }

    @Test func projectPanelTakesTheLeftOfTheTimelineOnlyWhenAsked() {
        let (t, _, _, _, _, _) = sampleTimeline()
        let plain = screen(t)
        #expect(plain.project == .zero)
        var s = EditorScreen()
        s.projectWidth = 280
        s.layout(width: 1280, height: 800, EditorSnapshot(projectName: "Sample", timeline: t))
        #expect(s.project.w == 280)
        #expect(s.timelineView.frame.x >= s.project.x + s.project.w)
        #expect(s.timelineView.frame.w < plain.timelineView.frame.w)
    }

    @Test func rowsStackVideoTopDownThenAudio() {
        let (t, _, _, v1, v2, a1) = sampleTimeline()
        let s = screen(t)
        #expect(s.timelineView.rows.map(\.track) == [v2, v1, a1])
        #expect(s.timelineView.rows[0].y == s.timelineView.tracksArea.y)
        // Zoomed to fit on first layout: 10 s fill about 95 % of the track area.
        let x = s.timelineView.x(of: Time(seconds: 10), frameDuration: Time(1, 30))
        #expect(abs(x - (s.timelineView.tracksArea.x + s.timelineView.tracksArea.w * 0.95)) < 1)
    }

    @Test func clickSelectsDragMovesRazorCuts() {
        let (t, a, b, v1, _, _) = sampleTimeline()
        var s = screen(t)
        let snap = EditorSnapshot(projectName: "Sample", timeline: t)
        let tv = s.timelineView
        let row = tv.rows[1]
        let fd = Time(1, 30)
        let xB = tv.x(of: Time(seconds: 5), frameDuration: fd), y = row.y + row.h / 2
        #expect(s.handle(.mouseDown(x: xB, y: y, modifiers: []), snap) == [.select([b])])
        let selected = EditorSnapshot(projectName: "Sample", timeline: t, selection: [b])
        let oneSecond = tv.pixelsPerFrame * 30
        #expect(s.handle(.mouseDragged(x: xB + oneSecond, y: y), selected) == [])
        #expect(s.handle(.mouseUp(x: xB + oneSecond, y: y), selected) == [.move(b, to: Time(seconds: 5), track: v1)])
        // Shift-click adds.
        let xA = tv.x(of: Time(seconds: 1), frameDuration: fd)
        #expect(s.handle(.mouseDown(x: xA, y: y, modifiers: .shift), selected) == [.select([a, b])])
        _ = s.handle(.mouseUp(x: xA, y: y), selected)
        // Razor: the cut lands on the frame under the pointer.
        _ = s.handle(.keyDown(.character("c"), modifiers: []), snap)
        let cutX = tv.x(of: Time(seconds: 2), frameDuration: fd)
        #expect(s.handle(.mouseDown(x: cutX, y: y, modifiers: []), snap) == [.razor(at: Time(seconds: 2), track: v1)])
        // Empty space clears the selection; the ruler scrubs.
        _ = s.handle(.keyDown(.character("v"), modifiers: []), snap)
        let empty = tv.x(of: Time(seconds: 10) + Time(1, 3), frameDuration: fd)
        #expect(s.handle(.mouseDown(x: empty, y: y, modifiers: []), selected) == [.select([])])
        _ = s.handle(.mouseUp(x: empty, y: y), selected)
        let rx = tv.x(of: Time(seconds: 3), frameDuration: fd)
        #expect(s.handle(.mouseDown(x: rx, y: tv.ruler.midY, modifiers: []), snap) == [.beginScrub, .scrub(Time(seconds: 3))])
        #expect(s.handle(.mouseUp(x: rx, y: tv.ruler.midY), snap) == [.endScrub])
    }

    @Test func keysMapToTransportAndEdits() {
        let (t, _, b, _, _, _) = sampleTimeline()
        var s = screen(t)
        let snap = EditorSnapshot(projectName: "Sample", timeline: t, selection: [b])
        #expect(s.handle(.keyDown(.space, modifiers: []), snap) == [.playPause])
        #expect(s.handle(.keyDown(.right, modifiers: []), snap) == [.step(1)])
        #expect(s.handle(.keyDown(.left, modifiers: .shift), snap) == [.step(-5)])
        #expect(s.handle(.keyDown(.character("l"), modifiers: []), snap) == [.shuttle(.setRate(.forward))])
        #expect(s.handle(.keyDown(.character("z"), modifiers: .command), snap) == [.undo])
        #expect(s.handle(.keyDown(.character("Z"), modifiers: [.command, .shift]), snap) == [.redo])
        #expect(s.handle(.keyDown(.delete, modifiers: .shift), snap) == [.delete(ripple: true)])
        // The footer button fires on release over it (MonitorPanelView's buttons).
        #expect(s.handle(.mouseDown(x: s.playButton.midX, y: s.playButton.midY, modifiers: []), snap) == [])
        #expect(s.handle(.mouseUp(x: s.playButton.midX, y: s.playButton.midY), snap) == [.playPause])
        #expect(s.handle(.keyDown(.character("i"), modifiers: []), snap) == [.monitor(.markIn)])
        #expect(s.handle(.keyDown(.character("O"), modifiers: .shift), snap) == [.monitor(.goToOut)])
    }

    @Test func screenRendersDeterministically() throws {
        let atlas = try #require(GlyphAtlas())
        let (t, _, b, _, _, _) = sampleTimeline()
        let s = screen(t)
        let snap = EditorSnapshot(projectName: "Sample", timeline: t, selection: [b], playhead: Time(seconds: 2), status: "Ready")
        let list = s.draw(snap, atlas: atlas, hasPicture: false)
        #expect(list.quads.count > 50)
        let one = SoftwareRenderer.render(list, width: 1280, height: 800, clear: s.theme.canvas, atlas: atlas)
        let two = SoftwareRenderer.render(s.draw(snap, atlas: atlas, hasPicture: false), width: 1280, height: 800,
                                          clear: s.theme.canvas, atlas: atlas)
        #expect(one == two)
        // The selected clip carries the yellow edge.
        let xb = Int(s.timelineView.x(of: Time(seconds: 7), frameDuration: Time(1, 30)))
        let row = s.timelineView.rows[1]
        let i = (Int(row.y + 1) * 1280 + xb) * 4
        #expect(Array(one.pixels[i..<(i + 3)]) == [255, 214, 10])
        #expect(TimecodeText.string(Time(seconds: 3723) + Time(5, 30), frameDuration: Time(1, 30)) == "01:02:03:05")
    }
}

@Suite struct SampleProjectTests {
    @Test func twoShotsWithLinkedSoundAndStableIDs() throws {
        let fd = Time(1, 25)
        let p = SampleProject.make(mediaPath: "/m/sample.mp4", fileSize: 1000, width: 1280, height: 720,
                                   frameDuration: fd, frames: 250)
        let again = SampleProject.make(mediaPath: "/m/sample.mp4", fileSize: 1000, width: 1280, height: 720,
                                       frameDuration: fd, frames: 250)
        #expect(p == again)
        let t = try #require(p.timelines.first)
        #expect(t.tracks.map(\.name) == ["V1", "V2", "A1"])
        let v = t.tracks[0].clips, a = t.tracks[2].clips
        #expect(v.map(\.name) == ["Shot A", "Shot B"])
        #expect(v[0].start == .zero && v[0].source.duration == fd * 100)
        #expect(v[1].start == fd * 100 && v[1].source.start == fd * 125 && v[1].source.duration == fd * 125)
        #expect(t.tracks[1].clips.isEmpty)
        for (vc, ac) in zip(v, a) {
            #expect(ac.link == vc.link && vc.link != nil)
            #expect(ac.start == vc.start && ac.source == vc.source && ac.kind == .audio)
            #expect(ac.id != vc.id)
        }
        #expect(p.media.first?.path == "/m/sample.mp4")
    }
}
